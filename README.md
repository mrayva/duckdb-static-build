# DuckDB Static Build Kit

Build DuckDB with 24 statically linked core extensions.
Optionally include `spatial`, and optionally build `openivm` as a regular loadable extension.

## Quick Start

```bash
# First build in a clean clone (recommended)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --clean

# Subsequent builds in same tree (faster)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --skip-vcpkg

# Include spatial (requires GDAL/PROJ/GEOS/SQLite vcpkg deps)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --with-spatial --clean

# Build openivm as a regular loadable extension
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --with-openivm-loadable --clean
```

## What This Produces

- Binary: `<duckdb-dir>/build/release-static/duckdb`
- Size: typically ~149-150MB
- 24 statically linked extensions loaded at runtime
- Add 1 loaded extension for `--with-spatial`
- `--with-openivm-loadable` keeps the default static extension count unchanged and also builds `openivm.duckdb_extension`

Current known-good verification matrix:
- `--skip-vcpkg --with-spatial`
- `--skip-vcpkg --with-openivm-loadable` for build/load verification only

## Extensions Included (24)

| Category | Extensions |
|----------|------------|
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

`spatial` is available through `--with-spatial` and is intentionally not part of the default build.

The spatial integration does three extra things:
- Enables DuckDB's `spatial` config by removing `DONT_LINK`.
- Patches spatial's memvfs SQLite open flags so the embedded PROJ database can be opened as a URI.
- Regenerates spatial's embedded `proj_db.c` from the matching vcpkg `proj.db`, avoiding PROJ database layout mismatches.

If you use `--skip-vcpkg`, the spatial dependencies must already exist in `~/vcpkg`.

See [build-instructions.md](/home/mrayva/duckdbbld/build-instructions.md) for a dedicated spatial section.

## OpenIVM Status

`--with-openivm-loadable` is the preferred non-static integration path. It prepares the same patched OpenIVM source tree, builds `openivm.duckdb_extension` as a regular loadable extension, and keeps OpenIVM out of DuckDB's static startup set.

The loadable profile builds into `<duckdb-dir>/build/release-static-openivm-loadable/` and verifies that the produced `openivm.duckdb_extension` can be loaded by the matching DuckDB binary with `-unsigned`, because the local artifact is not signed.

This is now the only supported OpenIVM integration path in this repo. Upstream DuckDB or OpenIVM refreshes may still require patch refreshes.

Functional OpenIVM validation is materially working. The loadable artifact builds and loads, and the runtime now executes `CREATE MATERIALIZED VIEW` side effects correctly:
- core suite (`ivm_*.test` + `mv_*.test`): `28 passed`, `1 failed`
- full suite (`test/sql/*.test`): `30 passed`, `13 failed`

What is now working:
- `CREATE MATERIALIZED VIEW ...` creates OpenIVM catalog state
- `_duckdb_ivm_*` metadata tables are created
- `PRAGMA ivm('view_name')` works for a substantial subset of views
- inner-join refresh correctness is fixed for the core suite
- `ivm_concurrency.test` passes in the repo-local validator

What is still failing:
- one cost-model mismatch in `ivm_auto_refresh.test`
- several DuckLake-specific tests in the full suite

Current DuckLake failure buckets:
- correctness mismatches in aggregate/projection/filter/union/chained/cte/distinct/delta cases
- `DuckLakeScan` serialization gaps in `ducklake_inner_join.test`, `ducklake_window.test`, and `ducklake_window_delta.test`

Use the repo-local validator to reproduce the current status:

```bash
./scripts/validate-openivm-functional.sh \
  /tmp/duckdb-clean/duckdbsrc/build/release-static-openivm-loadable core
```

Use `full` instead of `core` to run the entire upstream `test/sql/*.test` set.

## Files

| File | Description |
|------|-------------|
| `build-duckdb-static.sh` | Automated build script |
| `build-instructions.md` | Full build/runbook (clean env + troubleshooting) |
| `scripts/validate-openivm-functional.sh` | OpenIVM functional validator |
| `README.md` | Summary |

## Requirements

- Linux x64
- Git, CMake 3.15+, GCC/G++, Make
- Rust toolchain (for delta extension)
- vcpkg
- `xxd` for spatial builds
- ~20GB free disk if doing fresh dependency setup
