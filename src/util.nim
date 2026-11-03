## Flask 版 app/utils.py と、Python の標準動作に依存していた小さな処理の移植。
## Python と分かれやすい箇所 (空白の定義、int() の受け付ける書式、文字列の並び、
## 時刻表示) を、Python 側の出力を正解として揃える (Go 版 internal/util と同じ方針)。
## 正解データは tests/testdata/util/*.json (tools/gen_golden.py の出力)。

import std/[strutils, unicode]

# ---- 空白と strip ---------------------------------------------------------------

proc isPySpace*(r: Rune): bool =
  ## Python の str.isspace() が真になる文字か。
  ## Unicode の White_Space 一式に加えて、Python は U+001C〜U+001F も空白として扱う
  ## (Go 版は unicode.IsSpace + 0x1C〜0x1F で同じ集合にしている)。
  let c = r.int32
  if c <= 0x7F:
    return c in [0x09'i32, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x1C, 0x1D, 0x1E, 0x1F]
  if c == 0x85 or c == 0xA0:
    return true
  return c == 0x1680 or (c >= 0x2000 and c <= 0x200A) or
         c == 0x2028 or c == 0x2029 or c == 0x202F or c == 0x205F or c == 0x3000

proc pyStrip*(s: string): string =
  ## Python の str.strip() (引数なし) と同じ。
  var start = 0
  var stop = s.len
  while start < stop:
    let r = runeAt(s, start)
    if not isPySpace(r):
      break
    start += runeLenAt(s, start)
  while stop > start:
    let (r, rlen) = lastRune(s, stop - 1) # lastRune は (ルーン, バイト長) を返す
    if not isPySpace(r):
      break
    stop -= rlen
  s[start ..< stop]

proc runeCount*(s: string): int =
  ## コードポイント数 (Python の len(str)、Go の utf8.RuneCountInString)。
  runeLen(s)

proc truncateRunes*(s: string, n: int): string =
  ## Python の s[:n] (コードポイント単位の切り詰め)。
  let n = max(n, 0)
  var count = 0
  var i = 0
  while i < s.len:
    if count == n:
      return s[0 ..< i]
    i += runeLenAt(s, i)
    count += 1
  s

# ---- toInt (Python の int()) -----------------------------------------------------

const Int64Max*: int64 = 9223372036854775807
  ## SQLite の整数の上限。これを超える値を渡すとドライバーでエラーになる。
const MaxQty* = 1_000_000
  ## 1回の入荷・出荷・調整の上限 (Flask 版 MAX_QTY)。SQLite は整数の足し算が
  ## 溢れるとエラーにせず REAL にしてしまうので、在庫列を守るためにも必要。

# Unicode の Nd (10進数字) の範囲。Python 3.11 (Unicode 15.0) の
# unicodedata.category == 'Nd' から生成した。範囲はどれも「0 のコードポイント
# から始まる10個単位のブロック」の連結なので、値は (c - 範囲先頭) mod 10 で
# 得られる (Go 版 decimalValue が unicode.Nd の表で行っているのと同じ)。
const NdRanges: array[64, (int32, int32)] = [
  (48, 57), (1632, 1641), (1776, 1785), (1984, 1993), (2406, 2415),
  (2534, 2543), (2662, 2671), (2790, 2799), (2918, 2927), (3046, 3055),
  (3174, 3183), (3302, 3311), (3430, 3439), (3558, 3567), (3664, 3673),
  (3792, 3801), (3872, 3881), (4160, 4169), (4240, 4249), (6112, 6121),
  (6160, 6169), (6470, 6479), (6608, 6617), (6784, 6793), (6800, 6809),
  (6992, 7001), (7088, 7097), (7232, 7241), (7248, 7257), (42528, 42537),
  (43216, 43225), (43264, 43273), (43472, 43481), (43504, 43513),
  (43600, 43609), (44016, 44025), (65296, 65305), (66720, 66729),
  (68912, 68921), (69734, 69743), (69872, 69881), (69942, 69951),
  (70096, 70105), (70384, 70393), (70736, 70745), (70864, 70873),
  (71248, 71257), (71360, 71369), (71472, 71481), (71904, 71913),
  (72016, 72025), (72784, 72793), (73040, 73049), (73120, 73129),
  (73552, 73561), (92768, 92777), (92864, 92873), (93008, 93017),
  (120782, 120831), (123200, 123209), (123632, 123641), (124144, 124153),
  (125264, 125273), (130032, 130041),
]

proc decimalValue(r: Rune): (uint64, bool) =
  ## Python の int() が受け付ける「10進数字」(Unicode の Nd) の値を返す。
  ## 全角数字 (１２) やアラビア・インド数字 (٣) も数字として受け付ける。
  ## 上付き数字 (²) は Nd ではないので受け付けない (Python の int("²") も ValueError)。
  let c = r.int32
  if c >= '0'.ord and c <= '9'.ord:
    return (uint64(c - '0'.ord), true)
  if c < 0x80:
    return (0'u64, false)
  for (lo, hi) in NdRanges:
    if c >= lo and c <= hi:
      return (uint64((c - lo) mod 10), true)
  (0'u64, false)

type IntResult* = tuple[n: int64, ok: bool]

proc toInt*(raw: string): IntResult =
  ## フォーム/クエリの文字列を整数にする (Flask 版 to_int)。
  ## 変換できない、または SQLite の整数範囲 (±Int64Max) の外なら ok=false。
  ##
  ## Python の int() と同じ書式を受け付ける:
  ## 前後の空白 (pyStrip)、先頭の符号 (+ -)、数字の間の単独のアンダースコア
  ## (1_000)、全角数字などの Unicode 10進数字。
  var s = pyStrip(raw)
  var neg = false
  if s.len > 0 and (s[0] == '+' or s[0] == '-'):
    neg = s[0] == '-'
    s = s[1 .. ^1]
  if s.len == 0:
    return (0'i64, false)
  var acc: uint64 = 0
  var prevUnderscore = true # 先頭の _ と、連続する _ を拒否するため
  for r in runes(s):
    if r == Rune('_'):
      if prevUnderscore:
        return (0'i64, false)
      prevUnderscore = true
      continue
    let (d, isDigit) = decimalValue(r)
    if not isDigit:
      return (0'i64, false)
    prevUnderscore = false
    if acc > (uint64.high - d) div 10:
      return (0'i64, false) # 桁あふれ = 範囲外
    acc = acc * 10 + d
  if prevUnderscore: # 末尾の _
    return (0'i64, false)
  if acc > uint64(Int64Max):
    return (0'i64, false)
  if neg:
    return (-int64(acc), true)
  (int64(acc), true)

proc safeNext*(target: string): string =
  ## ログイン後の移動先 (next) が、このサイト内の相対パスのときだけ返す
  ## (オープンリダイレクト対策。Flask 版 safe_next)。それ以外は空文字。
  ##
  ## Flask 版と同じ判定に加えて、次の点を厳しくしている (ブラウザは、タブ・
  ## 改行を取り除き、\ を / として扱うため、Python 版では通ってしまう
  ## "/<TAB>\evil.example" が、外部への移動になりうる):
  ##   - 制御文字 (U+0000〜001F, U+007F) を含むものは拒否
  ##   - "/\" で始まるものは拒否
  if target.len == 0 or target[0] != '/':
    return ""
  if target.startsWith("//") or target.startsWith("/\\"):
    return ""
  for ch in target:
    if ch.uint8 < 0x20 or ch.uint8 == 0x7f:
      return ""
  target

# ---- サイズの並び (size_key) ------------------------------------------------------

const SizeOrder* = ["XXS", "XS", "S", "M", "L", "XL", "2XL", "XXL", "3XL",
                    "XXXL", "4XL", "5XL", "FREE", "F"]
  ## 決まったサイズ表記の並び (Flask 版 SIZE_ORDER)。

type SizeKey* = object
  ## Flask 版 size_key(s) の返すタプルに対応する並べ替えキー。
  ##
  ##   グループ0: SizeOrder にある表記 (大文字化して照合。表の順)
  ##   グループ1: ASCII の 0-9 だけの文字列 (数値の大小)
  ##   グループ2: それ以外 (空文字、全角数字、上付き数字、ふつうの文字列)
  ##
  ## 数値は整数に変換しない (桁数無制限の Python の int と一致させるため)。
  ## 先頭の 0 を除いた文字列を「長さ → 辞書順」で比べ、数値として等しければ
  ## 元の文字列で決める。文字列の比較は全てバイト順。UTF-8 ではコードポイント
  ## 順と一致するので、Python と同じになる。
  group*: int
  index*: int    # グループ0: SizeOrder の位置
  digits*: string # グループ1: 先頭の 0 を除いた数字列 (全て 0 なら空)
  orig*: string  # 元の文字列 (タイブレーク)

proc upperString(s: string): string =
  ## Go の strings.ToUpper と同じ、ルーン単位の単純大文字化。
  ## Python の str.upper() は ß→SS のような複数文字化をするが、SizeOrder の
  ## 表記に一致するかどうかの判定では単純マッピングと結果が変わらない
  ## (ſ→S は単純マッピングにもある。正解ベクトル 647 件で検証する)。
  result = newStringOfCap(s.len)
  for r in runes(s):
    result.add toUTF8(toUpper(r))

proc isASCIIDigits(s: string): bool =
  if s.len == 0:
    return false
  for ch in s:
    if ch < '0' or ch > '9':
      return false
  true

proc makeSizeKey*(s: string): SizeKey =
  ## size_key(s) に相当するキーを作る。
  let up = upperString(s)
  for i, name in SizeOrder:
    if up == name:
      return SizeKey(group: 0, index: i, orig: s)
  if isASCIIDigits(s):
    return SizeKey(group: 1, digits: s.strip(leading = true, trailing = false,
                   chars = {'0'}), orig: s)
  SizeKey(group: 2, orig: s)

proc cmp*(a, b: SizeKey): int =
  ## a < b なら負、等しければ 0、a > b なら正。
  if a.group != b.group:
    return cmp(a.group, b.group)
  case a.group
  of 0:
    if a.index != b.index:
      return cmp(a.index, b.index)
  of 1:
    if a.digits.len != b.digits.len:
      return cmp(a.digits.len, b.digits.len)
    let c = cmp(a.digits, b.digits)
    if c != 0:
      return c
  else:
    discard
  cmp(a.orig, b.orig)

# ---- JST の時刻表示 ----------------------------------------------------------------

## DB の時刻は SQLite の datetime('now') (UTC の "YYYY-MM-DD HH:MM:SS[.ffffff]")。
## 表示は JST (UTC+9、固定) に直す。Go 版 internal/util/jst.go の移植。
## 暦の変換は civil-from-days (Howard Hinnant の式) で行い、タイムゾーン
## データベースには依存しない。

const jstOffsetSeconds = 9 * 3600

proc daysFromCivil(y, m, d: int): int64 =
  var y = y
  if m <= 2: y -= 1
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400                  # [0, 399]
  let mp = (m + 9) mod 12                  # [0, 11] (3月=0)
  let doy = (153 * mp + 2) div 5 + d - 1   # [0, 365]
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  int64(era) * 146097 + doe - 719468

proc civilFromDays(z0: int64): (int, int, int) =
  let z = z0 + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097               # [0, 146096]
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153           # [0, 11]
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  (int(if m <= 2: y + 1 else: y), int(m), int(d))

proc isLeap(y: int): bool =
  (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0

proc daysInMonth(y, m: int): int =
  const dm = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  if m == 2 and isLeap(y): 29 else: dm[m - 1]

proc parseDateTime(v: string): (int64, bool) =
  ## Go の time.Parse が受ける形: "YYYY-MM-DD HH:MM:SS" / "YYYY-MM-DDTHH:MM:SS"、
  ## それぞれ小数秒 (任意) とオフセット ("Z" または "±hh:mm") を付けた形。
  ## 戻り値は Unix 秒 (UTC)。解釈できなければ ok=false。
  if v.len < 19:
    return (0'i64, false)
  proc numAt(i, n: int): int =
    result = 0
    for k in 0 ..< n:
      let ch = v[i + k]
      if ch < '0' or ch > '9':
        return -1
      result = result * 10 + (ch.ord - '0'.ord)
  let year = numAt(0, 4)
  let month = numAt(5, 2)
  let day = numAt(8, 2)
  let hour = numAt(11, 2)
  let minute = numAt(14, 2)
  let second = numAt(17, 2)
  if year < 0 or month < 0 or day < 0 or hour < 0 or minute < 0 or second < 0:
    return (0'i64, false)
  if v[4] != '-' or v[7] != '-' or (v[10] != ' ' and v[10] != 'T') or
     v[13] != ':' or v[16] != ':':
    return (0'i64, false)
  if month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or
     hour > 23 or minute > 59 or second > 59:
    return (0'i64, false)
  var i = 19
  if i < v.len and (v[i] == '.' or v[i] == ','):
    # 小数秒: 1桁以上の数字が要る (Go のパーサと同じ)
    var j = i + 1
    while j < v.len and v[j] >= '0' and v[j] <= '9':
      j += 1
    if j == i + 1:
      return (0'i64, false)
    i = j
  var offsetSeconds = 0
  if i < v.len:
    if v[i] == 'Z' and i + 1 == v.len:
      discard
    elif (v[i] == '+' or v[i] == '-') and v.len - i == 6 and v[i + 3] == ':':
      let oh = numAt(i + 1, 2)
      let om = numAt(i + 4, 2)
      if oh < 0 or om < 0 or oh > 23 or om > 59:
        return (0'i64, false)
      offsetSeconds = (oh * 3600 + om * 60) * (if v[i] == '-': -1 else: 1)
    else:
      return (0'i64, false)
  let unix = daysFromCivil(year, month, day) * 86400 +
             hour * 3600 + minute * 60 + second - offsetSeconds
  (unix, true)

proc pad2(n: int): string =
  if n < 10: "0" & $n else: $n

proc formatJst*(v: string): string =
  ## UTC 文字列を JST の "MM/DD HH:MM" に直す (Flask 版 format_jst の移植)。
  ## 空文字は空文字、解釈できない値はそのまま返す (Flask 版と同じ)。
  if v == "":
    return ""
  let (unix, ok) = parseDateTime(v)
  if not ok:
    return v
  let jst = unix + jstOffsetSeconds
  let days = if jst >= 0: jst div 86400 else: -((-jst + 86399) div 86400)
  let secs = int(jst - days * 86400)
  let (_, month, day) = civilFromDays(days)
  pad2(month) & "/" & pad2(day) & " " & pad2(secs div 3600) & ":" &
    pad2((secs mod 3600) div 60)

proc dateStampJst*(unixSeconds: int64): string =
  ## CSV ファイル名に使う JST の日付スタンプ "YYYYMMDD"。
  ## 引数は Unix 秒 (UTC)。Go 版は time.Time を受けるが、暦だけが必要なので
  ## 秒で受ける形にした。
  let jst = unixSeconds + jstOffsetSeconds
  let days = if jst >= 0: jst div 86400 else: -((-jst + 86399) div 86400)
  let (year, month, day) = civilFromDays(days)
  align($year, 4, '0') & pad2(month) & pad2(day)
