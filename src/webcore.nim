## Web 層の基盤 (Go 版 internal/web に対応)。
##
## この手順 (3) で作るのは、画面に依存しない共通部品:
## 署名付き Cookie のセッション、ログイン保持 (remember)、CSRF、flash、
## 権限チェック、エラーページ、no-store、DB が未作成/古いときの案内 (503)、
## 静的ファイル。各画面 (手順4) は、Public / Page / AdminPage に相当する
## 登録手続きでこの上に載せる。
##
## ハンドラーは「Request を受けて Response を返す proc」として書き、
## mummy への変換は末尾のアダプター (serveHttp) だけが行う。
## テストはソケットを開かず、handle を直接呼んで確かめる。

import std/[atomics, json, options, strutils, tables, times, unicode]
import nimcrypto/[hmac, sha2, sysrand, utils]
import mustache
import db
import repo
import authsvc
import util
import sessioncodec

export options

# ---- HTTP の抽象 (テストから直接呼べる形) -----------------------------------------

type Headers* = seq[(string, string)]

type Request* = object
  ## 1リクエストの入力。mummy アダプターかテストが組み立てる。
  httpMethod*: string
  path*: string       ## 復号済みのパス (ルーティング・静的ファイル用)
  rawPath*: string    ## 未復号のパス (ドットセグメント判定・next 用)
  queryString*: string ## 生のクエリ文字列
  query*: Headers     ## 復号済みのクエリ引数
  pathParams*: Headers ## ルートの {name} セグメントに入った値 (ルーティングで設定)
  headers*: Headers
  body*: string
  cookies*: Table[string, string]
  form: Headers
  formParsed: bool
  formError: bool     ## 本体が上限を超える等で、フォームを読めなかった

type Response* = object
  status*: int
  headers*: Headers
  body*: string

proc headerGet*(headers: Headers, name: string): string =
  ## ヘッダーを大文字小文字を区別せず探す。無ければ空文字。
  for (k, v) in headers:
    if cmpIgnoreCase(k, name) == 0:
      return v
  ""

proc paramGet*(params: Headers, name: string): string =
  for (k, v) in params:
    if k == name:
      return v
  ""

proc queryValue*(req: Request, name: string): string = paramGet(req.query, name)

proc pathParam*(req: Request, name: string): string =
  ## ルートの {name} セグメントの値。無ければ空文字。
  paramGet(req.pathParams, name)

proc requestUri*(req: Request): string =
  ## パス+クエリ (Go の URL.RequestURI 相当)。
  if req.queryString == "":
    req.rawPath
  else:
    req.rawPath & "?" & req.queryString

proc percentDecode(s: string, plusAsSpace: bool): string =
  ## %XX を復号する。不正な % はそのまま残す (Go の PathUnescape の誤りは
  ## ドットセグメント判定では「ドットではない」として扱うため、ここでは
  ## 寛容に進める)。
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      var v = 0
      var ok = true
      for j in 1 .. 2:
        let c = s[i + j]
        v = v shl 4
        case c
        of '0' .. '9': v = v or (ord(c) - ord('0'))
        of 'a' .. 'f': v = v or (ord(c) - ord('a') + 10)
        of 'A' .. 'F': v = v or (ord(c) - ord('A') + 10)
        else: ok = false
      if ok:
        result.add char(v)
        i += 3
        continue
    if s[i] == '+' and plusAsSpace:
      result.add ' '
    else:
      result.add s[i]
    inc i

proc parseParams*(s: string): Headers =
  ## "a=1&b=2" 形式を復号して引数の列にする (クエリ・フォーム共用)。
  for pair in s.split('&'):
    if pair == "":
      continue
    let eq = pair.find('=')
    if eq < 0:
      result.add (percentDecode(pair, true), "")
    else:
      result.add (percentDecode(pair[0 ..< eq], true),
                  percentDecode(pair[eq + 1 ..^ 1], true))

proc newRequest*(httpMethod, target: string): Request =
  ## 対象 URL (パス+クエリ) から Request を作る。テストとアダプター用。
  result.httpMethod = httpMethod
  let q = target.find('?')
  if q < 0:
    result.rawPath = target
  else:
    result.rawPath = target[0 ..< q]
    result.queryString = target[q + 1 ..^ 1]
  result.path = percentDecode(result.rawPath, false)
  result.query = parseParams(result.queryString)
  result.cookies = initTable[string, string]()

proc parseCookies*(header: string): Table[string, string] =
  ## Cookie ヘッダーを名前→値にする。
  result = initTable[string, string]()
  for part in header.split(';'):
    let p = part.strip()
    let eq = p.find('=')
    if eq > 0:
      result[p[0 ..< eq].strip()] = p[eq + 1 ..^ 1].strip()

const MaxBody* = 1 shl 20 ## フォームの最大サイズ (1 MiB。Go 版 maxBody)

