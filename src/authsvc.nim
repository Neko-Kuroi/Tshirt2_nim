## ログイン認証とパスワード変更 (Go 版 internal/service/auth.go の移植)。
## 文言は Flask 版と一致させる。

import std/options
import db
import passwords
import repo
import util

const MinPasswordLen* = 8 ## パスワードの最小長 (コードポイント数)

const
  MsgLoginFailed* = "ユーザー名またはパスワードが違います。"
  MsgLoginRequired* = "ログインしてください。"
  MsgOldPasswordWrong* = "現在のパスワードが違います。"
  MsgPasswordTooShort* = "新しいパスワードは8文字以上にしてください。"
  MsgConfirmMismatch* = "確認用パスワードが一致しません。"
  MsgPasswordChanged* = "パスワードを変更しました。"

var dummyHash {.threadvar.}: string
var dummyHashReady {.threadvar.}: bool

proc dummy(): string =
  ## ユーザーが存在しない場合も検証コストを払い、タイミングで存在を
  ## 推測できないようにする (Flask 版と同じ考え方)。初回だけ生成する。
  if not dummyHashReady:
    dummyHash = hashPassword("dummy-password-for-timing")
    dummyHashReady = true
  dummyHash

proc verifyQuiet(stored, password: string): bool =
  ## 照合。壊れたハッシュは例外にせず「不一致」として扱う (500 にしない)。
  try:
    return verify(stored, password)
  except CatchableError:
    return false

proc authenticate*(db: DbConn, username, password: string): Option[User] =
  ## 成功したらユーザーを返す。失敗の理由 (ユーザーなし / 停止中 /
  ## パスワード違い / ハッシュ破損) は区別しない。
  let user = db.getUserByName(pyStrip(username))
  if user.isNone:
    discard verifyQuiet(dummy(), password)
    return none(User)
  let u = user.get
  if not verifyQuiet(u.passwordHash, password):
    return none(User)
  if not u.isActive:
    return none(User)
  user

type ChangeResult* = tuple[user: Option[User], msg: string]

proc changePassword*(db: DbConn, userId: int64, oldPw, newPw,
                     confirm: string): ChangeResult =
  ## パスワード変更。検証に失敗したら理由 (画面表示用) を返す。
  ## 成功時は更新後のユーザーと空の msg を返す。
  let userOpt = db.getUser(userId)
  if userOpt.isNone:
    return (none(User), "")
  let user = userOpt.get
  if not verifyQuiet(user.passwordHash, oldPw):
    return (none(User), MsgOldPasswordWrong)
  if runeCount(newPw) < MinPasswordLen:
    return (none(User), MsgPasswordTooShort)
  if newPw != confirm:
    return (none(User), MsgConfirmMismatch)
  let hashed = hashPassword(newPw)
  db.tx do ():
    db.exec(SqlQuery("UPDATE \"user\" SET password_hash = ? WHERE id = ?"), hashed, userId)
  (db.getUser(userId), "")
