# Tshirt2_nim — 在庫管理アプリ (Nim 版)

Tシャツ・キャップ等の無地在庫とプリント済み在庫を管理する Web アプリの Nim 実装です。単一バイナリで動き、画面・業務規則・文言は Flask 版と一致させてあります。

## 位置づけ (3実装の共存)

このアプリには Python (Flask) 版・Go 版・Nim 版の3実装があり、**現段階ではどれも実稼働していません**。将来の稼働先 (デプロイサービスか、SoC のようなデバイスか) を見極めるための横並びの評価対象です。

3実装は **同じ `inventory.db` を無変更で共用** できます (スキーマ、`PRAGMA user_version`、パスワードハッシュの Werkzeug 形式まで互換)。どの実装で起動しても同じデータが見え、いつでも他の実装に切り替え・切り戻しができます。

## 前提

- 実行時: **libsqlite3** がシステムにあること (SQLite は動的リンク。Debian/Ubuntu なら `libsqlite3-0`、通常は導入済み)
- ビルド時: Nim 2.4.0 (choosenim で導入)。依存ライブラリは `vendor/` に同梱してあるので、ネットワーク取得は不要です (この環境では nimble のパッケージ一覧が取得できないため、全て vendor 化してあります)

## ビルドとテスト

```sh
make build   # dist/inventory を作る (release、--opt:size、strip 後 約1.23MiB)
make test    # 全テストを実行する
```

テストは全 **214件** (DB 23、util 17、パスワード 3、サービス 63、Web 基盤 53、画面の読み取り 12・操作 13・管理 7、CLI 23)。Flask 版から生成した照合データ (ゴールデン DB・CSV・一覧77条件・Werkzeug ハッシュベクトル) で検証しています。

## 使い方

バイナリ1つがサーバーと管理コマンドを兼ねます。設定ファイルは、実行ファイルのあるフォルダーの `instance/` に置かれます。

```sh
./inventory init-db                          # DB を作成/更新する (何度実行しても安全)
./inventory seed                             # 初期カテゴリーを登録する
./inventory create-user --admin 管理者名      # ユーザー作成 (パスワードは端末で入力。--password 指定も可)
./inventory list-users                       # ユーザー一覧
./inventory serve                            # サーバー起動 (既定は 127.0.0.1:5000)
./inventory help                             # 使い方
```

引数なしで実行すると `serve` になります。待ち受けアドレスは `serve --addr 0.0.0.0:5000` のように指定できます。

### 環境変数

| 変数 | 意味 |
| --- | --- |
| `INVENTORY_DATABASE` | DB ファイルのパス。無ければ `<バイナリのフォルダー>/instance/inventory.db` |
| `INVENTORY_SECRET_KEY` | Cookie の署名鍵。無ければ `instance/secret_key` を読み、無ければ生成して権限 0600 で保存する |
| `INVENTORY_COOKIE_SECURE` | `1` で Cookie に Secure 属性を付ける |
| `INVENTORY_ADDR` | `serve` の待ち受けアドレス (`--addr` が優先) |

DB が未作成・旧版の間は、サーバーは起動したまま案内画面 (503) を出し、`init-db` を実行すれば再起動なしで使えるようになります。他の版 (SQLAlchemy 版など) が作った DB は、書き換えずに停止します。

## 他の実装からの切替と戻し方

1. 今動いている実装 (Flask / Go) を止める
2. このバイナリを配置し、`./inventory init-db` を実行する (DB はそのまま使えます)
3. 同じポートで `./inventory serve` を起動する

- 利用者への影響は **全員が1回ログインし直す** だけです (セッション Cookie の形式が実装ごとに違うため)。ユーザー名とパスワードはそのまま使えます
- **戻すときは、Flask 版または Go 版を起動し直すだけ** です。DB は変更されていない (user_version=3 のまま) ので、そのまま戻れます