proc parseForm*(req: var Request) =
  ## 本体をフォームとして読む (urlencoded と multipart のフィールドのみ)。
  ## Go の ParseMultipartForm と同じく、対象外の Content-Type では空になる。
  if req.formParsed:
    return
  req.formParsed = true
  if req.body.len > MaxBody:
    req.formError = true
    return
  let ct = headerGet(req.headers, "Content-Type")
  if ct.toLowerAscii.startsWith("application/x-www-form-urlencoded"):
    req.form = parseParams(req.body)
  elif ct.toLowerAscii.startsWith("multipart/form-data"):
    let bpos = ct.toLowerAscii.find("boundary=")
    if bpos < 0:
      return
    var boundary = ct[bpos + 9 ..^ 1].strip()
    if boundary.len >= 2 and boundary[0] == '"' and boundary[^1] == '"':
      boundary = boundary[1 .. ^2]
    let delim = "--" & boundary
    for part in req.body.split(delim):
      var p = part
      if p.startsWith("\r\n"):
        p = p[2 ..^ 1]
      if p == "" or p == "--" or p == "--\r\n":
        continue
      let sep = p.find("\r\n\r\n")
      if sep < 0:
        continue
      let head = p[0 ..< sep]
      var value = p[sep + 4 ..^ 1]
      if value.endsWith("\r\n"):
        value = value[0 .. ^3]
      if "filename=" in head:
        continue # ファイル部品はフォーム値にしない (Go の PostForm と同じ)
      for line in head.split("\r\n"):
        if line.toLowerAscii.startsWith("content-disposition:"):
          let npos = line.find("name=\"")
          if npos >= 0:
            let nend = line.find('"', npos + 6)
            if nend > npos:
              req.form.add (line[npos + 6 ..< nend], value)

proc formValue*(req: var Request, name: string): string =
  parseForm(req)
  paramGet(req.form, name)

# ---- 設定 ---------------------------------------------------------------------------

type
  LogFn* = proc (msg: string) {.gcsafe.}
  NowFn* = proc (): int64 {.gcsafe.} ## Unix 秒を返す (テストで差し替え可能)

  WebConfig* = object
    databasePath*: string
    secretKey*: string
    cookieSecure*: bool
    sessionLifetime*: int64  ## 秒。0 なら既定 (14日。Flask 版 PERMANENT_SESSION_LIFETIME)
    rememberDuration*: int64 ## 秒。0 なら既定 (365日。Flask-Login の既定)
    csrfTtl*: int64          ## 秒。0 なら既定 (1時間。Flask-WTF の既定)
    initHint*: string        ## 503 の案内 (管理者向け)。"" なら既定文
    log*: LogFn
    now*: NowFn

proc defaultLog(msg: string) {.gcsafe.} =
  stderr.writeLine(msg)

proc defaultNow(): int64 {.gcsafe.} =
  epochTime().int64

proc applyDefaults(cfg: var WebConfig) =
  if cfg.sessionLifetime == 0:
    cfg.sessionLifetime = 14 * 24 * 3600
  if cfg.rememberDuration == 0:
    cfg.rememberDuration = 365 * 24 * 3600
  if cfg.csrfTtl == 0:
    cfg.csrfTtl = 3600
  if cfg.initHint == "":
    cfg.initHint = "サーバーで init-db を実行すると、再起動なしで使えるようになります"
  if cfg.log == nil:
    cfg.log = defaultLog
  if cfg.now == nil:
    cfg.now = defaultNow

# ---- アプリケーション ---------------------------------------------------------------

type
  Guard* = enum
    gPublic ## ログイン不要
    gPage   ## ログイン必須
    gAdmin  ## 管理者のみ

  FlashMessage* = object
    category*: string ## Bootstrap の alert の種類 (success / danger / warning / info)
    message*: string

  SessionData = object
    uid: int64  # ログイン中のユーザー (0 = 未ログイン)
    tok: string # repo.User のセッショントークン。パスワード変更で無効になる
    csrf: string # CSRF トークンの元になる、セッションごとの乱数
    iat: int64  # 作成時刻 (Unix 秒)。sessionLifetime で失効

  RememberData = object
    uid: int64
    tok: string
    iat: int64

  RememberAction = enum raKeep, raSet, raClear

  ReqState* = object
    ## 1リクエストぶんの状態 (セッション、ログイン中のユーザー、flash)。
    ## 変更は、レスポンスを返す直前にまとめて Cookie へ反映する (finalizeCookies)。
    app: App
    cookies: Table[string, string]
    sessLoaded: bool
    sess: SessionData
    sessDirty: bool
    userLoaded: bool
    user: Option[User]
    remember: RememberAction
    rememberVal: RememberData
    flashLoaded: bool
    flashIn: seq[FlashMessage]
    flashOut: seq[FlashMessage]
    flashShown: bool
    conn: DbConn
    connOpen: bool

  Handler* = proc (st: var ReqState, req: var Request): Response {.gcsafe.}

  Route = object
    httpMethod: string
    path: string
    guard: Guard
    handler: Handler

  StaticFile = object
    content: string
    etag: string
    contentType: string

  App* = ref object
    cfg: WebConfig
    sessCodec: Codec
    remCodec: Codec
    flashCodec: Codec
    csrfKey: string
    routes: seq[Route]
    staticFiles: Table[string, StaticFile]
    schemaOk: Atomic[bool]
    warned: Atomic[bool]

const
  CookieSession* = "session"
  CookieRemember* = "remember"
  CookieFlash* = "flash"
  MaxFlashes = 5
  MaxFlashLength = 300
  DefaultTitle* = "在庫管理"

