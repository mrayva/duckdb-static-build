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
8. Optional dependency install (unless `--skip-vcpkg`):
- AWS SDK components
- Azure SDK components
- roaring
- libmariadb
9. Configures out-of-source build at `<duckdb-dir>/build/release-static` with:
- vcpkg toolchain
- `-DVCPKG_MANIFEST_MODE=OFF`
- linker flag `--allow-multiple-definition`
10. Merges global and extension-local `vcpkg_installed` trees.
11. Builds with `EXTENSION_STATIC_BUILD=1 make -j$(nproc)`.
12. Verifies runtime by counting loaded extensions from `duckdb_extensions()`.

## 5. Output/Success Criteria

On success, you should see:

- Binary at `<duckdb-dir>/build/release-static/duckdb`
- Size around ~149-150MB
- `All 24 extensions loaded successfully!`

## 6. Fast Rebuilds

If dependencies are already present:

```bash
./build-duckdb-static.sh \
  --duckdb-dir /tmp/duckdb-clean/duckdbsrc \
  --vcpkg-dir "$HOME/vcpkg" \
  --skip-vcpkg
```

Use `--clean` whenever upstream refreshes significantly or configure/build state looks inconsistent.

## 7. Spatial Extension: Current Status and Blocker

`spatial` is not included in the default 24-extension static set here.

Important distinction:
- Static build breakage from old refresh issues is not the primary blocker now.
- In clean setups, the immediate blocker is dependency provisioning and discovery.

Observed failure mode when testing spatial without proper vcpkg wiring:
- CMake reports missing package config for `unofficial-sqlite3`.
- System `SQLite3` being installed does not satisfy this specific vcpkg package lookup.

Why this happens:
- `spatial` CMake expects vcpkg-style package config discovery.
- `--skip-vcpkg` (or missing vcpkg toolchain) means those package config files are not available on CMake search paths.

## 8. Spatial Test Recipe (With Toolchain)

If you want to test spatial in a clean tree, do not skip vcpkg/toolchain setup.

```bash
cd /tmp/duckdb-clean/duckdbsrc

# Example local config for spatial-only test
cat > extension/extension_config_local.cmake <<'CMAKE_EOF'
duckdb_extension_load(spatial APPLY_PATCHES)
CMAKE_EOF

cmake -S . -B build/spatial-static-test \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=$HOME/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_TARGET_TRIPLET=x64-linux \
  -DDUCKDB_EXTENSION_CONFIGS=./extension/extension_config_local.cmake \
  -DBUILD_EXTENSIONS=spatial \
  -DBUILD_SHELL=1

cmake --build build/spatial-static-test --target spatial_extension shell -j$(nproc)
```

If configure still reports missing packages, install required vcpkg ports first or rerun with network enabled so dependency resolution can complete.

## 9. Troubleshooting

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
