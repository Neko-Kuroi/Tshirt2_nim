## SQLite への接続、書き込みトランザクション、マイグレーションを扱う。
##
## Flask 版 app/db.py と app/schema.py、Go 版 internal/db に対応する。スキーマと
## PRAGMA user_version 方式は Flask 版と同一で、同じ inventory.db をそのまま
## 読み書きできる。
##
## Go 版との対応:
##   Open            → openDb (プールではなく接続を直接返す。PRAGMA は接続ごと)
##   Tx              → tx (例外でロールバック。Go の panic も例外として扱う)
##   Check           → checkDb
##   Migrate         → migrate
##   ForeignSchemaError → ForeignSchemaError (alembic フィールド付き)

import std/[os, random, strutils]

import db_connector/db_sqlite
from db_connector/sqlite3 import nil # 低レベル API は sqlite3.* で修飾して使う

import migrations

export db_sqlite # DbConn / DbError / getValue / getAllRows 等を上位層へそのまま出す

# ---- 実行ヘルパー ---------------------------------------------------------------

proc execSql*(db: DbConn, sqlText: string) =
  ## 複数文をまとめて実行する (結果行は捨てる)。
  ##
  ## db_sqlite の exec は prepare_v2 で先頭の文しか実行しないため、
  ## マイグレーションのような複数文の SQL は sqlite3_exec で流す必要がある。
  ## 引数の無い単文 (BEGIN / PRAGMA 等) もこちらに統一する。
  var errMsg: cstring = nil
  let rc = sqlite3.exec(db, sqlText.cstring, nil, nil, errMsg)
  if rc != sqlite3.SQLITE_OK:
    var msg = $sqlite3.errmsg(db)
    if not errMsg.isNil:
      msg = $errMsg
      sqlite3.free(errMsg)
    raise newException(DbError, msg)

# ---- 書き込みトランザクション (BEGIN IMMEDIATE + BUSY リトライ) -------------------

type DbBusyError = object of DbError
  ## tx の試行が SQLITE_BUSY で失敗したことを示す内部マーカー。
  ## DbError の一種なので、再試行し尽くした後は通常の DB エラーとして伝わる。

const BusyRetryLimit* = 5 # 再試行の回数 (初回と合わせて最大6回試す)
const BusyRetryBaseMs = 50
const BusyRetryMaxMs = 1000

var rngReady = false

proc jitterMs(maxIncl: int): int =
  if not rngReady:
    randomize()
    rngReady = true
  rand(maxIncl + 1)

proc isBusyErr(db: DbConn, e: ref Exception): bool =
  ## 直前の失敗が SQLITE_BUSY / SQLITE_LOCKED かを判定する。
  ##
  ## errcode は接続に残る直近のエラーコードなので、ROLLBACK より前に呼ぶこと。
  ## 主コード (下位バイト) が 5 / 6 のとき busy。DbError でない例外は対象外。
  ## errcode で判定できない場合の保険として、文言の "locked" でも拾う。
  if e of DbError:
    let code = sqlite3.errcode(db) and 0xFF
    if code == sqlite3.SQLITE_BUSY or code == sqlite3.SQLITE_LOCKED:
      return true
    return "locked" in e.msg.toLowerAscii
  false

proc retryOnBusy*[T](isBusy: proc (e: ref Exception): bool {.gcsafe.},
                     op: proc (): T {.gcsafe.}): T =
  ## op が busy エラーを返したら指数バックオフで再試行する。
  ##
  ## 1回あたりのロック待ちは busy_timeout (5秒) が既に吸収するので、ここは
  ## 「5秒待っても駄目だった」ときの保険。busy 以外のエラーはそのまま返す。
  var delay = BusyRetryBaseMs
  var attempt = 0
  while true:
    try:
      return op()
    except Exception as e:
      if not isBusy(e) or attempt >= BusyRetryLimit:
        raise
      # ジッターを付けて、待ち行列の全員が同じ瞬間に再挑戦しないようにする
      sleep(delay + jitterMs(delay div 2))
      delay = min(delay * 2, BusyRetryMaxMs)
      inc attempt

proc txOnce(db: DbConn, fn: proc () {.gcsafe.}) =
  var began = false
  var committed = false
  try:
    execSql(db, "BEGIN IMMEDIATE")
    began = true
    fn()
    execSql(db, "COMMIT")
    committed = true
  except Exception as e:
    let busy = isBusyErr(db, e) # ROLLBACK で errcode が消える前に判定する
    if began and not committed:
      # ロールバックは最善努力 (失敗しても元の例外を優先する)
      try:
        execSql(db, "ROLLBACK")
      except Exception:
        discard
    if busy:
      raise newException(DbBusyError, e.msg)
    raise

proc tx*(db: DbConn, fn: proc () {.gcsafe.}) =
  ## 書き込み用のトランザクション (Flask 版 transaction() の
  ## BEGIN IMMEDIATE ... COMMIT)。fn が例外を投げると全部ロールバックする。
  ##
  ## SQLITE_BUSY (他の書き込みが busy_timeout の5秒を超えて終わらない) のときは、
  ## 指数バックオフでトランザクション全体を再試行する。失敗した試行は
  ## ロールバック済みなので、fn の再実行は安全。別プロセスが同じ DB を
  ## 書いている間 (並行稼働や、サーバー稼働中の CLI 実行) でも、諦めずに
  ## 待てるようにするため。
  ##
  ## 注意: fn の中では、この接続だけを使うこと。別の接続を取ると、
  ## 書き込みロックを持つ自分自身を待つことになりうる。
  discard retryOnBusy(
    proc (e: ref Exception): bool = e of DbBusyError,
    proc (): int =
      txOnce(db, fn)
      0)

