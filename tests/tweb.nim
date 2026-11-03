## Web 基盤のテスト。Go 版 internal/web の infra_test.go / auth_test.go のうち、
## 手順3の範囲 (codec・CSRF・セッション・remember・ガード・エラーページ・
## 503・静的ファイル・ログイン/ログアウト・パスワード変更) の移植。
## ソケットは開かず、webcore.handle を直接呼ぶ (Go 版の httptest に相当)。
##
## テストユーザーのパスワードハッシュは、検証が速い pbkdf2 の固定ベクトルを
## 使う (scrypt はデバッグビルドで重いため。形式の往復は tpasswords が担う)。
## パスワード変更のテストだけは、本物の hashPassword (scrypt) を1回通す。

import std/[json, options, os, sequtils, strutils, tables, tempfiles, times,
            unittest]

import db
import migrations
import authsvc
import passwords
import sessioncodec
import webcore
import config

const ProjRoot = currentSourcePath.parentDir.parentDir
const SqlAlchemySql = ProjRoot / "tests/testdata/db/sqlalchemy_version_schema.sql"
const TestPassword = "password123"
const TestHash = "pbkdf2:sha256:1000$tweb-salt-0123$" &
  "484524fc3353e4eec1937452b3e2756506e7ce7f8b16732b655b7ba3ecc32bea"
  ## Werkzeug 形式の pbkdf2 ハッシュ (password123 用。Python の
  ## hashlib.pbkdf2_hmac で生成し、passwords.verify で照合できることを確認済み)

# ---- テスト用の時計とログ (トップレベル proc + threadvar。ハーネスの差し替え用) ------

var clockOffset {.threadvar.}: int64
var logLines {.threadvar.}: seq[string]

proc testNow(): int64 {.gcsafe.} =
  epochTime().int64 + clockOffset

proc testLog(msg: string) {.gcsafe.} =
  logLines.add msg

proc advance(seconds: int64) =
  clockOffset += seconds

proc logsText(): string = logLines.join("\n")

# ---- ハーネス ---------------------------------------------------------------------------

type Harness = object
  app: App
  dir: string
  dbPath: string
  conn: DbConn # テストが直接 DB を操作する (サーバーとは別の接続)

proc baseConfig(dbPath: string): WebConfig =
  WebConfig(databasePath: dbPath, secretKey: "test-secret-key",
            now: testNow, log: testLog)

proc seedUsers(conn: DbConn) =
  execSql(conn, "INSERT INTO \"user\" (username, password_hash, role) VALUES " &
    "('admin', '" & TestHash & "', 'admin'), ('staff', '" & TestHash & "', 'staff')")

# テスト専用の補助ルート (Go 版 harness の /test/* と、画面の代わりのスタブ)
proc stubPage(st: var ReqState, req: var Request): Response {.gcsafe.} =
  st.renderPage(200, DefaultTitle, tplDashboardStub, newJObject())

proc whoamiPage(st: var ReqState, req: var Request): Response {.gcsafe.} =
  plainResponse(200, st.currentUser().get.username)

proc postEcho(st: var ReqState, req: var Request): Response {.gcsafe.} =
  plainResponse(200, "posted:" & req.formValue("x"))

proc flashPage(st: var ReqState, req: var Request): Response {.gcsafe.} =
  st.flash("info", req.queryValue("m"))
  st.flash("success", "二つ目")
  st.renderPage(200, DefaultTitle, tplDashboardStub, newJObject())

proc flashRedirect(st: var ReqState, req: var Request): Response {.gcsafe.} =
  st.flash("success", "保存しました。")
  redirect("/login")

proc panicPage(st: var ReqState, req: var Request): Response {.gcsafe.} =
  raise newException(ValueError, "secret-internal-detail")

proc busyPage(st: var ReqState, req: var Request): Response {.gcsafe.} =
  raise newException(ValueError, "database is locked")

proc errPage(st: var ReqState, req: var Request): Response {.gcsafe.} =
  raise newException(ValueError, "boom: secret-detail")

proc adminStub(st: var ReqState, req: var Request): Response {.gcsafe.} =
  plainResponse(200, "admin")

