## DB 層のテスト。Go 版 internal/db/db_test.go (18件) と tx_retry_test.go の移植。
## フィクスチャ (tests/testdata) は書き換えない。DB は常に一時ディレクトリに作る
## (ゴールデン DB を使うときもコピーしてから開く)。
import std/[atomics, json, monotimes, os, sequtils, sets, strutils, tempfiles,
            times, unittest]

import db
import migrations

const ProjRoot = currentSourcePath.parentDir.parentDir
const GoldenDb = ProjRoot / "tests/testdata/golden/inventory.db"
const MigrationsJson = ProjRoot / "tests/testdata/db/migrations.json"
const SqlAlchemySql = ProjRoot / "tests/testdata/db/sqlalchemy_version_schema.sql"

proc newDb(): tuple[db: DbConn, path: string, dir: string] =
  let dir = createTempDir("tdb", "")
  let path = dir / "inventory.db"
  (openDb(path), path, dir)

proc scalarInt(db: DbConn, q: string): int =
  let s = db.getValue(SqlQuery(q))
  if s.len == 0:
    raise newException(ValueError, "no row: " & q)
  parseInt(s)

proc nameSet(db: DbConn, kind: string): HashSet[string] =
  result = initHashSet[string]()
  for row in db.getAllRows(sql"SELECT name FROM sqlite_master WHERE type=?", kind):
    result.incl row[0]

proc hasColumn(db: DbConn, table, col: string): bool =
  for row in db.getAllRows(sql"SELECT name FROM pragma_table_info(?)", table):
    if row[0] == col:
      return true
  false

proc atV1(db: DbConn) =
  execSql(db, Migrations[0])
  execSql(db, "PRAGMA user_version=1")

# ---- マイグレーション ---------------------------------------------------------

suite "migrations":
  test "migrations match Flask schema":
    let want = parseJson(readFile(MigrationsJson)).mapIt(it.getStr)
    check want.len == Migrations.len
    for i in 0 ..< want.len:
      check Migrations[i] == want[i]

  test "migrate fresh DB":
    let (db, _, dir) = newDb()
    defer: removeDir(dir)
    check migrate(db) == 3
    let tables = nameSet(db, "table")
    for n in ["user", "category", "item", "variant", "design",
              "printed_product", "stock_movement", "item_note"]:
      check n in tables
    let indexes = nameSet(db, "index")
    for n in ["ix_stock_movement_batch_id", "ix_stock_movement_created_at",
              "ix_item_note_item_id"]:
      check n in indexes
    check hasColumn(db, "item", "style") # マイグレーション3
    db.close()

  test "migrate is idempotent":
    let (db, _, dir) = newDb()
    defer: removeDir(dir)
    for i in 0 ..< 3:
      check migrate(db) == 3
    db.close()

  test "migrate from v1 copies old item notes":
    let (db, _, dir) = newDb()
    defer: removeDir(dir)
    atV1(db)
    execSql(db, """INSERT INTO "user"(id, username, password_hash) VALUES (5, 'a', 'x'), (7, 'b', 'x')""")
    execSql(db, "INSERT INTO category(id, name) VALUES (1, 'Tシャツ')")
    execSql(db, "INSERT INTO item(id, category_id, brand, item_no, note) VALUES (1, 1, 'P', '1', '旧メモ'), (2, 1, 'P', '2', '')")
    check migrate(db) == 3
    check scalarInt(db, "SELECT COUNT(*) FROM item_note") == 1 # 空の備考は引き継がない
    let row = db.getRow(sql"SELECT body, user_id FROM item_note")
    check row[0] == "旧メモ"
    check row[1] == "5" # 最小の user id
    check db.getValue(sql"SELECT style FROM item WHERE id=1") == ""
    db.close()

  test "migrate from v1 without users skips note copy":
    let (db, _, dir) = newDb()
    defer: removeDir(dir)
    atV1(db)
    execSql(db, "INSERT INTO category(id, name) VALUES (1, 'Tシャツ')")
    execSql(db, "INSERT INTO item(id, category_id, brand, item_no, note) VALUES (1, 1, 'P', '1', 'メモ')")
    discard migrate(db)
    check scalarInt(db, "SELECT COUNT(*) FROM item_note") == 0 # user が居ないので user_id を決められない
    db.close()

  test "failed migration is rolled back completely":
    let (db, _, dir) = newDb()
    defer: removeDir(dir)
    discard migrate(db)
    let migs = Migrations & @["CREATE TABLE half_done (x INTEGER);\nINSERT INTO no_such_table VALUES (1);"]
    expect DbError:
      discard migrateWith(db, migs)
    check currentVersion(db) == 3
    check "half_done" notin nameSet(db, "table")
    # 失敗のあとも接続は健全で、通常の書き込みができる
    tx(db) do ():
      execSql(db, "INSERT INTO category(name) VALUES ('after')")
    db.close()

  test "isCurrent":
    for (v, want) in [(0, false), (1, false), (2, false), (3, true), (4, true)]:
      check isCurrent(v) == want

  test "migrate from v2 adds style column and keeps data":
    let (db, _, dir) = newDb()
    defer: removeDir(dir)
    execSql(db, Migrations[0])
    execSql(db, "PRAGMA user_version=1")
    execSql(db, Migrations[1])
    execSql(db, "PRAGMA user_version=2")
    execSql(db, "INSERT INTO category (name, uses_size) VALUES ('Tシャツ', 1)")
    execSql(db, "INSERT INTO item (category_id, brand, item_no, name) VALUES (1, 'Printstar', '085', 'T')")
    check not hasColumn(db, "item", "style")
    check migrate(db) == 3
    let row = db.getRow(sql"SELECT brand, style FROM item")
    check row[0] == "Printstar"
    check row[1] == "" # 既存の品番はタイプ未設定
    check migrate(db) == 3 # 2回目は何も起きない
    db.close()

