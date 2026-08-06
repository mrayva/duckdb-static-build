#!/bin/bash
set -euo pipefail

# DuckDB Static Build Script
# Builds DuckDB with the current validated built-in extension set
# Optionally adds the spatial extension
# Usage: ./build-duckdb-static.sh [options]
#   Options:
#     --vcpkg-dir DIR    Path to vcpkg installation (default: ~/vcpkg)
#     --duckdb-dir DIR   Path to DuckDB source (default: ~/duckdbsrc)
#     --skip-vcpkg       Skip vcpkg dependency installation
#     --clean            Clean build before starting
#     --with-spatial     Include spatial as a statically-linked extension
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
BUILD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_VCPKG=false
CLEAN_BUILD=false
WITH_SPATIAL=false
ICEBERG_SOURCE_DIR=${ICEBERG_SOURCE_DIR:-}
ICEBERG_FALLBACK_DIR=${ICEBERG_FALLBACK_DIR:-/tmp/duckdb-iceberg-src}

# Keep unavailable GitHub endpoints from blocking a build indefinitely. These
# settings apply both to the script's Git operations and to CMake FetchContent.
GIT_HTTP_CONNECT_TIMEOUT=${GIT_HTTP_CONNECT_TIMEOUT:-15}
GIT_HTTP_LOW_SPEED_LIMIT=${GIT_HTTP_LOW_SPEED_LIMIT:-1000}
GIT_HTTP_LOW_SPEED_TIME=${GIT_HTTP_LOW_SPEED_TIME:-30}
GIT_COMMAND_TIMEOUT=${GIT_COMMAND_TIMEOUT:-120}
CURL_CONNECT_TIMEOUT=${CURL_CONNECT_TIMEOUT:-15}
CURL_MAX_TIME=${CURL_MAX_TIME:-180}
CMAKE_CONFIGURE_TIMEOUT=${CMAKE_CONFIGURE_TIMEOUT:-1800}

git_network() {
    timeout --foreground "$GIT_COMMAND_TIMEOUT" git \
        -c "http.connectTimeout=$GIT_HTTP_CONNECT_TIMEOUT" \
        -c "http.lowSpeedLimit=$GIT_HTTP_LOW_SPEED_LIMIT" \
        -c "http.lowSpeedTime=$GIT_HTTP_LOW_SPEED_TIME" "$@"
}

export GIT_CONFIG_PARAMETERS="'http.connectTimeout=$GIT_HTTP_CONNECT_TIMEOUT' 'http.lowSpeedLimit=$GIT_HTTP_LOW_SPEED_LIMIT' 'http.lowSpeedTime=$GIT_HTTP_LOW_SPEED_TIME'"

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "$cmd not found. Please install it first."
        exit 1
    fi
}

ensure_include_after_git_tag() {
    local file="$1"
    local include_line="$2"
    if [ ! -f "$file" ]; then
        return 0
    fi
    if grep -Fq "$include_line" "$file"; then
        return 0
    fi
    sed -i "/^[[:space:]]*GIT_TAG[[:space:]]/a\\            $include_line" "$file"
}

