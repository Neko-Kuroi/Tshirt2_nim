## コマンドラインの入口 (Flask 版の `flask` コマンドに相当)。
##
## サーバー起動 (serve) と管理コマンド (init-db / seed / create-user /
## list-users) を同じバイナリのサブコマンドとして提供する。文言は Flask 版に
## 合わせ、案内の中のコマンド名だけこの版の名前 (inventory) に置き換えてある。
## Go 版 internal/cli の移植で、文言・終了コード・出力先 (stdout/stderr) は
## Go 版と同一にしてある。
##
## Go 版との違い (実装手段の差だけ):
##   - パスワード入力のエコー停止は std/posix の termios で行う
##     (Go 版は golang.org/x/sys/unix の TCGETS/TCSETS)。
##   - serve の割り込み (SIGINT/SIGTERM) による graceful shutdown は無い。
##     mummy の serveHttp が戻らない作りのため、シグナルではプロセスが
##     そのまま終わる (DB はリクエストごとに開閉するので壊れない)。

import std/[os, posix, strutils]
import posix/termios

import config
import db
import passwords
import repo
import util
import webcore
import webread
import webops
import webadmin

const UsageText = """使い方: inventory <コマンド> [引数]

コマンド:
  serve         サーバーを起動する (省略時も同じ。--addr で待ち受けアドレスを指定)
  init-db       DBを作成/更新する (何度実行しても安全)
  seed          初期カテゴリーを登録する (既にあれば何もしない)
  create-user   ユーザーを作成する: create-user [--admin] [--password <パスワード>] <ユーザー名>
  list-users    登録済みのユーザー名・権限・有効/無効を表示する (パスワードは表示しない)
  help          この使い方を表示する
"""

# ---- 設定の解決 (Go 版 cli.resolve と同じ規則) --------------------------------

type CliSettings = object
  dbPath: string      ## INVENTORY_DATABASE、無ければ <baseDir>/instance/inventory.db
  instanceDir: string ## 鍵ファイルの置き場所。常に <baseDir>/instance

proc resolve(baseDir: string): CliSettings =
  ## 鍵は読み込まない (serve 以外のコマンドで secret_key を作らないため、
  ## Go 版と同じくパスの解決だけを行う)。
  let instanceDir = baseDir / "instance"
  var dbPath = getEnv("INVENTORY_DATABASE")
  if dbPath == "":
    dbPath = instanceDir / "inventory.db"
  CliSettings(dbPath: dbPath, instanceDir: instanceDir)

# ---- 共通の失敗処理 -------------------------------------------------------------

type UninitializedError = object of CatchableError
  ## テーブルがまだ無い DB への案内を出すための目印 (Go 版 errUninitialized)。

proc uninitializedErr(): ref UninitializedError =
  newException(UninitializedError, "DBが初期化されていません")

proc reportErr(stderr: File, e: ref Exception): int =
  ## コマンドの失敗を表示する。未初期化は案内に変える。
  if e of UninitializedError:
    stderr.writeLine("DBが初期化されていません。先に inventory init-db を実行してください。")
  else:
    stderr.writeLine(e.msg)
  1

proc isNoSuchTable(e: ref Exception): bool =
  e != nil and "no such table" in e.msg

proc isUniqueViolation(e: ref Exception): bool =
  ## DB のエラーが UNIQUE 制約違反か (Flask 版 utils.is_unique_violation)。
  e != nil and "unique constraint" in e.msg.toLowerAscii()

proc requireDb(stderr: File, path: string): tuple[conn: DbConn, ok: bool] =
  ## 既存の DB を開く。ファイルが無ければ作らずに案内を出して ok=false を返す
  ## (存在しないファイルに接続すると、空の DB が勝手に作られてしまうため。
  ## Flask 版と同じ配慮)。
  if not fileExists(path):
    stderr.write("DBがありません(" & path & ")。先に inventory init-db を実行してください。\n")
    return (nil, false)
  try:
    result = (openDb(path), true)
  except CatchableError as e:
    stderr.writeLine(e.msg)
    result = (nil, false)

# ---- init-db ---------------------------------------------------------------------

proc cmdInitDb(stdout, stderr: File, baseDir: string): int =
  ## DB を作成/更新する (Flask 版 init-db)。
  let st = resolve(baseDir)
  try:
    let dir = parentDir(st.dbPath)
    if dir != "":
      createDir(dir)
    let d = openDb(st.dbPath)
    defer: d.close()
    let version = migrate(d) # 他版の DB は ForeignSchemaError で止まる
    stdout.write("スキーマのバージョン: " & $version & "\n")
    0
  except CatchableError as e:
    stderr.writeLine(e.msg)
    1

# ---- seed --------------------------------------------------------------------------

## 初期カテゴリー (名前, 色, サイズ, 種類名, プリント可)。並びが sort_order になる。
const SeedDefaults = [
  ("Tシャツ", 1, 1, 0, 1),
  ("キャップ", 1, 0, 0, 1),
  ("カバン", 1, 0, 0, 1),
  ("バッジ", 0, 0, 1, 0)]

