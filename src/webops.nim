## 書き込み系の画面 (手順4-2。Go 版 internal/web/handlers_ops.go の
## 入荷・プリント変換・出荷/調整と、備考の追加・対応済み切替・削除に対応)。
## 履歴・備考の一覧・CSV 出力は webread 側 (chunk A)。
##
## ルート (すべてログイン必須):
##   GET/POST /receive            入荷
##   GET/POST /convert            プリント変換
##   GET/POST /move               出荷・棚卸し調整
##   POST /notes                  備考の追加
##   POST /notes/{id}/resolve     備考の対応済み切替
##   POST /notes/{id}/delete      備考の削除 (管理者のみ)
##
## 検証に失敗したときは、Flask 版と同じく StockError の文言を danger で
## flash し、送信値を保持したままフォームを再表示する (ステータス 200)。
##
## この版のフォームは Go 版と同じく1行単位 (動的行の JSON プロトコルは
## Flask / Go のどちらにも無い)。数量部品 (qty-step) の操作は、埋め込みの
## app.js が担う。

import std/[json, options]
import db
import repo
import repo_queries
import stock
import util
import webcore
import webread

const tplReceive = staticRead("web/templates/receive.mustache")
const tplConvert = staticRead("web/templates/convert.mustache")
const tplMove = staticRead("web/templates/move.mustache")

proc formIntOr(raw: string, def: int64): int64 =
  ## フォーム/クエリの文字列を整数にする。変換できなければ def
  ## (Flask 版 to_int(raw, def))。検証はサービス層が担うので、既定値は
  ## 「検証に落ちる値」にしておく (数量なら 0、完成数なら -1)。
  let (n, ok) = toInt(raw)
  if ok: n else: def

proc signedStr(d: int64): string =
  ## Go の printf "%+d" と同じ (符号を必ず付ける)。
  if d >= 0: "+" & $d else: $d

proc qtyJson(name, value, label: string, negative = false): JsonNode =
  result = newJObject()
  result["name"] = %name
  result["value"] = %value
  result["label"] = %label
  result["negative"] = %negative

# ---- 入荷 -----------------------------------------------------------------

proc receiveHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let user = st.currentUser().get # Page のガードでログイン済みが保証される
  let formItemId = req.formValue("item_id")
  let formColor = req.formValue("color")
  let formSize = req.formValue("size")
  let formVariantName = req.formValue("variant_name")
  let formQty = req.formValue("qty")
  let formNote = req.formValue("note")
  # Flask 版: selected = to_int(request.values.get("item_id")) (values はクエリが優先)
  var rawSel = req.queryValue("item_id")
  if rawSel == "":
    rawSel = formItemId
  let selected = formIntOr(rawSel, 0)

  if req.httpMethod == "POST":
    var item = none(Item)
    if selected != 0:
      item = conn.getItem(selected)
    let qty = formIntOr(formQty, 0)
    var opErr = ""
    var v: Variant
    if item.isNone:
      opErr = "品番を選んでください。"
    else:
      let it = item.get
      try:
        conn.tx do ():
          v = conn.getOrCreateVariant(it, formColor, formSize, formVariantName)
          discard conn.receive(user.id, v, qty, formNote)
      except StockError as e:
        opErr = e.msg
    if opErr == "":
      st.flash("success", "入荷を登録しました: " & v.label & " +" & $qty)
      return redirect("/receive?item_id=" & $item.get.id)
    st.flash("danger", opErr)

  let items = conn.itemsForSelect()
  let colors = conn.usedColors()
  var itemNotes: seq[Note]
  if selected != 0:
    itemNotes = conn.notes(NotesFilter(itemId: selected))

  let data = newJObject()
  var itemArr = newJArray()
  for it in items:
    var o = newJObject()
    o["id"] = %it.id
    o["selected"] = %(it.id == selected)
    o["usesColorAttr"] = %(if it.useColor: "1" else: "0")
    o["usesSizeAttr"] = %(if it.useSize: "1" else: "0")
    o["usesVariantNameAttr"] = %(if it.useVariantName: "1" else: "0")
    o["categoryName"] = %it.categoryName
    o["label"] = %it.itemLabel
    itemArr.add o
  data["items"] = itemArr
  data["noItems"] = %(items.len == 0)
  var colorArr = newJArray()
  for c in colors:
    colorArr.add %c
  data["colors"] = colorArr
  data["formVariantName"] = %formVariantName
  data["formColor"] = %formColor
  data["formSize"] = %formSize
  data["formNote"] = %formNote
  data["qty"] = qtyJson("qty", formQty, "数量")
  data["hasItemNotes"] = %(selected != 0 and itemNotes.len > 0)
  data["noteList"] = noteListJson(itemNotes, req.requestUri(), user.isAdmin,
                                  st.csrfToken())
  st.renderPage(200, "入荷 | 在庫管理", tplReceive, data)

