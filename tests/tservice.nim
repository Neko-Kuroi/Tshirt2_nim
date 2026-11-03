## サービス層のテスト。Go 版 internal/service の *_test.go (stock / stocklist /
## export / golden / admin)、internal/repo/users_test.go (セッショントークン)、
## service/auth.go の規則 (認証・パスワード変更) の移植。
## フィクスチャ (tests/testdata) は書き換えない。DB は常に一時ディレクトリに作り、
## ゴールデン DB はコピーしてから開く。
##
## 注意: unittest の test 本体はクロージャになるため、その中から db.tx に渡す
## ラムダは文字列や Variant をキャプチャできない (db.tx の引数は gcsafe な
## proc)。書き込み系の操作は、トップレベルのヘルパー proc (通常の proc
## フレーム) の中で tx を使う形にしてある。

import std/[algorithm, atomics, json, options, os, sequtils, sets, strutils,
            tables, tempfiles, times, unittest]
import db
import repo
import stock
import stocklist
import exportcsv
import adminsvc
import authsvc
import passwords
import util

const ProjRoot = currentSourcePath.parentDir.parentDir
const GoldenDir = ProjRoot / "tests/testdata/golden"
const AdminId = 1'i64
const StaffId = 2'i64

# ---- 共通ヘルパー (Go 版 helpers_test.go の移植) --------------------------------------

proc newTestDb(): tuple[db: DbConn, dir: string] =
  ## Flask 版 tests/conftest.py と同じ初期データを持つ、マイグレーション済みの DB。
  let dir = createTempDir("tsvc", "")
  let conn = openDb(dir / "test.db")
  discard migrate(conn)
  execSql(conn, """INSERT INTO category (name, sort_order, uses_color, uses_size, uses_variant_name, is_printable)
VALUES ('Tシャツ', 0, 1, 1, 0, 1), ('バッジ', 1, 0, 0, 1, 0)""")
  execSql(conn, """INSERT INTO item (category_id, brand, item_no, name) VALUES
(1, 'Printstar', '085-CVT', 'Tシャツ'), (1, 'United Athle', '5001', 'Tシャツ'), (2, '', '44mm', '缶バッジ')""")
  execSql(conn, """INSERT INTO "user" (username, password_hash, role) VALUES
('admin', 'x', 'admin'), ('staff', 'x', 'staff')""")
  (conn, dir)

proc scalar(db: DbConn, q: string): int64 =
  parseBiggestInt(db.getValue(SqlQuery(q)))

proc scalar(db: DbConn, q: string, arg: int64): int64 =
  parseBiggestInt(db.getValue(SqlQuery(q), arg))

proc countRows(db: DbConn, tail: string): int64 =
  scalar(db, "SELECT COUNT(*) FROM " & tail)

proc itemIdByBrand(db: DbConn, brand: string): int64 =
  parseBiggestInt(db.getValue(sql"SELECT id FROM item WHERE brand = ?", brand))

proc getItemOrFail(db: DbConn, id: int64): Item =
  let it = db.getItem(id)
  doAssert it.isSome, "GetItem failed"
  it.get

proc tee(db: DbConn, brand: string): Item =
  getItemOrFail(db, itemIdByBrand(db, brand))

proc badge(db: DbConn): Item =
  getItemOrFail(db, scalar(db, "SELECT id FROM item WHERE item_no = '44mm'"))

proc tee0(db: DbConn, brand: string): Item =
  ## brand が空ならバッジの品番 (Flask 版テストの _receive("", ...) と同じ)。
  if brand == "":
    return badge(db)
  tee(db, brand)

proc qtyOf(db: DbConn, variantId: int64): int64 =
  scalar(db, "SELECT quantity FROM variant WHERE id = ?", variantId)

# ---- tx を使う操作ヘルパー (トップレベル proc の中で tx を使う) -------------------------
# 成功系は例外をそのまま伝播させ、try* 系は業務エラーの文言を文字列で返す。

proc opCreateVariant(db: DbConn, item: Item, color, size, vn: string): Variant =
  var vid: int64
  db.tx do ():
    vid = getOrCreateVariant(db, item, color, size, vn).id
  db.getVariant(vid).get

proc tryCreateVariant(db: DbConn, item: Item, color, size, vn: string): string =
  try:
    discard opCreateVariant(db, item, color, size, vn)
    ""
  except StockError as e:
    e.msg

proc opReceive(db: DbConn, v: Variant, qty: int64, note = "") =
  db.tx do ():
    discard receive(db, AdminId, v, qty, note)

proc receiveH(db: DbConn, brand, color, size: string, qty: int64,
              variantName = ""): Variant =
  ## 1回の入荷 (variant を必要なら作る)。variant を返す。
  var vid: int64
  db.tx do ():
    let created = getOrCreateVariant(db, tee0(db, brand), color, size, variantName)
    discard receive(db, AdminId, created, qty, "")
    vid = created.id
  db.getVariant(vid).get

proc tryReceiveNew(db: DbConn, item: Item, color, size, vn: string,
                   qty: int64): string =
  ## variant 作成 + 入荷を1つの tx で。失敗したら文言を返す。
  try:
    db.tx do ():
      let v = getOrCreateVariant(db, item, color, size, vn)
      discard receive(db, AdminId, v, qty, "")
    ""
  except StockError as e:
    e.msg

proc tryReceive(db: DbConn, v: Variant, qty: int64): string =
  try:
    opReceive(db, v, qty)
    ""
  except StockError as e:
    e.msg

proc opShip(db: DbConn, target: Target, qty: int64, note = "") =
  db.tx do ():
    discard ship(db, AdminId, target, qty, note)

proc tryShip(db: DbConn, target: Target, qty: int64): string =
  try:
    opShip(db, target, qty)
    ""
  except StockError as e:
    e.msg

proc opConvert(db: DbConn, v: Variant, design: string, used, output: int64,
               note = ""): string =
  var batch = ""
  db.tx do ():
    batch = convertToPrinted(db, AdminId, v, design, used, output, note)
  batch

proc tryConvert(db: DbConn, v: Variant, design: string, used,
                output: int64): string =
  try:
    discard opConvert(db, v, design, used, output)
    ""
  except StockError as e:
    e.msg

proc opAdjust(db: DbConn, target: Target, delta: int64, note: string) =
  db.tx do ():
    discard adjust(db, AdminId, target, delta, note)

