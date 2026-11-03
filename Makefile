# Tshirt2_nim (在庫管理アプリ Nim 版) のビルド。
# 配布物は単一バイナリ dist/inventory (SQLite はシステムの libsqlite3 を動的リンク)。
NIM ?= nim
DIST := dist
BIN := $(DIST)/inventory

TESTS := tests/tdb.nim tests/tutil.nim tests/tpasswords.nim tests/tservice.nim \
         tests/tweb.nim tests/twebread.nim tests/twebops.nim tests/twebadmin.nim \
         tests/tcli.nim

.PHONY: build test clean

# 配布用ビルド: リリース最適化し、シンボルを落として小さくする
build:
	mkdir -p $(DIST)
	$(NIM) c -d:release --opt:size --path:src -o:$(BIN) src/inventory.nim
	strip $(BIN)

test:
	for f in $(TESTS); do $(NIM) c -r --path:src $$f || exit 1; done

clean:
	rm -rf $(DIST)