const
  MsgCSRF* = "画面の有効期限が切れたか、不正な送信です。ページを開き直して、もう一度お試しください。"
  MsgBusy* = "ただいま混み合っています。数秒おいて、もう一度お試しください。"
  MsgServer* = "エラーが起きました。管理者に連絡してください。"
  MsgFormRead* = "送信内容を読み取れませんでした。"

# ---- エラー --------------------------------------------------------------------------

type HttpError* = object of CatchableError
  code*: int

proc httpError*(code: int, message: string): ref HttpError =
  result = newException(HttpError, message)
  result.code = code

proc notFoundError*(): ref HttpError =
  httpError(404, "ページが見つかりません。")

proc forbiddenError*(): ref HttpError =
  httpError(403, "この操作をする権限がありません。")

# ---- 小物 ------------------------------------------------------------------------------

proc hmac256(key, data: string): string =
  let d = hmac(sha256, key, data)
  result = newString(d.data.len)
  for i, b in d.data:
    result[i] = char(b)

proc randomHex(n: int): string =
  var raw = newSeq[byte](n)
  if randomBytes(addr raw[0], raw.len) != raw.len:
    raise newException(IOError, "乱数を読み取れませんでした")
  toLowerAscii(toHex(raw))

proc htmlEscape*(s: string): string =
  ## Go の template.HTMLEscapeString と同じ置換。
  result = newStringOfCap(s.len)
  for ch in s:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&#34;"
    of '\'': result.add "&#39;"
    else: result.add ch

proc queryEscape*(s: string): string =
  ## Go の url.QueryEscape と同じ (空白は '+')。
  const unreserved = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.', '~'}
  result = newStringOfCap(s.len)
  for ch in s:
    if ch in unreserved:
      result.add ch
    elif ch == ' ':
      result.add '+'
    else:
      result.add '%'
      result.add "0123456789ABCDEF"[ord(ch) shr 4]
      result.add "0123456789ABCDEF"[ord(ch) and 15]

proc httpDate*(unixSeconds: int64): string =
  ## HTTP の日時形式 (Expires 用)。
  utc(fromUnix(unixSeconds)).format("ddd, dd MMM yyyy HH:mm:ss") & " GMT"

proc redirect*(location: string): Response =
  Response(status: 302, headers: @[("Location", location)], body: "")

proc plainResponse*(status: int, body: string): Response =
  Response(status: status,
           headers: @[("Content-Type", "text/plain; charset=utf-8")], body: body)

# ---- セッションの JSON 化 (Go 版 sessionData / rememberData / FlashMessage と同じキー) --

proc sessionToJson(d: SessionData): JsonNode =
  result = newJObject()
  if d.uid != 0:
    result["u"] = %d.uid
  if d.tok != "":
    result["t"] = %d.tok
  if d.csrf != "":
    result["c"] = %d.csrf
  result["i"] = %d.iat

proc jsonToSession(n: JsonNode): SessionData =
  if n != nil and n.kind == JObject:
    result.uid = n.getOrDefault("u").getBiggestInt(0)
    result.tok = n.getOrDefault("t").getStr("")
    result.csrf = n.getOrDefault("c").getStr("")
    result.iat = n.getOrDefault("i").getBiggestInt(0)

proc rememberToJson(d: RememberData): JsonNode =
  result = newJObject()
  result["u"] = %d.uid
  result["t"] = %d.tok
  result["i"] = %d.iat

proc jsonToRemember(n: JsonNode): RememberData =
  if n != nil and n.kind == JObject:
    result.uid = n.getOrDefault("u").getBiggestInt(0)
    result.tok = n.getOrDefault("t").getStr("")
    result.iat = n.getOrDefault("i").getBiggestInt(0)

proc flashesToJson(fl: seq[FlashMessage]): JsonNode =
  result = newJArray()
  for f in fl:
    let o = newJObject()
    o["c"] = %f.category
    o["m"] = %f.message
    result.add o

proc jsonToFlashes(n: JsonNode): seq[FlashMessage] =
  if n != nil and n.kind == JArray:
    for e in n:
      if e.kind == JObject:
        result.add FlashMessage(category: e.getOrDefault("c").getStr(""),
                                message: e.getOrDefault("m").getStr(""))

# ---- リクエスト状態 ---------------------------------------------------------------------

proc newReqState(app: App, req: Request): ReqState =
  ReqState(app: app, cookies: req.cookies)

proc now(st: ReqState): int64 = st.app.cfg.now()

proc db*(st: var ReqState): DbConn =
  ## このリクエスト用の DB 接続 (遅延して開き、handle の終わりに閉じる)。
  ## Go 版はプール済みの *sql.DB を共有するが、db_connector の接続は
  ## スレッド安全ではないため、リクエストごとに開く形にしている。
  if not st.connOpen:
    st.conn = openDb(st.app.cfg.databasePath)
    st.connOpen = true
  st.conn

proc closeConn(st: var ReqState) =
  if st.connOpen:
    st.connOpen = false
    try:
      st.conn.close()
    except CatchableError:
      discard

proc loadSession(st: var ReqState) =
  if st.sessLoaded:
    return
  st.sessLoaded = true
  let raw = st.cookies.getOrDefault(CookieSession, "")
  if raw != "":
    let (node, ok) = st.app.sessCodec.decode(raw)
    if ok:
      let d = jsonToSession(node)
      let age = st.now() - d.iat
      if age <= st.app.cfg.sessionLifetime and d.iat < st.now() + 60:
        st.sess = d