proc tryAdjust(db: DbConn, target: Target, delta: int64, note: string): string =
  try:
    opAdjust(db, target, delta, note)
    ""
  except StockError as e:
    e.msg

# ---- 在庫操作 (Go 版 stock_test.go の移植) --------------------------------------------

suite "stock":
  test "receive creates variant and movement":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = opCreateVariant(db, tee(db, "Printstar"), "黒", "M", "")
    opReceive(db, v, 30, "納品書A")
    check qtyOf(db, v.id) == 30
    check countRows(db, "stock_movement") == 1
    let row = db.getRow(sql"""SELECT kind, delta, variant_id, printed_product_id, note, user_id
FROM stock_movement""")
    check row[0] == "receive"
    check parseBiggestInt(row[1]) == 30
    check parseBiggestInt(row[2]) == v.id
    check row[3] == "" # printed_product_id は NULL
    check row[4] == "納品書A"
    check parseBiggestInt(row[5]) == AdminId
    db.close()

  test "same spec reuses variant and brands are separate":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let a1 = opCreateVariant(db, tee(db, "Printstar"), "黒", "M", "")
    let a2 = opCreateVariant(db, tee(db, "Printstar"), " 黒 ", "M", "")
    let b = opCreateVariant(db, tee(db, "United Athle"), "黒", "M", "")
    check a1.id == a2.id
    check a1.id != b.id
    db.close()

  test "unused columns are blanked and required ones enforced":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = opCreateVariant(db, badge(db), "赤", "M", "デザインA")
    check v.color == "" and v.size == "" and v.variantName == "デザインA"
    let cases = [
      ("", "", "", "", "種類名を入力してください。"),
      ("Printstar", "黒", "", "", "サイズを入力してください。"),
      ("Printstar", "", "M", "", "色を入力してください。"),
      ("Printstar", "  ", "M", "", "色を入力してください。"),
    ]
    for (brand, color, size, vn, msg) in cases:
      check tryCreateVariant(db, tee0(db, brand), color, size, vn) == msg
    db.close()

  test "inactive item cannot be received":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    execSql(db, "UPDATE item SET is_active = 0 WHERE brand = 'Printstar'")
    check tryCreateVariant(db, tee(db, "Printstar"), "黒", "M", "") ==
      "この品番は使用停止中のため、入荷できません。"
    db.close()

  test "cannot go negative and failure rolls everything back":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "黒", "M", 5)
    check tryShip(db, v.target, 6) == "在庫が足りません。"
    check qtyOf(db, v.id) == 5
    check countRows(db, "stock_movement") == 1
    db.close()

  test "convert is atomic and logs both sides":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "黒", "M", 20)
    let batch = opConvert(db, v, "ロゴA", 10, 9, "1枚ミスプリント")
    check qtyOf(db, v.id) == 10
    let ps = db.products("")
    check ps.len == 1 and ps[0].quantity == 9 and ps[0].designName == "ロゴA"
    var got: seq[string]
    for row in db.getAllRows(sql"SELECT kind, delta FROM stock_movement WHERE batch_id = ? ORDER BY id", batch):
      got.add row[0] & ":" & row[1]
    check got.join(",") == "print_use:-10,print_output:9"
    db.close()

  test "convert failure leaves nothing behind":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "黒", "M", 3)
    check tryConvert(db, v, "ロゴA", 5, 5) == "在庫が足りません。"
    check qtyOf(db, v.id) == 3
    check countRows(db, "printed_product") == 0
    check countRows(db, "design") == 0 # デザインの新規登録も巻き戻ること
    check countRows(db, "stock_movement") == 1
    db.close()

  test "convert validations":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "黒", "M", 10)
    let bv = receiveH(db, "", "", "", 10, "デザインA")
    let cases = [
      (v, "A", 5'i64, 6'i64, "完成数が使用数を超えています。"),
      (v, "", 5'i64, 5'i64, "デザイン名を入力してください。"),
      (bv, "A", 1'i64, 1'i64, "このカテゴリーはプリント対象ではありません。"),
      (v, "A", 0'i64, 0'i64, "使用数は1以上の整数で入力してください。"),
      (v, "A", 1'i64, -1'i64, "完成数は0以上の整数で入力してください。"),
      (v, "A", int64(MaxQty + 1), 1'i64, "使用数は1,000,000以下で入力してください。"),
    ]
    for (target, design, used, output, msg) in cases:
      check tryConvert(db, target, design, used, output) == msg
    execSql(db, "UPDATE item SET is_active = 0 WHERE brand = 'Printstar'")
    let stopped = db.getVariant(v.id).get
    check tryConvert(db, stopped, "A", 1, 1) ==
      "この品番は使用停止中のため、プリント変換できません。"
    check qtyOf(db, v.id) == 10
    db.close()

  test "convert with zero output creates no product":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "黒", "M", 5)
    discard opConvert(db, v, "全滅", 2, 0)
    check countRows(db, "printed_product") == 0
    check countRows(db, "stock_movement WHERE kind = 'print_output'") == 0
    check qtyOf(db, v.id) == 3
    db.close()

  test "adjust requires reason and nonzero":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "黒", "M", 10)
    let cases = [
      (-1'i64, "", "棚卸し調整には理由を入力してください。"),
      (-1'i64, " 　", "棚卸し調整には理由を入力してください。"), # 空白 (全角含む) だけの理由も不可
      (0'i64, "理由", "増減数は0以外の整数で入力してください。"),
    ]
    for (delta, note, msg) in cases:
      check tryAdjust(db, v.target, delta, note) == msg
    opAdjust(db, v.target, -2, "棚卸し")
    check qtyOf(db, v.id) == 8
    db.close()

  test "ship printed product":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "黒", "M", 10)
    discard opConvert(db, v, "ロゴA", 10, 10)
    let ps = db.products("")
    opShip(db, ps[0].target, 4)
    check db.getProduct(ps[0].id).get.quantity == 6
    let pid = db.getValue(sql"SELECT printed_product_id FROM stock_movement WHERE kind = 'ship'")
    check pid == $ps[0].id
    db.close()

  test "quantity stays integer even when a huge qty is sent":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "赤", "M", 5)
    check tryReceive(db, v, Int64Max) == "数量は1,000,000以下で入力してください。"
    let row = db.getRow(sql"SELECT quantity, typeof(quantity) FROM variant WHERE id = ?", v.id)
    check row[0] == "5" and row[1] == "integer"
    db.close()

  test "per-operation limit is enforced everywhere":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let over = MaxQty + 1
    let got = tryReceiveNew(db, tee(db, "Printstar"), "赤", "M", "", over)
    check "1,000,000以下" in got
    check countRows(db, "variant") == 0 # 上限超えの入荷で variant が残らない
    let v = receiveH(db, "Printstar", "赤", "M", MaxQty)
    check qtyOf(db, v.id) == MaxQty
    check "1,000,000以下" in tryShip(db, v.target, over)
    check "1,000,000以下" in tryAdjust(db, v.target, over, "x")
    check "1,000,000以下" in tryAdjust(db, v.target, -over, "x")
    check "1,000,000以下" in tryConvert(db, v, "x", over, 1)
    check qtyOf(db, v.id) == MaxQty
    db.close()

  test "stock error is distinguishable from database errors":
    # Nim では例外の型で区別する (StockError と DbError は別型)。
    var stockCaught = false
    try:
      raise newException(StockError, "x")
    except StockError:
      stockCaught = true
    check stockCaught
    var dbCaughtAsStock = false
    try:
      raise newException(DbError, "x")
    except StockError:
      dbCaughtAsStock = true
    except DbError:
      discard
    check not dbCaughtAsStock

  test "newUUID format":
    var seen = initHashSet[string]()
    for i in 0 ..< 200:
      let u = newUuid()
      check u.len == 36 and u[8] == '-' and u[13] == '-' and u[18] == '-' and
            u[23] == '-' and u[14] == '4' and u[19] in {'8', '9', 'a', 'b'} and
            u == u.toLowerAscii()
      check u notin seen
      seen.incl u

  test "formatQty":
    check formatQty(0) == "0"
    check formatQty(999) == "999"
    check formatQty(1000) == "1,000"
    check formatQty(1000000) == "1,000,000"
    check formatQty(1234567) == "1,234,567"

# ---- 同時リクエスト (別接続・別スレッド) でも壊れない --------------------------------

var gPathBuf: array[1024, char]
var gPathLen: int
var gItemId: int64
var gVariantId: int64
var gStart: Atomic[bool]
var gOk, gStockErr, gOtherErr: Atomic[int]

proc setTestPath(p: string) =
  gPathLen = min(p.len, gPathBuf.len)
  copyMem(addr gPathBuf[0], unsafeAddr p[0], gPathLen)

proc testPath(): string =
  result = newString(gPathLen)
  if gPathLen > 0:
    copyMem(addr result[0], addr gPathBuf[0], gPathLen)

proc waitStart() =
  while not gStart.load:
    sleep(1)

proc receiveWorker(_: int) {.thread.} =
  waitStart()
  try:
    let db = openDb(testPath())
    for i in 0 ..< 5:
      try:
        db.tx do ():
          let it = getItemOrFail(db, gItemId)
          let v = getOrCreateVariant(db, it, "黒", "M", "")
          discard receive(db, AdminId, v, 1, "")
        discard gOk.fetchAdd(1)
      except Exception:
        discard gOtherErr.fetchAdd(1)
    db.close()
  except Exception:
    discard gOtherErr.fetchAdd(1)

proc shipWorker(_: int) {.thread.} =
  waitStart()
  try:
    let db = openDb(testPath())
    for i in 0 ..< 3: # 8×3=24回 ×1枚 を出荷しようとする (在庫は10)
      try:
        db.tx do ():
          discard ship(db, AdminId, Target(kind: tkVariant, id: gVariantId), 1, "")
        discard gOk.fetchAdd(1)
      except StockError:
        discard gStockErr.fetchAdd(1)
      except Exception:
        discard gOtherErr.fetchAdd(1)
    db.close()
  except Exception:
    discard gOtherErr.fetchAdd(1)

suite "stock concurrency":
  test "concurrent receives on same new variant":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let path = dir / "test.db"
    gItemId = itemIdByBrand(db, "Printstar")
    db.close()
    setTestPath(path)
    gOk.store(0)
    gOtherErr.store(0)
    gStart.store(false)
    var threads: array[8, Thread[int]]
    for i in 0 ..< 8:
      createThread(threads[i], receiveWorker, i)
    gStart.store(true)
    for i in 0 ..< 8:
      joinThread(threads[i])
    check gOtherErr.load() == 0
    check gOk.load() == 40
    let db2 = openDb(path)
    check countRows(db2, "variant") == 1 # UNIQUE 衝突も、二重登録もなし
    check scalar(db2, "SELECT quantity FROM variant") == 40
    check countRows(db2, "stock_movement") == 40
    db2.close()

  test "concurrent ship never goes negative":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "黒", "M", 10)
    let path = dir / "test.db"
    gVariantId = v.id
    db.close()
    setTestPath(path)
    gOk.store(0)
    gStockErr.store(0)
    gOtherErr.store(0)
    gStart.store(false)
    var threads: array[8, Thread[int]]
    for i in 0 ..< 8:
      createThread(threads[i], shipWorker, i)
    gStart.store(true)
    for i in 0 ..< 8:
      joinThread(threads[i])
    check gOtherErr.load() == 0
    check gOk.load() == 10
    check gStockErr.load() == 14
    let db2 = openDb(path)
    check qtyOf(db2, v.id) == 0
    db2.close()

