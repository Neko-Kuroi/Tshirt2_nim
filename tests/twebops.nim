## 書き込み系画面のテスト (手順4-2)。Go 版 internal/web の
## handlers_ops_test.go (入荷・プリント変換・出荷/調整・備考) の移植。
## ソケットは開かず、webcore.handle を直接呼ぶ。
##
## Go 版に rows_json / product_rows のような動的行プロトコルは無く、
## フォームは1行単位 (対象の選択は /move の target 1件) なので、
## テストもその形に合わせている。
##
## テストユーザーのパスワードハッシュは tweb と同じ pbkdf2 の固定ベクトル
## (検証が速いため)。

import std/[os, strutils, tables, tempfiles, times, unittest]

import db
import migrations
import webcore
import webread
import webops

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

proc seedOps(h: Harness) =
  ## Go 版 seedOps: カテゴリー1「Tシャツ」(色・サイズ・種類名なし・プリント可)、
  ## カテゴリー2「バッジ」(種類名のみ)。品番3は使用停止中の品番。
  execSql(h.conn, """INSERT INTO category (id, name, sort_order, uses_color, uses_size, uses_variant_name, is_printable)
    VALUES (1, 'Tシャツ', 1, 1, 1, 0, 1), (2, 'バッジ', 2, 0, 0, 1, 0)""")
  execSql(h.conn, """INSERT INTO item (id, category_id, brand, item_no, name, style)
    VALUES (1, 1, 'Printstar', '085-CVT', 'Tシャツ', ''),
           (2, 2, '', '44mm', '缶バッジ', ''),
           (3, 1, 'OldBrand', '000', '旧品番', '')""")
  execSql(h.conn, "UPDATE item SET is_active = 0 WHERE id = 3")

proc seedVariant(h: Harness, qty: int64) =
  ## 品番1 (Printstar) の「ホワイト / M」を quantity 付きで作る (id=1)。
  execSql(h.conn, "INSERT INTO variant (id, item_id, color, size, variant_name, quantity) " &
    "VALUES (1, 1, 'ホワイト', 'M', '', " & $qty & ")")

proc newHarness(): Harness =
  clockOffset = 0
  logLines = @[]
  result.dir = createTempDir("twebops", "")
  result.dbPath = result.dir / "inventory.db"
  result.conn = openDb(result.dbPath)
  discard migrate(result.conn)
  seedUsers(result.conn)
  result.app = newApp(WebConfig(databasePath: result.dbPath,
                                secretKey: "test-secret-key",
                                now: testNow, log: testLog))
  result.app.registerReadRoutes()
  result.app.registerOpsRoutes()
  result.seedOps()

# ---- クライアント (Cookie Jar つき。twebread と同じ形) ------------------------------

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

# ---- DB の直接確認 -----------------------------------------------------------------

proc scalar(h: Harness, q: string): int64 =
  parseBiggestInt(h.conn.getValue(SqlQuery(q)))

proc variantQty(h: Harness, id: int64): int64 =
  h.scalar("SELECT quantity FROM variant WHERE id = " & $id)

proc newOpsClient(h: Harness): Client =
  result = h.client()
  result.mustLogin("staff")

# ---- 入荷 --------------------------------------------------------------------------------

