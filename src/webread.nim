## 読み取り系の画面 (手順4-1。Go 版 internal/web/handlers_read.go +
## handlers_ops.go の履歴・備考一覧・CSV 出力に対応)。
##
## ルート (すべてログイン必須):
##   GET /                  ダッシュボード (手順3の仮画面を置き換える)
##   GET /blank             無地在庫 (品番ごとの色×サイズ表)
##   GET /blank/list        無地在庫 (一覧・絞り込み・並べ替え)
##   GET /printed           プリント済み在庫
##   GET /history           操作履歴
##   GET /notes             備考の一覧
##   GET /export/blank.csv, GET /export/printed.csv
##
## mustache には Go テンプレートの「マップをキーで引く」「関数呼び出し」が
## 無いので、並べ替えリンクやマトリクスのセル列のような形は、ハンドラー側で
## 表示用の列に組み立ててから渡す (データの形の変更点はそこだけ)。

import std/[algorithm, json, options, sequtils, sets, strutils, tables, times]
import db
import repo
import repo_queries
import stocklist
import exportcsv
import util
import webcore

const tplDashboard = staticRead("web/templates/dashboard.mustache")
const tplBlankList = staticRead("web/templates/blank_list.mustache")
const tplStockList = staticRead("web/templates/stock_list.mustache")
const tplPrintedList = staticRead("web/templates/printed_list.mustache")
const tplHistory = staticRead("web/templates/history.mustache")
const tplNotes = staticRead("web/templates/notes.mustache")

const HistoryPerPage = 50 ## 履歴の1ページの件数 (Flask 版 HISTORY_PER_PAGE)

proc signedStr(d: int64): string =
  ## Go の printf "%+d" と同じ (符号を必ず付ける)。
  if d >= 0: "+" & $d else: $d

proc qtyClass(q: int64): string =
  ## 在庫セルの色分け (Go テンプレートの {{if eq 0}}zero{{else if le 3}}low)。
  if q == 0: "zero" elif q <= 3: "low" else: ""

# ---- 備考の部品 (Go 版 _notes.html の note_list / note_form への入力) ---------------

proc noteJson(n: Note): JsonNode =
  result = newJObject()
  result["id"] = %n.id
  result["target"] = %n.target
  result["resolved"] = %n.isResolved
  result["username"] = %n.username
  result["createdJst"] = %formatJst(n.createdAt)
  result["body"] = %n.body

proc noteListJson*(noteRows: seq[Note], back: string, isAdmin: bool,
                   csrf: string): JsonNode =
  ## Go 版 NoteList に対応 (partial note_list の入力)。
  result = newJObject()
  var arr = newJArray()
  for n in noteRows:
    arr.add noteJson(n)
  result["notes"] = arr
  result["back"] = %back
  result["isAdmin"] = %isAdmin
  result["csrf"] = %csrf

proc noteFormJson(itemId: int64, targets: seq[string], back,
                  csrf: string): JsonNode =
  ## Go 版 NoteForm に対応 (partial note_form の入力)。
  result = newJObject()
  result["itemId"] = %itemId
  var arr = newJArray()
  for t in targets:
    arr.add %t
  result["targets"] = arr
  result["back"] = %back
  result["csrf"] = %csrf

proc noteTargets*(variants: seq[Variant]): seq[string] =
  ## 備考の対象に選べる値 (その品番にある色・種類名。重複なし、空は除く、
  ## バイト順 = コードポイント順。Flask 版 note_targets と同じ)。
  var set = initHashSet[string]()
  for v in variants:
    if v.color != "":
      set.incl v.color
    if v.variantName != "":
      set.incl v.variantName
  result = toSeq(set)
  result.sort()

# ---- マトリクス (Go 版 internal/web/matrix.go の BuildMatrix) ----------------------

type MatrixRow = object
  label: string
  cells: Table[string, Variant] ## キーはサイズ (サイズ無しカテゴリーでは "")
  total: int64
  hasNote: bool

type Matrix = object
  sizes: seq[string] ## 列の見出し (サイズ順。サイズ無しカテゴリーでは [""])
  rows: seq[MatrixRow]
  targets: seq[string]
  total: int64