proc cmdSeed(stdout, stderr: File, baseDir: string): int =
  ## 初期カテゴリーを登録する (Flask 版 seed)。
  let st = resolve(baseDir)
  let (d, ok) = requireDb(stderr, st.dbPath)
  if not ok:
    return 1
  defer: d.close()
  var registered = false
  try:
    tx(d) do ():
      if d.getValue(sql"SELECT 1 FROM category LIMIT 1") != "":
        registered = true
      else:
        for i, c in SeedDefaults:
          d.exec(sql"""INSERT INTO category
            (name, sort_order, uses_color, uses_size, uses_variant_name, is_printable)
            VALUES (?, ?, ?, ?, ?, ?)""",
            c[0], i, c[1], c[2], c[3], c[4])
  except CatchableError as e:
    if isNoSuchTable(e):
      return reportErr(stderr, uninitializedErr())
    return reportErr(stderr, e)
  if registered:
    stdout.writeLine("カテゴリーは登録済みです。")
  else:
    stdout.writeLine("初期カテゴリーを登録しました。")
  0

# ---- list-users ----------------------------------------------------------------------

proc cmdListUsers(stdout, stderr: File, baseDir: string): int =
  ## ユーザー一覧を表示する (Flask 版 list-users)。パスワードハッシュは出さない。
  let st = resolve(baseDir)
  let (d, ok) = requireDb(stderr, st.dbPath)
  if not ok:
    return 1
  defer: d.close()
  var users: seq[User]
  try:
    users = listUsers(d)
  except CatchableError as e:
    if isNoSuchTable(e):
      return reportErr(stderr, uninitializedErr())
    return reportErr(stderr, e)
  if users.len == 0:
    stdout.writeLine("ユーザーはまだ登録されていません。(inventory create-user --admin 名前 で作成できます)")
    return 0
  for u in users:
    let role = if u.role == "admin": "管理者" else: "スタッフ"
    let status = if u.isActive: "有効" else: "無効"
    stdout.write(u.username & "\t" & role & "\t" & status & "\n")
  0

# ---- パスワード入力 (端末ではエコーを止める。getpass と同じ) ---------------------------

type Prompter = object
  f: File   ## 標準入力
  outF: File ## プロンプトの出力先 (Go 版と同じく標準出力)

proc readLineRaw(p: Prompter): tuple[line: string, err: ref IOError] =
  ## 1行読む。1バイトずつ読むので、2回のプロンプトで読み過ぎることはない。
  ## EOF で行が空ならエラー (Go 版は io.EOF をそのまま表示するので "EOF")。
  var line = ""
  while true:
    var c: char
    if p.f.readBuffer(addr c, 1) == 0: # EOF
      if line.len > 0:
        return (line, nil)
      return ("", newException(IOError, "EOF"))
    if c == '\n':
      return (line, nil)
    line.add c

proc promptPassword(p: Prompter, prompt: string): tuple[pw: string, err: ref IOError] =
  ## プロンプトを出してパスワードを読む。端末のときだけエコーを止める
  ## (パイプやファイルからの入力は、そのまま行として読む。Go 版と同じ)。
  p.outF.write(prompt)
  p.outF.flushFile()
  var hidden = false
  var old: Termios
  let fd = p.f.getFileHandle().cint
  if tcGetAttr(fd, addr old) == 0: # 端末でない入力では失敗するので、そのまま読む
    var noEcho = old
    noEcho.c_lflag = noEcho.c_lflag and not ECHO
    if tcSetAttr(fd, TCSANOW, addr noEcho) == 0:
      hidden = true
  let (line, err) = p.readLineRaw()
  if hidden:
    discard tcSetAttr(fd, TCSANOW, addr old)
    p.outF.write("\n") # エコーが無いので、Enter の改行はこちらで出す
    p.outF.flushFile()
  if err != nil:
    return ("", err)
  (line.strip(leading = false, chars = {'\r', '\n'}), nil)

# ---- create-user -----------------------------------------------------------------------