suite "receive":
  test "creates variant and stock, then accumulates":
    let h = newHarness()
    var c = newOpsClient(h)
    let r = c.postCSRF("/receive", "/receive", @[
      ("item_id", "1"), ("color", "ホワイト"), ("size", "M"),
      ("qty", "10"), ("note", "納品書1")])
    check r.status == 302
    check r.location == "/receive?item_id=1"
    let page = c.get(r.location)
    # Go 版は html/template が '+' を &#43; にするが、mustache はそのまま出す (表示は同じ)
    check page.contains("入荷を登録しました: Printstar 085-CVT Tシャツ | ホワイト / M +10")
    check page.contains("alert-success")
    check h.variantQty(1) == 10
    check h.scalar("SELECT COUNT(*) FROM stock_movement WHERE kind = 'receive' AND delta = 10") == 1
    check h.scalar("SELECT COUNT(*) FROM stock_movement WHERE note = '納品書1'") == 1

    # 同じ色・サイズでもう一度入荷すると、同じ variant に積み上がる
    let r2 = c.postCSRF("/receive", "/receive", @[
      ("item_id", "1"), ("color", "ホワイト"), ("size", "M"), ("qty", "5")])
    check r2.status == 302
    check h.variantQty(1) == 15
    check h.scalar("SELECT COUNT(*) FROM variant") == 1

  test "validation keeps the form and rolls back":
    let h = newHarness()
    var c = newOpsClient(h)

    let r = c.postCSRF("/receive", "/receive", @[("qty", "5")])
    check r.status == 200 # 再表示
    check r.contains("品番を選んでください。")
    check r.contains("alert-danger")

    let r2 = c.postCSRF("/receive", "/receive", @[
      ("item_id", "1"), ("size", "M"), ("qty", "5")])
    check r2.contains("色を入力してください。")
    check r2.contains("""value="M"""") # 送信値が保持されている

    let r3 = c.postCSRF("/receive", "/receive", @[
      ("item_id", "1"), ("color", "ホワイト"), ("size", "M"), ("qty", "abc")])
    check r3.contains("数量は1以上の整数で入力してください。")

    let r4 = c.postCSRF("/receive", "/receive", @[
      ("item_id", "1"), ("color", "ホワイト"), ("size", "M"), ("qty", "0")])
    check r4.contains("数量は1以上の整数で入力してください。")

    # 存在しない品番 ID も「選んでください」
    let r5 = c.postCSRF("/receive", "/receive", @[
      ("item_id", "999"), ("color", "ホワイト"), ("size", "M"), ("qty", "5")])
    check r5.contains("品番を選んでください。")

    # 使用停止中の品番には入荷できない
    let r6 = c.postCSRF("/receive", "/receive", @[
      ("item_id", "3"), ("color", "ホワイト"), ("size", "M"), ("qty", "5")])
    check r6.contains("この品番は使用停止中のため、入荷できません。")

    check h.scalar("SELECT COUNT(*) FROM variant") == 0 # 失敗した入荷では variant も残らない
    check h.scalar("SELECT COUNT(*) FROM stock_movement") == 0

  test "badge category uses variant name only":
    let h = newHarness()
    var c = newOpsClient(h)
    let r = c.postCSRF("/receive", "/receive", @[
      ("item_id", "2"), ("variant_name", "丸型"), ("qty", "7")])
    check r.status == 302
    check r.location == "/receive?item_id=2"
    check h.scalar("SELECT quantity FROM variant WHERE item_id = 2 AND variant_name = '丸型'") == 7
    # 種類名が空なら検証で落ちる (色・サイズは使わないので要求されない)
    let r2 = c.postCSRF("/receive", "/receive", @[("item_id", "2"), ("qty", "7")])
    check r2.contains("種類名を入力してください。")

  test "receive page shows open notes of the selected item":
    let h = newHarness()
    execSql(h.conn, "INSERT INTO item_note (item_id, target, body, is_resolved, user_id) " &
      "VALUES (1, 'ホワイト', '在庫わずか', 0, 1)")
    var c = newOpsClient(h)
    let r = c.get("/receive?item_id=1")
    check r.status == 200
    check r.contains("この品番の備考(未対応)")
    check r.contains("在庫わずか")
    check r.contains("""action="/notes/1/resolve"""")
    let r2 = c.get("/receive") # 品番未選択では出ない
    check r2.notContains("在庫わずか")

# ---- プリント変換 ---------------------------------------------------------------------------

suite "convert":
  test "convert flow with new and existing designs":
    let h = newHarness()
    h.seedVariant(10)
    var c = newOpsClient(h)

    let r = c.postCSRF("/convert", "/convert", @[
      ("variant_id", "1"), ("design_new", " ロゴ "), ("used", "4"), ("output", "3")])
    check r.status == 302
    check r.location == "/convert"
    check c.get("/convert").contains(
      "プリント変換しました: ロゴ / Printstar 085-CVT Tシャツ | ホワイト / M (使用 4 → 完成 3)")
    check h.variantQty(1) == 6
    check h.scalar("SELECT quantity FROM printed_product") == 3
    check h.scalar("SELECT COUNT(*) FROM stock_movement WHERE kind = 'print_use' AND delta = -4") == 1
    check h.scalar("SELECT COUNT(*) FROM stock_movement WHERE kind = 'print_output' AND delta = 3") == 1

    # 既存デザインは select から選ぶ (design_new が空なら design が使われる)
    let r2 = c.postCSRF("/convert", "/convert", @[
      ("variant_id", "1"), ("design", "ロゴ"), ("used", "1"), ("output", "1")])
    check r2.status == 302
    check h.scalar("SELECT quantity FROM printed_product") == 4
    check h.scalar("SELECT COUNT(*) FROM design") == 1

  test "convert validation":
    let h = newHarness()
    h.seedVariant(10)
    var c = newOpsClient(h)

    let r = c.postCSRF("/convert", "/convert", @[
      ("used", "1"), ("output", "1"), ("design_new", "x")])
    check r.contains("無地在庫を選んでください。")

    let r2 = c.postCSRF("/convert", "/convert", @[
      ("variant_id", "1"), ("design_new", "ロゴ"), ("used", "4"), ("output", "x")])
    check r2.contains("完成数は0以上の整数で入力してください。")

    let r3 = c.postCSRF("/convert", "/convert", @[
      ("variant_id", "1"), ("design_new", "ロゴ"), ("used", "0"), ("output", "0")])
    check r3.contains("使用数は1以上の整数で入力してください。")

    # 完成数が使用数を超える (上限チェック)
    let r4 = c.postCSRF("/convert", "/convert", @[
      ("variant_id", "1"), ("design_new", "ロゴ"), ("used", "2"), ("output", "3")])
    check r4.contains("完成数が使用数を超えています。")

    let r5 = c.postCSRF("/convert", "/convert", @[
      ("variant_id", "1"), ("design_new", "ロゴ"), ("used", "99"), ("output", "1")])
    check r5.contains("在庫が足りません。")
    check h.variantQty(1) == 10 # 失敗で減らない
    check h.scalar("SELECT COUNT(*) FROM printed_product") == 0
    check h.scalar("SELECT COUNT(*) FROM design") == 0 # デザインも残らない

# ---- 出荷・棚卸し調整 -------------------------------------------------------------------------

suite "move":
  test "ship and adjust":
    let h = newHarness()
    h.seedVariant(10)
    var c = newOpsClient(h)

    let r = c.postCSRF("/move", "/move", @[
      ("kind", "ship"), ("target", "v:1"), ("qty", "3")])
    check r.status == 302
    check r.location == "/move"
    check c.get("/move").contains(
      "出荷を登録しました: Printstar 085-CVT Tシャツ | ホワイト / M (-3)")
    check h.variantQty(1) == 7
    check h.scalar("SELECT COUNT(*) FROM stock_movement WHERE kind = 'ship' AND delta = -3") == 1

    let r2 = c.postCSRF("/move", "/move", @[
      ("kind", "adjust"), ("target", "v:1"), ("qty", "-2"), ("note", "棚卸しで不足")])
    check r2.status == 302
    check c.get("/move").contains(
      "棚卸し調整を登録しました: Printstar 085-CVT Tシャツ | ホワイト / M (-2)")
    check h.variantQty(1) == 5

    let r3 = c.postCSRF("/move", "/move", @[
      ("kind", "adjust"), ("target", "v:1"), ("qty", "4"), ("note", "発見")])
    check r3.status == 302
    check c.get("/move").contains("(+4)")
    check h.variantQty(1) == 9

  test "ship a printed product":
    let h = newHarness()
    h.seedVariant(10)
    execSql(h.conn, "INSERT INTO design (id, name, note) VALUES (1, 'ロゴ', '')")
    execSql(h.conn, "INSERT INTO printed_product (id, design_id, variant_id, quantity) VALUES (1, 1, 1, 4)")
    var c = newOpsClient(h)
    let r = c.postCSRF("/move", "/move", @[
      ("kind", "ship"), ("target", "p:1"), ("qty", "2")])
    check r.status == 302
    check c.get("/move").contains("出荷を登録しました: ロゴ | Printstar 085-CVT Tシャツ | ホワイト / M (-2)")
    check h.scalar("SELECT quantity FROM printed_product WHERE id = 1") == 2
    check h.variantQty(1) == 10 # 無地は減らない
    check h.scalar("SELECT COUNT(*) FROM stock_movement WHERE kind = 'ship' AND printed_product_id = 1 AND delta = -2") == 1

  test "move validation":
    let h = newHarness()
    h.seedVariant(10)
    var c = newOpsClient(h)

    let r = c.postCSRF("/move", "/move", @[("kind", "ship"), ("qty", "1")])
    check r.contains("対象の在庫を選んでください。")

    # 存在しない対象・解釈できない対象も同じ
    let r1 = c.postCSRF("/move", "/move", @[
      ("kind", "ship"), ("target", "v:999"), ("qty", "1")])
    check r1.contains("対象の在庫を選んでください。")
    let r1b = c.postCSRF("/move", "/move", @[
      ("kind", "ship"), ("target", "xyz"), ("qty", "1")])
    check r1b.contains("対象の在庫を選んでください。")

    let r2 = c.postCSRF("/move", "/move", @[
      ("kind", "x"), ("target", "v:1"), ("qty", "1")])
    check r2.contains("操作の種類を選んでください。")

    let r3 = c.postCSRF("/move", "/move", @[
      ("kind", "adjust"), ("target", "v:1"), ("qty", "1")])
    check r3.contains("棚卸し調整には理由を入力してください。")

    let r4 = c.postCSRF("/move", "/move", @[
      ("kind", "adjust"), ("target", "v:1"), ("qty", "0"), ("note", "理由")])
    check r4.contains("増減数は0以外の整数で入力してください。")

    let r5 = c.postCSRF("/move", "/move", @[
      ("kind", "ship"), ("target", "v:1"), ("qty", "999")])
    check r5.contains("在庫が足りません。")

    let r6 = c.postCSRF("/move", "/move", @[
      ("kind", "ship"), ("target", "v:1"), ("qty", "0")])
    check r6.contains("数量は1以上の整数で入力してください。")

    check h.variantQty(1) == 10 # 失敗で変わらない
    check h.scalar("SELECT COUNT(*) FROM stock_movement") == 0

# ---- 備考 --------------------------------------------------------------------------------------

suite "notes":
  test "add, resolve and delete":
    let h = newHarness()
    var c = newOpsClient(h)

    let r = c.postCSRF("/notes", "/notes", @[
      ("item_id", "1"), ("target", "ホワイト"), ("body", "在庫わずか"), ("back", "/notes")])
    check r.status == 302
    check r.location == "/notes"
    let page = c.get("/notes")
    check page.contains("備考を追加しました。")
    check page.contains("在庫わずか")
    check page.contains("ホワイト")
    check page.contains("staff") # 記録したユーザー名
    let noteId = h.scalar("SELECT id FROM item_note")
    check noteId > 0
    # 行の形 (webread の note_list と同じ部品)
    check page.contains("""action="/notes/""" & $noteId & """/resolve"""")
    check page.notContains("""action="/notes/""" & $noteId & """/delete"""") # スタッフには出ない

    # 対応済みにすると未対応の一覧から消え、all=1 で見える
    let r2 = c.postCSRF("/notes", "/notes/" & $noteId & "/resolve", @[("back", "/notes")])
    check r2.status == 302
    check c.get("/notes").notContains("在庫わずか")
    let done = c.get("/notes?all=1")
    check done.contains("在庫わずか")
    check done.contains("対応済み")

    # もう一度切り替えると未対応に戻る
    let r2b = c.postCSRF("/notes", "/notes/" & $noteId & "/resolve", @[("back", "/notes")])
    check r2b.status == 302
    check c.get("/notes").contains("在庫わずか")

    # スタッフは削除できない (存在確認より先に 403)
    let r3 = c.postCSRF("/notes", "/notes/" & $noteId & "/delete", @[("back", "/notes")])
    check r3.status == 403
    check r3.contains("この操作をする権限がありません。")
    check h.scalar("SELECT COUNT(*) FROM item_note") == 1

    # 無い備考・整数でない ID は 404
    check c.postCSRF("/notes", "/notes/999/resolve", @[]).status == 404
    check c.postCSRF("/notes", "/notes/abc/resolve", @[]).status == 404
    check c.postCSRF("/notes", "/notes/999/delete", @[]).status == 403 # スタッフは ID 以前に 403

    var admin = h.client()
    admin.mustLogin("admin")
    check admin.postCSRF("/notes", "/notes/999/delete", @[]).status == 404
    check admin.postCSRF("/notes", "/notes/abc/delete", @[]).status == 404
    let page2 = admin.get("/notes")
    check page2.contains("""action="/notes/""" & $noteId & """/delete"""") # 管理者には出る
    let r4 = admin.postCSRF("/notes", "/notes/" & $noteId & "/delete", @[("back", "/notes")])
    check r4.status == 302
    check admin.get("/notes").contains("備考を削除しました。")
    check h.scalar("SELECT COUNT(*) FROM item_note") == 0

  test "note add validation":
    let h = newHarness()
    var c = newOpsClient(h)

    let r = c.postCSRF("/notes", "/notes", @[
      ("item_id", "999"), ("body", "x"), ("back", "/notes")])
    check r.status == 302
    check c.get("/notes").contains("品番が見つかりません。")

    discard c.postCSRF("/notes", "/notes", @[
      ("item_id", "1"), ("body", ""), ("back", "/notes")])
    check c.get("/notes").contains("備考の内容を入力してください。")

    # 空白だけの本文も、strip されて空として扱われる
    discard c.postCSRF("/notes", "/notes", @[
      ("item_id", "1"), ("body", "　"), ("back", "/notes")])
    check c.get("/notes").contains("備考の内容を入力してください。")

    discard c.postCSRF("/notes", "/notes", @[
      ("item_id", "1"), ("body", repeat("あ", 1001)), ("back", "/notes")])
    check c.get("/notes").contains("備考は1000文字まで、対象は64文字までです。")

    discard c.postCSRF("/notes", "/notes", @[
      ("item_id", "1"), ("target", repeat("あ", 65)), ("body", "x"), ("back", "/notes")])
    check c.get("/notes").contains("備考は1000文字まで、対象は64文字までです。")

    check h.scalar("SELECT COUNT(*) FROM item_note") == 0

    # ちょうど上限 (1000文字・64文字) は通る
    let ok = c.postCSRF("/notes", "/notes", @[
      ("item_id", "1"), ("target", repeat("あ", 64)), ("body", repeat("あ", 1000)),
      ("back", "/notes")])
    check ok.status == 302
    check h.scalar("SELECT COUNT(*) FROM item_note") == 1

  test "back parameter rules":
    let h = newHarness()
    var c = newOpsClient(h)
    # サイト内のパスはそのまま戻る
    let r = c.postCSRF("/notes", "/notes", @[
      ("item_id", "1"), ("body", "x"), ("back", "/blank?category=1")])
    check r.status == 302
    check r.location == "/blank?category=1"
    # 外部 URL や指定なしは /notes に寄せる
    let r2 = c.postCSRF("/notes", "/notes", @[
      ("item_id", "1"), ("body", "x"), ("back", "https://evil.example/")])
    check r2.location == "/notes"
    let r3 = c.postCSRF("/notes", "/notes", @[("item_id", "1"), ("body", "x")])
    check r3.location == "/notes"
    let r4 = c.postCSRF("/notes", "/notes", @[
      ("item_id", "1"), ("body", "x"), ("back", "//evil.example")])
    check r4.location == "/notes"

# ---- ガード ---------------------------------------------------------------------------------------

suite "guards":
  test "ops pages require login":
    let h = newHarness()
    var c = h.client()
    for p in ["/receive", "/convert", "/move"]:
      let r = c.get(p)
      check r.status == 302
      check r.location.startsWith("/login")
    # POST /notes も未ログインではログイン画面へ (CSRF 用トークンはログイン画面から取る)
    let tok = c.csrfToken("/login")
    let r = c.post("/notes", @[
      ("item_id", "1"), ("body", "x"), ("csrf_token", tok)])
    check r.status == 302
    check r.location.startsWith("/login")
    check h.scalar("SELECT COUNT(*) FROM item_note") == 0
