## 署名付きの値 (Cookie の中身) を作る・読む (Go 版 internal/web/codec.go に対応)。
##
## 値は「base64url(JSON).base64url(HMAC-SHA256)」。鍵は用途ごとに分ける
## (セッション用の値を、remember や flash として使い回せないように)。
## 改ざん・形式の誤りは例外にせず、decode の ok=false で表す。

import std/[json, strutils]
import nimcrypto/[hmac, sha2]

type Codec* = object
  key: string # HMAC の鍵 (バイナリ文字列)

proc digestToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc newCodec*(secret, purpose: string): Codec =
  ## 用途別の鍵を導出する: HMAC(secret, "tshirt2/" & purpose)。
  let digest = hmac(sha256, secret, "tshirt2/" & purpose)
  Codec(key: digestToString(digest.data))

proc codecKey*(c: Codec): string =
  ## 導出済みの鍵そのもの (CSRF のように鍵を直接使う用途のため)。
  c.key

proc constTimeEq*(a, b: string): bool =
  ## 長さが違う場合は即 false、中身は全バイトを比較する (タイミング対策)。
  if a.len != b.len:
    return false
  var diff = 0'u8
  for i in 0 ..< a.len:
    diff = diff or uint8(a[i]) xor uint8(b[i])
  diff == 0

# ---- base64url (パディングなし) -------------------------------------------------

const b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

proc b64urlEncode*(s: string): string =
  result = newStringOfCap((s.len + 2) div 3 * 4)
  var i = 0
  while i + 3 <= s.len:
    let n = (uint32(s[i]) shl 16) or (uint32(s[i + 1]) shl 8) or uint32(s[i + 2])
    result.add b64chars[int(n shr 18)]
    result.add b64chars[int((n shr 12) and 63)]
    result.add b64chars[int((n shr 6) and 63)]
    result.add b64chars[int(n and 63)]
    i += 3
  case s.len - i
  of 1:
    let n = uint32(s[i]) shl 16
    result.add b64chars[int(n shr 18)]
    result.add b64chars[int((n shr 12) and 63)]
  of 2:
    let n = (uint32(s[i]) shl 16) or (uint32(s[i + 1]) shl 8)
    result.add b64chars[int(n shr 18)]
    result.add b64chars[int((n shr 12) and 63)]
    result.add b64chars[int((n shr 6) and 63)]
  else:
    discard

proc b64urlDecode*(s: string): tuple[data: string, ok: bool] =
  ## 復号。不正な文字・長さは ok=false。
  var rev: array[256, int8]
  for i in 0 ..< 256:
    rev[i] = -1
  for i, ch in b64chars:
    rev[ord(ch)] = int8(i)
  if s.len mod 4 == 1:
    return ("", false)
  result.data = newStringOfCap(s.len * 3 div 4)
  var acc = 0'u32
  var nbits = 0
  for ch in s:
    let v = rev[ord(ch)]
    if v < 0:
      return ("", false)
    acc = (acc shl 6) or uint32(v)
    nbits += 6
    if nbits >= 8:
      nbits -= 8
      result.data.add char((acc shr nbits) and 0xff)
  (result.data, true)

# ---- 符号化 ----------------------------------------------------------------------

proc mac(c: Codec, payload: string): string =
  let digest = hmac(sha256, c.key, payload)
  digestToString(digest.data)

proc encode*(c: Codec, v: JsonNode): string =
  ## JSON を符号化する。値は base64url のペイロードと署名を "." でつないだ形。
  let p = b64urlEncode($v)
  p & "." & b64urlEncode(c.mac(p))

proc decode*(c: Codec, s: string): tuple[node: JsonNode, ok: bool] =
  ## 署名を確かめて JSON を読み込む。改ざん・形式の誤りは ok=false。
  let i = s.find('.')
  if i <= 0 or i == s.len - 1:
    return (nil, false)
  let p = s[0 ..< i]
  let sig = b64urlDecode(s[i + 1 ..^ 1])
  if not sig.ok or not constTimeEq(sig.data, c.mac(p)):
    return (nil, false)
  let raw = b64urlDecode(p)
  if not raw.ok:
    return (nil, false)
  try:
    (parseJson(raw.data), true)
  except CatchableError:
    (nil, false)