# ---- SQLAlchemy 版のDBは引き継がず、書き込まずに止める ---------------------------

proc sqlalchemyMadeDb(): tuple[db: DbConn, path: string, dir: string] =
  result = newDb()
  execSql(result.db, readFile(SqlAlchemySql))
  execSql(result.db, "INSERT INTO alembic_version VALUES ('afd0c4cd0c7c')")

suite "foreign schema":
  test "SQLAlchemy-made DB is refused without writing":
    let (db, path, dir) = sqlalchemyMadeDb()
    defer: removeDir(dir)
    let tablesBefore = nameSet(db, "table").len
    var caught: ref ForeignSchemaError = nil
    try:
      discard migrate(db)
    except ForeignSchemaError as e:
      caught = e
    check caught != nil
    check caught.alembic
    check "SQLAlchemy" in caught.msg
    check currentVersion(db) == 0 # 触っていない
    check nameSet(db, "table").len == tablesBefore
    check not hasColumn(db, "item", "style")
    db.close()
    check checkDb(path) == dsForeign

  test "existing DB without user_version is refused too":
    let (db, _, dir) = newDb()
    defer: removeDir(dir)
    execSql(db, "CREATE TABLE category (id INTEGER PRIMARY KEY, name TEXT)")
    var caught: ref ForeignSchemaError = nil
    try:
      discard migrate(db)
    except ForeignSchemaError as e:
      caught = e
    check caught != nil
    check not caught.alembic
    db.close()

# ---- 起動時の状態 (旧503画面の判定) ------------------------------------------------

suite "checkDb":
  test "missing does not create the file":
    let dir = createTempDir("tdb", "")
    defer: removeDir(dir)
    let path = dir / "nope.db"
    check checkDb(path) == dsMissing
    check not fileExists(path)
    check not fileExists(path & "-wal")
    check not fileExists(path & "-shm")

  test "outdated then current":
    let (db, path, dir) = newDb()
    defer: removeDir(dir)
    atV1(db)
    check checkDb(path) == dsOutdated
    discard migrate(db)
    check checkDb(path) == dsCurrent
    db.close()

  test "empty file is outdated, not foreign":
    let dir = createTempDir("tdb", "")
    defer: removeDir(dir)
    let path = dir / "empty.db"
    writeFile(path, "")
    check checkDb(path) == dsOutdated

  test "garbage file is an error and left alone":
    let dir = createTempDir("tdb", "")
    defer: removeDir(dir)
    let path = dir / "garbage.db"
    let content = repeat("this is not a sqlite database\n", 200)
    writeFile(path, content)
    expect DbError:
      discard checkDb(path)
    check readFile(path) == content

  test "golden DB (Flask-made) is current":
    let dir = createTempDir("tdb", "")
    defer: removeDir(dir)
    let path = dir / "inventory.db"
    copyFile(GoldenDb, path)
    check checkDb(path) == dsCurrent
    let db = openDb(path)
    check currentVersion(db) == 3
    db.close()

