# DuckDB Static Build Runbook

This runbook describes the locked source build implemented by `build-duckdb-static.sh`. The validated DuckDB, vcpkg, Iceberg, and extension commits are recorded in `build.lock`.

## 1. Prerequisites

- Linux x64
- `git`, `cmake`, `make`, `gcc`, `g++`, `sed`, `awk`, `python3`, `cargo`, `rustc`
- `xxd` for spatial builds
- Network access to GitHub and the source hosts used by vcpkg
- vcpkg path (defaults to `~/vcpkg`; pass `--vcpkg-dir` to override)
- At least 20 GB free for a clean source/build tree; allow more when bootstrapping vcpkg dependencies

## 2. Clean Environment (Recommended)

```bash
df -h /tmp
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-repro/duckdb \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-spatial --jobs 8 --clean
```

The script clones DuckDB at the locked commit when the target directory is absent, pins configured extension repositories from `build.lock`, bootstraps the pinned vcpkg checkout if needed, installs native dependencies, configures an out-of-source build, and verifies the result. Existing DuckDB or vcpkg checkouts at a different commit are rejected and left untouched; use a fresh directory instead of resetting an existing checkout.

Do not pass `--refresh-extension-tips` for a reproducible build. That option intentionally replaces locked extension revisions with moving upstream tips. `CCACHE_DISABLE=1` avoids compiler-cache reuse; it is not required for source-version locking.

Verified clean run on 2026-11-02:

```bash
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-repro-20261102-buildlock \
  --vcpkg-dir "$HOME/vcpkg" \
  --skip-vcpkg --with-spatial --jobs 8 --clean
```

This produced DuckDB `v2.1.0-dev1`, loaded all 27 expected extensions, passed the ODBC sidecar smoke check, and built `test/unittest`. Configure took 838 seconds and compilation took 1464 seconds. It used `--skip-vcpkg` with packages already present in the host's vcpkg installation; provisioning every vcpkg package from an empty installation is not yet claimed as validated.

The clean build on 2026-11-07 loaded all 27 configured extensions. The full `test/unittest` suite was rerun on 2026-11-14 and passed all 10,607 executed cases with 6,526,397 assertions. The DuckDB-backed ODBC subset passed 24 cases with 301 assertions. Spatial expected outputs are updated for the pinned GEOS 3.15.0 behavior. Core SQLLogic tests explicitly stop test-owned Quack servers, preventing the prior order-dependent `attach_secret_name.test` authentication failure. The full run skipped 137 ODBC cases gated on `ODBC_CONN_STRING`, 17 DuckLake connection cases, 12 Lance S3 cases, and 51 S3-server cases, plus other credential/service-gated tests. External database ODBC connectivity and all registered integrations are therefore not claimed as validated.

## 3. Network and Disk

Network access is required for DuckDB/extension checkouts, Cargo dependencies, and vcpkg sources. A fresh target directory avoids modifying an existing user checkout. If the build fails for lack of space, inspect `df -h` and remove only build directories known to be generated for this project.

## 4. What the Script Does (Step-by-Step)

The script performs these exact phases:

1. Checks required tools.
2. Checks out the exact vcpkg and DuckDB revisions from `build.lock` (without resetting mismatched existing checkouts).
3. Applies locked extension revisions, unless the explicit non-reproducible `--refresh-extension-tips` option is used.
4. Optionally cleans generated build artifacts (`--clean`).
5. Writes `extension/extension_config_local.cmake` for optional out-of-tree extensions.
6. Applies the repository's narrowly scoped compatibility patches and config adjustments:
- removes `DONT_LINK` where needed (`fts`, `vss`, `postgres_scanner`)
- injects required `INCLUDE_DIR` entries
7. Installs native dependencies unless `--skip-vcpkg` is used:
- AWS SDK components
- Azure SDK components
- roaring
- libmariadb for `mysql_scanner`
- Spatial dependencies when `--with-spatial` is used: GDAL, PROJ, GEOS, SQLite with RTREE, curl, OpenSSL, zlib, expat
8. Configures the out-of-source build at `<duckdb-dir>/build/release-static` with:
- vcpkg toolchain
- `-DVCPKG_MANIFEST_MODE=OFF`
- linker flag `--allow-multiple-definition`
9. Merges global and extension-local `vcpkg_installed` trees.
10. When `--with-spatial` is used, regenerates spatial's embedded `proj_db.c` from the matching vcpkg `proj.db`.
11. Builds with `EXTENSION_STATIC_BUILD=1 make -jN` (`N` is `--jobs`).
12. Verifies the loaded-extension count and smoke-tests the ODBC loadable extension.

