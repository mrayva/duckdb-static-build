# DuckDB Static Build Kit

Build DuckDB with the current validated built-in extension set.
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
- Current tip baseline: 23 runtime-loaded built-in extensions
- Add 1 loaded extension for `--with-spatial` on current tip for 24 total runtime-loaded extensions
- `--with-openivm-loadable` keeps the default static extension count unchanged and also builds `openivm.duckdb_extension`

Current known-good verification matrix:
- `--skip-vcpkg --with-spatial`
- `--skip-vcpkg --with-openivm-loadable`

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

On current DuckDB tip, `jemalloc` is compiled into core allocator plumbing and is not counted by `duckdb_extensions()`.

## Spatial Status

`spatial` is available through `--with-spatial` and is intentionally not part of the default build.

The spatial integration does three extra things:
- Enables DuckDB's `spatial` config by removing `DONT_LINK`.
- Patches spatial's memvfs SQLite open flags so the embedded PROJ database can be opened as a URI.
- Regenerates spatial's embedded `proj_db.c` from the matching vcpkg `proj.db`, avoiding PROJ database layout mismatches.

If you use `--skip-vcpkg`, the spatial dependencies must already exist in `~/vcpkg`.

See [build-instructions.md](/home/mrayva/duckdbbld/build-instructions.md) for a dedicated spatial section.

## OpenIVM Status

`--with-openivm-loadable` is the supported OpenIVM integration path in this repo. It prepares the patched OpenIVM source tree, builds `openivm.duckdb_extension` as a regular loadable extension, and keeps OpenIVM out of DuckDB's static startup set.

For metadata regression checks, use the direct C++ probe in [`scripts/validate-openivm-meta.sh`](scripts/validate-openivm-meta.sh). It exercises `semi_anti_aux_meta_json` directly through DuckDB SQL and does not rely on sqllogic parsing.

The supported baseline is:
- OpenIVM loadable on normal DuckDB tables
- core OpenIVM functionality validated on the current tip baseline (`29 passed, 0 failed`)
- DuckLake-backed OpenIVM treated as experimental

The loadable profile builds into `<duckdb-dir>/build/release-static-openivm-loadable/` and the produced `openivm.duckdb_extension` is loaded with `-unsigned`, because the local artifact is not signed.

DuckLake-backed refresh remains outside the supported baseline.

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
- `xxd` for spatial builds
- ~20GB free disk if doing fresh dependency setup