proc buildMatrix(item: Item, cat: Category, variants: seq[Variant],
                 noteRows: seq[Note]): Matrix =
  ## Flask 版 build_matrix の移植。variants は repo の並び (variant_name,
  ## color 順) のまま渡すこと。行はその順で作る。
  var noted = initHashSet[string]()
  for n in noteRows:
    if n.target != "":
      noted.incl n.target

  var sizes: seq[string]
  if cat.useSize:
    var seen = initHashSet[string]()
    for v in variants:
      if v.size notin seen:
        seen.incl v.size
        sizes.add v.size
    # 安定ソート: SizeKey の比較で同点になるのは同じ文字列だけ (重複は除いてある)
    sizes.sort do (a, b: string) -> int:
      cmp(makeSizeKey(a), makeSizeKey(b))
  else:
    sizes = @[""]

  var rows: seq[MatrixRow]
  var rowIndex = initTable[(string, string), int]()
  for v in variants:
    let key = (v.variantName, v.color)
    var ri: int
    if key in rowIndex:
      ri = rowIndex[key]
    else:
      var parts: seq[string]
      if key[0] != "":
        parts.add key[0]
      if key[1] != "":
        parts.add key[1]
      var label = parts.join(" / ")
      if label == "":
        label = "-"
      let hasNote = (key[0] != "" and key[0] in noted) or
                    (key[1] != "" and key[1] in noted)
      rows.add MatrixRow(label: label, cells: initTable[string, Variant](),
                         hasNote: hasNote)
      ri = rows.len - 1
      rowIndex[key] = ri
    let cellKey = if cat.useSize: v.size else: ""
    rows[ri].cells[cellKey] = v
    rows[ri].total += v.quantity

  result = Matrix(sizes: sizes, rows: rows, targets: noteTargets(variants))
  for r in rows:
    result.total += r.total

proc matrixItemJson(it: Item, cat: Category, m: Matrix, noteRows: seq[Note],
                    back: string, isAdmin: bool, csrf: string): JsonNode =
  ## マトリクス1品番ぶんの表示データ。セルはサイズ見出しと位置を揃えた列に
  ## して渡す (mustache ではキーでマップを引けないため)。サイズ見出しは
  ## Go 版と同じく品番ごとのもの (その品番のバリエーションから作る)。
  result = newJObject()
  result["itemId"] = %it.id
  result["itemLabel"] = %it.itemLabel
  result["style"] = %it.style
  result["total"] = %m.total
  result["rowHeader"] = %(if cat.useSize: "色 / 種類"
                          elif cat.useVariantName: "種類名" else: "色")
  result["showTotal"] = %cat.useSize
  var sizeHeaders = newJArray()
  for s in m.sizes:
    var h = newJObject()
    h["label"] = %(if s == "": "数量" else: s)
    sizeHeaders.add h
  result["sizeHeaders"] = sizeHeaders
  result["hasNotes"] = %(noteRows.len > 0)
  result["noteList"] = noteListJson(noteRows, back, isAdmin, csrf)
  result["noteForm"] = noteFormJson(it.id, m.targets, back, csrf)
  result["hasRows"] = %(m.rows.len > 0)
  var rows = newJArray()
  for r in m.rows:
    var ro = newJObject()
    ro["label"] = %r.label
    ro["hasNote"] = %r.hasNote
    ro["total"] = %r.total
    var cells = newJArray()
    for s in m.sizes:
      var cell = newJObject()
      if s in r.cells:
        let q = r.cells[s].quantity
        cell["has"] = %true
        cell["qty"] = %q
        cell["cls"] = %qtyClass(q)
      else:
        cell["has"] = %false
      cells.add cell
    ro["cells"] = cells
    rows.add ro
  result["rows"] = rows

# ---- ダッシュボード -----------------------------------------------------------------

proc movementJson(m: Movement): JsonNode =
  result = newJObject()
  result["createdJst"] = %formatJst(m.createdAt)
  result["kindLabel"] = %m.kindLabel
  result["targetLabel"] = %m.targetLabel
  result["deltaStr"] = %signedStr(m.delta)
  result["deltaPos"] = %(m.delta > 0)
  result["username"] = %m.username
  result["note"] = %m.note