proc csrfSecret(st: var ReqState): string =
  ## セッションの CSRF 用の乱数 (無ければ作る。= セッションが作られる)。
  st.loadSession()
  if st.sess.csrf == "":
    st.sess.csrf = randomHex(32)
    if st.sess.iat == 0:
      st.sess.iat = st.now()
    st.sessDirty = true
  st.sess.csrf

proc verifyUser(st: var ReqState, uid: int64, tok: string): Option[User] =
  ## セッション (または remember) の指すユーザーを DB と突き合わせる。
  ## 無効なユーザー・トークン不一致は未ログイン扱い。DB の異常は例外として伝える。
  if uid == 0:
    return none(User)
  let u = st.db().getUser(uid)
  if u.isNone or not u.get.isActive:
    return none(User)
  if not constTimeEq(tok, u.get.sessionToken(st.app.cfg.secretKey)):
    return none(User)
  u

proc establish(st: var ReqState, u: User) =
  ## このユーザーでログインしたセッションにする (CSRF の乱数は作り直す)。
  st.sess = SessionData(uid: u.id, tok: u.sessionToken(st.app.cfg.secretKey),
                        csrf: randomHex(32), iat: st.now())
  st.sessLoaded = true
  st.sessDirty = true
  st.user = some(u)
  st.userLoaded = true

proc currentUser*(st: var ReqState): Option[User] =
  ## ログイン中のユーザー (未ログインなら none)。
  ## セッションが無効でも、remember Cookie が有効ならログイン状態を復元する。
  if st.userLoaded:
    return st.user
  st.userLoaded = true
  st.loadSession()
  if st.sess.uid != 0:
    let u = st.verifyUser(st.sess.uid, st.sess.tok)
    if u.isSome:
      st.user = u
      return u
    st.sess.uid = 0 # 無効になったログイン状態は捨てる (CSRF の乱数は残す)
    st.sess.tok = ""
    st.sessDirty = true
  if CookieRemember in st.cookies:
    let (node, ok) = st.app.remCodec.decode(st.cookies[CookieRemember])
    var u = none(User)
    if ok:
      let d = jsonToRemember(node)
      if st.now() - d.iat <= st.app.cfg.rememberDuration:
        u = st.verifyUser(d.uid, d.tok)
    if u.isNone:
      st.remember = raClear # 無効な remember Cookie は消す
      return none(User)
    st.establish(u.get)
    st.user = u
    return u
  none(User)

proc login*(st: var ReqState, u: User, remember: bool) =
  ## ログイン成功の処理。remember なら、ログイン保持の Cookie も出す。
  st.establish(u)
  if remember:
    st.remember = raSet
    st.rememberVal = RememberData(uid: u.id, tok: st.sess.tok, iat: st.now())
  else:
    st.remember = raClear # 前のユーザーの remember Cookie を残さない

proc refreshToken*(st: var ReqState, u: User) =
  ## パスワード変更後に、このセッション (と remember Cookie) のトークンを更新する。
  ## 他の端末のセッションは、トークンが合わなくなって無効になる。
  let hadRemember = CookieRemember in st.cookies
  st.loadSession()
  st.sess.uid = u.id
  st.sess.tok = u.sessionToken(st.app.cfg.secretKey)
  if st.sess.csrf == "":
    st.sess.csrf = randomHex(32)
  st.sessDirty = true
  st.user = some(u)
  st.userLoaded = true
  if hadRemember:
    st.remember = raSet
    st.rememberVal = RememberData(uid: u.id, tok: st.sess.tok, iat: st.now())

proc logout*(st: var ReqState) =
  st.sess = SessionData()
  st.sessLoaded = true
  st.sessDirty = true
  st.user = none(User)
  st.userLoaded = true
  st.remember = raClear

# ---- flash -------------------------------------------------------------------------------

proc loadFlash(st: var ReqState) =
  if st.flashLoaded:
    return
  st.flashLoaded = true
  let raw = st.cookies.getOrDefault(CookieFlash, "")
  if raw != "":
    let (node, ok) = st.app.flashCodec.decode(raw)
    if ok:
      let fl = jsonToFlashes(node)
      if fl.len <= MaxFlashes:
        st.flashIn = fl

proc flash*(st: var ReqState, category, message: string) =
  ## 次に表示するメッセージを追加する (リダイレクトを挟んでも届く)。
  st.loadFlash()
  st.flashOut.add FlashMessage(category: category,
                               message: truncateRunes(message, MaxFlashLength))

proc takeFlashes(st: var ReqState): seq[FlashMessage] =
  ## 表示するメッセージを返す (表示したものは、次のリクエストでは出さない)。
  st.loadFlash()
  st.flashShown = true
  st.flashIn & st.flashOut

# ---- CSRF トークン -------------------------------------------------------------------------
# 「発行時刻.HMAC(鍵, セッションの乱数|発行時刻)」。セッションの乱数は署名付き Cookie の
# 中にあるので、別のセッションで発行したトークンは通らない。発行から csrfTtl を過ぎると無効。

proc csrfMac(app: App, secret, ts: string): string =
  b64urlEncode(hmac256(app.csrfKey, secret & "|" & ts))

proc csrfMake(app: App, secret: string, now: int64): string =
  let ts = $now
  ts & "." & app.csrfMac(secret, ts)

