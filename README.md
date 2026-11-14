# DuckDB Static Build Kit

Build DuckDB with the current validated built-in extension set.
Optionally include `spatial`.

OpenIVM and DuckDBSP are built separately from `mrayva/openivm` and `mrayva/duckdbsp` and are no longer part of this repo.

## Reproducible Build

```bash
# Uses exact revisions in build.lock; installs pinned vcpkg dependencies.
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-repro/duckdb \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-spatial --jobs 8 --clean
```

The script checks out the DuckDB and vcpkg commits from `build.lock`, pins each configured extension source to its locked commit, applies the repository compatibility patches, then performs a clean static build. Network access is required for GitHub and vcpkg source downloads. Do not pass `--refresh-extension-tips` for a reproducible build; that deliberately resolves moving upstream revisions.

`--skip-vcpkg` is only for a faster rebuild when the required packages are already installed for the locked vcpkg checkout. It does not provision a clean machine. The successful clean build documented here reused the host's already-installed vcpkg packages, so the package-install-from-empty-cache path remains a separate validation item.

## Validation Status

The clean build completed on 2026-11-07. The full `test/unittest` suite was rerun on 2026-11-14 and passed all 10,607 executed cases with 6,526,397 assertions. The DuckDB-backed ODBC subset passed 24 cases with 301 assertions. External-service and credential-gated cases remain skipped when prerequisites are absent; in the latest full run this included 137 ODBC cases gated on `ODBC_CONN_STRING`, 17 DuckLake connection cases, 12 Lance S3 cases, and 51 S3-server cases. This does not validate every registered integration test.

The Spatial test expectations are pinned to the build's GEOS 3.15.0 behavior. Core SQLLogic tests now stop their test-owned Quack listeners explicitly, fixing an order-dependent authentication failure in the full suite.

## What This Produces

- Binary: `<duckdb-dir>/build/release-static/duckdb`
- The locked baseline loads 26 extensions without Spatial, or 27 with `--with-spatial` (including DuckLake)
- The ODBC scanner is built as a separate loadable extension and smoke-tested independently; it is not part of the static extension count
- DuckDB-backed ODBC SQL tests can be run with `scripts/validate-odbc-tests.sh <duckdb-build-dir>`; the script creates a temporary unixODBC driver registry so SQLLogic's per-test home directory cannot hide a user-level driver registration
- OpenIVM and DuckDBSP are intentionally built from their separate repositories, not this project

The build script verifies the extension count and runs an ODBC load/query smoke check. A successful build does not imply that DuckDB's full unit-test suite has been run.

The ODBC scanner's DuckDB-specific tests are separate from the full unit suite because the other ODBC tests target external database systems. Run the 24 DuckDB-backed and generic connection-lifecycle tests with:

```bash
scripts/validate-odbc-tests.sh /path/to/duckdb/build/release-static
```

The external-backend ODBC cases remain unvalidated unless their corresponding database servers and connection strings are configured.

Verified clean build on 2026-11-02: DuckDB `v2.1.0-dev1`, 27 loaded extensions, ODBC smoke passed. The build completed from a clean DuckDB build directory using the locked source revisions, but reused native packages already installed in the host vcpkg tree. Empty-cache vcpkg provisioning remains unverified.

An earlier full `test/unittest` run reported 10,608 passing cases and 6,513,219 assertions. It was superseded by the 2026-11-14 suite run above. External-service and credential-gated tests were skipped in both runs; this does not claim every registered integration test ran.

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

In this locked DuckDB revision, `jemalloc` is compiled into core allocator plumbing and is not counted by `duckdb_extensions()`.

## Spatial Status

`spatial` is available through `--with-spatial` and is intentionally not part of the default build.

The spatial integration does three extra things:
- Enables DuckDB's `spatial` config by removing `DONT_LINK`.
- Patches spatial's memvfs SQLite open flags so the embedded PROJ database can be opened as a URI.
- Regenerates spatial's embedded `proj_db.c` from the matching vcpkg `proj.db`, avoiding PROJ database layout mismatches.

Spatial's native dependencies are installed by the default vcpkg step. If you use `--skip-vcpkg`, they must already exist in the selected vcpkg installation.

See [build-instructions.md](/home/mrayva/duckdbbld/build-instructions.md) for a dedicated spatial section.

## OpenIVM and DuckDBSP

OpenIVM and DuckDBSP are no longer built from this repo. They are built separately from their own repos, `mrayva/openivm` and `mrayva/duckdbsp`.

## Files

| File | Description |
|------|-------------|
| `build-duckdb-static.sh` | Automated build script |
| `build-instructions.md` | Full build/runbook (locked sources, prerequisites, and troubleshooting) |
| `scripts/validate-odbc-tests.sh` | Run the DuckDB-backed ODBC scanner tests with an isolated unixODBC registry |
| `build.lock` | Exact DuckDB, vcpkg, Iceberg, and extension source revisions |
| `README.md` | Summary |

## Requirements

- Linux x64
- Git, CMake 3.15+, GCC/G++, Make
- Rust toolchain (for delta extension)
- vcpkg
- `xxd` for spatial builds
- ~20GB free disk for a clean source/build tree; allow additional space if bootstrapping vcpkg dependencies
