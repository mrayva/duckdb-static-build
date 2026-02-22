# DuckDB Static Build Kit

Build DuckDB with 24 statically-linked core extensions.

## Quick Start

```bash
# First time setup (installs vcpkg dependencies ~20 min)
./build-duckdb-static.sh --clean

# Subsequent builds (skip vcpkg, ~5 min)
./build-duckdb-static.sh --skip-vcpkg
```

## Files

| File | Description |
|------|-------------|
| `build-duckdb-static.sh` | Automated build script |
| `build-instructions.md` | Manual step-by-step instructions |
| `README.md` | This file |

## Extensions Included (24)

| Category | Extensions |
|----------|-----------|
| **Core** | autocomplete, icu, json, parquet, core_functions, jemalloc, shell |
| **Benchmarks** | tpcds, tpch |
| **Search** | fts, vss |
| **Database Connectors** | sqlite_scanner, postgres_scanner, mysql_scanner |
| **File Formats** | excel, avro |
| **Cloud Storage** | httpfs, aws, azure |
| **Table Formats** | iceberg, ducklake, delta |
| **Catalogs** | unity_catalog |
| **Networking** | inet |

## Extensions NOT Supported

| Extension | Reason |
|-----------|--------|
| **spatial** | GDAL 3.10.x API incompatibility (needs 3.8.x) |
| **vortex** | DuckDB API version mismatch in Rust FFI |
| **motherduck** | Proprietary/closed-source |

## Requirements

- Linux x64
- Git, CMake 3.15+, GCC/G++, Make
- Rust toolchain (for delta extension)
- ~20GB disk space for vcpkg dependencies

## Output

After successful build:
- Binary: `~/duckdbsrc/duckdb` (~150MB)
- All 24 extensions statically linked
- No runtime extension downloads needed