proc registerTestRoutes(app: App) =
  app.pageRoute("GET", "/blank", stubPage)
  app.pageRoute("GET", "/printed", stubPage)
  app.pageRoute("GET", "/receive", stubPage)
  app.pageRoute("GET", "/history", stubPage)
  app.adminRoute("GET", "/admin/users", adminStub)
  app.adminRoute("GET", "/admin/items", adminStub)
  app.pageRoute("GET", "/test/whoami", whoamiPage)
  app.pageRoute("POST", "/test/post", postEcho)
  app.publicRoute("GET", "/test/flash", flashPage)
  app.publicRoute("GET", "/test/flash-redirect", flashRedirect)
  app.publicRoute("GET", "/test/panic", panicPage)
  app.publicRoute("GET", "/test/busy", busyPage)
  app.publicRoute("GET", "/test/err", errPage)

proc newHarness(): Harness =
  ## マイグレーション済みの DB (admin / staff の2人) と Server を作る。
  clockOffset = 0
  logLines = @[]
  result.dir = createTempDir("tweb", "")
  result.dbPath = result.dir / "inventory.db"
  result.conn = openDb(result.dbPath)
  discard migrate(result.conn)
  seedUsers(result.conn)
  result.app = newApp(baseConfig(result.dbPath))
  result.app.registerTestRoutes()

proc newHarnessAt(dbPath: string, secret = "test-secret-key",
                  secure = false): Harness =
  ## 既存 (または存在しない) DB ファイルに対する Server。
  clockOffset = 0
  logLines = @[]
  result.dbPath = dbPath
  result.dir = dbPath.parentDir
  var cfg = baseConfig(dbPath)
  cfg.secretKey = secret
  cfg.cookieSecure = secure
  result.app = newApp(cfg)
  result.app.registerTestRoutes()

# ---- クライアント (Cookie Jar つき) -------------------------------------------------------

type Client = object
  app: App
  jar: Table[string, string]

proc client(h: Harness): Client =
  Client(app: h.app, jar: initTable[string, string]())

proc applyCookies(c: var Client, resp: Response) =
  for (k, v) in resp.headers:
    if cmpIgnoreCase(k, "Set-Cookie") == 0:
      let first = v.split(';')[0]
      let eq = first.find('=')
      if eq > 0:
        if "Max-Age=0" in v:
          c.jar.del(first[0 ..< eq])
        else:
          c.jar[first[0 ..< eq]] = first[eq + 1 ..^ 1]

proc doReq(c: var Client, req: var Request): Response =
  req.cookies = c.jar
  result = c.app.handle(req)
  c.applyCookies(result)

proc get(c: var Client, target: string): Response =
  var req = newRequest("GET", target)
  c.doReq(req)

proc encodeForm(form: seq[(string, string)]): string =
  form.map(proc (kv: (string, string)): string =
    queryEscape(kv[0]) & "=" & queryEscape(kv[1])).join("&")

proc post(c: var Client, target: string, form: seq[(string, string)],
          headers: seq[(string, string)] = @[]): Response =
  var req = newRequest("POST", target)
  req.headers.add ("Content-Type", "application/x-www-form-urlencoded")
  for hd in headers:
    req.headers.add hd
  req.body = encodeForm(form)
  c.doReq(req)

proc respHeader(r: Response, name: string): string = headerGet(r.headers, name)

proc location(r: Response): string = r.respHeader("Location")

proc setCookieLine(r: Response, name: string): string =
  ## その名前の Set-Cookie 行 (無ければ空文字)。
  for (k, v) in r.headers:
    if cmpIgnoreCase(k, "Set-Cookie") == 0 and
       (v.startsWith(name & "=") or v.startsWith(name & ";")):
      return v
  ""

proc csrfToken(c: var Client, page = "/login"): string =
  ## ページを開いて、CSRF トークンを取り出す (未ログインでも、セッションが作られる)。
  let r = c.get(page)
  let marker = "name=\"csrf_token\" value=\""
  let i = r.body.find(marker)
  doAssert i >= 0, "no csrf token in page (status " & $r.status & ")"
  let start = i + marker.len
  r.body[start ..< r.body.find('"', start)]

proc postCSRF(c: var Client, tokenPage, target: string,
              form: seq[(string, string)]): Response =
  var f = form
  f.add ("csrf_token", c.csrfToken(tokenPage))
  c.post(target, f)

proc login(c: var Client, user, pw: string, remember = false): Response =
  var f = @[("username", user), ("password", pw)]
  if remember:
    f.add ("remember", "on")
  c.postCSRF("/login", "/login", f)

