# DuckDB Static Build Kit

Build DuckDB with 24 statically-linked core extensions.

## Quick Start

```bash
# First build in a clean clone (recommended)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --clean

# Subsequent builds in same tree (faster)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --skip-vcpkg
```

## What This Produces

- Binary: `<duckdb-dir>/build/release-static/duckdb`
- Size: typically ~149-150MB
- 24 statically linked extensions loaded at runtime (no download/install needed)

## Extensions Included (24)

| Category | Extensions |
|----------|-----------|
| Core | autocomplete, icu, json, parquet, core_functions, jemalloc, shell |
| Benchmarks | tpcds, tpch |
| Search | fts, vss |
| Database Connectors | sqlite_scanner, postgres_scanner, mysql_scanner |
| File Formats | excel, avro |
| Cloud Storage | httpfs, aws, azure |
| Table Formats | iceberg, ducklake, delta |
| Catalogs | unity_catalog |
| Networking | inet |

## Spatial Status

`spatial` is intentionally not part of the default 24-extension static build in this repo.

Current blocker in clean environments is dependency provisioning through vcpkg/toolchain wiring:
- `spatial` requires packages discovered as vcpkg CMake configs (for example `unofficial-sqlite3`).
- If you build with `--skip-vcpkg` or without the vcpkg toolchain, configure can fail even if system `sqlite3` exists.

See [build-instructions.md](/home/mrayva/duckdbbld/build-instructions.md) for a dedicated spatial section.

## Files

| File | Description |
|------|-------------|
| `build-duckdb-static.sh` | Automated build script |
| `build-instructions.md` | Full build/runbook (clean env + troubleshooting) |
| `README.md` | Summary |

## Requirements

- Linux x64
- Git, CMake 3.15+, GCC/G++, Make
- Rust toolchain (for delta extension)
- vcpkg
- ~20GB free disk if doing fresh dependency setup