proc tx*[T](db: DbConn, fn: proc (): T {.gcsafe.}): T =
  ## 値を返す版の tx。
  var res: T
  tx(db, proc () = (res = fn()))
  res

proc openDb*(path: string): DbConn =
  ## ファイルを開く (無ければ作る)。「無ければ作らない」確認は checkDb を使う。
  ##
  ## PRAGMA は接続ごとの設定なので、接続を開くたびに適用する
  ## (Go 版は DSN で接続ごとに指定していた)。
  ##
  ## 順序が大事: busy_timeout を最初に効かせる。journal_mode の切替は排他が
  ## 必要で、他の接続が書き込み中の間は BUSY になるため、busy_timeout が
  ## 無い状態で実行すると即失敗する (並行オープンで実際に踏んだ)。
  ## 既に WAL のファイルでは切替自体を省く。
  let conn = open(path, "", "", "")
  execSql(conn, "PRAGMA busy_timeout=5000")
  execSql(conn, "PRAGMA foreign_keys=ON")
  if conn.getValue(sql"PRAGMA journal_mode") != "wal":
    discard retryOnBusy(
      proc (e: ref Exception): bool = isBusyErr(conn, e),
      proc (): int =
        execSql(conn, "PRAGMA journal_mode=WAL")
        0)
  conn

# ---- バージョンと状態 -------------------------------------------------------------

proc currentVersion*(db: DbConn): int =
  ## PRAGMA user_version (適用済みのスキーマ番号) を返す。
  let s = db.getValue(sql"PRAGMA user_version")
  if s.len == 0:
    0
  else:
    parseInt(s)

proc isCurrent*(version: int): bool =
  ## そのバージョンが最新のスキーマか (Flask 版 is_current と同じく >=)。
  version >= Migrations.len

type DbState* = enum
  ## 起動時の DB の状態 (Flask 版の「準備中」503画面の判定に相当)。
  dsMissing = "missing"   ## ファイルが無い (初回起動)
  dsOutdated = "outdated" ## スキーマが古い (migrate が必要)
  dsCurrent = "current"   ## 最新
  dsForeign = "foreign"   ## この版が作った DB ではない (SQLAlchemy 版など)。書き込まない

type ForeignSchemaError* = object of CatchableError
  ## この版が作ったものではないスキーマの DB を開いたことを表す。
  ##
  ## Flask 版には、SQLAlchemy + Alembic 版で作られた DB を引き継ぐ処理があるが、
  ## この版は引き継ぎを行わない (Go 版と同じ 2026-11-01 の決定)。user_version が
  ## 0 なのに表がある DB に v1 の CREATE TABLE を流すと中途半端に壊れるので、
  ## 書き込まずに止める。
  alembic*: bool ## alembic_version 表がある (= SQLAlchemy + Alembic 版で作られた DB)

proc foreignMessage(alembic: bool): string =
  if alembic:
    "SQLAlchemy 版で作成されたDBです。この版は対応していません。" &
      "Flask 版で user_version 方式へ移行してから使ってください"
  else:
    "user_version が未設定の既存DBです (この版が作ったDBではありません)。" &
      "Flask 版で user_version 方式へ移行してから使ってください"

proc tableExists(db: DbConn, name: string): bool =
  db.getValue(sql"SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
              name).len > 0

proc detectForeign(db: DbConn): ref ForeignSchemaError =
  ## user_version=0 の DB が、空 (新規) か、他の版が作った既存 DB かを調べる。
  ## 他版でなければ nil。
  let hasCategory = tableExists(db, "category")
  let hasAlembic = tableExists(db, "alembic_version")
  if hasCategory or hasAlembic:
    result = newException(ForeignSchemaError, foreignMessage(hasAlembic))
    result.alembic = hasAlembic

proc checkDb*(path: string): DbState =
  ## DB ファイルの状態を調べる。ファイルが無いときは、作らずに dsMissing を
  ## 返す (存在しないファイルに接続すると、空の DB が勝手に作られてしまうため)。
  if not fileExists(path):
    return dsMissing
  let db = openDb(path)
  defer: db.close()
  let v = currentVersion(db)
  if v == 0:
    if detectForeign(db) != nil:
      return dsForeign
  if isCurrent(v):
    dsCurrent
  else:
    dsOutdated

proc describeForeign*(path: string): ref ForeignSchemaError =
  ## dsForeign の DB について、どの種類の他版か (Alembic の記録があるか) を返す。
  ## 他版の DB でなければ nil。ファイルが無い・開けないときは例外。
  let db = openDb(path)
  defer: db.close()
  if currentVersion(db) != 0:
    return nil
  detectForeign(db)

# ---- マイグレーション ---------------------------------------------------------------

proc migrateWith*(db: DbConn, migs: seq[string]): int =
  ## migrate の本体 (テストでマイグレーション列を差し替えるために分けた)。
  ##
  ## 未適用のマイグレーションを順に適用し、最終的なバージョンを返す。
  ## 各版は1つのトランザクションで適用し、失敗したらその版の変更を全部取り消す。
  let v = currentVersion(db)
  if v == 0:
    let fe = detectForeign(db)
    if fe != nil:
      raise fe
  for n in v ..< migs.len:
    try:
      tx(db) do ():
        # 別プロセスが先に適用していないか、書き込みロックを取ってから確かめ直す
        if currentVersion(db) <= n:
          execSql(db, migs[n])
          execSql(db, "PRAGMA user_version=" & $(n + 1))
    except DbError as e:
      raise newException(DbError, "マイグレーション " & $(n + 1) & ": " & e.msg)
  currentVersion(db)

proc migrate*(db: DbConn): int =
  ## 未適用のマイグレーションを順に適用し、最終的なバージョンを返す。
  migrateWith(db, Migrations)
