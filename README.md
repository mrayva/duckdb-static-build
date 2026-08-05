# DuckDB Static Build Kit

Build DuckDB with the current validated built-in extension set.
Optionally include `spatial`.

OpenIVM and DuckDBSP are built separately from `mrayva/openivm` and `mrayva/duckdbsp` and are no longer part of this repo.

## Quick Start

```bash
# First build in a clean clone (recommended)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --clean

# Subsequent builds in same tree (faster)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --skip-vcpkg

# Include spatial (requires GDAL/PROJ/GEOS/SQLite vcpkg deps)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --with-spatial --clean
```

## What This Produces

- Binary: `<duckdb-dir>/build/release-static/duckdb`
- Size: typically ~149-150MB
- Current tip baseline: 23 runtime-loaded built-in extensions
- Add 1 loaded extension for `--with-spatial` on current tip for 24 total runtime-loaded extensions
- Current tip static build: build-clean with the repo script and compat patches

Current known-good verification matrix:
- `--skip-vcpkg --with-spatial`

Current known test boundary on DuckDB tip:
- `./test/unittest --abort` still stops on the upstream remote-optimizer serialized-plan regression (`PLAN_STATEMENT` in `test_remote_optimizer.cpp`)

## Extensions Included

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

## OpenIVM and DuckDBSP

OpenIVM and DuckDBSP are no longer built from this repo. They are built separately from their own repos, `mrayva/openivm` and `mrayva/duckdbsp`.

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