proc csrfCheck(app: App, secret, token: string, now: int64): bool =
  let i = token.find('.')
  if i <= 0:
    return false
  let ts = token[0 ..< i]
  let mac = token[i + 1 ..^ 1]
  var issued: int64
  try:
    issued = parseBiggestInt(ts)
  except CatchableError:
    return false
  let age = now - issued
  if age > app.cfg.csrfTtl or age < -60:
    return false
  constTimeEq(mac, app.csrfMac(secret, ts))

proc csrfToken*(st: var ReqState): string =
  st.app.csrfMake(st.csrfSecret(), st.now())

proc csrfValid(st: var ReqState, token: string): bool =
  st.loadSession()
  if st.sess.csrf == "" or token == "":
    return false
  st.app.csrfCheck(st.sess.csrf, token, st.now())

# ---- Cookie への反映 -------------------------------------------------------------------------

proc cookieAttrs(st: ReqState): string =
  result = "; Path=/; HttpOnly; SameSite=Lax"
  if st.app.cfg.cookieSecure:
    result.add "; Secure"

proc setCookieHeader(st: ReqState, name, value: string): string =
  name & "=" & value & st.cookieAttrs()

proc deleteCookieHeader(st: ReqState, name: string): string =
  st.setCookieHeader(name, "") & "; Max-Age=0"

proc finalizeCookies(st: var ReqState, resp: var Response) =
  ## このリクエストで起きた変更を Set-Cookie にする (レスポンスを返す直前に1回)。
  if st.sessDirty:
    if st.sess.uid == 0 and st.sess.csrf == "":
      if CookieSession in st.cookies:
        resp.headers.add ("Set-Cookie", st.deleteCookieHeader(CookieSession))
    else:
      if st.sess.iat == 0:
        st.sess.iat = st.now()
      resp.headers.add ("Set-Cookie", st.setCookieHeader(
        CookieSession, st.app.sessCodec.encode(sessionToJson(st.sess))))
        # 有効期限なし = ブラウザを閉じるまで
  case st.remember
  of raSet:
    resp.headers.add ("Set-Cookie", st.setCookieHeader(
      CookieRemember, st.app.remCodec.encode(rememberToJson(st.rememberVal))) &
      "; Max-Age=" & $st.app.cfg.rememberDuration &
      "; Expires=" & httpDate(st.now() + st.app.cfg.rememberDuration))
  of raClear:
    if CookieRemember in st.cookies:
      resp.headers.add ("Set-Cookie", st.deleteCookieHeader(CookieRemember))
  of raKeep:
    discard
  if st.flashLoaded:
    var pending: seq[FlashMessage]
    if not st.flashShown:
      pending = st.flashIn & st.flashOut
    if pending.len > 0:
      if pending.len > MaxFlashes:
        pending = pending[^MaxFlashes .. ^1]
      resp.headers.add ("Set-Cookie", st.setCookieHeader(
        CookieFlash, st.app.flashCodec.encode(flashesToJson(pending))))
    elif CookieFlash in st.cookies:
      resp.headers.add ("Set-Cookie", st.deleteCookieHeader(CookieFlash))

# ---- テンプレートと描画 ---------------------------------------------------------------------
# Go 版は base.html の骨格に各ページの title / content ブロックを差し込む構成。
# ここでは、ページ側テンプレートを先に描いて {{{content}}} へ差し込む2段描画で
# 置き換える。共通部品 (flash の列) は partial。

const tplBase = staticRead("web/templates/base.mustache")
const tplFlashes = staticRead("web/templates/flashes.mustache")
const tplLogin = staticRead("web/templates/login.mustache")
const tplPassword = staticRead("web/templates/password.mustache")
const tplError = staticRead("web/templates/error.mustache")
const tplNoteList = staticRead("web/templates/note_list.mustache")
const tplNoteForm = staticRead("web/templates/note_form.mustache")
const tplQtyInput = staticRead("web/templates/qty_input.mustache")
const tplDashboardStub* = staticRead("web/templates/dashboard_stub.mustache")
  ## 手順4で本物のダッシュボードに置き換える仮画面 (テストからも使う)

proc renderPage*(st: var ReqState, status: int, title, pageTpl: string,
                 data: JsonNode): Response =
  ## ページを描画する。ユーザー取得に失敗しても、ナビの表示を省くだけで
  ## 描画自体は止めない (エラーページの描画を止めないため。Go 版 Render と同じ)。
  let user = try:
      st.currentUser()
    except CatchableError:
      none(User)
  let flashes = st.takeFlashes()
  let csrf = st.csrfToken()
  var partials = initTable[string, string]()
  partials["flashes"] = tplFlashes
  partials["note_list"] = tplNoteList
  partials["note_form"] = tplNoteForm
  partials["qty_input"] = tplQtyInput
  var pctx = newContext()
  pctx.searchTable(partials)
  if data != nil and data.kind == JObject:
    for k, v in data:
      pctx[k] = v
  pctx["csrf"] = csrf
  let content = pageTpl.render(pctx)
  var bctx = newContext()
  bctx.searchTable(partials)
  bctx["title"] = title
  bctx["csrf"] = csrf
  bctx["content"] = content
  bctx["user"] = user.isSome
  bctx["isAdmin"] = user.isSome and user.get.isAdmin
  if user.isSome:
    bctx["username"] = user.get.username
  var fl: seq[Table[string, string]]
  for f in flashes:
    var t = initTable[string, string]()
    t["category"] = f.category
    t["message"] = f.message
    fl.add t
  bctx["flashes"] = fl
  Response(status: status,
           headers: @[("Content-Type", "text/html; charset=utf-8")],
           body: tplBase.render(bctx))