proc cmdCreateUser(args: seq[string], stdin, stdout, stderr: File,
                   baseDir: string): int =
  ## ユーザーを作成する (Flask 版 create-user)。
  ## パスワードの長さの規則は管理画面専用なので、ここでは Flask 版 CLI と
  ## 同じく課さない (adminsvc.createUser は使わない)。
  const usage = "使い方: inventory create-user [--admin] [--password <パスワード>] <ユーザー名>"
  var admin = false
  var password = ""
  var hasPassword = false
  var positional: seq[string]
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--admin":
      admin = true
    elif a == "--password":
      inc i
      if i >= args.len:
        stderr.writeLine(usage)
        return 2
      password = args[i]
      hasPassword = true
    elif a.startsWith("--password="):
      password = a["--password=".len .. ^1]
      hasPassword = true
    elif a.startsWith("-"):
      stderr.write("不明なオプションです: " & a & "\n")
      stderr.writeLine(usage)
      return 2
    else:
      positional.add a
    inc i
  if positional.len != 1:
    stderr.writeLine(usage)
    return 2
  # ログイン画面・管理画面と同じく前後の空白を取り除く (空白付きだと二度とログインできない)
  let username = pyStrip(positional[0])
  if username == "":
    stderr.writeLine("ユーザー名を入力してください。")
    return 1

  let st = resolve(baseDir)
  let (d, ok) = requireDb(stderr, st.dbPath)
  if not ok:
    return 1
  defer: d.close()

  var pw = ""
  if hasPassword:
    pw = password
  else:
    let p = Prompter(f: stdin, outF: stdout)
    let (first, err1) = p.promptPassword("Password: ")
    if err1 != nil:
      stderr.writeLine(err1.msg)
      return 1
    let (second, err2) = p.promptPassword("Repeat for confirmation: ")
    if err2 != nil:
      stderr.writeLine(err2.msg)
      return 1
    if first != second:
      stderr.writeLine("パスワードが一致しません。")
      return 1
    pw = first

  var hash: string
  try:
    hash = hashPassword(pw)
  except CatchableError as e:
    stderr.writeLine(e.msg)
    return 1
  let role = if admin: "admin" else: "staff"
  try:
    tx(d) do ():
      d.exec(sql"""INSERT INTO "user"
        (username, password_hash, role, is_active, created_at)
        VALUES (?, ?, ?, 1, datetime('now'))""",
        username, hash, role)
  except CatchableError as e:
    if isUniqueViolation(e):
      stderr.writeLine("そのユーザー名は既に使われています。")
      return 1
    if isNoSuchTable(e):
      return reportErr(stderr, uninitializedErr())
    return reportErr(stderr, e)
  stdout.write("作成しました: " & username & " (" & role & ")\n")
  0

# ---- serve --------------------------------------------------------------------------------

proc cmdServe(args: seq[string], stdout, stderr: File, baseDir: string): int =
  ## HTTP サーバーを起動する。DB が未作成/古くても起動し、
  ## web の層が案内 (503) を出す。init-db が済めば再起動なしで使える。
  const usage = "使い方: inventory serve [--addr <アドレス>]"
  var addrStr = getEnv("INVENTORY_ADDR")
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--addr":
      inc i
      if i >= args.len:
        stderr.writeLine(usage)
        return 2
      addrStr = args[i]
    elif a.startsWith("--addr="):
      addrStr = a["--addr=".len .. ^1]
    else:
      stderr.write("不明な引数です: " & a & "\n")
      stderr.writeLine(usage)
      return 2
    inc i
  if addrStr == "":
    addrStr = "127.0.0.1:5000"

  let st = resolve(baseDir)
  var secret: string
  try:
    secret = loadSecretKey(st.instanceDir)
  except CatchableError as e:
    stderr.writeLine(e.msg)
    return 1
  var app: App
  try:
    app = newApp(WebConfig(databasePath: st.dbPath, secretKey: secret,
      cookieSecure: getEnv("INVENTORY_COOKIE_SECURE") == "1"))
  except CatchableError as e:
    stderr.writeLine(e.msg)
    return 1
  app.registerReadRoutes()
  app.registerOpsRoutes()
  app.registerAdminRoutes()

  # mummy の serveHttp はアドレスとポートを分けて受けるので、Go 版の
  # "host:port" を分解する。形式が違うものは、Go 版が ListenAndServe で
  # 失敗するのと同じく、エラーにして終了する。
  let colon = addrStr.rfind(':')
  if colon < 0:
    stderr.writeLine("listen tcp: address " & addrStr & ": missing port in address")
    return 1
  let host = addrStr[0 ..< colon]
  var port: int
  try:
    port = parseInt(addrStr[colon + 1 .. ^1])
  except ValueError:
    stderr.writeLine("listen tcp: address " & addrStr & ": invalid port")
    return 1
  stderr.write("在庫管理サーバー起動: http://" & addrStr & " (DB: " & st.dbPath & ")\n")
  stderr.flushFile()
  try:
    app.serveHttp(host, port)
  except CatchableError as e:
    stderr.writeLine(e.msg)
    return 1
  0

# ---- 入口 ------------------------------------------------------------------------------------

proc runCli*(args: seq[string], stdin, stdout, stderr: File,
             baseDir: string): int =
  ## コマンドを実行し、終了コードを返す。
  ## baseDir は設定ファイル (instance フォルダー) の置き場所で、製品版では
  ## 実行ファイルのあるフォルダー。
  if args.len == 0:
    return cmdServe(@[], stdout, stderr, baseDir)
  case args[0]
  of "serve":
    cmdServe(args[1 .. ^1], stdout, stderr, baseDir)
  of "init-db":
    cmdInitDb(stdout, stderr, baseDir)
  of "seed":
    cmdSeed(stdout, stderr, baseDir)
  of "list-users":
    cmdListUsers(stdout, stderr, baseDir)
  of "create-user":
    cmdCreateUser(args[1 .. ^1], stdin, stdout, stderr, baseDir)
  of "help", "--help", "-h":
    stdout.write(UsageText)
    0
  else:
    stderr.write("不明なコマンドです: " & args[0] & "\n")
    stderr.write(UsageText)
    2
