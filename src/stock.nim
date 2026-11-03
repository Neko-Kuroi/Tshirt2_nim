## 在庫の書き込み (入荷・プリント変換・出荷・棚卸し調整)。Go 版
## internal/service/stock.go の移植。
##
## 呼び出し側が tx() で囲むこと。一連の操作は同じバッチ ID で stock_movement に
## 記録され、途中失敗で全部戻る。在庫が不足する更新は SQL の WHERE で弾き、
## 対象行が無ければ StockError にする (先読みしてから書く競合を避ける)。

import std/[options, strutils]
import nimcrypto/[sysrand, utils]
import db
import repo
import util

type StockError* = object of CatchableError
  ## 利用者向けの業務エラー (画面にそのまま出す文言を持つ)。

proc stockFail(msg: string) {.noreturn.} =
  raise newException(StockError, msg)

const
  KindReceive* = "receive"
  KindPrintUse* = "print_use"
  KindPrintOutput* = "print_output"
  KindShip* = "ship"
  KindAdjust* = "adjust"

const KindLabels* = [
  (KindReceive, "入荷"), (KindPrintUse, "プリント使用"),
  (KindPrintOutput, "プリント完成"), (KindShip, "出荷"),
  (KindAdjust, "棚卸し調整"),
]

proc kindLabel*(kind: string): string =
  for (k, label) in KindLabels:
    if k == kind:
      return label
  kind

proc formatQty*(n: int64): string =
  ## Python の f"{n:,}" (画面表示用)。
  let s = $n
  result = s
  var i = s.len - 3
  while i > 0:
    result = result[0 ..< i] & "," & result[i .. ^1]
    i -= 3

proc newUuid*(): string =
  ## UUID v4 (小文字)。バッチ ID 用。
  var b = newSeq[byte](16)
  if randomBytes(addr b[0], b.len) != b.len:
    raise newException(IOError, "uuid: cannot read random bytes")
  b[6] = (b[6] and 0x0f) or 0x40 # version 4
  b[8] = (b[8] and 0x3f) or 0x80 # variant 10
  let hex = toLowerAscii(toHex(b))
  hex[0 ..< 8] & "-" & hex[8 ..< 12] & "-" & hex[12 ..< 16] & "-" &
    hex[16 ..< 20] & "-" & hex[20 ..< 32]

proc apply(db: DbConn, target: Target, delta: int64) =
  ## 在庫数を delta だけ動かす。結果が負になる更新は対象行なしとして失敗する。
  let table = if target.kind == tkVariant: "variant" else: "printed_product"
  let changed = db.execAffectedRows(SqlQuery(
    "UPDATE " & table & " SET quantity = quantity + ?, updated_at = datetime('now')" &
    " WHERE id = ? AND quantity + ? >= 0"), delta, target.id, delta)
  if changed != 1:
    stockFail("在庫が足りません。")

proc logMovement(db: DbConn, batchId, kind: string, userId, delta: int64,
                 note: string, target: Target) =
  ## note は呼び出し側で画面入力をそのまま渡し、ここで pyStrip する (Go 版と同じ)。
  let memo = pyStrip(note)
  if target.kind == tkVariant:
    db.exec(sql"""INSERT INTO stock_movement
      (batch_id, kind, variant_id, delta, note, user_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, datetime('now'))""",
      batchId, kind, target.id, delta, memo, userId)
  else:
    db.exec(sql"""INSERT INTO stock_movement
      (batch_id, kind, printed_product_id, delta, note, user_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, datetime('now'))""",
      batchId, kind, target.id, delta, memo, userId)

proc positive(n: int64, label: string) =
  ## 数量の共通チェック (1 以上、MaxQty 以下)。文言は Flask 版の flash と一致。
  if n <= 0:
    stockFail(label & "は1以上の整数で入力してください。")
  if n > MaxQty:
    stockFail(label & "は" & formatQty(MaxQty) & "以下で入力してください。")

