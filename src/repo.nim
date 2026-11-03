## 読み取りクエリと表示用ラベル (Go 版 internal/repo の移植)。
## サービス層 (stock / stocklist / exportcsv / adminsvc / authsvc) が使う読み取りと、
## ユーザー参照・セッショントークンをここに置く。書き込みはサービス層の管轄。
##
## 「見つからない」は Go 版の nil に対応させて Option で返す。
## 数値列は db_sqlite が文字列で返すので parseBiggestInt で戻す。
## 列名は Flask 由来のスキーマそのまま (uses_color など)。

import std/[options, strutils]
import nimcrypto/[hmac, sha2, utils]
import db
import util

# ---- ユーザー ---------------------------------------------------------------------

type User* = object
  id*: int64
  username*: string
  passwordHash*: string
  role*: string
  isActive*: bool

proc isAdmin*(u: User): bool =
  u.role == "admin"


proc hasRow(row: Row): bool =
  ## db_sqlite の getRow は、行が無いとき空の Row ではなく「列数分の空文字」を
  ## 返す。先頭列 (id) が空かどうかで存在を見る。
  row.len > 0 and row[0] != ""

const userCols = "SELECT id, username, password_hash, role, is_active FROM \"user\""

proc toUser(row: Row): User =
  User(id: parseBiggestInt(row[0]), username: row[1], passwordHash: row[2],
       role: row[3], isActive: row[4] != "0")

proc getUserByName*(db: DbConn, username: string): Option[User] =
  let row = db.getRow(SqlQuery(userCols & " WHERE username = ?"), username)
  if not hasRow(row):
    return none(User)
  some(toUser(row))

proc getUser*(db: DbConn, id: int64): Option[User] =
  let row = db.getRow(SqlQuery(userCols & " WHERE id = ?"), id)
  if not hasRow(row):
    return none(User)
  some(toUser(row))

proc listUsers*(db: DbConn): seq[User] =
  for row in db.getAllRows(SqlQuery(userCols & " ORDER BY id")):
    result.add toUser(row)

proc sessionToken*(u: User, secret: string): string =
  ## パスワードハッシュに対する HMAC。パスワードを変えると既存セッションが
  ## 全て無効になる (Flask 版と同じ仕組み)。ページ表示時のユーザー取得 (手順3)
  ## がセッションと突き合わせるのに使う。
  let digest = hmac(sha256, secret, u.passwordHash)
  toLowerAscii(toHex(digest.data))[0 ..< 20]

# ---- 品目・バリエーション・プリント済み ----------------------------------------------

type Item* = object
  id*: int64
  categoryId*: int64
  brand*: string
  itemNo*: string
  name*: string
  style*: string
  isActive*: bool
  categoryName*: string
  useColor*: bool
  useSize*: bool
  useVariantName*: bool
  isPrintable*: bool

type Variant* = object
  id*: int64
  itemId*: int64
  color*: string
  size*: string
  variantName*: string
  quantity*: int64
  brand*: string
  itemNo*: string
  itemName*: string
  itemActive*: bool
  categoryId*: int64
  categoryName*: string
  categoryOrder*: int64
  isPrintable*: bool

type Product* = object
  id*: int64
  designId*: int64
  designName*: string
  variantId*: int64
  quantity*: int64
  color*: string
  size*: string
  variantName*: string
  itemId*: int64
  brand*: string
  itemNo*: string
  itemName*: string
  categoryName*: string
  categoryOrder*: int64

proc itemLabel*(brand, itemNo, name: string, id: int64): string =
  ## 「Printstar 085-CVT Tシャツ」。全て空なら "Item#<id>" (Flask 版 item_label)。
  var head: string
  if brand != "" and itemNo != "":
    head = brand & " " & itemNo
  elif brand != "":
    head = brand
  else:
    head = itemNo
  var label = head
  if name != "":
    if label != "":
      label.add " "
    label.add name
  label = pyStrip(label)
  if label == "":
    return "Item#" & $id
  label

proc itemLabel*(it: Item): string =
  itemLabel(it.brand, it.itemNo, it.name, it.id)

proc specOf*(variantName, color, size: string): string =
  ## 「種類名 / 色 / サイズ」。全て空なら "-" (Flask 版 spec_of)。
  var parts: seq[string]
  if variantName != "":
    parts.add variantName
  if color != "":
    parts.add color
  if size != "":
    parts.add size
  if parts.len == 0:
    return "-"
  parts.join(" / ")

proc spec*(v: Variant): string =
  specOf(v.variantName, v.color, v.size)

proc spec*(p: Product): string =
  specOf(p.variantName, p.color, p.size)

proc label*(v: Variant): string =
  itemLabel(v.brand, v.itemNo, v.itemName, v.itemId) & " | " & v.spec

proc label*(p: Product): string =
  p.designName & " | " & itemLabel(p.brand, p.itemNo, p.itemName, p.itemId) & " | " & p.spec

const itemCols = """
SELECT i.id, i.category_id, i.brand, i.item_no, i.name, i.style, i.is_active,
       c.name, c.uses_color, c.uses_size, c.uses_variant_name, c.is_printable
FROM item i JOIN category c ON c.id = i.category_id"""