# ---- 接続設定とトランザクション -----------------------------------------------------

suite "connections and tx":
  test "foreign keys, WAL, busy_timeout on every connection":
    let (db, path, dir) = newDb()
    defer: removeDir(dir)
    discard migrate(db)
    db.close()
    var conns: seq[DbConn]
    for i in 0 ..< 3: # 別々の接続を同時に確保する
      conns.add openDb(path)
    for i, c in conns:
      check scalarInt(c, "PRAGMA foreign_keys") == 1
      check c.getValue(sql"PRAGMA journal_mode") == "wal"
      check scalarInt(c, "PRAGMA busy_timeout") == 5000
      var msg = ""
      try:
        execSql(c, "INSERT INTO item(category_id, brand) VALUES (999, 'x')")
      except DbError as e:
        msg = e.msg
      check "FOREIGN KEY" in msg.toUpperAscii
      c.close()

  test "tx commit, rollback on exception, value passthrough":
    let (db, _, dir) = newDb()
    defer: removeDir(dir)
    execSql(db, "CREATE TABLE t (n INTEGER)")
    tx(db) do ():
      execSql(db, "INSERT INTO t VALUES (1)")
    check scalarInt(db, "SELECT COUNT(*) FROM t") == 1
    var boomMsg = ""
    try:
      tx(db) do ():
        execSql(db, "INSERT INTO t VALUES (1)")
        raise newException(ValueError, "boom")
    except ValueError as e:
      boomMsg = e.msg
    check boomMsg == "boom"
    check scalarInt(db, "SELECT COUNT(*) FROM t") == 1
    let v = tx(db, proc (): int =
      execSql(db, "INSERT INTO t VALUES (1)")
      7)
    check v == 7
    check scalarInt(db, "SELECT COUNT(*) FROM t") == 2 # 例外のあとも使える
    db.close()

  test "check constraints are enforced":
    let (db, _, dir) = newDb()
    defer: removeDir(dir)
    discard migrate(db)
    execSql(db, "INSERT INTO category(id, name) VALUES (1, 'Tシャツ')")
    execSql(db, "INSERT INTO item(id, category_id, brand) VALUES (1, 1, 'x')")
    var msg = ""
    try:
      execSql(db, "INSERT INTO variant (item_id, quantity) VALUES (1, -1)") # マイナス在庫
    except DbError as e:
      msg = e.msg
    check "CHECK" in msg.toUpperAscii
    execSql(db, "INSERT INTO variant (item_id, color, size, variant_name, quantity) VALUES (1, '黒', 'M', '', 0)")
    msg = ""
    try:
      execSql(db, "INSERT INTO variant (item_id, color, size, variant_name, quantity) VALUES (1, '黒', 'M', '', 0)")
    except DbError as e:
      msg = e.msg
    check "UNIQUE" in msg.toUpperAscii
    db.close()

# ---- 同時書き込み (スレッド) ----------------------------------------------------------

var gPathBuf: array[1024, char]
var gPathLen: int
var okCount: Atomic[int]
var errCount: Atomic[int]

proc setTestPath(p: string) =
  gPathLen = min(p.len, gPathBuf.len)
  if gPathLen > 0:
    copyMem(addr gPathBuf[0], unsafeAddr p[0], gPathLen)

proc testPath(): string =
  result = newString(gPathLen)
  if gPathLen > 0:
    copyMem(addr result[0], addr gPathBuf[0], gPathLen)