proc getOrCreateVariant*(db: DbConn, item: Item, colorIn, sizeIn,
                         variantNameIn: string): Variant =
  ## 色・サイズ・種類名をカテゴリー設定に合わせて正規化し (使わない列は空文字)、
  ## 既存行があればそれを、無ければ在庫0で作って返す。
  if not item.isActive:
    stockFail("この品番は使用停止中のため、入荷できません。")
  let color = if item.useColor: pyStrip(colorIn) else: ""
  let size = if item.useSize: pyStrip(sizeIn) else: ""
  let variantName = if item.useVariantName: pyStrip(variantNameIn) else: ""
  if item.useColor and color == "":
    stockFail("色を入力してください。")
  if item.useSize and size == "":
    stockFail("サイズを入力してください。")
  if item.useVariantName and variantName == "":
    stockFail("種類名を入力してください。")
  let found = db.findVariant(item.id, color, size, variantName)
  if found.isSome:
    return found.get
  let id = db.insertID(sql"""INSERT INTO variant
    (item_id, color, size, variant_name, quantity, updated_at)
    VALUES (?, ?, ?, ?, 0, datetime('now'))""",
    item.id, color, size, variantName)
  let created = db.getVariant(id)
  if created.isNone:
    raise newException(DbError, "stock: variant vanished after insert")
  created.get

proc getOrCreateDesign*(db: DbConn, name: string): int64 =
  let name = pyStrip(name)
  if name == "":
    stockFail("デザイン名を入力してください。")
  let row = db.getRow(sql"SELECT id FROM design WHERE name = ?", name)
  if row.len > 0 and row[0] != "": # getRow は行なしでも空文字の Row を返す
    return parseBiggestInt(row[0])
  db.insertID(sql"INSERT INTO design (name) VALUES (?)", name)

proc getOrCreateProduct*(db: DbConn, designId, variantId: int64): Product =
  let row = db.getRow(sql"SELECT id FROM printed_product WHERE design_id = ? AND variant_id = ?",
                      designId, variantId)
  if row.len > 0 and row[0] != "":
    let p = db.getProduct(parseBiggestInt(row[0]))
    if p.isNone:
      raise newException(DbError, "stock: product vanished")
    return p.get
  let id = db.insertID(sql"""INSERT INTO printed_product
    (design_id, variant_id, quantity, updated_at) VALUES (?, ?, 0, datetime('now'))""",
    designId, variantId)
  let p = db.getProduct(id)
  if p.isNone:
    raise newException(DbError, "stock: product vanished after insert")
  p.get

proc receive*(db: DbConn, userId: int64, v: Variant, qty: int64,
              note: string): string =
  ## 入荷 (対象はバリエーションのみ。Go 版 service.Receive と同じ)。バッチ ID を返す。
  positive(qty, "数量")
  let batch = newUuid()
  let target = v.target
  db.apply(target, qty)
  db.logMovement(batch, KindReceive, userId, qty, note, target)
  batch

proc ship*(db: DbConn, userId: int64, target: Target, qty: int64,
           note: string): string =
  ## 出荷。バッチ ID を返す。
  positive(qty, "数量")
  let batch = newUuid()
  db.apply(target, -qty)
  db.logMovement(batch, KindShip, userId, -qty, note, target)
  batch

proc adjust*(db: DbConn, userId: int64, target: Target, delta: int64,
             note: string): string =
  ## 棚卸し調整。delta は符号つき、理由必須。バッチ ID を返す。
  if delta == 0:
    stockFail("増減数は0以外の整数で入力してください。")
  if delta > MaxQty or delta < -MaxQty:
    stockFail("増減数は" & formatQty(MaxQty) & "以下で入力してください。")
  if pyStrip(note) == "":
    stockFail("棚卸し調整には理由を入力してください。")
  let batch = newUuid()
  db.apply(target, delta)
  db.logMovement(batch, KindAdjust, userId, delta, note, target)
  batch

proc convertToPrinted*(db: DbConn, userId: int64, v: Variant, designName: string,
                       used, output: int64, note: string): string =
  ## プリント変換: バリエーション在庫を used 減らし、完成品を output 増やす。
  ## チェック順と文言は Go 版 (元は Flask 版) と一致させる。バッチ ID を返す。
  positive(used, "使用数")
  if output < 0:
    stockFail("完成数は0以上の整数で入力してください。")
  if output > used:
    stockFail("完成数が使用数を超えています。")
  if not v.isPrintable:
    stockFail("このカテゴリーはプリント対象ではありません。")
  if not v.itemActive:
    stockFail("この品番は使用停止中のため、プリント変換できません。")
  let designId = db.getOrCreateDesign(designName)
  let batch = newUuid()
  let src = v.target
  db.apply(src, -used)
  db.logMovement(batch, KindPrintUse, userId, -used, note, src)
  if output > 0:
    let dst = db.getOrCreateProduct(designId, v.id).target
    db.apply(dst, output)
    db.logMovement(batch, KindPrintOutput, userId, output, note, dst)
  batch