proc mustLogin(c: var Client, user: string, remember = false) =
  let r = c.login(user, TestPassword, remember)
  doAssert r.status == 302 and r.location == "/",
    "login failed: " & $r.status & " " & r.location

proc hasSetCookie(r: Response): bool =
  for (k, _) in r.headers:
    if cmpIgnoreCase(k, "Set-Cookie") == 0:
      return true
  false

proc contains(r: Response, want: string): bool = want in r.body
proc notContains(r: Response, bad: string): bool = bad notin r.body

# ---- codec ---------------------------------------------------------------------------------

suite "codec":
  test "roundtrip preserves the JSON payload":
    let c = newCodec("secret", "session")
    let v = %*{"u": 3, "t": "tok123", "c": "csrf", "i": 1700000000}
    let (n, ok) = c.decode(c.encode(v))
    check ok
    check n == v

  test "value form is base64url payload dot signature":
    let c = newCodec("secret", "session")
    let enc = c.encode(%"hello")
    let parts = enc.split('.')
    check parts.len == 2
    check parts[0] == "ImhlbGxvIg" # base64url(`"hello"`)
    check '+' notin enc and '/' notin enc and '=' notin enc

  test "tampered and malformed values are rejected":
    let c = newCodec("secret", "session")
    let enc = c.encode(%*{"u": 1, "i": 1})
    for bad in ["", "garbage", ".", "a.", ".b", enc[0 ..< enc.len - 2] & "AA",
                "AAAA" & enc[4 ..^ 1]]:
      check not c.decode(bad).ok

  test "other purpose and other secret are rejected":
    let enc = newCodec("secret", "session").encode(%*{"u": 1})
    check not newCodec("secret", "remember").decode(enc).ok
    check not newCodec("secret", "flash").decode(enc).ok
    check not newCodec("another-secret", "session").decode(enc).ok

  test "b64url roundtrip and validation":
    for s in ["", "a", "ab", "abc", "abcd", "\x00\xff\xfe binary \x01"]:
      let (data, ok) = b64urlDecode(b64urlEncode(s))
      check ok and data == s
    check not b64urlDecode("a").ok      # 長さ mod 4 == 1 は不正
    check not b64urlDecode("ab$=").ok   # 使えない文字
    check b64urlDecode("SGVsbG8").data == "Hello"

# ---- CSRF -------------------------------------------------------------------------------------

suite "csrf":
  test "posts without a valid token are rejected":
    let h = newHarness()
    var c = h.client()
    for form in [
        @[("username", "admin"), ("password", TestPassword)],
        @[("username", "admin"), ("password", TestPassword), ("csrf_token", "")],
        @[("username", "admin"), ("password", TestPassword), ("csrf_token", "abc")],
        @[("username", "admin"), ("password", TestPassword),
          ("csrf_token", "1700000000.AAAA")]]:
      let r = c.post("/login", form)
      check r.status == 400
      check r.contains(MsgCSRF)
    check c.get("/blank").status == 302 # 拒否されたログインでログイン状態にならない

  test "csrf failure does not change state":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("admin")
    check c.post("/logout", @[]).status == 400
    check c.get("/blank").status == 200 # まだログイン中
    check c.post("/test/post", @[("x", "1")]).status == 400

  test "token is bound to the session":
    let h = newHarness()
    var a = h.client()
    var b = h.client()
    a.mustLogin("admin")
    b.mustLogin("admin")
    let tokA = a.csrfToken("/blank")
    let own = a.post("/test/post", @[("x", "1"), ("csrf_token", tokA)])
    check own.status == 200 and own.body == "posted:1"
    check b.post("/test/post", @[("x", "1"), ("csrf_token", tokA)]).status == 400

  test "header token is accepted":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("admin")
    let tok = c.csrfToken("/blank")
    let r = c.post("/test/post", @[("x", "h")], @[("X-CSRFToken", tok)])
    check r.status == 200 and r.body == "posted:h"
    check c.post("/test/post", @[("x", "h")],
                 @[("X-CSRFToken", "bad")]).status == 400

  test "token expires after one hour":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("admin")
    let tok = c.csrfToken("/blank")
    advance(59 * 60)
    check c.post("/test/post", @[("x", "1"), ("csrf_token", tok)]).status == 200
    advance(2 * 60)
    let r = c.post("/test/post", @[("x", "1"), ("csrf_token", tok)])
    check r.status == 400
    check r.contains(MsgCSRF)
    # ページを開き直せば、また送れる
    check c.postCSRF("/blank", "/test/post", @[("x", "1")]).status == 200

  test "oversized form is rejected":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("admin")
    let big = @[("x", repeat("a", 2 shl 20)), ("csrf_token", c.csrfToken("/blank"))]
    check c.post("/test/post", big).status == 400