# ---- 在庫一覧 (Go 版 stocklist_test.go の移植) -----------------------------------------

proc setStyle(db: DbConn, brand, style: string) =
  db.exec(sql"UPDATE item SET style = ? WHERE brand = ?", style, brand)

proc stocked(): tuple[db: DbConn, dir: string] =
  ## 半袖 (Printstar)・長袖 (United Athle)・タイプ未設定のバッジを用意する。
  let (db, dir) = newTestDb()
  setStyle(db, "Printstar", "半袖")
  setStyle(db, "United Athle", "長袖")
  for (size, qty) in [("XL", 4'i64), ("S", 10'i64), ("L", 1'i64), ("M", 7'i64)]:
    discard receiveH(db, "Printstar", "黒", size, qty)
  # 在庫0の行を作る (入荷0は拒否されるので、出荷で0にする)
  let l = db.findVariant(itemIdByBrand(db, "Printstar"), "黒", "L", "").get
  opShip(db, l.target, 1)
  discard receiveH(db, "Printstar", "白", "M", 2)
  discard receiveH(db, "United Athle", "黒", "M", 5)
  discard receiveH(db, "United Athle", "赤", "L", 1)
  discard receiveH(db, "", "", "", 9, "赤")
  (db, dir)

proc mkArgs(kv: varargs[string]): QueryArgs =
  for i in countup(0, kv.len - 2, 2):
    result.add (kv[i], kv[i + 1])

