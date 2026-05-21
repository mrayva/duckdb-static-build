# DuckDB Static Build Runbook

This document captures the build workflow implemented by `build-duckdb-static.sh`, including clean-environment setup and the spatial-specific dependency caveat.

## 1. Prerequisites

- Linux x64
- `git`, `cmake` (3.15+), `make`, `gcc`, `g++`, `sed`, `awk`, `python3`, `cargo`, `rustc`
- `xxd` for spatial builds
- vcpkg at `~/vcpkg` (or pass `--vcpkg-dir`)
- Enough disk space (`/tmp` can fill quickly; ~20GB+ recommended for fresh runs)

## 2. Clean Environment (Recommended)

```bash
# Optional: check space first
df -h /tmp

# Fresh clone location
mkdir -p /tmp/duckdb-clean/ && cd /tmp/duckdb-clean
git clone https://github.com/duckdb/duckdb.git duckdbsrc
```

Then run from this repo:

```bash
cd /home/mrayva/duckdbbld
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --clean
```

To include spatial:

```bash
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-spatial \
  --clean
```

To build OpenIVM as a regular loadable extension instead of statically linking it:

```bash
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-openivm-loadable \
  --clean
```

## 3. Permissions Needed In Restricted/Sandboxed Environments

You may need to allow:

1. Network access for:
- `git clone` of DuckDB
- FetchContent extension repos during CMake configure
- OpenIVM source checkout when `--with-openivm-loadable` is used

2. Temporary directory cleanup when `/tmp` is full:
- `rm -rf /tmp/<old-build-dir>`

Without network, extension fetch/configure will fail.

## 4. What the Script Does (Step-by-Step)

The script performs these exact phases:

1. Checks required tools.
2. Ensures `vcpkg` exists (clones/bootstrap if missing).
3. Ensures DuckDB source exists (clones if missing).
4. Optional clean (`--clean`) of prior build artifacts.
5. Writes `extension/extension_config_local.cmake` with the externally managed extensions that should start with DuckDB.
6. Patches selected extension config files:
- removes `DONT_LINK` where needed (`fts`, `vss`, `postgres_scanner`)
- injects required `INCLUDE_DIR` entries
7. If `--with-openivm-loadable` is used, prepares OpenIVM source, marks it `DONT_LINK`, and builds it as a regular loadable extension instead of adding it to the static startup set.
9. Optional dependency install (unless `--skip-vcpkg`):
- AWS SDK components
- Azure SDK components
- roaring
- libmariadb for `mysql_scanner`
- Spatial dependencies when `--with-spatial` is used: GDAL, PROJ, GEOS, SQLite with RTREE, curl, OpenSSL, zlib, expat
10. Configures out-of-source build at `<duckdb-dir>/build/release-static` with:
- vcpkg toolchain
- `-DVCPKG_MANIFEST_MODE=OFF`
- linker flag `--allow-multiple-definition`
11. `--with-openivm-loadable` uses `<duckdb-dir>/build/release-static-openivm-loadable`.
13. Merges global and extension-local `vcpkg_installed` trees.
14. When `--with-spatial` is used, regenerates spatial's embedded `proj_db.c` from the matching vcpkg `proj.db`.
15. Builds with `EXTENSION_STATIC_BUILD=1 make -j$(nproc)`.
16. Verifies runtime by counting loaded extensions from `duckdb_extensions()`.
18. If `--with-openivm-loadable` is used, verifies that `extension/openivm/openivm.duckdb_extension` exists and can be loaded by the matching DuckDB binary with `-unsigned`.

## 5. Output/Success Criteria

On success, you should see:

- Binary at `<duckdb-dir>/build/release-static/duckdb`
- Size around ~149-150MB
- `All 24 extensions loaded successfully!`

With `--with-spatial`, expect 25 loaded extensions on the currently validated non-tip snapshot.
On current DuckDB tip, expect 24 loaded extensions for the same matrix because `jemalloc` is compiled into core and no longer appears in `duckdb_extensions()`.
With `--with-openivm-loadable`, expect the default static extension count plus a separate `openivm.duckdb_extension` artifact.

Current known-good verification matrix:
- `--clean`
- `--skip-vcpkg`
- `--with-spatial`
- `--with-openivm-loadable` for build/load validation only

Current preferred non-static OpenIVM profile:
- `--with-openivm-loadable`
- This profile builds OpenIVM as a regular loadable extension and keeps it out of the static startup set.

## 6. Fast Rebuilds

If dependencies are already present:

```bash
./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --skip-vcpkg
```

Use `--clean` whenever upstream refreshes significantly or configure/build state looks inconsistent.

## 7. Spatial Extension

`spatial` is integrated behind `--with-spatial`. It is not included by default because it adds a large native geospatial dependency chain and is more sensitive to vcpkg/PROJ version drift.