# ---- セッションと remember ------------------------------------------------------------------------

suite "session and remember":
  test "session cookie attributes":
    let h = newHarness()
    var c = h.client()
    let tok = c.csrfToken("/login")
    let r = c.post("/login", @[("username", "admin"), ("password", TestPassword),
                               ("csrf_token", tok)])
    let line = r.setCookieLine("session")
    check line != ""
    check "HttpOnly" in line and "SameSite=Lax" in line and "Path=/" in line
    check "Secure" notin line
    check "Max-Age" notin line and "Expires" notin line # ブラウザを閉じるまで
    check r.setCookieLine("remember") == "" # チェックなしでは出ない
    let value = line.split(';')[0].split('=', 1)[1]
    check TestPassword notin value

  test "cookies are secure when configured":
    let dir = createTempDir("tweb", "")
    let path = dir / "inventory.db"
    let conn = openDb(path)
    discard migrate(conn)
    seedUsers(conn)
    conn.close()
    let h = newHarnessAt(path, secure = true)
    var c = h.client()
    let r = c.login("admin", TestPassword, remember = true)
    check r.status == 302
    for name in ["session", "remember"]:
      let line = r.setCookieLine(name)
      check line != "" and "Secure" in line and "HttpOnly" in line

  test "remember cookie attributes":
    let h = newHarness()
    var c = h.client()
    let r = c.login("admin", TestPassword, remember = true)
    let line = r.setCookieLine("remember")
    check line != ""
    check "Max-Age=31536000" in line # 365日 (Flask-Login の既定)
    check "HttpOnly" in line and "Path=/" in line

  test "remember restores the session after the session cookie is lost":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("admin", remember = true)
    c.jar.del("session") # ブラウザを閉じた状態
    let r = c.get("/test/whoami")
    check r.status == 200 and r.body == "admin"
    check r.setCookieLine("session") != "" # セッション Cookie が再発行される
    var c2 = h.client()
    c2.mustLogin("admin")
    c2.jar.del("session")
    check c2.get("/blank").status == 302 # ログイン保持なしでは復元されない

  test "session expires after fourteen days but remember outlives it":
    let h = newHarness()
    var plain = h.client()
    var kept = h.client()
    plain.mustLogin("admin")
    kept.mustLogin("admin", remember = true)
    advance(13 * 24 * 3600 + 23 * 3600)
    check plain.get("/blank").status == 200
    advance(2 * 3600) # 14日を超えた
    check plain.get("/blank").status == 302
    check kept.get("/blank").status == 200 # remember から復元
    advance(352 * 24 * 3600) # 合計で365日を超えた
    check kept.get("/blank").status == 302

  test "logout clears the cookies":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("admin", remember = true)
    let r = c.postCSRF("/blank", "/logout", @[])
    check r.status == 302 and r.location == "/login"
    check "Max-Age=0" in r.setCookieLine("session")
    check "Max-Age=0" in r.setCookieLine("remember")
    check c.get("/blank").status == 302

  test "disabled user's existing session is rejected":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("staff", remember = true)
    check c.get("/blank").status == 200
    execSql(h.conn, "UPDATE \"user\" SET is_active = 0 WHERE username = 'staff'")
    let r = c.get("/blank")
    check r.status == 302 and r.location.startsWith("/login")
    check "Max-Age=0" in r.setCookieLine("remember") # 古い remember も消される
    execSql(h.conn, "UPDATE \"user\" SET is_active = 1 WHERE username = 'staff'")
    c.mustLogin("staff") # 有効に戻せば、またログインできる

  test "tampered and foreign cookies are ignored":
    let h = newHarness()
    var good = h.client()
    good.mustLogin("admin", remember = true)
    let sess = good.jar["session"]
    let rem = good.jar["remember"]
    let other = newHarnessAt(h.dbPath, secret = "a-different-secret")
    var foreign = other.client()
    foreign.mustLogin("admin", remember = true)
    proc flip(s: string): string =
      result = s
      let i = result.len - 2
      result[i] = if result[i] == 'A': 'B' else: 'A'
    proc tamperPayload(v: string): string =
      let i = v.find('.')
      "eyJ" & v[3 ..< i] & "AA" & v[i ..^ 1]
    let flashEnc = newCodec("test-secret-key", "flash").encode(
      %*{"u": 1, "i": testNow()})
    for (s, r) in [("", ""), ("garbage", "garbage"), (".", "."),
                   (sess[0 ..< sess.len - 3], rem[0 ..< rem.len - 3]),
                   (flip(sess), flip(rem)),
                   (foreign.jar["session"], foreign.jar["remember"]),
                   (rem, sess), (flashEnc, flashEnc),
                   (tamperPayload(sess), tamperPayload(rem))]:
      var c = h.client()
      discard c.get("/login") # CSRF 用のセッションを作っておく
      c.jar["session"] = s
      c.jar["remember"] = r
      check c.get("/blank").status == 302
    check "panic" notin logsText()