## 5. Output/Success Criteria

On success, you should see:

- CLI binary at `<duckdb-dir>/build/release-static/duckdb`
- 26 loaded extensions without Spatial, or 27 with `--with-spatial` (DuckLake included)
- ODBC loadable extension at `extension/odbc_scanner/odbc_scanner.duckdb_extension`, passing the script's load/query smoke check
- `jemalloc` compiled into core allocator plumbing and not counted by `duckdb_extensions()`
- Script prints `BUILD SUCCESSFUL` only after those checks pass

The build script compiles test binaries, but it does not run the full DuckDB test suite. Report full-suite results separately from a successful build/runtime smoke, including the count and reasons for skipped tests.

## 6. Fast Rebuilds

If dependencies are already present:

```bash
./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-repro/duckdb \
  --vcpkg-dir "$HOME/vcpkg" \
  --skip-vcpkg
```

Use this only after the required packages are installed in that vcpkg tree. Use `--clean` to discard generated CMake/FetchContent state and rebuild from the locked sources.

## 7. Spatial Extension

`spatial` is integrated behind `--with-spatial` and is excluded by default because it adds a large native geospatial dependency chain.

The script handles three spatial-specific issues:
- The script enables the spatial extension config only when `--with-spatial` is passed.
- Spatial's memvfs SQLite open must include URI mode for the embedded PROJ database.
- `duckdb-spatial` embeds `proj.db`; the script regenerates `proj_db.c` from the vcpkg `proj.db` so the database layout matches the linked PROJ library.

The vcpkg revision is pinned, and the script regenerates Spatial's embedded PROJ database from the installed PROJ package to keep the embedded schema aligned with the linked library.

## 8. Spatial Build Recipe

Preferred path:

```bash
cd /home/mrayva/duckdbbld
CCACHE_DISABLE=1 ./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-repro/duckdb \
  --vcpkg-dir "$HOME/vcpkg" \
  --with-spatial --jobs 8 --clean
```

If you pass `--skip-vcpkg`, these vcpkg packages must already be installed in the selected vcpkg tree:

```bash
gdal[geos] proj geos expat sqlite3[rtree] curl openssl zlib libmariadb
```

## 9. OpenIVM and DuckDBSP

OpenIVM and DuckDBSP are no longer built from this repo. They are built separately from their own repos, `mrayva/openivm` and `mrayva/duckdbsp`.

## 10. Troubleshooting

### `/tmp` out of space

```bash
df -h /tmp
du -sh /tmp/* | sort -hr | head
# Remove only a build directory you have confirmed is disposable.
```

### FetchContent patch/apply conflicts after upstream change

Run with `--clean` so cached `_deps` checkouts are removed.

### Build succeeds but extension count is not 26/27

Run:

```bash
<duckdb-dir>/build/release-static/duckdb \
  -c "SELECT extension_name, loaded FROM duckdb_extensions() ORDER BY extension_name;"
```

Then inspect missing extension logs in `<duckdb-dir>/build/release-static`.

### Run the test suite

After a successful build, run the core suite separately:

```bash
cd /tmp/duckdb-repro/duckdb/build/release-static
./test/unittest --reporter compact
```

Record its pass/fail output separately; the build script's smoke checks are not a substitute for this suite.

### Network-related clone/fetch failures

Re-run with network access enabled; extension fetch is required at configure time.
