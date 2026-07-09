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

For the semi/anti metadata regression check, use `scripts/validate-openivm-meta.sh <duckdb-build-dir>`. That probe queries `_duckdb_ivm_views` directly through DuckDB SQL, outside sqllogic.

## 5. Output/Success Criteria

On success, you should see:

- Binary at `<duckdb-dir>/build/release-static/duckdb`
- Size around ~149-150MB
- `23 runtime-loaded built-in extensions` on current DuckDB tip
- `jemalloc` compiled into core allocator plumbing and not counted by `duckdb_extensions()`
- `24 runtime-loaded built-in extensions` when `--with-spatial` is enabled

With `--with-spatial`, expect 24 loaded extensions and a larger binary.
With `--with-openivm-loadable`, expect the default static extension count plus a separate `openivm.duckdb_extension` artifact.

Current known-good verification matrix:
- `--clean`
- `--skip-vcpkg`
- `--with-spatial`
- `--with-openivm-loadable`
- current tip static release build completes successfully with the repo compat patches

Current known test boundary on DuckDB tip:
- `./test/unittest --abort` currently fails at `test/extension/test_remote_optimizer.cpp`
- failure signature: remote optimizer serialized-plan path throws `Not implemented Error: PLAN_STATEMENT`
- treat the tip baseline as build-clean, not full-`unittest`-clean

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
This is the supported non-static integration path. It builds the regular `openivm.duckdb_extension` artifact using the patched OpenIVM source tree, while leaving DuckDB's static extension set unchanged.

The integration still relies on a maintained local patch because OpenIVM and its bundled `lpts` subtree need API-drift fixes for current DuckDB.

Supported OpenIVM baseline:
- normal DuckDB tables: validated
- current tip non-DuckLake core suite: `29 passed, 0 failed`
- DuckLake-backed refresh: experimental
- current tip build: build-clean and core-functional on the non-DuckLake path

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

Current status note:
- The non-DuckLake OpenIVM path is the supported tip baseline.
- DuckLake-backed refresh remains an experimental path and is not part of the supported baseline.

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

### Network-related clone/fetch failures

Re-run with network access enabled; extension fetch is required at configure time.
