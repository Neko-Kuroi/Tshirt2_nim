## 管理画面の書き込み (カテゴリー・品番・ユーザー)。Go 版 internal/service/admin.go
## の移植。業務エラーは AdminError (文言は Flask 版と一致)。
##
## 一意制約違反は「同名が既にある」に読み替える。それ以外の DB エラー
## (NOT NULL 違反など内部エラー) を重複と誤報しないよう、エラー文字列で
## "unique constraint" を含むかで判定する (Go 版 isUniqueViolation と同じ)。

import std/strutils
import db
import passwords
import repo
import util

type AdminError* = object of CatchableError

proc adminFail(msg: string) {.noreturn.} =
  raise newException(AdminError, msg)

proc isUniqueViolation(e: ref Exception): bool =
  e != nil and "unique constraint" in e.msg.toLowerAscii()

type CategoryFlags* = object
  useColor*: bool
  useSize*: bool
  useVariantName*: bool
  isPrintable*: bool

proc createCategory*(db: DbConn, name: string, flags: CategoryFlags): int64 =
  let name = pyStrip(name)
  if name == "":
    adminFail("カテゴリー名を入力してください。")
  # 並び順は末尾 (現在の件数) にする。画面で並べ替える前提。
  let order = parseBiggestInt(db.getValue(sql"SELECT COUNT(*) FROM category"))
  try:
    return db.insertID(sql"""INSERT INTO category
      (name, sort_order, uses_color, uses_size, uses_variant_name, is_printable)
      VALUES (?, ?, ?, ?, ?, ?)""",
      name, order, ord(flags.useColor), ord(flags.useSize),
      ord(flags.useVariantName), ord(flags.isPrintable))
  except DbError as e:
    if isUniqueViolation(e):
      adminFail("同名のカテゴリーが既にあります。")
    raise

proc flagsInUse*(db: DbConn, cat: Category, flags: CategoryFlags): seq[string] =
  ## カテゴリー設定で OFF にしようとした列のうち、値が入ったバリエーションが
  ## ある列の表示名 (「色」「サイズ」「種類名」) を返す。画面が確認を出すために
  ## 使う (更新自体は止めない)。順序は色・サイズ・種類名で固定。
  let checks = [
    (cat.useColor, flags.useColor, "color", "色"),
    (cat.useSize, flags.useSize, "size", "サイズ"),
    (cat.useVariantName, flags.useVariantName, "variant_name", "種類名"),
  ]
  for (was, now, col, label) in checks:
    if was and not now:
      let n = parseBiggestInt(db.getValue(SqlQuery(
        "SELECT COUNT(*) FROM variant v JOIN item i ON i.id = v.item_id" &
        " WHERE i.category_id = ? AND v." & col & " <> ''"), cat.id))
      if n > 0:
        result.add label

proc updateCategory*(db: DbConn, cat: Category, name: string, sortOrder: int,
                     flags: CategoryFlags) =
  var name = pyStrip(name)
  if name == "":
    name = cat.name # 名前欄を空にして送ったら、名前は変えない
  try:
    db.exec(sql"""UPDATE category SET name = ?, sort_order = ?, uses_color = ?,
      uses_size = ?, uses_variant_name = ?, is_printable = ? WHERE id = ?""",
      name, sortOrder, ord(flags.useColor), ord(flags.useSize),
      ord(flags.useVariantName), ord(flags.isPrintable), cat.id)
  except DbError as e:
    if isUniqueViolation(e):
      adminFail("同名のカテゴリーが既にあります。")
    raise

const MaxStyle* = 30 # タイプの最大長 (コードポイント。Flask 版 STYLE_MAX_LENGTH)

proc checkItemFields(brand, itemNo, style: string) =
  if brand == "" and itemNo == "":
    adminFail("ブランドか品番のどちらかは入力してください。")
  if runeCount(style) > MaxStyle:
    adminFail("タイプは30文字以内で入力してください。")

proc createItem*(db: DbConn, categoryId: int64, brand, itemNo, name,
                 style: string): int64 =
  let brand = pyStrip(brand)
  let itemNo = pyStrip(itemNo)
  let name = pyStrip(name)
  let style = pyStrip(style)
  checkItemFields(brand, itemNo, style)
  try:
    return db.insertID(sql"""INSERT INTO item
      (category_id, brand, item_no, name, style, note, is_active)
      VALUES (?, ?, ?, ?, ?, '', 1)""",
      categoryId, brand, itemNo, name, style)
  except DbError as e:
    if isUniqueViolation(e):
      adminFail("同じカテゴリーに同じブランド・品番が既にあります。")
    raise

proc updateItem*(db: DbConn, itemId: int64, brand, itemNo, name, style: string,
                 isActive: bool) =
  ## カテゴリーは変えない (Go 版 service.UpdateItem と同じ)。
  let brand = pyStrip(brand)
  let itemNo = pyStrip(itemNo)
  let name = pyStrip(name)
  let style = pyStrip(style)
  checkItemFields(brand, itemNo, style)
  try:
    db.exec(sql"""UPDATE item SET brand = ?, item_no = ?, name = ?, style = ?,
      is_active = ? WHERE id = ?""",
      brand, itemNo, name, style, ord(isActive), itemId)
  except DbError as e:
    if isUniqueViolation(e):
      adminFail("同じカテゴリーに同じブランド・品番が既にあります。")
    raise

proc createUser*(db: DbConn, username, password, role: string): int64 =
  ## パスワードの長さは「文字数」(コードポイント) で見る。
  let username = pyStrip(username)
  if username == "" or runeCount(password) < 8:
    adminFail("ユーザー名と、8文字以上のパスワードを入力してください。")
  let role = if role == "admin": "admin" else: "staff"
  try:
    return db.insertID(sql"""INSERT INTO "user"
      (username, password_hash, role, is_active, created_at)
      VALUES (?, ?, ?, 1, datetime('now'))""",
      username, hashPassword(password), role)
  except DbError as e:
    if isUniqueViolation(e):
      adminFail("そのユーザー名は既に使われています。")
    raise

proc setUserActive*(db: DbConn, userId: int64, active: bool) =
  db.exec(SqlQuery("UPDATE \"user\" SET is_active = ? WHERE id = ?"), ord(active), userId)

proc resetUserPassword*(db: DbConn, userId: int64, password: string) =
  if runeCount(password) < 8:
    adminFail("パスワードは8文字以上にしてください。")
  db.exec(SqlQuery("UPDATE \"user\" SET password_hash = ? WHERE id = ?"),
          hashPassword(password), userId)