proc toItem(row: Row): Item =
  Item(id: parseBiggestInt(row[0]), categoryId: parseBiggestInt(row[1]),
       brand: row[2], itemNo: row[3], name: row[4], style: row[5],
       isActive: row[6] != "0", categoryName: row[7],
       useColor: row[8] != "0", useSize: row[9] != "0",
       useVariantName: row[10] != "0", isPrintable: row[11] != "0")

proc listItems(db: DbConn, tail: string, args: varargs[string]): seq[Item] =
  for row in db.getAllRows(SqlQuery(itemCols & tail), args):
    result.add toItem(row)

proc getItem*(db: DbConn, id: int64): Option[Item] =
  let row = db.getRow(SqlQuery(itemCols & " WHERE i.id = ?"), id)
  if not hasRow(row):
    return none(Item)
  some(toItem(row))

const variantCols = """
SELECT v.id, v.item_id, v.color, v.size, v.variant_name, v.quantity,
       i.brand, i.item_no, i.name, i.is_active,
       i.category_id, c.name, c.sort_order, c.is_printable
FROM variant v
JOIN item i ON i.id = v.item_id
JOIN category c ON c.id = i.category_id"""

proc toVariant(row: Row): Variant =
  Variant(id: parseBiggestInt(row[0]), itemId: parseBiggestInt(row[1]),
          color: row[2], size: row[3], variantName: row[4],
          quantity: parseBiggestInt(row[5]), brand: row[6], itemNo: row[7],
          itemName: row[8], itemActive: row[9] != "0",
          categoryId: parseBiggestInt(row[10]), categoryName: row[11],
          categoryOrder: parseBiggestInt(row[12]), isPrintable: row[13] != "0")

proc listVariants(db: DbConn, tail: string, args: varargs[string]): seq[Variant] =
  for row in db.getAllRows(SqlQuery(variantCols & tail), args):
    result.add toVariant(row)

proc getVariant*(db: DbConn, id: int64): Option[Variant] =
  let row = db.getRow(SqlQuery(variantCols & " WHERE v.id = ?"), id)
  if not hasRow(row):
    return none(Variant)
  some(toVariant(row))

proc findVariant*(db: DbConn, itemId: int64, color, size,
                  variantName: string): Option[Variant] =
  let row = db.getRow(SqlQuery(variantCols &
    " WHERE v.item_id = ? AND v.color = ? AND v.size = ? AND v.variant_name = ?"),
    itemId, color, size, variantName)
  if not hasRow(row):
    return none(Variant)
  some(toVariant(row))

proc allVariants*(db: DbConn): seq[Variant] =
  ## 全バリエーション (CSV 出力用)。画面側の並びは呼び出し側で付ける。
  db.listVariants(" ORDER BY c.sort_order, i.brand, i.item_no, v.color, v.size")

const productCols = """
SELECT p.id, p.design_id, d.name, p.variant_id, p.quantity,
       v.color, v.size, v.variant_name, v.item_id,
       i.brand, i.item_no, i.name,
       c.name, c.sort_order
FROM printed_product p
JOIN design d ON d.id = p.design_id
JOIN variant v ON v.id = p.variant_id
JOIN item i ON i.id = v.item_id
JOIN category c ON c.id = i.category_id"""

proc toProduct(row: Row): Product =
  Product(id: parseBiggestInt(row[0]), designId: parseBiggestInt(row[1]),
          designName: row[2], variantId: parseBiggestInt(row[3]),
          quantity: parseBiggestInt(row[4]), color: row[5], size: row[6],
          variantName: row[7], itemId: parseBiggestInt(row[8]),
          brand: row[9], itemNo: row[10], itemName: row[11],
          categoryName: row[12], categoryOrder: parseBiggestInt(row[13]))

proc getProduct*(db: DbConn, id: int64): Option[Product] =
  let row = db.getRow(SqlQuery(productCols & " WHERE p.id = ?"), id)
  if not hasRow(row):
    return none(Product)
  some(toProduct(row))

proc products*(db: DbConn, text: string): seq[Product] =
  ## プリント済み商品の一覧。text が空でなければ各項目を部分一致で絞る。
  if text == "":
    for row in db.getAllRows(SqlQuery(productCols &
        " ORDER BY d.name, c.sort_order, i.brand, i.item_no, v.color, v.size")):
      result.add toProduct(row)
    return
  let like = "%" & text & "%"
  for row in db.getAllRows(SqlQuery(productCols & """
 WHERE d.name LIKE ? OR i.brand LIKE ? OR i.item_no LIKE ? OR i.name LIKE ? OR v.color LIKE ?
 ORDER BY d.name, c.sort_order, i.brand, i.item_no, v.color, v.size"""),
      like, like, like, like, like):
    result.add toProduct(row)

# ---- 在庫操作の対象 (バリエーション / プリント済み) ---------------------------------------

type
  TargetKind* = enum
    tkVariant, tkProduct

  Target* = object
    kind*: TargetKind
    id*: int64

