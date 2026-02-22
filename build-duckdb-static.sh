#!/bin/bash
set -e  # Exit on error

# DuckDB Static Build Script
# Builds DuckDB with 24 statically-linked core extensions
# Usage: ./build-duckdb-static.sh [options]
#   Options:
#     --vcpkg-dir DIR    Path to vcpkg installation (default: ~/vcpkg)
#     --duckdb-dir DIR   Path to DuckDB source (default: ~/duckdbsrc)
#     --skip-vcpkg       Skip vcpkg dependency installation
#     --clean            Clean build before starting
#     --help             Show this help

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default paths
VCPKG_DIR="$HOME/vcpkg"
DUCKDB_DIR="$HOME/duckdbsrc"
SKIP_VCPKG=false
CLEAN_BUILD=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --vcpkg-dir)
      VCPKG_DIR="$2"
      shift 2
      ;;
    --duckdb-dir)
      DUCKDB_DIR="$2"
      shift 2
      ;;
    --skip-vcpkg)
      SKIP_VCPKG=true
      shift
      ;;
    --clean)
      CLEAN_BUILD=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //'
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
log_info "Checking prerequisites..."
for cmd in git cmake make gcc g++; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd not found. Please install it first."
        exit 1
    fi
done
log_success "All prerequisites found"

# Step 1: Install/check vcpkg
log_info "Step 1: Setting up vcpkg at $VCPKG_DIR"
if [ ! -d "$VCPKG_DIR" ]; then
    log_info "Cloning vcpkg..."
    git clone https://github.com/microsoft/vcpkg.git "$VCPKG_DIR"
    cd "$VCPKG_DIR"
    ./bootstrap-vcpkg.sh
    log_success "vcpkg installed"
else
    log_success "vcpkg already exists at $VCPKG_DIR"
fi

# Step 2: Clone/check DuckDB
log_info "Step 2: Setting up DuckDB at $DUCKDB_DIR"
if [ ! -d "$DUCKDB_DIR" ]; then
    log_info "Cloning DuckDB..."
    git clone https://github.com/duckdb/duckdb.git "$DUCKDB_DIR"
    log_success "DuckDB cloned"
else
    log_success "DuckDB already exists at $DUCKDB_DIR"
fi

cd "$DUCKDB_DIR"

