## 在庫一覧の検索・並べ替え (Go 版 internal/service/stocklist.go の移植)。
##
## 元は Flask 版の一覧画面。データは1クエリで取り、並べ替えと「空欄は最後」は
## メモリ側で行う (SQL の ORDER BY では Flask の size_key や空欄最後を表せない)。
## 取得は variant テーブル中心: 数量0の行も、存在するバリエーションは全て出す。

import std/[algorithm, options, sequtils, sets, strutils]
import db_connector/db_sqlite as sqlite_low # finalize の修飾用
import db
import repo
import util

const
  MaxText* = 100 # テキスト条件の最大長 (コードポイント)
  DefaultSort* = "category"

var maxRows* = 2000 ## 表示する最大行数 (テストが差し替えるので var)

const DefaultStyles* = ["半袖", "長袖"]

type SortKey* = object
  value*, label*: string

const SortKeys*: array[6, SortKey] = [
  SortKey(value: "category", label: "カテゴリー"),
  SortKey(value: "style", label: "タイプ"),
  SortKey(value: "item", label: "品番"),
  SortKey(value: "color", label: "色・種類"),
  SortKey(value: "size", label: "サイズ"),
  SortKey(value: "qty", label: "数量"),
]

proc validSort(s: string): bool =
  for k in SortKeys:
    if k.value == s:
      return true
  false

type Filter* = object
  ## URL クエリから解釈した検索条件。
  category*: Option[int64]
  style*: string
  color*: string
  size*: string
  q*: string
  inStock*: bool
  sort*: string
  dir*: string

type QueryArgs* = seq[(string, string)]
  ## URL クエリの (キー, 値) 列。同名キーの重複と順序を保つ (最初の値が勝つ)。

proc getFirst(args: QueryArgs, name: string): string =
  for (k, v) in args:
    if k == name:
      return v
  ""

proc parseFilter*(args: QueryArgs): Filter =
  ## 未知の値・解釈できない値は既定に落とす (Go 版 ParseFilter と同じ)。
  proc text(name: string): string =
    truncateRunes(pyStrip(args.getFirst(name)), MaxText)
  result.style = text("style")
  result.color = text("color")
  result.size = text("size")
  result.q = text("q")
  let (cat, ok) = toInt(args.getFirst("category"))
  if ok:
    result.category = some(cat)
  result.inStock = args.getFirst("in_stock") == "1"
  result.sort = args.getFirst("sort")
  if not validSort(result.sort):
    result.sort = DefaultSort
  result.dir = args.getFirst("dir")
  if result.dir != "desc":
    result.dir = "asc"

proc likePattern*(q: string): string =
  ## LIKE のメタ文字をエスケープする (クエリ側は ESCAPE '\' を付ける)。
  ## Go 版では非公開だが、テストから検証するため公開する。
  "%" & q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") & "%"

type StockRow* = object
  variantId*: int64
  itemId*: int64
  categoryId*: int64
  brand*: string
  itemNo*: string
  itemName*: string
  style*: string
  itemActive*: bool
  categoryName*: string
  categoryOrder*: int
  color*: string
  size*: string
  variantName*: string
  quantity*: int64

proc itemLabel*(r: StockRow): string =
  repo.itemLabel(r.brand, r.itemNo, r.itemName, r.itemId)

proc itemKey*(r: StockRow): string =
  r.brand & "|" & r.itemNo & "|" & r.itemName

proc spec*(r: StockRow): string =
  ## 色・種類の列表示 (サイズは含まない)。
  var parts: seq[string]
  if r.variantName != "":
    parts.add r.variantName
  if r.color != "":
    parts.add r.color
  parts.join(" / ")

proc fetchStockRows(db: DbConn, f: Filter): seq[StockRow] =
  var conds: seq[string]
  var args: seq[string]
  if f.category.isSome:
    conds.add "i.category_id = ?"
    args.add $f.category.get
  if f.style != "":
    conds.add "i.style = ?"
    args.add f.style
  if f.color != "":
    conds.add "(v.color = ? OR v.variant_name = ?)"
    args.add f.color
    args.add f.color
  if f.size != "":
    conds.add "v.size = ?"
    args.add f.size
  if f.inStock:
    conds.add "v.quantity > 0"
  if f.q != "":
    conds.add "(i.brand LIKE ? ESCAPE '\\' OR i.item_no LIKE ? ESCAPE '\\' OR i.name LIKE ? ESCAPE '\\')"
    let p = likePattern(f.q)
    args.add p
    args.add p
    args.add p
  var q = """
SELECT v.id, v.item_id, i.category_id, i.brand, i.item_no, i.name, i.style, i.is_active,
       c.name, c.sort_order, v.color, v.size, v.variant_name, v.quantity
FROM variant v
JOIN item i ON i.id = v.item_id
JOIN category c ON c.id = i.category_id"""
  if conds.len > 0:
    q.add "\nWHERE " & conds.join(" AND ")
  q.add "\nORDER BY c.sort_order, i.brand, i.item_no, v.color, v.size"
  # 条件の数が動的なので、prepared statement に bindParam で渡す。
  # 文字列への埋め込み (dbFormat) と違い、NUL を含む入力でも壊れない
  # (Go 版がドライバーのパラメータバインドで処理しているのと同じ)。
  let ps = db.prepare(q)
  for i, a in args:
    ps.bindParam(i + 1, a)
  let rawRows = db.getAllRows(ps)
  sqlite_low.finalize(ps)
  for row in rawRows:
    result.add StockRow(
      variantId: parseBiggestInt(row[0]), itemId: parseBiggestInt(row[1]),
      categoryId: parseBiggestInt(row[2]), brand: row[3], itemNo: row[4],
      itemName: row[5], style: row[6], itemActive: row[7] != "0",
      categoryName: row[8], categoryOrder: parseInt(row[9]), color: row[10],
      size: row[11], variantName: row[12], quantity: parseBiggestInt(row[13]))