proc dashboardHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let cats = conn.categories()
  let blank = conn.blankTotals()
  let printed = conn.printedTotals()
  let recent = conn.recentMovements(8)
  let noteRows = conn.notes(NotesFilter(limit: 5))
  let count = conn.openNoteCount()

  let data = newJObject()
  var cards = newJArray()
  for c in cats:
    var card = newJObject()
    card["id"] = %c.id
    card["name"] = %c.name
    card["blank"] = %blank.getOrDefault(c.id)
    card["printable"] = %c.isPrintable
    if c.isPrintable:
      card["printed"] = %printed.getOrDefault(c.id)
    cards.add card
  data["cards"] = cards
  data["hasCards"] = %(cats.len > 0)
  var ns = newJArray()
  for n in noteRows:
    var o = newJObject()
    o["itemLabel"] = %n.itemLabel
    o["target"] = %n.target
    o["body"] = %n.body
    ns.add o
  data["notes"] = ns
  data["noteCount"] = %count
  var remaining = count - noteRows.len.int64
  if remaining < 0:
    remaining = 0
  data["remaining"] = %remaining
  data["hasRemaining"] = %(remaining > 0)
  var rec = newJArray()
  for m in recent:
    rec.add movementJson(m)
  data["recent"] = rec
  st.renderPage(200, DefaultTitle, tplDashboard, data)

# ---- 無地在庫 (マトリクス) --------------------------------------------------------------

proc blankListHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let cats = conn.categories()
  # ?category= が無効なら、先頭のカテゴリーに寄せる (Flask 版と同じ)
  var cat = none(Category)
  let (wantId, idOk) = toInt(req.queryValue("category"))
  if idOk:
    for c in cats:
      if c.id == wantId:
        cat = some(c)
        break
  if cat.isNone and cats.len > 0:
    cat = some(cats[0])
  let text = pyStrip(req.queryValue("q"))

  let data = newJObject()
  var catArr = newJArray()
  for c in cats:
    var o = newJObject()
    o["id"] = %c.id
    o["name"] = %c.name
    o["active"] = %(cat.isSome and cat.get.id == c.id)
    catArr.add o
  data["cats"] = catArr
  data["hasCats"] = %(cats.len > 0)
  data["hasCat"] = %cat.isSome
  data["q"] = %text
  var items = newJArray()
  if cat.isSome:
    let c = cat.get
    data["catId"] = %c.id
    let variants = conn.variantsInCategory(c.id)
    var byItem = initTable[int64, seq[Variant]]()
    for v in variants:
      byItem.mgetOrPut(v.itemId, @[]).add v
    let catNotes = conn.notes(NotesFilter(categoryId: c.id))
    var notesByItem = initTable[int64, seq[Note]]()
    for n in catNotes:
      notesByItem.mgetOrPut(n.itemId, @[]).add n
    let found = conn.itemsInCategory(c.id, text)
    let back = req.requestUri()
    let csrf = st.csrfToken()
    let user = st.currentUser()
    let isAdmin = user.isSome and user.get.isAdmin
    for it in found:
      let vs = byItem.getOrDefault(it.id)
      let ns = notesByItem.getOrDefault(it.id)
      let m = buildMatrix(it, c, vs, ns)
      items.add matrixItemJson(it, c, m, ns, back, isAdmin, csrf)
  data["items"] = items
  st.renderPage(200, "無地在庫 | 在庫管理", tplBlankList, data)

# ---- 無地在庫 (一覧) -----------------------------------------------------------------------

type SortLink = object
  url: string
  mark: string

proc buildSortLinks(f: Filter): Table[string, SortLink] =
  ## 見出しの並べ替えリンク (Flask 版 stock_list.py と同じ)。
  ## いまの絞り込みのうち、正規化済みで空でないものだけを引き継ぐ。
  ## パラメーターの並びは Python の url_for と同じ
  ## (category, style, color, size, q, in_stock, sort, dir)。
  var keep: seq[(string, string)]
  if f.category.isSome:
    keep.add ("category", $f.category.get)
  if f.style != "":
    keep.add ("style", f.style)
  if f.color != "":
    keep.add ("color", f.color)
  if f.size != "":
    keep.add ("size", f.size)
  if f.q != "":
    keep.add ("q", f.q)
  if f.inStock:
    keep.add ("in_stock", "1")
  result = initTable[string, SortLink]()
  for sk in SortKeys:
    let active = f.sort == sk.value
    var next = "asc"
    if active and f.dir == "asc":
      next = "desc"
    var mark = ""
    if active:
      mark = if f.dir == "asc": "▲" else: "▼"
    var parts: seq[string]
    for (k, v) in keep:
      parts.add queryEscape(k) & "=" & queryEscape(v)
    parts.add "sort=" & queryEscape(sk.value)
    parts.add "dir=" & next
    result[sk.value] = SortLink(url: "/blank/list?" & parts.join("&"), mark: mark)

