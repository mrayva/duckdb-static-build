# DuckDB Static Build Instructions (24 Extensions)

Complete instructions to build DuckDB with 24 statically-linked core extensions from a fresh clone.

## Prerequisites

- Linux (tested on x64)
- Git, CMake 3.15+, GCC/Clang, Make, Rust (for delta extension)
- vcpkg (will be installed if needed)
- libmariadb-dev (for mysql_scanner)

## Quick Start

Use the automated build script:

```bash
./build-duckdb-static.sh --clean
```

Or follow the manual steps below.

## Step 1: Install vcpkg

```bash
cd ~
git clone https://github.com/microsoft/vcpkg.git
cd vcpkg
./bootstrap-vcpkg.sh
```

## Step 2: Clone DuckDB

```bash
cd ~
git clone https://github.com/duckdb/duckdb.git duckdbsrc
cd duckdbsrc
```

## Step 3: Configure Extensions

Create `extension/extension_config_local.cmake`:

```cmake
duckdb_extension_load(autocomplete)
duckdb_extension_load(icu)
duckdb_extension_load(tpcds)
duckdb_extension_load(tpch)
duckdb_extension_load(fts)
duckdb_extension_load(json)
duckdb_extension_load(parquet)
duckdb_extension_load(sqlite_scanner)
duckdb_extension_load(postgres_scanner)
duckdb_extension_load(mysql_scanner APPLY_PATCHES)
duckdb_extension_load(httpfs)
duckdb_extension_load(excel)
duckdb_extension_load(vss)
duckdb_extension_load(inet)
duckdb_extension_load(avro)
duckdb_extension_load(aws)
duckdb_extension_load(azure)
duckdb_extension_load(iceberg)
duckdb_extension_load(ducklake APPLY_PATCHES)
duckdb_extension_load(delta)
duckdb_extension_load(unity_catalog
    GIT_URL https://github.com/duckdb/unity_catalog
    GIT_TAG main
)
```

## Step 4: Remove DONT_LINK Flags and Add INCLUDE_DIRs

### FTS Extension
Edit `.github/config/extensions/fts.cmake` - remove `DONT_LINK` and add `INCLUDE_DIR`:

```cmake
duckdb_extension_load(fts
    LOAD_TESTS
    GIT_URL https://github.com/duckdb/duckdb_fts
    GIT_TAG ...
    INCLUDE_DIR extension/fts/include
    TEST_DIR test/sql
)
```

### VSS Extension
Edit `.github/config/extensions/vss.cmake` - remove `DONT_LINK`:

```cmake
duckdb_extension_load(vss
    LOAD_TESTS
    GIT_URL https://github.com/duckdb/duckdb_vss
    GIT_TAG ...
    TEST_DIR test/sql
)
```

### postgres_scanner Extension
Edit `.github/config/extensions/postgres_scanner.cmake` - remove `DONT_LINK` and add `INCLUDE_DIR`:

```cmake
duckdb_extension_load(postgres_scanner
    ...
    INCLUDE_DIR src/include
    ...
)
```

### mysql_scanner Extension
Edit `.github/config/extensions/mysql_scanner.cmake` - remove `DONT_LINK` and add `INCLUDE_DIR`:

```cmake
duckdb_extension_load(mysql_scanner
    ...
    INCLUDE_DIR src/include
    ...
)
```

## Step 5: Install vcpkg Dependencies

```bash
cd ~/vcpkg
./vcpkg install \
  aws-sdk-cpp[core,s3,transfer,config,sts,sso,identity-management] \
  azure-storage-blobs-cpp \
  azure-storage-files-datalake-cpp \
  azure-identity-cpp \
  roaring \
  libmariadb
```

This takes ~15-20 minutes. Dependencies include:
- AWS SDK with all required components (~5 min)
- Azure SDK with DataLake support (~3 min)
- Avro-C (custom 1.11.3, auto-installed by extension)
- Roaring (for iceberg)
- libmariadb (for mysql_scanner)

## Step 6: Merge vcpkg Dependencies

After Step 7 (configure) fetches extensions, merge their vcpkg dependencies:

