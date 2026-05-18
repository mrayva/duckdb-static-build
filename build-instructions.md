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

To include OpenIVM in the stable default profile:

```bash
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-openivm \
  --clean
```

To include OpenIVM in the active profile:

```bash
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-openivm-active \
  --clean
```

This active profile is still experimental and not functionally validated yet.

## 3. Permissions Needed In Restricted/Sandboxed Environments

You may need to allow:

1. Network access for:
- `git clone` of DuckDB
- FetchContent extension repos during CMake configure
- OpenIVM source checkout when `--with-openivm` is used

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
- prepares OpenIVM source when `--with-openivm` is passed
7. If `--with-openivm-active` is used, applies an extra OpenIVM runtime patch and enables OpenIVM sqllogictest discovery.
8. Optional dependency install (unless `--skip-vcpkg`):
- AWS SDK components
- Azure SDK components
- roaring
- libmariadb for `mysql_scanner`
- Spatial dependencies when `--with-spatial` is used: GDAL, PROJ, GEOS, SQLite with RTREE, curl, OpenSSL, zlib, expat
9. Configures out-of-source build at `<duckdb-dir>/build/release-static` with:
- vcpkg toolchain
- `-DVCPKG_MANIFEST_MODE=OFF`
- linker flag `--allow-multiple-definition`
10. `--with-openivm-active` uses `<duckdb-dir>/build/release-static-openivm-active` instead so it does not overwrite the stable build.
11. Merges global and extension-local `vcpkg_installed` trees.
12. When `--with-spatial` is used, regenerates spatial's embedded `proj_db.c` from the matching vcpkg `proj.db`.
13. Builds with `EXTENSION_STATIC_BUILD=1 make -j$(nproc)`.
14. Verifies runtime by counting loaded extensions from `duckdb_extensions()`.
15. If `--with-openivm-active` is used, builds `unittest/fast`, runs an OpenIVM shell smoke test, and runs selected OpenIVM sqllogictests.

## 5. Output/Success Criteria

On success, you should see:

- Binary at `<duckdb-dir>/build/release-static/duckdb`
- Size around ~149-150MB
- `All 24 extensions loaded successfully!`

With `--with-spatial`, expect 25 loaded extensions and a larger binary.
With both `--with-spatial --with-openivm`, expect 26 loaded extensions.
With `--with-spatial --with-openivm-active`, also expect 26 loaded extensions if the build completes.

Current known-good verification matrix:
- `--clean`
- `--skip-vcpkg`
- `--with-spatial`
- `--with-openivm`

That matrix built successfully with:
- Binary at `/tmp/duckdbsrc-exec/build/release-static/duckdb`
- Size `199M`
- `All 26 extensions loaded successfully!`
- `./duckdb -version` returned `v1.6.0-dev1450 (Development Version) 0bf859fca7`

Current non-validated profile:
- `--with-openivm-active`
- This profile currently builds, but runtime validation still fails in OpenIVM metadata publication and selected OpenIVM sqllogictests.

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

`openivm` is integrated behind two modes:

- `--with-openivm`
This is the stable default profile. OpenIVM is built and loaded, but the runtime hooks stay inert so DuckDB startup remains predictable.

- `--with-openivm-active`
This is the explicitly active profile. It re-enables OpenIVM parser/optimizer/pragma hooks, includes OpenIVM `test/sql` in DuckDB's generated extension test paths, and runs a small OpenIVM validation suite after build.

The stable profile is part of the current verified matrix.
The active profile is currently buildable but not functionally validated on this DuckDB snapshot.

The integration still relies on a maintained local patch because OpenIVM and its bundled `lpts` subtree need API-drift fixes for current DuckDB.

Preferred recipe:

```bash
cd /home/mrayva/duckdbbld
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-openivm \
  --clean
```

Active-profile recipe:

```bash
cd /home/mrayva/duckdbbld
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-openivm-active \
  --clean
```

Current active-profile failure surface:
- `CREATE MATERIALIZED VIEW` returns success but OpenIVM catalog state is not yet functionally validated end-to-end.
- Selected OpenIVM sqllogictests still fail after build.
- Treat this mode as buildable/experimental, not production-ready.

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