The script handles three spatial-specific issues:
- DuckDB still marks spatial with `DONT_LINK`; the script removes that flag only when `--with-spatial` is passed.
- Spatial's memvfs SQLite open must include URI mode for the embedded PROJ database.
- `duckdb-spatial` embeds `proj.db`; the script regenerates `proj_db.c` from the vcpkg `proj.db` so the database layout matches the linked PROJ library.

Observed failure modes:
- CMake reports missing package config for `unofficial-sqlite3`.
- System `SQLite3` being installed does not satisfy this specific vcpkg package lookup.
- Runtime `LOAD spatial` can fail with `Could not open sqlite3 memvfs database` if SQLite URI mode is not used.
- Runtime `LOAD spatial` can fail with `Could not set proj.db path` if the embedded `proj.db` does not match the linked PROJ library.

Why this happens:
- `spatial` CMake expects vcpkg-style package config discovery.
- `--skip-vcpkg` (or missing vcpkg toolchain) means those package config files are not available on CMake search paths.
- PROJ validates the schema layout of `proj.db` at runtime.

## 8. Spatial Build Recipe

Preferred path:

```bash
cd /home/mrayva/duckdbbld
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-spatial \
  --clean
```

If you pass `--skip-vcpkg`, these vcpkg packages must already be installed:

```bash
gdal[geos] proj geos expat sqlite3[rtree] curl openssl zlib libmariadb
```

## 9. OpenIVM Extension

- `--with-openivm-loadable`
This is the preferred non-static integration path. It builds the regular `openivm.duckdb_extension` artifact using the same patched OpenIVM source tree, while leaving DuckDB's static extension set unchanged.

The integration still relies on a maintained local patch because OpenIVM and its bundled `lpts` subtree need API-drift fixes for current DuckDB.

Loadable-profile recipe:

```bash
cd /home/mrayva/duckdbbld
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-openivm-loadable \
  --clean
```

Expected artifact:
- `<duckdb-dir>/build/release-static-openivm-loadable/extension/openivm/openivm.duckdb_extension`

What the build script verifies today:
- the artifact exists
- the matching DuckDB binary can `LOAD` it with `-unsigned`
- the scripted build installs a tracked DuckLake patch snapshot before configure so loadable OpenIVM runs reproduce the validated `ducklake_scan` behavior

What is not currently green:
- the full upstream OpenIVM SQL suite
- several DuckLake-specific tests

Current measured result on the validated host-side build:
- core suite on normal DuckDB tables (`ivm_*.test` + `mv_*.test`): `29 passed`, `0 failed`
- full upstream suite (`test/sql/*.test`): `32 passed`, `11 failed`

What is now validated:
1. `CREATE MATERIALIZED VIEW ...` creates OpenIVM catalog state
2. `_duckdb_ivm_views` and related metadata tables are created
3. `PRAGMA ivm('view_name')` works across the full core suite
4. all core incremental-refresh correctness tests are green
5. `ivm_concurrency.test` passes in the repo-local validator
6. DuckLake `ducklake_scan` serialization/registration is fixed for the loadable profile

Support boundary:
1. supported and validated: loadable OpenIVM on normal DuckDB tables
2. experimental and not part of the validated matrix: DuckLake-backed OpenIVM refresh

Main remaining failures:
1. DuckLake-specific failures remain in the full suite

Current DuckLake failure buckets:
1. correctness mismatches in:
   `ducklake_aggregate.test`, `ducklake_chained.test`, `ducklake_cte.test`,
   `ducklake_deltas.test`, `ducklake_distinct.test`, `ducklake_filter.test`,
   `ducklake_inner_join.test`, `ducklake_projection.test`, `ducklake_union.test`,
   `ducklake_v1_features.test`, `ducklake_window_delta.test`

Functional validation command:

```bash
./scripts/validate-openivm-functional.sh \
  /tmp/duckdb-clean/duckdbsrc/build/release-static-openivm-loadable core
```

To run the full OpenIVM upstream SQL suite:

```bash
./scripts/validate-openivm-functional.sh \
  /tmp/duckdb-clean/duckdbsrc/build/release-static-openivm-loadable full
```

## 10. Troubleshooting

### `/tmp` out of space

```bash
df -h /tmp
du -sh /tmp/* | sort -hr | head
rm -rf /tmp/<old-large-build-dir>
```

### FetchContent patch/apply conflicts after upstream change

Run with `--clean` so cached `_deps` checkouts are removed.

### Build succeeds but extension count is not 24

Run:

```bash
<duckdb-dir>/build/release-static/duckdb \
  -c "SELECT extension_name, loaded FROM duckdb_extensions() ORDER BY extension_name;"
```

Then inspect missing extension logs in `<duckdb-dir>/build/release-static`.

On current DuckDB tip, `jemalloc` no longer appears in `duckdb_extensions()` because upstream moved it into core allocator plumbing. A tip build can therefore be correct even if the runtime-loaded extension count is one lower than older snapshots.

### Network-related clone/fetch failures

Re-run with network access enabled; extension fetch is required at configure time.
