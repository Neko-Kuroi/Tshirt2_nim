## CLI のテスト。Go 版 internal/cli/cli_test.go (18件) の移植 + 引数エラーの追加。
##
## Go 版は io.Reader / bytes.Buffer で入出力を差し替えるが、Nim 版の runCli は
## File を受けるので、一時ファイルで標準入出力を差し替える。パスワードの
## プロンプトは、端末でない入力 (一時ファイル) からは Go 版と同じく
## エコー停止なしで2行読む。
##
## Go 版との意図的な違い (Go の仕様が正):
##   - CLI の create-user はパスワードの長さを課さない (管理画面専用の規則)。
##     adminsvc.createUser ではなく Go 版 CLI と同じ生の INSERT を使うことの
##     確認として、短いパスワードが通ることもテストする。
##   - list-users はタブ区切り (Go 版 cli.go の "%s\t%s\t%s")。日本語名でも
##     桁揃えはしない。

import std/[os, strutils, tempfiles, unittest]

import cli
import db
import passwords

# ---- ハーネス ----------------------------------------------------------------

proc runCapture(baseDir, stdinText: string,
                args: seq[string]): tuple[code: int, outText, errText: string] =
  ## コマンドを1回実行し、終了コードと標準出力・標準エラー出力を返す。
  let (inF, inPath) = createTempFile("tcli-in-", ".txt")
  let (outF, outPath) = createTempFile("tcli-out-", ".txt")
  let (errF, errPath) = createTempFile("tcli-err-", ".txt")
  defer:
    inF.close(); outF.close(); errF.close()
    removeFile(inPath); removeFile(outPath); removeFile(errPath)
  inF.write(stdinText)
  inF.setFilePos(0)
  let code = runCli(args, inF, outF, errF, baseDir)
  outF.flushFile()
  errF.flushFile()
  outF.setFilePos(0)
  errF.setFilePos(0)
  (code, outF.readAll(), errF.readAll())

proc newBase(): string =
  ## テスト用の baseDir。INVENTORY_* の影響を受けないよう空にしておく。
  putEnv("INVENTORY_DATABASE", "")
  putEnv("INVENTORY_ADDR", "")
  createTempDir("tcli", "")

proc dbPath(baseDir: string): string = baseDir / "instance" / "inventory.db"

proc initDb(baseDir: string) =
  let (code, _, errText) = runCapture(baseDir, "", @["init-db"])
  doAssert code == 0, "init-db: code=" & $code & " stderr=" & errText

proc openTestDb(baseDir: string): DbConn = openDb(dbPath(baseDir))

proc userNames(baseDir: string): seq[string] =
  let d = openTestDb(baseDir)
  defer: d.close()
  for row in d.getAllRows(sql"""SELECT username FROM "user" ORDER BY id"""):
    result.add row[0]

proc createUser(baseDir: string,
                args: varargs[string]): tuple[code: int, outText, errText: string] =
  runCapture(baseDir, "", @["create-user"] & @args)

proc hashOf(baseDir, username: string): string =
  let d = openTestDb(baseDir)
  defer: d.close()
  d.getValue(sql"""SELECT password_hash FROM "user" WHERE username = ?""", username)

# ---- init-db -------------------------------------------------------------------

suite "init-db":
  test "prints version and is idempotent":
    let base = newBase()
    for i in 1 .. 2: # 何度実行しても安全で、同じ表示
      let (code, outText, _) = runCapture(base, "", @["init-db"])
      check code == 0
      check outText == "スキーマのバージョン: 3\n"
    check fileExists(dbPath(base))

  test "foreign (SQLAlchemy) database is refused":
    let base = newBase()
    createDir(base / "instance")
    let d = openDb(dbPath(base))
    execSql(d, readFile(currentSourcePath.parentDir /
                        "testdata/db/sqlalchemy_version_schema.sql"))
    d.close()
    let (code, _, errText) = runCapture(base, "", @["init-db"])
    check code == 1
    check "SQLAlchemy" in errText

# ---- seed -----------------------------------------------------------------------

