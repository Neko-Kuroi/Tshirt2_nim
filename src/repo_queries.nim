## 画面 (手順4) が使う読み取りクエリ集 (Go 版 internal/repo/queries.go のうち、
## ダッシュボード・履歴・備考ぶんの移植)。Flask 版 app/repo.py の残りに対応する。
## (カテゴリー・品番・バリエーションなどの既存の読み取りは repo.nim 側)
##
## SQL と並び順は Go 版と同一。「見つからない」は Option で返す。

import std/[options, strutils, tables]
import db
import repo

# ---- 履歴の種別ラベル ---------------------------------------------------------

const KindLabels* = [
  ("receive", "入荷"), ("print_use", "プリント使用"),
  ("print_output", "プリント完成"), ("ship", "出荷"), ("adjust", "棚卸し調整"),
]
  ## 履歴の種別の表示名 (Flask 版 models.KINDS)。並びは選択肢の表示順も兼ねる。

proc kindLabelOf*(kind: string): string =
  ## 種別の表示名。未知の種別はそのまま返す (Go 版 Movement.KindLabel と同じ)。
  for (k, label) in KindLabels:
    if k == kind:
      return label
  kind

proc isKnownKind*(kind: string): bool =
  for (k, _) in KindLabels:
    if k == kind:
      return true
  false

# ---- ダッシュボードの合計 -------------------------------------------------------

proc totals(db: DbConn, sqlText: string): Table[int64, int64] =
  result = initTable[int64, int64]()
  for row in db.getAllRows(SqlQuery(sqlText)):
    result[parseBiggestInt(row[0])] = parseBiggestInt(row[1])

proc blankTotals*(db: DbConn): Table[int64, int64] =
  ## カテゴリーごとの無地在庫の合計 (キーはカテゴリー ID)。
  db.totals("SELECT i.category_id, COALESCE(SUM(v.quantity), 0) AS total " &
            "FROM variant v JOIN item i ON i.id = v.item_id GROUP BY i.category_id")

proc printedTotals*(db: DbConn): Table[int64, int64] =
  ## カテゴリーごとのプリント済み在庫の合計 (キーはカテゴリー ID)。
  db.totals("SELECT i.category_id, COALESCE(SUM(p.quantity), 0) AS total " &
            "FROM printed_product p JOIN variant v ON v.id = p.variant_id " &
            "JOIN item i ON i.id = v.item_id GROUP BY i.category_id")

# ---- 履歴 -----------------------------------------------------------------------

type Movement* = object
  id*: int64
  itemId*: int64
  batchId*: string
  kind*: string
  delta*: int64
  note*: string
  createdAt*: string
  username*: string
  designName*: string
  brand*: string
  itemNo*: string
  itemName*: string
  color*: string
  size*: string
  variantName*: string

proc kindLabel*(m: Movement): string = kindLabelOf(m.kind)

proc targetLabel*(m: Movement): string =
  ## 「デザイン | ブランド 品番 商品名 | 種類名 / 色 / サイズ」(デザインはあれば)。
  let base = itemLabel(m.brand, m.itemNo, m.itemName, m.itemId) & " | " &
             specOf(m.variantName, m.color, m.size)
  if m.designName != "":
    return m.designName & " | " & base
  base

const movementSQL = """
SELECT m.id, m.batch_id, m.kind, m.delta, m.note, m.created_at, u.username,
       d.name AS design_name,
       i.id AS item_id, i.brand, i.item_no, i.name AS item_name,
       COALESCE(v.color, pv.color) AS color,
       COALESCE(v.size, pv.size) AS size,
       COALESCE(v.variant_name, pv.variant_name) AS variant_name
FROM stock_movement m
JOIN "user" u ON u.id = m.user_id
LEFT JOIN variant v ON v.id = m.variant_id
LEFT JOIN printed_product p ON p.id = m.printed_product_id
LEFT JOIN design d ON d.id = p.design_id
LEFT JOIN variant pv ON pv.id = p.variant_id
JOIN item i ON i.id = COALESCE(v.item_id, pv.item_id)
"""

proc toMovement(row: Row): Movement =
  Movement(id: parseBiggestInt(row[0]), batchId: row[1], kind: row[2],
           delta: parseBiggestInt(row[3]), note: row[4], createdAt: row[5],
           username: row[6], designName: row[7],
           itemId: parseBiggestInt(row[8]), brand: row[9], itemNo: row[10],
           itemName: row[11], color: row[12], size: row[13],
           variantName: row[14])