proc errorPage*(st: var ReqState, code: int, message: string): Response =
  try:
    let data = newJObject()
    data["code"] = %code
    data["message"] = %message
    st.renderPage(code, DefaultTitle, tplError, data)
  except CatchableError:
    # エラーページの描画自体が失敗したときの、最後の手段
    plainResponse(code, message)

proc isBusyError(e: ref CatchableError): bool =
  let m = e.msg.toLowerAscii
  "database is locked" in m or "busy" in m

proc handleHandlerError(st: var ReqState, req: Request,
                        e: ref CatchableError): Response =
  ## ハンドラーが投げた例外をエラーページにする (Go 版 handleError)。
  if e of HttpError:
    return st.errorPage((ref HttpError)(e).code, e.msg)
  st.app.cfg.log("error: " & req.httpMethod & " " & req.path & ": " & e.msg)
  if isBusyError(e):
    result = st.errorPage(503, MsgBusy)
    result.headers.add ("Retry-After", "5")
    return result
  st.errorPage(500, MsgServer)

# ---- 静的ファイル --------------------------------------------------------------------------------
# 埋め込んだファイルの一覧表にある名前だけを配る (URL からファイルパスを組み立てない
# ので、パストラバーサルの余地がない)。ETag は内容ハッシュ、Cache-Control: no-cache で
# 毎回確認させ、変わっていなければ 304 (Flask の static と同じ振る舞い)。

const staticCss = staticRead("web/static/app.css")
const staticJs = staticRead("web/static/app.js")
const staticBootCss = staticRead("web/static/vendor/bootstrap.min.css")
const staticBootJs = staticRead("web/static/vendor/bootstrap.bundle.min.js")

proc makeStaticFile(content, contentType: string): StaticFile =
  let d = sha256.digest(content)
  var bytes = newSeqOfCap[byte](d.data.len)
  for b in d.data:
    bytes.add b
  StaticFile(content: content,
             etag: "\"" & toLowerAscii(toHex(bytes))[0 ..< 16] & "\"",
             contentType: contentType)

proc buildStaticFiles(): Table[string, StaticFile] =
  {
    "app.css": makeStaticFile(staticCss, "text/css; charset=utf-8"),
    "app.js": makeStaticFile(staticJs, "text/javascript; charset=utf-8"),
    "vendor/bootstrap.min.css": makeStaticFile(staticBootCss, "text/css; charset=utf-8"),
    "vendor/bootstrap.bundle.min.js": makeStaticFile(staticBootJs, "text/javascript; charset=utf-8"),
  }.toTable

proc serveStatic(st: var ReqState, req: Request): Response =
  if req.httpMethod != "GET" and req.httpMethod != "HEAD":
    return plainResponse(405, "Method Not Allowed\n")
  let name = req.path[len("/static/") .. ^1]
  if name notin st.app.staticFiles:
    return st.errorPage(404, "ページが見つかりません。")
  let f = st.app.staticFiles[name]
  result = Response(status: 200, headers: @[
    ("ETag", f.etag), ("Cache-Control", "no-cache")])
  if headerGet(req.headers, "If-None-Match") == f.etag:
    result.status = 304
    return result
  result.headers.add ("Content-Type", f.contentType)
  result.body = f.content

# ---- スキーマ確認 (503 の案内) ----------------------------------------------------------------------

const schemaPage = """<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>準備中</title></head>
<body style="font-family:sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem">
<h1 style="font-size:1.3rem">データベースの更新が必要です</h1>
<p>管理者に連絡してください。</p>
<p style="color:#666;font-size:.9rem">(管理者向け: %s)</p>
</body></html>"""

proc ensureSchema(app: App): tuple[ok: bool, hint: string] =
  ## DB が使える状態か (最新のスキーマか) を確かめる。使える状態になったら、
  ## 以降は確認しない。更新が済めば、再起動なしで使えるようになる。
  if app.schemaOk.load:
    return (true, "")
  var state = dsMissing
  var hint = ""
  try:
    state = checkDb(app.cfg.databasePath) # 存在しないファイルは、作らずに missing を返す
  except CatchableError as e:
    hint = "DBファイルを開けません: " & e.msg
  if hint == "":
    case state
    of dsCurrent:
      try:
        let c = openDb(app.cfg.databasePath)
        c.close()
      except CatchableError as e:
        hint = "DBファイルを開けません: " & e.msg
      if hint == "":
        app.schemaOk.store(true)
        return (true, "")
    of dsForeign:
      hint = "この版が作ったDBではありません"
      let fe = try:
          describeForeign(app.cfg.databasePath)
        except CatchableError:
          nil
      if fe != nil:
        hint = fe.msg
    else:
      hint = app.cfg.initHint
  if not app.warned.exchange(true):
    app.cfg.log("DBが未作成か、古いか、使えない状態です (" & $state & "): " &
                app.cfg.databasePath)
  (false, hint)

# ---- ルート登録とハンドラー ---------------------------------------------------------------------------

