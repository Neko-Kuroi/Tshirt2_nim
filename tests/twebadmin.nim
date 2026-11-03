## 管理画面のテスト (手順4-3)。Go 版 internal/web の
## handlers_admin_test.go の移植。ソケットは開かず、webcore.handle を直接呼ぶ。
##
## テストユーザーのパスワードハッシュは tweb / twebops と同じ pbkdf2 の
## 固定ベクトル (検証が速いため)。ユーザー追加・パスワード再設定は本物の
## hashPassword (scrypt) を通る。

import std/[os, strutils, tables, tempfiles, times, unittest]

import db
import migrations
import webcore
import webadmin

const TestPassword = "password123"
const TestHash = "pbkdf2:sha256:1000$tweb-salt-0123$" &
  "484524fc3353e4eec1937452b3e2756506e7ce7f8b16732b655b7ba3ecc32bea"

var clockOffset {.threadvar.}: int64
var logLines {.threadvar.}: seq[string]

proc testNow(): int64 {.gcsafe.} =
  epochTime().int64 + clockOffset

proc testLog(msg: string) {.gcsafe.} =
  logLines.add msg

type Harness = object
  app: App
  dir: string
  dbPath: string
  conn: DbConn # テストが直接 DB を操作する (サーバーとは別の接続)

proc seedUsers(conn: DbConn) =
  execSql(conn, "INSERT INTO \"user\" (username, password_hash, role) VALUES " &
    "('admin', '" & TestHash & "', 'admin'), ('staff', '" & TestHash & "', 'staff')")

proc newHarness(): Harness =
  clockOffset = 0
  logLines = @[]
  result.dir = createTempDir("twebadmin", "")
  result.dbPath = result.dir / "inventory.db"
  result.conn = openDb(result.dbPath)
  discard migrate(result.conn)
  seedUsers(result.conn)
  result.app = newApp(WebConfig(databasePath: result.dbPath,
                                secretKey: "test-secret-key",
                                now: testNow, log: testLog))
  result.app.registerAdminRoutes()

# ---- クライアント (Cookie Jar つき。twebops と同じ形) ------------------------------

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
  result = ""
  for i, (k, v) in form:
    if i > 0:
      result.add "&"
    result.add queryEscape(k) & "=" & queryEscape(v)

proc post(c: var Client, target: string, form: seq[(string, string)]): Response =
  var req = newRequest("POST", target)
  req.headers.add ("Content-Type", "application/x-www-form-urlencoded")
  req.body = encodeForm(form)
  c.doReq(req)

proc respHeader(r: Response, name: string): string = headerGet(r.headers, name)
proc location(r: Response): string = r.respHeader("Location")

proc csrfToken(c: var Client, page: string): string =
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

proc login(c: var Client, user, pw: string): Response =
  let tok = c.csrfToken("/login")
  c.post("/login", @[("username", user), ("password", pw), ("csrf_token", tok)])

proc mustLogin(c: var Client, user: string) =
  let r = c.login(user, TestPassword)
  doAssert r.status == 302 and r.location == "/",
    "login failed: " & $r.status & " " & r.location

proc contains(r: Response, want: string): bool = want in r.body
proc notContains(r: Response, bad: string): bool = bad notin r.body

proc newAdminClient(h: Harness): Client =
  result = h.client()
  result.mustLogin("admin")

# ---- DB の直接確認 -----------------------------------------------------------------

proc scalar(h: Harness, q: string): int64 =
  parseBiggestInt(h.conn.getValue(SqlQuery(q)))

proc scalarStr(h: Harness, q: string): string =
  h.conn.getValue(SqlQuery(q))

# ---- カテゴリー ------------------------------------------------------

