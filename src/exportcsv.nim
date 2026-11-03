## CSV 出力 (Go 版 internal/service/export.go の移植)。
##
## Python の csv モジュール (QUOTE_MINIMAL) とバイト単位で一致させるため、
## 自前のライターで書く: BOM 付き UTF-8、改行は CRLF、引用は , " CR LF を
## 含むときだけ (先頭スペースでは引用しない — Go の encoding/csv との違い)。

import std/[algorithm, options, strutils, unicode]
import db
import repo
import util

const BlankHeaders* = ["カテゴリー", "ブランド", "品番", "商品名", "色", "サイズ",
                       "種類名", "数量", "品番の状態"]
const PrintedHeaders* = ["デザイン", "カテゴリー", "ブランド", "品番", "商品名",
                         "色", "サイズ", "種類名", "数量"]

type
  CsvCellKind* = enum ccText, ccInt
  CsvCell* = object
    ## CSV のセル: 文字列か整数か (Go 版の any に対応)。
    case kind*: CsvCellKind
    of ccText: text*: string
    of ccInt: num*: int64

proc ctext*(s: string): CsvCell = CsvCell(kind: ccText, text: s)
proc cint*(n: int64): CsvCell = CsvCell(kind: ccInt, num: n)

proc safeCell*(c: CsvCell): CsvCell =
  ## 数式インジェクション対策 (Excel 等で数式として解釈される先頭文字に ' を付ける)。
  ## 先頭「文字」を見る: \r を先頭に持つ値はこの後の CSV 引用でも数式化しないが、
  ## Flask 版が付けているので合わせる。
  if c.kind == ccText and c.text.len > 0:
    # Go 版は strings.ContainsRune("=+-@\t\r", 先頭ルーン) で判定 (全て ASCII)
    let first = toUTF8(runeAt(c.text, 0))
    if first.len == 1 and first[0] in "=+-@\t\r":
      return CsvCell(kind: ccText, text: "'" & c.text)
  c

proc csvField(s: string): string =
  if s.contains({',', '"', '\r', '\n'}):
    return "\"" & s.replace("\"", "\"\"") & "\""
  s

proc cellText(c: CsvCell): string =
  case c.kind
  of ccText: c.text
  of ccInt: $c.num

proc toCsvBytes*(headers: seq[string], rows: seq[seq[CsvCell]]): string =
  ## BOM + CRLF の CSV 全体。数式対策はデータ行にだけ適用 (見出しは固定文言)。
  result = "\xEF\xBB\xBF" # BOM (Excel で UTF-8 として開かせる)
  var line: seq[string]
  for h in headers:
    line.add csvField(h)
  result.add line.join(",") & "\r\n"
  for row in rows:
    line.setLen(0)
    for c in row:
      line.add csvField(cellText(safeCell(c)))
    result.add line.join(",") & "\r\n"

proc sortDecorated[T](rows: var seq[T], cmpFn: proc(a, b: T): int {.closure.}) =
  ## 安定ソート (元の位置をタイブレークにして安定性を保証する)。
  var indexed = newSeq[(T, int)](rows.len)
  for i, r in rows:
    indexed[i] = (r, i)
  indexed.sort do (a, b: (T, int)) -> int:
    let c = cmpFn(a[0], b[0])
    if c != 0: c else: cmp(a[1], b[1])
  for i, it in indexed:
    rows[i] = it[0]

proc blankRows*(db: DbConn, categoryId: Option[int64]): seq[seq[CsvCell]] =
  var vs: seq[Variant]
  for v in db.allVariants():
    if categoryId.isNone or v.categoryId == categoryId.get:
      vs.add v
  vs.sortDecorated do (a, b: Variant) -> int:
    result = cmp(a.categoryOrder, b.categoryOrder)
    if result != 0: return
    result = cmp(a.brand, b.brand)
    if result != 0: return
    result = cmp(a.itemNo, b.itemNo)
    if result != 0: return
    result = cmp(a.itemId, b.itemId)
    if result != 0: return
    result = cmp(a.variantName, b.variantName)
    if result != 0: return
    result = cmp(a.color, b.color)
    if result != 0: return
    result = cmp(makeSizeKey(a.size), makeSizeKey(b.size))
  for v in vs:
    result.add @[
      ctext(v.categoryName), ctext(v.brand), ctext(v.itemNo),
      ctext(v.itemName), ctext(v.color), ctext(v.size),
      ctext(v.variantName), cint(v.quantity),
      ctext(if v.itemActive: "使用中" else: "停止中"),
    ]

proc blankCsv*(db: DbConn, categoryId: Option[int64]): string =
  toCsvBytes(@BlankHeaders, db.blankRows(categoryId))

proc printedRows*(db: DbConn): seq[seq[CsvCell]] =
  var ps = db.products("")
  ps.sortDecorated do (a, b: Product) -> int:
    result = cmp(a.designName, b.designName)
    if result != 0: return
    result = cmp(a.categoryOrder, b.categoryOrder)
    if result != 0: return
    result = cmp(a.brand, b.brand)
    if result != 0: return
    result = cmp(a.itemNo, b.itemNo)
    if result != 0: return
    result = cmp(a.itemId, b.itemId)
    if result != 0: return
    result = cmp(a.variantName, b.variantName)
    if result != 0: return
    result = cmp(a.color, b.color)
    if result != 0: return
    result = cmp(makeSizeKey(a.size), makeSizeKey(b.size))
  for p in ps:
    result.add @[
      ctext(p.designName), ctext(p.categoryName), ctext(p.brand),
      ctext(p.itemNo), ctext(p.itemName), ctext(p.color), ctext(p.size),
      ctext(p.variantName), cint(p.quantity),
    ]

proc printedCsv*(db: DbConn): string =
  toCsvBytes(@PrintedHeaders, db.printedRows())

proc csvFilename*(name: string, unixSecondsUtc: int64): string =
  ## 例: inventory_blank_20261031.csv (日付は JST)。Go 版は time.Time を
  ## 受けるが、暦だけが必要なので Unix 秒で受ける形にした。
  name & "_" & dateStampJst(unixSecondsUtc) & ".csv"