suite "seed":
  test "inserts defaults once":
    let base = newBase()
    initDb(base)
    let (code, outText, _) = runCapture(base, "", @["seed"])
    require code == 0
    check outText == "初期カテゴリーを登録しました。\n"
    let d = openTestDb(base)
    defer: d.close()
    var got: seq[(string, int, int, int, int)]
    for row in d.getAllRows(sql"""SELECT name, uses_color, uses_size,
      uses_variant_name, is_printable FROM category ORDER BY sort_order"""):
      got.add (row[0], parseInt(row[1]), parseInt(row[2]), parseInt(row[3]),
               parseInt(row[4]))
    check got == @[("Tシャツ", 1, 1, 0, 1), ("キャップ", 1, 0, 0, 1),
                   ("カバン", 1, 0, 0, 1), ("バッジ", 0, 0, 1, 0)]
    # 2回目は登録済みの表示で、増えない
    let (code2, out2, _) = runCapture(base, "", @["seed"])
    check code2 == 0
    check out2 == "カテゴリーは登録済みです。\n"
    check d.getValue(sql"SELECT COUNT(*) FROM category") == "4"

  test "missing database guides and creates nothing":
    let base = newBase()
    let (code, _, errText) = runCapture(base, "", @["seed"])
    check code == 1
    check "inventory init-db" in errText
    check not fileExists(dbPath(base))

  test "uninitialized database":
    let base = newBase()
    createDir(base / "instance")
    writeFile(dbPath(base), "") # 空ファイル (テーブルなし)
    let (code, _, errText) = runCapture(base, "", @["seed"])
    check code == 1
    check "DBが初期化されていません" in errText

# ---- list-users --------------------------------------------------------------------

suite "list-users":
  test "shows name role and status but not the hash":
    let base = newBase()
    initDb(base)
    let (c1, _, e1) = createUser(base, "admin", "--admin", "--password", "password123")
    doAssert c1 == 0, e1
    let (c2, _, e2) = createUser(base, "staff", "--password", "password123")
    doAssert c2 == 0, e2
    let d = openTestDb(base)
    d.exec(sql"""UPDATE "user" SET is_active = 0 WHERE username = 'staff'""")
    let hash = d.getValue(sql"""SELECT password_hash FROM "user" LIMIT 1""")
    d.close()
    let (code, outText, _) = runCapture(base, "", @["list-users"])
    require code == 0
    let lines = outText.strip(leading = false, chars = {'\n'}).split("\n")
    check lines == @["admin\t管理者\t有効", "staff\tスタッフ\t無効"]
    check hash notin outText

  test "japanese username is shown as-is (tab separated)":
    let base = newBase()
    initDb(base)
    let (c, _, e) = createUser(base, "たろう", "--password", "password123")
    doAssert c == 0, e
    let (code, outText, _) = runCapture(base, "", @["list-users"])
    check code == 0
    check outText == "たろう\tスタッフ\t有効\n"

  test "no users":
    let base = newBase()
    initDb(base)
    let (code, outText, _) = runCapture(base, "", @["list-users"])
    check code == 0
    check "ユーザーはまだ登録されていません。(inventory create-user --admin 名前 で作成できます)" in outText

  test "missing database does not create it":
    let base = newBase()
    let (code, _, errText) = runCapture(base, "", @["list-users"])
    check code != 0
    check "DBがありません" in errText
    check "inventory init-db" in errText
    check not fileExists(dbPath(base))

  test "uninitialized database":
    let base = newBase()
    createDir(base / "instance")
    writeFile(dbPath(base), "")
    let (code, _, errText) = runCapture(base, "", @["list-users"])
    check code != 0
    check "DBが初期化されていません" in errText
    check "inventory init-db" in errText

# ---- create-user -----------------------------------------------------------------------

