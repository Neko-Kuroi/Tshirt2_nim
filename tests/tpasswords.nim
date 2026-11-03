## パスワードハッシュのテスト。Go 版 internal/auth/password_test.go の移植。

import std/[json, os, strutils, unittest]
import passwords

const ProjRoot = currentSourcePath.parentDir.parentDir
const VectorsFile = ProjRoot / "tests/testdata/werkzeug_hashes.json"

proc hashShapeOk(h: string): bool =
  ## ^scrypt:32768:8:1\$[A-Za-z0-9]{16}\$[0-9a-f]{128}$ の形か (正規表現を使わず手で見る)。
  let parts = h.split('$')
  if parts.len != 3 or parts[0] != "scrypt:32768:8:1":
    return false
  if parts[1].len != 16:
    return false
  for ch in parts[1]:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9'}:
      return false
  if parts[2].len != 128:
    return false
  for ch in parts[2]:
    if ch notin {'0'..'9', 'a'..'f'}:
      return false
  true

suite "werkzeug vectors":
  test "all 11 vectors verify, wrong passwords rejected":
    let cases = parseJson(readFile(VectorsFile))
    check cases.len >= 11
    var kinds = (scrypt: false, pbkdf2: false)
    for c in cases:
      let pw = c["pw"].getStr
      let hash = c["hash"].getStr
      if hash.startsWith("scrypt"):
        kinds.scrypt = true
      if hash.startsWith("pbkdf2"):
        kinds.pbkdf2 = true
      check verify(hash, pw)
      check not verify(hash, pw & "x")
    check kinds.scrypt and kinds.pbkdf2

suite "hash":
  test "format and round trip":
    let h = hashPassword("テストpass123")
    check hashShapeOk(h)
    check verify(h, "テストpass123")
    check not verify(h, "テストpass124")
    let h2 = hashPassword("テストpass123")
    check h != h2 # salt がランダム

  test "malformed hashes raise, never panic":
    let bad = [
      "", "plain", "a$b", "a$b$c$d", "scrypt:32768:8:1$salt$zz",
      "scrypt:32768:8:1$salt$", "scrypt:abc:8:1$salt$00",
      "scrypt:32768:8$salt$00", "scrypt:0:8:1$salt$00",
      "scrypt:32768:0:1$salt$00", "pbkdf2:sha256$salt$00",
      "pbkdf2:md5:1000$salt$00", "pbkdf2:sha256:0$salt$00",
      "pbkdf2:sha256:x$salt$00", "unknown:1:2:3$salt$00",
      "scrypt:1073741824:8:1$salt$00", # 巨大なメモリを要求する値
      "pbkdf2:sha256:999999999999$salt$00",
    ]
    for h in bad:
      expect CatchableError:
        discard verify(h, "x")
    expect UnrecognizedHashError:
      discard verify("x", "y")
