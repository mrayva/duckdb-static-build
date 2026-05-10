# DuckDB Static Build Runbook

This document captures the complete build workflow implemented by `build-duckdb-static.sh`, including clean-environment setup and the spatial-specific dependency caveat.

## 1. Prerequisites

- Linux x64
- `git`, `cmake` (3.15+), `make`, `gcc`, `g++`, `sed`, `awk`, `python3`, `cargo`, `rustc`
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

To include experimental robust RPT:

```bash
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-robust-rpt \
  --clean
```

To include experimental aggjoin:

```bash
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-aggjoin \
  --clean
```

## 3. Permissions Needed In Restricted/Sandboxed Environments

You may need to allow:

1. Network access for:
- `git clone` of DuckDB
- FetchContent extension repos during CMake configure

2. Temporary directory cleanup when `/tmp` is full:
- `rm -rf /tmp/<old-build-dir>`

Without network, extension fetch/configure will fail.

## 4. What the Script Does (Step-by-Step)

The script performs these exact phases:

1. Checks required tools.
2. Ensures `vcpkg` exists (clones/bootstrap if missing).
3. Ensures DuckDB source exists (clones if missing).
4. Optional clean (`--clean`) of prior build artifacts.
5. Writes `extension/extension_config_local.cmake` with 21 externally managed extensions.
6. Patches selected extension config files:
- removes `DONT_LINK` where needed (`fts`, `vss`, `postgres_scanner`, `mysql_scanner`)
- injects required `INCLUDE_DIR` entries.
7. Writes patch files under `.github/patches/extensions/` for:
- `mysql_scanner` static build target + include/link wiring
- `postgres_scanner` static build target + include/link wiring
- `delta` rustls feature selection (avoids problematic native-tls/OpenSSL path)
- `robust` current-DuckDB compatibility when `--with-robust-rpt` is used
- `aggjoin` current-DuckDB compatibility when `--with-aggjoin` is used
8. Optional dependency install (unless `--skip-vcpkg`):
- AWS SDK components
- Azure SDK components
- roaring
- libmariadb
- Spatial dependencies when `--with-spatial` is used: GDAL, PROJ, GEOS, SQLite with RTREE, curl, OpenSSL, zlib, expat
- OpenSSL when `--with-robust-rpt` is used
- No extra vcpkg packages for `--with-aggjoin`
9. Configures out-of-source build at `<duckdb-dir>/build/release-static` with:
- vcpkg toolchain
- `-DVCPKG_MANIFEST_MODE=OFF`
- linker flag `--allow-multiple-definition`
10. Merges global and extension-local `vcpkg_installed` trees.
11. When `--with-spatial` is used, regenerates spatial's embedded `proj_db.c` from the matching vcpkg `proj.db`.
12. Builds with `EXTENSION_STATIC_BUILD=1 make -j$(nproc)`.
13. Verifies runtime by counting loaded extensions from `duckdb_extensions()`.

## 5. Output/Success Criteria

On success, you should see:

- Binary at `<duckdb-dir>/build/release-static/duckdb`
- Size around ~149-150MB
- `All 24 extensions loaded successfully!`

With `--with-spatial`, expect 25 loaded extensions and a larger binary.

With `--with-robust-rpt` or `--with-aggjoin`, expect one additional loaded extension per flag. Combining `--with-spatial --with-robust-rpt --with-aggjoin` should produce 27 loaded extensions.

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
gdal[network,geos] proj geos expat sqlite3[rtree] curl openssl zlib
```

## 9. Robust RPT Extension

`robust-labs/robust` is integrated behind `--with-robust-rpt`. It is not included by default because it requires patching upstream extension code for current DuckDB APIs.

The script pins robust to:

```text
5ec7800e000291e27f7433cb513ba606fc675fc1
```

The compatibility patch handles:
- The missing upstream `probe_empty_registry.hpp` include.
- `TableIndex` becoming a wrapper type instead of a raw `idx_t`.
- `ProjectionIndex` being required for dynamic table filter pushdown.
- Protected expression type access moving to `GetExpressionType()`.
- `GetTableIndex()` returning `TableIndex` values.

Focused validation performed:
- CMake configure loaded `robust` from `robust-labs/robust` at `5ec7800`.
- `cmake --build ... --target robust_extension duckdb -j4` completed successfully against DuckDB `ae0aec232a` / `v1.6.0-dev5563`.

Preferred recipe:

```bash
cd /home/mrayva/duckdbbld
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-robust-rpt \
  --clean
```

## 10. AggJoin Extension

`arselzer/duckdb_aggjoin` is integrated behind `--with-aggjoin`. It is not included by default because it requires patching upstream extension code for current DuckDB APIs.

The script pins aggjoin to:

```text
5f4b64ac879b13662142bd7624784a4ad709393c
```

The compatibility patch handles:
- Protected function/expression fields replaced with `GetName()`, `GetReturnType()`, and `GetExpressionType()`.
- `TableIndex` and `ProjectionIndex` wrapper conversions.
- Private `JoinCondition` fields replaced with accessors/constructor use.
- Mutable vector writes moved to `FlatVector::GetDataMutable()` / `ValidityMutable()`.

Focused validation performed:
- CMake configure loaded `aggjoin` from `arselzer/duckdb_aggjoin` at `5f4b64a`.
- `cmake --build ... --target aggjoin_extension duckdb -j4` completed successfully against DuckDB `ae0aec232a` / `v1.6.0-dev5563`.
- Full script validation with `--skip-vcpkg --with-aggjoin` produced a 153MB binary with 25 loaded extensions, including `aggjoin`.

Preferred recipe:

```bash
cd /home/mrayva/duckdbbld
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-aggjoin \
  --clean
```

## 11. Troubleshooting

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