# ---- ガード (ログイン必須・管理者) ---------------------------------------------------------------------

suite "guards":
  test "login required redirects":
    let h = newHarness()
    var c = h.client()
    for p in ["/", "/blank", "/printed", "/receive", "/history", "/admin/users"]:
      let r = c.get(p)
      check r.status == 302 and r.location.startsWith("/login")

  test "unauthenticated redirect keeps the whole URL in next":
    let h = newHarness()
    var c = h.client()
    let r = c.get("/blank?category=1&q=a%20b")
    check r.location == "/login?next=%2Fblank%3Fcategory%3D1%26q%3Da%2520b"

  test "login required message is shown once on the login page":
    let h = newHarness()
    var c = h.client()
    discard c.get("/blank")
    let first = c.get("/login")
    check first.contains("ログインしてください。")
    check first.contains("alert-warning")
    check c.get("/login").notContains("ログインしてください。")

  test "staff cannot access admin but admin can":
    let h = newHarness()
    var staff = h.client()
    staff.mustLogin("staff")
    for p in ["/admin/users", "/admin/items"]:
      let r = staff.get(p)
      check r.status == 403
      check r.contains("この操作をする権限がありません。")
    check staff.get("/blank").status == 200
    var admin = h.client()
    admin.mustLogin("admin")
    for p in ["/admin/users", "/admin/items", "/blank"]:
      check admin.get(p).status == 200
    var anon = h.client()
    check anon.get("/admin/users").status == 302 # 未ログインは 403 でなくログイン画面へ

  test "navigation shows admin links only to admins":
    let h = newHarness()
    var a = h.client()
    var s = h.client()
    a.mustLogin("admin")
    s.mustLogin("staff")
    let ra = a.get("/blank")
    let rs = s.get("/blank")
    check ra.contains("href=\"/admin/users\"")
    check rs.notContains("href=\"/admin/users\"")
    check rs.contains("href=\"/receive\"")
    check rs.contains(">staff</a>") # ユーザー名 (パスワード変更へのリンク)
    var anon = h.client()
    check anon.get("/login").notContains("href=\"/receive\"")

  test "username is HTML-escaped in navigation":
    let h = newHarness()
    execSql(h.conn, "INSERT INTO \"user\" (username, password_hash, role) VALUES " &
      "('<i>x</i>', '" & TestHash & "', 'staff')")
    var c = h.client()
    c.mustLogin("<i>x</i>")
    let r = c.get("/blank")
    check r.contains("&lt;i&gt;x&lt;/i&gt;")
    check r.notContains("<i>x</i>")

# ---- ログイン / ログアウト --------------------------------------------------------------------------------