proc publicRoute*(app: App, httpMethod, path: string, h: Handler) =
  ## ログイン不要のルート。
  app.routes.add Route(httpMethod: httpMethod, path: path, guard: gPublic, handler: h)

proc pageRoute*(app: App, httpMethod, path: string, h: Handler) =
  ## ログイン必須のルート。未ログインなら、ログイン画面へ移動する (移動先は next に入れる)。
  app.routes.add Route(httpMethod: httpMethod, path: path, guard: gPage, handler: h)

proc adminRoute*(app: App, httpMethod, path: string, h: Handler) =
  ## 管理者だけのルート。未ログインはログイン画面へ、スタッフは 403。
  app.routes.add Route(httpMethod: httpMethod, path: path, guard: gAdmin, handler: h)

proc replaceRouteHandler*(app: App, httpMethod, path: string,
                          h: Handler): bool =
  ## 登録済みルートのハンドラーだけを差し替える (手順4の本物のダッシュボードが、
  ## 手順3で仮置きした GET / のスタブを置き換えるために使う)。
  ## 見つからなければ false (ルートは追加しない)。
  for route in app.routes.mitems:
    if route.httpMethod == httpMethod and route.path == path:
      route.handler = h
      return true
  false

proc loginHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let u = st.currentUser()
  if u.isSome:
    return redirect("/")
  if req.httpMethod == "POST":
    let user = authenticate(st.db(), req.formValue("username"),
                            req.formValue("password"))
    if user.isSome:
      st.login(user.get, req.formValue("remember") == "on")
      var next = safeNext(req.queryValue("next"))
      if next == "":
        next = "/"
      return redirect(next)
    st.flash("danger", MsgLoginFailed)
  st.renderPage(200, "ログイン | 在庫管理", tplLogin, newJObject())

proc logoutHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  st.logout()
  redirect("/login")

proc passwordHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  let u = st.currentUser().get # Page のガードでログイン済みが保証される
  if req.httpMethod == "POST":
    let (updated, msg) = changePassword(st.db(), u.id, req.formValue("old"),
                                        req.formValue("new"), req.formValue("confirm"))
    if msg != "":
      st.flash("danger", msg)
    else:
      if updated.isNone:
        raise newException(ValueError, "パスワード変更後のユーザーが取得できません")
      st.refreshToken(updated.get)
      st.flash("success", MsgPasswordChanged)
      return redirect("/")
  st.renderPage(200, DefaultTitle, tplPassword, newJObject())

proc dashboardStubHandler(st: var ReqState, req: var Request): Response {.gcsafe.} =
  ## 手順4でダッシュボードに置き換える仮の画面 (Go 版 dashboard_stub.html に相当)。
  st.renderPage(200, DefaultTitle, tplDashboardStub, newJObject())

proc registerRoutes(app: App) =
  ## この手順で用意する共通のルート (ログイン、ログアウト、パスワード変更)。
  ## 各画面は、別の場所で publicRoute / pageRoute / adminRoute を使って追加する。
  app.publicRoute("GET", "/login", loginHandler)
  app.publicRoute("POST", "/login", loginHandler)
  app.pageRoute("POST", "/logout", logoutHandler)
  app.pageRoute("GET", "/account/password", passwordHandler)
  app.pageRoute("POST", "/account/password", passwordHandler)
  app.pageRoute("GET", "/", dashboardStubHandler) # 手順4で置き換える仮置き

proc newApp*(cfg: WebConfig): App =
  ## App を作る。DB が未作成/古くても作れる (そのあいだは 503 の案内を返す)。
  var c = cfg
  c.applyDefaults()
  if c.secretKey == "":
    raise newException(ValueError, "web: SecretKey is empty")
  result = App(
    cfg: c,
    sessCodec: newCodec(c.secretKey, "session"),
    remCodec: newCodec(c.secretKey, "remember"),
    flashCodec: newCodec(c.secretKey, "flash"),
    csrfKey: newCodec(c.secretKey, "csrf").codecKey,
    staticFiles: buildStaticFiles())
  result.registerRoutes()

# ---- 処理の流れ (Go 版 Handler() のミドルウェア順と同じ) -----------------------------------------------
# 状態の用意 → パニック回復 → no-store → スキーマ確認 (503 案内) → CSRF →
# ドットセグメント除去 → 静的ファイル / ルート。スキーマ未整備のときは CSRF より
# 先に 503 案内を返す (Flask 版の before_request と同じ優先順位)。

proc isStaticPath(path: string): bool = path.startsWith("/static/")

proc runGuarded(st: var ReqState, req: var Request, route: Route): Response =
  if route.guard == gPublic:
    return route.handler(st, req)
  let u = st.currentUser()
  if u.isNone:
    st.flash("warning", MsgLoginRequired)
    return redirect("/login?next=" & queryEscape(req.requestUri()))
  if route.guard == gAdmin and not u.get.isAdmin:
    raise forbiddenError()
  route.handler(st, req)

proc matchRoutePath(pattern, path: string, params: var Headers): bool =
  ## ルートのパターンとパスを照合する。"{name}" のセグメントは、空でない
  ## 1セグメントと一致し、params に入る。それ以外は完全一致。
  if pattern == path:
    return true
  if '{' notin pattern:
    return false
  let ps = pattern.split('/')
  let xs = path.split('/')
  if ps.len != xs.len:
    return false
  params = @[]
  for i in 0 ..< ps.len:
    let p = ps[i]
    if p.len > 2 and p[0] == '{' and p[^1] == '}':
      if xs[i] == "":
        return false
      params.add (p[1 .. ^2], xs[i])
    elif p != xs[i]:
      return false
  true

