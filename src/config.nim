## 設定の解決 (Flask 版 config.py、Go 版 internal/cli の resolve と
## internal/auth の LoadSecretKey に対応)。
##
## パスの規則 (Go 版と同じ):
##   DB: 環境変数 INVENTORY_DATABASE、無ければ <baseDir>/instance/inventory.db
##   instance フォルダーは常に <baseDir>/instance (DB の場所には連動しない)
##   鍵: 環境変数 INVENTORY_SECRET_KEY → <instanceDir>/secret_key。
##       無ければ生成して 0600 で保存する (Flask 版と同じ)
##   CookieSecure: INVENTORY_COOKIE_SECURE=1
##
## 鍵そのものは、ここでも呼び出し側でもログに出さない。

import std/[os, posix, strutils]
import nimcrypto/sysrand
import nimcrypto/utils

type ResolvedConfig* = object
  ## この実行で使う設定の解決結果。
  dbPath*: string      ## inventory.db のパス
  instanceDir*: string ## 鍵ファイルの置き場所
  secretKey*: string   ## Cookie の署名鍵
  cookieSecure*: bool  ## Cookie に Secure 属性を付けるか

proc loadSecretKey*(instanceDir: string): string =
  ## 署名鍵を返す。環境変数 → 鍵ファイル → 生成して保存、の順 (Go 版と同一)。
  let env = getEnv("INVENTORY_SECRET_KEY")
  if env != "":
    return env
  let path = instanceDir / "secret_key"
  try:
    let s = readFile(path).strip()
    if s != "":
      return s
  except IOError:
    discard # 無い (または読めない) 場合は生成に進む
  createDir(instanceDir)
  var raw = newSeq[byte](32)
  if randomBytes(addr raw[0], raw.len) != raw.len:
    raise newException(IOError, "乱数を読み取れませんでした")
  let key = toLowerAscii(toHex(raw))
  # 他のプロセスが同時に作った場合に上書きしないよう、新規作成のときだけ書く
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
  if fd < 0:
    if errno == EEXIST:
      return loadSecretKey(instanceDir)
    raiseOSError(osLastError())
  if posix.write(fd, key.cstring, key.len) != key.len:
    discard posix.close(fd)
    raiseOSError(osLastError())
  discard posix.close(fd)
  key

proc resolveConfig*(baseDir: string): ResolvedConfig =
  ## baseDir (実行ファイルのあるフォルダー) から設定一式を解決する。
  let instanceDir = baseDir / "instance"
  var dbPath = getEnv("INVENTORY_DATABASE")
  if dbPath == "":
    dbPath = instanceDir / "inventory.db"
  ResolvedConfig(
    dbPath: dbPath,
    instanceDir: instanceDir,
    secretKey: loadSecretKey(instanceDir),
    cookieSecure: getEnv("INVENTORY_COOKIE_SECURE") == "1")