proc target*(v: Variant): Target =
  Target(kind: tkVariant, id: v.id)

proc target*(p: Product): Target =
  Target(kind: tkProduct, id: p.id)

type TargetRow* = object
  ## フォームの対象パース結果。target.kind が指す側のフィールドだけ有効
  ## (Go 版はポインタで nil を表すところを、kind で判別する形にした)。
  target*: Target
  variant*: Variant
  product*: Product

proc label*(t: TargetRow): string =
  if t.target.kind == tkVariant:
    return t.variant.label
  t.product.label

proc getTarget*(db: DbConn, raw: string): Option[TargetRow] =
  ## フォームの "v:12" / "p:34" を対象に解決する。解釈できなければ none。
  let idx = raw.find(':')
  if idx < 0:
    return none(TargetRow)
  let (id, ok) = toInt(raw[idx + 1 .. ^1])
  if not ok:
    return none(TargetRow)
  case raw[0 ..< idx]
  of "v":
    let v = db.getVariant(id)
    if v.isNone:
      return none(TargetRow)
    return some(TargetRow(target: v.get.target, variant: v.get))
  of "p":
    let p = db.getProduct(id)
    if p.isNone:
      return none(TargetRow)
    return some(TargetRow(target: p.get.target, product: p.get))
  else:
    return none(TargetRow)

# ---- カテゴリー・選択肢などの読み取り ---------------------------------------------------

type Category* = object
  id*: int64
  name*: string
  sortOrder*: int64
  useColor*: bool
  useSize*: bool
  useVariantName*: bool
  isPrintable*: bool

const categoryCols =
  "SELECT id, name, sort_order, uses_color, uses_size, uses_variant_name, is_printable FROM category"

proc toCategory(row: Row): Category =
  Category(id: parseBiggestInt(row[0]), name: row[1],
           sortOrder: parseBiggestInt(row[2]), useColor: row[3] != "0",
           useSize: row[4] != "0", useVariantName: row[5] != "0",
           isPrintable: row[6] != "0")

proc categories*(db: DbConn): seq[Category] =
  for row in db.getAllRows(SqlQuery(categoryCols & " ORDER BY sort_order, id")):
    result.add toCategory(row)

proc getCategory*(db: DbConn, id: int64): Option[Category] =
  let row = db.getRow(SqlQuery(categoryCols & " WHERE id = ?"), id)
  if not hasRow(row):
    return none(Category)
  some(toCategory(row))

proc itemsForSelect*(db: DbConn): seq[Item] =
  ## 入荷画面などの選択肢 (有効な品番のみ)。
  db.listItems(" WHERE i.is_active = 1 ORDER BY c.sort_order, i.brand, i.item_no")

proc itemsInCategory*(db: DbConn, categoryId: int64, text: string): seq[Item] =
  ## カテゴリー内の有効な品番。text は brand / item_no / name の部分一致。
  var tail = " WHERE i.is_active = 1 AND i.category_id = ?"
  if text != "":
    tail.add " AND (i.brand LIKE ? OR i.item_no LIKE ? OR i.name LIKE ?)"
    let like = "%" & text & "%"
    return db.listItems(tail & " ORDER BY i.brand, i.item_no",
                        $categoryId, like, like, like)
  db.listItems(tail & " ORDER BY i.brand, i.item_no", $categoryId)

proc itemsAdmin*(db: DbConn, categoryId: int64): seq[Item] =
  ## 管理画面用 (無効な品番も含む)。categoryId = 0 で全カテゴリー。
  if categoryId != 0:
    return db.listItems(
      " WHERE i.category_id = ? ORDER BY c.sort_order, i.brand, i.item_no",
      $categoryId)
  db.listItems(" ORDER BY c.sort_order, i.brand, i.item_no")

proc variantsOfItem*(db: DbConn, itemId: int64): seq[Variant] =
  db.listVariants(" WHERE v.item_id = ? ORDER BY v.variant_name, v.color",
                  $itemId)

proc variantsInCategory*(db: DbConn, categoryId: int64): seq[Variant] =
  db.listVariants(" WHERE i.category_id = ? ORDER BY v.variant_name, v.color",
                  $categoryId)

proc printableVariantsInStock*(db: DbConn): seq[Variant] =
  db.listVariants(" WHERE c.is_printable = 1 AND v.quantity > 0 AND i.is_active = 1" &
                  " ORDER BY c.sort_order, i.brand, i.item_no, v.color, v.size")

proc usedColors*(db: DbConn): seq[string] =
  ## 履歴入力の色候補 (過去に使った色)。
  for row in db.getAllRows(sql"SELECT DISTINCT color FROM variant WHERE color <> '' ORDER BY color"):
    result.add row[0]

type Design* = object
  id*: int64
  name*: string
  note*: string

proc designs*(db: DbConn): seq[Design] =
  for row in db.getAllRows(sql"SELECT id, name, note FROM design ORDER BY name"):
    result.add Design(id: parseBiggestInt(row[0]), name: row[1], note: row[2])