sanitize_dirty_fetchcontent_deps() {
    local removed_any=false
    local dep_dir dep_base dep_prefix
    shopt -s nullglob
    for dep_dir in _deps/*_extension_fc-src _deps/*_extension-src; do
        [ -d "$dep_dir/.git" ] || continue
        if [ -n "$(git -C "$dep_dir" status --porcelain 2>/dev/null || true)" ]; then
            dep_base=$(basename "$dep_dir")
            dep_prefix="${dep_base%-src}"
            log_warning "Dirty FetchContent repo detected: $dep_dir"
            log_warning "Removing cached dependency checkout to avoid git stash/update conflicts"
            rm -rf "$dep_dir" "_deps/${dep_prefix}-build" "_deps/${dep_prefix}-subbuild"
            removed_any=true
        fi
    done
    shopt -u nullglob

    if [ "$removed_any" = true ]; then
        log_success "Removed dirty FetchContent dependency checkouts"
    fi
}

apply_patch_if_needed() {
    local repo_dir="$1"
    local patch_file="$2"
    local label="$3"

    if git -C "$repo_dir" apply --check "$patch_file" >/dev/null 2>&1; then
        git -C "$repo_dir" apply "$patch_file"
        log_success "$label applied"
        return 0
    fi

    if git -C "$repo_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
        log_success "$label already integrated upstream"
        return 0
    fi

    log_warning "$label no longer matches upstream tree; skipping"
    return 0
}

apply_patch_series_to_source_dir() {
    local source_dir="$1"
    local patch_dir="$2"
    local label="$3"
    local stamp_file="$source_dir/.duckdb_static_build_patch_series"
    local patch_fingerprint
    local patch_file
    local patches=()

    if [ ! -d "$patch_dir" ]; then
        log_error "$label patch directory not found at $patch_dir"
        exit 1
    fi

    while IFS= read -r patch_file; do
        patches+=("$patch_file")
    done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | sort)

    if [ ${#patches[@]} -eq 0 ]; then
        log_error "No patch files found for $label in $patch_dir"
        exit 1
    fi

    patch_fingerprint=$(cat "${patches[@]}" | sha256sum | awk '{print $1}')
    if [ -f "$stamp_file" ] && [ "$(cat "$stamp_file")" = "$patch_fingerprint" ]; then
        log_success "$label patch series already applied to $source_dir"
        return 0
    fi

    for patch_file in "${patches[@]}"; do
        if patch -d "$source_dir" -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
            patch -d "$source_dir" -p1 --forward < "$patch_file" >/dev/null
        elif patch -d "$source_dir" -R -p1 --dry-run < "$patch_file" >/dev/null 2>&1; then
            :
        else
            log_error "Failed to apply $label patch $(basename "$patch_file") to $source_dir"
            exit 1
        fi
    done

    echo "$patch_fingerprint" > "$stamp_file"
    log_success "$label patch series applied to $source_dir"
}

patch_series_matches_source_dir() {
    local source_dir="$1"
    local patch_dir="$2"
    local patch_file

    while IFS= read -r patch_file; do
        if patch -d "$source_dir" -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
            continue
        fi
        if patch -d "$source_dir" -R -p1 --dry-run < "$patch_file" >/dev/null 2>&1; then
            continue
        fi
        return 1
    done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | sort)

    return 0
}

ensure_local_archive_source() {
    local repo_slug="$1"
    local ref="$2"
    local source_dir="$3"
    local label="$4"
    local force_refresh="${5:-false}"
    local marker_file="$source_dir/.duckdb_static_build_ref"
    local archive_url="https://codeload.github.com/${repo_slug}/tar.gz/${ref}"
    local archive_path="/tmp/${label}-${ref}.tar.gz"
    local extract_dir
    local archive_listing
    local top_dir

    if [ "$force_refresh" != true ] && [ -d "$source_dir" ] && [ -f "$marker_file" ] && [ "$(cat "$marker_file")" = "$ref" ]; then
        log_success "Local source ready for $label at $source_dir"
        return 0
    fi

    extract_dir=$(mktemp -d "/tmp/${label}-extract.XXXXXX")

    if [ ! -f "$archive_path" ] || ! tar -tzf "$archive_path" >/dev/null 2>&1; then
        log_info "Downloading source archive for $label at $ref..."
        curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            --continue-at - --retry 5 --retry-all-errors --retry-delay 2 \
            --retry-max-time "$CURL_MAX_TIME" \
            "$archive_url" -o "$archive_path"
    else
        log_info "Reusing cached source archive for $label at $archive_path"
    fi

    archive_listing="$extract_dir/archive.list"
    tar -tzf "$archive_path" > "$archive_listing"
    top_dir=$(head -1 "$archive_listing" | cut -d/ -f1)
    if [ -z "$top_dir" ]; then
        log_error "Failed to inspect archive layout for $label"
        rm -rf "$extract_dir"
        exit 1
    fi

    tar -xzf "$archive_path" -C "$extract_dir"
    rm -rf "$source_dir"
    mkdir -p "$(dirname "$source_dir")"
    mv "$extract_dir/$top_dir" "$source_dir"
    echo "$ref" > "$marker_file"
    rm -rf "$extract_dir"

    log_success "Local source ready for $label at $source_dir"
}

use_iceberg_source_dir() {
    local source_dir="$1"
    local label="$2"

    if [ ! -d "$source_dir" ]; then
        log_error "$label source directory not found at $source_dir"
        exit 1
    fi

    cat > .github/config/extensions/iceberg.cmake <<EOF
# Windows tests for iceberg currently not working
IF (NOT WIN32)
    set(LOAD_ICEBERG_TESTS "LOAD_TESTS")
else ()
    set(LOAD_ICEBERG_TESTS "")
endif()
if (NOT MINGW)
    duckdb_extension_load(iceberg
            #FIXME: restore autoloading tests \${LOAD_ICEBERG_TESTS}
            SOURCE_DIR ${source_dir}
            )
endif()
EOF
    log_success "$label config patched to use SOURCE_DIR $source_dir"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --vcpkg-dir)
      if [[ $# -lt 2 ]]; then
        echo -e "${RED}[ERROR]${NC} --vcpkg-dir requires a value"
        exit 1
      fi
      VCPKG_DIR="$2"
      shift 2
      ;;
    --duckdb-dir)
      if [[ $# -lt 2 ]]; then
        echo -e "${RED}[ERROR]${NC} --duckdb-dir requires a value"
        exit 1
      fi
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
    --with-spatial)
      WITH_SPATIAL=true
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
for cmd in git cmake make sed awk nproc python3 curl tar patch timeout; do
    require_cmd "$cmd"
done
for cmd in gcc g++ cargo rustc; do
    require_cmd "$cmd"
done
if [ "$WITH_SPATIAL" = true ]; then
    require_cmd xxd
fi
log_success "All prerequisites found"

# Step 1: Install/check vcpkg
log_info "Step 1: Setting up vcpkg at $VCPKG_DIR"
if [ ! -d "$VCPKG_DIR" ]; then
    log_info "Cloning vcpkg..."
    git_network clone --depth 1 https://github.com/microsoft/vcpkg.git "$VCPKG_DIR"
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
    git_network clone --depth 1 https://github.com/duckdb/duckdb.git "$DUCKDB_DIR"
    log_success "DuckDB cloned"
else
    log_success "DuckDB already exists at $DUCKDB_DIR"
fi

cd "$DUCKDB_DIR"

# The upstream remote-optimizer test forks after the test runner may have
# initialized Spatial/PROJ's process-global SQLite state. Run its client and
# helper through clean exec'd processes so the test exercises plan transport,
# not inherited extension state.
apply_patch_if_needed "$DUCKDB_DIR" "$BUILD_SCRIPT_DIR/patches/remote-optimizer-exec.patch" \
    "remote optimizer exec isolation"

# Clean build if requested
if [ "$CLEAN_BUILD" = true ]; then
    log_info "Cleaning previous build artifacts..."
    rm -rf CMakeCache.txt CMakeFiles/ _deps/ duckdb duckdb_platform_* *.log \
        cmake_install.cmake DuckDB*.cmake DuckDBExports.cmake compile_commands.json \
        codegen/include/* codegen/src/*
    shopt -s nullglob
    for build_dir in build build-* build_*; do
        [ -e "$build_dir" ] || continue
        rm -rf "$build_dir"
    done
    shopt -u nullglob
    log_success "Build artifacts cleaned"
fi

# Step 3: Create extension configuration
log_info "Step 3: Creating extension configuration..."
mkdir -p extension
cat > extension/extension_config_local.cmake << EOF
duckdb_extension_load(autocomplete)
duckdb_extension_load(icu)
duckdb_extension_load(tpcds)
duckdb_extension_load(tpch)
duckdb_extension_load(fts)
duckdb_extension_load(json)
duckdb_extension_load(parquet)
duckdb_extension_load(sqlite_scanner)
duckdb_extension_load(postgres_scanner APPLY_PATCHES)
duckdb_extension_load(mysql_scanner APPLY_PATCHES)
duckdb_extension_load(httpfs)
duckdb_extension_load(excel)
duckdb_extension_load(vss)
duckdb_extension_load(inet)
duckdb_extension_load(avro)
duckdb_extension_load(aws)
duckdb_extension_load(azure)
duckdb_extension_load(iceberg)
duckdb_extension_load(ducklake)
duckdb_extension_load(delta APPLY_PATCHES)
duckdb_extension_load(unity_catalog)
EOF
if [ "$WITH_SPATIAL" = true ]; then
    echo "duckdb_extension_load(spatial APPLY_PATCHES)" >> extension/extension_config_local.cmake
fi
log_success "Extension configuration created"

# Step 4: Remove DONT_LINK flags and add INCLUDE_DIRs
log_info "Step 4: Patching extension configs..."
if [ -f .github/config/extensions/fts.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/fts.cmake
    sed -i '/INCLUDE_DIR extension\/fts\/include/d' .github/config/extensions/fts.cmake
    log_success "FTS config patched"
fi
if [ -f .github/config/extensions/vss.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/vss.cmake
    log_success "VSS config patched"
fi
if [ -f .github/config/extensions/postgres_scanner.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/postgres_scanner.cmake
    ensure_include_after_git_tag .github/config/extensions/postgres_scanner.cmake "INCLUDE_DIR src/include"
    ensure_include_after_git_tag .github/config/extensions/postgres_scanner.cmake "APPLY_PATCHES"
    log_success "postgres_scanner config patched"
fi
if [ -f .github/config/extensions/mysql_scanner.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/mysql_scanner.cmake
    sed -i '/^[[:space:]]*INCLUDE_DIR src\/include$/d' .github/config/extensions/mysql_scanner.cmake
    sed -i 's/set(MYSQL_SCANNER_ENABLED OFF)/set(MYSQL_SCANNER_ENABLED ON)/' \
        .github/config/extensions/mysql_scanner.cmake
    ensure_include_after_git_tag .github/config/extensions/mysql_scanner.cmake "INCLUDE_DIR src/include"
    ensure_include_after_git_tag .github/config/extensions/mysql_scanner.cmake "APPLY_PATCHES"
    log_success "mysql_scanner config patched"
fi
if [ -f .github/config/extensions/iceberg.cmake ]; then
    ICEBERG_PATCH_DIR="$DUCKDB_DIR/.github/patches/extensions/iceberg"
    mkdir -p "$ICEBERG_PATCH_DIR"
    cp "$BUILD_SCRIPT_DIR/patches/iceberg-current-duckdb.patch" "$ICEBERG_PATCH_DIR/fix.patch"
    log_success "Synchronized Iceberg compatibility patch"
    ICEBERG_REFRESH_REF=""
    CURRENT_ICEBERG_SOURCE_DIR=$(awk '/SOURCE_DIR/ {print $2; exit}' .github/config/extensions/iceberg.cmake)
    ICEBERG_GIT_TAG=$(awk '/GIT_TAG/ {print $2; exit}' .github/config/extensions/iceberg.cmake)
    if [ -n "$ICEBERG_GIT_TAG" ]; then
        ICEBERG_REFRESH_REF="$ICEBERG_GIT_TAG"
    elif [ -f "$ICEBERG_FALLBACK_DIR/.duckdb_static_build_ref" ]; then
        ICEBERG_REFRESH_REF=$(cat "$ICEBERG_FALLBACK_DIR/.duckdb_static_build_ref")
    fi
    if [ -n "$ICEBERG_SOURCE_DIR" ]; then
        apply_patch_series_to_source_dir "$ICEBERG_SOURCE_DIR" "$ICEBERG_PATCH_DIR" "duckdb-iceberg"
        use_iceberg_source_dir "$ICEBERG_SOURCE_DIR" "duckdb-iceberg"
    elif [ -n "$CURRENT_ICEBERG_SOURCE_DIR" ]; then
        if [ "$CURRENT_ICEBERG_SOURCE_DIR" = "$ICEBERG_FALLBACK_DIR" ] && ! patch_series_matches_source_dir "$CURRENT_ICEBERG_SOURCE_DIR" "$ICEBERG_PATCH_DIR"; then
            log_warning "duckdb-iceberg fallback source is stale or partially patched; refreshing from archive"
            if [ -z "$ICEBERG_REFRESH_REF" ]; then
                log_error "Could not determine iceberg ref needed to refresh fallback SOURCE_DIR $CURRENT_ICEBERG_SOURCE_DIR"
                exit 1
            fi
            ensure_local_archive_source "duckdb/duckdb-iceberg" "$ICEBERG_REFRESH_REF" "$CURRENT_ICEBERG_SOURCE_DIR" "duckdb-iceberg" true
        fi
        apply_patch_series_to_source_dir "$CURRENT_ICEBERG_SOURCE_DIR" "$ICEBERG_PATCH_DIR" "duckdb-iceberg"
        use_iceberg_source_dir "$CURRENT_ICEBERG_SOURCE_DIR" "duckdb-iceberg"
    else
        if [ -z "$ICEBERG_REFRESH_REF" ]; then
            log_error "Could not determine iceberg GIT_TAG or SOURCE_DIR from .github/config/extensions/iceberg.cmake"
            exit 1
        fi
        ensure_local_archive_source "duckdb/duckdb-iceberg" "$ICEBERG_REFRESH_REF" "$ICEBERG_FALLBACK_DIR" "duckdb-iceberg"
        if ! patch_series_matches_source_dir "$ICEBERG_FALLBACK_DIR" "$ICEBERG_PATCH_DIR"; then
            log_warning "duckdb-iceberg fallback source is stale or partially patched; refreshing from archive"
            ensure_local_archive_source "duckdb/duckdb-iceberg" "$ICEBERG_REFRESH_REF" "$ICEBERG_FALLBACK_DIR" "duckdb-iceberg" true
        fi
        apply_patch_series_to_source_dir "$ICEBERG_FALLBACK_DIR" "$ICEBERG_PATCH_DIR" "duckdb-iceberg"
        use_iceberg_source_dir "$ICEBERG_FALLBACK_DIR" "duckdb-iceberg"
    fi
fi
if [ "$WITH_SPATIAL" = true ] && [ -f .github/config/extensions/spatial.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/spatial.cmake
    mkdir -p .github/patches/extensions/spatial
    cp "$BUILD_SCRIPT_DIR/patches/spatial-current-duckdb.patch" \
       .github/patches/extensions/spatial/gdal-tip-compat.patch
    log_success "spatial config patched"
fi
# Step 4b: Create extension patch files
log_info "Step 4b: Creating extension patch files..."

mkdir -p .github/patches/extensions/postgres_scanner
cat > .github/patches/extensions/postgres_scanner/static_build.patch << 'PATCH_EOF'
diff --git a/CMakeLists.txt b/CMakeLists.txt
index b30ca04..e465362 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -49,20 +49,28 @@ if(NOT WIN32 AND NOT APPLE)
         "-Wl,-Bsymbolic"
     )
 endif()

 target_link_libraries(${LOADABLE_EXTENSION_NAME}
     OpenSSL::SSL
     OpenSSL::Crypto
     PostgreSQL::PostgreSQL
     ${CURL_LIBRARIES})
 set_property(TARGET ${EXTENSION_NAME} PROPERTY C_STANDARD 99)
+target_include_directories(
+    ${EXTENSION_NAME}
+    PRIVATE include database-connector/src/include ${OPENSSL_INCLUDE_DIR}
+            ${PostgreSQL_INCLUDE_DIRS})
+target_link_libraries(${EXTENSION_NAME}
+    OpenSSL::SSL
+    OpenSSL::Crypto
+    PostgreSQL::PostgreSQL)
 set_property(TARGET ${LOADABLE_EXTENSION_NAME} PROPERTY C_STANDARD 99)

 if(WIN32)
   target_link_libraries(${LOADABLE_EXTENSION_NAME}
       wsock32
       ws2_32
       wldap32
       secur32
       crypt32)
 endif()
PATCH_EOF

cat > .github/patches/extensions/postgres_scanner/oauth_hook_compat.patch << 'PATCH_EOF'
diff --git a/CMakeLists.txt b/CMakeLists.txt
index b30ca04..5edb9b2 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -3,29 +3,38 @@ set(TARGET_NAME postgres_scanner)
 project(${TARGET_NAME})

 add_definitions(
     -DFRONTEND=1
     -D_GNU_SOURCE=1
     -DUSE_OPENSSL=1
     -DHAVE_BIO_GET_DATA=1
     -DHAVE_BIO_METH_NEW=1)

 find_package(OpenSSL REQUIRED)
+include(CheckSymbolExists)
 find_package(PostgreSQL REQUIRED)

 if(NOT MSVC)
     add_compile_options(
         -Wno-pedantic
         -Wno-sign-compare
         -Wno-unused-variable)
 endif()

+set(CMAKE_REQUIRED_INCLUDES ${PostgreSQL_INCLUDE_DIRS})
+check_symbol_exists(PQsetAuthDataHook "libpq-fe.h" HAVE_PQ_AUTH_DATA_HOOK)
+unset(CMAKE_REQUIRED_INCLUDES)
+
+if(HAVE_PQ_AUTH_DATA_HOOK)
+    add_compile_definitions(HAVE_PQ_AUTH_DATA_HOOK=1)
+endif()
+
 include_directories(
     include
     database-connector/src/include
     ${OPENSSL_INCLUDE_DIR}
     ${PostgreSQL_INCLUDE_DIRS})

 if(WIN32)
   include_directories(
       vcpkg_ports/libpq/include/port/win32
       vcpkg_ports/libpq/include/port/win32_msvc)
diff --git a/src/postgres_oauth.cpp b/src/postgres_oauth.cpp
index a9cc073..5e50add 100644
--- a/src/postgres_oauth.cpp
+++ b/src/postgres_oauth.cpp
@@ -3,20 +3,22 @@

 #include <cstdlib>
 #include <cstring>
 #include <mutex>
 #include <string>

 extern "C" {
 #include "libpq-fe.h"
 }

+#ifdef HAVE_PQ_AUTH_DATA_HOOK
+
 namespace duckdb {

 //! Previous hook in the chain (if any)
 static PQauthDataHook_type prev_hook = nullptr;

 struct OAuthTokenState {
 	char *token_copy;
 };

 //! Managed by SetThreadLocalOAuthTokenFromSessionOption
@@ -101,10 +103,24 @@ void PostgresInitOAuthHook() {
 OAuthTokenHolder SetThreadLocalOAuthTokenFromSessionOption(ClientContext &ctx) {
 	Value val;
 	if (ctx.TryGetCurrentSetting("pg_oauth_token", val) && !val.IsNull()) {
 		std::string token = StringValue::Get(val);
 		oauth_token = std::string(token.data(), token.length());
 	}
 	return OAuthTokenHolder();
 }

 } // namespace duckdb
+
+#else
+
+namespace duckdb {
+
+OAuthTokenHolder::~OAuthTokenHolder() {
+}
+
+void PostgresInitOAuthHook() {
+}
+
+OAuthTokenHolder SetThreadLocalOAuthTokenFromSessionOption(ClientContext &) { return OAuthTokenHolder(); }
+} // namespace duckdb
+#endif
PATCH_EOF

mkdir -p .github/patches/extensions/delta
mkdir -p .github/patches/extensions/mysql_scanner
mkdir -p .github/patches/extensions/avro
mkdir -p .github/vcpkg_ports/avro-c
cat > .github/vcpkg_ports/avro-c/vcpkg.json << 'EOF'
{
  "name": "avro-c",
  "version": "1.12.1",
  "description": "DuckDB-compatible Apache Avro C library",
  "homepage": "https://github.com/duckdb/duckdb-avro-c",
  "license": "Apache-2.0",
  "dependencies": [
    "jansson",
    "liblzma",
    "snappy",
    "vcpkg-cmake",
    "zlib"
  ]
}
EOF
cat > .github/vcpkg_ports/avro-c/portfile.cmake << 'EOF'
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO duckdb/duckdb-avro-c
    REF 52bafc6a90fb6176b9b85ab2489ee5e49a5f208c
    SHA512 1e9527b95023e0c92fc8844cdb8357d256e3cf92abb63a10adb57536722cf7a7eb314aac99555373d84995e7d96fddf7475f420ca9e0fe79f713c1e6daa9334a
)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}/lang/c"
    OPTIONS
        -DBUILD_EXAMPLES=OFF
        -DBUILD_TESTS=OFF
        -DBUILD_DOCS=OFF
)
vcpkg_cmake_install()
vcpkg_copy_pdbs()
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/lib/pkgconfig" "${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig")
vcpkg_copy_tools(TOOL_NAMES avroappend avrocat avropipe avromod AUTO_CLEAN)
if(VCPKG_LIBRARY_LINKAGE STREQUAL "static" AND NOT VCPKG_TARGET_IS_WINDOWS)
    file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/bin" "${CURRENT_PACKAGES_DIR}/debug/bin")
endif()
file(INSTALL "${SOURCE_PATH}/lang/c/LICENSE" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}" RENAME copyright)
EOF
if [ -f .github/patches/extensions/avro/0004-logical-type-compat.patch ]; then
    rm -f .github/patches/extensions/avro/logical_type_compat.patch
    log_success "avro logical-type compat already present upstream"
else
cat > .github/patches/extensions/avro/logical_type_compat.patch << 'PATCH_EOF'
diff --git a/CMakeLists.txt b/CMakeLists.txt
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -32,7 +32,10 @@
 # Get avro-c include directory
 set(AVRO_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/avro-c/lang/c/src")

+# Vendored avro-c submodule always provides avro_schema_logical_type/scale/precision/adjust_to_utc
+add_compile_definitions(HAVE_AVRO_SCHEMA_LOGICAL_TYPE=1)
+
 # Disable all UBSan checks for avro-static to work around multiple UB issues in avro-c
 if(TARGET avro-static AND NOT MSVC)
   target_compile_options(avro-static PRIVATE -fno-sanitize=undefined)
 endif()
diff --git a/src/avro_reader.cpp b/src/avro_reader.cpp
--- a/src/avro_reader.cpp
+++ b/src/avro_reader.cpp
@@ -19,8 +19,42 @@
 
 namespace duckdb {
 
+#ifdef HAVE_AVRO_SCHEMA_LOGICAL_TYPE
+static const char *GetAvroLogicalType(avro_schema_t &avro_schema) {
+	return avro_schema_logical_type(avro_schema);
+}
+
+static int32_t GetAvroSchemaScale(avro_schema_t &avro_schema) {
+	return avro_schema_scale(avro_schema);
+}
+
+static int32_t GetAvroSchemaPrecision(avro_schema_t &avro_schema) {
+	return avro_schema_precision(avro_schema);
+}
+
+static int GetAvroSchemaAdjustToUTC(avro_schema_t &avro_schema) {
+	return avro_schema_adjust_to_utc(avro_schema);
+}
+#else
+static const char *GetAvroLogicalType(avro_schema_t &) {
+	return nullptr;
+}
+
+static int32_t GetAvroSchemaScale(avro_schema_t &) {
+	return 0;
+}
+
+static int32_t GetAvroSchemaPrecision(avro_schema_t &) {
+	return 0;
+}
+
+static int GetAvroSchemaAdjustToUTC(avro_schema_t &) {
+	return 0;
+}
+#endif
+
 static LogicalType AvroLogicalTypeToLogicalType(avro_schema_t &avro_schema) {
-	auto logical_type_raw = avro_schema_logical_type(avro_schema);
+	auto logical_type_raw = GetAvroLogicalType(avro_schema);
 	if (!logical_type_raw) {
 		return LogicalType::INVALID;
 	}
@@ -39,15 +73,15 @@ static LogicalType AvroLogicalTypeToLogicalType(avro_schema_t &avro_schema) {
 		return LogicalType::DATE;
 	}
 	if (logical_type == "decimal") {
-		auto scale = avro_schema_scale(avro_schema);
-		auto precision = avro_schema_precision(avro_schema);
+		auto scale = GetAvroSchemaScale(avro_schema);
+		auto precision = GetAvroSchemaPrecision(avro_schema);
 		return LogicalType::DECIMAL(precision, scale);
 	}
 	if (logical_type == "time-micros") {
 		return LogicalType::TIME;
 	}
 	if (logical_type == "timestamp-micros") {
-		auto adjust_to_utc = avro_schema_adjust_to_utc(avro_schema);
+		auto adjust_to_utc = GetAvroSchemaAdjustToUTC(avro_schema);
 		// -1 doesn't exist
 		if (adjust_to_utc > 0) {
 			return LogicalType::TIMESTAMP_TZ;
@@ -55,7 +89,7 @@ static LogicalType AvroLogicalTypeToLogicalType(avro_schema_t &avro_schema) {
 		return LogicalType::TIMESTAMP;
 	}
 	if (logical_type == "timestamp-nanos") {
-		auto adjust_to_utc = avro_schema_adjust_to_utc(avro_schema);
+		auto adjust_to_utc = GetAvroSchemaAdjustToUTC(avro_schema);
 		if (adjust_to_utc > 0) {
 			throw NotImplementedException("Avro timestamp-nanos with adjust_to_utc not supported");
 		}
@@ -72,7 +106,7 @@ static LogicalType AvroLogicalTypeToLogicalType(avro_schema_t &avro_schema) {
 		return LogicalType::TIME;
 	}
 	if (logical_type == "timestamp-millis") {
-		auto adjust_to_utc = avro_schema_adjust_to_utc(avro_schema);
+		auto adjust_to_utc = GetAvroSchemaAdjustToUTC(avro_schema);
 		if (adjust_to_utc > 0) {
 			return LogicalType::TIMESTAMP_TZ;
 		}
@@ -88,7 +122,7 @@ static AvroType TransformSchema(avro_schema_t &avro_schema, unordered_set<string
 	auto duckdb_logical_type = AvroLogicalTypeToLogicalType(avro_schema);
 	bool has_logical_type = duckdb_logical_type != LogicalType::INVALID;
 
-	auto raw_lt = avro_schema_logical_type(avro_schema);
+	auto raw_lt = GetAvroLogicalType(avro_schema);
	bool is_millis = raw_lt && (string(raw_lt) == "timestamp-millis" || string(raw_lt) == "time-millis" ||
	                            string(raw_lt) == "local-timestamp-millis");

PATCH_EOF
fi

cat > .github/patches/extensions/mysql_scanner/static_build.patch << 'PATCH_EOF'
diff --git a/CMakeLists.txt b/CMakeLists.txt
index 02a6321..cd06b8a 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -6,17 +6,25 @@ set(libmariadb_DIR ${CMAKE_CURRENT_LIST_DIR}/vcpkg_ports/libmariadb)
 find_package(libmariadb REQUIRED)
 set(EXTENSION_NAME ${TARGET_NAME}_extension)

 set(MYSQL_INCLUDE_DIR
     ${CMAKE_BINARY_DIR}/vcpkg_installed/${VCPKG_TARGET_TRIPLET}/include/mysql)
 include_directories(${MYSQL_INCLUDE_DIR})
 include_directories(database-connector/src/include)

 add_subdirectory(src)

+# Static extension build (added by build script)
+build_static_extension(${TARGET_NAME} "" ${ALL_OBJECT_FILES})
+
 set(PARAMETERS "-no-warnings")
 build_loadable_extension(${TARGET_NAME} ${PARAMETERS} ${ALL_OBJECT_FILES})

 # Loadable binary
 target_include_directories(${TARGET_NAME}_loadable_extension
                            PRIVATE include ${MYSQL_INCLUDE_DIR})
 target_link_libraries(${TARGET_NAME}_loadable_extension ${MYSQL_LIBRARIES})
+
+# Static binary includes/libs (added by build script)
+target_include_directories(${TARGET_NAME}_extension
+                           PRIVATE include src/include ${MYSQL_INCLUDE_DIR})
+target_link_libraries(${TARGET_NAME}_extension ${MYSQL_LIBRARIES})
PATCH_EOF

rm -f .github/patches/extensions/delta/rustls.patch
cp "$BUILD_SCRIPT_DIR/patches/delta-kernel-cmake-profile.patch" \
   .github/patches/extensions/delta/cmake-profile.patch

log_success "Extension patch files created"

# Step 5: Install vcpkg dependencies
if [ "$SKIP_VCPKG" = false ]; then
    log_info "Step 5: Installing vcpkg dependencies (this takes 15-20 minutes)..."
    cd "$VCPKG_DIR"
    
    log_info "Installing AWS SDK (~5 min)..."
    ./vcpkg install --recurse aws-crt-cpp
    ./vcpkg install --recurse aws-sdk-cpp[core,s3,transfer,config,sts,sso,identity-management,rds,redshift,cloudformation]
    
    log_info "Installing Azure SDK (~3 min)..."
    ./vcpkg install azure-storage-blobs-cpp azure-storage-files-datalake-cpp azure-identity-cpp
    
    log_info "Installing Roaring..."
    ./vcpkg install roaring

    log_info "Installing DuckDB-compatible Avro C library..."
    ./vcpkg remove avro-c:x64-linux >/dev/null 2>&1 || true
    ./vcpkg install --overlay-ports="$DUCKDB_DIR/.github/vcpkg_ports" avro-c:x64-linux
    
    log_info "Installing libmariadb (for mysql_scanner)..."
    ./vcpkg install libmariadb

    if [ "$WITH_SPATIAL" = true ]; then
        log_info "Installing spatial dependencies (GDAL/PROJ/GEOS/SQLite)..."
        ./vcpkg install gdal[geos] proj geos expat sqlite3[rtree] curl openssl zlib
    fi
    log_success "vcpkg dependencies installed"
    cd "$DUCKDB_DIR"
else
    log_warning "Skipping vcpkg dependency installation (--skip-vcpkg)"
fi

# Step 6: Configure build
log_info "Step 6: Configuring CMake (fetches extensions)..."
BUILD_DIR="$DUCKDB_DIR/build/release-static"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
sanitize_dirty_fetchcontent_deps
cd "$DUCKDB_DIR"

# Create minimal vcpkg.json to avoid manifest mode issues
echo '{"name":"duckdb","version":"1.0.0"}' > vcpkg.json

BUILD_EXTENSIONS="autocomplete;icu;tpcds;tpch;fts;json;parquet;sqlite_scanner;postgres_scanner;mysql_scanner;httpfs;excel;vss;inet;avro;aws;azure;iceberg;ducklake;delta;unity_catalog"
EXPECTED_EXTENSIONS=23
if [ "$WITH_SPATIAL" = true ]; then
    BUILD_EXTENSIONS="${BUILD_EXTENSIONS};spatial"
    EXPECTED_EXTENSIONS=$((EXPECTED_EXTENSIONS + 1))
fi
# Note: --allow-multiple-definition is required because postgres_scanner
# shares some common helper functions with other static extensions.
timeout --foreground "$CMAKE_CONFIGURE_TIMEOUT" cmake -S "$DUCKDB_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_DIR/scripts/buildsystems/vcpkg.cmake" \
  -DCMAKE_C_COMPILER_LAUNCHER= \
  -DCMAKE_CXX_COMPILER_LAUNCHER= \
  -DVCPKG_BUILD=1 \
  -DVCPKG_MANIFEST_MODE=OFF \
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
  -DBUILD_EXTENSIONS="$BUILD_EXTENSIONS" \
  .
log_success "CMake configuration complete"

cd "$BUILD_DIR"

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
shopt -s nullglob
for ext_dir in _deps/*_extension_fc-src _deps/*_extension-src; do
    if [ -d "$ext_dir/vcpkg_installed/x64-linux" ]; then
        ext_name=$(basename "$ext_dir" | sed 's/_extension_fc-src//' | sed 's/_extension-src//')
        log_info "  Merging $ext_name..."
        cp -r "$ext_dir/vcpkg_installed/x64-linux"/* vcpkg_installed/x64-linux/ 2>/dev/null || true
    fi
done
shopt -u nullglob
log_success "vcpkg dependencies merged"

if [ "$WITH_SPATIAL" = true ]; then
    SPATIAL_PROJ_DB="$VCPKG_DIR/installed/x64-linux/share/proj/proj.db"
    SPATIAL_PROJ_DIR="$BUILD_DIR/_deps/spatial_extension_fc-src/src/spatial/modules/proj"
    SPATIAL_PROJ_MODULE="$SPATIAL_PROJ_DIR/proj_module.cpp"
    if [ ! -f "$SPATIAL_PROJ_DB" ]; then
        log_error "Spatial requested, but $SPATIAL_PROJ_DB was not found"
        log_error "Install spatial dependencies first or rerun without --skip-vcpkg"
        exit 1
    fi
    if [ ! -d "$SPATIAL_PROJ_DIR" ]; then
        log_error "Spatial source directory not found at $SPATIAL_PROJ_DIR"
        exit 1
    fi
    if [ ! -f "$SPATIAL_PROJ_MODULE" ]; then
        log_error "Spatial PROJ module not found at $SPATIAL_PROJ_MODULE"
        exit 1
    fi

    log_info "Patching spatial memvfs sqlite URI open flags..."
    sed -i 's/SQLITE_OPEN_READONLY, "memvfs"/SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, "memvfs"/' "$SPATIAL_PROJ_MODULE"
    log_success "Spatial memvfs open flags patched"

    log_info "Regenerating spatial embedded proj_db.c from vcpkg PROJ database..."
    cp "$SPATIAL_PROJ_DB" "$SPATIAL_PROJ_DIR/proj.db"
    (cd "$SPATIAL_PROJ_DIR" && xxd -i proj.db > proj_db.c && rm -f proj.db)
    log_success "Spatial proj_db.c regenerated"
fi

# Step 8: Build
log_info "Step 8: Building DuckDB (5-10 minutes)..."
NUM_CORES=$(nproc)
log_info "Building with $NUM_CORES cores..."
START_TIME=$(date +%s)
EXTENSION_STATIC_BUILD=1 make -j"$NUM_CORES"
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

if [ "$EXTENSION_COUNT" = "$EXPECTED_EXTENSIONS" ]; then
    log_success "All $EXPECTED_EXTENSIONS extensions loaded successfully!"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}BUILD SUCCESSFUL${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Binary location: ${BLUE}$BUILD_DIR/duckdb${NC}"
    echo -e "Binary size: ${BLUE}$BINARY_SIZE${NC}"
    echo -e "Extensions: ${BLUE}$EXPECTED_EXTENSIONS statically linked${NC}"
    echo -e "Build time: ${BLUE}$BUILD_TIME seconds${NC}"
    echo ""
    echo "Extensions loaded:"
    ./duckdb -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded=true ORDER BY extension_name;" 2>/dev/null | \
        awk '/│/ && !/extension_name/ && !/varchar/ {gsub(/│/,""); gsub(/^ +| +$/,""); if (length($0) > 0) print "  - " $0}'
    echo ""
else
    log_warning "Expected $EXPECTED_EXTENSIONS extensions, found $EXTENSION_COUNT"
    echo ""
    echo "Loaded extensions:"
    ./duckdb -c "SELECT extension_name, loaded FROM duckdb_extensions() WHERE installed=true ORDER BY extension_name;"
fi

echo ""
echo -e "${BLUE}To use DuckDB:${NC}"
echo -e "  cd $BUILD_DIR"
echo -e "  ./duckdb"
echo ""
