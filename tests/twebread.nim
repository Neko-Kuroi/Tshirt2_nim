## 読み取り系画面のテスト (手順4-1)。Go 版 internal/web の
## handlers_read_test.go と、handlers_ops_test.go の履歴・備考一覧・CSV の
## 読み取りぶんの移植。ソケットは開かず、webcore.handle を直接呼ぶ。
##
## テストユーザーのパスワードハッシュは tweb と同じ pbkdf2 の固定ベクトル
## (検証が速いため)。

import std/[json, options, os, strutils, tables, tempfiles, times, unittest]

import db
import migrations
import exportcsv
import webcore
import webread

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
  result.dir = createTempDir("twebread", "")
  result.dbPath = result.dir / "inventory.db"
  result.conn = openDb(result.dbPath)
  discard migrate(result.conn)
  seedUsers(result.conn)
  result.app = newApp(WebConfig(databasePath: result.dbPath,
                                secretKey: "test-secret-key",
                                now: testNow, log: testLog))
  result.app.registerReadRoutes()

# ---- クライアント (Cookie Jar つき。tweb と同じ形) --------------------------------

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

proc csrfToken(c: var Client, page = "/login"): string =
  let r = c.get(page)
  let marker = "name=\"csrf_token\" value=\""
  let i = r.body.find(marker)
  doAssert i >= 0, "no csrf token in page (status " & $r.status & ")"
  let start = i + marker.len
  r.body[start ..< r.body.find('"', start)]

proc login(c: var Client, user, pw: string): Response =
  let tok = c.csrfToken("/login")
  c.post("/login", @[("username", user), ("password", pw), ("csrf_token", tok)])

proc mustLogin(c: var Client, user: string) =
  let r = c.login(user, TestPassword)
  doAssert r.status == 302 and r.location == "/",
    "login failed: " & $r.status & " " & r.location

proc contains(r: Response, want: string): bool = want in r.body
proc notContains(r: Response, bad: string): bool = bad notin r.body

# ---- シード (Go 版 seedReadData の移植) ------------------------------------------
# カテゴリー1「Tシャツ」(色・サイズ・プリント可)、カテゴリー2「バッジ」(種類名のみ)。
# Tシャツ: 白 M=10 / L=2 (low)、黒 M=0 (zero) / L は行なし (– になる)。バッジ: 丸型=5。

proc seedReadData(h: Harness) =
  execSql(h.conn, """INSERT INTO category (id, name, sort_order, uses_color, uses_size, uses_variant_name, is_printable)
    VALUES (1, 'Tシャツ', 1, 1, 1, 0, 1), (2, 'バッジ', 2, 0, 0, 1, 0)""")
  execSql(h.conn, """INSERT INTO item (id, category_id, brand, item_no, name, style)
    VALUES (1, 1, 'Fruit', '001', 'ヘビーウェイトT', '半袖'), (2, 2, '', 'B1', '缶バッジ', '')""")
  execSql(h.conn, """INSERT INTO variant (item_id, color, size, variant_name, quantity) VALUES
    (1, '白', 'M', '', 10), (1, '白', 'L', '', 2), (1, '黒', 'M', '', 0), (2, '', '', '丸型', 5)""")
  execSql(h.conn, "INSERT INTO design (id, name) VALUES (1, 'ロゴA'), (2, 'ロゴB')")
  execSql(h.conn, """INSERT INTO printed_product (design_id, variant_id, quantity)
    SELECT 1, id, 4 FROM variant WHERE item_id = 1 AND color = '白' AND size = 'M'""")
  execSql(h.conn, """INSERT INTO printed_product (design_id, variant_id, quantity)
    SELECT 2, id, 3 FROM variant WHERE item_id = 1 AND color = '白' AND size = 'L'""")
  execSql(h.conn, """INSERT INTO item_note (item_id, target, body, is_resolved, user_id)
    VALUES (1, '白', '白は補充注意', 0, 1)""")
  execSql(h.conn, """INSERT INTO stock_movement (batch_id, kind, variant_id, delta, user_id, created_at)
    SELECT 'b1', 'receive', id, 10, 1, '2026-11-01 00:00:00'
    FROM variant WHERE item_id = 1 AND color = '白' AND size = 'M'""")