suite "login flow":
  test "login, logout, and open redirect blocked":
    let h = newHarness()
    var c = h.client()
    let r = c.postCSRF("/login", "/login?next=https://evil.example/",
      @[("username", "admin"), ("password", TestPassword)])
    check r.status == 302 and r.location == "/"
    let lo = c.postCSRF("/", "/logout", @[])
    check lo.status == 302 and lo.location == "/login"
    let bad = c.login("admin", "wrong")
    check bad.status == 200
    check bad.contains("違います")
    check bad.contains("alert-danger")

  test "safe next is followed after login, evil next is not":
    let h = newHarness()
    var c = h.client()
    let r = c.postCSRF("/login", "/login?next=%2Fblank%3Fcategory%3D1",
      @[("username", "admin"), ("password", TestPassword)])
    check r.status == 302 and r.location == "/blank?category=1"
    for evil in ["//evil.example", "https://evil.example", "/\t/evil",
                 "/\n/evil", "javascript:alert(1)", "evil"]:
      var c2 = h.client()
      let rr = c2.postCSRF("/login", "/login?next=" & queryEscape(evil),
        @[("username", "admin"), ("password", TestPassword)])
      check rr.status == 302 and rr.location == "/"

  test "disabled user cannot login":
    let h = newHarness()
    execSql(h.conn, "UPDATE \"user\" SET is_active = 0 WHERE username = 'staff'")
    var c = h.client()
    let r = c.login("staff", TestPassword)
    check r.status == 200
    check r.contains("違います")

  test "unknown user and wrong password look the same":
    let h = newHarness()
    var a = h.client()
    var b = h.client()
    let ra = a.login("nobody", "x")
    let rb = b.login("admin", "x")
    check ra.status == 200 and rb.status == 200
    check ra.contains("ユーザー名またはパスワードが違います。")
    check rb.contains("ユーザー名またはパスワードが違います。")

  test "username whitespace is stripped at login":
    let h = newHarness()
    var c = h.client()
    check c.login(" admin\u{3000}", TestPassword).status == 302

  test "logged-in user visiting login goes home":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("admin")
    let r = c.get("/login")
    check r.status == 302 and r.location == "/"

# ---- パスワード変更 -------------------------------------------------------------------------------------------------

suite "password change":
  test "change password rules":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("staff")
    for (old, nw, conf, msg) in [
        ("wrong", "newpassword1", "newpassword1", MsgOldPasswordWrong),
        (TestPassword, "short", "short", MsgPasswordTooShort),
        (TestPassword, "1234567", "1234567", MsgPasswordTooShort),
        (TestPassword, "あいうえおかき", "あいうえおかき", MsgPasswordTooShort), # 7文字
        (TestPassword, "newpassword1", "newpassword2", MsgConfirmMismatch)]:
      let r = c.postCSRF("/account/password", "/account/password",
        @[("old", old), ("new", nw), ("confirm", conf)])
      check r.status == 200
      check r.contains(msg)
      check r.contains("alert-danger")
    check h.conn.getValue(SqlQuery("SELECT password_hash FROM \"user\" WHERE username='staff'")) == TestHash
    # 8文字ちょうど (日本語は文字数で数える) は通る
    let r = c.postCSRF("/account/password", "/account/password",
      @[("old", TestPassword), ("new", "あいうえおかきく"), ("confirm", "あいうえおかきく")])
    check r.status == 302 and r.location == "/"
    check c.get("/").contains("パスワードを変更しました。")
    let hash = h.conn.getValue(SqlQuery("SELECT password_hash FROM \"user\" WHERE username='staff'"))
    check hash.startsWith("scrypt:32768:8:1$") # Flask 版 (Werkzeug) でも読める形式
    check verify(hash, "あいうえおかきく")
    var old = h.client()
    check old.login("staff", TestPassword).status == 200 # 旧パスワードは使えない
    var newc = h.client()
    check newc.login("staff", "あいうえおかきく").status == 302

  test "password change invalidates other sessions but not the own":
    let h = newHarness()
    var a = h.client()
    var b = h.client()
    var bKept = h.client()
    a.mustLogin("staff")
    b.mustLogin("staff")
    bKept.mustLogin("staff", remember = true)
    let r = a.postCSRF("/account/password", "/account/password",
      @[("old", TestPassword), ("new", "newpassword1"), ("confirm", "newpassword1")])
    check r.status == 302 and r.location == "/"
    check a.get("/blank").status == 200 # 自分のセッションは生き続ける
    check b.get("/blank").status == 302 # 他のセッションは無効
    check bKept.get("/blank").status == 302 # remember も古いトークンでは復元されない

  test "own remember cookie is refreshed after password change":
    let h = newHarness()
    var a = h.client()
    a.mustLogin("staff", remember = true)
    discard a.postCSRF("/account/password", "/account/password",
      @[("old", TestPassword), ("new", "newpassword1"), ("confirm", "newpassword1")])
    a.jar.del("session")
    let r = a.get("/test/whoami")
    check r.status == 200 and r.body == "staff"

  test "change password requires login":
    let h = newHarness()
    var c = h.client()
    check c.get("/account/password").status == 302
    let tok = c.csrfToken("/login")
    let r = c.post("/account/password",
      @[("old", TestPassword), ("new", "newpassword1"),
        ("confirm", "newpassword1"), ("csrf_token", tok)])
    check r.status == 302 and r.location.startsWith("/login")

