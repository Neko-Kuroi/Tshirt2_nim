## 比較検証用の使い捨てサーバー (本番バイナリではない)。
## 使い方: devserver <dbPath> <port>

import std/[os, strutils]
import webcore
import webread
import webops
import webadmin

let dbPath = paramStr(1)
let port = parseInt(paramStr(2))
let cfg = WebConfig(databasePath: dbPath, secretKey: "cmp-secret")
let app = newApp(cfg)
app.registerReadRoutes()
app.registerOpsRoutes()
app.registerAdminRoutes()
stderr.writeLine("devserver: db=" & dbPath & " port=" & $port)
app.serveHttp("127.0.0.1", port)