# ---- プリント変換 ------------------------------------------------------------

proc convertHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let user = st.currentUser().get
  let formVariantId = req.formValue("variant_id")
  let formDesign = req.formValue("design")
  let formDesignNew = req.formValue("design_new")
  let formUsed = req.formValue("used")
  let formOutput = req.formValue("output")
  let formNote = req.formValue("note")

  if req.httpMethod == "POST":
    let vOpt = conn.getVariant(formIntOr(formVariantId, 0))
    let used = formIntOr(formUsed, 0)
    let output = formIntOr(formOutput, -1) # 不正な完成数は「0以上で入力」を出すため -1
    var designName = pyStrip(formDesignNew)
    if designName == "":
      designName = formDesign
    var opErr = ""
    if vOpt.isNone:
      opErr = "無地在庫を選んでください。"
    else:
      let v = vOpt.get
      try:
        conn.tx do ():
          discard conn.convertToPrinted(user.id, v, designName, used, output,
                                        formNote)
      except StockError as e:
        opErr = e.msg
    if opErr == "":
      st.flash("success", "プリント変換しました: " & designName & " / " &
        vOpt.get.label & " (使用 " & $used & " → 完成 " & $output & ")")
      return redirect("/convert")
    st.flash("danger", opErr)

  let variants = conn.printableVariantsInStock()
  let designs = conn.designs()
  let data = newJObject()
  var varArr = newJArray()
  for v in variants:
    var o = newJObject()
    o["id"] = %v.id
    o["selected"] = %(formVariantId == $v.id)
    o["categoryName"] = %v.categoryName
    o["label"] = %v.label
    o["quantity"] = %v.quantity
    varArr.add o
  data["variants"] = varArr
  var desArr = newJArray()
  for d in designs:
    var o = newJObject()
    o["name"] = %d.name
    o["selected"] = %(formDesign == d.name)
    desArr.add o
  data["designs"] = desArr
  data["formDesignNew"] = %formDesignNew
  data["formNote"] = %formNote
  data["used"] = qtyJson("used", formUsed, "使用数(無地から減る数)")
  data["output"] = qtyJson("output", formOutput, "完成数(プリント済みに増える数)")
  st.renderPage(200, "プリント変換 | 在庫管理", tplConvert, data)

# ---- 出荷・棚卸し調整 -----------------------------------------------------------

proc moveHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let user = st.currentUser().get
  let formKind = req.formValue("kind")
  let formTarget = req.formValue("target")
  let formQty = req.formValue("qty")
  let formNote = req.formValue("note")

  if req.httpMethod == "POST":
    let targetOpt = conn.getTarget(formTarget)
    let qty = formIntOr(formQty, 0)
    var opErr = ""
    if targetOpt.isNone:
      opErr = "対象の在庫を選んでください。"
    else:
      let t = targetOpt.get
      try:
        conn.tx do ():
          case formKind
          of "ship":
            discard conn.ship(user.id, t.target, qty, formNote)
          of "adjust":
            discard conn.adjust(user.id, t.target, qty, formNote)
          else:
            raise newException(StockError, "操作の種類を選んでください。")
      except StockError as e:
        opErr = e.msg
    if opErr == "":
      let t = targetOpt.get
      let shown = if formKind == "adjust": signedStr(qty) else: "-" & $qty
      st.flash("success", kindLabelOf(formKind) & "を登録しました: " &
        t.label & " (" & shown & ")")
      return redirect("/move")
    st.flash("danger", opErr)

  let variants = conn.allVariants()
  let products = conn.products("")
  let data = newJObject()
  data["kindAdjust"] = %(formKind == "adjust")
  var prodArr = newJArray()
  for p in products:
    var o = newJObject()
    let value = "p:" & $p.id
    o["value"] = %value
    o["selected"] = %(formTarget == value)
    o["text"] = %(p.label & " (在庫 " & $p.quantity & ")")
    prodArr.add o
  data["products"] = prodArr
  var varArr = newJArray()
  for v in variants:
    var o = newJObject()
    let value = "v:" & $v.id
    o["value"] = %value
    o["selected"] = %(formTarget == value)
    o["text"] = %("[" & v.categoryName & "] " & v.label &
                  " (在庫 " & $v.quantity & ")")
    varArr.add o
  data["variants"] = varArr
  data["formNote"] = %formNote
  data["qty"] = qtyJson("qty", formQty, "数量(調整のときは ± 可)", negative = true)
  st.renderPage(200, "出荷・調整 | 在庫管理", tplMove, data)