suite "admin categories":
  test "create and edit":
    let h = newHarness()
    var c = h.newAdminClient()

    # 追加 → 一覧へ戻り、成功メッセージと行が出る
    var r = c.postCSRF("/admin/categories", "/admin/categories", @[
      ("name", "ステッカー"), ("uses_color", "on"), ("is_printable", "on")])
    check r.status == 302 and r.location == "/admin/categories"
    # チェックボックス: on のものだけ 1 (uses_size / uses_variant_name は未送信 = off)
    check h.scalar("SELECT uses_color FROM category WHERE name = 'ステッカー'") == 1
    check h.scalar("SELECT is_printable FROM category WHERE name = 'ステッカー'") == 1
    check h.scalar("SELECT uses_size FROM category WHERE name = 'ステッカー'") == 0
    check h.scalar("SELECT uses_variant_name FROM category WHERE name = 'ステッカー'") == 0
    r = c.get("/admin/categories")
    check r.contains("カテゴリーを追加しました: ステッカー")
    check r.contains("ステッカー")

    # 名前が空 → エラー表示で出し直し (302 しない)
    r = c.postCSRF("/admin/categories", "/admin/categories", @[("name", "  ")])
    check r.status == 200
    check r.contains("カテゴリー名を入力してください。")

    # 同名 → 重複エラー
    r = c.postCSRF("/admin/categories", "/admin/categories", @[("name", "ステッカー")])
    check r.status == 200
    check r.contains("同名のカテゴリーが既にあります。")

    # 編集: 表示順が整数でない → エラー。正常なら保存される
    let cid = h.scalar("SELECT id FROM category WHERE name = 'ステッカー'")
    r = c.get("/admin/categories/" & $cid)
    check r.status == 200
    check r.contains("カテゴリー編集: ステッカー")
    let editPage = "/admin/categories/" & $cid
    r = c.postCSRF(editPage, editPage, @[("name", "ステッカー"), ("sort_order", "abc")])
    check r.status == 200
    check r.contains("表示順は整数で入力してください。")
    r = c.postCSRF(editPage, editPage, @[
      ("name", "シール"), ("sort_order", "7"), ("uses_color", "on")])
    check r.status == 302 and r.location == "/admin/categories"
    check h.scalar("SELECT sort_order FROM category WHERE id = " & $cid) == 7
    # 編集でも、送らなかったチェックボックスは off になる
    check h.scalar("SELECT is_printable FROM category WHERE id = " & $cid) == 0
    r = c.get("/admin/categories")
    check r.contains("カテゴリーを更新しました。")
    check r.contains("シール")

    # 無いカテゴリーは 404 で、Flask 版の文言
    r = c.get("/admin/categories/999")
    check r.status == 404
    check r.contains("カテゴリーが見つかりません。")

    # 数字でない ID はルートに無いものとして扱う
    r = c.get("/admin/categories/abc")
    check r.status == 404
    check r.contains("ページが見つかりません。")

  test "flag in use cannot be turned off":
    let h = newHarness()
    var c = h.newAdminClient()

    var r = c.postCSRF("/admin/categories", "/admin/categories", @[
      ("name", "テスト"), ("uses_color", "on")])
    check r.status == 302
    let cid = h.scalar("SELECT id FROM category WHERE name = 'テスト'")
    # そのカテゴリーの品番に、色つきの在庫を登録する
    execSql(h.conn, "INSERT INTO item (category_id, brand, item_no, name) " &
      "VALUES (" & $cid & ", 'B社', '1', '')")
    let iid = h.scalar("SELECT id FROM item WHERE category_id = " & $cid)
    execSql(h.conn, "INSERT INTO variant (item_id, color, size, variant_name, quantity) " &
      "VALUES (" & $iid & ", '赤', '', '', 1)")

    # 色を OFF にして保存 → 在庫があるので拒否され、設定は変わらない
    let editPage = "/admin/categories/" & $cid
    r = c.postCSRF(editPage, editPage, @[("name", "テスト"), ("sort_order", "0")])
    check r.status == 200
    check r.contains("「色」は、既に在庫登録があるためOFFにできません。")
    check h.scalar("SELECT uses_color FROM category WHERE id = " & $cid) == 1

# ---- 品番 ------------------------------------------------------------

