## 管理画面 (カテゴリー・品番・ユーザー) のハンドラー (手順4-3。
## Go 版 internal/web/handlers_admin.go の移植。Flask 版 app/admin/routes.py)。
## すべて管理者専用 (adminRoute)。検証に失敗したら、flash を出して同じ画面を
## 出し直す (Flask 版と同じで、入力値は保持しない。編集画面は DB の値で
## 出し直す)。
##
## ルート:
##   GET/POST /admin/categories            一覧 + 追加
##   GET/POST /admin/categories/{id}       編集
##   GET/POST /admin/items                 一覧 + 追加
##   GET/POST /admin/items/{id}            編集
##   GET/POST /admin/users                 一覧 + 追加
##   POST     /admin/users/{id}/toggle     有効/無効の切替
##   POST     /admin/users/{id}/password   パスワード再設定

import std/[json, options, strutils]
import db
import repo
import adminsvc
import stocklist
import util
import webcore

const tplAdminCategories = staticRead("web/templates/admin_categories.mustache")
const tplAdminCategoryEdit = staticRead("web/templates/admin_category_edit.mustache")
const tplAdminItems = staticRead("web/templates/admin_items.mustache")
const tplAdminItemEdit = staticRead("web/templates/admin_item_edit.mustache")
const tplAdminUsers = staticRead("web/templates/admin_users.mustache")

