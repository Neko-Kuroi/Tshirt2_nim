## util のテスト。Go 版 internal/util/util_test.go の移植。
## 正解ベクトル (tests/testdata/util/*.json) は全件照合する。

import std/[algorithm, json, os, strutils, times, unittest]
import util

const ProjRoot = currentSourcePath.parentDir.parentDir
const UtilData = ProjRoot / "tests/testdata/util"

proc loadJson(name: string): JsonNode =
  parseJson(readFile(UtilData / name))

proc strs(n: JsonNode): seq[string] =
  for it in n:
    result.add it.getStr

proc sortedSizes(input: seq[string]): seq[string] =
  ## Go 版は sort.SliceStable。安定性は元の位置をタイブレークにして再現する。
  var indexed = newSeq[(string, int)](input.len)
  for i, s in input:
    indexed[i] = (s, i)
  indexed.sort do (a, b: (string, int)) -> int:
    let c = cmp(makeSizeKey(a[0]), makeSizeKey(b[0]))
    if c != 0: c else: cmp(a[1], b[1])
  for it in indexed:
    result.add it[0]

suite "python vectors":
  test "toInt matches Python (67 cases)":
    let cases = loadJson("toint.json")
    check cases.len >= 50
    for c in cases:
      let (n, ok) = toInt(c["in"].getStr)
      let outNode = c["out"]
      if outNode.kind == JNull:
        check not ok
      else:
        check ok and n == outNode.getInt

  test "pyStrip matches Python (18 cases)":
    let cases = loadJson("strip.json")
    check cases.len > 0
    for c in cases:
      check pyStrip(c["in"].getStr) == c["out"].getStr

  test "sizeKey order matches Python (647 cases)":
    let v = loadJson("sizekey.json")
    let input = strs(v["input"])
    let want = strs(v["sorted"])
    check input.len == 647
    let got = sortedSizes(input)
    check got.len == want.len
    for i in 0 ..< want.len:
      if got[i] != want[i]:
        checkpoint("first difference at " & $i & ": got " & got[i] &
                   ", Python " & want[i])
        fail()

  test "safeNext matches Python on ordinary inputs (30 cases)":
    let cases = loadJson("safe_next.json")
    check cases.len >= 20
    for c in cases:
      let outNode = c["out"]
      let want = if outNode.kind == JNull: "" else: outNode.getStr
      check safeNext(c["in"].getStr) == want

suite "sizeKey (Flask test_utils port)":
  test "known sizes come first":
    check sortedSizes(@["XL", "10", "S", "2", "M"]) == @["S", "M", "XL", "2", "10"]

  test "ASCII digits are numeric":
    check sortedSizes(@["100", "9", "12"]) == @["9", "12", "100"]

  test "superscript digits are text":
    check makeSizeKey("²").group == 2
    check makeSizeKey("¹²³").group == 2
    check sortedSizes(@["M", "²", "10", "2"]) == @["M", "2", "10", "²"]

  test "non-ASCII digits are text, not numbers":
    check makeSizeKey("１２").group == 2
    check makeSizeKey("٣").group == 2
    check sortedSizes(@["１２", "3"]) == @["3", "１２"]

  test "huge ASCII number stays numeric":
    let big = "99999999999999999999" # 20桁。Int64 の最大を超える
    check sortedSizes(@[big, "9"]) == @["9", big]
    check sortedSizes(@[big, "10000000000000000000"]) ==
      @["10000000000000000000", big]

  test "leading zeros tie-break on original string":
    check sortedSizes(@["7", "007"]) == @["007", "7"]
    check sortedSizes(@["00", "0"]) == @["0", "00"]

  test "combining character uses code point order":
    check sortedSizes(@["\u00e9", "e\u0301"]) == @["e\u0301", "\u00e9"]

  test "case-insensitive known sizes keep original":
    check sortedSizes(@["xl", "S", "m"]) == @["S", "m", "xl"]

suite "toInt edges":
  test "range edges":
    let (n1, ok1) = toInt("9223372036854775807")
    check ok1 and n1 == Int64Max
    check not toInt("9223372036854775808").ok
    let (n3, ok3) = toInt("-9223372036854775807")
    check ok3 and n3 == -Int64Max
    check not toInt("-9223372036854775808").ok # Flask 版 to_int は -Int64Max まで
    check not toInt(repeat("9", 100000)).ok

  test "truncateRunes":
    check truncateRunes("あいうえお", 3) == "あいう"
    check truncateRunes("abc", 5) == "abc"
    check truncateRunes("", 3) == ""
    check truncateRunes("abc", 0) == ""
    check truncateRunes(repeat("あ", 5000), 100) == repeat("あ", 100)

suite "jst":
  test "formatJst":
    let cases = {
      "2026-10-31 15:00:00": "11/01 00:00", # UTC 15:00 = JST 翌日 0:00
      "2026-10-04 00:20:10.887356": "10/04 09:20", # 小数秒付き
      "2026-01-01T00:00:00": "01/01 09:00",
      "2026-01-01 00:00:00+00:00": "01/01 09:00",
      "2026-01-01 09:00:00+09:00": "01/01 09:00", # オフセット付きは JST に直す
      "": "",
      "not a date": "not a date",
    }
    for (input, want) in cases:
      check formatJst(input) == want

  test "dateStampJst":
    # UTC の 15:30 は JST では翌日。ファイル名の日付は JST で決まる
    let utc = dateTime(2026, mOct, 31, 15, 30, 0, zone = utc()).toTime.toUnix
    check dateStampJst(utc) == "20261101"

suite "safeNext stricter than Python":
  test "browser-normalized attacks are rejected":
    for input in ["/\t\\evil.example", "/\n/evil.example", "/\r\n/evil.example",
                  "/\t/evil.example", "/a\x00b", "/a\x7fb", "/\\evil.example",
                  "//evil.example"]:
      check safeNext(input) == ""
    for input in ["/blank", "/blank/list?category=1&q=a%20b", "/日本語"]:
      check safeNext(input) == input
