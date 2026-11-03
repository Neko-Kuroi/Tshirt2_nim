## 在庫管理アプリの実行ファイル。
## サーバー起動と管理コマンド (init-db / seed / create-user / list-users) を兼ねる。
import std/os

import cli

proc main() =
  # 設定 (instance フォルダー) の置き場所は、実行ファイルのあるフォルダー
  # (Flask 版の BASE_DIR 相当)。getAppDir は /proc/self/exe ベースなので、
  # シンボリックリンク経由でも実体のフォルダーになる (Go 版 main と同じ)。
  var baseDir = getAppDir()
  if baseDir == "":
    baseDir = "."
  quit(runCli(commandLineParams(), stdin, stdout, stderr, baseDir))

main()