proc optionJson(values: seq[string], selected: string): JsonNode =
  result = newJArray()
  for v in values:
    var o = newJObject()
    o["v"] = %v
    o["selected"] = %(v == selected)
    result.add o

proc stockListHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let f = parseFilter(req.query)
  let res = conn.searchStock(f)
  let opts = conn.listOptions()
  let cats = conn.categories()
  let links = buildSortLinks(f)

  let data = newJObject()
  var catArr = newJArray()
  for c in cats:
    var o = newJObject()
    o["id"] = %c.id
    o["name"] = %c.name
    o["selected"] = %(f.category.isSome and f.category.get == c.id)
    catArr.add o
  data["cats"] = catArr
  data["styles"] = optionJson(opts.styles, f.style)
  data["colors"] = optionJson(opts.colors, f.color)
  data["sizes"] = optionJson(opts.sizes, f.size)
  var sorts = newJArray()
  var headers = newJArray()
  for sk in SortKeys:
    var o = newJObject()
    o["key"] = %sk.value
    o["label"] = %sk.label
    o["selected"] = %(sk.value == f.sort)
    sorts.add o
    var h = newJObject()
    h["label"] = %sk.label
    h["url"] = %links[sk.value].url
    h["mark"] = %links[sk.value].mark
    h["cls"] = %(if sk.value == "qty": "text-end text-nowrap"
                 else: "text-nowrap")
    headers.add h
  data["sorts"] = sorts
  data["headers"] = headers
  data["q"] = %f.q
  data["inStock"] = %f.inStock
  data["dirAsc"] = %(f.dir == "asc")
  data["dirDesc"] = %(f.dir == "desc")
  data["count"] = %res.count
  data["totalQty"] = %res.totalQty
  data["truncated"] = %res.truncated
  data["shown"] = %res.rows.len
  var rows = newJArray()
  for r in res.rows:
    var o = newJObject()
    o["categoryName"] = %r.categoryName
    o["styleDisp"] = %(if r.style != "": r.style else: "–")
    o["itemLabel"] = %r.itemLabel
    o["stopped"] = %(not r.itemActive)
    o["rowCls"] = %(if r.itemActive: "" else: "text-muted")
    let sp = r.spec
    o["specDisp"] = %(if sp != "": sp else: "–")
    o["sizeDisp"] = %(if r.size != "": r.size else: "–")
    o["qty"] = %r.quantity
    o["qtyCls"] = %qtyClass(r.quantity)
    rows.add o
  data["rows"] = rows
  st.renderPage(200, "無地在庫(一覧) | 在庫管理", tplStockList, data)

# ---- プリント済み ----------------------------------------------------------------------------

proc printedListHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let text = pyStrip(req.queryValue("q"))
  let products = st.db().products(text)
  # デザイン名でまとめる (最初に現れた順。repo 側でデザイン名順に並んでいる)
  let data = newJObject()
  data["q"] = %text
  var groups = newJArray()
  var index = initTable[string, int]()
  var groupTotals: seq[int64]
  var groupRows: seq[JsonNode]
  for p in products:
    var gi: int
    if p.designName in index:
      gi = index[p.designName]
    else:
      var g = newJObject()
      g["name"] = %p.designName
      groups.add g
      groupRows.add newJArray()
      groupTotals.add 0
      gi = groups.len - 1
      index[p.designName] = gi
    var o = newJObject()
    o["categoryName"] = %p.categoryName
    o["itemLabel"] = %itemLabel(p.brand, p.itemNo, p.itemName, p.itemId)
    o["spec"] = %p.spec
    o["quantity"] = %p.quantity
    groupRows[gi].add o
    groupTotals[gi] += p.quantity
  for i in 0 ..< groups.len:
    groups[i]["rows"] = groupRows[i]
    groups[i]["total"] = %groupTotals[i]
  data["groups"] = groups
  st.renderPage(200, "プリント済み | 在庫管理", tplPrintedList, data)

