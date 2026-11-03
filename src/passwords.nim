## パスワードハッシュ (Flask 版 werkzeug.security と互換)。
## Go 版 internal/auth/password.go の移植。
##
## 確認できる形式:
##   scrypt:N:R:P$salt$hex
##   pbkdf2:sha256:<iterations>$salt$hex (sha1/224/256/384/512)
## 生成は Werkzeug の既定 (scrypt:32768:8:1、salt 16文字、鍵長64バイト)。
## salt は「文字列そのままのバイト列」として使う (Werkzeug の仕様)。
## 16進は小文字 (nimcrypto の toHex は大文字なので小文字化する)。

import std/strutils
import nimcrypto/[scrypt, pbkdf2, sha, sha2, sysrand, utils]

type
  UnrecognizedHashError* = object of CatchableError
    ## 形式が解釈できないハッシュ (Go 版 ErrUnrecognizedHash)。
  HashParamError* = object of CatchableError
    ## 形式は合っているが、パラメータが安全な範囲を超えている。

const saltChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

proc fail(msg: string) {.noreturn.} =
  raise newException(UnrecognizedHashError, "auth: unrecognized password hash format: " & msg)

proc constTimeEq(a, b: openArray[byte]): bool =
  ## バイト列の定数時間比較 (Go 版 subtle.ConstantTimeCompare)。
  if a.len != b.len:
    return false
  var diff = 0'u8
  for i in 0 ..< a.len:
    diff = diff or (a[i] xor b[i])
  diff == 0

proc isHexText(s: string): bool =
  if s.len == 0 or s.len mod 2 != 0:
    return false
  for ch in s:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc parseUint(s: string): int =
  ## 10進の非負整数。Go の strconv.Atoi と同様、解釈できなければ例外。
  if s.len == 0:
    raise newException(ValueError, "empty")
  result = 0
  for ch in s:
    if ch < '0' or ch > '9':
      raise newException(ValueError, "not a number: " & s)
    let d = ch.ord - '0'.ord
    if result > (int.high - d) div 10:
      raise newException(ValueError, "overflow: " & s)
    result = result * 10 + d

# scrypt の作業領域 (Werkzeug のパラメータでは約34MB) は、Nim の
# アロケータではなく C の malloc/free で確保する。Nim のアロケータは
# 解放した大きなブロックを自分のフリーリストに保持して OS に返さない
# ため、スレッドプール型のサーバーでは、ログインを処理したワーカーの
# 分だけ RSS が増えたまま戻らなかった。malloc ならこの大きさは mmap で
# 確保され、free で OS に返る (Python/Go 版と同じ挙動になる)。
# 作業領域は素の数値配列で、GC 管理下のデータを含まず、この proc の
# 外へも出ない。
proc cmalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cfree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc scryptKey(password, salt: string, n, r, p, dkLen: int): seq[byte] =
  let (xyvLen, bLen) = scryptCalc(n, r, p)
  let xyvRaw = cmalloc(csize_t(xyvLen * sizeof(uint32)))
  let bRaw = cmalloc(csize_t(bLen))
  if xyvRaw.isNil or bRaw.isNil:
    if not xyvRaw.isNil: cfree(xyvRaw)
    if not bRaw.isNil: cfree(bRaw)
    raise newException(HashParamError, "auth: scrypt failed (out of memory)")
  try:
    let xyv = cast[ptr UncheckedArray[uint32]](xyvRaw)
    let b = cast[ptr UncheckedArray[byte]](bRaw)
    result = newSeq[byte](dkLen)
    if scrypt(password, salt, n, r, p, xyv.toOpenArray(0, xyvLen - 1),
              b.toOpenArray(0, bLen - 1), result) != dkLen:
      raise newException(HashParamError, "auth: scrypt failed (invalid parameters)")
  finally:
    cfree(xyvRaw)
    cfree(bRaw)