# ---- 備考 -----------------------------------------------------------------------

proc noteBack(req: var Request): string =
  ## 備考の操作後に戻る先 (フォームの back。サイト内パスでなければ /notes)。
  let back = safeNext(req.formValue("back"))
  if back != "":
    back
  else:
    "/notes"

proc pathId(req: Request): (int64, bool) =
  ## URL の {id} を整数にする。Flask 版の <int:...> と同じく、ASCII の数字だけ
  ## (符号・空白なし) を受け付け、それ以外はルートに無いものとして扱う。
  let raw = req.pathParam("id")
  if raw == "":
    return (0'i64, false)
  for ch in raw:
    if ch < '0' or ch > '9':
      return (0'i64, false)
  toInt(raw)

proc noteAddHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let itemId = formIntOr(req.formValue("item_id"), 0)
  let body = pyStrip(req.formValue("body"))
  let target = pyStrip(req.formValue("target"))
  let item = conn.getItem(itemId)
  if item.isNone:
    st.flash("danger", "品番が見つかりません。")
  elif body == "":
    st.flash("danger", "備考の内容を入力してください。")
  elif runeCount(body) > 1000 or runeCount(target) > 64:
    st.flash("danger", "備考は1000文字まで、対象は64文字までです。")
  else:
    let user = st.currentUser().get
    conn.tx do ():
      conn.exec(sql"""INSERT INTO item_note (item_id, target, body, is_resolved, user_id, created_at)
        VALUES (?, ?, ?, 0, ?, datetime('now'))""",
        itemId, target, body, user.id)
    st.flash("success", "備考を追加しました。")
  redirect(noteBack(req))

proc noteResolveHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let (id, ok) = pathId(req)
  if not ok:
    raise notFoundError()
  if conn.getNote(id).isNone:
    raise notFoundError()
  conn.tx do ():
    conn.exec(sql"UPDATE item_note SET is_resolved = 1 - is_resolved WHERE id = ?",
              id)
  redirect(noteBack(req))

proc noteDeleteHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  if not st.currentUser().get.isAdmin: # 管理者でなければ、存在確認より先に 403
    raise forbiddenError()
  let (id, ok) = pathId(req)
  if not ok:
    raise notFoundError()
  if conn.getNote(id).isNone:
    raise notFoundError()
  conn.tx do ():
    conn.exec(sql"DELETE FROM item_note WHERE id = ?", id)
  st.flash("success", "備考を削除しました。")
  redirect(noteBack(req))

# ---- ルート登録 ---------------------------------------------------------------------

proc registerOpsRoutes*(app: App) =
  ## 書き込み系の画面を登録する (読み取り系の履歴・備考一覧・CSV は webread)。
  app.pageRoute("GET", "/receive", receiveHandler)
  app.pageRoute("POST", "/receive", receiveHandler)
  app.pageRoute("GET", "/convert", convertHandler)
  app.pageRoute("POST", "/convert", convertHandler)
  app.pageRoute("GET", "/move", moveHandler)
  app.pageRoute("POST", "/move", moveHandler)
  app.pageRoute("POST", "/notes", noteAddHandler)
  app.pageRoute("POST", "/notes/{id}/resolve", noteResolveHandler)
  app.pageRoute("POST", "/notes/{id}/delete", noteDeleteHandler)