# Clean build if requested
if [ "$CLEAN_BUILD" = true ]; then
    log_info "Cleaning previous build artifacts..."
    rm -rf CMakeCache.txt CMakeFiles/ build*/ _deps/ duckdb duckdb_platform_* *.log \
        cmake_install.cmake DuckDB*.cmake DuckDBExports.cmake compile_commands.json \
        codegen/include/* codegen/src/*
    log_success "Build artifacts cleaned"
fi

# Step 3: Create extension configuration
log_info "Step 3: Creating extension configuration..."
mkdir -p extension
cat > extension/extension_config_local.cmake << 'EOF'
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
EOF
log_success "Extension configuration created"

# Step 4: Remove DONT_LINK flags and add INCLUDE_DIRs
log_info "Step 4: Patching extension configs..."
if [ -f .github/config/extensions/fts.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/fts.cmake
    sed -i '/GIT_TAG/a\        INCLUDE_DIR extension/fts/include' .github/config/extensions/fts.cmake
    log_success "FTS config patched"
fi
if [ -f .github/config/extensions/vss.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/vss.cmake
    log_success "VSS config patched"
fi
if [ -f .github/config/extensions/postgres_scanner.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/postgres_scanner.cmake
    sed -i '/GIT_TAG/a\            INCLUDE_DIR src/include' .github/config/extensions/postgres_scanner.cmake
    log_success "postgres_scanner config patched"
fi
if [ -f .github/config/extensions/mysql_scanner.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/mysql_scanner.cmake
    # Check if INCLUDE_DIR already exists
    if ! grep -q "INCLUDE_DIR" .github/config/extensions/mysql_scanner.cmake; then
        sed -i '/GIT_TAG/a\            INCLUDE_DIR src/include' .github/config/extensions/mysql_scanner.cmake
    fi
    log_success "mysql_scanner config patched"
fi

# Step 4b: Create mysql_scanner static build patch
log_info "Step 4b: Creating mysql_scanner static build patch..."
mkdir -p .github/patches/extensions/mysql_scanner
cat > .github/patches/extensions/mysql_scanner/static_build.patch << 'PATCHEOF'
diff --git a/CMakeLists.txt b/CMakeLists.txt
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -12,6 +12,9 @@ include_directories(${MYSQL_INCLUDE_DIR})
 
 add_subdirectory(src)
 
+# Static extension build
+build_static_extension(${TARGET_NAME} "" ${ALL_OBJECT_FILES})
+
 set(PARAMETERS "-no-warnings")
 build_loadable_extension(${TARGET_NAME} ${PARAMETERS} ${ALL_OBJECT_FILES})
 
@@ -19,3 +22,8 @@ build_loadable_extension(${TARGET_NAME} ${PARAMETERS} ${ALL_OBJECT_FILES})
 target_include_directories(${TARGET_NAME}_loadable_extension
                            PRIVATE include ${MYSQL_INCLUDE_DIR})
 target_link_libraries(${TARGET_NAME}_loadable_extension ${MYSQL_LIBRARIES})
+
+# Static binary
+target_include_directories(${TARGET_NAME}_extension
+                           PRIVATE include src/include ${MYSQL_INCLUDE_DIR})
+target_link_libraries(${TARGET_NAME}_extension ${MYSQL_LIBRARIES})
PATCHEOF
log_success "mysql_scanner static build patch created"

# Step 5: Install vcpkg dependencies
if [ "$SKIP_VCPKG" = false ]; then
    log_info "Step 5: Installing vcpkg dependencies (this takes 15-20 minutes)..."
    cd "$VCPKG_DIR"
    
    log_info "Installing AWS SDK (~5 min)..."
    ./vcpkg install aws-sdk-cpp[core,s3,transfer,config,sts,sso,identity-management]
    
    log_info "Installing Azure SDK (~3 min)..."
    ./vcpkg install azure-storage-blobs-cpp azure-storage-files-datalake-cpp azure-identity-cpp
    
    log_info "Installing Roaring..."
    ./vcpkg install roaring
    
    log_info "Installing libmariadb (for mysql_scanner)..."
    ./vcpkg install libmariadb
    
    log_success "vcpkg dependencies installed"
    cd "$DUCKDB_DIR"
else
    log_warning "Skipping vcpkg dependency installation (--skip-vcpkg)"
fi

# Step 6: Configure build
log_info "Step 6: Configuring CMake (fetches extensions)..."

# Create minimal vcpkg.json to avoid manifest mode issues
echo '{"name":"duckdb","version":"1.0.0"}' > vcpkg.json

# Note: --allow-multiple-definition is required because postgres_scanner and mysql_scanner
# share some common helper functions (EscapeConnectionString, GetSecret, CatalogTypeIsSupported)
cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_DIR/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_MANIFEST_MODE=OFF \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
  -DBUILD_EXTENSIONS="autocomplete;icu;tpcds;tpch;fts;json;parquet;sqlite_scanner;postgres_scanner;mysql_scanner;httpfs;excel;vss;inet;avro;aws;azure;iceberg;ducklake;delta;unity_catalog" \
  .
log_success "CMake configuration complete"

# Step 6b: Patch postgres_scanner CMakeLists.txt to enable static build
log_info "Step 6b: Patching postgres_scanner for static build..."
PG_CMAKE="_deps/postgres_scanner_extension_fc-src/CMakeLists.txt"
if [ -f "$PG_CMAKE" ]; then
    # Check if already patched
    if ! grep -q "build_static_extension" "$PG_CMAKE"; then
        # Patch using Python for reliable multi-line modifications
        python3 << 'PYEOF'
import re

with open("_deps/postgres_scanner_extension_fc-src/CMakeLists.txt", "r") as f:
    content = f.read()

# 1. Add build_static_extension before set(PARAMETERS)
static_build = '''# Static extension build (added by build script)
build_static_extension(${TARGET_NAME} "" ${ALL_OBJECT_FILES}
                       ${LIBPG_SOURCES_FULLPATH})

set(PARAMETERS "-no-warnings")'''
content = content.replace('set(PARAMETERS "-no-warnings")', static_build)

# 2. Add static extension target_include_directories after loadable one
old_includes = '''target_include_directories(
  ${TARGET_NAME}_loadable_extension
  PRIVATE include postgres/src/include postgres/src/backend
          postgres/src/interfaces/libpq ${OPENSSL_INCLUDE_DIR})'''

new_includes = old_includes + '''

target_include_directories(
  ${TARGET_NAME}_extension
  PRIVATE include src/include postgres/src/include postgres/src/backend
          postgres/src/interfaces/libpq ${OPENSSL_INCLUDE_DIR})'''
content = content.replace(old_includes, new_includes)

# 3. Add static extension target_link_libraries
content = content.replace(
    'target_link_libraries(${TARGET_NAME}_loadable_extension ${OPENSSL_LIBRARIES})',
    'target_link_libraries(${TARGET_NAME}_loadable_extension ${OPENSSL_LIBRARIES})\ntarget_link_libraries(${TARGET_NAME}_extension ${OPENSSL_LIBRARIES})'
)

# 4. Add static extension set_property
content = content.replace(
    'set_property(TARGET ${TARGET_NAME}_loadable_extension PROPERTY C_STANDARD 99)',
    'set_property(TARGET ${TARGET_NAME}_loadable_extension PROPERTY C_STANDARD 99)\nset_property(TARGET ${TARGET_NAME}_extension PROPERTY C_STANDARD 99)'
)

with open("_deps/postgres_scanner_extension_fc-src/CMakeLists.txt", "w") as f:
    f.write(content)

print("Patched successfully")
PYEOF
        log_success "postgres_scanner CMakeLists.txt patched for static build"
    else
        log_success "postgres_scanner already patched"
    fi
else
    log_warning "postgres_scanner CMakeLists.txt not found - will be patched on next run"
fi

# Step 6c: Patch delta CMakeLists.txt to use rustls instead of native-tls (OpenSSL)
log_info "Step 6c: Patching delta for rustls..."
DELTA_CMAKE="_deps/delta_extension_fc-src/CMakeLists.txt"
if [ -f "$DELTA_CMAKE" ]; then
    # Check if already patched
    if grep -q "all-features" "$DELTA_CMAKE"; then
        # Replace --all-features with specific rustls features to avoid OpenSSL linking issues
        sed -i 's/--package delta_kernel_ffi --workspace --profile=\${CARGO_PROFILE} --all-features/--package delta_kernel_ffi --profile=\${CARGO_PROFILE} --no-default-features --features "default-engine-rustls,tracing,test-ffi"/' "$DELTA_CMAKE"
        log_success "delta patched for rustls"
    else
        log_success "delta already patched"
    fi
else
    log_warning "delta CMakeLists.txt not found - will be patched on next run"
fi

# Reconfigure to pick up postgres_scanner CMakeLists changes
log_info "Reconfiguring after postgres_scanner patch..."
cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_DIR/scripts/buildsystems/vcpkg.cmake" \
  -DVCPKG_MANIFEST_MODE=OFF \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
  -DBUILD_EXTENSIONS="autocomplete;icu;tpcds;tpch;fts;json;parquet;sqlite_scanner;postgres_scanner;mysql_scanner;httpfs;excel;vss;inet;avro;aws;azure;iceberg;ducklake;delta;unity_catalog" \
  .
log_success "Reconfiguration complete"

# Step 7: Merge vcpkg dependencies
log_info "Step 7: Merging vcpkg dependencies..."
mkdir -p vcpkg_installed/x64-linux

# Copy from global vcpkg
if [ -d "$VCPKG_DIR/installed/x64-linux" ]; then
    log_info "Copying from global vcpkg..."
    cp -r "$VCPKG_DIR/installed/x64-linux"/* vcpkg_installed/x64-linux/ 2>/dev/null || true
fi

# Merge extension-specific vcpkg directories
log_info "Merging extension-specific vcpkg directories..."
for ext_dir in _deps/*_extension_fc-src; do
    if [ -d "$ext_dir/vcpkg_installed/x64-linux" ]; then
        ext_name=$(basename "$ext_dir" | sed 's/_extension_fc-src//')
        log_info "  Merging $ext_name..."
        cp -r "$ext_dir/vcpkg_installed/x64-linux"/* vcpkg_installed/x64-linux/ 2>/dev/null || true
    fi
done
log_success "vcpkg dependencies merged"

# Step 8: Build
log_info "Step 8: Building DuckDB (5-10 minutes)..."
NUM_CORES=$(nproc)
log_info "Building with $NUM_CORES cores..."
START_TIME=$(date +%s)
EXTENSION_STATIC_BUILD=1 make -j$NUM_CORES
END_TIME=$(date +%s)
BUILD_TIME=$((END_TIME - START_TIME))
log_success "Build completed in $BUILD_TIME seconds"

# Step 9: Verify
log_info "Step 9: Verifying build..."
if [ ! -f "./duckdb" ]; then
    log_error "Binary not found at ./duckdb"
    exit 1
fi

BINARY_SIZE=$(du -h ./duckdb | cut -f1)
log_success "Binary created: $BINARY_SIZE"

log_info "Checking extensions..."
EXTENSION_COUNT=$(./duckdb -c "SELECT COUNT(*) FROM duckdb_extensions() WHERE loaded=true;" 2>/dev/null | grep -o '[0-9]\+' | tail -1)

if [ "$EXTENSION_COUNT" = "24" ]; then
    log_success "All 24 extensions loaded successfully!"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}BUILD SUCCESSFUL${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Binary location: ${BLUE}$DUCKDB_DIR/duckdb${NC}"
    echo -e "Binary size: ${BLUE}$BINARY_SIZE${NC}"
    echo -e "Extensions: ${BLUE}23 statically linked${NC}"
    echo -e "Build time: ${BLUE}$BUILD_TIME seconds${NC}"
    echo ""
    echo "Extensions loaded:"
    ./duckdb -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded=true ORDER BY extension_name;" 2>/dev/null | \
        awk '/│/ && !/extension_name/ && !/varchar/ {gsub(/│/,""); gsub(/^ +| +$/,""); if (length($0) > 0) print "  - " $0}'
    echo ""
else
    log_warning "Expected 24 extensions, found $EXTENSION_COUNT"
    echo ""
    echo "Loaded extensions:"
    ./duckdb -c "SELECT extension_name, loaded FROM duckdb_extensions() WHERE installed=true ORDER BY extension_name;"
fi

echo ""
echo -e "${BLUE}To use DuckDB:${NC}"
echo -e "  cd $DUCKDB_DIR"
echo -e "  ./duckdb"
echo ""