# ---- 履歴 ---------------------------------------------------------------------------------------

proc formIntOr(raw: string, def: int64): int64 =
  ## フォーム/クエリの文字列を整数にする。変換できなければ def
  ## (Flask 版 to_int(raw, def))。
  let (n, ok) = toInt(raw)
  if ok: n else: def

proc historyHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  var page = formIntOr(req.queryValue("page"), 1)
  if page < 1:
    page = 1
  if page > 100000: # OFFSET の計算が溢れないように (Flask 版と同じ上限)
    page = 100000
  let kind = req.queryValue("kind")
  let pg = st.db().movementsPage(kind, page, HistoryPerPage)
  let data = newJObject()
  data["kind"] = %kind
  var kinds = newJArray()
  for (k, label) in KindLabels:
    var o = newJObject()
    o["key"] = %k
    o["label"] = %label
    o["selected"] = %(k == kind)
    kinds.add o
  data["kinds"] = kinds
  var items = newJArray()
  for m in pg.items:
    items.add movementJson(m)
  data["items"] = items
  data["hasPrev"] = %pg.hasPrev
  data["prevNum"] = %pg.prevNum
  data["hasNext"] = %pg.hasNext
  data["nextNum"] = %pg.nextNum
  st.renderPage(200, "履歴 | 在庫管理", tplHistory, data)

# ---- 備考の一覧 ------------------------------------------------------------------------------------

proc notesListHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let showAll = req.queryValue("all") == "1"
  let noteRows = st.db().notes(NotesFilter(includeResolved: showAll))
  let back = req.requestUri()
  let csrf = st.csrfToken()
  let user = st.currentUser()
  let isAdmin = user.isSome and user.get.isAdmin
  let data = newJObject()
  data["showAll"] = %showAll
  var panels = newJArray()
  for n in noteRows:
    var o = newJObject()
    o["itemLabel"] = %n.itemLabel
    o["categoryId"] = %n.categoryId
    o["categoryName"] = %n.categoryName
    # 見出しリンクの検索語 (Flask 版: item_no が無ければ brand)。
    # href のクエリ部品なので、Go 版 html/template と同じく URL エスケープ済みで渡す。
    let q = if n.itemNo != "": n.itemNo else: n.brand
    o["qEsc"] = %queryEscape(q)
    o["list"] = noteListJson(@[n], back, isAdmin, csrf)
    panels.add o
  data["panels"] = panels
  st.renderPage(200, "備考 | 在庫管理", tplNotes, data)

# ---- CSV 出力 ----------------------------------------------------------------------------------------

proc csvResponse(name, body: string): Response =
  Response(status: 200, headers: @[
    ("Content-Type", "text/csv; charset=utf-8"),
    ("Content-Disposition",
     "attachment; filename=\"" & csvFilename(name, epochTime().int64) & "\""),
    ("Cache-Control", "no-store"), # 在庫データなので、共有キャッシュに残さない
  ], body: body)

proc exportBlankHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  var cat = none(int64)
  let (n, ok) = toInt(req.queryValue("category"))
  if ok:
    cat = some(n) # 存在しない ID は、見出しだけの CSV になる (Flask 版と同じ)
  csvResponse("inventory_blank", st.db().blankCsv(cat))

proc exportPrintedHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  csvResponse("inventory_printed", st.db().printedCsv())

# ---- ルート登録 ------------------------------------------------------------------------------------------------

proc registerReadRoutes*(app: App) =
  ## 読み取り系の画面を登録する。GET / は手順3の仮ダッシュボードを置き換える。
  discard app.replaceRouteHandler("GET", "/", dashboardHandler)
  app.pageRoute("GET", "/blank", blankListHandler)
  app.pageRoute("GET", "/blank/list", stockListHandler)
  app.pageRoute("GET", "/printed", printedListHandler)
  app.pageRoute("GET", "/history", historyHandler)
  app.pageRoute("GET", "/notes", notesListHandler)
  app.pageRoute("GET", "/export/blank.csv", exportBlankHandler)
  app.pageRoute("GET", "/export/printed.csv", exportPrintedHandler)