proc writerWorker(_: int) {.thread.} =
  try:
    let db = openDb(testPath())
    for i in 0 ..< 25:
      tx(db) do ():
        let n = scalarInt(db, "SELECT n FROM counter")
        sleep(1) # 読んでから書くまでの間に、他の書き込みが割り込もうとする状況を作る
        execSql(db, "UPDATE counter SET n = " & $(n + 1))
      discard okCount.fetchAdd(1)
    db.close()
  except Exception:
    discard errCount.fetchAdd(1)

suite "concurrent writers":
  test "tx serializes concurrent writers (8 threads x 25)":
    let (db, path, dir) = newDb()
    defer: removeDir(dir)
    execSql(db, "CREATE TABLE counter (n INTEGER)")
    execSql(db, "INSERT INTO counter VALUES (0)")
    db.close()
    setTestPath(path)
    okCount.store(0)
    errCount.store(0)
    var threads: array[8, Thread[int]]
    for i in 0 ..< 8:
      createThread(threads[i], writerWorker, i)
    for i in 0 ..< 8:
      joinThread(threads[i])
    check errCount.load() == 0
    check okCount.load() == 200
    let db2 = openDb(path)
    check scalarInt(db2, "SELECT n FROM counter") == 200 # lost update が無い
    db2.close()

# ---- BUSY リトライ -----------------------------------------------------------------

type StubBusyError = object of CatchableError
type StubOtherError = object of CatchableError

proc stubIsBusy(e: ref Exception): bool = e of StubBusyError

suite "retryOnBusy":
  test "succeeds after retries":
    var calls = 0
    let r = retryOnBusy(stubIsBusy, proc (): int =
      inc calls
      if calls <= 3:
        raise newException(StubBusyError, "stub: database is locked")
      42)
    check r == 42
    check calls == 4

  test "gives up after the limit":
    var calls = 0
    var caught = false
    try:
      discard retryOnBusy(stubIsBusy, proc (): int =
        inc calls
        raise newException(StubBusyError, "stub: database is locked"))
    except StubBusyError:
      caught = true
    check caught
    check calls == BusyRetryLimit + 1

  test "does not retry other errors":
    var calls = 0
    var caught = false
    try:
      discard retryOnBusy(stubIsBusy, proc (): int =
        inc calls
        raise newException(StubOtherError, "constraint failed"))
    except StubOtherError:
      caught = true
    check caught
    check calls == 1

# ---- 外部ロックの統合テスト -----------------------------------------------------------

var lockStatus: Atomic[int] # 0=未完 1=成功 2=失敗
var lockElapsedMs: Atomic[int]

proc waiterWorker(_: int) {.thread.} =
  let t0 = getMonoTime()
  var status = 1
  try:
    let db = openDb(testPath())
    tx(db) do ():
      execSql(db, "UPDATE counter SET n = n + 1")
    db.close()
  except Exception:
    status = 2
  lockElapsedMs.store(int((getMonoTime() - t0).inMilliseconds))
  lockStatus.store(status)

suite "external lock":
  test "tx waits out an external lock held past busy_timeout":
    # 別ハンドル (別プロセス相当) が書き込みロックを busy_timeout (5秒) より
    # 長く保持しても、Tx がリトライで最終的に成功することを見る。
    # 5秒超の保持が要るため、このテスト自体も6秒ほどかかる。
    let (db, path, dir) = newDb()
    defer: removeDir(dir)
    execSql(db, "CREATE TABLE counter (n INTEGER)")
    execSql(db, "INSERT INTO counter VALUES (0)")
    setTestPath(path)
    lockStatus.store(0)
    execSql(db, "BEGIN IMMEDIATE")
    execSql(db, "UPDATE counter SET n = n + 1")
    var th: Thread[int]
    createThread(th, waiterWorker, 0)
    sleep(5500)
    execSql(db, "COMMIT")
    joinThread(th)
    check lockStatus.load() == 1
    check lockElapsedMs.load() >= 5000 # ロックを待ち切ったはず
    check scalarInt(db, "SELECT n FROM counter") == 2
    db.close()