proc search(db: DbConn, kv: varargs[string]): StockListResult =
  searchStock(db, parseFilter(mkArgs(kv)))

proc rowIds(rows: seq[StockRow]): seq[int64] =
  rows.mapIt(it.variantId)

proc colorSize(rows: seq[StockRow]): seq[string] =
  rows.mapIt(it.color & "/" & it.size)

suite "stocklist":
  test "all rows are listed including zero stock":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let res = search(db)
    check res.rows.len == 8 and res.count == 8
    check res.rows.countIt(it.quantity == 0) == 1
    db.close()

  test "default order is category brand item color size":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let res = search(db)
    let printstar = res.rows.filterIt(it.brand == "Printstar")
    check colorSize(printstar) == @["白/M", "黒/S", "黒/M", "黒/L", "黒/XL"]
    for i, r in res.rows:
      check r.categoryName == (if i == 7: "バッジ" else: "Tシャツ")
    db.close()

  test "filter by style is what makes sleeve length work":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let short = search(db, "style", "半袖")
    check short.rows.len == 5
    for r in short.rows:
      check r.brand == "Printstar" and r.style == "半袖"
    let long = search(db, "style", "長袖")
    check long.rows.len == 2
    for r in long.rows:
      check r.brand == "United Athle"
    let none = search(db, "style", "存在しない")
    check none.rows.len == 0 and none.count == 0
    db.close()

  test "filter by category color size and combination":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let cat2 = search(db, "category", "2")
    check cat2.rows.len == 1
    for r in cat2.rows:
      check r.categoryName == "バッジ"
    for r in search(db, "color", "白").rows:
      check r.color == "白"
    check search(db, "size", "M").rows.len == 3
    let both = search(db, "style", "半袖", "color", "黒", "size", "M")
    check both.rows.len == 1 and both.rows[0].quantity == 7
    db.close()

  test "color filter also finds badge variant name":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    var cats = initHashSet[string]()
    for r in search(db, "color", "赤").rows:
      cats.incl r.categoryName
    check cats == ["Tシャツ", "バッジ"].toHashSet
    db.close()

  test "in stock only and text search":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let inStock = search(db, "in_stock", "1")
    check inStock.rows.len == 7
    for r in inStock.rows:
      check r.quantity != 0
    check search(db, "q", "United").rows.len == 2
    check search(db, "q", "085").rows.len == 5
    db.close()

  test "LIKE wildcards in search are literal":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    for q in ["%", "_"]:
      check search(db, "q", q).rows.len == 0
    # 文字として含む品番は、そのまま見つかる (item_no は A + バックスラッシュ2つ + B)
    execSql(db, "INSERT INTO item (category_id, brand, item_no, name) VALUES (1, '100%_cotton', 'A\\\\B', 'x')")
    discard receiveH(db, "100%_cotton", "黒", "M", 1)
    let bs2 = "\\\\" # バックスラッシュ2文字
    for q in ["%", "_", "0%_c", "A" & bs2 & "B", bs2]:
      check search(db, "q", q).rows.len == 1
    db.close()

  test "sort by size is natural both directions":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let base = @["category", "1", "style", "半袖", "color", "黒", "sort", "size"]
    let asc = colorSize(search(db, base & @["dir", "asc"]).rows)
    check asc == @["黒/S", "黒/M", "黒/L", "黒/XL"]
    let desc = colorSize(search(db, base & @["dir", "desc"]).rows)
    check desc == @["黒/XL", "黒/L", "黒/M", "黒/S"]
    db.close()

  test "sort by quantity":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let asc = search(db, "sort", "qty", "dir", "asc").rows.mapIt(it.quantity)
    check asc == sorted(asc) and asc[0] == 0
    let desc = search(db, "sort", "qty", "dir", "desc").rows.mapIt(it.quantity)
    check desc == sorted(desc, Descending) and desc[0] == 10
    db.close()

  test "blank values always sort last":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    for dirn in ["asc", "desc"]:
      let rows = search(db, "sort", "style", "dir", dirn).rows
      check rows[^1].style == ""
      for r in rows[0 ..< ^1]:
        check r.style != ""
      let bySize = search(db, "sort", "size", "dir", dirn).rows
      check bySize[^1].size == ""
    db.close()

  test "sort by style groups and keeps default order inside":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let rows = search(db, "sort", "style", "dir", "asc").rows
    for r in rows[0 ..< 5]:
      check r.style == "半袖"
    for r in rows[5 ..< 7]:
      check r.style == "長袖"
    check colorSize(rows[0 ..< 5]) == @["白/M", "黒/S", "黒/M", "黒/L", "黒/XL"]
    db.close()

  test "sort by category desc":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    check search(db, "sort", "category", "dir", "desc").rows[0].categoryName == "バッジ"
    db.close()

  test "bad input never breaks and falls back":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let big = "1" & repeat("0", 30)
    let bad: seq[QueryArgs] = @[
      mkArgs("sort", "evil;DROP TABLE item"), mkArgs("sort", ""),
      mkArgs("dir", "sideways"), mkArgs("category", "abc"),
      mkArgs("category", big), mkArgs("category", "-1"),
      mkArgs("style", repeat("あ", 5000)), mkArgs("q", repeat("x", 5000)),
      mkArgs("color", "\x00"), mkArgs("in_stock", "yes"),
      @[("sort", "size"), ("sort", "qty")],
      @[("_external", "1"), ("endpoint", "x")],
    ]
    for args in bad:
      discard searchStock(db, parseFilter(args)) # 例外にならないこと
    let def = rowIds(search(db).rows)
    check rowIds(search(db, "sort", "nonsense", "dir", "sideways").rows) == def
    check parseFilter(@[("sort", "size"), ("sort", "qty")]).sort == "size"
    db.close()

  test "parseFilter":
    let f0 = parseFilter(@[])
    check f0.category.isNone and f0.sort == "category" and f0.dir == "asc" and
          not f0.inStock and f0.style == ""
    let f = parseFilter(mkArgs("style", "  半袖 ", "in_stock", "1", "dir", "desc",
                               "sort", "qty", "category", "１"))
    check f.style == "半袖" and f.inStock and f.dir == "desc" and
          f.sort == "qty" and f.category.isSome and f.category.get == 1
    check runeCount(parseFilter(mkArgs("style", repeat("あ", 5000))).style) == MaxText
    check not parseFilter(mkArgs("in_stock", "yes")).inStock

  test "likePattern":
    check likePattern("abc") == "%abc%"
    check likePattern("50%") == "%50\\%%"
    check likePattern("a_b") == "%a\\_b%"
    check likePattern("a\\b") == "%a\\\\b%"
    check likePattern("") == "%%"

  test "stopped items are listed with flag":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    execSql(db, "UPDATE item SET is_active = 0 WHERE brand = 'United Athle'")
    let rows = search(db, "style", "長袖").rows
    check rows.len == 2
    for r in rows:
      check not r.itemActive
    db.close()

  test "total counts all matches":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let res = search(db, "style", "半袖")
    check res.count == 5 and res.totalQty == 23
    db.close()

  test "truncation keeps the total correct":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    let saved = stocklist.maxRows
    defer: stocklist.maxRows = saved
    stocklist.maxRows = 3
    let res = search(db)
    check res.rows.len == 3 and res.truncated and res.count == 8 and
          res.totalQty == 38
    stocklist.maxRows = 8
    check not search(db).truncated
    db.close()

  test "empty database":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let res = search(db)
    check res.rows.len == 0 and res.count == 0 and res.totalQty == 0 and
          not res.truncated
    let opts = db.listOptions()
    check opts.styles.len + opts.colors.len + opts.sizes.len == 0
    db.close()

  test "options and style choices":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    setStyle(db, "Printstar", "ドライ")
    let opts = db.listOptions()
    check opts.styles == @["ドライ", "長袖"]
    check opts.sizes == @["S", "M", "L", "XL"]
    let choices = db.styleChoices()
    for s in ["半袖", "長袖", "ドライ"]:
      check s in choices
    check choices == sorted(choices)
    db.close()