suite "admin items":
  test "create and edit":
    let h = newHarness()
    var c = h.newAdminClient()
    execSql(h.conn, "INSERT INTO category (name, sort_order, uses_color, uses_size, uses_variant_name, is_printable) " &
      "VALUES ('Tシャツ', 0, 1, 1, 0, 1)")

    # 一覧 (まだ品番なし) の空表示
    var r = c.get("/admin/items")
    check r.status == 200
    check r.contains("まだ品番がありません。下のフォームから追加してください。")

    # カテゴリー未選択 → エラー
    r = c.postCSRF("/admin/items", "/admin/items", @[("brand", "B社")])
    check r.status == 200
    check r.contains("カテゴリーを選んでください。")

    # ブランド・品番が両方空 → エラー
    r = c.postCSRF("/admin/items", "/admin/items", @[("category_id", "1"), ("name", "x")])
    check r.contains("ブランドか品番のどちらかは入力してください。")

    # 追加 → そのカテゴリーの一覧へ
    r = c.postCSRF("/admin/items", "/admin/items", @[
      ("category_id", "1"), ("brand", "Printstar"), ("item_no", "085-CVT"),
      ("name", "ヘビーウェイト"), ("style", "半袖")])
    check r.status == 302 and r.location == "/admin/items?category=1"
    r = c.get("/admin/items?category=1")
    check r.contains("品番を追加しました。")
    check r.contains("Printstar")
    check r.contains("085-CVT")
    check r.notContains("まだ品番がありません")

    # 重複 → エラー
    r = c.postCSRF("/admin/items", "/admin/items", @[
      ("category_id", "1"), ("brand", "Printstar"), ("item_no", "085-CVT")])
    check r.status == 200
    check r.contains("同じカテゴリーに同じブランド・品番が既にあります。")

    # 編集: 使用停止にして保存 → 一覧で (停止中) と出る
    # (is_active を送らない = チェックを外したのと同じ)
    let iid = h.scalar("SELECT id FROM item WHERE brand = 'Printstar'")
    let editPage = "/admin/items/" & $iid
    r = c.postCSRF(editPage, editPage, @[
      ("brand", "Printstar"), ("item_no", "085-CVT"),
      ("name", "ヘビーウェイト"), ("style", "長袖")])
    check r.status == 302 and r.location == "/admin/items?category=1"
    r = c.get("/admin/items?category=1")
    check r.contains("品番を更新しました。")
    check r.contains("(停止中)")
    check h.scalar("SELECT is_active FROM item WHERE id = " & $iid) == 0
    check h.scalarStr("SELECT style FROM item WHERE id = " & $iid) == "長袖"

    # is_active を送れば使用中に戻る
    r = c.postCSRF(editPage, editPage, @[
      ("brand", "Printstar"), ("item_no", "085-CVT"),
      ("name", "ヘビーウェイト"), ("style", "長袖"), ("is_active", "on")])
    check r.status == 302
    check h.scalar("SELECT is_active FROM item WHERE id = " & $iid) == 1

    # 無い品番は 404 で、Flask 版の文言
    r = c.get("/admin/items/999")
    check r.status == 404
    check r.contains("品番が見つかりません。")

# ---- ユーザー --------------------------------------------------------