suite "dashboard":
  test "cards, note badge and recent movements":
    let h = newHarness()
    seedReadData(h)
    var c = h.client()
    c.mustLogin("admin")
    let r = c.get("/")
    check r.status == 200
    check r.contains("Tシャツ")
    check r.contains("""<div class="fs-3 num text-start">12</div>""") # 無地の合計 (10+2+0)
    check r.contains("""<div class="fs-5 num text-start">7</div>""")  # プリント済みの合計 (4+3)
    check r.contains("バッジ")
    check r.contains("""<div class="fs-3 num text-start">5</div>""")
    check r.contains("""<span class="badge text-bg-warning">1</span>""") # 未対応の備考の件数
    check r.contains("白は補充注意")
    check r.contains("11/01 09:00") # UTC 00:00 → JST
    check r.contains("入荷")
    check r.contains("Fruit 001 ヘビーウェイトT | 白 / M")
    # Go 版は html/template が '+' を &#43; にするが、mustache はそのまま出す (表示は同じ +10)
    check r.contains("""<span class="num delta-pos">+10</span>""")
    check r.contains("admin")

  test "remaining open notes are counted past the five shown":
    let h = newHarness()
    seedReadData(h)
    for i in 1 .. 6:
      execSql(h.conn, "INSERT INTO item_note (item_id, target, body, is_resolved, user_id) " &
        "VALUES (1, '', '追加の備考" & $i & "', 0, 1)")
    var c = h.client()
    c.mustLogin("admin")
    let r = c.get("/")
    check r.contains("""<span class="badge text-bg-warning">7</span>""")
    check r.contains("(残り 2 件)") # 7件中5件だけ表示

  test "empty database shows the guidance panels":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("admin")
    let r = c.get("/")
    check r.status == 200
    check r.contains("カテゴリーがまだありません。")
    check r.contains("未対応の備考はありません。")
    check r.contains("まだ操作がありません。「入荷」から登録してください。")

