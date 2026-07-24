#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <duckdb-build-dir>" >&2
    exit 1
fi

BUILD_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUCKDB_DIR="$(cd "$BUILD_DIR/../.." && pwd)"
PROBE_SRC="$SCRIPT_DIR/openivm_meta_probe.cpp"
PROBE_BIN="$(mktemp -t openivm_meta_probe.XXXXXX)"
trap 'rm -f "$PROBE_BIN"' EXIT

c++ -std=c++17 -O0 -g \
    -I"$DUCKDB_DIR/src/include" \
    -I"$DUCKDB_DIR/third_party/fmt/include" \
    -I"$DUCKDB_DIR/third_party/utf8proc/include" \
    -I"$DUCKDB_DIR/third_party/mbedtls/include" \
    -I"$DUCKDB_DIR/third_party/yyjson/include" \
    -I"$DUCKDB_DIR/third_party/zstd/include" \
    -I"$DUCKDB_DIR/third_party/re2" \
    -I"$DUCKDB_DIR/third_party/miniz" \
    -I"$DUCKDB_DIR/third_party/fsst" \
    -I"$DUCKDB_DIR/third_party/skiplist" \
    -I"$DUCKDB_DIR/third_party/fastpforlib" \
    -I"$DUCKDB_DIR/third_party/hyperloglog" \
    -I"$DUCKDB_DIR/third_party/concurrentqueue" \
    -I"$DUCKDB_DIR/third_party/pcg" \
    -I"$DUCKDB_DIR/third_party/pdqsort" \
    -I"$DUCKDB_DIR/third_party/tdigest" \
    -I"$DUCKDB_DIR/third_party/jaro_winkler" \
    -I"$DUCKDB_DIR/third_party/vergesort" \
    "$PROBE_SRC" \
    "$BUILD_DIR/src/libduckdb_static.a" \
    "$BUILD_DIR/extension/libdummy_static_extension_loader.a" \
    -ldl -lpthread -lssl -lcrypto -lm -lc -lresolv \
    -o "$PROBE_BIN"

"$PROBE_BIN" "$BUILD_DIR"