# ---- flash ------------------------------------------------------------------------------------------------------------

suite "flash":
  test "flash is escaped, shown once, and in order":
    let h = newHarness()
    var c = h.client()
    let r = c.get("/test/flash?m=" & queryEscape("<script>alert(1)</script>"))
    check r.contains("&lt;script&gt;alert(1)&lt;/script&gt;")
    check r.notContains("<script>alert(1)")
    let i = r.body.find("alert-info")
    let j = r.body.find("alert-success")
    check i >= 0 and j >= 0 and i < j
    check c.get("/test/flash?m=x2").notContains("&lt;script")

  test "flash survives a redirect":
    let h = newHarness()
    var c = h.client()
    check c.get("/test/flash-redirect").status == 302
    check c.get("/login").contains("保存しました。")
    check c.get("/login").notContains("保存しました。")

  test "tampered flash cookie is ignored":
    let h = newHarness()
    var c = h.client()
    c.jar["flash"] = "eyJjIjoiZGFuZ2VyIn0.xxxx"
    let r = c.get("/login")
    check r.status == 200
    check r.notContains("alert-danger")

# ---- エラーページと共通動作 -------------------------------------------------------------------------------------------

suite "error pages":
  test "error pages use the Flask messages":
    let h = newHarness()
    var c = h.client()
    let r = c.get("/no-such-page") # 未ログインでも 404 (ログイン画面へは移動しない)
    check r.status == 404
    check r.contains("ページが見つかりません。")
    c.mustLogin("admin")
    let r2 = c.get("/change-me-not-found")
    check r2.status == 404
    check r2.contains("ページが見つかりません。")
    check r2.contains("href=\"/admin/users\"") # エラーページにも、通常のナビが付く

  test "panic becomes 500 without leaking details":
    let h = newHarness()
    var c = h.client()
    let r = c.get("/test/panic")
    check r.status == 500
    check r.contains("エラーが起きました。管理者に連絡してください。")
    check r.notContains("secret-internal-detail")
    check "secret-internal-detail" in logsText() # 詳細はログにだけ残る
    check c.get("/login").status == 200 # その後もサーバーは動き続ける

  test "busy database is 503 and other errors are 500":
    let h = newHarness()
    var c = h.client()
    let r = c.get("/test/busy")
    check r.status == 503 and r.respHeader("Retry-After") != ""
    check r.contains("ただいま混み合っています。数秒おいて、もう一度お試しください。")
    let r2 = c.get("/test/err")
    check r2.status == 500
    check r2.contains("エラーが起きました。")
    check r2.notContains("secret-detail")

  test "no-store for pages and redirects but not static":
    let h = newHarness()
    var c = h.client()
    for r in [c.get("/login"), c.get("/blank"), c.get("/nope")]:
      check r.respHeader("Cache-Control") == "no-store"
    check c.get("/static/app.css").respHeader("Cache-Control") != "no-store"

# ---- 静的ファイル -------------------------------------------------------------------------------------------------------

suite "static files":
  test "etag and not modified":
    let h = newHarness()
    var c = h.client()
    let r = c.get("/static/app.css")
    check r.status == 200
    check r.respHeader("Content-Type").startsWith("text/css")
    let etag = r.respHeader("ETag")
    check etag != "" and r.respHeader("Cache-Control") == "no-cache"
    check not r.hasSetCookie
    var req = newRequest("GET", "/static/app.css")
    req.headers.add ("If-None-Match", etag)
    let r2 = c.doReq(req)
    check r2.status == 304 and r2.body == ""
    let js = c.get("/static/vendor/bootstrap.bundle.min.js")
    check js.status == 200 and "javascript" in js.respHeader("Content-Type")

  test "missing and dot-segment paths are 404":
    let h = newHarness()
    var c = h.client()
    for p in ["/static/missing.css", "/static/../go.mod",
              "/static/%2e%2e/templates/base.html", "/static/",
              "/static/./app.css", "/static/%2e/app.css"]:
      check c.get(p).status == 404
    check c.get("/static/missing.css").contains("ページが見つかりません。")

  test "pages reference existing static files":
    let h = newHarness()
    var c = h.client()
    let body = c.get("/login").body
    for p in ["/static/vendor/bootstrap.min.css", "/static/app.css",
              "/static/vendor/bootstrap.bundle.min.js", "/static/app.js"]:
      check p in body
      check c.get(p).status == 200