proc pathId(req: Request): (int64, bool) =
  ## URL の {id} を整数にする。Flask 版の <int:...> と同じく、ASCII の数字だけ
  ## (符号・空白なし) を受け付け、それ以外はルートに無いものとして扱う
  ## (webops の pathId と同じ)。
  let raw = req.pathParam("id")
  if raw == "":
    return (0'i64, false)
  for ch in raw:
    if ch < '0' or ch > '9':
      return (0'i64, false)
  toInt(raw)

proc flagOn(req: var Request, name: string): bool =
  ## Flask 版 _flag (チェックボックスは "on" のときだけ真)。
  req.formValue(name) == "on"

proc formFlags(req: var Request): CategoryFlags =
  CategoryFlags(useColor: flagOn(req, "uses_color"),
                useSize: flagOn(req, "uses_size"),
                useVariantName: flagOn(req, "uses_variant_name"),
                isPrintable: flagOn(req, "is_printable"))

proc categoryJson(cat: Category, selectedId = 0'i64): JsonNode =
  result = newJObject()
  result["id"] = %cat.id
  result["name"] = %cat.name
  result["sortOrder"] = %cat.sortOrder
  result["useColor"] = %cat.useColor
  result["useSize"] = %cat.useSize
  result["useVariantName"] = %cat.useVariantName
  result["isPrintable"] = %cat.isPrintable
  result["active"] = %(cat.id == selectedId and selectedId != 0)
  result["selected"] = %(cat.id == selectedId and selectedId != 0)

proc stylesJson(styles: seq[string]): JsonNode =
  result = newJArray()
  for s in styles:
    let o = newJObject()
    o["v"] = %s
    result.add o

# ---- カテゴリー ------------------------------------------------------

proc categoriesHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  if req.httpMethod == "POST":
    let name = req.formValue("name")
    let flags = formFlags(req)
    var errMsg = ""
    try:
      conn.tx do ():
        discard conn.createCategory(name, flags)
    except AdminError as e:
      errMsg = e.msg
    if errMsg == "":
      st.flash("success", "カテゴリーを追加しました: " & pyStrip(name))
      return redirect("/admin/categories")
    st.flash("danger", errMsg)
  let data = newJObject()
  var cats = newJArray()
  for cat in conn.categories():
    cats.add categoryJson(cat)
  data["cats"] = cats
  st.renderPage(200, DefaultTitle, tplAdminCategories, data)

proc categoryEditHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let (id, ok) = pathId(req)
  if not ok:
    raise notFoundError()
  let catOpt = conn.getCategory(id)
  if catOpt.isNone:
    raise httpError(404, "カテゴリーが見つかりません。")
  let cat = catOpt.get
  if req.httpMethod == "POST":
    let rawOrder = pyStrip(req.formValue("sort_order"))
    var sortOrder = 0'i64
    var valid = true # 空欄は 0 (Flask 版と同じ)
    if rawOrder != "":
      let (n, okInt) = toInt(rawOrder)
      if not okInt:
        valid = false
      else:
        sortOrder = n
    let flags = formFlags(req)
    if not valid:
      st.flash("danger", "表示順は整数で入力してください。")
    else:
      let blocked = conn.flagsInUse(cat, flags)
      if blocked.len > 0:
        st.flash("danger", "「" & blocked.join("」「") &
          "」は、既に在庫登録があるためOFFにできません。" &
          "(OFFにすると、同じ行・列の在庫が1つに見えてしまいます)")
      else:
        let newName = req.formValue("name")
        var errMsg = ""
        try:
          conn.tx do ():
            conn.updateCategory(cat, newName, int(sortOrder), flags)
        except AdminError as e:
          errMsg = e.msg
        if errMsg == "":
          st.flash("success", "カテゴリーを更新しました。")
          return redirect("/admin/categories")
        st.flash("danger", errMsg)
  # 編集画面は DB の値で出す (送信値は保持しない。Go 版と同じ)
  st.renderPage(200, DefaultTitle, tplAdminCategoryEdit, categoryJson(cat))

# ---- 品番 ------------------------------------------------------------

proc queryCatId(req: Request): int64 =
  ## 一覧の絞り込み (Flask 版 to_int(request.args.get("category")))。
  ## 変換できない・指定なしは 0 (= すべて)。
  let (n, ok) = toInt(req.queryValue("category"))
  if ok: n else: 0

proc renderItems(st: var ReqState, req: var Request): Response =
  let conn = st.db()
  let catId = queryCatId(req)
  let data = newJObject()
  data["allActive"] = %(catId == 0)
  var cats = newJArray()
  for cat in conn.categories():
    cats.add categoryJson(cat, catId)
  data["cats"] = cats
  data["styles"] = stylesJson(conn.styleChoices())
  var items = newJArray()
  for it in conn.itemsAdmin(catId):
    let o = newJObject()
    o["id"] = %it.id
    o["categoryName"] = %it.categoryName
    o["brand"] = %it.brand
    o["itemNo"] = %it.itemNo
    o["name"] = %it.name
    o["style"] = %it.style
    o["isActive"] = %it.isActive
    items.add o
  data["items"] = items
  st.renderPage(200, DefaultTitle, tplAdminItems, data)

proc itemsHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  if req.httpMethod == "POST":
    let (rawId, okInt) = toInt(req.formValue("category_id")) # Flask 版 to_int(..., 0)
    let catId = if okInt: rawId else: 0'i64
    let catOpt = conn.getCategory(catId)
    if catOpt.isNone:
      st.flash("danger", "カテゴリーを選んでください。")
    else:
      let cat = catOpt.get
      let brand = req.formValue("brand")
      let itemNo = req.formValue("item_no")
      let itemName = req.formValue("name")
      let style = req.formValue("style")
      var errMsg = ""
      try:
        conn.tx do ():
          discard conn.createItem(cat.id, brand, itemNo, itemName, style)
      except AdminError as e:
        errMsg = e.msg
      if errMsg == "":
        st.flash("success", "品番を追加しました。")
        return redirect("/admin/items?category=" & $cat.id)
      st.flash("danger", errMsg)
  renderItems(st, req)

proc itemEditHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let (id, ok) = pathId(req)
  if not ok:
    raise notFoundError()
  let itemOpt = conn.getItem(id)
  if itemOpt.isNone:
    raise httpError(404, "品番が見つかりません。")
  let item = itemOpt.get
  if req.httpMethod == "POST":
    let brand = req.formValue("brand")
    let itemNo = req.formValue("item_no")
    let itemName = req.formValue("name")
    let style = req.formValue("style")
    let isActive = flagOn(req, "is_active")
    var errMsg = ""
    try:
      conn.tx do ():
        conn.updateItem(item.id, brand, itemNo, itemName, style, isActive)
    except AdminError as e:
      errMsg = e.msg
    if errMsg == "":
      st.flash("success", "品番を更新しました。")
      return redirect("/admin/items?category=" & $item.categoryId)
    st.flash("danger", errMsg)
  let data = newJObject()
  data["categoryName"] = %item.categoryName
  data["brand"] = %item.brand
  data["itemNo"] = %item.itemNo
  data["name"] = %item.name
  data["style"] = %item.style
  data["isActive"] = %item.isActive
  data["styles"] = stylesJson(conn.styleChoices())
  st.renderPage(200, DefaultTitle, tplAdminItemEdit, data)

# ---- ユーザー --------------------------------------------------------

proc renderUsers(st: var ReqState): Response =
  let conn = st.db()
  let csrf = st.csrfToken() # 行内のフォーム用 (noteListJson と同じ流儀)
  let data = newJObject()
  var users = newJArray()
  for u in conn.listUsers():
    let o = newJObject()
    o["id"] = %u.id
    o["username"] = %u.username
    o["isAdmin"] = %u.isAdmin
    o["roleLabel"] = %(if u.isAdmin: "管理者" else: "スタッフ")
    o["isActive"] = %u.isActive
    o["stateLabel"] = %(if u.isActive: "有効" else: "無効")
    o["csrf"] = %csrf
    users.add o
  data["users"] = users
  st.renderPage(200, DefaultTitle, tplAdminUsers, data)

proc usersHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  if req.httpMethod == "POST":
    let username = req.formValue("username")
    let password = req.formValue("password")
    let role = req.formValue("role")
    var errMsg = ""
    try:
      conn.tx do ():
        discard conn.createUser(username, password, role)
    except AdminError as e:
      errMsg = e.msg
    if errMsg == "":
      st.flash("success", "ユーザーを追加しました: " & pyStrip(username))
      return redirect("/admin/users")
    st.flash("danger", errMsg)
  renderUsers(st)

proc adminTargetUser(st: var ReqState, req: Request): User =
  ## toggle / password の対象ユーザー。無ければ、その旨のエラーを投げる。
  let (id, ok) = pathId(req)
  if not ok:
    raise notFoundError()
  let u = st.db().getUser(id)
  if u.isNone:
    raise httpError(404, "ユーザーが見つかりません。")
  u.get

proc userToggleHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let u = adminTargetUser(st, req)
  if u.id == st.currentUser().get.id:
    st.flash("danger", "自分自身は無効化できません。")
  else:
    let newState = not u.isActive
    conn.tx do ():
      conn.setUserActive(u.id, newState)
    st.flash("success", u.username & " を" &
             (if newState: "有効" else: "無効") & "にしました。")
  redirect("/admin/users")

proc userPasswordHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let conn = st.db()
  let u = adminTargetUser(st, req)
  let password = req.formValue("password")
  var errMsg = ""
  try:
    conn.tx do ():
      conn.resetUserPassword(u.id, password)
  except AdminError as e:
    errMsg = e.msg
  if errMsg != "":
    st.flash("danger", errMsg)
  else:
    if u.id == st.currentUser().get.id:
      # 自分自身を再設定した場合は入り直し (Flask 版 login_user の呼び直しと同じ)
      let updated = conn.getUser(u.id)
      if updated.isSome:
        st.refreshToken(updated.get)
    st.flash("success", u.username &
             " のパスワードを再設定しました。(その人は再ログインが必要になります)")
  redirect("/admin/users")

# ---- ルート登録 ---------------------------------------------------------------------

proc registerAdminRoutes*(app: App) =
  ## 管理画面を登録する (すべて管理者専用)。
  app.adminRoute("GET", "/admin/categories", categoriesHandler)
  app.adminRoute("POST", "/admin/categories", categoriesHandler)
  app.adminRoute("GET", "/admin/categories/{id}", categoryEditHandler)
  app.adminRoute("POST", "/admin/categories/{id}", categoryEditHandler)
  app.adminRoute("GET", "/admin/items", itemsHandler)
  app.adminRoute("POST", "/admin/items", itemsHandler)
  app.adminRoute("GET", "/admin/items/{id}", itemEditHandler)
  app.adminRoute("POST", "/admin/items/{id}", itemEditHandler)
  app.adminRoute("GET", "/admin/users", usersHandler)
  app.adminRoute("POST", "/admin/users", usersHandler)
  app.adminRoute("POST", "/admin/users/{id}/toggle", userToggleHandler)
  app.adminRoute("POST", "/admin/users/{id}/password", userPasswordHandler)