# ---- クエリ数の測定 (Go 版 countingQ の代替: sqlite3_profile) ---------------------------

type ProfileCb = proc(arg: pointer, sqlText: cstring, ns: uint64) {.cdecl.}

proc sqlite3_profile(db: pointer, cb: ProfileCb, arg: pointer): pointer
  {.importc: "sqlite3_profile", dynlib: "libsqlite3.so.0".}

var qCount: Atomic[int]

proc onProfile(arg: pointer, sqlText: cstring, ns: uint64) {.cdecl.} =
  discard qCount.fetchAdd(1)

proc countQueries(db: DbConn, body: proc()): int =
  ## Go 版の countingQ (Querier ラッパー) に相当する測定を、SQLite の
  ## プロファイルコールバックで行う。件数が行数で増えないことだけを見る。
  qCount.store(0)
  discard sqlite3_profile(cast[pointer](db), onProfile, nil)
  body()
  discard sqlite3_profile(cast[pointer](db), ProfileCb(nil), nil)
  qCount.load()

proc seedSearchItems(db: DbConn, fromIdx, n: int) =
  for i in fromIdx ..< fromIdx + n:
    let brand = "B" & $chr('a'.ord + i)
    let id = db.insertID(sql"INSERT INTO item (category_id, brand, item_no, name, style) VALUES (1, ?, ?, 'T', '半袖')",
                         brand, "N")
    db.tx do ():
      let it = getItemOrFail(db, id)
      let v = getOrCreateVariant(db, it, "黒", "M", "")
      discard receive(db, AdminId, v, 3, "")

suite "query count":
  test "searchStock query count does not grow with rows":
    let (db, dir) = stocked()
    defer: removeDir(dir)
    proc run() =
      discard searchStock(db, parseFilter(mkArgs("sort", "size")))
    let small = countQueries(db, run)
    seedSearchItems(db, 0, 15)
    check countQueries(db, run) == small
    db.close()

# ---- CSV 出力 (Go 版 export_test.go の移植) ---------------------------------------------

proc parseCsvText(s: string): seq[seq[string]] =
  ## テスト用の最小 CSV リーダー (Python の csv と同じ読み方ができる範囲)。
  var i = 0
  var row: seq[string]
  var field = ""
  var inQuotes = false
  var started = false
  template endField() =
    row.add field
    field = ""
    started = false
  template endRow() =
    endField()
    result.add row
    row = @[]
  while i < s.len:
    let ch = s[i]
    if inQuotes:
      if ch == '"':
        if i + 1 < s.len and s[i + 1] == '"':
          field.add '"'
          i += 2
        else:
          inQuotes = false
          i += 1
      else:
        field.add ch
        i += 1
    elif ch == '"' and not started and field.len == 0:
      inQuotes = true
      started = true
      i += 1
    elif ch == ',':
      endField()
      i += 1
    elif ch == '\r':
      if i + 1 < s.len and s[i + 1] == '\n':
        i += 1
      endRow()
      i += 1
    elif ch == '\n':
      endRow()
      i += 1
    else:
      field.add ch
      started = true
      i += 1
  if started or field.len > 0 or row.len > 0:
    endRow()

proc csvRowsOf(csvText: string): seq[seq[string]] =
  var s = csvText
  if s.startsWith("\xEF\xBB\xBF"):
    s = s[3 .. ^1]
  parseCsvText(s)

proc containsRow(rows: seq[seq[string]], want: seq[string]): bool =
  for r in rows:
    if r == want:
      return true
  false

proc seedExportItems(db: DbConn, fromIdx, n: int) =
  for i in fromIdx ..< fromIdx + n:
    let brand = "B" & $chr('a'.ord + i)
    let id = db.insertID(sql"INSERT INTO item (category_id, brand, item_no, name) VALUES (1, ?, 'N', 'T')", brand)
    db.tx do ():
      let it = getItemOrFail(db, id)
      let v = getOrCreateVariant(db, it, "黒", "M", "")
      discard receive(db, AdminId, v, 10, "")
      discard convertToPrinted(db, AdminId, v, "D" & brand, 5, 5, "")