proc pbkdf2Key(digest, password, salt: string, iter, dkLen: int): seq[byte] =
  # nimcrypto の pbkdf2 は (方式, パスワード, salt, 回数, 鍵長) → seq[byte] の形。
  result = case digest
    of "sha1": pbkdf2(sha1, password, salt, iter, dkLen)
    of "sha224": pbkdf2(sha224, password, salt, iter, dkLen)
    of "sha256": pbkdf2(sha256, password, salt, iter, dkLen)
    of "sha384": pbkdf2(sha384, password, salt, iter, dkLen)
    of "sha512": pbkdf2(sha512, password, salt, iter, dkLen)
    else: fail("unknown pbkdf2 digest " & digest)
  if result.len != dkLen:
    raise newException(HashParamError, "auth: pbkdf2 failed")

proc derive(parts: seq[string], password: string, wantLen: int): seq[byte] =
  ## 先頭要素 (方式) を見て鍵導出する。Go 版 auth.derive の移植。
  let head = parts[0].split(':')
  case head[0]
  of "scrypt":
    if head.len != 4:
      fail("scrypt needs N:R:P")
    var n, r, p: int
    try:
      n = parseUint(head[1])
      r = parseUint(head[2])
      p = parseUint(head[3])
    except ValueError:
      fail("bad scrypt params")
    if n < 2 or r < 1 or p < 1:
      fail("scrypt params out of range")
    # Go の x/crypto/scrypt が確保するメモリ量の上限ガード (512MiB)。
    # uint64 で計算する (n は int 幅までありうる)。
    if uint64(128) * uint64(n) * uint64(r) > uint64(512 * 1024 * 1024):
      raise newException(HashParamError,
        "auth: scrypt parameters too large (n=" & $n & " r=" & $r & ")")
    return scryptKey(password, parts[1], n, r, p, wantLen)
  of "pbkdf2":
    if head.len != 3:
      fail("pbkdf2 needs digest:iterations")
    var iter: int
    try:
      iter = parseUint(head[2])
    except ValueError:
      fail("bad pbkdf2 iterations")
    if iter <= 0 or iter > 50_000_000:
      fail("pbkdf2 iterations out of range")
    return pbkdf2Key(head[1], password, parts[1], iter, wantLen)
  else:
    fail("unknown method " & head[0])

proc verify*(stored, password: string): bool =
  ## 保存済みハッシュとパスワードを照合する (Go 版 Verify)。
  ## 形式が解釈できなければ UnrecognizedHashError、パラメータ過大なら
  ## HashParamError を送出する (呼び出し側はログイン失敗として扱う)。
  let parts = stored.split('$')
  if parts.len != 3:
    fail("want method$salt$hash")
  if not isHexText(parts[2]):
    fail("hash part is not hex")
  let want = utils.fromHex(parts[2])
  # 鍵長は保存済みハッシュのバイト数に合わせる (Werkzeug の仕様で、形式文字列
  # に鍵長は含まれない)。
  let got = derive(parts, password, want.len)
  constTimeEq(got, want)

proc randomSalt(n: int): string =
  var bytes = newSeq[byte](n * 2)
  if randomBytes(addr bytes[0], bytes.len) != bytes.len:
    raise newException(IOError, "auth: cannot read random bytes")
  result = newStringOfCap(n)
  var i = 0
  while result.len < n:
    let b = bytes[i].int
    i += 1
    if b < 248: # 62 * 4。一様分布にするための棄却サンプリング (Go 版と同じ考え方)
      result.add saltChars[b mod saltChars.len]

proc hashPassword*(password: string): string =
  ## Werkzeug 互換の新規ハッシュを作る (Go 版 auth.Hash)。
  let salt = randomSalt(16)
  let dk = scryptKey(password, salt, 32768, 8, 1, 64)
  "scrypt:32768:8:1$" & salt & "$" & toLowerAscii(toHex(dk))