```bash
cd ~/duckdbsrc

# Copy from global vcpkg
cp -r ~/vcpkg/installed/x64-linux/* vcpkg_installed/x64-linux/

# Merge extension-specific vcpkg directories
for ext in _deps/*_extension_fc-src; do
  if [ -d "$ext/vcpkg_installed/x64-linux" ]; then
    cp -r "$ext/vcpkg_installed/x64-linux"/* vcpkg_installed/x64-linux/
  fi
done
```

## Step 7: Configure Build

```bash
cd ~/duckdbsrc

# Create minimal vcpkg.json to avoid manifest mode conflicts
echo '{"name":"duckdb","version":"1.0.0"}' > vcpkg.json

# Note: --allow-multiple-definition required for postgres_scanner + mysql_scanner
cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=~/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_MANIFEST_MODE=OFF \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
  -DBUILD_EXTENSIONS="autocomplete;icu;tpcds;tpch;fts;json;parquet;sqlite_scanner;postgres_scanner;mysql_scanner;httpfs;excel;vss;inet;avro;aws;azure;iceberg;ducklake;delta;unity_catalog" \
  .
```

**Then run Step 6** to merge vcpkg dependencies after extensions are fetched.

## Step 7b: Patch postgres_scanner for Static Build

The postgres_scanner extension needs CMakeLists.txt patching to enable static builds:

```bash
# Add build_static_extension() call before set(PARAMETERS)
# Add target_include_directories for _extension target
# Add target_link_libraries for _extension target
```

See the build script for the exact patch applied.

## Step 7c: Patch delta for rustls

The delta extension uses native-tls by default which conflicts with OpenSSL versions. Patch to use rustls:

```bash
# In _deps/delta_extension_fc-src/CMakeLists.txt
# Replace --all-features with:
# --no-default-features --features "default-engine-rustls,tracing,test-ffi"
```

## Step 8: Build

```bash
cd ~/duckdbsrc
EXTENSION_STATIC_BUILD=1 make -j$(nproc)
```

Build time: ~5-10 minutes depending on CPU.

## Step 9: Verify

```bash
./duckdb -c "SELECT extension_name, loaded FROM duckdb_extensions() WHERE installed=true ORDER BY extension_name;"
```

Expected output: 24 extensions, all `loaded=true`:
- autocomplete
- avro
- aws
- azure
- core_functions
- delta
- ducklake
- excel
- fts
- httpfs
- iceberg
- icu
- inet
- jemalloc
- json
- mysql_scanner
- parquet
- postgres_scanner
- shell
- sqlite_scanner
- tpcds
- tpch
- unity_catalog
- vss

Binary size: ~150MB at `./duckdb`

## Extensions NOT Included (Cannot Be Statically Linked)

| Extension | Reason |
|-----------|--------|
| **spatial** | GDAL API incompatibility - system GDAL 3.10.x has new pure virtual methods (ClearErr, Error, MultipartUpload*, CopyFileRestartable) not implemented in spatial's VSIFilesystemHandler. Extension requires GDAL 3.8.x. |
| **vortex** | DuckDB API version mismatch - Rust FFI bindings were generated for DuckDB 1.4.x. Current main branch (1.5.0-dev) has incompatible ExceptionFormatValue and TableFunction signatures. |
| **motherduck** | Proprietary/closed-source - no source code available for static linking. |
| **ui** | Complex web/UI dependencies - not a core data processing extension. |

## Troubleshooting

### Extensions not found during configure
Run with `-DBUILD_EXTENSIONS="..."` to fetch them first.

### Missing symbols during link
Merge vcpkg_installed directories from all extension sources (Step 6).

### avro-c not found
The extension auto-fetches custom avro-c 1.11.3 from DuckDB's vcpkg registry.

### Build fails after vcpkg install
Re-run Step 6 to ensure all libraries are merged into main vcpkg_installed directory.

### Multiple definition errors
Use `-DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition"` - postgres_scanner and mysql_scanner share some helper functions.

### delta OpenSSL conflicts
Patch delta's CMakeLists.txt to use rustls instead of native-tls (see Step 7c).

## Clean Rebuild

```bash
cd ~/duckdbsrc
rm -rf CMakeCache.txt CMakeFiles/ build*/ _deps/ duckdb duckdb_platform_* *.log \
  cmake_install.cmake DuckDB*.cmake DuckDBExports.cmake compile_commands.json \
  codegen/include/* codegen/src/*
```

Then repeat Steps 7-9.