proc pipeline(app: App, st: var ReqState, req: var Request): Response =
  # スキーマ確認: DB が未作成/古いままだと、画面を開いて初めて 500 になる。先に分かりやすく止める。
  if not isStaticPath(req.path):
    let (ok, hint) = app.ensureSchema()
    if not ok:
      return Response(status: 503, headers: @[
        ("Content-Type", "text/html; charset=utf-8"), ("Retry-After", "60")],
        body: schemaPage.replace("%s", htmlEscape(hint)))
  # CSRF: 状態を変える要求 (POST など) には、フォームの csrf_token か X-CSRFToken ヘッダーを必須にする。
  if req.httpMethod notin ["GET", "HEAD", "OPTIONS", "TRACE"]:
    var token = headerGet(req.headers, "X-CSRFToken")
    if token == "":
      token = headerGet(req.headers, "X-CSRF-Token")
    if token == "":
      parseForm(req)
      if req.formError:
        return st.errorPage(400, MsgFormRead)
      token = req.formValue("csrf_token")
    if not st.csrfValid(token):
      return st.errorPage(400, MsgCSRF)
  # ドットセグメント: "." / ".." を含むパスは、その場でアプリの 404 にする (案B)。
  # 判定はセグメント単位で、各セグメントを復号してから比べるため、%2e%2e のような
  # エンコードされた ".." もここで受けるし、"foo..bar" のような名前の一部は弾かない。
  for seg in req.rawPath.split('/'):
    let u = percentDecode(seg, false)
    if u == "." or u == "..":
      return st.errorPage(404, "ページが見つかりません。")
  # 静的ファイル
  if isStaticPath(req.path):
    return serveStatic(st, req)
  # ルート ({name} セグメントは1セグメントぶんの値として受ける。Go 版の
  # ServeMux の "{id}" パターンと同じ)
  var pathMethods: seq[string]
  for route in app.routes:
    var params: Headers
    if matchRoutePath(route.path, req.path, params):
      if route.httpMethod == req.httpMethod:
        req.pathParams = params
        try:
          return runGuarded(st, req, route)
        except CatchableError as e:
          return handleHandlerError(st, req, e)
      pathMethods.add route.httpMethod
  if pathMethods.len > 0:
    result = plainResponse(405, "Method Not Allowed\n")
    result.headers.add ("Allow", pathMethods.join(", "))
    return result
  # どのルートにも当たらないものは 404 (Flask 版と同じエラーページ)
  st.errorPage(404, "ページが見つかりません。")

proc handle*(app: App, req: var Request): Response =
  ## 1リクエストを処理する (mummy アダプターとテストの入口)。
  var st = newReqState(app, req)
  try:
    result = app.pipeline(st, req)
  except CatchableError as e:
    # パニック回復: 詳細はログにだけ残し、画面には出さない
    app.cfg.log("panic: " & req.httpMethod & " " & req.path & ": " & e.msg &
                "\n" & e.getStackTrace())
    try:
      result = st.errorPage(500, MsgServer)
    except CatchableError:
      result = plainResponse(500, MsgServer)
  if not isStaticPath(req.path):
    # no-store: 在庫は常に最新を見せたいので、HTML をキャッシュさせない (静的ファイル以外)
    var hasCC = false
    for (k, _) in result.headers:
      if cmpIgnoreCase(k, "Cache-Control") == 0:
        hasCC = true
    if not hasCC:
      result.headers.add ("Cache-Control", "no-store")
  try:
    st.finalizeCookies(result)
  except CatchableError:
    discard # Cookie の反映に失敗しても、応答自体は返す
  st.closeConn()

# ---- mummy アダプター -----------------------------------------------------------------------------------

import mummy
import webby/httpheaders

proc toWebRequest(r: mummy.Request): Request =
  var target = r.uri
  if target == "":
    target = "/"
  result = newRequest(r.httpMethod, target)
  # mummy はパスを復号済みで持っているので、newRequest の復号結果より優先する
  if r.path != "":
    result.path = r.path
  result.query.setLen(0)
  for (k, v) in seq[(string, string)](r.queryParams):
    result.query.add (k, v)
  for (k, v) in seq[(string, string)](r.headers):
    result.headers.add (k, v)
  result.body = r.body
  result.cookies = parseCookies(headerGet(result.headers, "Cookie"))

proc serveHttp*(app: App, address: string, port: int,
                workerThreads = 0) =
  ## mummy で待ち受ける (この呼び出しは戻らない。server.close で止まる)。
  let handler = proc (request: mummy.Request) {.gcsafe.} =
    var req = toWebRequest(request)
    let resp = app.handle(req)
    var raw: seq[(string, string)]
    for (k, v) in resp.headers:
      raw.add (k, v)
    request.respond(resp.status, HttpHeaders(raw), resp.body)
  var server: mummy.Server
  if workerThreads > 0:
    server = newServer(handler, workerThreads = workerThreads)
  else:
    server = newServer(handler)
  server.serve(Port(port), address)