suite "export":
  test "blank CSV format for Excel":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    discard receiveH(db, "Printstar", "黒", "M", 10)
    let outText = blankCsv(db, none(int64))
    check outText.startsWith("\xEF\xBB\xBF") # BOM (Excel の文字化け防止)
    check "\r\n" in outText
    check "\n" notin outText.replace("\r\n", "")
    let rows = csvRowsOf(outText)
    check rows[0] == @BlankHeaders
    check containsRow(rows, @["Tシャツ", "Printstar", "085-CVT", "Tシャツ",
                              "黒", "M", "", "10", "使用中"])
    db.close()

  test "quantity is plain number and zero rows are included":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    discard receiveH(db, "Printstar", "黒", "M", 5)
    let w = receiveH(db, "Printstar", "白", "M", 3)
    opShip(db, w.target, 3)
    let outText = blankCsv(db, none(int64))
    let raw = outText[3 .. ^1] # BOM を除く
    check "\"5\"" notin raw and "\"0\"" notin raw # 数量は引用符なしの数値
    var qty = initTable[string, string]()
    for r in csvRowsOf(outText)[1 .. ^1]:
      qty[r[4]] = r[7]
    check qty["黒"] == "5" and qty["白"] == "0"
    db.close()

  test "stopped item is marked":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    discard receiveH(db, "United Athle", "赤", "L", 2)
    execSql(db, "UPDATE item SET is_active = 0 WHERE brand = 'United Athle'")
    for r in csvRowsOf(blankCsv(db, none(int64)))[1 .. ^1]:
      if r[1] == "United Athle":
        check r[8] == "停止中"
    db.close()

  test "sizes are in natural order":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    for s in ["XL", "S", "L", "M"]:
      discard receiveH(db, "Printstar", "黒", s, 1)
    var sizes: seq[string]
    for r in csvRowsOf(blankCsv(db, none(int64)))[1 .. ^1]:
      if r[1] == "Printstar":
        sizes.add r[5]
    check sizes == @["S", "M", "L", "XL"]
    db.close()

  test "category filter":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    discard receiveH(db, "Printstar", "黒", "M", 1)
    discard receiveH(db, "", "", "", 4, "赤")
    proc cats(rows: seq[seq[string]]): HashSet[string] =
      result = initHashSet[string]()
      for r in rows[1 .. ^1]:
        result.incl r[0]
    check cats(csvRowsOf(blankCsv(db, none(int64)))) ==
      ["Tシャツ", "バッジ"].toHashSet
    check cats(csvRowsOf(blankCsv(db, some(2'i64)))) == ["バッジ"].toHashSet
    check csvRowsOf(blankCsv(db, some(999'i64))).len == 1 # 存在しないIDは見出しだけ
    db.close()

  test "special characters round trip":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    db.exec(sql"UPDATE item SET name = ? WHERE brand = 'Printstar'", "A,\"B\"\nC")
    discard receiveH(db, "Printstar", "黒", "M", 1)
    for r in csvRowsOf(blankCsv(db, none(int64)))[1 .. ^1]:
      if r[1] == "Printstar":
        check r[3] == "A,\"B\"\nC"
    db.close()

  test "formula injection is neutralized":
    for evil in ["=1+1", "+1", "-1", "@SUM(A1)", "\t=1"]:
      let (db, dir) = newTestDb()
      db.exec(sql"UPDATE item SET name = ? WHERE brand = 'Printstar'", evil)
      discard receiveH(db, "Printstar", "黒", "M", 1)
      for r in csvRowsOf(blankCsv(db, none(int64)))[1 .. ^1]:
        if r[1] == "Printstar":
          check r[3] == "'" & evil
      db.close()
      removeDir(dir)

  test "safeCell leaves normal values alone":
    for v in ["黒", "", "a=b", "x-1"]:
      check safeCell(ctext(v)).text == v
    check safeCell(cint(0)).num == 0
    check safeCell(cint(12)).num == 12
    let cases = {"=1": "'=1", "+1": "'+1", "-1": "'-1", "@a": "'@a",
                 "\tx": "'\tx", "\rx": "'\rx"}
    for (input, want) in cases:
      check safeCell(ctext(input)).text == want

  test "printed CSV":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let v = receiveH(db, "Printstar", "黒", "M", 10)
    discard opConvert(db, v, "ねこロゴ", 6, 5)
    let rows = csvRowsOf(printedCsv(db))
    check rows[0] == @PrintedHeaders
    check containsRow(rows, @["ねこロゴ", "Tシャツ", "Printstar", "085-CVT",
                              "Tシャツ", "黒", "M", "", "5"])
    db.close()

  test "empty database gives header only":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let blank = csvRowsOf(blankCsv(db, none(int64)))
    check blank.len == 1 and blank[0] == @BlankHeaders
    let printed = csvRowsOf(printedCsv(db))
    check printed.len == 1 and printed[0] == @PrintedHeaders
    db.close()

  test "export query count does not grow with rows":
    for kind in ["blank", "printed"]:
      let (db, dir) = newTestDb()
      seedExportItems(db, 0, 3)
      proc runBlank() = discard blankRows(db, none(int64))
      proc runPrinted() = discard printedRows(db)
      let run = if kind == "blank": runBlank else: runPrinted
      let small = countQueries(db, run)
      seedExportItems(db, 3, 12)
      check countQueries(db, run) == small
      db.close()
      removeDir(dir)

  test "CSV quoting matches Python csv writer":
    # Python の csv.writer は、先頭の空白では引用符を付けない。
    let got = toCsvBytes(@["h"], @[
      @[ctext(" lead")], @[ctext("a,b")], @[ctext("q\"q")],
      @[ctext("l1\nl2")], @[ctext("c\rr")], @[ctext("")], @[cint(7)],
    ])
    let want = "\xEF\xBB\xBF" &
      "h\r\n lead\r\n\"a,b\"\r\n\"q\"\"q\"\r\n\"l1\nl2\"\r\n\"c\rr\"\r\n\r\n7\r\n"
    check got == want

  test "CSV filename uses JST date":
    # UTC の 10/31 15:30 は、JST では 11/01
    let utc = dateTime(2026, mOct, 31, 15, 30, 0, zone = utc()).toTime.toUnix
    check csvFilename("inventory_blank", utc) == "inventory_blank_20261101.csv"

# ---- 管理操作のヘルパー (tx はトップレベル proc の中で使う) ------------------------------

proc opCreateUser(db: DbConn, username, password, role: string): string =
  try:
    db.tx do ():
      discard createUser(db, username, password, role)
    ""
  except AdminError as e:
    e.msg

proc opSetUserActive(db: DbConn, userId: int64, active: bool) =
  db.tx do ():
    setUserActive(db, userId, active)

proc opResetUserPassword(db: DbConn, userId: int64, password: string): string =
  try:
    db.tx do ():
      resetUserPassword(db, userId, password)
    ""
  except AdminError as e:
    e.msg

proc opCreateCategory(db: DbConn, name: string, flags: CategoryFlags): string =
  try:
    db.tx do ():
      discard createCategory(db, name, flags)
    ""
  except AdminError as e:
    e.msg

proc opUpdateCategory(db: DbConn, cat: Category, name: string, sortOrder: int,
                      flags: CategoryFlags): string =
  try:
    db.tx do ():
      updateCategory(db, cat, name, sortOrder, flags)
    ""
  except AdminError as e:
    e.msg

proc opCreateItem(db: DbConn, categoryId: int64, brand, itemNo, name,
                  style: string): string =
  try:
    db.tx do ():
      discard createItem(db, categoryId, brand, itemNo, name, style)
    ""
  except AdminError as e:
    e.msg

proc opUpdateItem(db: DbConn, itemId: int64, brand, itemNo, name, style: string,
                  isActive: bool): string =
  try:
    db.tx do ():
      updateItem(db, itemId, brand, itemNo, name, style, isActive)
    ""
  except AdminError as e:
    e.msg

# ---- ゴールデン照合 (Go 版 golden_test.go の移植) ---------------------------------------

proc goldenDb(): tuple[db: DbConn, dir: string] =
  ## ゴールデン DB はコピーしてから開く (フィクスチャは書き換えない)。
  let dir = createTempDir("tgold", "")
  let path = dir / "golden.db"
  copyFile(GoldenDir / "inventory.db", path)
  doAssert checkDb(path) == dsCurrent, "golden DB is not current"
  (openDb(path), dir)

proc firstDiff(got, want: string): string =
  let n = min(got.len, want.len)
  var i = 0
  while i < n and got[i] == want[i]:
    i += 1
  let lo = max(0, i - 30)
  "first difference at byte " & $i & ":\n got  " &
    got[lo ..< min(got.len, i + 30)] & "\n want " &
    want[lo ..< min(want.len, i + 30)]

proc jsonStrs(n: JsonNode): seq[string] =
  if n.kind == JArray:
    for it in n:
      result.add it.getStr

suite "golden":
  test "CSV matches Python byte for byte":
    let (db, dir) = goldenDb()
    defer: removeDir(dir)
    let cases = [
      ("blank.csv", blankCsv(db, none(int64))),
      ("blank_cat1.csv", blankCsv(db, some(1'i64))),
      ("blank_cat2.csv", blankCsv(db, some(2'i64))),
      ("blank_cat3.csv", blankCsv(db, some(3'i64))),
      ("blank_cat999.csv", blankCsv(db, some(999'i64))),
      ("printed.csv", printedCsv(db)),
    ]
    for (name, got) in cases:
      let want = readFile(GoldenDir / name)
      if got != want:
        checkpoint(name & " differs from Flask's output\n" & firstDiff(got, want))
        fail()
    db.close()

  test "stocklist matches Python (77 cases)":
    let (db, dir) = goldenDb()
    defer: removeDir(dir)
    let cases = parseJson(readFile(GoldenDir / "stocklist.json"))
    check cases.len >= 70
    let saved = stocklist.maxRows
    defer: stocklist.maxRows = saved
    for c in cases:
      var args: QueryArgs
      for kv in c["query"]:
        args.add (kv[0].getStr, kv[1].getStr)
      stocklist.maxRows = saved
      if c["max_rows"].kind != JNull:
        stocklist.maxRows = c["max_rows"].getInt
      let f = parseFilter(args)
      let gf = c["filter"]
      let catOk = (gf["category"].kind == JNull and f.category.isNone) or
                  (gf["category"].kind == JInt and f.category.isSome and
                   f.category.get == gf["category"].getInt)
      check catOk
      check f.style == gf["style"].getStr
      check f.color == gf["color"].getStr
      check f.size == gf["size"].getStr
      check f.q == gf["q"].getStr
      check f.inStock == gf["in_stock"].getBool
      check f.sort == gf["sort"].getStr
      check f.dir == gf["dir"].getStr
      let res = searchStock(db, f)
      check rowIds(res.rows) == c["ids"].mapIt(it.getBiggestInt)
      check res.count == c["count"].getInt
      check res.totalQty == c["total_qty"].getInt
      check res.truncated == c["truncated"].getBool
    db.close()

  test "options match Python":
    let (db, dir) = goldenDb()
    defer: removeDir(dir)
    let want = parseJson(readFile(GoldenDir / "options.json"))
    let got = db.listOptions()
    check got.styles == jsonStrs(want["styles"])
    check got.colors == jsonStrs(want["colors"])
    check got.sizes == jsonStrs(want["sizes"])
    check db.styleChoices() == jsonStrs(want["style_choices"])
    db.close()

# ---- 管理 (Go 版 admin_test.go の移植) ---------------------------------------------------

suite "admin users":
  test "createUser validations":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    for name in ["", " 　"]:
      check opCreateUser(db, name, "password123", "staff") ==
        "ユーザー名と、8文字以上のパスワードを入力してください。"
    # パスワードが短い → エラー。文字数 (バイト数ではない) で数える
    check opCreateUser(db, "new1", "あいうえおかき", "staff") ==
      "ユーザー名と、8文字以上のパスワードを入力してください。"
    check countRows(db, "\"user\"") == 2 # 失敗した作成が残っていない
    # 正常系: 前後の空白は除かれ、role の指定なし相当 ("x") はスタッフになる
    check opCreateUser(db, " new1 ", "あいうえおかきく", "x") == ""
    let u = db.getUserByName("new1").get
    check u.role == "staff" and u.isActive
    check u.passwordHash.startsWith("scrypt:")
    check verify(u.passwordHash, "あいうえおかきく")
    check opCreateUser(db, "boss", "password123", "admin") == ""
    check db.getUserByName("boss").get.isAdmin
    for dup in ["new1", "admin"]:
      check opCreateUser(db, dup, "password123", "staff") ==
        "そのユーザー名は既に使われています。"
    db.close()

  test "setUserActive and resetUserPassword":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    opSetUserActive(db, StaffId, false)
    check not db.getUser(StaffId).get.isActive
    opSetUserActive(db, StaffId, true)
    check db.getUser(StaffId).get.isActive
    check opResetUserPassword(db, StaffId, "short") ==
      "パスワードは8文字以上にしてください。"
    check opResetUserPassword(db, StaffId, "new-password") == ""
    check verify(db.getUser(StaffId).get.passwordHash, "new-password")
    db.close()

suite "admin categories and items":
  test "create and update category":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    let all = CategoryFlags(useColor: true, useSize: true,
                            useVariantName: true, isPrintable: true)
    check opCreateCategory(db, " ", all) == "カテゴリー名を入力してください。"
    check opCreateCategory(db, "ステッカー", all) == ""
    let cats = db.categories()
    check cats.len == 3
    # 表示順は追加前の件数 (初期データが2件あるので 2)
    check cats[2].name == "ステッカー" and cats[2].sortOrder == 2
    check opCreateCategory(db, "ステッカー", all) ==
      "同名のカテゴリーが既にあります。"
    let cat = cats[2]
    check opUpdateCategory(db, cat, "", 5, CategoryFlags()) == ""
    let updated = db.getCategory(cat.id).get
    check updated.name == "ステッカー" and updated.sortOrder == 5 and
          not updated.useColor
    check opUpdateCategory(db, cat, "Tシャツ", 0, CategoryFlags()) ==
      "同名のカテゴリーが既にあります。"
    db.close()

  test "flagsInUse":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    execSql(db, "INSERT INTO variant (item_id, color, size, variant_name, quantity) VALUES (1, '白', '', '', 3)")
    let cat = db.getCategory(1).get
    # 色を OFF → ブロックされる。サイズは値が無いので OFF にできる
    check db.flagsInUse(cat, CategoryFlags(useSize: true, isPrintable: true)) ==
      @["色"]
    execSql(db, "UPDATE variant SET size = 'M' WHERE item_id = 1")
    # サイズにも値が入れば、両方ブロックされる (順序は色・サイズ)
    check db.flagsInUse(cat, CategoryFlags(isPrintable: true)) == @["色", "サイズ"]
    check db.flagsInUse(cat, CategoryFlags(useColor: true, useSize: true)).len == 0
    execSql(db, "INSERT INTO variant (item_id, color, size, variant_name, quantity) VALUES (3, '', '', '星', 1)")
    let badgeCat = db.getCategory(2).get # バッジ: 種類名 ON
    check db.flagsInUse(badgeCat, CategoryFlags()) == @["種類名"]
    db.close()

  test "create and update item":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    check opCreateItem(db, 1, " ", "", "名前", "") ==
      "ブランドか品番のどちらかは入力してください。"
    # タイプが31文字 (文字数) → エラー。30文字は可
    check opCreateItem(db, 1, "B", "1", "", repeat("あ", MaxStyle + 1)) ==
      "タイプは30文字以内で入力してください。"
    check opCreateItem(db, 1, "B", "1", "", repeat("あ", MaxStyle)) == ""
    for (brand, itemNo) in [("Printstar", "085-CVT"), ("B", "1")]:
      check opCreateItem(db, 1, brand, itemNo, "", "") ==
        "同じカテゴリーに同じブランド・品番が既にあります。"
    check opCreateItem(db, 2, "Printstar", "085-CVT", "", "") == "" # 別カテゴリーならよい
    let id = itemIdByBrand(db, "B")
    let it = getItemOrFail(db, id)
    check opUpdateItem(db, id, "B2", "1", it.name, "", false) == ""
    let updated = getItemOrFail(db, id)
    check updated.brand == "B2" and not updated.isActive
    check opUpdateItem(db, id, "", "", "", "", true) ==
      "ブランドか品番のどちらかは入力してください。"
    db.close()

# ---- 認証 (Go 版 service/auth.go の規則) ---------------------------------------------------

suite "auth":
  test "authenticate":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    check opCreateUser(db, " alice ", "password123", "staff") == ""
    check db.authenticate("alice", "password123").isSome
    check db.authenticate(" alice ", "password123").isSome # ユーザー名は strip される
    check db.authenticate("alice", "password124").isNone
    check db.authenticate("nobody", "password123").isNone # ダミーハッシュで検証する経路
    check db.authenticate("admin", "password123").isNone # 壊れたハッシュ 'x' でも 500 にしない
    opSetUserActive(db, db.getUserByName("alice").get.id, false)
    check db.authenticate("alice", "password123").isNone # 停止中は入れない
    db.close()

  test "changePassword":
    let (db, dir) = newTestDb()
    defer: removeDir(dir)
    check opCreateUser(db, "alice", "password123", "staff") == ""
    let alice = db.getUserByName("alice").get
    let tokenBefore = alice.sessionToken("secret")
    var res = db.changePassword(alice.id, "wrong-old", "newpassword1", "newpassword1")
    check res.user.isNone and res.msg == MsgOldPasswordWrong
    res = db.changePassword(alice.id, "password123", "あいうえおかき", "あいうえおかき")
    check res.user.isNone and res.msg == MsgPasswordTooShort # 7文字は不可
    res = db.changePassword(alice.id, "password123", "newpassword1", "newpassword2")
    check res.user.isNone and res.msg == MsgConfirmMismatch
    res = db.changePassword(alice.id, "password123", "newpassword1", "newpassword1")
    check res.user.isSome and res.msg == ""
    check db.authenticate("alice", "newpassword1").isSome
    check db.authenticate("alice", "password123").isNone
    # パスワードが変わるとセッショントークンも変わる (既存セッションが無効になる)
    check res.user.get.sessionToken("secret") != tokenBefore
    db.close()

suite "session token":
  test "matches Python":
    let u1 = User(passwordHash: "scrypt:32768:8:1$AbCdEfGhIjKlMnOp$00ff")
    check u1.sessionToken("test-secret") == "c7c569a5fb9770027996"
    let u2 = User(passwordHash: "pbkdf2:sha256:1000000$salt$beef")
    check u2.sessionToken("日本語の鍵") == "bb5a9fa1d457cc9983c6"
    check User(passwordHash: "x").sessionToken("k") !=
          User(passwordHash: "y").sessionToken("k")