並行稼働の検証 (2026-11-03): Flask 版と Nim 版を同じ DB で同時起動し、相互の入出荷・履歴・備考・パスワード変更の反映、交互の入荷10件など **17項目すべて合格**。検証後も user_version=3、integrity ok、スキーマは Flask 製 DB と完全一致でした。

## 3実装の比較 (2026-11-03 実測、x86_64 VM・4コア)

同じ DB・同じ操作 (ログイン、ダッシュボード表示、入荷30件) で測った値です (「RSS (ログイン負荷の後)」の行だけは、メモリ対策後の確認として、ログインを繰り返す手順で測り直した値)。

| 項目 | Flask (Python) | Go | Nim |
| --- | ---: | ---: | ---: |
| 配布物 | ソース約1MB＋Python と venv 約21MB | 単一バイナリ 13.5MiB (依存なし) | 単一バイナリ **1.23MiB** (＋libsqlite3) |
| 起動時間 | 0.46〜0.51秒 | 0.03秒 | 0.03〜0.05秒 |
| RSS (待機時) | 35.0MB | 14.9MB | **7.4MB** |
| RSS (ログイン負荷の後) | 35.0MB | 約18MB | 約43MB |
| ログイン応答 (scrypt 検証) | 約137ms | 約115ms | 約161ms |
| ダッシュボード表示 | 約4.2ms | 約2.0ms | 約12.7ms |
| 入荷30件 (1件あたり) | 0.23秒 (7.7ms) | 0.11秒 (3.7ms) | 0.44秒 (15ms) |

読み:

- **デプロイサービス** なら、Python がそのまま動く環境では Flask 版が一番素直です。バイナリ配置型なら Go / Nim のどちらでも置けます
- **SoC** では、Go は依存ゼロの静的バイナリで前提が最小です。Nim はバイナリも待機時メモリも最小です。Python はインタプリタ前提＋待機時 35MB が下限になります
- ログイン応答は3実装とも scrypt の計算が支配的で大差ありません (SoC の弱い CPU では全体が数倍に伸びる見込み)。画面表示や入荷の差は SQLite 本体よりアプリ側の処理 (接続の開き方、テンプレート処理) の差です

### 補足: ログイン時のメモリ (対策済み)

Nim 版は待機時 7.4MB と最小です。ログイン (scrypt 検証) の最中は、他の実装と同じく作業メモリ約34MB を一時的に使いますが、検証が終われば OS に返ります (実測: 待機時 5.5MB → ログイン負荷後は約43MB で安定し、それ以上は増えません。残りはワーカースレッド各々のヒープ保持分です)。これは、scrypt の作業領域を Nim のアロケータではなく C の malloc/free で確保しているためです (Nim のアロケータは解放した大きなブロックを保持して OS に返さないため、当初はログインを処理したワーカーの分だけ RSS が増えたままになっていました)。なお Go 版にも同種の保持がありましたが、こちらも対策済みです (派生処理の同時実行を絞り、検証のたびにメモリを OS へ返すようにし、負荷後も約18MB で一定)。

## 構成

- `src/` — 本体。`db.nim` (接続・Tx・マイグレーション)、`stock.nim` / `stocklist.nim` / `exportcsv.nim` / `adminsvc.nim` / `authsvc.nim` (業務規則)、`webcore.nim` (セッション・CSRF・ガード・静的配信) と画面ハンドラー `webread.nim` / `webops.nim` / `webadmin.nim`、`cli.nim` (サブコマンド)、`inventory.nim` (入口)
- `src/web/templates/` — nim-mustache のテンプレート (`{{ }}` は HTML エスケープが既定)
- `vendor/` — nimcrypto、db_connector、mummy (+ webby / zippy / crunchy / nimsimd)、nim-mustache。コミットは `docs/PLAN.md` の手順0記録に記載
- `tests/` — テスト一式と照合データ (`tests/testdata/`)
- `docs/PLAN.md` — 移植計画と実施記録

設計判断 (セッション・CSRF・Tx の BUSY リトライ・ドットセグメント 404 等) は Go 版の DESIGN.md を仕様として踏襲しています。