suite "blank matrix":
  test "matrix cells, note badges and forms":
    let h = newHarness()
    seedReadData(h)
    var c = h.client()
    c.mustLogin("admin")

    let r = c.get("/blank") # カテゴリー指定なし → 先頭のカテゴリー
    check r.status == 200
    check r.contains("色 / 種類")
    check r.contains("<th>M</th>")
    check r.contains("<th>L</th>")
    check r.contains("<th>計</th>")
    check r.contains("""白 <span class="badge text-bg-warning">備考</span>""") # 「白」対象の備考がある行
    check r.contains("""<td class="num low">2</td>""")    # 白 L (3以下は low)
    check r.contains("""<td class="num zero">0</td>""")   # 黒 M
    check r.contains("""<td class="num zero">–</td>""")   # 黒 L は行がない
    check r.contains("""<td class="num fw-bold">12</td>""") # 白の行合計
    check r.contains("白は補充注意")                            # 備考の一覧
    check r.contains("""action="/notes/1/resolve"""")
    check r.contains("""action="/notes/1/delete"""") # 管理者には削除フォーム
    check r.contains("この備考を削除しますか?")
    check r.contains("""<option value="白">""") # 備考フォームの対象候補
    check r.contains("""<option value="黒">""")
    check r.contains("""href="/receive?item_id=1"""")
    check r.contains("""href="/export/blank.csv?category=1"""")
    check r.contains("""href="/blank/list?category=1"""")

    # スタッフには削除フォームを出さない
    var s = h.client()
    s.mustLogin("staff")
    let rs = s.get("/blank")
    check rs.contains("""action="/notes/1/resolve"""")
    check rs.notContains("""action="/notes/1/delete"""")

    # 存在しない・不正なカテゴリーは、先頭のカテゴリーに寄せる
    for target in ["/blank?category=999", "/blank?category=abc"]:
      let rr = c.get(target)
      check rr.status == 200
      check rr.contains("ヘビーウェイトT")

    # 種類名だけのカテゴリー (サイズ無し → 計の列なし、見出しは「種類名」、列は「数量」)
    let r2 = c.get("/blank?category=2")
    check r2.contains("種類名")
    check r2.contains("<th>数量</th>")
    check r2.contains("丸型")
    check r2.notContains("<th>計</th>")

    # 検索で品番を絞る
    let r3 = c.get("/blank?q=" & queryEscape("缶"))
    check r3.contains("該当する品番がありません。") # カテゴリー1内には無い

suite "stock list":
  test "filters and sort links":
    let h = newHarness()
    seedReadData(h)
    var c = h.client()
    c.mustLogin("staff")

    let r = c.get("/blank/list?color=" & queryEscape("白"))
    check r.status == 200
    check r.contains("""<span class="num">2</span> 件""")   # 白の2行
    check r.contains("""合計 <span class="num">12</span>""") # 10+2
    # 並べ替えリンクは、いまの絞り込み (正規化済み) を引き継ぐ
    check r.contains("""href="/blank/list?color=%E7%99%BD&amp;sort=qty&amp;dir=asc"""")
    check r.contains("""<option value="白" selected>白</option>""")

    # 並べ替え中の列は、リンクの向きが反転し、向きの印が付く
    let r2 = c.get("/blank/list?sort=qty")
    check r2.contains("""<a class="text-decoration-none" href="/blank/list?sort=qty&amp;dir=desc">数量 ▲</a>""")
    let r3 = c.get("/blank/list?sort=qty&dir=desc")
    check r3.contains("""<a class="text-decoration-none" href="/blank/list?sort=qty&amp;dir=asc">数量 ▼</a>""")

    # カテゴリーで絞ると、そのカテゴリーの行だけになる
    let r4 = c.get("/blank/list?category=2")
    check r4.contains("""<span class="num">1</span> 件""")
    check r4.contains("""<option value="2" selected>バッジ</option>""")
    check r4.contains("丸型")
    check r4.notContains("ヘビーウェイトT")

  test "bad filter values fall back to defaults":
    let h = newHarness()
    seedReadData(h)
    var c = h.client()
    c.mustLogin("staff")
    # category が数値でない・sort/dir が未知 → 既定に落として全件出す
    let r = c.get("/blank/list?category=abc&sort=bogus&dir=sideways")
    check r.status == 200
    check r.contains("""<span class="num">4</span> 件""") # 全バリエーション
    # 在庫があるものだけ (数量0の黒 M が落ちる)
    let r2 = c.get("/blank/list?in_stock=1")
    check r2.contains("""<span class="num">3</span> 件""")

suite "printed list":
  test "groups by design in first-seen order":
    let h = newHarness()
    seedReadData(h)
    var c = h.client()
    c.mustLogin("staff")
    let r = c.get("/printed")
    check r.status == 200
    check r.contains("ロゴA")
    check r.contains("""<span class="num text-muted">4</span>""") # ロゴA の合計
    check r.contains("ロゴB")
    check r.contains("""<span class="num text-muted">3</span>""") # ロゴB の合計
    check r.contains("Fruit 001 ヘビーウェイトT")
    check r.contains("白 / M")
    check r.body.find("ロゴA") < r.body.find("ロゴB")
    # 検索で絞る
    let r2 = c.get("/printed?q=" & queryEscape("ロゴB"))
    check r2.contains("ロゴB")
    check r2.notContains("ロゴA")

suite "history":
  test "pagination and kind filter":
    let h = newHarness()
    execSql(h.conn, """INSERT INTO category (id, name, sort_order, uses_color, uses_size, uses_variant_name, is_printable)
      VALUES (1, 'Tシャツ', 1, 1, 1, 0, 1)""")
    execSql(h.conn, """INSERT INTO item (id, category_id, brand, item_no, name, style)
      VALUES (1, 1, 'Printstar', '085-CVT', 'Tシャツ', '半袖')""")
    execSql(h.conn, """INSERT INTO variant (id, item_id, color, size, variant_name, quantity)
      VALUES (1, 1, 'ホワイト', 'M', '', 10)""")
    for i in 1 .. 55:
      execSql(h.conn, """INSERT INTO stock_movement (batch_id, kind, variant_id, delta, note, user_id, created_at)
        VALUES ('b', 'receive', 1, 1, '入荷メモ', 2, datetime('now'))""")
    for i in 1 .. 2:
      execSql(h.conn, """INSERT INTO stock_movement (batch_id, kind, variant_id, delta, note, user_id, created_at)
        VALUES ('b', 'ship', 1, -1, '出荷メモ', 2, datetime('now'))""")
    var c = h.client()
    c.mustLogin("admin")

    let page = c.get("/history")
    check page.status == 200
    check page.contains("Printstar 085-CVT Tシャツ | ホワイト / M")
    check page.contains("""<span class="num delta-pos">+1</span>""")
    check page.contains("""href="/history?page=2&kind="""")

    let page2 = c.get("/history?page=2")
    check page2.contains("← 新しい方")
    check page2.notContains("page=3")

    let ships = c.get("/history?kind=ship")
    check ships.contains("出荷メモ")
    check ships.contains("""<span class="num delta-neg">-1</span>""")
    check ships.notContains("入荷メモ")

    let all = c.get("/history?kind=bogus") # 未知の kind は絞らない (Flask 版と同じ)
    check all.contains("入荷メモ")
    check all.contains("出荷メモ")

    # page の不正値・0 は1ページ目に寄せる
    check c.get("/history?page=abc").contains("入荷メモ")
    check c.get("/history?page=0").contains("入荷メモ")

suite "notes list":
  test "open notes shown, resolved only with all=1":
    let h = newHarness()
    seedReadData(h)
    execSql(h.conn, """INSERT INTO item_note (item_id, target, body, is_resolved, user_id)
      VALUES (1, '', '対応済みの備考', 1, 2)""")
    var c = h.client()
    c.mustLogin("staff")
    let r = c.get("/notes")
    check r.status == 200
    check r.contains("白は補充注意")
    check r.notContains("対応済みの備考")
    # 見出しは品番へのリンク (検索語は item_no)、カテゴリー名も出す
    check r.contains("""href="/blank?category=1&q=001"""")
    check r.contains("Tシャツ")
    check r.contains("""action="/notes/1/resolve"""")

    let all = c.get("/notes?all=1")
    check all.contains("白は補充注意")
    check all.contains("対応済みの備考")
    check all.contains("対応済み")
    check all.contains("未対応に戻す")

  test "empty notes messages":
    let h = newHarness()
    var c = h.client()
    c.mustLogin("staff")
    check c.get("/notes").contains("未対応の備考はありません。")
    check c.get("/notes?all=1").contains("備考はありません。")

suite "csv export":
  test "blank and printed CSV match the service output byte for byte":
    let h = newHarness()
    execSql(h.conn, """INSERT INTO category (id, name, sort_order, uses_color, uses_size, uses_variant_name, is_printable)
      VALUES (1, 'Tシャツ', 1, 1, 1, 0, 1), (2, 'バッジ', 2, 0, 0, 1, 0)""")
    execSql(h.conn, """INSERT INTO item (id, category_id, brand, item_no, name, style)
      VALUES (1, 1, 'Printstar', '085-CVT', 'Tシャツ', ''), (2, 2, '', '44mm', '缶バッジ', '')""")
    execSql(h.conn, """INSERT INTO variant (id, item_id, color, size, variant_name, quantity)
      VALUES (1, 1, 'ホワイト', 'M', '', 10), (2, 2, '', '', '丸型', 5)""")
    execSql(h.conn, "INSERT INTO design (id, name, note) VALUES (1, 'ロゴ', '')")
    execSql(h.conn, "INSERT INTO printed_product (id, design_id, variant_id, quantity) VALUES (1, 1, 1, 3)")
    var c = h.client()
    c.mustLogin("admin")

    let r = c.get("/export/blank.csv")
    check r.status == 200
    check r.respHeader("Content-Type") == "text/csv; charset=utf-8"
    check r.respHeader("Cache-Control") == "no-store"
    let cd = r.respHeader("Content-Disposition")
    check cd.startsWith("""attachment; filename="inventory_blank_""")
    check cd.endsWith(""".csv"""")
    check r.body == h.conn.blankCsv(none(int64)) # サービス層の出力とバイト一致
    check r.contains("カテゴリー,ブランド,品番,商品名,色,サイズ,種類名,数量,品番の状態\r\n")
    check r.contains("Tシャツ,Printstar,085-CVT,Tシャツ,ホワイト,M,,10,使用中")
    check r.contains("バッジ,,44mm,缶バッジ,,,丸型,5,使用中")

    let one = c.get("/export/blank.csv?category=2")
    check one.body == h.conn.blankCsv(some(2'i64))
    check one.contains("バッジ,,44mm,缶バッジ,,,丸型,5,使用中")
    check one.notContains("Printstar")

    let noneCsv = c.get("/export/blank.csv?category=999")
    check noneCsv.body == h.conn.blankCsv(some(999'i64)) # 見出しだけ

    let rp = c.get("/export/printed.csv")
    check rp.status == 200
    check rp.respHeader("Content-Type") == "text/csv; charset=utf-8"
    check rp.respHeader("Content-Disposition").startsWith(
      """attachment; filename="inventory_printed_""")
    check rp.body == h.conn.printedCsv()
    check rp.contains("デザイン,カテゴリー,ブランド,品番,商品名,色,サイズ,種類名,数量\r\n")
    check rp.contains("ロゴ,Tシャツ,Printstar,085-CVT,Tシャツ,ホワイト,M,,3")

suite "guards":
  test "read pages require login":
    let h = newHarness()
    var c = h.client()
    for p in ["/", "/blank", "/blank/list", "/printed", "/history", "/notes",
              "/export/blank.csv", "/export/printed.csv"]:
      let r = c.get(p)
      check r.status == 302
      check r.location.startsWith("/login")
