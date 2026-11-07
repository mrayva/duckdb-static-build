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
- Size: 193MB in the current non-Spatial tip build, with statically linked Quack
- Current tip baseline: 24 runtime-loaded extensions, including statically linked HTTPFS and Quack
- ODBC is built as a loadable extension because its upstream implementation uses the C extension API and cannot be registered by the C++ static loader
- Add 1 loaded extension for `--with-spatial` on current tip for 25 total runtime-loaded extensions
- Current tip static build: build-clean with the repo script and compat patches

Current known-good verification matrix:
- `--skip-vcpkg --with-spatial`

The latest recorded full `test/unittest` run reported 10,608 passing cases and 6,513,219 assertions. Tests gated on unavailable external services or credentials, and tests marked flaky, unstable, or unsupported, were skipped; this does not mean every registered integration test ran.

The DuckDB-backed ODBC subset was separately validated: 24 tests and 301 assertions passed. Run it against a build with:

```bash
scripts/validate-odbc-tests.sh /path/to/duckdb/build/release-static
```

The validator creates an isolated unixODBC registry because SQLLogic tests may not see a user-level driver registration. ODBC tests for other database engines still require their own servers and connection strings.

## Extensions Included

| Category | Extensions |
|----------|------------|
| Core | autocomplete, icu, json, parquet, core_functions, jemalloc, shell |
| Benchmarks | tpcds, tpch |
| Search | fts, vss |
| Database Connectors | sqlite_scanner, postgres_scanner, mysql_scanner, odbc_scanner (loadable) |
| File Formats | excel, avro |
| Cloud Storage | httpfs, aws, azure |
| Table Formats | iceberg, ducklake, delta |
| Catalogs | unity_catalog |
| Networking | inet |
| Remote Access | quack (statically linked) |

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
| `scripts/validate-odbc-tests.sh` | Run DuckDB-backed ODBC tests with an isolated unixODBC registry |
| `README.md` | Summary |

## Requirements

- Linux x64
- Git, CMake 3.15+, GCC/G++, Make
- Rust toolchain (for delta extension)
- vcpkg
- `xxd` for spatial builds
- ~20GB free disk if doing fresh dependency setup