# ---- DB が未作成・古い・他の版のとき (503) ---------------------------------------------------------------------------------

suite "schema gate":
  test "missing database gives 503 and creates nothing":
    let dir = createTempDir("tweb", "")
    let path = dir / "nope.db"
    let h = newHarnessAt(path)
    var c = h.client()
    let r = c.get("/login")
    check r.status == 503 and r.respHeader("Retry-After") == "60"
    check r.contains("データベースの更新が必要です")
    check r.contains("管理者に連絡してください。")
    check r.respHeader("Cache-Control") == "no-store"
    check c.post("/login", @[("username", "a")]).status == 503 # CSRF エラーではなく案内
    check c.get("/static/app.css").status == 200 # 静的ファイルは配れる
    check not fileExists(path) # リクエストで DB が作られていない
    check logsText().count("DBが未作成か") == 1 # 警告は1回だけ

  test "outdated database recovers without restart":
    let dir = createTempDir("tweb", "")
    let path = dir / "old.db"
    let conn = openDb(path)
    execSql(conn, Migrations[0])
    execSql(conn, "PRAGMA user_version=1")
    let h = newHarnessAt(path)
    var c = h.client()
    check c.get("/login").status == 503
    discard migrate(conn) # 別のプロセスで init-db を実行した状態
    conn.close()
    check c.get("/login").status == 200 # 再起動なしで復旧

  test "SQLAlchemy-made database gives 503 with an explanation":
    let dir = createTempDir("tweb", "")
    let path = dir / "sa.db"
    let conn = openDb(path)
    execSql(conn, readFile(SqlAlchemySql))
    execSql(conn, "INSERT INTO alembic_version VALUES ('afd0c4cd0c7c')")
    let h = newHarnessAt(path)
    var c = h.client()
    let r = c.get("/login")
    check r.status == 503
    check r.contains("SQLAlchemy")
    check conn.getValue(SqlQuery("PRAGMA user_version")) == "0" # 他版の DB を書き換えていない
    conn.close()

  test "unreadable database file gives 503 and is left alone":
    let dir = createTempDir("tweb", "")
    let path = dir / "garbage.db"
    let content = repeat("not a database ", 500)
    writeFile(path, content)
    let h = newHarnessAt(path)
    var c = h.client()
    let r = c.get("/login")
    check r.status == 503
    check r.contains("DBファイルを開けません")
    check readFile(path) == content

  test "newApp requires a secret key":
    expect ValueError:
      discard newApp(WebConfig(databasePath: "x", secretKey: ""))

# ---- 設定 (config.nim) --------------------------------------------------------------------------------------------------------

suite "config":
  test "secret key is generated, persisted with 0600, and reused":
    let dir = createTempDir("tweb", "")
    let inst = dir / "instance"
    let k1 = loadSecretKey(inst)
    check k1.len == 64
    let path = inst / "secret_key"
    check fileExists(path)
    check getFilePermissions(path) == {fpUserRead, fpUserWrite}
    check loadSecretKey(inst) == k1 # 2回目は同じ鍵

  test "secret key from env wins and no file is created":
    let dir = createTempDir("tweb", "")
    putEnv("INVENTORY_SECRET_KEY", "from-env")
    try:
      check loadSecretKey(dir / "instance") == "from-env"
      check not fileExists(dir / "instance" / "secret_key")
    finally:
      delEnv("INVENTORY_SECRET_KEY")

  test "resolveConfig applies env and defaults":
    let dir = createTempDir("tweb", "")
    putEnv("INVENTORY_SECRET_KEY", "k")
    try:
      let c1 = resolveConfig(dir)
      check c1.dbPath == dir / "instance" / "inventory.db"
      check c1.instanceDir == dir / "instance"
      check c1.secretKey == "k"
      check not c1.cookieSecure
      putEnv("INVENTORY_DATABASE", dir / "elsewhere.db")
      putEnv("INVENTORY_COOKIE_SECURE", "1")
      let c2 = resolveConfig(dir)
      check c2.dbPath == dir / "elsewhere.db"
      check c2.cookieSecure
    finally:
      delEnv("INVENTORY_SECRET_KEY")
      delEnv("INVENTORY_DATABASE")
      delEnv("INVENTORY_COOKIE_SECURE")