proc defaultCmp(a, b: StockRow): int =
  ## 一覧の既定の並び (カテゴリー順 → ブランド → 品番 → 色 → 種類 → サイズ自然順)。
  result = cmp(a.categoryOrder, b.categoryOrder)
  if result != 0: return
  result = cmp(a.categoryId, b.categoryId)
  if result != 0: return
  result = cmp(a.brand, b.brand)
  if result != 0: return
  result = cmp(a.itemNo, b.itemNo)
  if result != 0: return
  result = cmp(a.itemId, b.itemId)
  if result != 0: return
  result = cmp(a.color, b.color)
  if result != 0: return
  result = cmp(a.variantName, b.variantName)
  if result != 0: return
  result = cmp(makeSizeKey(a.size), makeSizeKey(b.size))

proc isBlank(key: string, r: StockRow): bool =
  ## 空欄判定 (空欄の行は主キーの値が無いので、昇順・降順とも最後に置く)。
  case key
  of "style": r.style == ""
  of "item": r.brand == "" and r.itemNo == ""
  of "color": r.color == "" and r.variantName == ""
  of "size": r.size == ""
  else: false

proc colorOrName(r: StockRow): string =
  ## 色ソートの主キー: 色があれば色、無ければ種類名 (Go 版 colorOrName)。
  if r.color != "":
    return r.color
  r.variantName

proc primaryCmp(key: string, a, b: StockRow): int =
  case key
  of "category":
    result = cmp(a.categoryOrder, b.categoryOrder)
    if result == 0:
      result = cmp(a.categoryId, b.categoryId)
  of "style":
    result = cmp(a.style, b.style)
  of "item":
    result = cmp(a.brand, b.brand)
    if result == 0:
      result = cmp(a.itemNo, b.itemNo)
  of "color":
    result = cmp(colorOrName(a), colorOrName(b))
  of "size":
    result = cmp(makeSizeKey(a.size), makeSizeKey(b.size))
  of "qty":
    result = cmp(a.quantity, b.quantity)
  else:
    result = 0

proc sortRows*(rows: seq[StockRow], f: Filter): seq[StockRow] =
  ## 決まった手順で並べ替える (Flask 版と同じ):
  ## まず既定順にし、主キーで安定ソート。空欄 (主キーの値が空) は方向に
  ## かかわらず最後に回す。安定性は「既定順での位置」をタイブレークに使って
  ## 保証する (ソートアルゴリズムの安定性には依存しない)。
  var indexed = newSeq[(StockRow, int)](rows.len)
  for i, r in rows:
    indexed[i] = (r, i)
  indexed.sort do (a, b: (StockRow, int)) -> int:
    let c = defaultCmp(a[0], b[0])
    if c != 0: c else: cmp(a[1], b[1])
  for k in 0 ..< indexed.len:
    indexed[k] = (indexed[k][0], k) # 第2段のタイブレークは「既定順での位置」
  var present, blank: seq[(StockRow, int)]
  for it in indexed:
    if isBlank(f.sort, it[0]):
      blank.add it
    else:
      present.add it
  let dirSign = if f.dir == "desc": -1 else: 1
  present.sort do (a, b: (StockRow, int)) -> int:
    let c = primaryCmp(f.sort, a[0], b[0]) * dirSign
    if c != 0: c else: cmp(a[1], b[1])
  result = newSeqOfCap[StockRow](rows.len)
  for it in present:
    result.add it[0]
  for it in blank:
    result.add it[0]

type StockListResult* = object
  rows*: seq[StockRow]
  count*: int     # 上限で切る前の全件数
  totalQty*: int64 # 上限で切る前の数量合計
  truncated*: bool

proc searchStock*(db: DbConn, f: Filter): StockListResult =
  let rows = fetchStockRows(db, f)
  result.count = rows.len
  for r in rows:
    result.totalQty += r.quantity
  var sorted = sortRows(rows, f)
  if sorted.len > maxRows:
    result.truncated = true
    sorted.setLen(maxRows)
  result.rows = sorted

type ListOptions* = object
  ## フィルターのセレクトボックス用。
  styles*: seq[string]
  colors*: seq[string]
  sizes*: seq[string]

proc listOptions*(db: DbConn): ListOptions =
  for row in db.getAllRows(sql"SELECT DISTINCT style FROM item WHERE style <> '' ORDER BY style"):
    result.styles.add row[0]
  for row in db.getAllRows(sql"""
SELECT color AS v FROM variant WHERE color <> ''
UNION SELECT variant_name FROM variant WHERE variant_name <> ''
ORDER BY v"""):
    result.colors.add row[0]
  var sizes: seq[string]
  for row in db.getAllRows(sql"SELECT DISTINCT size FROM variant WHERE size <> ''"):
    sizes.add row[0]
  var keyed = newSeq[(SizeKey, int, string)](sizes.len)
  for i, s in sizes:
    keyed[i] = (makeSizeKey(s), i, s)
  keyed.sort do (a, b: (SizeKey, int, string)) -> int:
    let c = cmp(a[0], b[0])
    if c != 0: c else: cmp(a[1], b[1])
  for k in keyed:
    result.sizes.add k[2]

proc styleChoices*(db: DbConn): seq[string] =
  ## タイプの候補: 既定 (半袖・長袖) と実データの和集合をソートしたもの。
  var set = initHashSet[string]()
  for s in DefaultStyles:
    set.incl s
  for s in db.listOptions().styles:
    set.incl s
  result = toSeq(set)
  result.sort()