proc listMovements(db: DbConn, tail: string, args: varargs[string]): seq[Movement] =
  for row in db.getAllRows(SqlQuery(movementSQL & tail), args):
    result.add toMovement(row)

proc recentMovements*(db: DbConn, limit: int64): seq[Movement] =
  ## 直近の操作 (ダッシュボード用)。
  db.listMovements(" ORDER BY m.created_at DESC, m.id DESC LIMIT ?", $limit)

type MovementPage* = object
  items*: seq[Movement]
  page*: int64
  hasPrev*: bool
  hasNext*: bool
  prevNum*: int64
  nextNum*: int64

proc movementsPage*(db: DbConn, kind: string, page,
                    perPage: int64): MovementPage =
  ## 履歴の1ページ。kind が既知の種別なら絞り込む (未知の値は絞らない。
  ## Flask 版と同じ)。次ページの有無は perPage+1 件読んで判定する。
  var tail = ""
  var args: seq[string]
  if isKnownKind(kind):
    tail.add " WHERE m.kind = ?"
    args.add kind
  tail.add " ORDER BY m.created_at DESC, m.id DESC LIMIT ? OFFSET ?"
  args.add $(perPage + 1)
  args.add $((page - 1) * perPage)
  let all = db.listMovements(tail, args)
  let hasNext = all.len.int64 > perPage
  var items = all
  if hasNext:
    items.setLen(perPage.int)
  MovementPage(items: items, page: page, hasPrev: page > 1, hasNext: hasNext,
               prevNum: page - 1, nextNum: page + 1)

# ---- 備考 (item_note) --------------------------------------------------------------

type Note* = object
  id*: int64
  itemId*: int64
  target*: string
  body*: string
  isResolved*: bool
  createdAt*: string
  username*: string
  brand*: string
  itemNo*: string
  itemName*: string
  categoryId*: int64
  categoryName*: string

proc itemLabel*(n: Note): string =
  itemLabel(n.brand, n.itemNo, n.itemName, n.itemId)

const noteSQL = """
SELECT n.id, n.item_id, n.target, n.body, n.is_resolved, n.created_at, u.username,
       i.brand, i.item_no, i.name AS item_name, i.category_id, c.name AS category_name
FROM item_note n
JOIN "user" u ON u.id = n.user_id
JOIN item i ON i.id = n.item_id
JOIN category c ON c.id = i.category_id
"""

proc toNote(row: Row): Note =
  Note(id: parseBiggestInt(row[0]), itemId: parseBiggestInt(row[1]),
       target: row[2], body: row[3], isResolved: row[4] != "0",
       createdAt: row[5], username: row[6], brand: row[7], itemNo: row[8],
       itemName: row[9], categoryId: parseBiggestInt(row[10]),
       categoryName: row[11])

type NotesFilter* = object
  includeResolved*: bool
  itemId*: int64     ## 0 = 指定なし
  categoryId*: int64 ## 0 = 指定なし
  limit*: int64      ## 0 = 無制限

proc notes*(db: DbConn, f: NotesFilter): seq[Note] =
  var tail = " WHERE 1=1"
  var args: seq[string]
  if not f.includeResolved:
    tail.add " AND n.is_resolved = 0"
  if f.itemId != 0:
    tail.add " AND n.item_id = ?"
    args.add $f.itemId
  if f.categoryId != 0:
    tail.add " AND i.category_id = ?"
    args.add $f.categoryId
  tail.add " ORDER BY n.is_resolved, n.created_at DESC, n.id DESC"
  if f.limit != 0:
    tail.add " LIMIT ?"
    args.add $f.limit
  for row in db.getAllRows(SqlQuery(noteSQL & tail), args):
    result.add toNote(row)

proc getNote*(db: DbConn, noteId: int64): Option[int64] =
  ## 備考の item_id を返す (操作前の存在確認用)。無ければ none。
  let rows = db.getAllRows(
    SqlQuery("SELECT item_id FROM item_note WHERE id = ?"), $noteId)
  if rows.len == 0:
    return none(int64)
  some(parseBiggestInt(rows[0][0]))

proc openNoteCount*(db: DbConn): int64 =
  ## 未対応の備考の件数 (ダッシュボードのバッジ用)。
  parseBiggestInt(db.getValue(
    SqlQuery("SELECT COUNT(*) FROM item_note WHERE is_resolved = 0")))