suite "create-user":
  test "surrounding whitespace is stripped so the user can log in":
    let base = newBase()
    initDb(base)
    for raw in [" pad1", "pad2 ", "　pad3　"]: # 半角・全角 (U+3000) の空白
      let (code, _, errText) = createUser(base, raw, "--password", "password123")
      doAssert code == 0, errText
    check userNames(base) == @["pad1", "pad2", "pad3"]
    # 作った資格情報で実際に検証できる
    check verify(hashOf(base, "pad3"), "password123")

  test "blank username is rejected":
    let base = newBase()
    initDb(base)
    for raw in ["", "   ", "　"]:
      let (code, _, errText) = createUser(base, raw, "--password", "password123")
      check code != 0
      check "ユーザー名を入力してください。" in errText
    check userNames(base).len == 0

  test "duplicate is detected after stripping":
    let base = newBase()
    initDb(base)
    let (c1, _, _) = createUser(base, "pad", "--password", "password123")
    require c1 == 0
    let (code, _, errText) = createUser(base, " pad ", "--password", "password123")
    check code != 0
    check "そのユーザー名は既に使われています。" in errText
    check userNames(base) == @["pad"]

  test "admin flag and messages":
    let base = newBase()
    initDb(base)
    let (c1, out1, _) = createUser(base, "boss", "--admin", "--password", "password123")
    check c1 == 0
    check out1 == "作成しました: boss (admin)\n"
    let (c2, out2, _) = createUser(base, "helper", "--password", "password123")
    check c2 == 0
    check out2 == "作成しました: helper (staff)\n"
    let d = openTestDb(base)
    defer: d.close()
    check d.getValue(sql"""SELECT role FROM "user" WHERE username = 'boss'""") == "admin"

  test "short password is accepted (length rule is admin-screen only)":
    # Go 版 CLI と同じく、CLI では長さを課さない。
    let base = newBase()
    initDb(base)
    let (code, outText, errText) = createUser(base, "shorty", "--password", "x")
    doAssert code == 0, errText
    check outText == "作成しました: shorty (staff)\n"
    check verify(hashOf(base, "shorty"), "x")

  test "argument errors are usage with code 2":
    let base = newBase()
    initDb(base)
    for args in [@["create-user"],
                 @["create-user", "a", "b"],
                 @["create-user", "a", "--password"],
                 @["create-user", "a", "--bogus"]]:
      let (code, _, errText) = runCapture(base, "", args)
      check code == 2
      check "使い方: inventory create-user" in errText
    let (_, _, errText) = runCapture(base, "", @["create-user", "a", "--bogus"])
    check "不明なオプションです: --bogus" in errText
    check userNames(base).len == 0

  test "prompt via pipe":
    let base = newBase()
    initDb(base)
    # 端末でない標準入力からは、2行をそのまま読む (1行目=パスワード、2行目=確認)
    let (code, outText, errText) = runCapture(base, "secretpw\nsecretpw\n",
                                              @["create-user", "prompted"])
    doAssert code == 0, errText
    check "Password: " in outText
    check "Repeat for confirmation: " in outText
    check verify(hashOf(base, "prompted"), "secretpw")

  test "prompt mismatch":
    let base = newBase()
    initDb(base)
    let (code, _, errText) = runCapture(base, "aaa\nbbb\n",
                                        @["create-user", "mismatch"])
    check code == 1
    check "パスワードが一致しません。" in errText
    check userNames(base).len == 0

  test "prompt without trailing newline still works":
    let base = newBase()
    initDb(base)
    let (code, _, errText) = runCapture(base, "secretpw\nsecretpw",
                                        @["create-user", "prompted2"])
    doAssert code == 0, errText
    check verify(hashOf(base, "prompted2"), "secretpw")

  test "missing database does not create it":
    let base = newBase()
    let (code, _, errText) = createUser(base, "someone", "--password", "password123")
    check code == 1
    check "inventory init-db" in errText
    check not fileExists(dbPath(base))

  test "uninitialized database":
    let base = newBase()
    createDir(base / "instance")
    writeFile(dbPath(base), "")
    let (code, _, errText) = createUser(base, "someone", "--password", "password123")
    check code == 1
    check "DBが初期化されていません" in errText

# ---- help / 不明なコマンド / serve の引数 -------------------------------------------------

suite "help and serve args":
  test "help and unknown command":
    let base = newBase()
    for arg in ["help", "--help", "-h"]:
      let (code, outText, _) = runCapture(base, "", @[arg])
      check code == 0
      check "使い方: inventory" in outText
    let (code, _, errText) = runCapture(base, "", @["bogus"])
    check code == 2
    check "不明なコマンドです: bogus" in errText
    check "使い方: inventory" in errText

  test "serve rejects bad args":
    let base = newBase()
    let (c1, _, _) = runCapture(base, "", @["serve", "--bogus"])
    check c1 == 2
    let (c2, _, _) = runCapture(base, "", @["serve", "--addr"])
    check c2 == 2
    # ポートの無いアドレスは、起動せずにエラーで終わる (Go 版は ListenAndServe の失敗)
    let (c3, _, errText) = runCapture(base, "", @["serve", "--addr", "garbage"])
    check c3 == 1
    check errText.len > 0