suite "admin users":
  test "create":
    let h = newHarness()
    var c = h.newAdminClient()

    # 追加 → 一覧へ。作ったユーザーでログインできる
    var r = c.postCSRF("/admin/users", "/admin/users", @[
      ("username", "newbie"), ("password", "password999"), ("role", "staff")])
    check r.status == 302 and r.location == "/admin/users"
    r = c.get("/admin/users")
    check r.contains("ユーザーを追加しました: newbie")
    check r.contains("newbie")
    var nc = h.client()
    check nc.login("newbie", "password999").status == 302

    # 行内のフォームにも CSRF トークンが入っている
    check r.notContains("name=\"csrf_token\" value=\"\"")
    check r.contains("/admin/users/")

    # 重複 → エラー
    r = c.postCSRF("/admin/users", "/admin/users", @[
      ("username", "newbie"), ("password", "password999")])
    check r.status == 200
    check r.contains("そのユーザー名は既に使われています。")

    # 短いパスワード / 空のユーザー名 → エラー
    r = c.postCSRF("/admin/users", "/admin/users", @[
      ("username", "shorty"), ("password", "short")])
    check r.contains("ユーザー名と、8文字以上のパスワードを入力してください。")
    r = c.postCSRF("/admin/users", "/admin/users", @[
      ("username", " "), ("password", "password999")])
    check r.contains("ユーザー名と、8文字以上のパスワードを入力してください。")
    check h.scalar("SELECT COUNT(*) FROM \"user\"") == 3 # admin, staff, newbie だけ

  test "toggle":
    let h = newHarness()
    var c = h.newAdminClient()
    let staffID = h.scalar("SELECT id FROM \"user\" WHERE username = 'staff'")
    let toggle = "/admin/users/" & $staffID & "/toggle"

    # 無効化 → メッセージが出て、staff はログインできなくなる
    var r = c.postCSRF("/admin/users", toggle, @[])
    check r.status == 302 and r.location == "/admin/users"
    r = c.get("/admin/users")
    check r.contains("staff を無効にしました。")
    check h.scalar("SELECT is_active FROM \"user\" WHERE id = " & $staffID) == 0
    var sc = h.client()
    check sc.login("staff", TestPassword).status == 200 # ログイン画面のまま

    # 有効化し直せる
    r = c.postCSRF("/admin/users", toggle, @[])
    check r.status == 302
    r = c.get("/admin/users")
    check r.contains("staff を有効にしました。")
    check h.scalar("SELECT is_active FROM \"user\" WHERE id = " & $staffID) == 1

    # 自分自身は無効化できない
    let adminID = h.scalar("SELECT id FROM \"user\" WHERE username = 'admin'")
    r = c.postCSRF("/admin/users", "/admin/users/" & $adminID & "/toggle", @[])
    check r.status == 302
    r = c.get("/admin/users")
    check r.contains("自分自身は無効化できません。")
    check h.scalar("SELECT is_active FROM \"user\" WHERE id = " & $adminID) == 1

    # 無いユーザーは 404 で、Flask 版の文言
    r = c.postCSRF("/admin/users", "/admin/users/999/toggle", @[])
    check r.status == 404
    check r.contains("ユーザーが見つかりません。")

  test "password reset":
    let h = newHarness()
    var c = h.newAdminClient()
    let staffID = h.scalar("SELECT id FROM \"user\" WHERE username = 'staff'")
    let pwPage = "/admin/users/" & $staffID & "/password"

    # 短いパスワード → エラー (リダイレクト先の一覧で表示)
    var r = c.postCSRF("/admin/users", pwPage, @[("password", "short")])
    check r.status == 302
    r = c.get("/admin/users")
    check r.contains("パスワードは8文字以上にしてください。")

    # 再設定 → 新しいパスワードでログインでき、古いパスワードは通らない
    r = c.postCSRF("/admin/users", pwPage, @[("password", "brand-new-pw")])
    check r.status == 302
    r = c.get("/admin/users")
    check r.contains("staff のパスワードを再設定しました。(その人は再ログインが必要になります)")
    var nc = h.client()
    check nc.login("staff", "brand-new-pw").status == 302
    var oc = h.client()
    check oc.login("staff", TestPassword).status == 200 # 失敗

    # 自分自身の再設定: セッションは入り直し扱いになり、そのまま使い続けられる
    let adminID = h.scalar("SELECT id FROM \"user\" WHERE username = 'admin'")
    r = c.postCSRF("/admin/users", "/admin/users/" & $adminID & "/password",
                   @[("password", "admin-new-pw")])
    check r.status == 302
    check c.get("/admin/users").status == 200 # セッション継続
    var ac = h.client()
    check ac.login("admin", "admin-new-pw").status == 302

    # 無いユーザーは 404
    r = c.postCSRF("/admin/users", "/admin/users/999/password",
                   @[("password", "password999")])
    check r.status == 404
    check r.contains("ユーザーが見つかりません。")

# ---- 権限 ------------------------------------------------------------

suite "admin guards":
  test "staff is denied and anon is redirected":
    let h = newHarness()
    var staff = h.client()
    staff.mustLogin("staff")
    for p in ["/admin/categories", "/admin/items", "/admin/users"]:
      let r = staff.get(p)
      check r.status == 403
      check r.contains("この操作をする権限がありません。")
    var r = staff.postCSRF("/", "/admin/users", @[
      ("username", "x"), ("password", "password999")])
    check r.status == 403
    check r.contains("この操作をする権限がありません。")
    check h.scalar("SELECT COUNT(*) FROM \"user\"") == 2
    # スタッフは toggle / password もできない
    let staffID = h.scalar("SELECT id FROM \"user\" WHERE username = 'staff'")
    r = staff.postCSRF("/", "/admin/users/" & $staffID & "/toggle", @[])
    check r.status == 403
    check h.scalar("SELECT is_active FROM \"user\" WHERE id = " & $staffID) == 1

    # 未ログインはログイン画面へ
    var anon = h.client()
    for p in ["/admin/categories", "/admin/items", "/admin/users",
              "/admin/categories/1", "/admin/items/1"]:
      let rr = anon.get(p)
      check rr.status == 302
      check rr.location.startsWith("/login")
