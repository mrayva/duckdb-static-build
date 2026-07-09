#!/bin/bash
set -euo pipefail

# DuckDB Static Build Script
# Builds DuckDB with the current validated built-in extension set
# Optionally adds the spatial extension
# Optionally builds ila/openivm as a regular loadable extension
# Usage: ./build-duckdb-static.sh [options]
#   Options:
#     --vcpkg-dir DIR    Path to vcpkg installation (default: ~/vcpkg)
#     --duckdb-dir DIR   Path to DuckDB source (default: ~/duckdbsrc)
#     --skip-vcpkg       Skip vcpkg dependency installation
#     --clean            Clean build before starting
#     --with-spatial     Include spatial as a statically-linked extension
#     --with-openivm-loadable Build ila/openivm as a regular loadable extension, not statically linked
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
WITH_OPENIVM_LOADABLE=false
WITH_ROBUST_RPT=false
WITH_AGGJOIN=false
COPY_TESTS=false
ROBUST_BISECT_MINIMAL_EXTENSIONS=false
ROBUST_PATCH_CURRENT_COMPAT=false
ROBUST_PATCH_EXCEPTION_SAFE_CLEANUP=false
ROBUST_PATCH_PROBE_EMPTY_REGISTRY_CLEANUP=false
ROBUST_PATCH_SKIP_COPY_OPTIMIZATION=false
ROBUST_LOCAL_DIR=${ROBUST_LOCAL_DIR:-/tmp/robust-labs-robust}
ICEBERG_SOURCE_DIR=${ICEBERG_SOURCE_DIR:-}
ICEBERG_FALLBACK_DIR=${ICEBERG_FALLBACK_DIR:-/tmp/duckdb-iceberg-src}

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
    sed -i "/GIT_TAG/a\\            $include_line" "$file"
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
    local archive_url="https://github.com/${repo_slug}/archive/${ref}.tar.gz"
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
        rm -f "$archive_path"
        log_info "Downloading source archive for $label at $ref..."
        curl -fsSL --retry 3 --retry-delay 2 "$archive_url" -o "$archive_path"
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
    rm -f "$archive_path"

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
    --with-openivm-loadable)
      WITH_OPENIVM_LOADABLE=true
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
for cmd in git cmake make sed awk nproc python3 curl tar patch; do
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
if [ "$ROBUST_BISECT_MINIMAL_EXTENSIONS" = true ]; then
    cat > extension/extension_config_local.cmake << EOF
duckdb_extension_load(autocomplete)
duckdb_extension_load(icu)
duckdb_extension_load(tpcds)
duckdb_extension_load(tpch)
duckdb_extension_load(json)
duckdb_extension_load(parquet)
EOF
else
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
fi
if [ "$WITH_SPATIAL" = true ]; then
    echo "duckdb_extension_load(spatial APPLY_PATCHES)" >> extension/extension_config_local.cmake
fi
if [ "$WITH_ROBUST_RPT" = true ] && [ "$ROBUST_PATCH_CURRENT_COMPAT" = true ]; then
    cat >> extension/extension_config_local.cmake << EOF
duckdb_extension_load(robust
    GIT_URL https://github.com/robust-labs/robust
    GIT_TAG 0827cfa87e2a1ac52d0e8eba7fd6af9d0e84b3d8
    APPLY_PATCHES
)
EOF
fi
if [ "$WITH_AGGJOIN" = true ]; then
    cat >> extension/extension_config_local.cmake << EOF
duckdb_extension_load(aggjoin
    GIT_URL https://github.com/arselzer/duckdb_aggjoin
    GIT_TAG f7259a9255ecda3dee8402714048799e6900c72c
    APPLY_PATCHES
)
EOF
fi
log_success "Extension configuration created"

# Step 4: Remove DONT_LINK flags and add INCLUDE_DIRs
log_info "Step 4: Patching extension configs..."
if [ -f .github/config/extensions/fts.cmake ]; then
    sed -i '/DONT_LINK/d' .github/config/extensions/fts.cmake
    if ! grep -Fq "INCLUDE_DIR extension/fts/include" .github/config/extensions/fts.cmake; then
        sed -i '/GIT_TAG/a\        INCLUDE_DIR extension/fts/include' .github/config/extensions/fts.cmake
    fi
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
    ensure_include_after_git_tag .github/config/extensions/mysql_scanner.cmake "INCLUDE_DIR src/include"
    ensure_include_after_git_tag .github/config/extensions/mysql_scanner.cmake "APPLY_PATCHES"
    log_success "mysql_scanner config patched"
fi
if [ -f .github/config/extensions/iceberg.cmake ]; then
    ICEBERG_PATCH_DIR="$DUCKDB_DIR/.github/patches/extensions/iceberg"
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
    log_success "spatial config patched"
fi
if [ "$WITH_ROBUST_RPT" = true ]; then
    mkdir -p .github/config/extensions
    cat > .github/config/extensions/robust.cmake << 'EOF'
duckdb_extension_load(robust
    GIT_URL ROBUST_GIT_URL_PLACEHOLDER
    GIT_TAG 0827cfa87e2a1ac52d0e8eba7fd6af9d0e84b3d8
    APPLY_PATCHES
)
EOF
    sed -i "s|ROBUST_GIT_URL_PLACEHOLDER|file://${ROBUST_LOCAL_DIR}|" .github/config/extensions/robust.cmake
    log_success "robust RPT config created"
fi
if [ "$WITH_AGGJOIN" = true ]; then
    mkdir -p .github/config/extensions
    cat > .github/config/extensions/aggjoin.cmake << 'EOF'
duckdb_extension_load(aggjoin
    GIT_URL https://github.com/arselzer/duckdb_aggjoin
    GIT_TAG f7259a9255ecda3dee8402714048799e6900c72c
    APPLY_PATCHES
)
EOF
    log_success "aggjoin config created"
fi
if [ "$WITH_OPENIVM_LOADABLE" = true ]; then
    mkdir -p .github/config/extensions
    cat > .github/config/extensions/openivm.cmake << 'EOF'
duckdb_extension_load(openivm
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/build/openivm-local-src
)
EOF
    perl -0pi -e 's/SOURCE_DIR \$\{CMAKE_CURRENT_SOURCE_DIR\}\/build\/openivm-local-src\n\)/SOURCE_DIR \$\{CMAKE_CURRENT_SOURCE_DIR\}\/build\/openivm-local-src\n    DONT_LINK\n)/' .github/config/extensions/openivm.cmake
    log_success "openivm config created"
fi

# Step 4b: Create extension patch files
log_info "Step 4b: Creating extension patch files..."

mkdir -p .github/patches/extensions/postgres_scanner
cat > .github/patches/extensions/postgres_scanner/static_build.patch << 'PATCH_EOF'
diff --git a/CMakeLists.txt b/CMakeLists.txt
index d0e5371..e7478aa 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -49,6 +49,14 @@ target_link_libraries(${LOADABLE_EXTENSION_NAME}
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
PATCH_EOF

cat > .github/patches/extensions/postgres_scanner/oauth_hook_compat.patch << 'PATCH_EOF'
diff --git a/CMakeLists.txt b/CMakeLists.txt
index b30ca04..5edb9b2 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -10,6 +10,7 @@ add_definitions(
     -DHAVE_BIO_METH_NEW=1)
 
 find_package(OpenSSL REQUIRED)
+include(CheckSymbolExists)
 find_package(PostgreSQL REQUIRED)
 
 if(NOT MSVC)
@@ -19,6 +20,14 @@ if(NOT MSVC)
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
diff --git a/src/postgres_oauth.cpp b/src/postgres_oauth.cpp
index 619532a..2317879 100644
--- a/src/postgres_oauth.cpp
+++ b/src/postgres_oauth.cpp
@@ -9,6 +9,8 @@ extern "C" {
 #include "libpq-fe.h"
 }
 
+#ifdef HAVE_PQ_AUTH_DATA_HOOK
+
 namespace duckdb {
 
 //! Previous hook in the chain (if any)
@@ -107,3 +109,17 @@ OAuthTokenHolder SetThreadLocalOAuthTokenFromSessionOption(ClientContext &ctx) {
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
if [ -f .github/patches/extensions/avro/0004-logical-type-compat.patch ]; then
    rm -f .github/patches/extensions/avro/logical_type_compat.patch
    log_success "avro logical-type compat already present upstream"
else
cat > .github/patches/extensions/avro/logical_type_compat.patch << 'PATCH_EOF'
diff --git a/CMakeLists.txt b/CMakeLists.txt
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -31,6 +31,16 @@ else()
   find_library(ZLIB_LIBRARY libz.a REQUIRED)
 endif()
 
+include(CheckSymbolExists)
+
+set(CMAKE_REQUIRED_INCLUDES ${AVRO_INCLUDE_DIR})
+check_symbol_exists(avro_schema_logical_type "avro/schema.h" HAVE_AVRO_SCHEMA_LOGICAL_TYPE)
+unset(CMAKE_REQUIRED_INCLUDES)
+
+if(HAVE_AVRO_SCHEMA_LOGICAL_TYPE)
+  add_compile_definitions(HAVE_AVRO_SCHEMA_LOGICAL_TYPE=1)
+endif()
+
 find_library(SNAPPY_LIBRARY snappy REQUIRED)
 set(ALL_AVRO_LIBRARIES
     ${AVRO_LIBRARY}
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
index 081124a..f0a2df6 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -12,6 +12,9 @@ include_directories(${MYSQL_INCLUDE_DIR})
 
 add_subdirectory(src)
 
+# Static extension build (added by build script)
+build_static_extension(${TARGET_NAME} "" ${ALL_OBJECT_FILES})
+
 set(PARAMETERS "-no-warnings")
 build_loadable_extension(${TARGET_NAME} ${PARAMETERS} ${ALL_OBJECT_FILES})
 
@@ -19,3 +22,8 @@ build_loadable_extension(${TARGET_NAME} ${PARAMETERS} ${ALL_OBJECT_FILES})
 target_include_directories(${TARGET_NAME}_loadable_extension
                            PRIVATE include ${MYSQL_INCLUDE_DIR})
 target_link_libraries(${TARGET_NAME}_loadable_extension ${MYSQL_LIBRARIES})
+
+# Static binary includes/libs (added by build script)
+target_include_directories(${TARGET_NAME}_extension
+                           PRIVATE include src/include ${MYSQL_INCLUDE_DIR})
+target_link_libraries(${TARGET_NAME}_extension ${MYSQL_LIBRARIES})
PATCH_EOF

cat > .github/patches/extensions/delta/rustls.patch << 'PATCH_EOF'
diff --git a/CMakeLists.txt b/CMakeLists.txt
index ff33ba9..f2e3361 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -162,13 +162,9 @@ ExternalProject_Add(
   # Build debug build
   BUILD_COMMAND
     ${CMAKE_COMMAND} -E env ${RUST_UNSET_ENV_VARS} ${RUST_ENV_VARS} cargo build
-    --package delta_kernel_ffi --workspace --profile=${CARGO_PROFILE} --all-features
+    --package delta_kernel_ffi --profile=${CARGO_PROFILE} --no-default-features --features "default-engine-rustls,tracing,test-ffi"
     ${RUST_PLATFORM_PARAM}
-  # Build DATs
-  COMMAND
-    ${CMAKE_COMMAND} -E env ${RUST_UNSET_ENV_VARS} ${RUST_ENV_VARS} cargo build
-    --manifest-path=${CMAKE_BINARY_DIR}/rust/src/delta_kernel/acceptance/Cargo.toml
   # Define the byproducts, required for building with Ninja
   BUILD_BYPRODUCTS "${DELTA_KERNEL_LIBPATH}"
   BUILD_BYPRODUCTS "${DELTA_KERNEL_FFI_HEADER_C}"
   BUILD_BYPRODUCTS "${DELTA_KERNEL_FFI_HEADER_CXX}"
PATCH_EOF

if [ "$WITH_ROBUST_RPT" = true ]; then
    mkdir -p .github/patches/extensions/robust
    base64 -d > .github/patches/extensions/robust/current-duckdb-compat.patch << 'PATCH_B64'
ZGlmZiAtLWdpdCBhL3NyYy9pbmNsdWRlL3Byb2JlX2VtcHR5X3JlZ2lzdHJ5LmhwcCBiL3NyYy9p
bmNsdWRlL3Byb2JlX2VtcHR5X3JlZ2lzdHJ5LmhwcApuZXcgZmlsZSBtb2RlIDEwMDY0NAppbmRl
eCAwMDAwMDAwLi4xYjMzOTZmCi0tLSAvZGV2L251bGwKKysrIGIvc3JjL2luY2x1ZGUvcHJvYmVf
ZW1wdHlfcmVnaXN0cnkuaHBwCkBAIC0wLDAgKzEsNDEgQEAKKyNwcmFnbWEgb25jZQorCisjaW5j
bHVkZSAiZHVja2RiL21haW4vY2xpZW50X2NvbnRleHQuaHBwIgorI2luY2x1ZGUgImR1Y2tkYi9t
YWluL2NsaWVudF9jb250ZXh0X3N0YXRlLmhwcCIKKyNpbmNsdWRlICJkdWNrZGIvY29tbW9uL3No
YXJlZF9wdHIuaHBwIgorI2luY2x1ZGUgImR1Y2tkYi9jb21tb24vY29tbW9uLmhwcCIKKyNpbmNs
dWRlIDxhdG9taWM+CisjaW5jbHVkZSA8bXV0ZXg+CisjaW5jbHVkZSA8dW5vcmRlcmVkX21hcD4K
KworbmFtZXNwYWNlIGR1Y2tkYiB7CisKK2NsYXNzIFByb2JlRW1wdHlSZWdpc3RyeSA6IHB1Ymxp
YyBDbGllbnRDb250ZXh0U3RhdGUgeworcHVibGljOgorCXNoYXJlZF9wdHI8c3RkOjphdG9taWM8
Ym9vbD4+IEdldE9yQ3JlYXRlKGlkeF90IHRhYmxlX2lkeCkgeworCQlsb2NrX2d1YXJkPG11dGV4
PiBndWFyZChyZWdpc3RyeV9sb2NrKTsKKwkJYXV0byBpdCA9IGZsYWdzLmZpbmQodGFibGVfaWR4
KTsKKwkJaWYgKGl0ICE9IGZsYWdzLmVuZCgpKSB7CisJCQlyZXR1cm4gaXQtPnNlY29uZDsKKwkJ
fQorCQlhdXRvIGZsYWcgPSBtYWtlX3NoYXJlZF9wdHI8c3RkOjphdG9taWM8Ym9vbD4+KGZhbHNl
KTsKKwkJZmxhZ3MuZW1wbGFjZSh0YWJsZV9pZHgsIGZsYWcpOworCQlyZXR1cm4gZmxhZzsKKwl9
CisKK3ByaXZhdGU6CisJbXV0ZXggcmVnaXN0cnlfbG9jazsKKwl1bm9yZGVyZWRfbWFwPGlkeF90
LCBzaGFyZWRfcHRyPHN0ZDo6YXRvbWljPGJvb2w+Pj4gZmxhZ3M7Cit9OworCitzdGF0aWMgaW5s
aW5lIHNoYXJlZF9wdHI8UHJvYmVFbXB0eVJlZ2lzdHJ5PiBHZXRQcm9iZUVtcHR5UmVnaXN0cnko
Q2xpZW50Q29udGV4dCAmY29udGV4dCkgeworCWF1dG8gc3RhdGUgPSBjb250ZXh0LnJlZ2lzdGVy
ZWRfc3RhdGUtPkdldDxQcm9iZUVtcHR5UmVnaXN0cnk+KCJyb2J1c3RfcHJvYmVfZW1wdHlfcmVn
aXN0cnkiKTsKKwlpZiAoc3RhdGUpIHsKKwkJcmV0dXJuIHN0YXRlOworCX0KKwlhdXRvIHJlZ2lz
dHJ5ID0gbWFrZV9zaGFyZWRfcHRyPFByb2JlRW1wdHlSZWdpc3RyeT4oKTsKKwljb250ZXh0LnJl
Z2lzdGVyZWRfc3RhdGUtPkluc2VydCgicm9idXN0X3Byb2JlX2VtcHR5X3JlZ2lzdHJ5IiwgcmVn
aXN0cnkpOworCXJldHVybiByZWdpc3RyeTsKK30KKworfSAvLyBuYW1lc3BhY2UgZHVja2RiCmRp
ZmYgLS1naXQgYS9zcmMvaW5jbHVkZS9yb2J1c3RfcHJvZmlsaW5nLmhwcCBiL3NyYy9pbmNsdWRl
L3JvYnVzdF9wcm9maWxpbmcuaHBwCmluZGV4IDFlNmFiZjQuLmJlZTM2MzIgMTAwNjQ0Ci0tLSBh
L3NyYy9pbmNsdWRlL3JvYnVzdF9wcm9maWxpbmcuaHBwCisrKyBiL3NyYy9pbmNsdWRlL3JvYnVz
dF9wcm9maWxpbmcuaHBwCkBAIC04MSwxNyArODEsMTcgQEAgcHVibGljOgogCQlzdGF0cy0+aXNf
Zm9yd2FyZF9wYXNzID0gaXNfZm9yd2FyZF9wYXNzOwogCQkvLyBleHRyYWN0IHVuaXF1ZSBwcm9i
ZSB0YWJsZSBpbmRpY2VzIGZyb20gcHJvYmUgY29sdW1ucwogCQlmb3IgKGNvbnN0IGF1dG8gJmNv
bCA6IHByb2JlX2NvbHVtbnMpIHsKLQkJCWlmIChzdGF0cy0+cHJvYmVfdGFibGVfaW5kaWNlcy5l
bXB0eSgpIHx8IHN0YXRzLT5wcm9iZV90YWJsZV9pbmRpY2VzLmJhY2soKSAhPSBjb2wudGFibGVf
aW5kZXgpIHsKKwkJCWlmIChzdGF0cy0+cHJvYmVfdGFibGVfaW5kaWNlcy5lbXB0eSgpIHx8IHN0
YXRzLT5wcm9iZV90YWJsZV9pbmRpY2VzLmJhY2soKSAhPSBjb2wudGFibGVfaW5kZXguaW5kZXgp
IHsKIAkJCQkvLyBjaGVjayBpZiBhbHJlYWR5IHByZXNlbnQKIAkJCQlib29sIGZvdW5kID0gZmFs
c2U7CiAJCQkJZm9yIChhdXRvIGlkeCA6IHN0YXRzLT5wcm9iZV90YWJsZV9pbmRpY2VzKSB7Ci0J
CQkJCWlmIChpZHggPT0gY29sLnRhYmxlX2luZGV4KSB7CisJCQkJCWlmIChpZHggPT0gY29sLnRh
YmxlX2luZGV4LmluZGV4KSB7CiAJCQkJCQlmb3VuZCA9IHRydWU7CiAJCQkJCQlicmVhazsKIAkJ
CQkJfQogCQkJCX0KIAkJCQlpZiAoIWZvdW5kKSB7Ci0JCQkJCXN0YXRzLT5wcm9iZV90YWJsZV9p
bmRpY2VzLnB1c2hfYmFjayhjb2wudGFibGVfaW5kZXgpOworCQkJCQlzdGF0cy0+cHJvYmVfdGFi
bGVfaW5kaWNlcy5wdXNoX2JhY2soY29sLnRhYmxlX2luZGV4LmluZGV4KTsKIAkJCQl9CiAJCQl9
CiAJCX0KZGlmZiAtLWdpdCBhL3NyYy9vcGVyYXRvcnMvbG9naWNhbF9jcmVhdGVfZmlsdGVyLmNw
cCBiL3NyYy9vcGVyYXRvcnMvbG9naWNhbF9jcmVhdGVfZmlsdGVyLmNwcAppbmRleCBmNjJjOTU3
Li41ODY4NTZjIDEwMDY0NAotLS0gYS9zcmMvb3BlcmF0b3JzL2xvZ2ljYWxfY3JlYXRlX2ZpbHRl
ci5jcHAKKysrIGIvc3JjL29wZXJhdG9ycy9sb2dpY2FsX2NyZWF0ZV9maWx0ZXIuY3BwCkBAIC0y
OSw3ICsyOSw3IEBAIEluc2VydGlvbk9yZGVyUHJlc2VydmluZ01hcDxzdHJpbmc+IExvZ2ljYWxD
cmVhdGVGaWx0ZXI6OlBhcmFtc1RvU3RyaW5nKCkgY29uc3QKIAlmb3IgKGNvbnN0IGF1dG8gJmNv
bCA6IGZpbHRlcl9vcGVyYXRpb24ucHJvYmVfY29sdW1ucykgewogCQlib29sIGZvdW5kID0gZmFs
c2U7CiAJCWZvciAoYXV0byBpZHggOiBzZWVuX3Byb2JlKSB7Ci0JCQlpZiAoaWR4ID09IGNvbC50
YWJsZV9pbmRleCkgeworCQkJaWYgKGlkeCA9PSBjb2wudGFibGVfaW5kZXguaW5kZXgpIHsKIAkJ
CQlmb3VuZCA9IHRydWU7CiAJCQkJYnJlYWs7CiAJCQl9CkBAIC0zNyw4ICszNyw4IEBAIEluc2Vy
dGlvbk9yZGVyUHJlc2VydmluZ01hcDxzdHJpbmc+IExvZ2ljYWxDcmVhdGVGaWx0ZXI6OlBhcmFt
c1RvU3RyaW5nKCkgY29uc3QKIAkJaWYgKCFmb3VuZCkgewogCQkJaWYgKCFwcm9iZV90YWJsZXMu
ZW1wdHkoKSkKIAkJCQlwcm9iZV90YWJsZXMgKz0gIiwgIjsKLQkJCXByb2JlX3RhYmxlcyArPSB0
b19zdHJpbmcoY29sLnRhYmxlX2luZGV4KTsKLQkJCXNlZW5fcHJvYmUucHVzaF9iYWNrKGNvbC50
YWJsZV9pbmRleCk7CisJCQlwcm9iZV90YWJsZXMgKz0gdG9fc3RyaW5nKGNvbC50YWJsZV9pbmRl
eC5pbmRleCk7CisJCQlzZWVuX3Byb2JlLnB1c2hfYmFjayhjb2wudGFibGVfaW5kZXguaW5kZXgp
OwogCQl9CiAJfQogCXJlc3VsdFsiUHJvYmUgVGFibGVzIl0gPSBwcm9iZV90YWJsZXM7CkBAIC00
OCw3ICs0OCw3IEBAIEluc2VydGlvbk9yZGVyUHJlc2VydmluZ01hcDxzdHJpbmc+IExvZ2ljYWxD
cmVhdGVGaWx0ZXI6OlBhcmFtc1RvU3RyaW5nKCkgY29uc3QKIAkJaWYgKGkgPiAwKSB7CiAJCQli
dWlsZF9jb2xzICs9ICIsICI7CiAJCX0KLQkJYnVpbGRfY29scyArPSAiKCIgKyB0b19zdHJpbmco
ZmlsdGVyX29wZXJhdGlvbi5idWlsZF9jb2x1bW5zW2ldLnRhYmxlX2luZGV4KSArICIuIiArCisJ
CWJ1aWxkX2NvbHMgKz0gIigiICsgdG9fc3RyaW5nKGZpbHRlcl9vcGVyYXRpb24uYnVpbGRfY29s
dW1uc1tpXS50YWJsZV9pbmRleC5pbmRleCkgKyAiLiIgKwogCQkgICAgICAgICAgICAgIHRvX3N0
cmluZyhmaWx0ZXJfb3BlcmF0aW9uLmJ1aWxkX2NvbHVtbnNbaV0uY29sdW1uX2luZGV4KSArICIp
IjsKIAl9CiAJcmVzdWx0WyJCdWlsZCBDb2x1bW5zIl0gPSBidWlsZF9jb2xzOwpkaWZmIC0tZ2l0
IGEvc3JjL29wZXJhdG9ycy9sb2dpY2FsX2NyZWF0ZV9maWx0ZXIuaHBwIGIvc3JjL29wZXJhdG9y
cy9sb2dpY2FsX2NyZWF0ZV9maWx0ZXIuaHBwCmluZGV4IGMyNGQ4NzcuLjQwY2UwOTkgMTAwNjQ0
Ci0tLSBhL3NyYy9vcGVyYXRvcnMvbG9naWNhbF9jcmVhdGVfZmlsdGVyLmhwcAorKysgYi9zcmMv
b3BlcmF0b3JzL2xvZ2ljYWxfY3JlYXRlX2ZpbHRlci5ocHAKQEAgLTEwLDYgKzEwLDcgQEAKICNp
bmNsdWRlICJkdWNrZGIvcGxhbm5lci9sb2dpY2FsX29wZXJhdG9yLmhwcCIKICNpbmNsdWRlICJk
dWNrZGIvcGxhbm5lci9vcGVyYXRvci9sb2dpY2FsX2V4dGVuc2lvbl9vcGVyYXRvci5ocHAiCiAj
aW5jbHVkZSAiZHVja2RiL3BsYW5uZXIvdGFibGVfZmlsdGVyLmhwcCIKKyNpbmNsdWRlICJkdWNr
ZGIvcGxhbm5lci90YWJsZV9maWx0ZXJfc2V0LmhwcCIKICNpbmNsdWRlICIuLi9vcHRpbWl6ZXIv
Z3JhcGhfbWFuYWdlci5ocHAiCiAKIG5hbWVzcGFjZSBkdWNrZGIgewpkaWZmIC0tZ2l0IGEvc3Jj
L29wZXJhdG9ycy9sb2dpY2FsX3Byb2JlX2ZpbHRlci5jcHAgYi9zcmMvb3BlcmF0b3JzL2xvZ2lj
YWxfcHJvYmVfZmlsdGVyLmNwcAppbmRleCAzMjkzMjAzLi44MzBhZWIyIDEwMDY0NAotLS0gYS9z
cmMvb3BlcmF0b3JzL2xvZ2ljYWxfcHJvYmVfZmlsdGVyLmNwcAorKysgYi9zcmMvb3BlcmF0b3Jz
L2xvZ2ljYWxfcHJvYmVfZmlsdGVyLmNwcApAQCAtMjQsNyArMjQsNyBAQCBJbnNlcnRpb25PcmRl
clByZXNlcnZpbmdNYXA8c3RyaW5nPiBMb2dpY2FsUHJvYmVGaWx0ZXI6OlBhcmFtc1RvU3RyaW5n
KCkgY29uc3QgewogCQlpZiAoaSA+IDApIHsKIAkJCXByb2JlX2NvbHMgKz0gIiwgIjsKIAkJfQot
CQlwcm9iZV9jb2xzICs9ICIoIiArIHRvX3N0cmluZyhmaWx0ZXJfb3BlcmF0aW9uLnByb2JlX2Nv
bHVtbnNbaV0udGFibGVfaW5kZXgpICsgIi4iICsKKwkJcHJvYmVfY29scyArPSAiKCIgKyB0b19z
dHJpbmcoZmlsdGVyX29wZXJhdGlvbi5wcm9iZV9jb2x1bW5zW2ldLnRhYmxlX2luZGV4LmluZGV4
KSArICIuIiArCiAJCSAgICAgICAgICAgICAgdG9fc3RyaW5nKGZpbHRlcl9vcGVyYXRpb24ucHJv
YmVfY29sdW1uc1tpXS5jb2x1bW5faW5kZXgpICsgIikiOwogCX0KIAlyZXN1bHRbIlByb2JlIENv
bHVtbnMiXSA9IHByb2JlX2NvbHM7CkBAIC02MSwxNCArNjEsMTQgQEAgUGh5c2ljYWxPcGVyYXRv
ciAmTG9naWNhbFByb2JlRmlsdGVyOjpDcmVhdGVQbGFuKENsaWVudENvbnRleHQgJmNvbnRleHQs
IFBoeXNpY2EKIAkJUHJpbnRlcjo6UHJpbnQoU3RyaW5nVXRpbDo6Rm9ybWF0KCJbUkVTT0xWRV0g
Y2hpbGRfYmluZGluZ3Muc2l6ZSgpPSV6dSIsIGNoaWxkX2JpbmRpbmdzLnNpemUoKSkpOwogCQlm
b3IgKGlkeF90IGogPSAwOyBqIDwgY2hpbGRfYmluZGluZ3Muc2l6ZSgpOyBqKyspIHsKIAkJCVBy
aW50ZXI6OlByaW50KFN0cmluZ1V0aWw6OkZvcm1hdCgiICBjaGlsZF9iaW5kaW5nc1slbGx1XSA9
IHRhYmxlX2lkeD0lbGx1LCBjb2xfaWR4PSVsbHUiLAotCQkJICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICh1bnNpZ25lZCBsb25nIGxvbmcpaiwgKHVuc2lnbmVkIGxvbmcgbG9uZylj
aGlsZF9iaW5kaW5nc1tqXS50YWJsZV9pbmRleCwKKwkJCSAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAodW5zaWduZWQgbG9uZyBsb25nKWosICh1bnNpZ25lZCBsb25nIGxvbmcpY2hp
bGRfYmluZGluZ3Nbal0udGFibGVfaW5kZXguaW5kZXgsCiAJCQkgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgKHVuc2lnbmVkIGxvbmcgbG9uZyljaGlsZF9iaW5kaW5nc1tqXS5jb2x1
bW5faW5kZXgpKTsKIAkJfQogI2VuZGlmCiAKIAkJZm9yIChjb25zdCBDb2x1bW5CaW5kaW5nICZj
b2x1bW5fYmluZGluZyA6IGZpbHRlcl9vcGVyYXRpb24ucHJvYmVfY29sdW1ucykgewogCQkJRF9Q
UklOVEYoIltSRVNPTFZFXSBMb29raW5nIGZvciBwcm9iZV9jb2x1bW46IHRhYmxlX2lkeD0lbGx1
LCBjb2xfaWR4PSVsbHUiLAotCQkJICAgICAgICAgKHVuc2lnbmVkIGxvbmcgbG9uZyljb2x1bW5f
YmluZGluZy50YWJsZV9pbmRleCwgKHVuc2lnbmVkIGxvbmcgbG9uZyljb2x1bW5fYmluZGluZy5j
b2x1bW5faW5kZXgpOworCQkJICAgICAgICAgKHVuc2lnbmVkIGxvbmcgbG9uZyljb2x1bW5fYmlu
ZGluZy50YWJsZV9pbmRleC5pbmRleCwgKHVuc2lnbmVkIGxvbmcgbG9uZyljb2x1bW5fYmluZGlu
Zy5jb2x1bW5faW5kZXgpOwogCQkJLy8gZmluZCB0aGUgcG9zaXRpb24gb2YgdGhlIGZpbHRlciBj
b2x1bW4gQ29sdW1uQmluZGluZyBpbiB0aGUgY2h1bmsgY29sdW1ucwogCQkJZm9yIChpZHhfdCBp
ID0gMDsgaSA8IGNoaWxkX2JpbmRpbmdzLnNpemUoKTsgaSsrKSB7CiAJCQkJaWYgKGNoaWxkX2Jp
bmRpbmdzW2ldLnRhYmxlX2luZGV4ID09IGNvbHVtbl9iaW5kaW5nLnRhYmxlX2luZGV4ICYmCmRp
ZmYgLS1naXQgYS9zcmMvb3BlcmF0b3JzL3BoeXNpY2FsX2NyZWF0ZV9maWx0ZXIuY3BwIGIvc3Jj
L29wZXJhdG9ycy9waHlzaWNhbF9jcmVhdGVfZmlsdGVyLmNwcAppbmRleCA0MTM0MjExLi40NjIy
ODRlIDEwMDY0NAotLS0gYS9zcmMvb3BlcmF0b3JzL3BoeXNpY2FsX2NyZWF0ZV9maWx0ZXIuY3Bw
CisrKyBiL3NyYy9vcGVyYXRvcnMvcGh5c2ljYWxfY3JlYXRlX2ZpbHRlci5jcHAKQEAgLTQ4LDcg
KzQ4LDcgQEAgSW5zZXJ0aW9uT3JkZXJQcmVzZXJ2aW5nTWFwPHN0cmluZz4gUGh5c2ljYWxDcmVh
dGVGaWx0ZXI6OlBhcmFtc1RvU3RyaW5nKCkgY29uc3QKIAlmb3IgKGNvbnN0IGF1dG8gJmNvbCA6
IGZpbHRlcl9vcGVyYXRpb24tPnByb2JlX2NvbHVtbnMpIHsKIAkJYm9vbCBmb3VuZCA9IGZhbHNl
OwogCQlmb3IgKGF1dG8gaWR4IDogc2Vlbl9wcm9iZSkgewotCQkJaWYgKGlkeCA9PSBjb2wudGFi
bGVfaW5kZXgpIHsKKwkJCWlmIChpZHggPT0gY29sLnRhYmxlX2luZGV4LmluZGV4KSB7CiAJCQkJ
Zm91bmQgPSB0cnVlOwogCQkJCWJyZWFrOwogCQkJfQpAQCAtNTYsOCArNTYsOCBAQCBJbnNlcnRp
b25PcmRlclByZXNlcnZpbmdNYXA8c3RyaW5nPiBQaHlzaWNhbENyZWF0ZUZpbHRlcjo6UGFyYW1z
VG9TdHJpbmcoKSBjb25zdAogCQlpZiAoIWZvdW5kKSB7CiAJCQlpZiAoIXByb2JlX3RhYmxlcy5l
bXB0eSgpKQogCQkJCXByb2JlX3RhYmxlcyArPSAiLCAiOwotCQkJcHJvYmVfdGFibGVzICs9IHRv
X3N0cmluZyhjb2wudGFibGVfaW5kZXgpOwotCQkJc2Vlbl9wcm9iZS5wdXNoX2JhY2soY29sLnRh
YmxlX2luZGV4KTsKKwkJCXByb2JlX3RhYmxlcyArPSB0b19zdHJpbmcoY29sLnRhYmxlX2luZGV4
LmluZGV4KTsKKwkJCXNlZW5fcHJvYmUucHVzaF9iYWNrKGNvbC50YWJsZV9pbmRleC5pbmRleCk7
CiAJCX0KIAl9CiAJcmVzdWx0WyJQcm9iZSBUYWJsZXMiXSA9IHByb2JlX3RhYmxlczsKQEAgLTY3
LDcgKzY3LDcgQEAgSW5zZXJ0aW9uT3JkZXJQcmVzZXJ2aW5nTWFwPHN0cmluZz4gUGh5c2ljYWxD
cmVhdGVGaWx0ZXI6OlBhcmFtc1RvU3RyaW5nKCkgY29uc3QKIAkJaWYgKGkgPiAwKSB7CiAJCQli
dWlsZF9jb2xzICs9ICIsICI7CiAJCX0KLQkJYnVpbGRfY29scyArPSAiKCIgKyB0b19zdHJpbmco
ZmlsdGVyX29wZXJhdGlvbi0+YnVpbGRfY29sdW1uc1tpXS50YWJsZV9pbmRleCkgKyAiLiIgKwor
CQlidWlsZF9jb2xzICs9ICIoIiArIHRvX3N0cmluZyhmaWx0ZXJfb3BlcmF0aW9uLT5idWlsZF9j
b2x1bW5zW2ldLnRhYmxlX2luZGV4LmluZGV4KSArICIuIiArCiAJCSAgICAgICAgICAgICAgdG9f
c3RyaW5nKGZpbHRlcl9vcGVyYXRpb24tPmJ1aWxkX2NvbHVtbnNbaV0uY29sdW1uX2luZGV4KSAr
ICIpIjsKIAl9CiAJcmVzdWx0WyJCdWlsZCBDb2x1bW5zIl0gPSBidWlsZF9jb2xzOwpAQCAtMzY3
LDcgKzM2Nyw3IEBAIHN0YXRpYyB2b2lkIFB1c2hEeW5hbWljRmlsdGVycyhjb25zdCBQaHlzaWNh
bENyZWF0ZUZpbHRlciAmb3AsIGNvbnN0IENyZWF0ZUZpbHRlCiAJCWZvciAoYXV0byAmdGFyZ2V0
IDogb3AucHVzaGRvd25fdGFyZ2V0cykgewogCQkJYXV0byBhbHdheXNfZmFsc2UgPQogCQkJICAg
IG1ha2VfdW5pcTxDb25zdGFudEZpbHRlcj4oRXhwcmVzc2lvblR5cGU6OkNPTVBBUkVfR1JFQVRF
UlRIQU4sIFZhbHVlOjpNYXhpbXVtVmFsdWUodGFyZ2V0LmNvbHVtbl90eXBlKSk7Ci0JCQl0YXJn
ZXQuZHluYW1pY19maWx0ZXJzLT5QdXNoRmlsdGVyKG9wLCB0YXJnZXQuc2Nhbl9jb2x1bW5faW5k
ZXgsIHN0ZDo6bW92ZShhbHdheXNfZmFsc2UpKTsKKwkJCXRhcmdldC5keW5hbWljX2ZpbHRlcnMt
PlB1c2hGaWx0ZXIob3AsIFByb2plY3Rpb25JbmRleCh0YXJnZXQuc2Nhbl9jb2x1bW5faW5kZXgp
LCBzdGQ6Om1vdmUoYWx3YXlzX2ZhbHNlKSk7CiAJCQlEX1BSSU5URigiW1BVU0hET1dOXSBwdXNo
ZWQgYWx3YXlzLWZhbHNlIGZvciBjb2wgJXMgKGVtcHR5IGJ1aWxkIHNpZGUpIiwgdGFyZ2V0LmNv
bHVtbl9uYW1lLmNfc3RyKCkpOwogCQl9CiAJCXJldHVybjsKQEAgLTQwMyw3ICs0MDMsNyBAQCBz
dGF0aWMgdm9pZCBQdXNoRHluYW1pY0ZpbHRlcnMoY29uc3QgUGh5c2ljYWxDcmVhdGVGaWx0ZXIg
Jm9wLCBjb25zdCBDcmVhdGVGaWx0ZQogCQkJCWF1dG8gJmNkID0gZ3NpbmsuY29sdW1uX2Rpc3Rp
bmN0W2ldOwogCQkJCWlmICghY2Qub3Zlcl90aHJlc2hvbGQgJiYgY2QudmFsdWVzLnNpemUoKSA9
PSAxKSB7CiAJCQkJCWF1dG8gZXEgPSBtYWtlX3VuaXE8Q29uc3RhbnRGaWx0ZXI+KEV4cHJlc3Np
b25UeXBlOjpDT01QQVJFX0VRVUFMLCAqY2QudmFsdWVzLmJlZ2luKCkpOwotCQkJCQl0YXJnZXQu
ZHluYW1pY19maWx0ZXJzLT5QdXNoRmlsdGVyKG9wLCB0YXJnZXQuc2Nhbl9jb2x1bW5faW5kZXgs
IHN0ZDo6bW92ZShlcSkpOworCQkJCQl0YXJnZXQuZHluYW1pY19maWx0ZXJzLT5QdXNoRmlsdGVy
KG9wLCBQcm9qZWN0aW9uSW5kZXgodGFyZ2V0LnNjYW5fY29sdW1uX2luZGV4KSwgc3RkOjptb3Zl
KGVxKSk7CiAJCQkJCXB1c2hlZF9lcXVhbCA9IHRydWU7CiAJCQkJCURfUFJJTlRGKCJbUFVTSERP
V05dIHB1c2hlZCBlcXVhbGl0eSBjb25zdGFudCBmb3IgY29sICVzIiwgdGFyZ2V0LmNvbHVtbl9u
YW1lLmNfc3RyKCkpOwogCQkJCX0gZWxzZSBpZiAoIWNkLm92ZXJfdGhyZXNob2xkICYmIGNkLnZh
bHVlcy5zaXplKCkgPiAxKSB7CkBAIC00MTEsNyArNDExLDcgQEAgc3RhdGljIHZvaWQgUHVzaER5
bmFtaWNGaWx0ZXJzKGNvbnN0IFBoeXNpY2FsQ3JlYXRlRmlsdGVyICZvcCwgY29uc3QgQ3JlYXRl
RmlsdGUKIAkJCQkJaWYgKCFGaWx0ZXJDb21iaW5lcjo6Q29udGFpbnNOdWxsKGluX2xpc3QpICYm
ICFGaWx0ZXJDb21iaW5lcjo6SXNEZW5zZVJhbmdlKGluX2xpc3QpKSB7CiAJCQkJCQlhdXRvIGlu
X2YgPSBtYWtlX3VuaXE8SW5GaWx0ZXI+KHN0ZDo6bW92ZShpbl9saXN0KSk7CiAJCQkJCQlhdXRv
IG9wdCA9IG1ha2VfdW5pcTxPcHRpb25hbEZpbHRlcj4oc3RkOjptb3ZlKGluX2YpKTsKLQkJCQkJ
CXRhcmdldC5keW5hbWljX2ZpbHRlcnMtPlB1c2hGaWx0ZXIob3AsIHRhcmdldC5zY2FuX2NvbHVt
bl9pbmRleCwgc3RkOjptb3ZlKG9wdCkpOworCQkJCQkJdGFyZ2V0LmR5bmFtaWNfZmlsdGVycy0+
UHVzaEZpbHRlcihvcCwgUHJvamVjdGlvbkluZGV4KHRhcmdldC5zY2FuX2NvbHVtbl9pbmRleCks
IHN0ZDo6bW92ZShvcHQpKTsKIAkJCQkJCURfUFJJTlRGKCJbUFVTSERPV05dIHB1c2hlZCBJTi1m
aWx0ZXIgKCVsbHUgdmFsdWVzKSBmb3IgY29sICVzIiwKIAkJCQkJCSAgICAgICAgICh1bnNpZ25l
ZCBsb25nIGxvbmcpY2QudmFsdWVzLnNpemUoKSwgdGFyZ2V0LmNvbHVtbl9uYW1lLmNfc3RyKCkp
OwogCQkJCQl9CkBAIC00MjgsNyArNDI4LDcgQEAgc3RhdGljIHZvaWQgUHVzaER5bmFtaWNGaWx0
ZXJzKGNvbnN0IFBoeXNpY2FsQ3JlYXRlRmlsdGVyICZvcCwgY29uc3QgQ3JlYXRlRmlsdGUKIAkJ
CQkJYXV0byB3cmFwcGVkID0gbWFrZV91bmlxPFNlbGVjdGl2aXR5T3B0aW9uYWxGaWx0ZXI+KHN0
ZDo6bW92ZShiZl9maWx0ZXIpLAogCQkJCQkgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgMSwKIAkJCQkJICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgIDEwMDAwMDApOwotCQkJCQl0YXJnZXQuZHluYW1pY19m
aWx0ZXJzLT5QdXNoRmlsdGVyKG9wLCB0YXJnZXQuc2Nhbl9jb2x1bW5faW5kZXgsIHN0ZDo6bW92
ZSh3cmFwcGVkKSk7CisJCQkJCXRhcmdldC5keW5hbWljX2ZpbHRlcnMtPlB1c2hGaWx0ZXIob3As
IFByb2plY3Rpb25JbmRleCh0YXJnZXQuc2Nhbl9jb2x1bW5faW5kZXgpLCBzdGQ6Om1vdmUod3Jh
cHBlZCkpOwogCQkJCQlEX1BSSU5URigiW1BVU0hET1dOXSBwdXNoZWQgQkYgZm9yIGNvbCAlcyB0
byBzY2FuIGNvbCAlbGx1IiwgdGFyZ2V0LmNvbHVtbl9uYW1lLmNfc3RyKCksCiAJCQkJCSAgICAg
ICAgICh1bnNpZ25lZCBsb25nIGxvbmcpdGFyZ2V0LnNjYW5fY29sdW1uX2luZGV4KTsKIAkJCQl9
CkBAIC00MzksMTAgKzQzOSwxMCBAQCBzdGF0aWMgdm9pZCBQdXNoRHluYW1pY0ZpbHRlcnMoY29u
c3QgUGh5c2ljYWxDcmVhdGVGaWx0ZXIgJm9wLCBjb25zdCBDcmVhdGVGaWx0ZQogCQkJICAgIGdz
aW5rLmNvbHVtbl9taW5fbWF4W2ldLmhhc192YWx1ZSkgewogCQkJCWF1dG8gJm1tID0gZ3Npbmsu
Y29sdW1uX21pbl9tYXhbaV07CiAJCQkJYXV0byBtaW5fZmlsdGVyID0gbWFrZV91bmlxPENvbnN0
YW50RmlsdGVyPihFeHByZXNzaW9uVHlwZTo6Q09NUEFSRV9HUkVBVEVSVEhBTk9SRVFVQUxUTywg
bW0ubWluX3ZhbCk7Ci0JCQkJdGFyZ2V0LmR5bmFtaWNfZmlsdGVycy0+UHVzaEZpbHRlcihvcCwg
dGFyZ2V0LnNjYW5fY29sdW1uX2luZGV4LCBzdGQ6Om1vdmUobWluX2ZpbHRlcikpOworCQkJCXRh
cmdldC5keW5hbWljX2ZpbHRlcnMtPlB1c2hGaWx0ZXIob3AsIFByb2plY3Rpb25JbmRleCh0YXJn
ZXQuc2Nhbl9jb2x1bW5faW5kZXgpLCBzdGQ6Om1vdmUobWluX2ZpbHRlcikpOwogCiAJCQkJYXV0
byBtYXhfZmlsdGVyID0gbWFrZV91bmlxPENvbnN0YW50RmlsdGVyPihFeHByZXNzaW9uVHlwZTo6
Q09NUEFSRV9MRVNTVEhBTk9SRVFVQUxUTywgbW0ubWF4X3ZhbCk7Ci0JCQkJdGFyZ2V0LmR5bmFt
aWNfZmlsdGVycy0+UHVzaEZpbHRlcihvcCwgdGFyZ2V0LnNjYW5fY29sdW1uX2luZGV4LCBzdGQ6
Om1vdmUobWF4X2ZpbHRlcikpOworCQkJCXRhcmdldC5keW5hbWljX2ZpbHRlcnMtPlB1c2hGaWx0
ZXIob3AsIFByb2plY3Rpb25JbmRleCh0YXJnZXQuc2Nhbl9jb2x1bW5faW5kZXgpLCBzdGQ6Om1v
dmUobWF4X2ZpbHRlcikpOwogCiAJCQkJRF9QUklOVEYoIltQVVNIRE9XTl0gcHVzaGVkIG1pbi1t
YXggZm9yIGNvbCAlcyBbJXMsICVzXSIsIHRhcmdldC5jb2x1bW5fbmFtZS5jX3N0cigpLAogCQkJ
CSAgICAgICAgIG1tLm1pbl92YWwuVG9TdHJpbmcoKS5jX3N0cigpLCBtbS5tYXhfdmFsLlRvU3Ry
aW5nKCkuY19zdHIoKSk7CkBAIC01MDEsNyArNTAxLDcgQEAgU2lua0ZpbmFsaXplVHlwZSBQaHlz
aWNhbENyZWF0ZUZpbHRlcjo6RmluYWxpemUoUGlwZWxpbmUgJnBpcGVsaW5lLCBFdmVudCAmZXZl
bnQKIAkJCWlmIChhY3R1YWxfcm93cyAqIDggPiBhbGxvY2F0ZWRfYml0cykgewogCQkJCURfUFJJ
TlRGKCJbUkVTSVpFXSBDUkVBVEVfRklMVEVSIChidWlsZD0lcykgY29sPSglbGx1LiVsbHUpIHNp
emVkX2Zvcj0lbGx1IGFjdHVhbD0lbGx1ICIKIAkJCQkgICAgICAgICAiYWxsb2NhdGVkX2JpdHM9
JWxsdSAtPiByZWhhc2hpbmciLAotCQkJCSAgICAgICAgIGJ1aWxkX3RhYmxlLmNfc3RyKCksICh1
bnNpZ25lZCBsb25nIGxvbmcpY29sLnRhYmxlX2luZGV4LAorCQkJCSAgICAgICAgIGJ1aWxkX3Rh
YmxlLmNfc3RyKCksICh1bnNpZ25lZCBsb25nIGxvbmcpY29sLnRhYmxlX2luZGV4LmluZGV4LAog
CQkJCSAgICAgICAgICh1bnNpZ25lZCBsb25nIGxvbmcpY29sLmNvbHVtbl9pbmRleCwgKHVuc2ln
bmVkIGxvbmcgbG9uZyliZi5TaXplZEZvclJvd3MoKSwKIAkJCQkgICAgICAgICAodW5zaWduZWQg
bG9uZyBsb25nKWFjdHVhbF9yb3dzLCAodW5zaWduZWQgbG9uZyBsb25nKWFsbG9jYXRlZF9iaXRz
KTsKIAkJCQliZi5SZWluaXRpYWxpemVBbmRSZWhhc2goY29udGV4dCwgYWN0dWFsX3Jvd3MsICpn
c2luay50b3RhbF9kYXRhLCB7Ym91bmRfY29sdW1uX2luZGljZXNbaV19KTsKZGlmZiAtLWdpdCBh
L3NyYy9vcGVyYXRvcnMvcGh5c2ljYWxfY3JlYXRlX2ZpbHRlci5ocHAgYi9zcmMvb3BlcmF0b3Jz
L3BoeXNpY2FsX2NyZWF0ZV9maWx0ZXIuaHBwCmluZGV4IGRkNTc0NTEuLjI3MTQ3MzcgMTAwNjQ0
Ci0tLSBhL3NyYy9vcGVyYXRvcnMvcGh5c2ljYWxfY3JlYXRlX2ZpbHRlci5ocHAKKysrIGIvc3Jj
L29wZXJhdG9ycy9waHlzaWNhbF9jcmVhdGVfZmlsdGVyLmhwcApAQCAtNiw2ICs2LDcgQEAKICNp
bmNsdWRlICJkdWNrZGIvY29tbW9uL3R5cGVzL2NvbHVtbi9jb2x1bW5fZGF0YV9jb2xsZWN0aW9u
LmhwcCIKICNpbmNsdWRlIDxkdWNrZGIvY29tbW9uL3R5cGVzL2NvbHVtbi9jb2x1bW5fZGF0YV9z
Y2FuX3N0YXRlcy5ocHA+CiAjaW5jbHVkZSAiZHVja2RiL3BsYW5uZXIvdGFibGVfZmlsdGVyLmhw
cCIKKyNpbmNsdWRlICJkdWNrZGIvcGxhbm5lci90YWJsZV9maWx0ZXJfc2V0LmhwcCIKICNpbmNs
dWRlICJkdWNrZGIvY29tbW9uL3R5cGVzL3ZhbHVlX21hcC5ocHAiCiAKIG5hbWVzcGFjZSBkdWNr
ZGIgewpkaWZmIC0tZ2l0IGEvc3JjL29wZXJhdG9ycy9waHlzaWNhbF9wcm9iZV9maWx0ZXIuY3Bw
IGIvc3JjL29wZXJhdG9ycy9waHlzaWNhbF9wcm9iZV9maWx0ZXIuY3BwCmluZGV4IDFlMjM1ZGIu
Ljg3YmJmM2MgMTAwNjQ0Ci0tLSBhL3NyYy9vcGVyYXRvcnMvcGh5c2ljYWxfcHJvYmVfZmlsdGVy
LmNwcAorKysgYi9zcmMvb3BlcmF0b3JzL3BoeXNpY2FsX3Byb2JlX2ZpbHRlci5jcHAKQEAgLTQy
LDcgKzQyLDcgQEAgSW5zZXJ0aW9uT3JkZXJQcmVzZXJ2aW5nTWFwPHN0cmluZz4gUGh5c2ljYWxQ
cm9iZUZpbHRlcjo6UGFyYW1zVG9TdHJpbmcoKSBjb25zdAogCQlpZiAoaSA+IDApIHsKIAkJCXBy
b2JlX2NvbHMgKz0gIiwgIjsKIAkJfQotCQlwcm9iZV9jb2xzICs9ICIoIiArIHRvX3N0cmluZyhm
aWx0ZXJfb3BlcmF0aW9uLT5wcm9iZV9jb2x1bW5zW2ldLnRhYmxlX2luZGV4KSArICIuIiArCisJ
CXByb2JlX2NvbHMgKz0gIigiICsgdG9fc3RyaW5nKGZpbHRlcl9vcGVyYXRpb24tPnByb2JlX2Nv
bHVtbnNbaV0udGFibGVfaW5kZXguaW5kZXgpICsgIi4iICsKIAkJICAgICAgICAgICAgICB0b19z
dHJpbmcoZmlsdGVyX29wZXJhdGlvbi0+cHJvYmVfY29sdW1uc1tpXS5jb2x1bW5faW5kZXgpICsg
IikiOwogCX0KIAlyZXN1bHRbIlByb2JlIENvbHVtbnMiXSA9IHByb2JlX2NvbHM7CkBAIC05OCw3
ICs5OCw3IEBAIE9wZXJhdG9yUmVzdWx0VHlwZSBQaHlzaWNhbFByb2JlRmlsdGVyOjpFeGVjdXRl
SW50ZXJuYWwoRXhlY3V0aW9uQ29udGV4dCAmY29udGV4CiAJCQkJCQkgICAgICAgICAgICAgICAg
ICAgICAgICAgOiAidW5rbm93biI7CiAJCQkJCQlEX1BSSU5URigKIAkJCQkJCSAgICAiW0VYRUNf
SU5URVJOQUxdIFBST0JFX0ZJTFRFUiBmb3VuZCBibG9vbSBmaWx0ZXIgZm9yIGNvbCglbGx1LCVs
bHUpIGZyb20gQ1JFQVRFX0ZJTFRFUiAoYnVpbGQ9JXMpIiwKLQkJCQkJCSAgICAodW5zaWduZWQg
bG9uZyBsb25nKWJ1aWxkX2NvbC50YWJsZV9pbmRleCwgKHVuc2lnbmVkIGxvbmcgbG9uZylidWls
ZF9jb2wuY29sdW1uX2luZGV4LAorCQkJCQkJICAgICh1bnNpZ25lZCBsb25nIGxvbmcpYnVpbGRf
Y29sLnRhYmxlX2luZGV4LmluZGV4LCAodW5zaWduZWQgbG9uZyBsb25nKWJ1aWxkX2NvbC5jb2x1
bW5faW5kZXgsCiAJCQkJCQkgICAgYnVpbGRfdGFibGUuY19zdHIoKSk7CiAJCQkJCQlzdGF0ZS5i
bG9vbV9maWx0ZXJzLnB1c2hfYmFjayhiZik7CiAJCQkJCQlicmVhazsgLy8gZm91bmQgdGhlIGZp
bHRlciBmb3IgdGhpcyBjb2x1bW4KZGlmZiAtLWdpdCBhL3NyYy9vcHRpbWl6ZXIvZ3JhcGhfbWFu
YWdlci5ocHAgYi9zcmMvb3B0aW1pemVyL2dyYXBoX21hbmFnZXIuaHBwCmluZGV4IGQwZjRiNWUu
LjlkY2YyYjQgMTAwNjQ0Ci0tLSBhL3NyYy9vcHRpbWl6ZXIvZ3JhcGhfbWFuYWdlci5ocHAKKysr
IGIvc3JjL29wdGltaXplci9ncmFwaF9tYW5hZ2VyLmhwcApAQCAtMTEsNyArMTEsNyBAQCBuYW1l
c3BhY2UgZHVja2RiIHsKIC8vIGhhc2ggZnVuY3Rpb24gZm9yIENvbHVtbkJpbmRpbmcgdG8gdXNl
IGFzIG1hcCBrZXkKIHN0cnVjdCBDb2x1bW5CaW5kaW5nSGFzaCB7CiAJc2l6ZV90IG9wZXJhdG9y
KCkoY29uc3QgQ29sdW1uQmluZGluZyAmYmluZGluZykgY29uc3QgewotCQlyZXR1cm4gc3RkOjpo
YXNoPGlkeF90PigpKGJpbmRpbmcudGFibGVfaW5kZXgpIF4gKHN0ZDo6aGFzaDxpZHhfdD4oKShi
aW5kaW5nLmNvbHVtbl9pbmRleCkgPDwgMTYpOworCQlyZXR1cm4gc3RkOjpoYXNoPFRhYmxlSW5k
ZXg+KCkoYmluZGluZy50YWJsZV9pbmRleCkgXiAoc3RkOjpoYXNoPGlkeF90PigpKGJpbmRpbmcu
Y29sdW1uX2luZGV4KSA8PCAxNik7CiAJfQogfTsKIApkaWZmIC0tZ2l0IGEvc3JjL29wdGltaXpl
ci9yb2J1c3Rfb3B0aW1pemVyLmNwcCBiL3NyYy9vcHRpbWl6ZXIvcm9idXN0X29wdGltaXplci5j
cHAKaW5kZXggODY1MmQxNC4uZWRmNTEyNiAxMDA2NDQKLS0tIGEvc3JjL29wdGltaXplci9yb2J1
c3Rfb3B0aW1pemVyLmNwcAorKysgYi9zcmMvb3B0aW1pemVyL3JvYnVzdF9vcHRpbWl6ZXIuY3Bw
CkBAIC01Nyw4ICs1Nyw4IEBAIHZvaWQgUm9idXN0T3B0aW1pemVyQ29udGV4dFN0YXRlOjpFeHRy
YWN0T3BlcmF0b3JzUmVjdXJzaXZlKExvZ2ljYWxPcGVyYXRvciAmcGxhCiAJCWNhc2UgSm9pblR5
cGU6OlJJR0hUX1NFTUk6IHsKIAkJCWlmIChzdGQ6OmFueV9vZihqb2luLmNvbmRpdGlvbnMuYmVn
aW4oKSwgam9pbi5jb25kaXRpb25zLmVuZCgpLCBbXShjb25zdCBKb2luQ29uZGl0aW9uICZqYykg
ewogCQkJCSAgICByZXR1cm4gamMuR2V0Q29tcGFyaXNvblR5cGUoKSA9PSBFeHByZXNzaW9uVHlw
ZTo6Q09NUEFSRV9FUVVBTCAmJgotCQkJCSAgICAgICAgICAgamMuR2V0TEhTKCkudHlwZSA9PSBF
eHByZXNzaW9uVHlwZTo6Qk9VTkRfQ09MVU1OX1JFRiAmJgotCQkJCSAgICAgICAgICAgamMuR2V0
UkhTKCkudHlwZSA9PSBFeHByZXNzaW9uVHlwZTo6Qk9VTkRfQ09MVU1OX1JFRjsKKwkJCQkgICAg
ICAgICAgIGpjLkdldExIUygpLkdldEV4cHJlc3Npb25UeXBlKCkgPT0gRXhwcmVzc2lvblR5cGU6
OkJPVU5EX0NPTFVNTl9SRUYgJiYKKwkJCQkgICAgICAgICAgIGpjLkdldFJIUygpLkdldEV4cHJl
c3Npb25UeXBlKCkgPT0gRXhwcmVzc2lvblR5cGU6OkJPVU5EX0NPTFVNTl9SRUY7CiAJCQkgICAg
fSkpIHsKIAkJCQkvLyBKb2luRWRnZSBlZGdlKGpvaW4pOwogCQkJCWpvaW5fb3BzLnB1c2hfYmFj
ayhvcCk7CkBAIC04OSw3ICs4OSw3IEBAIHZvaWQgUm9idXN0T3B0aW1pemVyQ29udGV4dFN0YXRl
OjpFeHRyYWN0T3BlcmF0b3JzUmVjdXJzaXZlKExvZ2ljYWxPcGVyYXRvciAmcGxhCiAJCX0gZWxz
ZSB7CiAJCQlhdXRvIG9sZF9yZWZzID0gYWdnLkdldENvbHVtbkJpbmRpbmdzKCk7CiAJCQlmb3Ig
KHNpemVfdCBpID0gMDsgaSA8IGFnZy5ncm91cHMuc2l6ZSgpOyBpKyspIHsKLQkJCQlpZiAoYWdn
Lmdyb3Vwc1tpXS0+dHlwZSA9PSBFeHByZXNzaW9uVHlwZTo6Qk9VTkRfQ09MVU1OX1JFRikgewor
CQkJCWlmIChhZ2cuZ3JvdXBzW2ldLT5HZXRFeHByZXNzaW9uVHlwZSgpID09IEV4cHJlc3Npb25U
eXBlOjpCT1VORF9DT0xVTU5fUkVGKSB7CiAJCQkJCWF1dG8gJmNvbF9yZWYgPSBhZ2cuZ3JvdXBz
W2ldLT5DYXN0PEJvdW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oKTsKIAkJCQkJcmVuYW1lX2NvbF9i
aW5kaW5ncy5pbnNlcnQoe29sZF9yZWZzW2ldLCBjb2xfcmVmLmJpbmRpbmd9KTsKIAkJCQl9CkBA
IC0xMDEsNyArMTAxLDcgQEAgdm9pZCBSb2J1c3RPcHRpbWl6ZXJDb250ZXh0U3RhdGU6OkV4dHJh
Y3RPcGVyYXRvcnNSZWN1cnNpdmUoTG9naWNhbE9wZXJhdG9yICZwbGEKIAljYXNlIExvZ2ljYWxP
cGVyYXRvclR5cGU6OkxPR0lDQUxfUFJPSkVDVElPTjogewogCQlhdXRvIG9sZF9yZWZzID0gb3At
PkdldENvbHVtbkJpbmRpbmdzKCk7CiAJCWZvciAoc2l6ZV90IGkgPSAwOyBpIDwgb3AtPmV4cHJl
c3Npb25zLnNpemUoKTsgaSsrKSB7Ci0JCQlpZiAob3AtPmV4cHJlc3Npb25zW2ldLT50eXBlID09
IEV4cHJlc3Npb25UeXBlOjpCT1VORF9DT0xVTU5fUkVGKSB7CisJCQlpZiAob3AtPmV4cHJlc3Np
b25zW2ldLT5HZXRFeHByZXNzaW9uVHlwZSgpID09IEV4cHJlc3Npb25UeXBlOjpCT1VORF9DT0xV
TU5fUkVGKSB7CiAJCQkJYXV0byAmY29sX3JlZiA9IG9wLT5leHByZXNzaW9uc1tpXS0+Q2FzdDxC
b3VuZENvbHVtblJlZkV4cHJlc3Npb24+KCk7CiAJCQkJcmVuYW1lX2NvbF9iaW5kaW5ncy5pbnNl
cnQoe29sZF9yZWZzW2ldLCBjb2xfcmVmLmJpbmRpbmd9KTsKIAkJCX0KQEAgLTE0NCwxMCArMTQ0
LDEwIEBAIENvbHVtbkJpbmRpbmcgUm9idXN0T3B0aW1pemVyQ29udGV4dFN0YXRlOjpSZXNvbHZl
Q29sdW1uQmluZGluZyhjb25zdCBDb2x1bW5CaW5kCiAKIAkvLyBmb2xsb3cgdGhlIHJlbmFtZSBj
aGFpbiB1bnRpbCB3ZSBmaW5kIGEgYmFzZSB0YWJsZSBiaW5kaW5nCiAJd2hpbGUgKHRydWUpIHsK
LQkJYXV0byBrZXkgPSBtYWtlX3BhaXIoY3VycmVudC50YWJsZV9pbmRleCwgY3VycmVudC5jb2x1
bW5faW5kZXgpOworCQlhdXRvIGtleSA9IG1ha2VfcGFpcihjdXJyZW50LnRhYmxlX2luZGV4Lmlu
ZGV4LCBjdXJyZW50LmNvbHVtbl9pbmRleCk7CiAJCWlmICh2aXNpdGVkLmNvdW50KGtleSkpIHsK
IAkJCURfUFJJTlRGKCJXQVJOSU5HOiBDeWNsZSBkZXRlY3RlZCBpbiByZW5hbWVfY29sX2JpbmRp
bmdzIGZvciBiaW5kaW5nICglbGx1LiVsbHUpIiwKLQkJCSAgICAgICAgICh1bnNpZ25lZCBsb25n
IGxvbmcpY3VycmVudC50YWJsZV9pbmRleCwgKHVuc2lnbmVkIGxvbmcgbG9uZyljdXJyZW50LmNv
bHVtbl9pbmRleCk7CisJCQkgICAgICAgICAodW5zaWduZWQgbG9uZyBsb25nKWN1cnJlbnQudGFi
bGVfaW5kZXguaW5kZXgsICh1bnNpZ25lZCBsb25nIGxvbmcpY3VycmVudC5jb2x1bW5faW5kZXgp
OwogCQkJYnJlYWs7CiAJCX0KIAkJdmlzaXRlZC5pbnNlcnQoa2V5KTsKQEAgLTE3NSw4ICsxNzUs
OCBAQCB2ZWN0b3I8Sm9pbkVkZ2U+IFJvYnVzdE9wdGltaXplckNvbnRleHRTdGF0ZTo6Q3JlYXRl
Sm9pbkVkZ2VzKHZlY3RvcjxMb2dpY2FsT3BlcgogCiAJCWZvciAoY29uc3QgSm9pbkNvbmRpdGlv
biAmY29uZCA6IGpvaW4uY29uZGl0aW9ucykgewogCQkJaWYgKGNvbmQuR2V0Q29tcGFyaXNvblR5
cGUoKSA9PSBFeHByZXNzaW9uVHlwZTo6Q09NUEFSRV9FUVVBTCAmJgotCQkJICAgIGNvbmQuR2V0
TEhTKCkudHlwZSA9PSBFeHByZXNzaW9uVHlwZTo6Qk9VTkRfQ09MVU1OX1JFRiAmJgotCQkJICAg
IGNvbmQuR2V0UkhTKCkudHlwZSA9PSBFeHByZXNzaW9uVHlwZTo6Qk9VTkRfQ09MVU1OX1JFRikg
eworCQkJICAgIGNvbmQuR2V0TEhTKCkuR2V0RXhwcmVzc2lvblR5cGUoKSA9PSBFeHByZXNzaW9u
VHlwZTo6Qk9VTkRfQ09MVU1OX1JFRiAmJgorCQkJICAgIGNvbmQuR2V0UkhTKCkuR2V0RXhwcmVz
c2lvblR5cGUoKSA9PSBFeHByZXNzaW9uVHlwZTo6Qk9VTkRfQ09MVU1OX1JFRikgewogCQkJCS8v
IHN0b3JlIG9yaWdpbmFsIGJpbmRpbmdzCiAJCQkJQ29sdW1uQmluZGluZyBsZWZ0X2JpbmRpbmcg
PSBjb25kLkdldExIUygpLkNhc3Q8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPigpLmJpbmRpbmc7
CiAJCQkJQ29sdW1uQmluZGluZyByaWdodF9iaW5kaW5nID0gY29uZC5HZXRSSFMoKS5DYXN0PEJv
dW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oKS5iaW5kaW5nOwpAQCAtMTkyLDggKzE5Miw4IEBAIHZl
Y3RvcjxKb2luRWRnZT4gUm9idXN0T3B0aW1pemVyQ29udGV4dFN0YXRlOjpDcmVhdGVKb2luRWRn
ZXModmVjdG9yPExvZ2ljYWxPcGVyCiAKIAkJaWYgKCFsZWZ0X2NvbHVtbnMuZW1wdHkoKSAmJiAh
cmlnaHRfY29sdW1ucy5lbXB0eSgpKSB7CiAJCQkvLyBnZXQgdGFibGUgaW5kaWNlcyBmcm9tIGZp
cnN0IHJlc29sdmVkIGNvbHVtbgotCQkJaWR4X3QgbGVmdF90YWJsZV9pZHggPSByZXNvbHZlZF9s
ZWZ0X2NvbHVtbnNbMF0udGFibGVfaW5kZXg7Ci0JCQlpZHhfdCByaWdodF90YWJsZV9pZHggPSBy
ZXNvbHZlZF9yaWdodF9jb2x1bW5zWzBdLnRhYmxlX2luZGV4OworCQkJaWR4X3QgbGVmdF90YWJs
ZV9pZHggPSByZXNvbHZlZF9sZWZ0X2NvbHVtbnNbMF0udGFibGVfaW5kZXguaW5kZXg7CisJCQlp
ZHhfdCByaWdodF90YWJsZV9pZHggPSByZXNvbHZlZF9yaWdodF9jb2x1bW5zWzBdLnRhYmxlX2lu
ZGV4LmluZGV4OwogCiAJCQkvLyB2ZXJpZnkgdGhlc2UgdGFibGUgaW5kaWNlcyBleGlzdCBpbiBv
dXIgdGFibGUgbWFuYWdlcgogCQkJaWYgKHRhYmxlX21nci50YWJsZV9sb29rdXAuZmluZChsZWZ0
X3RhYmxlX2lkeCkgIT0gdGFibGVfbWdyLnRhYmxlX2xvb2t1cC5lbmQoKSAmJgpAQCAtNDA3LDEz
ICs0MDcsMTMgQEAgdm9pZCBSb2J1c3RPcHRpbWl6ZXJDb250ZXh0U3RhdGU6OkRlYnVnUHJpbnRH
cmFwaChjb25zdCB2ZWN0b3I8Sm9pbkVkZ2U+ICZlZGdlcykKIAkJLy8gUHJpbnQgY29sdW1uIGJp
bmRpbmdzCiAJCXN0cmluZyBjb2xzX2EgPSAiICBDb2x1bW5zIEE6ICI7CiAJCWZvciAoY29uc3Qg
YXV0byAmY29sIDogZWRnZS5qb2luX2NvbHVtbnNfYSkgewotCQkJY29sc19hICs9ICIoIiArIHN0
ZDo6dG9fc3RyaW5nKGNvbC50YWJsZV9pbmRleCkgKyAiLiIgKyBzdGQ6OnRvX3N0cmluZyhjb2wu
Y29sdW1uX2luZGV4KSArICIpICI7CisJCQljb2xzX2EgKz0gIigiICsgc3RkOjp0b19zdHJpbmco
Y29sLnRhYmxlX2luZGV4LmluZGV4KSArICIuIiArIHN0ZDo6dG9fc3RyaW5nKGNvbC5jb2x1bW5f
aW5kZXgpICsgIikgIjsKIAkJfQogCQlQcmludGVyOjpQcmludChjb2xzX2EpOwogCiAJCXN0cmlu
ZyBjb2xzX2IgPSAiICBDb2x1bW5zIEI6ICI7CiAJCWZvciAoY29uc3QgYXV0byAmY29sIDogZWRn
ZS5qb2luX2NvbHVtbnNfYikgewotCQkJY29sc19iICs9ICIoIiArIHN0ZDo6dG9fc3RyaW5nKGNv
bC50YWJsZV9pbmRleCkgKyAiLiIgKyBzdGQ6OnRvX3N0cmluZyhjb2wuY29sdW1uX2luZGV4KSAr
ICIpICI7CisJCQljb2xzX2IgKz0gIigiICsgc3RkOjp0b19zdHJpbmcoY29sLnRhYmxlX2luZGV4
LmluZGV4KSArICIuIiArIHN0ZDo6dG9fc3RyaW5nKGNvbC5jb2x1bW5faW5kZXgpICsgIikgIjsK
IAkJfQogCQlQcmludGVyOjpQcmludChjb2xzX2IpOwogCX0KQEAgLTQ0Myw3ICs0NDMsNyBAQCB2
b2lkIFJvYnVzdE9wdGltaXplckNvbnRleHRTdGF0ZTo6RGVidWdQcmludE1TVChjb25zdCB2ZWN0
b3I8Sm9pbkVkZ2U+ICZtc3RfZWRnZQogCQkJUHJpbnRlcjo6UHJpbnRGKCJGaWx0ZXIgT3AgJXp1
OiBDUkVBVEVfRklMVEVSIG9uIHRhYmxlICVsbHUiLCBpLCAodW5zaWduZWQgbG9uZyBsb25nKWZp
bHRlcl9vcC5idWlsZF90YWJsZV9pZHgpOwogCQkJc3RyaW5nIGNvbHMgPSAiICBCdWlsZCBjb2x1
bW5zOiAiOwogCQkJZm9yIChjb25zdCBhdXRvICZjb2wgOiBmaWx0ZXJfb3AuYnVpbGRfY29sdW1u
cykgewotCQkJCWNvbHMgKz0gIigiICsgc3RkOjp0b19zdHJpbmcoY29sLnRhYmxlX2luZGV4KSAr
ICIuIiArIHN0ZDo6dG9fc3RyaW5nKGNvbC5jb2x1bW5faW5kZXgpICsgIikgIjsKKwkJCQljb2xz
ICs9ICIoIiArIHN0ZDo6dG9fc3RyaW5nKGNvbC50YWJsZV9pbmRleC5pbmRleCkgKyAiLiIgKyBz
dGQ6OnRvX3N0cmluZyhjb2wuY29sdW1uX2luZGV4KSArICIpICI7CiAJCQl9CiAJCQlQcmludGVy
OjpQcmludChjb2xzKTsKIAkJfSBlbHNlIHsKQEAgLTQ1MiwxMyArNDUyLDEzIEBAIHZvaWQgUm9i
dXN0T3B0aW1pemVyQ29udGV4dFN0YXRlOjpEZWJ1Z1ByaW50TVNUKGNvbnN0IHZlY3RvcjxKb2lu
RWRnZT4gJm1zdF9lZGdlCiAJCQkgICAgICAgICAgICAgICAgKHVuc2lnbmVkIGxvbmcgbG9uZylm
aWx0ZXJfb3AucHJvYmVfdGFibGVfaWR4LCAodW5zaWduZWQgbG9uZyBsb25nKWZpbHRlcl9vcC5i
dWlsZF90YWJsZV9pZHgpOwogCQkJc3RyaW5nIGJ1aWxkX2NvbHMgPSAiICBCdWlsZCBjb2x1bW5z
OiAiOwogCQkJZm9yIChjb25zdCBhdXRvICZjb2wgOiBmaWx0ZXJfb3AuYnVpbGRfY29sdW1ucykg
ewotCQkJCWJ1aWxkX2NvbHMgKz0gIigiICsgc3RkOjp0b19zdHJpbmcoY29sLnRhYmxlX2luZGV4
KSArICIuIiArIHN0ZDo6dG9fc3RyaW5nKGNvbC5jb2x1bW5faW5kZXgpICsgIikgIjsKKwkJCQli
dWlsZF9jb2xzICs9ICIoIiArIHN0ZDo6dG9fc3RyaW5nKGNvbC50YWJsZV9pbmRleC5pbmRleCkg
KyAiLiIgKyBzdGQ6OnRvX3N0cmluZyhjb2wuY29sdW1uX2luZGV4KSArICIpICI7CiAJCQl9CiAJ
CQlQcmludGVyOjpQcmludChidWlsZF9jb2xzKTsKIAogCQkJc3RyaW5nIHByb2JlX2NvbHMgPSAi
ICBQcm9iZSBjb2x1bW5zOiAiOwogCQkJZm9yIChjb25zdCBhdXRvICZjb2wgOiBmaWx0ZXJfb3Au
cHJvYmVfY29sdW1ucykgewotCQkJCXByb2JlX2NvbHMgKz0gIigiICsgc3RkOjp0b19zdHJpbmco
Y29sLnRhYmxlX2luZGV4KSArICIuIiArIHN0ZDo6dG9fc3RyaW5nKGNvbC5jb2x1bW5faW5kZXgp
ICsgIikgIjsKKwkJCQlwcm9iZV9jb2xzICs9ICIoIiArIHN0ZDo6dG9fc3RyaW5nKGNvbC50YWJs
ZV9pbmRleC5pbmRleCkgKyAiLiIgKyBzdGQ6OnRvX3N0cmluZyhjb2wuY29sdW1uX2luZGV4KSAr
ICIpICI7CiAJCQl9CiAJCQlQcmludGVyOjpQcmludChwcm9iZV9jb2xzKTsKIAkJfQpAQCAtNTU4
LDggKzU1OCw4IEBAIHN0YXRpYyB2b2lkIFBoeXNpY2FsREFHREZTKExvZ2ljYWxPcGVyYXRvciAq
b3AsIFRhYmxlTWFuYWdlciAmdGFibGVfbWdyLCBSb2J1c3RPCiAJCQlpZiAoY29uZC5HZXRDb21w
YXJpc29uVHlwZSgpICE9IEV4cHJlc3Npb25UeXBlOjpDT01QQVJFX0VRVUFMKSB7CiAJCQkJY29u
dGludWU7CiAJCQl9Ci0JCQlpZiAoY29uZC5HZXRMSFMoKS50eXBlICE9IEV4cHJlc3Npb25UeXBl
OjpCT1VORF9DT0xVTU5fUkVGIHx8Ci0JCQkgICAgY29uZC5HZXRSSFMoKS50eXBlICE9IEV4cHJl
c3Npb25UeXBlOjpCT1VORF9DT0xVTU5fUkVGKSB7CisJCQlpZiAoY29uZC5HZXRMSFMoKS5HZXRF
eHByZXNzaW9uVHlwZSgpICE9IEV4cHJlc3Npb25UeXBlOjpCT1VORF9DT0xVTU5fUkVGIHx8CisJ
CQkgICAgY29uZC5HZXRSSFMoKS5HZXRFeHByZXNzaW9uVHlwZSgpICE9IEV4cHJlc3Npb25UeXBl
OjpCT1VORF9DT0xVTU5fUkVGKSB7CiAJCQkJY29udGludWU7CiAJCQl9CiAKQEAgLTU2OSwxMiAr
NTY5LDEyIEBAIHN0YXRpYyB2b2lkIFBoeXNpY2FsREFHREZTKExvZ2ljYWxPcGVyYXRvciAqb3As
IFRhYmxlTWFuYWdlciAmdGFibGVfbWdyLCBSb2J1c3RPCiAJCQkgICAgc3RhdGUuUmVzb2x2ZUNv
bHVtbkJpbmRpbmcoY29uZC5HZXRSSFMoKS5DYXN0PEJvdW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4o
KS5iaW5kaW5nKTsKIAogCQkJLy8gYWRkIHRvIGVxdWl2YWxlbmNlIGNsYXNzZXMKLQkJCUNvbEtl
eSBsZWZ0X2tleSA9IHtsZWZ0X3Jlc29sdmVkLnRhYmxlX2luZGV4LCBsZWZ0X3Jlc29sdmVkLmNv
bHVtbl9pbmRleH07Ci0JCQlDb2xLZXkgcmlnaHRfa2V5ID0ge3JpZ2h0X3Jlc29sdmVkLnRhYmxl
X2luZGV4LCByaWdodF9yZXNvbHZlZC5jb2x1bW5faW5kZXh9OworCQkJQ29sS2V5IGxlZnRfa2V5
ID0ge2xlZnRfcmVzb2x2ZWQudGFibGVfaW5kZXguaW5kZXgsIGxlZnRfcmVzb2x2ZWQuY29sdW1u
X2luZGV4fTsKKwkJCUNvbEtleSByaWdodF9rZXkgPSB7cmlnaHRfcmVzb2x2ZWQudGFibGVfaW5k
ZXguaW5kZXgsIHJpZ2h0X3Jlc29sdmVkLmNvbHVtbl9pbmRleH07CiAJCQlVRlVuaW9uKHVmX3Bh
cmVudCwgbGVmdF9rZXksIHJpZ2h0X2tleSk7CiAKLQkJCWlkeF90IHRhYmxlX2EgPSBsZWZ0X3Jl
c29sdmVkLnRhYmxlX2luZGV4OwotCQkJaWR4X3QgdGFibGVfYiA9IHJpZ2h0X3Jlc29sdmVkLnRh
YmxlX2luZGV4OworCQkJaWR4X3QgdGFibGVfYSA9IGxlZnRfcmVzb2x2ZWQudGFibGVfaW5kZXgu
aW5kZXg7CisJCQlpZHhfdCB0YWJsZV9iID0gcmlnaHRfcmVzb2x2ZWQudGFibGVfaW5kZXguaW5k
ZXg7CiAJCQlpZiAoIW5vZGVfbWFwLmNvdW50KHRhYmxlX2EpIHx8ICFub2RlX21hcC5jb3VudCh0
YWJsZV9iKSkgewogCQkJCWNvbnRpbnVlOwogCQkJfQpAQCAtNjAxLDcgKzYwMSw3IEBAIHN0YXRp
YyB2b2lkIFBoeXNpY2FsREFHREZTKExvZ2ljYWxPcGVyYXRvciAqb3AsIFRhYmxlTWFuYWdlciAm
dGFibGVfbWdyLCBSb2J1c3RPCiAJCQl9CiAKIAkJCS8vIGVxdWl2IHJlc29sdXRpb24gb24gY2hp
bGQgc2lkZTogZmluZCBzaGFsbG93ZXN0IGVxdWl2YWxlbnQgKGhpZ2hlc3QgREZTLCAhPSBwYXJl
bnQpCi0JCQlDb2xLZXkgY2hpbGRfcm9vdCA9IFVGRmluZCh1Zl9wYXJlbnQsIHtjaGlsZF9jb2wu
dGFibGVfaW5kZXgsIGNoaWxkX2NvbC5jb2x1bW5faW5kZXh9KTsKKwkJCUNvbEtleSBjaGlsZF9y
b290ID0gVUZGaW5kKHVmX3BhcmVudCwge2NoaWxkX2NvbC50YWJsZV9pbmRleC5pbmRleCwgY2hp
bGRfY29sLmNvbHVtbl9pbmRleH0pOwogCQkJaWR4X3QgYmVzdF9jaGlsZCA9IGNoaWxkX2lkeDsK
IAkJCWludCBiZXN0X2NoaWxkX2RmcyA9IGRmc19pbmRleC5jb3VudChjaGlsZF9pZHgpID8gZGZz
X2luZGV4W2NoaWxkX2lkeF0gOiAtMTsKIAkJCUNvbHVtbkJpbmRpbmcgYmVzdF9jaGlsZF9jb2wg
PSBjaGlsZF9jb2w7CkBAIC02MjUsNyArNjI1LDcgQEAgc3RhdGljIHZvaWQgUGh5c2ljYWxEQUdE
RlMoTG9naWNhbE9wZXJhdG9yICpvcCwgVGFibGVNYW5hZ2VyICZ0YWJsZV9tZ3IsIFJvYnVzdE8K
IAkJCQlpZiAoY2FuZGlkYXRlX2RmcyA+IGJlc3RfY2hpbGRfZGZzKSB7CiAJCQkJCWJlc3RfY2hp
bGQgPSBjYW5kaWRhdGU7CiAJCQkJCWJlc3RfY2hpbGRfZGZzID0gY2FuZGlkYXRlX2RmczsKLQkJ
CQkJYmVzdF9jaGlsZF9jb2wgPSBDb2x1bW5CaW5kaW5nKGtleS5maXJzdCwga2V5LnNlY29uZCk7
CisJCQkJCWJlc3RfY2hpbGRfY29sID0gQ29sdW1uQmluZGluZyhUYWJsZUluZGV4KGtleS5maXJz
dCksIFByb2plY3Rpb25JbmRleChrZXkuc2Vjb25kKSk7CiAJCQkJfQogCQkJfQogCkBAIC0xMDk5
LDcgKzEwOTksNyBAQCBSb2J1c3RPcHRpbWl6ZXJDb250ZXh0U3RhdGU6OkdlbmVyYXRlU3RhZ2VN
b2RpZmljYXRpb25zRnJvbURBRyh2ZWN0b3I8UGh5c2ljYWxEQQogCQkJCWF1dG8gKnBhcmVudF9u
b2RlID0gY2hpbGRfbm9kZS0+cGFyZW50c1tlaV07CiAKIAkJCQkvLyBkZXRlcm1pbmUgdGhlIGVx
dWl2YWxlbmNlIGNsYXNzIGZvciB0aGlzIGVkZ2UgdXNpbmcgdGhlIGZpcnN0IGNvbHVtbiBwYWly
Ci0JCQkJQ29sS2V5IHBhcmVudF9jb2xfa2V5ID0ge2VkZ2UucGFyZW50X2NvbHNbMF0udGFibGVf
aW5kZXgsIGVkZ2UucGFyZW50X2NvbHNbMF0uY29sdW1uX2luZGV4fTsKKwkJCQlDb2xLZXkgcGFy
ZW50X2NvbF9rZXkgPSB7ZWRnZS5wYXJlbnRfY29sc1swXS50YWJsZV9pbmRleC5pbmRleCwgZWRn
ZS5wYXJlbnRfY29sc1swXS5jb2x1bW5faW5kZXh9OwogCQkJCUNvbEtleSBlcXVpdl9yb290ID0g
VUZGaW5kKHVmX3BhcmVudCwgcGFyZW50X2NvbF9rZXkpOwogCiAJCQkJYXV0byBpdCA9IGVxdWl2
X2NsYXNzX2JmX3NvdXJjZS5maW5kKGVxdWl2X3Jvb3QpOwpAQCAtMTMyNCw3ICsxMzI0LDcgQEAg
dm9pZCBSb2J1c3RPcHRpbWl6ZXJDb250ZXh0U3RhdGU6OkxpbmtQcm9iZUZpbHRlclRvQ3JlYXRl
RmlsdGVyKExvZ2ljYWxPcGVyYXRvcgogCQlzaXplX3Qgb3BlcmF0b3IoKShjb25zdCBDcmVhdGVG
aWx0ZXJLZXkgJmtleSkgY29uc3QgewogCQkJc2l6ZV90IGhhc2ggPSBzdGQ6Omhhc2g8aWR4X3Q+
KCkoa2V5LmJ1aWxkX3RhYmxlX2lkeCk7CiAJCQlmb3IgKGNvbnN0IGF1dG8gJmNvbCA6IGtleS5i
dWlsZF9jb2x1bW5zKSB7Ci0JCQkJaGFzaCBePSAoc3RkOjpoYXNoPGlkeF90PigpKGNvbC50YWJs
ZV9pbmRleCkgPDwgMSk7CisJCQkJaGFzaCBePSAoc3RkOjpoYXNoPFRhYmxlSW5kZXg+KCkoY29s
LnRhYmxlX2luZGV4KSA8PCAxKTsKIAkJCQloYXNoIF49IChzdGQ6Omhhc2g8aWR4X3Q+KCkoY29s
LmNvbHVtbl9pbmRleCkgPDwgMik7CiAJCQl9CiAJCQlyZXR1cm4gaGFzaDsKQEAgLTEzNzAsNyAr
MTM3MCw3IEBAIHZvaWQgUm9idXN0T3B0aW1pemVyQ29udGV4dFN0YXRlOjpMaW5rUHJvYmVGaWx0
ZXJUb0NyZWF0ZUZpbHRlcihMb2dpY2FsT3BlcmF0b3IKIAkJCQlpZiAoaXQgIT0gY3JlYXRlX2Zp
bHRlcl9ieV90YWJsZS5lbmQoKSkgewogCQkJCQlmb3IgKGF1dG8gKmNyZWF0ZV9maWx0ZXIgOiBp
dC0+c2Vjb25kKSB7CiAJCQkJCQlmb3IgKGNvbnN0IGF1dG8gJnBjIDogY3JlYXRlX2ZpbHRlci0+
ZmlsdGVyX29wZXJhdGlvbi5wcm9iZV9jb2x1bW5zKSB7Ci0JCQkJCQkJaWYgKHBjLnRhYmxlX2lu
ZGV4ID09IHByb2JlX3RhYmxlX2lkeCkgeworCQkJCQkJCWlmIChwYy50YWJsZV9pbmRleC5pbmRl
eCA9PSBwcm9iZV90YWJsZV9pZHgpIHsKIAkJCQkJCQkJcHJvYmVfZmlsdGVyLT5yZWxhdGVkX2Ny
ZWF0ZV9maWx0ZXIgPSBjcmVhdGVfZmlsdGVyOwogCQkJCQkJCQljcmVhdGVfZmlsdGVyLT5yZWxh
dGVkX3Byb2JlX2ZpbHRlci5wdXNoX2JhY2socHJvYmVfZmlsdGVyKTsKIAkJCQkJCQkJYnJlYWs7
CkBAIC0xNDY1LDcgKzE0NjUsNyBAQCB2b2lkIFJvYnVzdE9wdGltaXplckNvbnRleHRTdGF0ZTo6
U2V0dXBEeW5hbWljRmlsdGVyUHVzaGRvd24oTG9naWNhbE9wZXJhdG9yICpwbAogCQkJCWlkeF90
IHNjYW5fY29sX2lkeCA9IHByb2JlX2NvbC5jb2x1bW5faW5kZXg7CiAJCQkJaWYgKHNjYW5fY29s
X2lkeCA+PSBjb2xfaWRzLnNpemUoKSkgewogCQkJCQlEX1BSSU5URigiW1BVU0hET1dOXSBwcm9i
ZSBjb2x1bW4gKCVsbHUuJWxsdSkgb3V0IG9mIGJvdW5kcyBmb3Igc2NhbiBjb2x1bW5faWRzIChz
aXplPSV6dSkiLAotCQkJCQkgICAgICAgICAodW5zaWduZWQgbG9uZyBsb25nKXByb2JlX2NvbC50
YWJsZV9pbmRleCwgKHVuc2lnbmVkIGxvbmcgbG9uZylwcm9iZV9jb2wuY29sdW1uX2luZGV4LAor
CQkJCQkgICAgICAgICAodW5zaWduZWQgbG9uZyBsb25nKXByb2JlX2NvbC50YWJsZV9pbmRleC5p
bmRleCwgKHVuc2lnbmVkIGxvbmcgbG9uZylwcm9iZV9jb2wuY29sdW1uX2luZGV4LAogCQkJCQkg
ICAgICAgICBjb2xfaWRzLnNpemUoKSk7CiAJCQkJCWNvbnRpbnVlOwogCQkJCX0KZGlmZiAtLWdp
dCBhL3NyYy9vcHRpbWl6ZXIvdGFibGVfbWFuYWdlci5jcHAgYi9zcmMvb3B0aW1pemVyL3RhYmxl
X21hbmFnZXIuY3BwCmluZGV4IDA1YWUwMDAuLmU0YWRkMTggMTAwNjQ0Ci0tLSBhL3NyYy9vcHRp
bWl6ZXIvdGFibGVfbWFuYWdlci5jcHAKKysrIGIvc3JjL29wdGltaXplci90YWJsZV9tYW5hZ2Vy
LmNwcApAQCAtNDgsMTMgKzQ4LDEzIEBAIGlkeF90IFRhYmxlTWFuYWdlcjo6R2V0U2NhbGFyVGFi
bGVJbmRleChMb2dpY2FsT3BlcmF0b3IgKm9wKSB7CiAJY2FzZSBMb2dpY2FsT3BlcmF0b3JUeXBl
OjpMT0dJQ0FMX1VOSU9OOgogCWNhc2UgTG9naWNhbE9wZXJhdG9yVHlwZTo6TE9HSUNBTF9FWENF
UFQ6CiAJY2FzZSBMb2dpY2FsT3BlcmF0b3JUeXBlOjpMT0dJQ0FMX0lOVEVSU0VDVDogewotCQly
ZXR1cm4gb3AtPkdldFRhYmxlSW5kZXgoKVswXTsKKwkJcmV0dXJuIG9wLT5HZXRUYWJsZUluZGV4
KClbMF0uaW5kZXg7CiAJfQogCWNhc2UgTG9naWNhbE9wZXJhdG9yVHlwZTo6TE9HSUNBTF9GSUxU
RVI6IHsKIAkJcmV0dXJuIEdldFNjYWxhclRhYmxlSW5kZXgob3AtPmNoaWxkcmVuWzBdLmdldCgp
KTsKIAl9CiAJY2FzZSBMb2dpY2FsT3BlcmF0b3JUeXBlOjpMT0dJQ0FMX0FHR1JFR0FURV9BTkRf
R1JPVVBfQlk6IHsKLQkJcmV0dXJuIG9wLT5HZXRUYWJsZUluZGV4KClbMV07CisJCXJldHVybiBv
cC0+R2V0VGFibGVJbmRleCgpWzFdLmluZGV4OwogCX0KIAlkZWZhdWx0OgogCQlyZXR1cm4gc3Rk
OjpudW1lcmljX2xpbWl0czxpZHhfdD46Om1heCgpOwpkaWZmIC0tZ2l0IGEvc3JjL3RyYW5zZmVy
X2dyYXBoX21hbmFnZXIuaHBwIGIvc3JjL3RyYW5zZmVyX2dyYXBoX21hbmFnZXIuaHBwCmluZGV4
IGVhNjAxOWMuLjg1OGRjZWMgMTAwNjQ0Ci0tLSBhL3NyYy90cmFuc2Zlcl9ncmFwaF9tYW5hZ2Vy
LmhwcAorKysgYi9zcmMvdHJhbnNmZXJfZ3JhcGhfbWFuYWdlci5ocHAKQEAgLTY1LDcgKzY1LDcg
QEAgc3RydWN0IEpvaW5LZXlUYWJsZUdyb3VwIHsKIAogc3RydWN0IENvbHVtbkJpbmRpbmdIYXNo
RnVuYyB7CiAJc2l6ZV90IG9wZXJhdG9yKCkoY29uc3QgQ29sdW1uQmluZGluZyAma2V5KSBjb25z
dCB7Ci0JCXJldHVybiBzdGQ6Omhhc2g8dWludDY0X3Q+IHt9KGtleS50YWJsZV9pbmRleCkgXiAo
c3RkOjpoYXNoPHVpbnQ2NF90PiB7fShrZXkuY29sdW1uX2luZGV4KSA8PCAxKTsKKwkJcmV0dXJu
IHN0ZDo6aGFzaDxUYWJsZUluZGV4PiB7fShrZXkudGFibGVfaW5kZXgpIF4gKHN0ZDo6aGFzaDx1
aW50NjRfdD4ge30oa2V5LmNvbHVtbl9pbmRleCkgPDwgMSk7CiAJfQogfTsKIAo=
PATCH_B64
fi
if [ "$WITH_ROBUST_RPT" = true ] && [ "$ROBUST_PATCH_EXCEPTION_SAFE_CLEANUP" = true ]; then
    cat > .github/patches/extensions/robust/exception_safe_cleanup.patch << 'PATCH_EOF'
--- a/src/optimizer/robust_optimizer.cpp
+++ b/src/optimizer/robust_optimizer.cpp
@@ -1705,6 +1705,13 @@
 
 	const auto optimizer_state =
 	    input.context.registered_state->GetOrCreate<RobustOptimizerContextState>("robust_optimizer_state", input.context);
+	struct RobustOptimizerStateCleanup {
+		ClientContext &context;
+		~RobustOptimizerStateCleanup() {
+			context.registered_state->Remove("robust_optimizer_state");
+		}
+	} cleanup {input.context};
+
 	plan = optimizer_state->Optimize(std::move(plan));
 
 	if (profiling) {
@@ -1717,8 +1724,6 @@
 			profiling->table_names[ti.table_idx] = optimizer_state->table_mgr.GetTableName(ti.table_idx);
 		}
 	}
-
-	input.context.registered_state->Remove("robust_optimizer_state");
 }
 
 } // namespace duckdb
PATCH_EOF
fi

if [ "$WITH_ROBUST_RPT" = true ] && [ "$ROBUST_PATCH_PROBE_EMPTY_REGISTRY_CLEANUP" = true ]; then
    cat > .github/patches/extensions/robust/probe_empty_registry_cleanup.patch << 'PATCH_EOF'
--- a/src/include/probe_empty_registry.hpp
+++ b/src/include/probe_empty_registry.hpp
@@ -23,6 +23,12 @@
 		return flag;
 	}
 
+	void QueryEnd(ClientContext &context) override {
+		lock_guard<mutex> guard(registry_lock);
+		flags.clear();
+		context.registered_state->Remove("robust_probe_empty_registry");
+	}
+
 private:
 	mutex registry_lock;
 	unordered_map<idx_t, shared_ptr<std::atomic<bool>>> flags;
PATCH_EOF
fi

if [ "$WITH_ROBUST_RPT" = true ] && [ "$ROBUST_PATCH_SKIP_COPY_OPTIMIZATION" = true ]; then
    cat > .github/patches/extensions/robust/skip_copy_optimization.patch << 'PATCH_EOF'
--- a/src/optimizer/robust_optimizer.cpp
+++ b/src/optimizer/robust_optimizer.cpp
@@ -1700,6 +1700,11 @@
 }
 
 void RobustOptimizerContextState::Optimize(OptimizerExtensionInput &input, unique_ptr<LogicalOperator> &plan) {
+	if (plan->type == LogicalOperatorType::LOGICAL_COPY_TO_FILE ||
+	    plan->type == LogicalOperatorType::LOGICAL_COPY_DATABASE) {
+		return;
+	}
+
 	auto profiling = GetRobustProfilingState(input.context);
 	auto opt_start = std::chrono::high_resolution_clock::now();
 
PATCH_EOF
fi


if [ "$WITH_AGGJOIN" = true ]; then
    mkdir -p .github/patches/extensions/aggjoin
    base64 -d > .github/patches/extensions/aggjoin/current-duckdb-compat.patch << 'PATCH_B64'
ZGlmZiAtLWdpdCBhL3NyYy9hZ2dqb2luX2VtaXQuY3BwIGIvc3JjL2FnZ2pvaW5fZW1pdC5jcHAK
aW5kZXggYzEyMDAzZS4uZWU3Y2UxYiAxMDA2NDQKLS0tIGEvc3JjL2FnZ2pvaW5fZW1pdC5jcHAK
KysrIGIvc3JjL2FnZ2pvaW5fZW1pdC5jcHAKQEAgLTE5NCwxOSArMTk0LDE5IEBAIFNvdXJjZVJl
c3VsdFR5cGUgUGh5c2ljYWxBZ2dKb2luOjpBR0dKT0lOX0dFVERBVEEoRXhlY3V0aW9uQ29udGV4
dCAmY3R4LCBEYXRhQ2h1CiAgICAgICAgICAgICAgICAgYXV0byBjb21wcmVzc2VkID0gcmF3X2lu
dCAtIGNvbC5ncm91cF9jb21wcmVzc1tnXS5vZmZzZXQ7CiAgICAgICAgICAgICAgICAgc3dpdGNo
IChjb2wuZ3JvdXBfY29tcHJlc3NbZ10uY29tcHJlc3NlZF90eXBlLkludGVybmFsVHlwZSgpKSB7
CiAgICAgICAgICAgICAgICAgY2FzZSBQaHlzaWNhbFR5cGU6OlVJTlQ4OgotICAgICAgICAgICAg
ICAgICAgICBGbGF0VmVjdG9yOjpHZXREYXRhPHVpbnQ4X3Q+KGNodW5rLmRhdGFbZ10pW2NudF0g
PSAodWludDhfdCljb21wcmVzc2VkOworICAgICAgICAgICAgICAgICAgICBGbGF0VmVjdG9yOjpH
ZXREYXRhTXV0YWJsZTx1aW50OF90PihjaHVuay5kYXRhW2ddKVtjbnRdID0gKHVpbnQ4X3QpY29t
cHJlc3NlZDsKICAgICAgICAgICAgICAgICAgICAgYnJlYWs7CiAgICAgICAgICAgICAgICAgY2Fz
ZSBQaHlzaWNhbFR5cGU6OlVJTlQxNjoKLSAgICAgICAgICAgICAgICAgICAgRmxhdFZlY3Rvcjo6
R2V0RGF0YTx1aW50MTZfdD4oY2h1bmsuZGF0YVtnXSlbY250XSA9ICh1aW50MTZfdCljb21wcmVz
c2VkOworICAgICAgICAgICAgICAgICAgICBGbGF0VmVjdG9yOjpHZXREYXRhTXV0YWJsZTx1aW50
MTZfdD4oY2h1bmsuZGF0YVtnXSlbY250XSA9ICh1aW50MTZfdCljb21wcmVzc2VkOwogICAgICAg
ICAgICAgICAgICAgICBicmVhazsKICAgICAgICAgICAgICAgICBjYXNlIFBoeXNpY2FsVHlwZTo6
VUlOVDMyOgotICAgICAgICAgICAgICAgICAgICBGbGF0VmVjdG9yOjpHZXREYXRhPHVpbnQzMl90
PihjaHVuay5kYXRhW2ddKVtjbnRdID0gKHVpbnQzMl90KWNvbXByZXNzZWQ7CisgICAgICAgICAg
ICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPHVpbnQzMl90PihjaHVuay5kYXRh
W2ddKVtjbnRdID0gKHVpbnQzMl90KWNvbXByZXNzZWQ7CiAgICAgICAgICAgICAgICAgICAgIGJy
ZWFrOwogICAgICAgICAgICAgICAgIGNhc2UgUGh5c2ljYWxUeXBlOjpVSU5UNjQ6Ci0gICAgICAg
ICAgICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERhdGE8dWludDY0X3Q+KGNodW5rLmRhdGFbZ10p
W2NudF0gPSAodWludDY0X3QpY29tcHJlc3NlZDsKKyAgICAgICAgICAgICAgICAgICAgRmxhdFZl
Y3Rvcjo6R2V0RGF0YU11dGFibGU8dWludDY0X3Q+KGNodW5rLmRhdGFbZ10pW2NudF0gPSAodWlu
dDY0X3QpY29tcHJlc3NlZDsKICAgICAgICAgICAgICAgICAgICAgYnJlYWs7CiAgICAgICAgICAg
ICAgICAgZGVmYXVsdDoKLSAgICAgICAgICAgICAgICAgICAgRmxhdFZlY3Rvcjo6R2V0RGF0YTxp
bnQzMl90PihjaHVuay5kYXRhW2ddKVtjbnRdID0gKGludDMyX3QpcmF3X2ludDsKKyAgICAgICAg
ICAgICAgICAgICAgRmxhdFZlY3Rvcjo6R2V0RGF0YU11dGFibGU8aW50MzJfdD4oY2h1bmsuZGF0
YVtnXSlbY250XSA9IChpbnQzMl90KXJhd19pbnQ7CiAgICAgICAgICAgICAgICAgICAgIGJyZWFr
OwogICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgIH0gZWxzZSBpZiAocmh0Lkdyb3VwVXNl
c1ZhbHVlKGcpKSB7CkBAIC0yMTYsMjMgKzIxNiwyMyBAQCBTb3VyY2VSZXN1bHRUeXBlIFBoeXNp
Y2FsQWdnSm9pbjo6QUdHSk9JTl9HRVREQVRBKEV4ZWN1dGlvbkNvbnRleHQgJmN0eCwgRGF0YUNo
dQogICAgICAgICAgICAgICAgIGF1dG8gdmFsID0gcmh0Lkdyb3VwSW50KGcsIHNsb3QpOwogICAg
ICAgICAgICAgICAgIHN3aXRjaCAob3V0X3R5cGUpIHsKICAgICAgICAgICAgICAgICBjYXNlIFBo
eXNpY2FsVHlwZTo6SU5UMzI6Ci0gICAgICAgICAgICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERh
dGE8aW50MzJfdD4oY2h1bmsuZGF0YVtnXSlbY250XSA9IChpbnQzMl90KXZhbDsKKyAgICAgICAg
ICAgICAgICAgICAgRmxhdFZlY3Rvcjo6R2V0RGF0YU11dGFibGU8aW50MzJfdD4oY2h1bmsuZGF0
YVtnXSlbY250XSA9IChpbnQzMl90KXZhbDsKICAgICAgICAgICAgICAgICAgICAgYnJlYWs7CiAg
ICAgICAgICAgICAgICAgY2FzZSBQaHlzaWNhbFR5cGU6OklOVDY0OgotICAgICAgICAgICAgICAg
ICAgICBGbGF0VmVjdG9yOjpHZXREYXRhPGludDY0X3Q+KGNodW5rLmRhdGFbZ10pW2NudF0gPSB2
YWw7CisgICAgICAgICAgICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGludDY0
X3Q+KGNodW5rLmRhdGFbZ10pW2NudF0gPSB2YWw7CiAgICAgICAgICAgICAgICAgICAgIGJyZWFr
OwogICAgICAgICAgICAgICAgIGNhc2UgUGh5c2ljYWxUeXBlOjpVSU5UMzI6Ci0gICAgICAgICAg
ICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERhdGE8dWludDMyX3Q+KGNodW5rLmRhdGFbZ10pW2Nu
dF0gPSAodWludDMyX3QpdmFsOworICAgICAgICAgICAgICAgICAgICBGbGF0VmVjdG9yOjpHZXRE
YXRhTXV0YWJsZTx1aW50MzJfdD4oY2h1bmsuZGF0YVtnXSlbY250XSA9ICh1aW50MzJfdCl2YWw7
CiAgICAgICAgICAgICAgICAgICAgIGJyZWFrOwogICAgICAgICAgICAgICAgIGNhc2UgUGh5c2lj
YWxUeXBlOjpVSU5UNjQ6Ci0gICAgICAgICAgICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERhdGE8
dWludDY0X3Q+KGNodW5rLmRhdGFbZ10pW2NudF0gPSAodWludDY0X3QpdmFsOworICAgICAgICAg
ICAgICAgICAgICBGbGF0VmVjdG9yOjpHZXREYXRhTXV0YWJsZTx1aW50NjRfdD4oY2h1bmsuZGF0
YVtnXSlbY250XSA9ICh1aW50NjRfdCl2YWw7CiAgICAgICAgICAgICAgICAgICAgIGJyZWFrOwog
ICAgICAgICAgICAgICAgIGRlZmF1bHQ6CiAgICAgICAgICAgICAgICAgICAgIGNodW5rLmRhdGFb
Z10uU2V0VmFsdWUoY250LCBWYWx1ZTo6QklHSU5UKHZhbCkpOwogICAgICAgICAgICAgICAgICAg
ICBicmVhazsKICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICB9IGVsc2UgewotICAgICAg
ICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERhdGE8ZG91YmxlPihjaHVuay5kYXRhW2ddKVtjbnRd
ID0gcmh0Lkdyb3VwRGJsKGcsIHNsb3QpOworICAgICAgICAgICAgICAgIEZsYXRWZWN0b3I6Okdl
dERhdGFNdXRhYmxlPGRvdWJsZT4oY2h1bmsuZGF0YVtnXSlbY250XSA9IHJodC5Hcm91cERibChn
LCBzbG90KTsKICAgICAgICAgICAgIH0KICAgICAgICAgfQogICAgICAgICBmb3IgKGlkeF90IGEg
PSAwOyBhIDwgbmE7IGErKykgewpkaWZmIC0tZ2l0IGEvc3JjL2FnZ2pvaW5fZW1pdF9kaXJlY3Qu
Y3BwIGIvc3JjL2FnZ2pvaW5fZW1pdF9kaXJlY3QuY3BwCmluZGV4IGNjMGMxOTQuLjlmNTFmN2Mg
MTAwNjQ0Ci0tLSBhL3NyYy9hZ2dqb2luX2VtaXRfZGlyZWN0LmNwcAorKysgYi9zcmMvYWdnam9p
bl9lbWl0X2RpcmVjdC5jcHAKQEAgLTI2LDIyICsyNiwyMiBAQCBib29sIFRyeUVtaXREaXJlY3RM
aWtlUmVzdWx0KGNvbnN0IFBoeXNpY2FsQWdnSm9pbiAmb3AsIERhdGFDaHVuayAmY2h1bmssIEFn
Z0pvaQogICAgICAgICAgICAgYXV0byBjb21wcmVzc19vZmZzZXQgPSBjaS5vZmZzZXQ7CiAgICAg
ICAgICAgICBzd2l0Y2ggKGNpLmNvbXByZXNzZWRfdHlwZS5JbnRlcm5hbFR5cGUoKSkgewogICAg
ICAgICAgICAgY2FzZSBQaHlzaWNhbFR5cGU6OlVJTlQ4OiB7Ci0gICAgICAgICAgICAgICAgYXV0
byAqZHN0ID0gRmxhdFZlY3Rvcjo6R2V0RGF0YTx1aW50OF90PihjaHVuay5kYXRhWzBdKTsKKyAg
ICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhTXV0YWJsZTx1aW50
OF90PihjaHVuay5kYXRhWzBdKTsKICAgICAgICAgICAgICAgICBmb3IgKGlkeF90IGkgPSAwOyBp
IDwgYmF0Y2g7IGkrKykgZHN0W2ldID0gKHVpbnQ4X3QpKChpbnQ2NF90KXNyYy5kaXJlY3Rfa2V5
c1tzcmMucG9zICsgaV0gKyBzaW5rLmtleV9taW4gLSBjb21wcmVzc19vZmZzZXQpOwogICAgICAg
ICAgICAgICAgIGJyZWFrOwogICAgICAgICAgICAgfQogICAgICAgICAgICAgY2FzZSBQaHlzaWNh
bFR5cGU6OlVJTlQxNjogewotICAgICAgICAgICAgICAgIGF1dG8gKmRzdCA9IEZsYXRWZWN0b3I6
OkdldERhdGE8dWludDE2X3Q+KGNodW5rLmRhdGFbMF0pOworICAgICAgICAgICAgICAgIGF1dG8g
KmRzdCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPHVpbnQxNl90PihjaHVuay5kYXRhWzBd
KTsKICAgICAgICAgICAgICAgICBmb3IgKGlkeF90IGkgPSAwOyBpIDwgYmF0Y2g7IGkrKykgZHN0
W2ldID0gKHVpbnQxNl90KSgoaW50NjRfdClzcmMuZGlyZWN0X2tleXNbc3JjLnBvcyArIGldICsg
c2luay5rZXlfbWluIC0gY29tcHJlc3Nfb2Zmc2V0KTsKICAgICAgICAgICAgICAgICBicmVhazsK
ICAgICAgICAgICAgIH0KICAgICAgICAgICAgIGNhc2UgUGh5c2ljYWxUeXBlOjpVSU5UMzI6IHsK
LSAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhPHVpbnQzMl90
PihjaHVuay5kYXRhWzBdKTsKKyAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9y
OjpHZXREYXRhTXV0YWJsZTx1aW50MzJfdD4oY2h1bmsuZGF0YVswXSk7CiAgICAgICAgICAgICAg
ICAgZm9yIChpZHhfdCBpID0gMDsgaSA8IGJhdGNoOyBpKyspIGRzdFtpXSA9ICh1aW50MzJfdCko
KGludDY0X3Qpc3JjLmRpcmVjdF9rZXlzW3NyYy5wb3MgKyBpXSArIHNpbmsua2V5X21pbiAtIGNv
bXByZXNzX29mZnNldCk7CiAgICAgICAgICAgICAgICAgYnJlYWs7CiAgICAgICAgICAgICB9CiAg
ICAgICAgICAgICBkZWZhdWx0OiB7Ci0gICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZl
Y3Rvcjo6R2V0RGF0YTxpbnQzMl90PihjaHVuay5kYXRhWzBdKTsKKyAgICAgICAgICAgICAgICBh
dXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhTXV0YWJsZTxpbnQzMl90PihjaHVuay5kYXRh
WzBdKTsKICAgICAgICAgICAgICAgICBmb3IgKGlkeF90IGkgPSAwOyBpIDwgYmF0Y2g7IGkrKykg
ZHN0W2ldID0gKGludDMyX3QpKChpbnQ2NF90KXNyYy5kaXJlY3Rfa2V5c1tzcmMucG9zICsgaV0g
KyBzaW5rLmtleV9taW4pOwogICAgICAgICAgICAgICAgIGJyZWFrOwogICAgICAgICAgICAgfQpA
QCAtNTAsMTIgKzUwLDEyIEBAIGJvb2wgVHJ5RW1pdERpcmVjdExpa2VSZXN1bHQoY29uc3QgUGh5
c2ljYWxBZ2dKb2luICZvcCwgRGF0YUNodW5rICZjaHVuaywgQWdnSm9pCiAgICAgICAgICAgICBh
dXRvIG91dF90eXBlID0gY2h1bmsuZGF0YVswXS5HZXRUeXBlKCkuSW50ZXJuYWxUeXBlKCk7CiAg
ICAgICAgICAgICBzd2l0Y2ggKG91dF90eXBlKSB7CiAgICAgICAgICAgICBjYXNlIFBoeXNpY2Fs
VHlwZTo6SU5UMzI6IHsKLSAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpH
ZXREYXRhPGludDMyX3Q+KGNodW5rLmRhdGFbMF0pOworICAgICAgICAgICAgICAgIGF1dG8gKmRz
dCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGludDMyX3Q+KGNodW5rLmRhdGFbMF0pOwog
ICAgICAgICAgICAgICAgIGZvciAoaWR4X3QgaSA9IDA7IGkgPCBiYXRjaDsgaSsrKSBkc3RbaV0g
PSAoaW50MzJfdCkoKGludDY0X3Qpc3JjLmRpcmVjdF9rZXlzW3NyYy5wb3MgKyBpXSArIHNpbmsu
a2V5X21pbik7CiAgICAgICAgICAgICAgICAgYnJlYWs7CiAgICAgICAgICAgICB9CiAgICAgICAg
ICAgICBjYXNlIFBoeXNpY2FsVHlwZTo6SU5UNjQ6IHsKLSAgICAgICAgICAgICAgICBhdXRvICpk
c3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhPGludDY0X3Q+KGNodW5rLmRhdGFbMF0pOworICAgICAg
ICAgICAgICAgIGF1dG8gKmRzdCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGludDY0X3Q+
KGNodW5rLmRhdGFbMF0pOwogICAgICAgICAgICAgICAgIGZvciAoaWR4X3QgaSA9IDA7IGkgPCBi
YXRjaDsgaSsrKSBkc3RbaV0gPSAoaW50NjRfdClzcmMuZGlyZWN0X2tleXNbc3JjLnBvcyArIGld
ICsgc2luay5rZXlfbWluOwogICAgICAgICAgICAgICAgIGJyZWFrOwogICAgICAgICAgICAgfQpA
QCAtNjgsOCArNjgsOCBAQCBib29sIFRyeUVtaXREaXJlY3RMaWtlUmVzdWx0KGNvbnN0IFBoeXNp
Y2FsQWdnSm9pbiAmb3AsIERhdGFDaHVuayAmY2h1bmssIEFnZ0pvaQogICAgICAgICAgICAgYXV0
byAmZiA9IGNvbC5hZ2dfZnVuY3NbYV07CiAgICAgICAgICAgICBhdXRvIG91dF9pZHggPSAxICsg
YTsKICAgICAgICAgICAgIGF1dG8gb3V0X3R5cGUgPSBjaHVuay5kYXRhW291dF9pZHhdLkdldFR5
cGUoKS5JbnRlcm5hbFR5cGUoKTsKLSAgICAgICAgICAgIGF1dG8gKmRzdCA9IChvdXRfdHlwZSA9
PSBQaHlzaWNhbFR5cGU6OklOVDY0KSA/IG51bGxwdHIgOiBGbGF0VmVjdG9yOjpHZXREYXRhPGRv
dWJsZT4oY2h1bmsuZGF0YVtvdXRfaWR4XSk7Ci0gICAgICAgICAgICBhdXRvICZ2YWxpZGl0eSA9
IEZsYXRWZWN0b3I6OlZhbGlkaXR5KGNodW5rLmRhdGFbb3V0X2lkeF0pOworICAgICAgICAgICAg
YXV0byAqZHN0ID0gKG91dF90eXBlID09IFBoeXNpY2FsVHlwZTo6SU5UNjQpID8gbnVsbHB0ciA6
IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGRvdWJsZT4oY2h1bmsuZGF0YVtvdXRfaWR4XSk7
CisgICAgICAgICAgICBhdXRvICZ2YWxpZGl0eSA9IEZsYXRWZWN0b3I6OlZhbGlkaXR5TXV0YWJs
ZShjaHVuay5kYXRhW291dF9pZHhdKTsKICAgICAgICAgICAgIGZvciAoaWR4X3QgaSA9IDA7IGkg
PCBiYXRjaDsgaSsrKSB7CiAgICAgICAgICAgICAgICAgYXV0byBrID0gc3JjLmRpcmVjdF9rZXlz
W3NyYy5wb3MgKyBpXTsKICAgICAgICAgICAgICAgICBhdXRvIHNlZyA9IGsgPj4gc2luay5zZWdt
ZW50ZWRfc2hpZnQ7CkBAIC0xNzIsMjcgKzE3MiwyNyBAQCBib29sIFRyeUVtaXREaXJlY3RMaWtl
UmVzdWx0KGNvbnN0IFBoeXNpY2FsQWdnSm9pbiAmb3AsIERhdGFDaHVuayAmY2h1bmssIEFnZ0pv
aQogICAgICAgICAgICAgICAgICAgICBhdXRvIGNvbXByZXNzX29mZnNldCA9IGNpLm9mZnNldDsK
ICAgICAgICAgICAgICAgICAgICAgc3dpdGNoIChjaS5jb21wcmVzc2VkX3R5cGUuSW50ZXJuYWxU
eXBlKCkpIHsKICAgICAgICAgICAgICAgICAgICAgY2FzZSBQaHlzaWNhbFR5cGU6OlVJTlQ4OiB7
Ci0gICAgICAgICAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRh
PHVpbnQ4X3Q+KGNodW5rLmRhdGFbZ2ldKTsKKyAgICAgICAgICAgICAgICAgICAgICAgIGF1dG8g
KmRzdCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPHVpbnQ4X3Q+KGNodW5rLmRhdGFbZ2ld
KTsKICAgICAgICAgICAgICAgICAgICAgICAgIGZvciAoaWR4X3QgaSA9IDA7IGkgPCBiYXRjaDsg
aSsrKSBkc3RbaV0gPSAodWludDhfdCkoKGludDY0X3Qpc3JjLmRpcmVjdF9rZXlzW3NyYy5wb3Mg
KyBpXSArIHNpbmsua2V5X21pbiAtIGNvbXByZXNzX29mZnNldCk7CiAgICAgICAgICAgICAgICAg
ICAgICAgICBicmVhazsKICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAg
ICBjYXNlIFBoeXNpY2FsVHlwZTo6VUlOVDE2OiB7Ci0gICAgICAgICAgICAgICAgICAgICAgICBh
dXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhPHVpbnQxNl90PihjaHVuay5kYXRhW2dpXSk7
CisgICAgICAgICAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRh
TXV0YWJsZTx1aW50MTZfdD4oY2h1bmsuZGF0YVtnaV0pOwogICAgICAgICAgICAgICAgICAgICAg
ICAgZm9yIChpZHhfdCBpID0gMDsgaSA8IGJhdGNoOyBpKyspIGRzdFtpXSA9ICh1aW50MTZfdCko
KGludDY0X3Qpc3JjLmRpcmVjdF9rZXlzW3NyYy5wb3MgKyBpXSArIHNpbmsua2V5X21pbiAtIGNv
bXByZXNzX29mZnNldCk7CiAgICAgICAgICAgICAgICAgICAgICAgICBicmVhazsKICAgICAgICAg
ICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgICBjYXNlIFBoeXNpY2FsVHlwZTo6VUlO
VDMyOiB7Ci0gICAgICAgICAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpH
ZXREYXRhPHVpbnQzMl90PihjaHVuay5kYXRhW2dpXSk7CisgICAgICAgICAgICAgICAgICAgICAg
ICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhTXV0YWJsZTx1aW50MzJfdD4oY2h1bmsu
ZGF0YVtnaV0pOwogICAgICAgICAgICAgICAgICAgICAgICAgZm9yIChpZHhfdCBpID0gMDsgaSA8
IGJhdGNoOyBpKyspIGRzdFtpXSA9ICh1aW50MzJfdCkoKGludDY0X3Qpc3JjLmRpcmVjdF9rZXlz
W3NyYy5wb3MgKyBpXSArIHNpbmsua2V5X21pbiAtIGNvbXByZXNzX29mZnNldCk7CiAgICAgICAg
ICAgICAgICAgICAgICAgICBicmVhazsKICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAg
ICAgICAgICAgICBjYXNlIFBoeXNpY2FsVHlwZTo6VUlOVDY0OiB7Ci0gICAgICAgICAgICAgICAg
ICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhPHVpbnQ2NF90PihjaHVuay5k
YXRhW2dpXSk7CisgICAgICAgICAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9y
OjpHZXREYXRhTXV0YWJsZTx1aW50NjRfdD4oY2h1bmsuZGF0YVtnaV0pOwogICAgICAgICAgICAg
ICAgICAgICAgICAgZm9yIChpZHhfdCBpID0gMDsgaSA8IGJhdGNoOyBpKyspIGRzdFtpXSA9ICh1
aW50NjRfdCkoKGludDY0X3Qpc3JjLmRpcmVjdF9rZXlzW3NyYy5wb3MgKyBpXSArIHNpbmsua2V5
X21pbiAtIGNvbXByZXNzX29mZnNldCk7CiAgICAgICAgICAgICAgICAgICAgICAgICBicmVhazsK
ICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgICBkZWZhdWx0OiB7Ci0g
ICAgICAgICAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhPGlu
dDMyX3Q+KGNodW5rLmRhdGFbZ2ldKTsKKyAgICAgICAgICAgICAgICAgICAgICAgIGF1dG8gKmRz
dCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGludDMyX3Q+KGNodW5rLmRhdGFbZ2ldKTsK
ICAgICAgICAgICAgICAgICAgICAgICAgIGZvciAoaWR4X3QgaSA9IDA7IGkgPCBiYXRjaDsgaSsr
KSBkc3RbaV0gPSAoaW50MzJfdCkoKGludDY0X3Qpc3JjLmRpcmVjdF9rZXlzW3NyYy5wb3MgKyBp
XSArIHNpbmsua2V5X21pbik7CiAgICAgICAgICAgICAgICAgICAgICAgICBicmVhazsKICAgICAg
ICAgICAgICAgICAgICAgfQpAQCAtMjAwLDIyICsyMDAsMjIgQEAgYm9vbCBUcnlFbWl0RGlyZWN0
TGlrZVJlc3VsdChjb25zdCBQaHlzaWNhbEFnZ0pvaW4gJm9wLCBEYXRhQ2h1bmsgJmNodW5rLCBB
Z2dKb2kKICAgICAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgICAgICBzd2l0
Y2ggKG91dF90eXBlKSB7CiAgICAgICAgICAgICAgICAgICAgIGNhc2UgUGh5c2ljYWxUeXBlOjpJ
TlQzMjogewotICAgICAgICAgICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rvcjo6
R2V0RGF0YTxpbnQzMl90PihjaHVuay5kYXRhW2dpXSk7CisgICAgICAgICAgICAgICAgICAgICAg
ICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhTXV0YWJsZTxpbnQzMl90PihjaHVuay5k
YXRhW2dpXSk7CiAgICAgICAgICAgICAgICAgICAgICAgICBmb3IgKGlkeF90IGkgPSAwOyBpIDwg
YmF0Y2g7IGkrKykgZHN0W2ldID0gKGludDMyX3QpKChpbnQ2NF90KXNyYy5kaXJlY3Rfa2V5c1tz
cmMucG9zICsgaV0gKyBzaW5rLmtleV9taW4pOwogICAgICAgICAgICAgICAgICAgICAgICAgYnJl
YWs7CiAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICAgY2FzZSBQaHlz
aWNhbFR5cGU6OklOVDY0OiB7Ci0gICAgICAgICAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBG
bGF0VmVjdG9yOjpHZXREYXRhPGludDY0X3Q+KGNodW5rLmRhdGFbZ2ldKTsKKyAgICAgICAgICAg
ICAgICAgICAgICAgIGF1dG8gKmRzdCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGludDY0
X3Q+KGNodW5rLmRhdGFbZ2ldKTsKICAgICAgICAgICAgICAgICAgICAgICAgIGZvciAoaWR4X3Qg
aSA9IDA7IGkgPCBiYXRjaDsgaSsrKSBkc3RbaV0gPSAoaW50NjRfdClzcmMuZGlyZWN0X2tleXNb
c3JjLnBvcyArIGldICsgc2luay5rZXlfbWluOwogICAgICAgICAgICAgICAgICAgICAgICAgYnJl
YWs7CiAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICAgY2FzZSBQaHlz
aWNhbFR5cGU6OlVJTlQzMjogewotICAgICAgICAgICAgICAgICAgICAgICAgYXV0byAqZHN0ID0g
RmxhdFZlY3Rvcjo6R2V0RGF0YTx1aW50MzJfdD4oY2h1bmsuZGF0YVtnaV0pOworICAgICAgICAg
ICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rvcjo6R2V0RGF0YU11dGFibGU8dWlu
dDMyX3Q+KGNodW5rLmRhdGFbZ2ldKTsKICAgICAgICAgICAgICAgICAgICAgICAgIGZvciAoaWR4
X3QgaSA9IDA7IGkgPCBiYXRjaDsgaSsrKSBkc3RbaV0gPSAodWludDMyX3QpKChpbnQ2NF90KXNy
Yy5kaXJlY3Rfa2V5c1tzcmMucG9zICsgaV0gKyBzaW5rLmtleV9taW4pOwogICAgICAgICAgICAg
ICAgICAgICAgICAgYnJlYWs7CiAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAg
ICAgICAgY2FzZSBQaHlzaWNhbFR5cGU6OlVJTlQ2NDogewotICAgICAgICAgICAgICAgICAgICAg
ICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rvcjo6R2V0RGF0YTx1aW50NjRfdD4oY2h1bmsuZGF0YVtn
aV0pOworICAgICAgICAgICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rvcjo6R2V0
RGF0YU11dGFibGU8dWludDY0X3Q+KGNodW5rLmRhdGFbZ2ldKTsKICAgICAgICAgICAgICAgICAg
ICAgICAgIGZvciAoaWR4X3QgaSA9IDA7IGkgPCBiYXRjaDsgaSsrKSBkc3RbaV0gPSAodWludDY0
X3QpKChpbnQ2NF90KXNyYy5kaXJlY3Rfa2V5c1tzcmMucG9zICsgaV0gKyBzaW5rLmtleV9taW4p
OwogICAgICAgICAgICAgICAgICAgICAgICAgYnJlYWs7CiAgICAgICAgICAgICAgICAgICAgIH0K
QEAgLTI0Myw3ICsyNDMsNyBAQCBib29sIFRyeUVtaXREaXJlY3RMaWtlUmVzdWx0KGNvbnN0IFBo
eXNpY2FsQWdnSm9pbiAmb3AsIERhdGFDaHVuayAmY2h1bmssIEFnZ0pvaQogICAgICAgICAgICAg
ICAgIGF1dG8gKnN1bXMgPSBzaW5rLnNlZ21lbnRlZF9kaXJlY3RfbW9kZSA/IG51bGxwdHIgOiBz
aW5rLmRpcmVjdF9zdW1zLmRhdGEoKSArIGEgKiBzaW5rLmtleV9yYW5nZTsKICAgICAgICAgICAg
ICAgICBhdXRvICpjb3VudHMgPSBzaW5rLnNlZ21lbnRlZF9kaXJlY3RfbW9kZSA/IG51bGxwdHIg
OiBzaW5rLmRpcmVjdF9jb3VudHMuZGF0YSgpICsgYSAqIHNpbmsua2V5X3JhbmdlOwogICAgICAg
ICAgICAgICAgIGlmIChvdXRfdHlwZSA9PSBQaHlzaWNhbFR5cGU6OkRPVUJMRSkgewotICAgICAg
ICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhPGRvdWJsZT4oY2h1
bmsuZGF0YVtvdXRfaWR4XSk7CisgICAgICAgICAgICAgICAgICAgIGF1dG8gKmRzdCA9IEZsYXRW
ZWN0b3I6OkdldERhdGFNdXRhYmxlPGRvdWJsZT4oY2h1bmsuZGF0YVtvdXRfaWR4XSk7CiAgICAg
ICAgICAgICAgICAgICAgIGZvciAoaWR4X3QgaSA9IDA7IGkgPCBiYXRjaDsgaSsrKSB7CiAgICAg
ICAgICAgICAgICAgICAgICAgICBhdXRvIGsgPSBzcmMuZGlyZWN0X2tleXNbc3JjLnBvcyArIGld
OwogICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHNpbmsuc2VnbWVudGVkX2RpcmVjdF9tb2Rl
KSB7CkBAIC0yNzgsOSArMjc4LDkgQEAgYm9vbCBUcnlFbWl0RGlyZWN0TGlrZVJlc3VsdChjb25z
dCBQaHlzaWNhbEFnZ0pvaW4gJm9wLCBEYXRhQ2h1bmsgJmNodW5rLCBBZ2dKb2kKICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA6IChpc19taW4g
PyBzaW5rLmRpcmVjdF9taW5zLmRhdGEoKSArIGEgKiBzaW5rLmtleV9yYW5nZQogICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA6
IHNpbmsuZGlyZWN0X21heHMuZGF0YSgpICsgYSAqIHNpbmsua2V5X3JhbmdlKTsKICAgICAgICAg
ICAgICAgICBhdXRvICpoYXMgPSBzaW5rLnNlZ21lbnRlZF9kaXJlY3RfbW9kZSA/IG51bGxwdHIg
OiBzaW5rLmRpcmVjdF9oYXMuZGF0YSgpICsgYSAqIHNpbmsua2V5X3JhbmdlOwotICAgICAgICAg
ICAgICAgIGF1dG8gJnZhbGlkaXR5ID0gRmxhdFZlY3Rvcjo6VmFsaWRpdHkoY2h1bmsuZGF0YVtv
dXRfaWR4XSk7CisgICAgICAgICAgICAgICAgYXV0byAmdmFsaWRpdHkgPSBGbGF0VmVjdG9yOjpW
YWxpZGl0eU11dGFibGUoY2h1bmsuZGF0YVtvdXRfaWR4XSk7CiAgICAgICAgICAgICAgICAgaWYg
KG91dF90eXBlID09IFBoeXNpY2FsVHlwZTo6RE9VQkxFKSB7Ci0gICAgICAgICAgICAgICAgICAg
IGF1dG8gKmRzdCA9IEZsYXRWZWN0b3I6OkdldERhdGE8ZG91YmxlPihjaHVuay5kYXRhW291dF9p
ZHhdKTsKKyAgICAgICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rvcjo6R2V0RGF0
YU11dGFibGU8ZG91YmxlPihjaHVuay5kYXRhW291dF9pZHhdKTsKICAgICAgICAgICAgICAgICAg
ICAgZm9yIChpZHhfdCBpID0gMDsgaSA8IGJhdGNoOyBpKyspIHsKICAgICAgICAgICAgICAgICAg
ICAgICAgIGF1dG8gayA9IHNyYy5kaXJlY3Rfa2V5c1tzcmMucG9zICsgaV07CiAgICAgICAgICAg
ICAgICAgICAgICAgICBpZiAoc2luay5zZWdtZW50ZWRfZGlyZWN0X21vZGUpIHsKQEAgLTMwNiw3
ICszMDYsNyBAQCBib29sIFRyeUVtaXREaXJlY3RMaWtlUmVzdWx0KGNvbnN0IFBoeXNpY2FsQWdn
Sm9pbiAmb3AsIERhdGFDaHVuayAmY2h1bmssIEFnZ0pvaQogICAgICAgICAgICAgfSBlbHNlIHsK
ICAgICAgICAgICAgICAgICBhdXRvICpzdW1zID0gc2luay5zZWdtZW50ZWRfZGlyZWN0X21vZGUg
PyBudWxscHRyIDogc2luay5kaXJlY3Rfc3Vtcy5kYXRhKCkgKyBhICogc2luay5rZXlfcmFuZ2U7
CiAgICAgICAgICAgICAgICAgaWYgKG91dF90eXBlID09IFBoeXNpY2FsVHlwZTo6SU5UNjQpIHsK
LSAgICAgICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rvcjo6R2V0RGF0YTxpbnQ2
NF90PihjaHVuay5kYXRhW291dF9pZHhdKTsKKyAgICAgICAgICAgICAgICAgICAgYXV0byAqZHN0
ID0gRmxhdFZlY3Rvcjo6R2V0RGF0YU11dGFibGU8aW50NjRfdD4oY2h1bmsuZGF0YVtvdXRfaWR4
XSk7CiAgICAgICAgICAgICAgICAgICAgIGZvciAoaWR4X3QgaSA9IDA7IGkgPCBiYXRjaDsgaSsr
KSB7CiAgICAgICAgICAgICAgICAgICAgICAgICBhdXRvIGsgPSBzcmMuZGlyZWN0X2tleXNbc3Jj
LnBvcyArIGldOwogICAgICAgICAgICAgICAgICAgICAgICAgaWYgKHNpbmsuc2VnbWVudGVkX2Rp
cmVjdF9tb2RlKSB7CkBAIC0zMTgsNyArMzE4LDcgQEAgYm9vbCBUcnlFbWl0RGlyZWN0TGlrZVJl
c3VsdChjb25zdCBQaHlzaWNhbEFnZ0pvaW4gJm9wLCBEYXRhQ2h1bmsgJmNodW5rLCBBZ2dKb2kK
ICAgICAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICAgICAgfQogICAgICAg
ICAgICAgICAgIH0gZWxzZSBpZiAob3V0X3R5cGUgPT0gUGh5c2ljYWxUeXBlOjpET1VCTEUpIHsK
LSAgICAgICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rvcjo6R2V0RGF0YTxkb3Vi
bGU+KGNodW5rLmRhdGFbb3V0X2lkeF0pOworICAgICAgICAgICAgICAgICAgICBhdXRvICpkc3Qg
PSBGbGF0VmVjdG9yOjpHZXREYXRhTXV0YWJsZTxkb3VibGU+KGNodW5rLmRhdGFbb3V0X2lkeF0p
OwogICAgICAgICAgICAgICAgICAgICBmb3IgKGlkeF90IGkgPSAwOyBpIDwgYmF0Y2g7IGkrKykg
ewogICAgICAgICAgICAgICAgICAgICAgICAgYXV0byBrID0gc3JjLmRpcmVjdF9rZXlzW3NyYy5w
b3MgKyBpXTsKICAgICAgICAgICAgICAgICAgICAgICAgIGlmIChzaW5rLnNlZ21lbnRlZF9kaXJl
Y3RfbW9kZSkgewpAQCAtMzY1LDIyICszNjUsMjIgQEAgYm9vbCBUcnlFbWl0RGlyZWN0TGlrZVJl
c3VsdChjb25zdCBQaHlzaWNhbEFnZ0pvaW4gJm9wLCBEYXRhQ2h1bmsgJmNodW5rLCBBZ2dKb2kK
ICAgICAgICAgICAgIGF1dG8gc2xvdCA9IHNyYy5zbG90X2luZGljZXNbc3JjLnBvcyArIGldOwog
ICAgICAgICAgICAgYXV0byAmZW50cnkgPSBzaW5rLmJ1aWxkX2h0LmJ1Y2tldHNbc2xvdF07CiAg
ICAgICAgICAgICBpZiAoY29sLmdyb3VwX2NvbXByZXNzWzBdLmlzX3N0cmluZ19jb21wcmVzcykg
ewotICAgICAgICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERhdGE8c3RyaW5nX3Q+KGNodW5rLmRh
dGFbMF0pW2ldID0gU3RyaW5nVmVjdG9yOjpBZGRTdHJpbmdPckJsb2IoY2h1bmsuZGF0YVswXSwg
ZW50cnkuc3RyX2tleSk7CisgICAgICAgICAgICAgICAgRmxhdFZlY3Rvcjo6R2V0RGF0YU11dGFi
bGU8c3RyaW5nX3Q+KGNodW5rLmRhdGFbMF0pW2ldID0gU3RyaW5nVmVjdG9yOjpBZGRTdHJpbmdP
ckJsb2IoY2h1bmsuZGF0YVswXSwgZW50cnkuc3RyX2tleSk7CiAgICAgICAgICAgICB9IGVsc2Ug
ewogICAgICAgICAgICAgICAgIGF1dG8gb3V0X3R5cGUgPSBjaHVuay5kYXRhWzBdLkdldFR5cGUo
KS5JbnRlcm5hbFR5cGUoKTsKICAgICAgICAgICAgICAgICBpZiAoZW50cnkuaW50X2tleSAhPSBJ
TlQ2NF9NSU4pIHsKICAgICAgICAgICAgICAgICAgICAgc3dpdGNoIChvdXRfdHlwZSkgewogICAg
ICAgICAgICAgICAgICAgICBjYXNlIFBoeXNpY2FsVHlwZTo6SU5UMzI6Ci0gICAgICAgICAgICAg
ICAgICAgICAgICBGbGF0VmVjdG9yOjpHZXREYXRhPGludDMyX3Q+KGNodW5rLmRhdGFbMF0pW2ld
ID0gKGludDMyX3QpZW50cnkuaW50X2tleTsKKyAgICAgICAgICAgICAgICAgICAgICAgIEZsYXRW
ZWN0b3I6OkdldERhdGFNdXRhYmxlPGludDMyX3Q+KGNodW5rLmRhdGFbMF0pW2ldID0gKGludDMy
X3QpZW50cnkuaW50X2tleTsKICAgICAgICAgICAgICAgICAgICAgICAgIGJyZWFrOwogICAgICAg
ICAgICAgICAgICAgICBjYXNlIFBoeXNpY2FsVHlwZTo6SU5UNjQ6Ci0gICAgICAgICAgICAgICAg
ICAgICAgICBGbGF0VmVjdG9yOjpHZXREYXRhPGludDY0X3Q+KGNodW5rLmRhdGFbMF0pW2ldID0g
ZW50cnkuaW50X2tleTsKKyAgICAgICAgICAgICAgICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERh
dGFNdXRhYmxlPGludDY0X3Q+KGNodW5rLmRhdGFbMF0pW2ldID0gZW50cnkuaW50X2tleTsKICAg
ICAgICAgICAgICAgICAgICAgICAgIGJyZWFrOwogICAgICAgICAgICAgICAgICAgICBjYXNlIFBo
eXNpY2FsVHlwZTo6VUlOVDMyOgotICAgICAgICAgICAgICAgICAgICAgICAgRmxhdFZlY3Rvcjo6
R2V0RGF0YTx1aW50MzJfdD4oY2h1bmsuZGF0YVswXSlbaV0gPSAodWludDMyX3QpZW50cnkuaW50
X2tleTsKKyAgICAgICAgICAgICAgICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxl
PHVpbnQzMl90PihjaHVuay5kYXRhWzBdKVtpXSA9ICh1aW50MzJfdCllbnRyeS5pbnRfa2V5Owog
ICAgICAgICAgICAgICAgICAgICAgICAgYnJlYWs7CiAgICAgICAgICAgICAgICAgICAgIGNhc2Ug
UGh5c2ljYWxUeXBlOjpVSU5UNjQ6Ci0gICAgICAgICAgICAgICAgICAgICAgICBGbGF0VmVjdG9y
OjpHZXREYXRhPHVpbnQ2NF90PihjaHVuay5kYXRhWzBdKVtpXSA9ICh1aW50NjRfdCllbnRyeS5p
bnRfa2V5OworICAgICAgICAgICAgICAgICAgICAgICAgRmxhdFZlY3Rvcjo6R2V0RGF0YU11dGFi
bGU8dWludDY0X3Q+KGNodW5rLmRhdGFbMF0pW2ldID0gKHVpbnQ2NF90KWVudHJ5LmludF9rZXk7
CiAgICAgICAgICAgICAgICAgICAgICAgICBicmVhazsKICAgICAgICAgICAgICAgICAgICAgZGVm
YXVsdDoKICAgICAgICAgICAgICAgICAgICAgICAgIGNodW5rLmRhdGFbMF0uU2V0VmFsdWUoaSwg
VmFsdWU6OkJJR0lOVChlbnRyeS5pbnRfa2V5KSk7CkBAIC0zODgsNyArMzg4LDcgQEAgYm9vbCBU
cnlFbWl0RGlyZWN0TGlrZVJlc3VsdChjb25zdCBQaHlzaWNhbEFnZ0pvaW4gJm9wLCBEYXRhQ2h1
bmsgJmNodW5rLCBBZ2dKb2kKICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAg
IH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgICAgIGlmIChvdXRfdHlwZSA9PSBQaHlzaWNhbFR5
cGU6OkRPVUJMRSkgewotICAgICAgICAgICAgICAgICAgICAgICAgRmxhdFZlY3Rvcjo6R2V0RGF0
YTxkb3VibGU+KGNodW5rLmRhdGFbMF0pW2ldID0gZW50cnkuZGJsX2tleTsKKyAgICAgICAgICAg
ICAgICAgICAgICAgIEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGRvdWJsZT4oY2h1bmsuZGF0
YVswXSlbaV0gPSBlbnRyeS5kYmxfa2V5OwogICAgICAgICAgICAgICAgICAgICB9IGVsc2Ugewog
ICAgICAgICAgICAgICAgICAgICAgICAgY2h1bmsuZGF0YVswXS5TZXRWYWx1ZShpLCBWYWx1ZTo6
RE9VQkxFKGVudHJ5LmRibF9rZXkpKTsKICAgICAgICAgICAgICAgICAgICAgfQpAQCAtNDAyLDcg
KzQwMiw3IEBAIGJvb2wgVHJ5RW1pdERpcmVjdExpa2VSZXN1bHQoY29uc3QgUGh5c2ljYWxBZ2dK
b2luICZvcCwgRGF0YUNodW5rICZjaHVuaywgQWdnSm9pCiAgICAgICAgICAgICBhdXRvIG91dF90
eXBlID0gY2h1bmsuZGF0YVtvdXRfaWR4XS5HZXRUeXBlKCkuSW50ZXJuYWxUeXBlKCk7CiAgICAg
ICAgICAgICBpZiAoZiA9PSAiQVZHIikgewogICAgICAgICAgICAgICAgIGlmIChvdXRfdHlwZSA9
PSBQaHlzaWNhbFR5cGU6OkRPVUJMRSkgewotICAgICAgICAgICAgICAgICAgICBhdXRvICpkc3Qg
PSBGbGF0VmVjdG9yOjpHZXREYXRhPGRvdWJsZT4oY2h1bmsuZGF0YVtvdXRfaWR4XSk7CisgICAg
ICAgICAgICAgICAgICAgIGF1dG8gKmRzdCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGRv
dWJsZT4oY2h1bmsuZGF0YVtvdXRfaWR4XSk7CiAgICAgICAgICAgICAgICAgICAgIGZvciAoaWR4
X3QgaSA9IDA7IGkgPCBiYXRjaDsgaSsrKSB7CiAgICAgICAgICAgICAgICAgICAgICAgICBhdXRv
IG9mZiA9IGEgKiBjYXAgKyBzcmMuc2xvdF9pbmRpY2VzW3NyYy5wb3MgKyBpXTsKICAgICAgICAg
ICAgICAgICAgICAgICAgIGF1dG8gY250ID0gc2luay5idWlsZF9zbG90X2NvdW50c1tvZmZdOwpA
QCAtNDE3LDkgKzQxNyw5IEBAIGJvb2wgVHJ5RW1pdERpcmVjdExpa2VSZXN1bHQoY29uc3QgUGh5
c2ljYWxBZ2dKb2luICZvcCwgRGF0YUNodW5rICZjaHVuaywgQWdnSm9pCiAgICAgICAgICAgICAg
ICAgfQogICAgICAgICAgICAgfSBlbHNlIGlmIChmID09ICJNSU4iIHx8IGYgPT0gIk1BWCIpIHsK
ICAgICAgICAgICAgICAgICBib29sIGlzX21pbiA9IChmID09ICJNSU4iKTsKLSAgICAgICAgICAg
ICAgICBhdXRvICZ2YWxpZGl0eSA9IEZsYXRWZWN0b3I6OlZhbGlkaXR5KGNodW5rLmRhdGFbb3V0
X2lkeF0pOworICAgICAgICAgICAgICAgIGF1dG8gJnZhbGlkaXR5ID0gRmxhdFZlY3Rvcjo6VmFs
aWRpdHlNdXRhYmxlKGNodW5rLmRhdGFbb3V0X2lkeF0pOwogICAgICAgICAgICAgICAgIGlmIChv
dXRfdHlwZSA9PSBQaHlzaWNhbFR5cGU6OkRPVUJMRSkgewotICAgICAgICAgICAgICAgICAgICBh
dXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhPGRvdWJsZT4oY2h1bmsuZGF0YVtvdXRfaWR4
XSk7CisgICAgICAgICAgICAgICAgICAgIGF1dG8gKmRzdCA9IEZsYXRWZWN0b3I6OkdldERhdGFN
dXRhYmxlPGRvdWJsZT4oY2h1bmsuZGF0YVtvdXRfaWR4XSk7CiAgICAgICAgICAgICAgICAgICAg
IGZvciAoaWR4X3QgaSA9IDA7IGkgPCBiYXRjaDsgaSsrKSB7CiAgICAgICAgICAgICAgICAgICAg
ICAgICBhdXRvIG9mZiA9IGEgKiBjYXAgKyBzcmMuc2xvdF9pbmRpY2VzW3NyYy5wb3MgKyBpXTsK
ICAgICAgICAgICAgICAgICAgICAgICAgIGlmICghc2luay5idWlsZF9zbG90X2hhc1tvZmZdKSB7
CkBAIC00NDAsMTMgKzQ0MCwxMyBAQCBib29sIFRyeUVtaXREaXJlY3RMaWtlUmVzdWx0KGNvbnN0
IFBoeXNpY2FsQWdnSm9pbiAmb3AsIERhdGFDaHVuayAmY2h1bmssIEFnZ0pvaQogICAgICAgICAg
ICAgICAgIH0KICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgaWYgKG91dF90
eXBlID09IFBoeXNpY2FsVHlwZTo6SU5UNjQpIHsKLSAgICAgICAgICAgICAgICAgICAgYXV0byAq
ZHN0ID0gRmxhdFZlY3Rvcjo6R2V0RGF0YTxpbnQ2NF90PihjaHVuay5kYXRhW291dF9pZHhdKTsK
KyAgICAgICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rvcjo6R2V0RGF0YU11dGFi
bGU8aW50NjRfdD4oY2h1bmsuZGF0YVtvdXRfaWR4XSk7CiAgICAgICAgICAgICAgICAgICAgIGZv
ciAoaWR4X3QgaSA9IDA7IGkgPCBiYXRjaDsgaSsrKSB7CiAgICAgICAgICAgICAgICAgICAgICAg
ICBhdXRvIG9mZiA9IGEgKiBjYXAgKyBzcmMuc2xvdF9pbmRpY2VzW3NyYy5wb3MgKyBpXTsKICAg
ICAgICAgICAgICAgICAgICAgICAgIGRzdFtpXSA9IChpbnQ2NF90KXNpbmsuYnVpbGRfc2xvdF9z
dW1zW29mZl07CiAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICB9IGVsc2Ug
aWYgKG91dF90eXBlID09IFBoeXNpY2FsVHlwZTo6RE9VQkxFKSB7Ci0gICAgICAgICAgICAgICAg
ICAgIGF1dG8gKmRzdCA9IEZsYXRWZWN0b3I6OkdldERhdGE8ZG91YmxlPihjaHVuay5kYXRhW291
dF9pZHhdKTsKKyAgICAgICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rvcjo6R2V0
RGF0YU11dGFibGU8ZG91YmxlPihjaHVuay5kYXRhW291dF9pZHhdKTsKICAgICAgICAgICAgICAg
ICAgICAgZm9yIChpZHhfdCBpID0gMDsgaSA8IGJhdGNoOyBpKyspIHsKICAgICAgICAgICAgICAg
ICAgICAgICAgIGF1dG8gb2ZmID0gYSAqIGNhcCArIHNyYy5zbG90X2luZGljZXNbc3JjLnBvcyAr
IGldOwogICAgICAgICAgICAgICAgICAgICAgICAgZHN0W2ldID0gc2luay5idWlsZF9zbG90X3N1
bXNbb2ZmXTsKZGlmZiAtLWdpdCBhL3NyYy9hZ2dqb2luX2xvZ2ljYWwuY3BwIGIvc3JjL2FnZ2pv
aW5fbG9naWNhbC5jcHAKaW5kZXggZWUyZGNkYy4uYzUzNTY5ZiAxMDA2NDQKLS0tIGEvc3JjL2Fn
Z2pvaW5fbG9naWNhbC5jcHAKKysrIGIvc3JjL2FnZ2pvaW5fbG9naWNhbC5jcHAKQEAgLTcsOCAr
Nyw4IEBAIHZlY3RvcjxDb2x1bW5CaW5kaW5nPiBMb2dpY2FsQWdnSm9pbjo6R2V0Q29sdW1uQmlu
ZGluZ3MoKSB7CiAgICAgdmVjdG9yPENvbHVtbkJpbmRpbmc+IHI7CiAgICAgaWR4X3QgbmcgPSBj
b2wuZ3JvdXBfY29scy5zaXplKCk7CiAgICAgaWR4X3QgbmEgPSBjb2wuYWdnX2Z1bmNzLnNpemUo
KTsKLSAgICBmb3IgKGlkeF90IGkgPSAwOyBpIDwgbmc7IGkrKykgci5lbXBsYWNlX2JhY2soZ3Jv
dXBfaW5kZXgsIGkpOwotICAgIGZvciAoaWR4X3QgaSA9IDA7IGkgPCBuYTsgaSsrKSByLmVtcGxh
Y2VfYmFjayhhZ2dyZWdhdGVfaW5kZXgsIGkpOworICAgIGZvciAoaWR4X3QgaSA9IDA7IGkgPCBu
ZzsgaSsrKSByLmVtcGxhY2VfYmFjayhUYWJsZUluZGV4KGdyb3VwX2luZGV4KSwgUHJvamVjdGlv
bkluZGV4KGkpKTsKKyAgICBmb3IgKGlkeF90IGkgPSAwOyBpIDwgbmE7IGkrKykgci5lbXBsYWNl
X2JhY2soVGFibGVJbmRleChhZ2dyZWdhdGVfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgoaSkpOwog
ICAgIHJldHVybiByOwogfQogCmRpZmYgLS1naXQgYS9zcmMvYWdnam9pbl9waHlzaWNhbC5jcHAg
Yi9zcmMvYWdnam9pbl9waHlzaWNhbC5jcHAKaW5kZXggZDkyOTM3Yy4uMWY5YjFjZCAxMDA2NDQK
LS0tIGEvc3JjL2FnZ2pvaW5fcGh5c2ljYWwuY3BwCisrKyBiL3NyYy9hZ2dqb2luX3BoeXNpY2Fs
LmNwcApAQCAtOTYsMTIgKzk2LDEyIEBAIFBoeXNpY2FsT3BlcmF0b3IgJkNyZWF0ZVBoeXNpY2Fs
QWdnSm9pblBsYW4oTG9naWNhbEFnZ0pvaW4gJm9wLCBDbGllbnRDb250ZXh0ICZjCiAgICAgcGh5
cy5jb2wgPSBvcC5jb2w7CiAKICAgICBmb3IgKGF1dG8gJmcgOiBvcC5ncm91cF9leHByZXNzaW9u
cykgewotICAgICAgICBwaHlzLmdyb3VwX3R5cGVzLnB1c2hfYmFjayhnLT5yZXR1cm5fdHlwZSk7
CisgICAgICAgIHBoeXMuZ3JvdXBfdHlwZXMucHVzaF9iYWNrKGctPkdldFJldHVyblR5cGUoKSk7
CiAgICAgfQogICAgIGZvciAoYXV0byAmZSA6IG9wLmFnZ19leHByZXNzaW9ucykgewogICAgICAg
ICBhdXRvICZiYSA9IGUtPkNhc3Q8Qm91bmRBZ2dyZWdhdGVFeHByZXNzaW9uPigpOwogICAgICAg
ICBpZiAoIWJhLmNoaWxkcmVuLmVtcHR5KCkpIHsKLSAgICAgICAgICAgIHBoeXMucGF5bG9hZF90
eXBlcy5wdXNoX2JhY2soYmEuY2hpbGRyZW5bMF0tPnJldHVybl90eXBlKTsKKyAgICAgICAgICAg
IHBoeXMucGF5bG9hZF90eXBlcy5wdXNoX2JhY2soYmEuY2hpbGRyZW5bMF0tPkdldFJldHVyblR5
cGUoKSk7CiAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICBwaHlzLnBheWxvYWRfdHlwZXMu
cHVzaF9iYWNrKExvZ2ljYWxUeXBlOjpCSUdJTlQpOwogICAgICAgICB9CmRpZmYgLS1naXQgYS9z
cmMvYWdnam9pbl9yZXdyaXRlX2J1aWxkLmNwcCBiL3NyYy9hZ2dqb2luX3Jld3JpdGVfYnVpbGQu
Y3BwCmluZGV4IDhiNWVkNWYuLjE3MTZiNDMgMTAwNjQ0Ci0tLSBhL3NyYy9hZ2dqb2luX3Jld3Jp
dGVfYnVpbGQuY3BwCisrKyBiL3NyYy9hZ2dqb2luX3Jld3JpdGVfYnVpbGQuY3BwCkBAIC00NCw3
ICs0NCw3IEBAIGJvb2wgVHJ5UmV3cml0ZU5hdGl2ZUJ1aWxkUHJlYWdnKENsaWVudENvbnRleHQg
JmNvbnRleHQsIE9wdGltaXplciAmb3B0aW1pemVyLCB1CiAgICAgYm9vbCBzYXdfcGF5bG9hZF9v
bl9wcm9iZSA9IGZhbHNlOwogICAgIGZvciAoaWR4X3QgYSA9IDA7IGEgPCBhZ2cuZXhwcmVzc2lv
bnMuc2l6ZSgpOyBhKyspIHsKICAgICAgICAgYXV0byAmYmEgPSBhZ2cuZXhwcmVzc2lvbnNbYV0t
PkNhc3Q8Qm91bmRBZ2dyZWdhdGVFeHByZXNzaW9uPigpOwotICAgICAgICBhdXRvIGZuID0gU3Ry
aW5nVXRpbDo6VXBwZXIoYmEuZnVuY3Rpb24ubmFtZSk7CisgICAgICAgIGF1dG8gZm4gPSBTdHJp
bmdVdGlsOjpVcHBlcihiYS5mdW5jdGlvbi5HZXROYW1lKCkpOwogICAgICAgICBpZiAoZm4gPT0g
IkNPVU5UX1NUQVIiKSB7CiAgICAgICAgICAgICBjb250aW51ZTsKICAgICAgICAgfQpAQCAtMTEy
LDEwICsxMTIsMTAgQEAgYm9vbCBUcnlSZXdyaXRlTmF0aXZlQnVpbGRQcmVhZ2coQ2xpZW50Q29u
dGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZXIsIHUKICAgICB9OwogICAgIGZvciAo
aWR4X3QgYSA9IDA7IGEgPCBhZ2cuZXhwcmVzc2lvbnMuc2l6ZSgpOyBhKyspIHsKICAgICAgICAg
YXV0byAmYmEgPSBhZ2cuZXhwcmVzc2lvbnNbYV0tPkNhc3Q8Qm91bmRBZ2dyZWdhdGVFeHByZXNz
aW9uPigpOwotICAgICAgICBhdXRvIGZuID0gU3RyaW5nVXRpbDo6VXBwZXIoYmEuZnVuY3Rpb24u
bmFtZSk7CisgICAgICAgIGF1dG8gZm4gPSBTdHJpbmdVdGlsOjpVcHBlcihiYS5mdW5jdGlvbi5H
ZXROYW1lKCkpOwogICAgICAgICBOYXRpdmVCdWlsZEFnZ0luZm8gaW5mbzsKICAgICAgICAgaW5m
by5mbiA9IGZuOwotICAgICAgICBpbmZvLnJlc3VsdF90eXBlID0gYmEucmV0dXJuX3R5cGU7Cisg
ICAgICAgIGluZm8ucmVzdWx0X3R5cGUgPSBiYS5HZXRSZXR1cm5UeXBlKCk7CiAgICAgICAgIGlm
IChBZ2dKb2luVHJhY2VFbmFibGVkKCkpIHsKICAgICAgICAgICAgIGZwcmludGYoc3RkZXJyLCAi
W0FHR0pPSU5dIG5hdGl2ZS1idWlsZC1wcmVhZ2cgYWdnJWxsdSBmbj0lcyBjaGlsZF9jb3VudD0l
enVcbiIsCiAgICAgICAgICAgICAgICAgICAgICh1bnNpZ25lZCBsb25nIGxvbmcpYSwgZm4uY19z
dHIoKSwgYmEuY2hpbGRyZW4uc2l6ZSgpKTsKQEAgLTEzNCw3ICsxMzQsNyBAQCBib29sIFRyeVJl
d3JpdGVOYXRpdmVCdWlsZFByZWFnZyhDbGllbnRDb250ZXh0ICZjb250ZXh0LCBPcHRpbWl6ZXIg
Jm9wdGltaXplciwgdQogICAgICAgICBpZiAoYmEuY2hpbGRyZW4uZW1wdHkoKSkgewogICAgICAg
ICAgICAgcmV0dXJuIGZhbHNlOwogICAgICAgICB9Ci0gICAgICAgIGlmICgoZm4gPT0gIlNVTSIg
fHwgZm4gPT0gIkFWRyIpICYmICFiYS5jaGlsZHJlblswXS0+cmV0dXJuX3R5cGUuSXNOdW1lcmlj
KCkpIHsKKyAgICAgICAgaWYgKChmbiA9PSAiU1VNIiB8fCBmbiA9PSAiQVZHIikgJiYgIWJhLmNo
aWxkcmVuWzBdLT5HZXRSZXR1cm5UeXBlKCkuSXNOdW1lcmljKCkpIHsKICAgICAgICAgICAgIHJl
dHVybiBmYWxzZTsKICAgICAgICAgfQogICAgICAgICBhdXRvIGNoaWxkX2lkeCA9IHJlc29sdmVf
YmluZGluZygqYmEuY2hpbGRyZW5bMF0pOwpAQCAtMjY2LDE0ICsyNjYsMTIgQEAgYm9vbCBUcnlS
ZXdyaXRlTmF0aXZlQnVpbGRQcmVhZ2coQ2xpZW50Q29udGV4dCAmY29udGV4dCwgT3B0aW1pemVy
ICZvcHRpbWl6ZXIsIHUKIAogICAgIGF1dG8gbmF0aXZlX2pvaW4gPSBtYWtlX3VuaXE8TG9naWNh
bENvbXBhcmlzb25Kb2luPihKb2luVHlwZTo6SU5ORVIpOwogICAgIGZvciAoaWR4X3QgaSA9IDA7
IGkgPCBrZXlfY291bnQ7IGkrKykgewotICAgICAgICBKb2luQ29uZGl0aW9uIGNvbmQ7Ci0gICAg
ICAgIGNvbmQuY29tcGFyaXNvbiA9IEV4cHJlc3Npb25UeXBlOjpDT01QQVJFX0VRVUFMOwotICAg
ICAgICBjb25kLmxlZnQgPSBtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihjb3Vu
dF9wcmVhZ2ctPnR5cGVzW2ldLCBDb2x1bW5CaW5kaW5nKGNvdW50X2dyb3VwX2luZGV4LCBpKSk7
Ci0gICAgICAgIGNvbmQucmlnaHQgPSBtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9u
PihidWlsZF9wcmVhZ2ctPnR5cGVzW2ldLCBDb2x1bW5CaW5kaW5nKGJ1aWxkX2dyb3VwX2luZGV4
LCBpKSk7CisgICAgICAgIHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4gbGhzID0gbWFrZV91bmlxPEJv
dW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oY291bnRfcHJlYWdnLT50eXBlc1tpXSwgQ29sdW1uQmlu
ZGluZyhUYWJsZUluZGV4KGNvdW50X2dyb3VwX2luZGV4KSwgUHJvamVjdGlvbkluZGV4KGkpKSk7
CisgICAgICAgIHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4gcmhzID0gbWFrZV91bmlxPEJvdW5kQ29s
dW1uUmVmRXhwcmVzc2lvbj4oYnVpbGRfcHJlYWdnLT50eXBlc1tpXSwgQ29sdW1uQmluZGluZyhU
YWJsZUluZGV4KGJ1aWxkX2dyb3VwX2luZGV4KSwgUHJvamVjdGlvbkluZGV4KGkpKSk7CiAgICAg
ICAgIGlmIChjb3VudF9wcmVhZ2ctPnR5cGVzW2ldICE9IGJ1aWxkX3ByZWFnZy0+dHlwZXNbaV0p
IHsKLSAgICAgICAgICAgIGNvbmQucmlnaHQgPSBCb3VuZENhc3RFeHByZXNzaW9uOjpBZGRDYXN0
VG9UeXBlKGNvbnRleHQsIHN0ZDo6bW92ZShjb25kLnJpZ2h0KSwgY291bnRfcHJlYWdnLT50eXBl
c1tpXSk7CisgICAgICAgICAgICByaHMgPSBCb3VuZENhc3RFeHByZXNzaW9uOjpBZGRDYXN0VG9U
eXBlKGNvbnRleHQsIHN0ZDo6bW92ZShyaHMpLCBjb3VudF9wcmVhZ2ctPnR5cGVzW2ldKTsKICAg
ICAgICAgfQotICAgICAgICBuYXRpdmVfam9pbi0+Y29uZGl0aW9ucy5wdXNoX2JhY2soc3RkOjpt
b3ZlKGNvbmQpKTsKKyAgICAgICAgbmF0aXZlX2pvaW4tPmNvbmRpdGlvbnMuZW1wbGFjZV9iYWNr
KHN0ZDo6bW92ZShsaHMpLCBzdGQ6Om1vdmUocmhzKSwgRXhwcmVzc2lvblR5cGU6OkNPTVBBUkVf
RVFVQUwpOwogICAgIH0KICAgICBuYXRpdmVfam9pbi0+Y2hpbGRyZW4ucHVzaF9iYWNrKHN0ZDo6
bW92ZShjb3VudF9wcmVhZ2cpKTsKICAgICBuYXRpdmVfam9pbi0+Y2hpbGRyZW4ucHVzaF9iYWNr
KHN0ZDo6bW92ZShidWlsZF9wcmVhZ2cpKTsKQEAgLTMzNiw3ICszMzQsNyBAQCBib29sIFRyeVJl
d3JpdGVOYXRpdmVCdWlsZFByZWFnZyhDbGllbnRDb250ZXh0ICZjb250ZXh0LCBPcHRpbWl6ZXIg
Jm9wdGltaXplciwgdQogICAgICAgICBpZiAob3AtPmhhc19lc3RpbWF0ZWRfY2FyZGluYWxpdHkp
IHsKICAgICAgICAgICAgIHByb2otPlNldEVzdGltYXRlZENhcmRpbmFsaXR5KG9wLT5lc3RpbWF0
ZWRfY2FyZGluYWxpdHkpOwogICAgICAgICB9Ci0gICAgICAgIG91dHB1dF9pbmRleCA9IHByb2pf
aW5kZXg7CisgICAgICAgIG91dHB1dF9pbmRleCA9IHByb2pfaW5kZXguaW5kZXg7CiAgICAgICAg
IG91dHB1dF9iYXNlID0gMTsKICAgICAgICAgcmVwbGFjZW1lbnQgPSBzdGQ6Om1vdmUocHJvaik7
CiAgICAgfSBlbHNlIGlmIChncm91cGVkX2J5X2pvaW5fa2V5X3N1YnNldCkgewpAQCAtMzk5LDI1
ICszOTcsMjUgQEAgYm9vbCBUcnlSZXdyaXRlTmF0aXZlQnVpbGRQcmVhZ2coQ2xpZW50Q29udGV4
dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZXIsIHUKICAgICAgICAgICAgICAgICBmb3Ig
KGF1dG8gc2xvdCA6IHtzdW1fc2xvdHNbYV0sIGNvdW50X3Nsb3RzW2FdfSkgewogICAgICAgICAg
ICAgICAgICAgICB2ZWN0b3I8dW5pcXVlX3B0cjxFeHByZXNzaW9uPj4gY2hpbGRyZW47CiAgICAg
ICAgICAgICAgICAgICAgIGNoaWxkcmVuLnB1c2hfYmFjayhtYWtlX3VuaXE8Qm91bmRDb2x1bW5S
ZWZFeHByZXNzaW9uPihjb250cmliX3Byb2otPnR5cGVzW2NvbnRyaWJfdmFsdWVfYmFzZSArIHNs
b3RdLAotICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgQ29sdW1uQmluZGluZyhjb250cmliX2luZGV4LCBjb250
cmliX3ZhbHVlX2Jhc2UgKyBzbG90KSkpOworICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29sdW1uQmluZGlu
ZyhUYWJsZUluZGV4KGNvbnRyaWJfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgoY29udHJpYl92YWx1
ZV9iYXNlICsgc2xvdCkpKSk7CiAgICAgICAgICAgICAgICAgICAgIGZpbmFsX2FnZ3MucHVzaF9i
YWNrKEJpbmRBZ2dyZWdhdGVCeU5hbWUoY29udGV4dCwgInN1bSIsIHN0ZDo6bW92ZShjaGlsZHJl
bikpKTsKICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICB9IGVsc2UgaWYgKGZuID09ICJN
SU4iIHx8IGZuID09ICJNQVgiKSB7CiAgICAgICAgICAgICAgICAgYXV0byBzbG90ID0gc3VtX3Ns
b3RzW2FdOwogICAgICAgICAgICAgICAgIHZlY3Rvcjx1bmlxdWVfcHRyPEV4cHJlc3Npb24+PiBj
aGlsZHJlbjsKICAgICAgICAgICAgICAgICBjaGlsZHJlbi5wdXNoX2JhY2sobWFrZV91bmlxPEJv
dW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oY29udHJpYl9wcm9qLT50eXBlc1tjb250cmliX3ZhbHVl
X2Jhc2UgKyBzbG90XSwKLSAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29sdW1uQmluZGluZyhjb250cmliX2luZGV4
LCBjb250cmliX3ZhbHVlX2Jhc2UgKyBzbG90KSkpOworICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5k
aW5nKFRhYmxlSW5kZXgoY29udHJpYl9pbmRleCksIFByb2plY3Rpb25JbmRleChjb250cmliX3Zh
bHVlX2Jhc2UgKyBzbG90KSkpKTsKICAgICAgICAgICAgICAgICBmaW5hbF9hZ2dzLnB1c2hfYmFj
ayhCaW5kQWdncmVnYXRlQnlOYW1lKGNvbnRleHQsIFN0cmluZ1V0aWw6Okxvd2VyKGZuKSwgc3Rk
Ojptb3ZlKGNoaWxkcmVuKSkpOwogICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAg
ICBhdXRvIHNsb3QgPSBzdW1fc2xvdHNbYV07CiAgICAgICAgICAgICAgICAgdmVjdG9yPHVuaXF1
ZV9wdHI8RXhwcmVzc2lvbj4+IGNoaWxkcmVuOwogICAgICAgICAgICAgICAgIGNoaWxkcmVuLnB1
c2hfYmFjayhtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihjb250cmliX3Byb2ot
PnR5cGVzW2NvbnRyaWJfdmFsdWVfYmFzZSArIHNsb3RdLAotICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5C
aW5kaW5nKGNvbnRyaWJfaW5kZXgsIGNvbnRyaWJfdmFsdWVfYmFzZSArIHNsb3QpKSk7CisgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgIENvbHVtbkJpbmRpbmcoVGFibGVJbmRleChjb250cmliX2luZGV4KSwgUHJvamVj
dGlvbkluZGV4KGNvbnRyaWJfdmFsdWVfYmFzZSArIHNsb3QpKSkpOwogICAgICAgICAgICAgICAg
IGZpbmFsX2FnZ3MucHVzaF9iYWNrKEJpbmRBZ2dyZWdhdGVCeU5hbWUoY29udGV4dCwgInN1bSIs
IHN0ZDo6bW92ZShjaGlsZHJlbikpKTsKICAgICAgICAgICAgIH0KICAgICAgICAgfQogICAgICAg
ICBhdXRvIGZpbmFsX2FnZyA9IG1ha2VfdW5pcTxMb2dpY2FsQWdncmVnYXRlPihmaW5hbF9ncm91
cF9pbmRleCwgZmluYWxfYWdnX2luZGV4LCBzdGQ6Om1vdmUoZmluYWxfYWdncykpOwotICAgICAg
ICBmaW5hbF9hZ2ctPmdyb3Vwcy5wdXNoX2JhY2sobWFrZV91bmlxPEJvdW5kQ29sdW1uUmVmRXhw
cmVzc2lvbj4oY29udHJpYl9wcm9qLT50eXBlc1swXSwgQ29sdW1uQmluZGluZyhjb250cmliX2lu
ZGV4LCAwKSkpOworICAgICAgICBmaW5hbF9hZ2ctPmdyb3Vwcy5wdXNoX2JhY2sobWFrZV91bmlx
PEJvdW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oY29udHJpYl9wcm9qLT50eXBlc1swXSwgQ29sdW1u
QmluZGluZyhUYWJsZUluZGV4KGNvbnRyaWJfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgoMCkpKSk7
CiAgICAgICAgIGZpbmFsX2FnZy0+Y2hpbGRyZW4ucHVzaF9iYWNrKHN0ZDo6bW92ZShjb250cmli
X3Byb2opKTsKICAgICAgICAgZmluYWxfYWdnLT5SZXNvbHZlT3BlcmF0b3JUeXBlcygpOwogCkBA
IC00NTQsNyArNDUyLDcgQEAgYm9vbCBUcnlSZXdyaXRlTmF0aXZlQnVpbGRQcmVhZ2coQ2xpZW50
Q29udGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZXIsIHUKICAgICAgICAgaWYgKG9w
LT5oYXNfZXN0aW1hdGVkX2NhcmRpbmFsaXR5KSB7CiAgICAgICAgICAgICBmaW5hbF9wcm9qLT5T
ZXRFc3RpbWF0ZWRDYXJkaW5hbGl0eShvcC0+ZXN0aW1hdGVkX2NhcmRpbmFsaXR5KTsKICAgICAg
ICAgfQotICAgICAgICBvdXRwdXRfaW5kZXggPSBmaW5hbF9wcm9qX2luZGV4OworICAgICAgICBv
dXRwdXRfaW5kZXggPSBmaW5hbF9wcm9qX2luZGV4LmluZGV4OwogICAgICAgICBvdXRwdXRfYmFz
ZSA9IDE7CiAgICAgICAgIHJlcGxhY2VtZW50ID0gc3RkOjptb3ZlKGZpbmFsX3Byb2opOwogICAg
IH0gZWxzZSB7CkBAIC01MTYsMjQgKzUxNCwyNCBAQCBib29sIFRyeVJld3JpdGVOYXRpdmVCdWls
ZFByZWFnZyhDbGllbnRDb250ZXh0ICZjb250ZXh0LCBPcHRpbWl6ZXIgJm9wdGltaXplciwgdQog
ICAgICAgICAgICAgICAgIGZvciAoYXV0byBzbG90IDoge3N1bV9zbG90c1thXSwgY291bnRfc2xv
dHNbYV19KSB7CiAgICAgICAgICAgICAgICAgICAgIHZlY3Rvcjx1bmlxdWVfcHRyPEV4cHJlc3Np
b24+PiBjaGlsZHJlbjsKICAgICAgICAgICAgICAgICAgICAgY2hpbGRyZW4ucHVzaF9iYWNrKG1h
a2VfdW5pcTxCb3VuZENvbHVtblJlZkV4cHJlc3Npb24+KGNvbnRyaWJfcHJvai0+dHlwZXNbc2xv
dF0sCi0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKGNvbnRyaWJfaW5kZXgsIHNsb3Qp
KSk7CisgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKFRhYmxlSW5kZXgoY29udHJpYl9p
bmRleCksIFByb2plY3Rpb25JbmRleChzbG90KSkpKTsKICAgICAgICAgICAgICAgICAgICAgZmlu
YWxfYWdncy5wdXNoX2JhY2soQmluZEFnZ3JlZ2F0ZUJ5TmFtZShjb250ZXh0LCAic3VtIiwgc3Rk
Ojptb3ZlKGNoaWxkcmVuKSkpOwogICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgIH0gZWxz
ZSBpZiAoZm4gPT0gIk1JTiIgfHwgZm4gPT0gIk1BWCIpIHsKICAgICAgICAgICAgICAgICBhdXRv
IHNsb3QgPSBzdW1fc2xvdHNbYV07CiAgICAgICAgICAgICAgICAgdmVjdG9yPHVuaXF1ZV9wdHI8
RXhwcmVzc2lvbj4+IGNoaWxkcmVuOwogICAgICAgICAgICAgICAgIGNoaWxkcmVuLnB1c2hfYmFj
ayhtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihjb250cmliX3Byb2otPnR5cGVz
W3Nsb3RdLAotICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKGNvbnRyaWJfaW5kZXgsIHNsb3Qp
KSk7CisgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgIENvbHVtbkJpbmRpbmcoVGFibGVJbmRleChjb250cmliX2luZGV4
KSwgUHJvamVjdGlvbkluZGV4KHNsb3QpKSkpOwogICAgICAgICAgICAgICAgIGZpbmFsX2FnZ3Mu
cHVzaF9iYWNrKEJpbmRBZ2dyZWdhdGVCeU5hbWUoY29udGV4dCwgU3RyaW5nVXRpbDo6TG93ZXIo
Zm4pLCBzdGQ6Om1vdmUoY2hpbGRyZW4pKSk7CiAgICAgICAgICAgICB9IGVsc2UgewogICAgICAg
ICAgICAgICAgIGF1dG8gc2xvdCA9IHN1bV9zbG90c1thXTsKICAgICAgICAgICAgICAgICB2ZWN0
b3I8dW5pcXVlX3B0cjxFeHByZXNzaW9uPj4gY2hpbGRyZW47CiAgICAgICAgICAgICAgICAgY2hp
bGRyZW4ucHVzaF9iYWNrKG1ha2VfdW5pcTxCb3VuZENvbHVtblJlZkV4cHJlc3Npb24+KGNvbnRy
aWJfcHJvai0+dHlwZXNbc2xvdF0sCi0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbHVtbkJpbmRpbmcoY29udHJp
Yl9pbmRleCwgc2xvdCkpKTsKKyAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29sdW1uQmluZGluZyhUYWJsZUluZGV4
KGNvbnRyaWJfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgoc2xvdCkpKSk7CiAgICAgICAgICAgICAg
ICAgZmluYWxfYWdncy5wdXNoX2JhY2soQmluZEFnZ3JlZ2F0ZUJ5TmFtZShjb250ZXh0LCAic3Vt
Iiwgc3RkOjptb3ZlKGNoaWxkcmVuKSkpOwogICAgICAgICAgICAgfQogICAgICAgICB9Ci0gICAg
ICAgIGF1dG8gZmluYWxfYWdnID0gbWFrZV91bmlxPExvZ2ljYWxBZ2dyZWdhdGU+KERDb25zdGFu
dHM6OklOVkFMSURfSU5ERVgsIGZpbmFsX2FnZ19pbmRleCwgc3RkOjptb3ZlKGZpbmFsX2FnZ3Mp
KTsKKyAgICAgICAgYXV0byBmaW5hbF9hZ2cgPSBtYWtlX3VuaXE8TG9naWNhbEFnZ3JlZ2F0ZT4o
VGFibGVJbmRleChEQ29uc3RhbnRzOjpJTlZBTElEX0lOREVYKSwgZmluYWxfYWdnX2luZGV4LCBz
dGQ6Om1vdmUoZmluYWxfYWdncykpOwogICAgICAgICBmaW5hbF9hZ2ctPmNoaWxkcmVuLnB1c2hf
YmFjayhzdGQ6Om1vdmUoY29udHJpYl9wcm9qKSk7CiAgICAgICAgIGZpbmFsX2FnZy0+UmVzb2x2
ZU9wZXJhdG9yVHlwZXMoKTsKIApAQCAtNTQ2LDE5ICs1NDQsMTkgQEAgYm9vbCBUcnlSZXdyaXRl
TmF0aXZlQnVpbGRQcmVhZ2coQ2xpZW50Q29udGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRp
bWl6ZXIsIHUKICAgICAgICAgICAgIHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4gZmluYWxfZXhwcjsK
ICAgICAgICAgICAgIGlmIChpbmZvLmZuID09ICJBVkciKSB7CiAgICAgICAgICAgICAgICAgYXV0
byBudW1fcmVmID0gbWFrZV91bmlxPEJvdW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oZmluYWxfYWdn
LT50eXBlc1tzdW1fc2xvdHNbYV1dLAotICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbHVtbkJpbmRpbmcoZmluYWxfYWdn
X2luZGV4LCBzdW1fc2xvdHNbYV0pKTsKKyAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKFRhYmxlSW5k
ZXgoZmluYWxfYWdnX2luZGV4KSwgUHJvamVjdGlvbkluZGV4KHN1bV9zbG90c1thXSkpKTsKICAg
ICAgICAgICAgICAgICBhdXRvIGRlbl9yZWYgPSBtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHBy
ZXNzaW9uPihmaW5hbF9hZ2ctPnR5cGVzW2NvdW50X3Nsb3RzW2FdXSwKLSAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1
bW5CaW5kaW5nKGZpbmFsX2FnZ19pbmRleCwgY291bnRfc2xvdHNbYV0pKTsKKyAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBD
b2x1bW5CaW5kaW5nKFRhYmxlSW5kZXgoZmluYWxfYWdnX2luZGV4KSwgUHJvamVjdGlvbkluZGV4
KGNvdW50X3Nsb3RzW2FdKSkpOwogICAgICAgICAgICAgICAgIGF1dG8gY2FzdF9udW0gPSBCb3Vu
ZENhc3RFeHByZXNzaW9uOjpBZGRDYXN0VG9UeXBlKGNvbnRleHQsIHN0ZDo6bW92ZShudW1fcmVm
KSwgcmVzdWx0X3R5cGUpOwogICAgICAgICAgICAgICAgIGF1dG8gY2FzdF9kZW4gPSBCb3VuZENh
c3RFeHByZXNzaW9uOjpBZGRDYXN0VG9UeXBlKGNvbnRleHQsIHN0ZDo6bW92ZShkZW5fcmVmKSwg
cmVzdWx0X3R5cGUpOwogICAgICAgICAgICAgICAgIGZpbmFsX2V4cHIgPSBvcHRpbWl6ZXIuQmlu
ZFNjYWxhckZ1bmN0aW9uKCIvIiwgc3RkOjptb3ZlKGNhc3RfbnVtKSwgc3RkOjptb3ZlKGNhc3Rf
ZGVuKSk7CiAgICAgICAgICAgICB9IGVsc2UgaWYgKGluZm8uZm4gPT0gIk1JTiIgfHwgaW5mby5m
biA9PSAiTUFYIikgewogICAgICAgICAgICAgICAgIGF1dG8gc3VtX3JlZiA9IG1ha2VfdW5pcTxC
b3VuZENvbHVtblJlZkV4cHJlc3Npb24+KGZpbmFsX2FnZy0+dHlwZXNbc3VtX3Nsb3RzW2FdXSwK
LSAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICBDb2x1bW5CaW5kaW5nKGZpbmFsX2FnZ19pbmRleCwgc3VtX3Nsb3RzW2FdKSk7
CisgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgQ29sdW1uQmluZGluZyhUYWJsZUluZGV4KGZpbmFsX2FnZ19pbmRleCksIFBy
b2plY3Rpb25JbmRleChzdW1fc2xvdHNbYV0pKSk7CiAgICAgICAgICAgICAgICAgZmluYWxfZXhw
ciA9IEJvdW5kQ2FzdEV4cHJlc3Npb246OkFkZENhc3RUb1R5cGUoY29udGV4dCwgc3RkOjptb3Zl
KHN1bV9yZWYpLCByZXN1bHRfdHlwZSk7CiAgICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAg
ICAgICAgIGF1dG8gc3VtX3JlZiA9IG1ha2VfdW5pcTxCb3VuZENvbHVtblJlZkV4cHJlc3Npb24+
KGZpbmFsX2FnZy0+dHlwZXNbc3VtX3Nsb3RzW2FdXSwKLSAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5n
KGZpbmFsX2FnZ19pbmRleCwgc3VtX3Nsb3RzW2FdKSk7CisgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29sdW1uQmluZGlu
ZyhUYWJsZUluZGV4KGZpbmFsX2FnZ19pbmRleCksIFByb2plY3Rpb25JbmRleChzdW1fc2xvdHNb
YV0pKSk7CiAgICAgICAgICAgICAgICAgZmluYWxfZXhwciA9IEJvdW5kQ2FzdEV4cHJlc3Npb246
OkFkZENhc3RUb1R5cGUoY29udGV4dCwgc3RkOjptb3ZlKHN1bV9yZWYpLCByZXN1bHRfdHlwZSk7
CiAgICAgICAgICAgICB9CiAgICAgICAgICAgICBmaW5hbF9leHBycy5wdXNoX2JhY2soc3RkOjpt
b3ZlKGZpbmFsX2V4cHIpKTsKQEAgLTU2NiwxOCArNTY0LDE4IEBAIGJvb2wgVHJ5UmV3cml0ZU5h
dGl2ZUJ1aWxkUHJlYWdnKENsaWVudENvbnRleHQgJmNvbnRleHQsIE9wdGltaXplciAmb3B0aW1p
emVyLCB1CiAgICAgICAgIGF1dG8gZmluYWxfcHJvaiA9IG1ha2VfdW5pcTxMb2dpY2FsUHJvamVj
dGlvbj4oZmluYWxfcHJval9pbmRleCwgc3RkOjptb3ZlKGZpbmFsX2V4cHJzKSk7CiAgICAgICAg
IGZpbmFsX3Byb2otPmNoaWxkcmVuLnB1c2hfYmFjayhzdGQ6Om1vdmUoZmluYWxfYWdnKSk7CiAg
ICAgICAgIGZpbmFsX3Byb2otPlJlc29sdmVPcGVyYXRvclR5cGVzKCk7Ci0gICAgICAgIG91dHB1
dF9pbmRleCA9IGZpbmFsX3Byb2pfaW5kZXg7CisgICAgICAgIG91dHB1dF9pbmRleCA9IGZpbmFs
X3Byb2pfaW5kZXguaW5kZXg7CiAgICAgICAgIG91dHB1dF9iYXNlID0gMDsKICAgICAgICAgcmVw
bGFjZW1lbnQgPSBzdGQ6Om1vdmUoZmluYWxfcHJvaik7CiAgICAgfQogCiAgICAgaWYgKGhhc19w
YXJlbnQpIHsKICAgICAgICAgZm9yIChpZHhfdCBhID0gMDsgYSA8IGFnZy5leHByZXNzaW9ucy5z
aXplKCk7IGErKykgewotICAgICAgICAgICAgc3RhdGUucmVwbGFjZW1lbnRfYmluZGluZ3MuZW1w
bGFjZV9iYWNrKENvbHVtbkJpbmRpbmcoYWdnLmFnZ3JlZ2F0ZV9pbmRleCwgYSksCi0gICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29sdW1uQmluZGlu
ZyhvdXRwdXRfaW5kZXgsIG91dHB1dF9iYXNlICsgYSkpOworICAgICAgICAgICAgc3RhdGUucmVw
bGFjZW1lbnRfYmluZGluZ3MuZW1wbGFjZV9iYWNrKENvbHVtbkJpbmRpbmcoVGFibGVJbmRleChh
Z2cuYWdncmVnYXRlX2luZGV4KSwgUHJvamVjdGlvbkluZGV4KGEpKSwKKyAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKFRhYmxl
SW5kZXgob3V0cHV0X2luZGV4KSwgUHJvamVjdGlvbkluZGV4KG91dHB1dF9iYXNlICsgYSkpKTsK
ICAgICAgICAgfQogICAgICAgICBpZiAoZ3JvdXBlZF9ieV9qb2luX2tleSB8fCBncm91cGVkX2J5
X2pvaW5fa2V5X3N1YnNldCkgewotICAgICAgICAgICAgc3RhdGUucmVwbGFjZW1lbnRfYmluZGlu
Z3MuZW1wbGFjZV9iYWNrKENvbHVtbkJpbmRpbmcoYWdnLmdyb3VwX2luZGV4LCAwKSwgQ29sdW1u
QmluZGluZyhvdXRwdXRfaW5kZXgsIDApKTsKKyAgICAgICAgICAgIHN0YXRlLnJlcGxhY2VtZW50
X2JpbmRpbmdzLmVtcGxhY2VfYmFjayhDb2x1bW5CaW5kaW5nKFRhYmxlSW5kZXgoYWdnLmdyb3Vw
X2luZGV4KSwgUHJvamVjdGlvbkluZGV4KDApKSwgQ29sdW1uQmluZGluZyhUYWJsZUluZGV4KG91
dHB1dF9pbmRleCksIFByb2plY3Rpb25JbmRleCgwKSkpOwogICAgICAgICB9CiAgICAgfQogICAg
IGlmIChBZ2dKb2luVHJhY2VFbmFibGVkKCkpIHsKZGlmZiAtLWdpdCBhL3NyYy9hZ2dqb2luX3Jl
d3JpdGVfZmluYWxfYmFnLmNwcCBiL3NyYy9hZ2dqb2luX3Jld3JpdGVfZmluYWxfYmFnLmNwcApp
bmRleCAzNThhYTJlLi40ZDUxZTZiIDEwMDY0NAotLS0gYS9zcmMvYWdnam9pbl9yZXdyaXRlX2Zp
bmFsX2JhZy5jcHAKKysrIGIvc3JjL2FnZ2pvaW5fcmV3cml0ZV9maW5hbF9iYWcuY3BwCkBAIC00
MSw3ICs0MSw3IEBAIHN0YXRpYyBib29sIElzU2luZ2xlQ29uZElubmVySm9pbihMb2dpY2FsT3Bl
cmF0b3IgJm9wKSB7CiAgICAgaWYgKGpvaW4uam9pbl90eXBlICE9IEpvaW5UeXBlOjpJTk5FUiB8
fCBqb2luLmNvbmRpdGlvbnMuc2l6ZSgpICE9IDEpIHsKICAgICAgICAgcmV0dXJuIGZhbHNlOwog
ICAgIH0KLSAgICByZXR1cm4gam9pbi5jb25kaXRpb25zWzBdLmNvbXBhcmlzb24gPT0gRXhwcmVz
c2lvblR5cGU6OkNPTVBBUkVfRVFVQUw7CisgICAgcmV0dXJuIGpvaW4uY29uZGl0aW9uc1swXS5H
ZXRDb21wYXJpc29uVHlwZSgpID09IEV4cHJlc3Npb25UeXBlOjpDT01QQVJFX0VRVUFMOwogfQog
CiBzdGF0aWMgYm9vbCBFeHRyYWN0QmluZGluZyhFeHByZXNzaW9uICZleHByLCBDb2x1bW5CaW5k
aW5nICZiaW5kaW5nKSB7CkBAIC03MCw3ICs3MCw3IEBAIHN0YXRpYyBib29sIEJpbmRpbmdJblNl
dChjb25zdCB2ZWN0b3I8Q29sdW1uQmluZGluZz4gJmJpbmRpbmdzLCBjb25zdCBDb2x1bW5CaW5k
CiAKIHN0YXRpYyBib29sIE1hdGNoRmluYWxCYWdQYXR0ZXJuKExvZ2ljYWxDb21wYXJpc29uSm9p
biAmdG9wX2pvaW4sIEZpbmFsQmFnUGF0dGVybiAmcGF0dGVybikgewogICAgIGlmICh0b3Bfam9p
bi5qb2luX3R5cGUgIT0gSm9pblR5cGU6OklOTkVSIHx8IHRvcF9qb2luLmNvbmRpdGlvbnMuc2l6
ZSgpICE9IDEgfHwKLSAgICAgICAgdG9wX2pvaW4uY29uZGl0aW9uc1swXS5jb21wYXJpc29uICE9
IEV4cHJlc3Npb25UeXBlOjpDT01QQVJFX0VRVUFMKSB7CisgICAgICAgIHRvcF9qb2luLmNvbmRp
dGlvbnNbMF0uR2V0Q29tcGFyaXNvblR5cGUoKSAhPSBFeHByZXNzaW9uVHlwZTo6Q09NUEFSRV9F
UVVBTCkgewogICAgICAgICByZXR1cm4gZmFsc2U7CiAgICAgfQogCkBAIC05Miw4ICs5Miw4IEBA
IHN0YXRpYyBib29sIE1hdGNoRmluYWxCYWdQYXR0ZXJuKExvZ2ljYWxDb21wYXJpc29uSm9pbiAm
dG9wX2pvaW4sIEZpbmFsQmFnUGF0dGVyCiAgICAgYXV0byB0YWlsX2JpbmRpbmdzID0gdG9wX2pv
aW4uY2hpbGRyZW5bdGFpbF9pZHhdLT5HZXRDb2x1bW5CaW5kaW5ncygpOwogCiAgICAgQ29sdW1u
QmluZGluZyB0b3BfbGVmdF9iaW5kaW5nLCB0b3BfcmlnaHRfYmluZGluZzsKLSAgICBpZiAoIUV4
dHJhY3RCaW5kaW5nKCp0b3Bfam9pbi5jb25kaXRpb25zWzBdLmxlZnQsIHRvcF9sZWZ0X2JpbmRp
bmcpIHx8Ci0gICAgICAgICFFeHRyYWN0QmluZGluZygqdG9wX2pvaW4uY29uZGl0aW9uc1swXS5y
aWdodCwgdG9wX3JpZ2h0X2JpbmRpbmcpKSB7CisgICAgaWYgKCFFeHRyYWN0QmluZGluZyh0b3Bf
am9pbi5jb25kaXRpb25zWzBdLkdldExIUygpLCB0b3BfbGVmdF9iaW5kaW5nKSB8fAorICAgICAg
ICAhRXh0cmFjdEJpbmRpbmcodG9wX2pvaW4uY29uZGl0aW9uc1swXS5HZXRSSFMoKSwgdG9wX3Jp
Z2h0X2JpbmRpbmcpKSB7CiAgICAgICAgIHJldHVybiBmYWxzZTsKICAgICB9CiAKQEAgLTEyMiw4
ICsxMjIsOCBAQCBzdGF0aWMgYm9vbCBNYXRjaEZpbmFsQmFnUGF0dGVybihMb2dpY2FsQ29tcGFy
aXNvbkpvaW4gJnRvcF9qb2luLCBGaW5hbEJhZ1BhdHRlcgogICAgIGF1dG8gYnJpZGdlX2JpbmRp
bmdzID0gbmVzdGVkX2pvaW4uY2hpbGRyZW5bYnJpZGdlX2NoaWxkX2lkeF0tPkdldENvbHVtbkJp
bmRpbmdzKCk7CiAKICAgICBDb2x1bW5CaW5kaW5nIGlubmVyX2xlZnRfYmluZGluZywgaW5uZXJf
cmlnaHRfYmluZGluZzsKLSAgICBpZiAoIUV4dHJhY3RCaW5kaW5nKCpuZXN0ZWRfam9pbi5jb25k
aXRpb25zWzBdLmxlZnQsIGlubmVyX2xlZnRfYmluZGluZykgfHwKLSAgICAgICAgIUV4dHJhY3RC
aW5kaW5nKCpuZXN0ZWRfam9pbi5jb25kaXRpb25zWzBdLnJpZ2h0LCBpbm5lcl9yaWdodF9iaW5k
aW5nKSkgeworICAgIGlmICghRXh0cmFjdEJpbmRpbmcobmVzdGVkX2pvaW4uY29uZGl0aW9uc1sw
XS5HZXRMSFMoKSwgaW5uZXJfbGVmdF9iaW5kaW5nKSB8fAorICAgICAgICAhRXh0cmFjdEJpbmRp
bmcobmVzdGVkX2pvaW4uY29uZGl0aW9uc1swXS5HZXRSSFMoKSwgaW5uZXJfcmlnaHRfYmluZGlu
ZykpIHsKICAgICAgICAgcmV0dXJuIGZhbHNlOwogICAgIH0KIApAQCAtMjMzLDEwICsyMzMsMTAg
QEAgYm9vbCBUcnlSZXdyaXRlTmF0aXZlRmluYWxCYWdQcmVhZ2coQ2xpZW50Q29udGV4dCAmY29u
dGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZXIKICAgICBib29sIHNhd190YWlsX3BheWxvYWQgPSBm
YWxzZTsKICAgICBmb3IgKGF1dG8gJmV4cHIgOiBhZ2cuZXhwcmVzc2lvbnMpIHsKICAgICAgICAg
YXV0byAmYmEgPSBleHByLT5DYXN0PEJvdW5kQWdncmVnYXRlRXhwcmVzc2lvbj4oKTsKLSAgICAg
ICAgYXV0byBmbiA9IFN0cmluZ1V0aWw6OlVwcGVyKGJhLmZ1bmN0aW9uLm5hbWUpOworICAgICAg
ICBhdXRvIGZuID0gU3RyaW5nVXRpbDo6VXBwZXIoYmEuZnVuY3Rpb24uR2V0TmFtZSgpKTsKICAg
ICAgICAgRmluYWxCYWdBZ2dJbmZvIGluZm87CiAgICAgICAgIGluZm8uZm4gPSBmbjsKLSAgICAg
ICAgaW5mby5yZXN1bHRfdHlwZSA9IGJhLnJldHVybl90eXBlOworICAgICAgICBpbmZvLnJlc3Vs
dF90eXBlID0gYmEuR2V0UmV0dXJuVHlwZSgpOwogCiAgICAgICAgIGlmIChmbiAhPSAiU1VNIiAm
JiBmbiAhPSAiQ09VTlQiICYmIGZuICE9ICJDT1VOVF9TVEFSIiAmJiBmbiAhPSAiQVZHIiAmJiBm
biAhPSAiTUlOIiAmJiBmbiAhPSAiTUFYIikgewogICAgICAgICAgICAgcmV0dXJuIGZhbHNlOwpA
QCAtMjY1LDE0ICsyNjUsMTQgQEAgYm9vbCBUcnlSZXdyaXRlTmF0aXZlRmluYWxCYWdQcmVhZ2co
Q2xpZW50Q29udGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZXIKICAgICAgICAgICAg
IGlmIChmbiA9PSAiTUlOIiB8fCBmbiA9PSAiTUFYIikgewogICAgICAgICAgICAgICAgIHJldHVy
biBmYWxzZTsKICAgICAgICAgICAgIH0KLSAgICAgICAgICAgIGlmICgoZm4gPT0gIlNVTSIgfHwg
Zm4gPT0gIkFWRyIpICYmICFiYS5jaGlsZHJlblswXS0+cmV0dXJuX3R5cGUuSXNOdW1lcmljKCkp
IHsKKyAgICAgICAgICAgIGlmICgoZm4gPT0gIlNVTSIgfHwgZm4gPT0gIkFWRyIpICYmICFiYS5j
aGlsZHJlblswXS0+R2V0UmV0dXJuVHlwZSgpLklzTnVtZXJpYygpKSB7CiAgICAgICAgICAgICAg
ICAgcmV0dXJuIGZhbHNlOwogICAgICAgICAgICAgfQogICAgICAgICAgICAgaW5mby5vbl9oZWFk
ID0gdHJ1ZTsKICAgICAgICAgICAgIGluZm8uc2lkZV9jb2wgPSBGaW5kQmluZGluZ0luZGV4KHBh
dHRlcm4uaGVhZF9iaW5kaW5ncywgYmluZGluZyk7CiAgICAgICAgICAgICBzYXdfaGVhZF9wYXls
b2FkID0gdHJ1ZTsKICAgICAgICAgfSBlbHNlIGlmIChCaW5kaW5nSW5TZXQocGF0dGVybi50YWls
X2JpbmRpbmdzLCBiaW5kaW5nKSkgewotICAgICAgICAgICAgaWYgKChmbiA9PSAiU1VNIiB8fCBm
biA9PSAiQVZHIikgJiYgIWJhLmNoaWxkcmVuWzBdLT5yZXR1cm5fdHlwZS5Jc051bWVyaWMoKSkg
eworICAgICAgICAgICAgaWYgKChmbiA9PSAiU1VNIiB8fCBmbiA9PSAiQVZHIikgJiYgIWJhLmNo
aWxkcmVuWzBdLT5HZXRSZXR1cm5UeXBlKCkuSXNOdW1lcmljKCkpIHsKICAgICAgICAgICAgICAg
ICByZXR1cm4gZmFsc2U7CiAgICAgICAgICAgICB9CiAgICAgICAgICAgICBpbmZvLm9uX2hlYWQg
PSBmYWxzZTsKQEAgLTM0MCwxNyArMzQwLDE1IEBAIGJvb2wgVHJ5UmV3cml0ZU5hdGl2ZUZpbmFs
QmFnUHJlYWdnKENsaWVudENvbnRleHQgJmNvbnRleHQsIE9wdGltaXplciAmb3B0aW1pemVyCiAg
ICAgaGVhZF9wcmVhZ2ctPlJlc29sdmVPcGVyYXRvclR5cGVzKCk7CiAKICAgICBhdXRvIHRhaWxf
am9pbiA9IG1ha2VfdW5pcTxMb2dpY2FsQ29tcGFyaXNvbkpvaW4+KEpvaW5UeXBlOjpJTk5FUik7
Ci0gICAgSm9pbkNvbmRpdGlvbiB0YWlsX2NvbmQ7Ci0gICAgdGFpbF9jb25kLmNvbXBhcmlzb24g
PSBFeHByZXNzaW9uVHlwZTo6Q09NUEFSRV9FUVVBTDsKLSAgICB0YWlsX2NvbmQubGVmdCA9IG1h
a2VfdW5pcTxCb3VuZENvbHVtblJlZkV4cHJlc3Npb24+KHBhdHRlcm4uYnJpZGdlX3R5cGVzW3Bh
dHRlcm4uYnJpZGdlX3RhaWxfa2V5X2lkeF0sCisgICAgdW5pcXVlX3B0cjxFeHByZXNzaW9uPiB0
YWlsX2xocyA9IG1ha2VfdW5pcTxCb3VuZENvbHVtblJlZkV4cHJlc3Npb24+KHBhdHRlcm4uYnJp
ZGdlX3R5cGVzW3BhdHRlcm4uYnJpZGdlX3RhaWxfa2V5X2lkeF0sCiAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwYXR0ZXJuLmJyaWRnZV9i
aW5kaW5nc1twYXR0ZXJuLmJyaWRnZV90YWlsX2tleV9pZHhdKTsKLSAgICB0YWlsX2NvbmQucmln
aHQgPSBtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihwYXR0ZXJuLnRhaWxfdHlw
ZXNbcGF0dGVybi50YWlsX2tleV9pZHhdLAorICAgIHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4gdGFp
bF9yaHMgPSBtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihwYXR0ZXJuLnRhaWxf
dHlwZXNbcGF0dGVybi50YWlsX2tleV9pZHhdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBhdHRlcm4udGFpbF9iaW5kaW5nc1twYXR0
ZXJuLnRhaWxfa2V5X2lkeF0pOwogICAgIGlmIChwYXR0ZXJuLmJyaWRnZV90eXBlc1twYXR0ZXJu
LmJyaWRnZV90YWlsX2tleV9pZHhdICE9IHBhdHRlcm4udGFpbF90eXBlc1twYXR0ZXJuLnRhaWxf
a2V5X2lkeF0pIHsKLSAgICAgICAgdGFpbF9jb25kLnJpZ2h0ID0gQm91bmRDYXN0RXhwcmVzc2lv
bjo6QWRkQ2FzdFRvVHlwZShjb250ZXh0LCBzdGQ6Om1vdmUodGFpbF9jb25kLnJpZ2h0KSwKKyAg
ICAgICAgdGFpbF9yaHMgPSBCb3VuZENhc3RFeHByZXNzaW9uOjpBZGRDYXN0VG9UeXBlKGNvbnRl
eHQsIHN0ZDo6bW92ZSh0YWlsX3JocyksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcGF0dGVybi5icmlkZ2VfdHlwZXNbcGF0dGVy
bi5icmlkZ2VfdGFpbF9rZXlfaWR4XSk7CiAgICAgfQotICAgIHRhaWxfam9pbi0+Y29uZGl0aW9u
cy5wdXNoX2JhY2soc3RkOjptb3ZlKHRhaWxfY29uZCkpOworICAgIHRhaWxfam9pbi0+Y29uZGl0
aW9ucy5lbXBsYWNlX2JhY2soc3RkOjptb3ZlKHRhaWxfbGhzKSwgc3RkOjptb3ZlKHRhaWxfcmhz
KSwgRXhwcmVzc2lvblR5cGU6OkNPTVBBUkVfRVFVQUwpOwogICAgIHRhaWxfam9pbi0+Y2hpbGRy
ZW4ucHVzaF9iYWNrKHN0ZDo6bW92ZShicmlkZ2VfY2hpbGQpKTsKICAgICB0YWlsX2pvaW4tPmNo
aWxkcmVuLnB1c2hfYmFjayhzdGQ6Om1vdmUodGFpbF9jaGlsZCkpOwogICAgIHRhaWxfam9pbi0+
UmVzb2x2ZU9wZXJhdG9yVHlwZXMoKTsKQEAgLTQxMCwxNSArNDA4LDEzIEBAIGJvb2wgVHJ5UmV3
cml0ZU5hdGl2ZUZpbmFsQmFnUHJlYWdnKENsaWVudENvbnRleHQgJmNvbnRleHQsIE9wdGltaXpl
ciAmb3B0aW1pemVyCiAgICAgdGFpbF9wcmVhZ2ctPlJlc29sdmVPcGVyYXRvclR5cGVzKCk7CiAK
ICAgICBhdXRvIGZpbmFsX2pvaW4gPSBtYWtlX3VuaXE8TG9naWNhbENvbXBhcmlzb25Kb2luPihK
b2luVHlwZTo6SU5ORVIpOwotICAgIEpvaW5Db25kaXRpb24gZmluYWxfY29uZDsKLSAgICBmaW5h
bF9jb25kLmNvbXBhcmlzb24gPSBFeHByZXNzaW9uVHlwZTo6Q09NUEFSRV9FUVVBTDsKLSAgICBm
aW5hbF9jb25kLmxlZnQgPSBtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihoZWFk
X3ByZWFnZy0+dHlwZXNbMF0sIENvbHVtbkJpbmRpbmcoaGVhZF9ncm91cF9pbmRleCwgMCkpOwot
ICAgIGZpbmFsX2NvbmQucmlnaHQgPSBtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9u
Pih0YWlsX3ByZWFnZy0+dHlwZXNbMF0sIENvbHVtbkJpbmRpbmcodGFpbF9ncm91cF9pbmRleCwg
MCkpOworICAgIHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4gZmluYWxfbGhzID0gbWFrZV91bmlxPEJv
dW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oaGVhZF9wcmVhZ2ctPnR5cGVzWzBdLCBDb2x1bW5CaW5k
aW5nKFRhYmxlSW5kZXgoaGVhZF9ncm91cF9pbmRleCksIFByb2plY3Rpb25JbmRleCgwKSkpOwor
ICAgIHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4gZmluYWxfcmhzID0gbWFrZV91bmlxPEJvdW5kQ29s
dW1uUmVmRXhwcmVzc2lvbj4odGFpbF9wcmVhZ2ctPnR5cGVzWzBdLCBDb2x1bW5CaW5kaW5nKFRh
YmxlSW5kZXgodGFpbF9ncm91cF9pbmRleCksIFByb2plY3Rpb25JbmRleCgwKSkpOwogICAgIGlm
IChoZWFkX3ByZWFnZy0+dHlwZXNbMF0gIT0gdGFpbF9wcmVhZ2ctPnR5cGVzWzBdKSB7Ci0gICAg
ICAgIGZpbmFsX2NvbmQucmlnaHQgPSBCb3VuZENhc3RFeHByZXNzaW9uOjpBZGRDYXN0VG9UeXBl
KGNvbnRleHQsIHN0ZDo6bW92ZShmaW5hbF9jb25kLnJpZ2h0KSwKKyAgICAgICAgZmluYWxfcmhz
ID0gQm91bmRDYXN0RXhwcmVzc2lvbjo6QWRkQ2FzdFRvVHlwZShjb250ZXh0LCBzdGQ6Om1vdmUo
ZmluYWxfcmhzKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgaGVhZF9wcmVhZ2ctPnR5cGVzWzBdKTsKICAgICB9Ci0gICAgZmlu
YWxfam9pbi0+Y29uZGl0aW9ucy5wdXNoX2JhY2soc3RkOjptb3ZlKGZpbmFsX2NvbmQpKTsKKyAg
ICBmaW5hbF9qb2luLT5jb25kaXRpb25zLmVtcGxhY2VfYmFjayhzdGQ6Om1vdmUoZmluYWxfbGhz
KSwgc3RkOjptb3ZlKGZpbmFsX3JocyksIEV4cHJlc3Npb25UeXBlOjpDT01QQVJFX0VRVUFMKTsK
ICAgICBmaW5hbF9qb2luLT5jaGlsZHJlbi5wdXNoX2JhY2soc3RkOjptb3ZlKGhlYWRfcHJlYWdn
KSk7CiAgICAgZmluYWxfam9pbi0+Y2hpbGRyZW4ucHVzaF9iYWNrKHN0ZDo6bW92ZSh0YWlsX3By
ZWFnZykpOwogICAgIGZpbmFsX2pvaW4tPlJlc29sdmVPcGVyYXRvclR5cGVzKCk7CkBAIC01MTEs
NyArNTA3LDcgQEAgYm9vbCBUcnlSZXdyaXRlTmF0aXZlRmluYWxCYWdQcmVhZ2coQ2xpZW50Q29u
dGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZXIKICAgICAgICAgaWYgKG9wLT5oYXNf
ZXN0aW1hdGVkX2NhcmRpbmFsaXR5KSB7CiAgICAgICAgICAgICBwcm9qLT5TZXRFc3RpbWF0ZWRD
YXJkaW5hbGl0eShvcC0+ZXN0aW1hdGVkX2NhcmRpbmFsaXR5KTsKICAgICAgICAgfQotICAgICAg
ICBvdXRwdXRfaW5kZXggPSBwcm9qX2luZGV4OworICAgICAgICBvdXRwdXRfaW5kZXggPSBwcm9q
X2luZGV4LmluZGV4OwogICAgICAgICBvdXRwdXRfYmFzZSA9IDE7CiAgICAgICAgIHJlcGxhY2Vt
ZW50ID0gc3RkOjptb3ZlKHByb2opOwogICAgIH0gZWxzZSB7CkBAIC01NjcsMjIgKzU2MywyMiBA
QCBib29sIFRyeVJld3JpdGVOYXRpdmVGaW5hbEJhZ1ByZWFnZyhDbGllbnRDb250ZXh0ICZjb250
ZXh0LCBPcHRpbWl6ZXIgJm9wdGltaXplcgogICAgICAgICAgICAgaWYgKGluZm8uZm4gPT0gIkFW
RyIpIHsKICAgICAgICAgICAgICAgICBmb3IgKGF1dG8gc2xvdCA6IHtzdW1fc2xvdHNbYV0sIGNv
dW50X3Nsb3RzW2FdfSkgewogICAgICAgICAgICAgICAgICAgICB2ZWN0b3I8dW5pcXVlX3B0cjxF
eHByZXNzaW9uPj4gY2hpbGRyZW47Ci0gICAgICAgICAgICAgICAgICAgIGNoaWxkcmVuLnB1c2hf
YmFjayhtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihjb250cmliX3Byb2otPnR5
cGVzW3Nsb3RdLCBDb2x1bW5CaW5kaW5nKGNvbnRyaWJfaW5kZXgsIHNsb3QpKSk7CisgICAgICAg
ICAgICAgICAgICAgIGNoaWxkcmVuLnB1c2hfYmFjayhtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZF
eHByZXNzaW9uPihjb250cmliX3Byb2otPnR5cGVzW3Nsb3RdLCBDb2x1bW5CaW5kaW5nKFRhYmxl
SW5kZXgoY29udHJpYl9pbmRleCksIFByb2plY3Rpb25JbmRleChzbG90KSkpKTsKICAgICAgICAg
ICAgICAgICAgICAgZmluYWxfYWdnc19leHBycy5wdXNoX2JhY2soQmluZEFnZ3JlZ2F0ZUJ5TmFt
ZShjb250ZXh0LCAic3VtIiwgc3RkOjptb3ZlKGNoaWxkcmVuKSkpOwogICAgICAgICAgICAgICAg
IH0KICAgICAgICAgICAgIH0gZWxzZSBpZiAoaW5mby5mbiA9PSAiTUlOIiB8fCBpbmZvLmZuID09
ICJNQVgiKSB7CiAgICAgICAgICAgICAgICAgdmVjdG9yPHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4+
IGNoaWxkcmVuOwogICAgICAgICAgICAgICAgIGNoaWxkcmVuLnB1c2hfYmFjayhtYWtlX3VuaXE8
Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihjb250cmliX3Byb2otPnR5cGVzW3N1bV9zbG90c1th
XV0sCi0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgIENvbHVtbkJpbmRpbmcoY29udHJpYl9pbmRleCwgc3VtX3Nsb3Rz
W2FdKSkpOworICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKFRhYmxlSW5kZXgoY29udHJpYl9p
bmRleCksIFByb2plY3Rpb25JbmRleChzdW1fc2xvdHNbYV0pKSkpOwogICAgICAgICAgICAgICAg
IGZpbmFsX2FnZ3NfZXhwcnMucHVzaF9iYWNrKEJpbmRBZ2dyZWdhdGVCeU5hbWUoY29udGV4dCwg
U3RyaW5nVXRpbDo6TG93ZXIoaW5mby5mbiksIHN0ZDo6bW92ZShjaGlsZHJlbikpKTsKICAgICAg
ICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgdmVjdG9yPHVuaXF1ZV9wdHI8RXhwcmVz
c2lvbj4+IGNoaWxkcmVuOwogICAgICAgICAgICAgICAgIGNoaWxkcmVuLnB1c2hfYmFjayhtYWtl
X3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihjb250cmliX3Byb2otPnR5cGVzW3N1bV9z
bG90c1thXV0sCi0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgIENvbHVtbkJpbmRpbmcoY29udHJpYl9pbmRleCwgc3Vt
X3Nsb3RzW2FdKSkpOworICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKFRhYmxlSW5kZXgoY29u
dHJpYl9pbmRleCksIFByb2plY3Rpb25JbmRleChzdW1fc2xvdHNbYV0pKSkpOwogICAgICAgICAg
ICAgICAgIGZpbmFsX2FnZ3NfZXhwcnMucHVzaF9iYWNrKEJpbmRBZ2dyZWdhdGVCeU5hbWUoY29u
dGV4dCwgInN1bSIsIHN0ZDo6bW92ZShjaGlsZHJlbikpKTsKICAgICAgICAgICAgIH0KICAgICAg
ICAgfQotICAgICAgICBhdXRvIGZpbmFsX2FnZyA9IG1ha2VfdW5pcTxMb2dpY2FsQWdncmVnYXRl
PihEQ29uc3RhbnRzOjpJTlZBTElEX0lOREVYLCBmaW5hbF9hZ2dfaW5kZXgsIHN0ZDo6bW92ZShm
aW5hbF9hZ2dzX2V4cHJzKSk7CisgICAgICAgIGF1dG8gZmluYWxfYWdnID0gbWFrZV91bmlxPExv
Z2ljYWxBZ2dyZWdhdGU+KFRhYmxlSW5kZXgoRENvbnN0YW50czo6SU5WQUxJRF9JTkRFWCksIGZp
bmFsX2FnZ19pbmRleCwgc3RkOjptb3ZlKGZpbmFsX2FnZ3NfZXhwcnMpKTsKICAgICAgICAgZmlu
YWxfYWdnLT5jaGlsZHJlbi5wdXNoX2JhY2soc3RkOjptb3ZlKGNvbnRyaWJfcHJvaikpOwogICAg
ICAgICBmaW5hbF9hZ2ctPlJlc29sdmVPcGVyYXRvclR5cGVzKCk7CiAKQEAgLTU5NCwxNSArNTkw
LDE1IEBAIGJvb2wgVHJ5UmV3cml0ZU5hdGl2ZUZpbmFsQmFnUHJlYWdnKENsaWVudENvbnRleHQg
JmNvbnRleHQsIE9wdGltaXplciAmb3B0aW1pemVyCiAgICAgICAgICAgICB1bmlxdWVfcHRyPEV4
cHJlc3Npb24+IGZpbmFsX2V4cHI7CiAgICAgICAgICAgICBpZiAoaW5mby5mbiA9PSAiQVZHIikg
ewogICAgICAgICAgICAgICAgIGF1dG8gbnVtX3JlZiA9IG1ha2VfdW5pcTxCb3VuZENvbHVtblJl
ZkV4cHJlc3Npb24+KGZpbmFsX2FnZy0+dHlwZXNbc3VtX3Nsb3RzW2FdXSwKLSAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBD
b2x1bW5CaW5kaW5nKGZpbmFsX2FnZ19pbmRleCwgc3VtX3Nsb3RzW2FdKSk7CisgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
Q29sdW1uQmluZGluZyhUYWJsZUluZGV4KGZpbmFsX2FnZ19pbmRleCksIFByb2plY3Rpb25JbmRl
eChzdW1fc2xvdHNbYV0pKSk7CiAgICAgICAgICAgICAgICAgYXV0byBkZW5fcmVmID0gbWFrZV91
bmlxPEJvdW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oZmluYWxfYWdnLT50eXBlc1tjb3VudF9zbG90
c1thXV0sCi0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgQ29sdW1uQmluZGluZyhmaW5hbF9hZ2dfaW5kZXgsIGNvdW50X3Ns
b3RzW2FdKSk7CisgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgQ29sdW1uQmluZGluZyhUYWJsZUluZGV4KGZpbmFsX2FnZ19p
bmRleCksIFByb2plY3Rpb25JbmRleChjb3VudF9zbG90c1thXSkpKTsKICAgICAgICAgICAgICAg
ICBhdXRvIGNhc3RfbnVtID0gQm91bmRDYXN0RXhwcmVzc2lvbjo6QWRkQ2FzdFRvVHlwZShjb250
ZXh0LCBzdGQ6Om1vdmUobnVtX3JlZiksIGluZm8ucmVzdWx0X3R5cGUpOwogICAgICAgICAgICAg
ICAgIGF1dG8gY2FzdF9kZW4gPSBCb3VuZENhc3RFeHByZXNzaW9uOjpBZGRDYXN0VG9UeXBlKGNv
bnRleHQsIHN0ZDo6bW92ZShkZW5fcmVmKSwgaW5mby5yZXN1bHRfdHlwZSk7CiAgICAgICAgICAg
ICAgICAgZmluYWxfZXhwciA9IG9wdGltaXplci5CaW5kU2NhbGFyRnVuY3Rpb24oIi8iLCBzdGQ6
Om1vdmUoY2FzdF9udW0pLCBzdGQ6Om1vdmUoY2FzdF9kZW4pKTsKICAgICAgICAgICAgIH0gZWxz
ZSB7CiAgICAgICAgICAgICAgICAgYXV0byBzdW1fcmVmID0gbWFrZV91bmlxPEJvdW5kQ29sdW1u
UmVmRXhwcmVzc2lvbj4oZmluYWxfYWdnLT50eXBlc1tzdW1fc2xvdHNbYV1dLAotICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
IENvbHVtbkJpbmRpbmcoZmluYWxfYWdnX2luZGV4LCBzdW1fc2xvdHNbYV0pKTsKKyAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICBDb2x1bW5CaW5kaW5nKFRhYmxlSW5kZXgoZmluYWxfYWdnX2luZGV4KSwgUHJvamVjdGlvbklu
ZGV4KHN1bV9zbG90c1thXSkpKTsKICAgICAgICAgICAgICAgICBmaW5hbF9leHByID0gQm91bmRD
YXN0RXhwcmVzc2lvbjo6QWRkQ2FzdFRvVHlwZShjb250ZXh0LCBzdGQ6Om1vdmUoc3VtX3JlZiks
IGluZm8ucmVzdWx0X3R5cGUpOwogICAgICAgICAgICAgfQogICAgICAgICAgICAgZmluYWxfZXhw
cnMucHVzaF9iYWNrKHN0ZDo6bW92ZShmaW5hbF9leHByKSk7CkBAIC02MTMsMTggKzYwOSwxOCBA
QCBib29sIFRyeVJld3JpdGVOYXRpdmVGaW5hbEJhZ1ByZWFnZyhDbGllbnRDb250ZXh0ICZjb250
ZXh0LCBPcHRpbWl6ZXIgJm9wdGltaXplcgogICAgICAgICBpZiAob3AtPmhhc19lc3RpbWF0ZWRf
Y2FyZGluYWxpdHkpIHsKICAgICAgICAgICAgIGZpbmFsX3Byb2otPlNldEVzdGltYXRlZENhcmRp
bmFsaXR5KG9wLT5lc3RpbWF0ZWRfY2FyZGluYWxpdHkpOwogICAgICAgICB9Ci0gICAgICAgIG91
dHB1dF9pbmRleCA9IGZpbmFsX3Byb2pfaW5kZXg7CisgICAgICAgIG91dHB1dF9pbmRleCA9IGZp
bmFsX3Byb2pfaW5kZXguaW5kZXg7CiAgICAgICAgIG91dHB1dF9iYXNlID0gMDsKICAgICAgICAg
cmVwbGFjZW1lbnQgPSBzdGQ6Om1vdmUoZmluYWxfcHJvaik7CiAgICAgfQogCiAgICAgaWYgKGhh
c19wYXJlbnQpIHsKICAgICAgICAgaWYgKGdyb3VwZWQpIHsKLSAgICAgICAgICAgIHN0YXRlLnJl
cGxhY2VtZW50X2JpbmRpbmdzLmVtcGxhY2VfYmFjayhDb2x1bW5CaW5kaW5nKGFnZy5ncm91cF9p
bmRleCwgMCksIENvbHVtbkJpbmRpbmcob3V0cHV0X2luZGV4LCAwKSk7CisgICAgICAgICAgICBz
dGF0ZS5yZXBsYWNlbWVudF9iaW5kaW5ncy5lbXBsYWNlX2JhY2soQ29sdW1uQmluZGluZyhUYWJs
ZUluZGV4KGFnZy5ncm91cF9pbmRleCksIFByb2plY3Rpb25JbmRleCgwKSksIENvbHVtbkJpbmRp
bmcoVGFibGVJbmRleChvdXRwdXRfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgoMCkpKTsKICAgICAg
ICAgfQogICAgICAgICBmb3IgKGlkeF90IGEgPSAwOyBhIDwgYWdnLmV4cHJlc3Npb25zLnNpemUo
KTsgYSsrKSB7Ci0gICAgICAgICAgICBzdGF0ZS5yZXBsYWNlbWVudF9iaW5kaW5ncy5lbXBsYWNl
X2JhY2soQ29sdW1uQmluZGluZyhhZ2cuYWdncmVnYXRlX2luZGV4LCBhKSwKLSAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKG91
dHB1dF9pbmRleCwgb3V0cHV0X2Jhc2UgKyBhKSk7CisgICAgICAgICAgICBzdGF0ZS5yZXBsYWNl
bWVudF9iaW5kaW5ncy5lbXBsYWNlX2JhY2soQ29sdW1uQmluZGluZyhUYWJsZUluZGV4KGFnZy5h
Z2dyZWdhdGVfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgoYSkpLAorICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbHVtbkJpbmRpbmcoVGFibGVJbmRl
eChvdXRwdXRfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgob3V0cHV0X2Jhc2UgKyBhKSkpOwogICAg
ICAgICB9CiAgICAgfQogICAgIGlmIChBZ2dKb2luVHJhY2VFbmFibGVkKCkpIHsKZGlmZiAtLWdp
dCBhL3NyYy9hZ2dqb2luX3Jld3JpdGVfbWl4ZWQuY3BwIGIvc3JjL2FnZ2pvaW5fcmV3cml0ZV9t
aXhlZC5jcHAKaW5kZXggMWU0NjJmOC4uYjA0ZjZkMyAxMDA2NDQKLS0tIGEvc3JjL2FnZ2pvaW5f
cmV3cml0ZV9taXhlZC5jcHAKKysrIGIvc3JjL2FnZ2pvaW5fcmV3cml0ZV9taXhlZC5jcHAKQEAg
LTY1LDcgKzY1LDcgQEAgYm9vbCBUcnlSZXdyaXRlTmF0aXZlTWl4ZWRTaWRlUHJlYWdnKENsaWVu
dENvbnRleHQgJmNvbnRleHQsIE9wdGltaXplciAmb3B0aW1pemUKICAgICBib29sIHNhd19wYXls
b2FkX29uX3Byb2JlID0gZmFsc2U7CiAgICAgZm9yIChpZHhfdCBhID0gMDsgYSA8IGFnZy5leHBy
ZXNzaW9ucy5zaXplKCk7IGErKykgewogICAgICAgICBhdXRvICZiYSA9IGFnZy5leHByZXNzaW9u
c1thXS0+Q2FzdDxCb3VuZEFnZ3JlZ2F0ZUV4cHJlc3Npb24+KCk7Ci0gICAgICAgIGF1dG8gZm4g
PSBTdHJpbmdVdGlsOjpVcHBlcihiYS5mdW5jdGlvbi5uYW1lKTsKKyAgICAgICAgYXV0byBmbiA9
IFN0cmluZ1V0aWw6OlVwcGVyKGJhLmZ1bmN0aW9uLkdldE5hbWUoKSk7CiAgICAgICAgIGlmIChm
biA9PSAiQ09VTlRfU1RBUiIpIHsKICAgICAgICAgICAgIHNhd19wYXlsb2FkX29uX3Byb2JlID0g
dHJ1ZTsKICAgICAgICAgICAgIHNhd19wYXlsb2FkX29uX2J1aWxkID0gdHJ1ZTsKQEAgLTExOCwx
MCArMTE4LDEwIEBAIGJvb2wgVHJ5UmV3cml0ZU5hdGl2ZU1peGVkU2lkZVByZWFnZyhDbGllbnRD
b250ZXh0ICZjb250ZXh0LCBPcHRpbWl6ZXIgJm9wdGltaXplCiAgICAgYm9vbCBzYXdfYnVpbGRf
bGluZWFyX251bWVyaWMgPSBmYWxzZTsKICAgICBmb3IgKGlkeF90IGEgPSAwOyBhIDwgYWdnLmV4
cHJlc3Npb25zLnNpemUoKTsgYSsrKSB7CiAgICAgICAgIGF1dG8gJmJhID0gYWdnLmV4cHJlc3Np
b25zW2FdLT5DYXN0PEJvdW5kQWdncmVnYXRlRXhwcmVzc2lvbj4oKTsKLSAgICAgICAgYXV0byBm
biA9IFN0cmluZ1V0aWw6OlVwcGVyKGJhLmZ1bmN0aW9uLm5hbWUpOworICAgICAgICBhdXRvIGZu
ID0gU3RyaW5nVXRpbDo6VXBwZXIoYmEuZnVuY3Rpb24uR2V0TmFtZSgpKTsKICAgICAgICAgTWl4
ZWRBZ2dJbmZvIGluZm87CiAgICAgICAgIGluZm8uZm4gPSBmbjsKLSAgICAgICAgaW5mby5yZXN1
bHRfdHlwZSA9IGJhLnJldHVybl90eXBlOworICAgICAgICBpbmZvLnJlc3VsdF90eXBlID0gYmEu
R2V0UmV0dXJuVHlwZSgpOwogICAgICAgICBpZiAoZm4gIT0gIlNVTSIgJiYgZm4gIT0gIkNPVU5U
IiAmJiBmbiAhPSAiQ09VTlRfU1RBUiIgJiYgZm4gIT0gIkFWRyIgJiYgZm4gIT0gIk1JTiIgJiYg
Zm4gIT0gIk1BWCIpIHsKICAgICAgICAgICAgIGlmIChBZ2dKb2luVHJhY2VFbmFibGVkKCkpIGZw
cmludGYoc3RkZXJyLCAiW0FHR0pPSU5dIG5hdGl2ZS1taXhlZC1zaWRlIHNraXA6IHVuc3VwcG9y
dGVkIGFnZyBmbiAlc1xuIiwgZm4uY19zdHIoKSk7CiAgICAgICAgICAgICByZXR1cm4gZmFsc2U7
CkBAIC0xMzgsNyArMTM4LDcgQEAgYm9vbCBUcnlSZXdyaXRlTmF0aXZlTWl4ZWRTaWRlUHJlYWdn
KENsaWVudENvbnRleHQgJmNvbnRleHQsIE9wdGltaXplciAmb3B0aW1pemUKICAgICAgICAgICAg
IGlmIChBZ2dKb2luVHJhY2VFbmFibGVkKCkpIGZwcmludGYoc3RkZXJyLCAiW0FHR0pPSU5dIG5h
dGl2ZS1taXhlZC1zaWRlIHNraXA6IGVtcHR5IGFnZyBjaGlsZHJlblxuIik7CiAgICAgICAgICAg
ICByZXR1cm4gZmFsc2U7CiAgICAgICAgIH0KLSAgICAgICAgaWYgKChmbiA9PSAiU1VNIiB8fCBm
biA9PSAiQVZHIikgJiYgIWJhLmNoaWxkcmVuWzBdLT5yZXR1cm5fdHlwZS5Jc051bWVyaWMoKSkg
eworICAgICAgICBpZiAoKGZuID09ICJTVU0iIHx8IGZuID09ICJBVkciKSAmJiAhYmEuY2hpbGRy
ZW5bMF0tPkdldFJldHVyblR5cGUoKS5Jc051bWVyaWMoKSkgewogICAgICAgICAgICAgaWYgKEFn
Z0pvaW5UcmFjZUVuYWJsZWQoKSkgZnByaW50ZihzdGRlcnIsICJbQUdHSk9JTl0gbmF0aXZlLW1p
eGVkLXNpZGUgc2tpcDogbm9ubnVtZXJpYyBTVU0vQVZHIGlucHV0XG4iKTsKICAgICAgICAgICAg
IHJldHVybiBmYWxzZTsKICAgICAgICAgfQpAQCAtMTY4LDcgKzE2OCw3IEBAIGJvb2wgVHJ5UmV3
cml0ZU5hdGl2ZU1peGVkU2lkZVByZWFnZyhDbGllbnRDb250ZXh0ICZjb250ZXh0LCBPcHRpbWl6
ZXIgJm9wdGltaXplCiAgICAgICAgIH0KICAgICAgICAgaW5mby5zaWRlX2NvbCA9IHBheWxvYWRf
aWR4OwogICAgICAgICBib29sIGlzX2xpbmVhcl9udW1lcmljID0gZm4gPT0gIlNVTSIgfHwgZm4g
PT0gIkNPVU5UIiB8fCBmbiA9PSAiQ09VTlRfU1RBUiIgfHwgZm4gPT0gIkFWRyI7Ci0gICAgICAg
IGJvb2wgaXNfbm9ubnVtZXJpY19taW5tYXggPSAoZm4gPT0gIk1JTiIgfHwgZm4gPT0gIk1BWCIp
ICYmICFiYS5jaGlsZHJlblswXS0+cmV0dXJuX3R5cGUuSXNOdW1lcmljKCk7CisgICAgICAgIGJv
b2wgaXNfbm9ubnVtZXJpY19taW5tYXggPSAoZm4gPT0gIk1JTiIgfHwgZm4gPT0gIk1BWCIpICYm
ICFiYS5jaGlsZHJlblswXS0+R2V0UmV0dXJuVHlwZSgpLklzTnVtZXJpYygpOwogICAgICAgICBp
ZiAoaW5mby5vbl9idWlsZCkgewogICAgICAgICAgICAgaWYgKGlzX2xpbmVhcl9udW1lcmljKSB7
CiAgICAgICAgICAgICAgICAgc2F3X2J1aWxkX2xpbmVhcl9udW1lcmljID0gdHJ1ZTsKQEAgLTE3
Nyw3ICsxNzcsNyBAQCBib29sIFRyeVJld3JpdGVOYXRpdmVNaXhlZFNpZGVQcmVhZ2coQ2xpZW50
Q29udGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZQogICAgICAgICAgICAgfQogICAg
ICAgICAgICAgaWYgKCEoZm4gPT0gIk1JTiIgfHwgZm4gPT0gIk1BWCIpKSB7CiAgICAgICAgICAg
ICAgICAgYnVpbGRfb25seV9ub25udW1lcmljX21pbm1heCA9IGZhbHNlOwotICAgICAgICAgICAg
fSBlbHNlIGlmIChiYS5jaGlsZHJlblswXS0+cmV0dXJuX3R5cGUuSXNOdW1lcmljKCkpIHsKKyAg
ICAgICAgICAgIH0gZWxzZSBpZiAoYmEuY2hpbGRyZW5bMF0tPkdldFJldHVyblR5cGUoKS5Jc051
bWVyaWMoKSkgewogICAgICAgICAgICAgICAgIGJ1aWxkX29ubHlfbm9ubnVtZXJpY19taW5tYXgg
PSBmYWxzZTsKICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICAgc2F3X2J1aWxk
X25vbm51bWVyaWNfbWlubWF4ID0gdHJ1ZTsKQEAgLTE5Niw3ICsxOTYsNyBAQCBib29sIFRyeVJl
d3JpdGVOYXRpdmVNaXhlZFNpZGVQcmVhZ2coQ2xpZW50Q29udGV4dCAmY29udGV4dCwgT3B0aW1p
emVyICZvcHRpbWl6ZQogICAgICAgICAgICAgfQogICAgICAgICAgICAgaWYgKCEoZm4gPT0gIk1J
TiIgfHwgZm4gPT0gIk1BWCIpKSB7CiAgICAgICAgICAgICAgICAgcHJvYmVfb25seV9ub25udW1l
cmljX21pbm1heCA9IGZhbHNlOwotICAgICAgICAgICAgfSBlbHNlIGlmIChiYS5jaGlsZHJlblsw
XS0+cmV0dXJuX3R5cGUuSXNOdW1lcmljKCkpIHsKKyAgICAgICAgICAgIH0gZWxzZSBpZiAoYmEu
Y2hpbGRyZW5bMF0tPkdldFJldHVyblR5cGUoKS5Jc051bWVyaWMoKSkgewogICAgICAgICAgICAg
ICAgIHByb2JlX29ubHlfbm9ubnVtZXJpY19taW5tYXggPSBmYWxzZTsKICAgICAgICAgICAgIH0g
ZWxzZSB7CiAgICAgICAgICAgICAgICAgc2F3X3Byb2JlX25vbm51bWVyaWNfbWlubWF4ID0gdHJ1
ZTsKQEAgLTI0OSw4ICsyNDksOCBAQCBib29sIFRyeVJld3JpdGVOYXRpdmVNaXhlZFNpZGVQcmVh
Z2coQ2xpZW50Q29udGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZQogICAgIGF1dG8g
bWFrZV9zaWRlX3ByZWFnZyA9IFsmXSh1bmlxdWVfcHRyPExvZ2ljYWxPcGVyYXRvcj4gY2hpbGQs
IGNvbnN0IHZlY3RvcjxDb2x1bW5CaW5kaW5nPiAmYmluZGluZ3MsCiAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgIGNvbnN0IHZlY3RvcjxMb2dpY2FsVHlwZT4gJnR5cGVzLCBjb25zdCB2
ZWN0b3I8aWR4X3Q+ICZrZXlfaWR4cywgYm9vbCBvbl9idWlsZF9zaWRlLAogICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICBpZHhfdCAmZ3JvdXBfaW5kZXhfb3V0LCBpZHhfdCAmYWdnX2lu
ZGV4X291dCkgLT4gdW5pcXVlX3B0cjxMb2dpY2FsQWdncmVnYXRlPiB7Ci0gICAgICAgIGdyb3Vw
X2luZGV4X291dCA9IG9wdGltaXplci5iaW5kZXIuR2VuZXJhdGVUYWJsZUluZGV4KCk7Ci0gICAg
ICAgIGFnZ19pbmRleF9vdXQgPSBvcHRpbWl6ZXIuYmluZGVyLkdlbmVyYXRlVGFibGVJbmRleCgp
OworICAgICAgICBncm91cF9pbmRleF9vdXQgPSBvcHRpbWl6ZXIuYmluZGVyLkdlbmVyYXRlVGFi
bGVJbmRleCgpLmluZGV4OworICAgICAgICBhZ2dfaW5kZXhfb3V0ID0gb3B0aW1pemVyLmJpbmRl
ci5HZW5lcmF0ZVRhYmxlSW5kZXgoKS5pbmRleDsKICAgICAgICAgdmVjdG9yPHVuaXF1ZV9wdHI8
RXhwcmVzc2lvbj4+IHNpZGVfYWdnczsKICAgICAgICAgc2lkZV9hZ2dzLnB1c2hfYmFjayhCaW5k
QWdncmVnYXRlQnlOYW1lKGNvbnRleHQsICJjb3VudF9zdGFyIiwge30pKTsKICAgICAgICAgZm9y
IChpZHhfdCBhID0gMDsgYSA8IG1peGVkX2FnZ3Muc2l6ZSgpOyBhKyspIHsKQEAgLTI5Niw3ICsy
OTYsNyBAQCBib29sIFRyeVJld3JpdGVOYXRpdmVNaXhlZFNpZGVQcmVhZ2coQ2xpZW50Q29udGV4
dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZQogICAgICAgICAgICAgICAgIH0KICAgICAg
ICAgICAgIH0KICAgICAgICAgfQotICAgICAgICBhdXRvIHNpZGVfcHJlYWdnID0gbWFrZV91bmlx
PExvZ2ljYWxBZ2dyZWdhdGU+KGdyb3VwX2luZGV4X291dCwgYWdnX2luZGV4X291dCwgc3RkOjpt
b3ZlKHNpZGVfYWdncykpOworICAgICAgICBhdXRvIHNpZGVfcHJlYWdnID0gbWFrZV91bmlxPExv
Z2ljYWxBZ2dyZWdhdGU+KFRhYmxlSW5kZXgoZ3JvdXBfaW5kZXhfb3V0KSwgVGFibGVJbmRleChh
Z2dfaW5kZXhfb3V0KSwgc3RkOjptb3ZlKHNpZGVfYWdncykpOwogICAgICAgICBmb3IgKGF1dG8g
a2V5X2lkeCA6IGtleV9pZHhzKSB7CiAgICAgICAgICAgICBzaWRlX3ByZWFnZy0+Z3JvdXBzLnB1
c2hfYmFjayhtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPih0eXBlc1trZXlfaWR4
XSwgYmluZGluZ3Nba2V5X2lkeF0pKTsKICAgICAgICAgfQpAQCAtMzE0LDE0ICszMTQsMTIgQEAg
Ym9vbCBUcnlSZXdyaXRlTmF0aXZlTWl4ZWRTaWRlUHJlYWdnKENsaWVudENvbnRleHQgJmNvbnRl
eHQsIE9wdGltaXplciAmb3B0aW1pemUKIAogICAgIGF1dG8gbmF0aXZlX2pvaW4gPSBtYWtlX3Vu
aXE8TG9naWNhbENvbXBhcmlzb25Kb2luPihKb2luVHlwZTo6SU5ORVIpOwogICAgIGZvciAoaWR4
X3QgaSA9IDA7IGkgPCBrZXlfY291bnQ7IGkrKykgewotICAgICAgICBKb2luQ29uZGl0aW9uIGNv
bmQ7Ci0gICAgICAgIGNvbmQuY29tcGFyaXNvbiA9IEV4cHJlc3Npb25UeXBlOjpDT01QQVJFX0VR
VUFMOwotICAgICAgICBjb25kLmxlZnQgPSBtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNz
aW9uPihwcm9iZV9wcmVhZ2ctPnR5cGVzW2ldLCBDb2x1bW5CaW5kaW5nKHByb2JlX2dyb3VwX2lu
ZGV4LCBpKSk7Ci0gICAgICAgIGNvbmQucmlnaHQgPSBtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZF
eHByZXNzaW9uPihidWlsZF9wcmVhZ2ctPnR5cGVzW2ldLCBDb2x1bW5CaW5kaW5nKGJ1aWxkX2dy
b3VwX2luZGV4LCBpKSk7CisgICAgICAgIHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4gbGhzID0gbWFr
ZV91bmlxPEJvdW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4ocHJvYmVfcHJlYWdnLT50eXBlc1tpXSwg
Q29sdW1uQmluZGluZyhUYWJsZUluZGV4KHByb2JlX2dyb3VwX2luZGV4KSwgUHJvamVjdGlvbklu
ZGV4KGkpKSk7CisgICAgICAgIHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4gcmhzID0gbWFrZV91bmlx
PEJvdW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oYnVpbGRfcHJlYWdnLT50eXBlc1tpXSwgQ29sdW1u
QmluZGluZyhUYWJsZUluZGV4KGJ1aWxkX2dyb3VwX2luZGV4KSwgUHJvamVjdGlvbkluZGV4KGkp
KSk7CiAgICAgICAgIGlmIChwcm9iZV9wcmVhZ2ctPnR5cGVzW2ldICE9IGJ1aWxkX3ByZWFnZy0+
dHlwZXNbaV0pIHsKLSAgICAgICAgICAgIGNvbmQucmlnaHQgPSBCb3VuZENhc3RFeHByZXNzaW9u
OjpBZGRDYXN0VG9UeXBlKGNvbnRleHQsIHN0ZDo6bW92ZShjb25kLnJpZ2h0KSwgcHJvYmVfcHJl
YWdnLT50eXBlc1tpXSk7CisgICAgICAgICAgICByaHMgPSBCb3VuZENhc3RFeHByZXNzaW9uOjpB
ZGRDYXN0VG9UeXBlKGNvbnRleHQsIHN0ZDo6bW92ZShyaHMpLCBwcm9iZV9wcmVhZ2ctPnR5cGVz
W2ldKTsKICAgICAgICAgfQotICAgICAgICBuYXRpdmVfam9pbi0+Y29uZGl0aW9ucy5wdXNoX2Jh
Y2soc3RkOjptb3ZlKGNvbmQpKTsKKyAgICAgICAgbmF0aXZlX2pvaW4tPmNvbmRpdGlvbnMuZW1w
bGFjZV9iYWNrKHN0ZDo6bW92ZShsaHMpLCBzdGQ6Om1vdmUocmhzKSwgRXhwcmVzc2lvblR5cGU6
OkNPTVBBUkVfRVFVQUwpOwogICAgIH0KICAgICBuYXRpdmVfam9pbi0+Y2hpbGRyZW4ucHVzaF9i
YWNrKHN0ZDo6bW92ZShwcm9iZV9wcmVhZ2cpKTsKICAgICBuYXRpdmVfam9pbi0+Y2hpbGRyZW4u
cHVzaF9iYWNrKHN0ZDo6bW92ZShidWlsZF9wcmVhZ2cpKTsKQEAgLTQwMSw3ICszOTksNyBAQCBi
b29sIFRyeVJld3JpdGVOYXRpdmVNaXhlZFNpZGVQcmVhZ2coQ2xpZW50Q29udGV4dCAmY29udGV4
dCwgT3B0aW1pemVyICZvcHRpbWl6ZQogICAgICAgICBpZiAob3AtPmhhc19lc3RpbWF0ZWRfY2Fy
ZGluYWxpdHkpIHsKICAgICAgICAgICAgIHByb2otPlNldEVzdGltYXRlZENhcmRpbmFsaXR5KG9w
LT5lc3RpbWF0ZWRfY2FyZGluYWxpdHkpOwogICAgICAgICB9Ci0gICAgICAgIG91dHB1dF9pbmRl
eCA9IHByb2pfaW5kZXg7CisgICAgICAgIG91dHB1dF9pbmRleCA9IHByb2pfaW5kZXguaW5kZXg7
CiAgICAgICAgIG91dHB1dF9iYXNlID0ga2V5X2NvdW50OwogICAgICAgICByZXBsYWNlbWVudCA9
IHN0ZDo6bW92ZShwcm9qKTsKICAgICB9IGVsc2UgewpAQCAtNDYyLDcgKzQ2MCw3IEBAIGJvb2wg
VHJ5UmV3cml0ZU5hdGl2ZU1peGVkU2lkZVByZWFnZyhDbGllbnRDb250ZXh0ICZjb250ZXh0LCBP
cHRpbWl6ZXIgJm9wdGltaXplCiAgICAgICAgIGNvbnRyaWJfcHJvai0+UmVzb2x2ZU9wZXJhdG9y
VHlwZXMoKTsKIAogICAgICAgICBhdXRvIGZpbmFsX2FnZ19pbmRleCA9IG9wdGltaXplci5iaW5k
ZXIuR2VuZXJhdGVUYWJsZUluZGV4KCk7Ci0gICAgICAgIGlkeF90IGZpbmFsX2dyb3VwX2luZGV4
ID0gZ3JvdXBlZF9ieV9qb2luX2tleV9zdWJzZXQgPyBvcHRpbWl6ZXIuYmluZGVyLkdlbmVyYXRl
VGFibGVJbmRleCgpIDogRENvbnN0YW50czo6SU5WQUxJRF9JTkRFWDsKKyAgICAgICAgVGFibGVJ
bmRleCBmaW5hbF9ncm91cF9pbmRleCA9IGdyb3VwZWRfYnlfam9pbl9rZXlfc3Vic2V0ID8gb3B0
aW1pemVyLmJpbmRlci5HZW5lcmF0ZVRhYmxlSW5kZXgoKSA6IFRhYmxlSW5kZXgoRENvbnN0YW50
czo6SU5WQUxJRF9JTkRFWCk7CiAgICAgICAgIHZlY3Rvcjx1bmlxdWVfcHRyPEV4cHJlc3Npb24+
PiBmaW5hbF9hZ2dzOwogICAgICAgICBmb3IgKGlkeF90IGEgPSAwOyBhIDwgbWl4ZWRfYWdncy5z
aXplKCk7IGErKykgewogICAgICAgICAgICAgYXV0byAmaW5mbyA9IG1peGVkX2FnZ3NbYV07CkBA
IC00NzAsMjUgKzQ2OCwyNSBAQCBib29sIFRyeVJld3JpdGVOYXRpdmVNaXhlZFNpZGVQcmVhZ2co
Q2xpZW50Q29udGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZQogICAgICAgICAgICAg
ICAgIGZvciAoYXV0byBzbG90IDoge3N1bV9zbG90c1thXSwgY291bnRfc2xvdHNbYV19KSB7CiAg
ICAgICAgICAgICAgICAgICAgIHZlY3Rvcjx1bmlxdWVfcHRyPEV4cHJlc3Npb24+PiBjaGlsZHJl
bjsKICAgICAgICAgICAgICAgICAgICAgY2hpbGRyZW4ucHVzaF9iYWNrKG1ha2VfdW5pcTxCb3Vu
ZENvbHVtblJlZkV4cHJlc3Npb24+KGNvbnRyaWJfcHJvai0+dHlwZXNbY29udHJpYl92YWx1ZV9i
YXNlICsgc2xvdF0sCi0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKGNvbnRyaWJfaW5k
ZXgsIGNvbnRyaWJfdmFsdWVfYmFzZSArIHNsb3QpKSk7CisgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1
bW5CaW5kaW5nKFRhYmxlSW5kZXgoY29udHJpYl9pbmRleCksIFByb2plY3Rpb25JbmRleChjb250
cmliX3ZhbHVlX2Jhc2UgKyBzbG90KSkpKTsKICAgICAgICAgICAgICAgICAgICAgZmluYWxfYWdn
cy5wdXNoX2JhY2soQmluZEFnZ3JlZ2F0ZUJ5TmFtZShjb250ZXh0LCAic3VtIiwgc3RkOjptb3Zl
KGNoaWxkcmVuKSkpOwogICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgIH0gZWxzZSBpZiAo
aW5mby5mbiA9PSAiTUlOIiB8fCBpbmZvLmZuID09ICJNQVgiKSB7CiAgICAgICAgICAgICAgICAg
dmVjdG9yPHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4+IGNoaWxkcmVuOwogICAgICAgICAgICAgICAg
IGNoaWxkcmVuLnB1c2hfYmFjayhtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNzaW9uPihj
b250cmliX3Byb2otPnR5cGVzW2NvbnRyaWJfdmFsdWVfYmFzZSArIHN1bV9zbG90c1thXV0sCi0g
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgIENvbHVtbkJpbmRpbmcoY29udHJpYl9pbmRleCwgY29udHJpYl92YWx1ZV9i
YXNlICsgc3VtX3Nsb3RzW2FdKSkpOworICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKFRhYmxl
SW5kZXgoY29udHJpYl9pbmRleCksIFByb2plY3Rpb25JbmRleChjb250cmliX3ZhbHVlX2Jhc2Ug
KyBzdW1fc2xvdHNbYV0pKSkpOwogICAgICAgICAgICAgICAgIGZpbmFsX2FnZ3MucHVzaF9iYWNr
KEJpbmRBZ2dyZWdhdGVCeU5hbWUoY29udGV4dCwgU3RyaW5nVXRpbDo6TG93ZXIoaW5mby5mbiks
IHN0ZDo6bW92ZShjaGlsZHJlbikpKTsKICAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAg
ICAgICAgdmVjdG9yPHVuaXF1ZV9wdHI8RXhwcmVzc2lvbj4+IGNoaWxkcmVuOwogICAgICAgICAg
ICAgICAgIGNoaWxkcmVuLnB1c2hfYmFjayhtYWtlX3VuaXE8Qm91bmRDb2x1bW5SZWZFeHByZXNz
aW9uPihjb250cmliX3Byb2otPnR5cGVzW2NvbnRyaWJfdmFsdWVfYmFzZSArIHN1bV9zbG90c1th
XV0sCi0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgIENvbHVtbkJpbmRpbmcoY29udHJpYl9pbmRleCwgY29udHJpYl92
YWx1ZV9iYXNlICsgc3VtX3Nsb3RzW2FdKSkpOworICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5n
KFRhYmxlSW5kZXgoY29udHJpYl9pbmRleCksIFByb2plY3Rpb25JbmRleChjb250cmliX3ZhbHVl
X2Jhc2UgKyBzdW1fc2xvdHNbYV0pKSkpOwogICAgICAgICAgICAgICAgIGZpbmFsX2FnZ3MucHVz
aF9iYWNrKEJpbmRBZ2dyZWdhdGVCeU5hbWUoY29udGV4dCwgInN1bSIsIHN0ZDo6bW92ZShjaGls
ZHJlbikpKTsKICAgICAgICAgICAgIH0KICAgICAgICAgfQogICAgICAgICBhdXRvIGZpbmFsX2Fn
ZyA9IG1ha2VfdW5pcTxMb2dpY2FsQWdncmVnYXRlPihmaW5hbF9ncm91cF9pbmRleCwgZmluYWxf
YWdnX2luZGV4LCBzdGQ6Om1vdmUoZmluYWxfYWdncykpOwogICAgICAgICBpZiAoZ3JvdXBlZF9i
eV9qb2luX2tleV9zdWJzZXQpIHsKICAgICAgICAgICAgIGZvciAoaWR4X3QgZyA9IDA7IGcgPCBn
cm91cF9rZXlfcG9zaXRpb25zLnNpemUoKTsgZysrKSB7Ci0gICAgICAgICAgICAgICAgZmluYWxf
YWdnLT5ncm91cHMucHVzaF9iYWNrKG1ha2VfdW5pcTxCb3VuZENvbHVtblJlZkV4cHJlc3Npb24+
KGNvbnRyaWJfcHJvai0+dHlwZXNbZ10sIENvbHVtbkJpbmRpbmcoY29udHJpYl9pbmRleCwgZykp
KTsKKyAgICAgICAgICAgICAgICBmaW5hbF9hZ2ctPmdyb3Vwcy5wdXNoX2JhY2sobWFrZV91bmlx
PEJvdW5kQ29sdW1uUmVmRXhwcmVzc2lvbj4oY29udHJpYl9wcm9qLT50eXBlc1tnXSwgQ29sdW1u
QmluZGluZyhUYWJsZUluZGV4KGNvbnRyaWJfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgoZykpKSk7
CiAgICAgICAgICAgICB9CiAgICAgICAgIH0KICAgICAgICAgZmluYWxfYWdnLT5jaGlsZHJlbi5w
dXNoX2JhY2soc3RkOjptb3ZlKGNvbnRyaWJfcHJvaikpOwpAQCAtNTMwLDIxICs1MjgsMjEgQEAg
Ym9vbCBUcnlSZXdyaXRlTmF0aXZlTWl4ZWRTaWRlUHJlYWdnKENsaWVudENvbnRleHQgJmNvbnRl
eHQsIE9wdGltaXplciAmb3B0aW1pemUKICAgICAgICAgaWYgKG9wLT5oYXNfZXN0aW1hdGVkX2Nh
cmRpbmFsaXR5KSB7CiAgICAgICAgICAgICBmaW5hbF9wcm9qLT5TZXRFc3RpbWF0ZWRDYXJkaW5h
bGl0eShvcC0+ZXN0aW1hdGVkX2NhcmRpbmFsaXR5KTsKICAgICAgICAgfQotICAgICAgICBvdXRw
dXRfaW5kZXggPSBmaW5hbF9wcm9qX2luZGV4OworICAgICAgICBvdXRwdXRfaW5kZXggPSBmaW5h
bF9wcm9qX2luZGV4LmluZGV4OwogICAgICAgICBvdXRwdXRfYmFzZSA9IGdyb3VwZWRfYnlfam9p
bl9rZXlfc3Vic2V0ID8gZ3JvdXBfa2V5X3Bvc2l0aW9ucy5zaXplKCkgOiAwOwogICAgICAgICBy
ZXBsYWNlbWVudCA9IHN0ZDo6bW92ZShmaW5hbF9wcm9qKTsKICAgICB9CiAKICAgICBpZiAoaGFz
X3BhcmVudCkgewogICAgICAgICBmb3IgKGlkeF90IGEgPSAwOyBhIDwgYWdnLmV4cHJlc3Npb25z
LnNpemUoKTsgYSsrKSB7Ci0gICAgICAgICAgICBzdGF0ZS5yZXBsYWNlbWVudF9iaW5kaW5ncy5l
bXBsYWNlX2JhY2soQ29sdW1uQmluZGluZyhhZ2cuYWdncmVnYXRlX2luZGV4LCBhKSwKLSAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5k
aW5nKG91dHB1dF9pbmRleCwgb3V0cHV0X2Jhc2UgKyBhKSk7CisgICAgICAgICAgICBzdGF0ZS5y
ZXBsYWNlbWVudF9iaW5kaW5ncy5lbXBsYWNlX2JhY2soQ29sdW1uQmluZGluZyhUYWJsZUluZGV4
KGFnZy5hZ2dyZWdhdGVfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgoYSkpLAorICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbHVtbkJpbmRpbmcoVGFi
bGVJbmRleChvdXRwdXRfaW5kZXgpLCBQcm9qZWN0aW9uSW5kZXgob3V0cHV0X2Jhc2UgKyBhKSkp
OwogICAgICAgICB9CiAgICAgICAgIGlmIChncm91cGVkX2J5X2pvaW5fa2V5IHx8IGdyb3VwZWRf
Ynlfam9pbl9rZXlfc3Vic2V0KSB7CiAgICAgICAgICAgICBhdXRvIGdyb3VwX2NvdW50ID0gZ3Jv
dXBlZF9ieV9qb2luX2tleSA/IGtleV9jb3VudCA6IGdyb3VwX2tleV9wb3NpdGlvbnMuc2l6ZSgp
OwogICAgICAgICAgICAgZm9yIChpZHhfdCBpID0gMDsgaSA8IGdyb3VwX2NvdW50OyBpKyspIHsK
LSAgICAgICAgICAgICAgICBzdGF0ZS5yZXBsYWNlbWVudF9iaW5kaW5ncy5lbXBsYWNlX2JhY2so
Q29sdW1uQmluZGluZyhhZ2cuZ3JvdXBfaW5kZXgsIGkpLAotICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb2x1bW5CaW5kaW5nKG91dHB1dF9p
bmRleCwgaSkpOworICAgICAgICAgICAgICAgIHN0YXRlLnJlcGxhY2VtZW50X2JpbmRpbmdzLmVt
cGxhY2VfYmFjayhDb2x1bW5CaW5kaW5nKFRhYmxlSW5kZXgoYWdnLmdyb3VwX2luZGV4KSwgUHJv
amVjdGlvbkluZGV4KGkpKSwKKyAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgQ29sdW1uQmluZGluZyhUYWJsZUluZGV4KG91dHB1dF9pbmRleCks
IFByb2plY3Rpb25JbmRleChpKSkpOwogICAgICAgICAgICAgfQogICAgICAgICB9CiAgICAgfQpk
aWZmIC0tZ2l0IGEvc3JjL2FnZ2pvaW5fcmV3cml0ZXMuY3BwIGIvc3JjL2FnZ2pvaW5fcmV3cml0
ZXMuY3BwCmluZGV4IDc1MjFkNmEuLmNhNjQ2NDkgMTAwNjQ0Ci0tLSBhL3NyYy9hZ2dqb2luX3Jl
d3JpdGVzLmNwcAorKysgYi9zcmMvYWdnam9pbl9yZXdyaXRlcy5jcHAKQEAgLTIzLDcgKzIzLDcg
QEAgc3RhdGljIGJvb2wgSXNFcXVpSm9pbihMb2dpY2FsT3BlcmF0b3IgJm9wKSB7CiAgICAgaWYo
b3AudHlwZSE9TG9naWNhbE9wZXJhdG9yVHlwZTo6TE9HSUNBTF9DT01QQVJJU09OX0pPSU4pIHJl
dHVybiBmYWxzZTsKICAgICBhdXRvICZqPW9wLkNhc3Q8TG9naWNhbENvbXBhcmlzb25Kb2luPigp
OwogICAgIGlmKGouam9pbl90eXBlIT1Kb2luVHlwZTo6SU5ORVIpIHJldHVybiBmYWxzZTsKLSAg
ICBmb3IoYXV0byAmYzpqLmNvbmRpdGlvbnMpIGlmKGMuY29tcGFyaXNvbiE9RXhwcmVzc2lvblR5
cGU6OkNPTVBBUkVfRVFVQUwpIHJldHVybiBmYWxzZTsKKyAgICBmb3IoYXV0byAmYzpqLmNvbmRp
dGlvbnMpIGlmKGMuR2V0Q29tcGFyaXNvblR5cGUoKSE9RXhwcmVzc2lvblR5cGU6OkNPTVBBUkVf
RVFVQUwpIHJldHVybiBmYWxzZTsKICAgICByZXR1cm4gIWouY29uZGl0aW9ucy5lbXB0eSgpOwog
fQogCkBAIC01MSwxNSArNTEsMTUgQEAgc3RhdGljIGJvb2wgSXNBZ2dyZWdhdGUoTG9naWNhbE9w
ZXJhdG9yICZvcCkgewogICAgIAogICAgIC8vIFVuZ3JvdXBlZCBhZ2dyZWdhdGVzIChubyBHUk9V
UCBCWSkgYXJlIHN1cHBvcnRlZCDigJQgc2luZ2xlIHJlc3VsdCByb3cKICAgICBmb3IoYXV0byAm
ZTphLmV4cHJlc3Npb25zKSB7Ci0gICAgICAgIGlmKGUtPnR5cGUhPUV4cHJlc3Npb25UeXBlOjpC
T1VORF9BR0dSRUdBVEUpIHsgcmV0dXJuIGZhbHNlOyB9CisgICAgICAgIGlmKGUtPkdldEV4cHJl
c3Npb25UeXBlKCkgIT0gRXhwcmVzc2lvblR5cGU6OkJPVU5EX0FHR1JFR0FURSkgeyByZXR1cm4g
ZmFsc2U7IH0KICAgICAgICAgYXV0byAmYmEgPSBlLT5DYXN0PEJvdW5kQWdncmVnYXRlRXhwcmVz
c2lvbj4oKTsKLSAgICAgICAgYXV0byBmbj1TdHJpbmdVdGlsOjpVcHBlcihiYS5mdW5jdGlvbi5u
YW1lKTsKKyAgICAgICAgYXV0byBmbj1TdHJpbmdVdGlsOjpVcHBlcihiYS5mdW5jdGlvbi5HZXRO
YW1lKCkpOwogICAgICAgICBpZihmbiE9IlNVTSImJmZuIT0iTUlOIiYmZm4hPSJNQVgiJiZmbiE9
IkNPVU5UIiYmZm4hPSJDT1VOVF9TVEFSIiYmZm4hPSJBVkciKSByZXR1cm4gZmFsc2U7CiAgICAg
ICAgIC8vIFNVTS9BVkcgc3RpbGwgcmVxdWlyZSB0aGUgY3VycmVudCBudW1lcmljIGZhc3QgcGF0
aC4gTUlOL01BWCBjYW4gYmUKICAgICAgICAgLy8gYWRtaXR0ZWQgaGVyZSBhbmQgbGF0ZXIgbG93
ZXJlZCBiYWNrIHRvIG5hdGl2ZSBpZiB0aGV5IHN0YXkgb24gdGhlCiAgICAgICAgIC8vIG9sZCBW
YWx1ZS1oZWF2eSBleGVjdXRpb24gcGF0aC4KICAgICAgICAgaWYgKGZuICE9ICJDT1VOVCIgJiYg
Zm4gIT0gIkNPVU5UX1NUQVIiICYmIGZuICE9ICJNSU4iICYmIGZuICE9ICJNQVgiKSB7Ci0gICAg
ICAgICAgICBhdXRvICZyZXRfdHlwZSA9IGJhLnJldHVybl90eXBlOworICAgICAgICAgICAgYXV0
byAmcmV0X3R5cGUgPSBiYS5HZXRSZXR1cm5UeXBlKCk7CiAgICAgICAgICAgICBhdXRvIHBoeXMg
PSByZXRfdHlwZS5JbnRlcm5hbFR5cGUoKTsKICAgICAgICAgICAgIGlmIChwaHlzICE9IFBoeXNp
Y2FsVHlwZTo6RE9VQkxFICYmIHBoeXMgIT0gUGh5c2ljYWxUeXBlOjpGTE9BVCAmJgogICAgICAg
ICAgICAgICAgIHBoeXMgIT0gUGh5c2ljYWxUeXBlOjpJTlQzMiAmJiBwaHlzICE9IFBoeXNpY2Fs
VHlwZTo6SU5UNjQgJiYKQEAgLTY4LDcgKzY4LDcgQEAgc3RhdGljIGJvb2wgSXNBZ2dyZWdhdGUo
TG9naWNhbE9wZXJhdG9yICZvcCkgewogICAgICAgICAgICAgfQogICAgICAgICB9CiAgICAgICAg
IGlmICgoZm4gPT0gIlNVTSIgfHwgZm4gPT0gIkFWRyIpICYmCi0gICAgICAgICAgICAhYmEuY2hp
bGRyZW4uZW1wdHkoKSAmJiAhYmEuY2hpbGRyZW5bMF0tPnJldHVybl90eXBlLklzTnVtZXJpYygp
KSB7CisgICAgICAgICAgICAhYmEuY2hpbGRyZW4uZW1wdHkoKSAmJiAhYmEuY2hpbGRyZW5bMF0t
PkdldFJldHVyblR5cGUoKS5Jc051bWVyaWMoKSkgewogICAgICAgICAgICAgcmV0dXJuIGZhbHNl
OyAvLyBOb24tbnVtZXJpYyBhZ2dyZWdhdGUgaW5wdXQg4oCUIGJhaWwgdG8gbmF0aXZlCiAgICAg
ICAgIH0KICAgICB9CkBAIC0xODMsNyArMTgzLDcgQEAgdm9pZCBXYWxrQW5kUmVwbGFjZShDbGll
bnRDb250ZXh0ICZjb250ZXh0LCBPcHRpbWl6ZXIgJm9wdGltaXplciwgdW5pcXVlX3B0cjxMb2cK
IAogICAgIGZvcihhdXRvICZlIDogYWdnLmV4cHJlc3Npb25zKSB7CiAgICAgICAgIGF1dG8gJmJh
ID0gZS0+Q2FzdDxCb3VuZEFnZ3JlZ2F0ZUV4cHJlc3Npb24+KCk7Ci0gICAgICAgIGF1dG8gZm4g
PSBTdHJpbmdVdGlsOjpVcHBlcihiYS5mdW5jdGlvbi5uYW1lKTsKKyAgICAgICAgYXV0byBmbiA9
IFN0cmluZ1V0aWw6OlVwcGVyKGJhLmZ1bmN0aW9uLkdldE5hbWUoKSk7CiAgICAgICAgIC8vIE5v
cm1hbGl6ZSBDT1VOVF9TVEFSIOKGkiBDT1VOVCBmb3IgdW5pZm9ybSBoYW5kbGluZwogICAgICAg
ICBpZiAoZm4gPT0gIkNPVU5UX1NUQVIiKSBmbiA9ICJDT1VOVCI7CiAgICAgICAgIC8vIFRoZSBm
dXNlZCBvcGVyYXRvciBjYW4gb25seSBoYW5kbGUgYSBzaW5nbGUgZGlyZWN0IGNvbHVtbiByZWYg
cGVyCkBAIC0yMTcsNyArMjE3LDcgQEAgdm9pZCBXYWxrQW5kUmVwbGFjZShDbGllbnRDb250ZXh0
ICZjb250ZXh0LCBPcHRpbWl6ZXIgJm9wdGltaXplciwgdW5pcXVlX3B0cjxMb2cKICAgICAgICAg
fQogICAgICAgICBjb2wuYWdnX2Z1bmNzLnB1c2hfYmFjayhmbik7CiAgICAgICAgIGJvb2wgaXNf
bnVtZXJpYyA9IHRydWU7Ci0gICAgICAgIGlmICghYmEuY2hpbGRyZW4uZW1wdHkoKSAmJiAhYmEu
Y2hpbGRyZW5bMF0tPnJldHVybl90eXBlLklzTnVtZXJpYygpKSB7CisgICAgICAgIGlmICghYmEu
Y2hpbGRyZW4uZW1wdHkoKSAmJiAhYmEuY2hpbGRyZW5bMF0tPkdldFJldHVyblR5cGUoKS5Jc051
bWVyaWMoKSkgewogICAgICAgICAgICAgaXNfbnVtZXJpYyA9IGZhbHNlOyAvLyBWQVJDSEFSLCBE
QVRFLCBldGMuCiAgICAgICAgIH0KICAgICAgICAgY29sLmFnZ19pc19udW1lcmljLnB1c2hfYmFj
ayhpc19udW1lcmljKTsKQEAgLTMwNywxMSArMzA3LDExIEBAIHZvaWQgV2Fsa0FuZFJlcGxhY2Uo
Q2xpZW50Q29udGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZXIsIHVuaXF1ZV9wdHI8
TG9nCiAgICAgICAgIGlkeF90IHJhX2lkeCA9IDA7CiAgICAgICAgIGZvciAoYXV0byAmZSA6IGFn
Zy5leHByZXNzaW9ucykgewogICAgICAgICAgICAgYXV0byAmYmEgPSBlLT5DYXN0PEJvdW5kQWdn
cmVnYXRlRXhwcmVzc2lvbj4oKTsKLSAgICAgICAgICAgIGF1dG8gZm4gPSBTdHJpbmdVdGlsOjpV
cHBlcihiYS5mdW5jdGlvbi5uYW1lKTsKKyAgICAgICAgICAgIGF1dG8gZm4gPSBTdHJpbmdVdGls
OjpVcHBlcihiYS5mdW5jdGlvbi5HZXROYW1lKCkpOwogICAgICAgICAgICAgaWYgKHJhX2lkeCA8
IHJlc29sdmVkX2FnZ3Muc2l6ZSgpKSB7CiAgICAgICAgICAgICAgICAgYXV0byAmcmEgPSByZXNv
bHZlZF9hZ2dzW3JhX2lkeF07CiAgICAgICAgICAgICAgICAgaWYgKHJhLnNjYW5faWR4ICE9IERD
b25zdGFudHM6OklOVkFMSURfSU5ERVggJiYgKGZuID09ICJNSU4iIHx8IGZuID09ICJNQVgiKSkg
ewotICAgICAgICAgICAgICAgICAgICBpZiAoIWJhLmNoaWxkcmVuLmVtcHR5KCkgJiYgIWJhLmNo
aWxkcmVuWzBdLT5yZXR1cm5fdHlwZS5Jc051bWVyaWMoKSkgeworICAgICAgICAgICAgICAgICAg
ICBpZiAoIWJhLmNoaWxkcmVuLmVtcHR5KCkgJiYgIWJhLmNoaWxkcmVuWzBdLT5HZXRSZXR1cm5U
eXBlKCkuSXNOdW1lcmljKCkpIHsKICAgICAgICAgICAgICAgICAgICAgICAgIGhhc19ub25udW1l
cmljX21pbm1heCA9IHRydWU7CiAgICAgICAgICAgICAgICAgICAgICAgICBicmVhazsKICAgICAg
ICAgICAgICAgICAgICAgfQpAQCAtMzYwLDggKzM2MCw4IEBAIHZvaWQgV2Fsa0FuZFJlcGxhY2Uo
Q2xpZW50Q29udGV4dCAmY29udGV4dCwgT3B0aW1pemVyICZvcHRpbWl6ZXIsIHVuaXF1ZV9wdHI8
TG9nCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA6IERDb25z
dGFudHM6OklOVkFMSURfSU5ERVg7CiAgICAgfTsKICAgICBmb3IoYXV0byAmY29uZCA6IGpvaW4t
PmNvbmRpdGlvbnMpIHsKLSAgICAgICAgYXV0byBsaSA9IHJlc29sdmVfam9pbl9jaGlsZF9pZHgo
KmNvbmQubGVmdCwgbGVmdF9jaGlsZF9iaW5kaW5ncyk7Ci0gICAgICAgIGF1dG8gcmkgPSByZXNv
bHZlX2pvaW5fY2hpbGRfaWR4KCpjb25kLnJpZ2h0LCByaWdodF9jaGlsZF9iaW5kaW5ncyk7Cisg
ICAgICAgIGF1dG8gbGkgPSByZXNvbHZlX2pvaW5fY2hpbGRfaWR4KGNvbmQuR2V0TEhTKCksIGxl
ZnRfY2hpbGRfYmluZGluZ3MpOworICAgICAgICBhdXRvIHJpID0gcmVzb2x2ZV9qb2luX2NoaWxk
X2lkeChjb25kLkdldFJIUygpLCByaWdodF9jaGlsZF9iaW5kaW5ncyk7CiAgICAgICAgIGlmIChs
aSA9PSBEQ29uc3RhbnRzOjpJTlZBTElEX0lOREVYIHx8IHJpID09IERDb25zdGFudHM6OklOVkFM
SURfSU5ERVgpIHJldHVybjsKICAgICAgICAgaWYgKG5lZWRfc3dhcCkgewogICAgICAgICAgICAg
Ly8gQWZ0ZXIgc3dhcDogb3JpZ2luYWwgbGVmdCAocHJvYmUpIGlzIG5vdyBidWlsZCwgcmlnaHQg
aXMgbm93IHByb2JlCkBAIC01NTUsOCArNTU1LDggQEAgdm9pZCBXYWxrQW5kUmVwbGFjZShDbGll
bnRDb250ZXh0ICZjb250ZXh0LCBPcHRpbWl6ZXIgJm9wdGltaXplciwgdW5pcXVlX3B0cjxMb2cK
ICAgICAgICAgYWotPnJldHVybl90eXBlcyA9IHN0ZDo6bW92ZShyZXRfdHlwZXMpOwogICAgIH0K
ICAgICBhai0+ZXN0aW1hdGVkX2NhcmRpbmFsaXR5ID0gYWdnLmVzdGltYXRlZF9jYXJkaW5hbGl0
eTsKLSAgICBhai0+Z3JvdXBfaW5kZXggPSBhZ2cuZ3JvdXBfaW5kZXg7Ci0gICAgYWotPmFnZ3Jl
Z2F0ZV9pbmRleCA9IGFnZy5hZ2dyZWdhdGVfaW5kZXg7CisgICAgYWotPmdyb3VwX2luZGV4ID0g
YWdnLmdyb3VwX2luZGV4LmluZGV4OworICAgIGFqLT5hZ2dyZWdhdGVfaW5kZXggPSBhZ2cuYWdn
cmVnYXRlX2luZGV4LmluZGV4OwogICAgIGFqLT5jb2wgPSBzdGQ6Om1vdmUoY29sKTsKICAgICAv
LyBTdG9yZSBleHByZXNzaW9ucyBmb3IgbmF0aXZlIEhUIGNyZWF0aW9uCiAgICAgZm9yIChhdXRv
ICZlIDogYWdnLmV4cHJlc3Npb25zKSB7CkBAIC01OTUsNyArNTk1LDcgQEAgdm9pZCBTdHJpcERl
Y29tcHJlc3NQcm9qZWN0aW9ucyh1bmlxdWVfcHRyPExvZ2ljYWxPcGVyYXRvcj4gJm9wKSB7CiAg
ICAgZm9yIChhdXRvICZleHByIDogcHJvai5leHByZXNzaW9ucykgewogICAgICAgICBpZiAoZXhw
ci0+R2V0RXhwcmVzc2lvbkNsYXNzKCkgPT0gRXhwcmVzc2lvbkNsYXNzOjpCT1VORF9GVU5DVElP
TikgewogICAgICAgICAgICAgYXV0byAmZnVuYyA9IGV4cHItPkNhc3Q8Qm91bmRGdW5jdGlvbkV4
cHJlc3Npb24+KCk7Ci0gICAgICAgICAgICBpZiAoZnVuYy5mdW5jdGlvbi5uYW1lLmZpbmQoImRl
Y29tcHJlc3Nfc3RyaW5nIikgIT0gc3RyaW5nOjpucG9zKSB7CisgICAgICAgICAgICBpZiAoZnVu
Yy5mdW5jdGlvbi5HZXROYW1lKCkuZmluZCgiZGVjb21wcmVzc19zdHJpbmciKSAhPSBzdHJpbmc6
Om5wb3MpIHsKICAgICAgICAgICAgICAgICBpZiAoY2hpbGRfaXNfYWdnam9pbikgewogICAgICAg
ICAgICAgICAgICAgICBoYXNfc3RyaW5nX2RlY29tcHJlc3MgPSB0cnVlOwogICAgICAgICAgICAg
ICAgICAgICBjb250aW51ZTsKQEAgLTYxMiw3ICs2MTIsNyBAQCB2b2lkIFN0cmlwRGVjb21wcmVz
c1Byb2plY3Rpb25zKHVuaXF1ZV9wdHI8TG9naWNhbE9wZXJhdG9yPiAmb3ApIHsKICAgICAgICAg
ICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgICBpZiAocmVm
X2lkeCAhPSBEQ29uc3RhbnRzOjpJTlZBTElEX0lOREVYICYmIHJlZl9pZHggPCBvcC0+Y2hpbGRy
ZW5bMF0tPnR5cGVzLnNpemUoKSAmJgotICAgICAgICAgICAgICAgICAgICBvcC0+Y2hpbGRyZW5b
MF0tPnR5cGVzW3JlZl9pZHhdID09IGZ1bmMucmV0dXJuX3R5cGUpIHsKKyAgICAgICAgICAgICAg
ICAgICAgb3AtPmNoaWxkcmVuWzBdLT50eXBlc1tyZWZfaWR4XSA9PSBmdW5jLkdldFJldHVyblR5
cGUoKSkgewogICAgICAgICAgICAgICAgICAgICBoYXNfc3RyaW5nX2RlY29tcHJlc3MgPSB0cnVl
OwogICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgIH0KQEAgLTYyNSwxNyArNjI1LDE3IEBA
IHZvaWQgU3RyaXBEZWNvbXByZXNzUHJvamVjdGlvbnModW5pcXVlX3B0cjxMb2dpY2FsT3BlcmF0
b3I+ICZvcCkgewogICAgICAgICBhdXRvICZleHByID0gcHJvai5leHByZXNzaW9uc1tpXTsKICAg
ICAgICAgaWYgKGV4cHItPkdldEV4cHJlc3Npb25DbGFzcygpID09IEV4cHJlc3Npb25DbGFzczo6
Qk9VTkRfRlVOQ1RJT04pIHsKICAgICAgICAgICAgIGF1dG8gJmZ1bmMgPSBleHByLT5DYXN0PEJv
dW5kRnVuY3Rpb25FeHByZXNzaW9uPigpOwotICAgICAgICAgICAgaWYgKGZ1bmMuZnVuY3Rpb24u
bmFtZS5maW5kKCJkZWNvbXByZXNzX3N0cmluZyIpICE9IHN0cmluZzo6bnBvcykgeworICAgICAg
ICAgICAgaWYgKGZ1bmMuZnVuY3Rpb24uR2V0TmFtZSgpLmZpbmQoImRlY29tcHJlc3Nfc3RyaW5n
IikgIT0gc3RyaW5nOjpucG9zKSB7CiAgICAgICAgICAgICAgICAgaWYgKGNoaWxkX2lzX2FnZ2pv
aW4pIHsKICAgICAgICAgICAgICAgICAgICAgZm9yIChhdXRvICZjaGlsZCA6IGZ1bmMuY2hpbGRy
ZW4pIHsKICAgICAgICAgICAgICAgICAgICAgICAgIGlmIChjaGlsZC0+R2V0RXhwcmVzc2lvbkNs
YXNzKCkgPT0gRXhwcmVzc2lvbkNsYXNzOjpCT1VORF9SRUYpIHsKICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICBhdXRvIHJlZl9pZHggPSBjaGlsZC0+Q2FzdDxCb3VuZFJlZmVyZW5jZUV4cHJl
c3Npb24+KCkuaW5kZXg7Ci0gICAgICAgICAgICAgICAgICAgICAgICAgICAgcHJvai5leHByZXNz
aW9uc1tpXSA9IG1ha2VfdW5pcTxCb3VuZFJlZmVyZW5jZUV4cHJlc3Npb24+KGZ1bmMucmV0dXJu
X3R5cGUsIHJlZl9pZHgpOworICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByb2ouZXhwcmVz
c2lvbnNbaV0gPSBtYWtlX3VuaXE8Qm91bmRSZWZlcmVuY2VFeHByZXNzaW9uPihmdW5jLkdldFJl
dHVyblR5cGUoKSwgcmVmX2lkeCk7CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYnJlYWs7
CiAgICAgICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICAgICAgICAgICBpZiAo
Y2hpbGQtPkdldEV4cHJlc3Npb25DbGFzcygpID09IEV4cHJlc3Npb25DbGFzczo6Qk9VTkRfQ09M
VU1OX1JFRikgewogICAgICAgICAgICAgICAgICAgICAgICAgICAgIGF1dG8gJmJpbmRpbmcgPSBj
aGlsZC0+Q2FzdDxCb3VuZENvbHVtblJlZkV4cHJlc3Npb24+KCkuYmluZGluZzsKLSAgICAgICAg
ICAgICAgICAgICAgICAgICAgICBwcm9qLmV4cHJlc3Npb25zW2ldID0gbWFrZV91bmlxPEJvdW5k
UmVmZXJlbmNlRXhwcmVzc2lvbj4oZnVuYy5yZXR1cm5fdHlwZSwgYmluZGluZy5jb2x1bW5faW5k
ZXgpOworICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByb2ouZXhwcmVzc2lvbnNbaV0gPSBt
YWtlX3VuaXE8Qm91bmRSZWZlcmVuY2VFeHByZXNzaW9uPihmdW5jLkdldFJldHVyblR5cGUoKSwg
YmluZGluZy5jb2x1bW5faW5kZXgpOwogICAgICAgICAgICAgICAgICAgICAgICAgICAgIGJyZWFr
OwogICAgICAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgICAgICB9CkBAIC02
NTMsOCArNjUzLDggQEAgdm9pZCBTdHJpcERlY29tcHJlc3NQcm9qZWN0aW9ucyh1bmlxdWVfcHRy
PExvZ2ljYWxPcGVyYXRvcj4gJm9wKSB7CiAgICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAg
ICAgICAgICB9CiAgICAgICAgICAgICAgICAgaWYgKHJlZl9pZHggIT0gRENvbnN0YW50czo6SU5W
QUxJRF9JTkRFWCAmJiByZWZfaWR4IDwgb3AtPmNoaWxkcmVuWzBdLT50eXBlcy5zaXplKCkgJiYK
LSAgICAgICAgICAgICAgICAgICAgb3AtPmNoaWxkcmVuWzBdLT50eXBlc1tyZWZfaWR4XSA9PSBm
dW5jLnJldHVybl90eXBlKSB7Ci0gICAgICAgICAgICAgICAgICAgIHByb2ouZXhwcmVzc2lvbnNb
aV0gPSBtYWtlX3VuaXE8Qm91bmRSZWZlcmVuY2VFeHByZXNzaW9uPihmdW5jLnJldHVybl90eXBl
LCByZWZfaWR4KTsKKyAgICAgICAgICAgICAgICAgICAgb3AtPmNoaWxkcmVuWzBdLT50eXBlc1ty
ZWZfaWR4XSA9PSBmdW5jLkdldFJldHVyblR5cGUoKSkgeworICAgICAgICAgICAgICAgICAgICBw
cm9qLmV4cHJlc3Npb25zW2ldID0gbWFrZV91bmlxPEJvdW5kUmVmZXJlbmNlRXhwcmVzc2lvbj4o
ZnVuYy5HZXRSZXR1cm5UeXBlKCksIHJlZl9pZHgpOwogICAgICAgICAgICAgICAgIH0KICAgICAg
ICAgICAgIH0KICAgICAgICAgfQpAQCAtNjYyLDcgKzY2Miw3IEBAIHZvaWQgU3RyaXBEZWNvbXBy
ZXNzUHJvamVjdGlvbnModW5pcXVlX3B0cjxMb2dpY2FsT3BlcmF0b3I+ICZvcCkgewogCiAgICAg
cHJvai50eXBlcy5jbGVhcigpOwogICAgIGZvciAoYXV0byAmZXhwciA6IHByb2ouZXhwcmVzc2lv
bnMpIHsKLSAgICAgICAgcHJvai50eXBlcy5wdXNoX2JhY2soZXhwci0+cmV0dXJuX3R5cGUpOwor
ICAgICAgICBwcm9qLnR5cGVzLnB1c2hfYmFjayhleHByLT5HZXRSZXR1cm5UeXBlKCkpOwogICAg
IH0KIH0KIApkaWZmIC0tZ2l0IGEvc3JjL2FnZ2pvaW5fc2luay5jcHAgYi9zcmMvYWdnam9pbl9z
aW5rLmNwcAppbmRleCBiZmNlN2Q3Li44NmUwMDkwIDEwMDY0NAotLS0gYS9zcmMvYWdnam9pbl9z
aW5rLmNwcAorKysgYi9zcmMvYWdnam9pbl9zaW5rLmNwcApAQCAtNjgsNyArNjgsNyBAQCB1bmlx
dWVfcHRyPEdsb2JhbFNpbmtTdGF0ZT4gUGh5c2ljYWxBZ2dKb2luOjpHZXRHbG9iYWxTaW5rU3Rh
dGUoQ2xpZW50Q29udGV4dCAmYwogICAgIH0KICAgICBmb3IgKGF1dG8gJmUgOiBvd25lZF9hZ2df
ZXhwcnMpIHsKICAgICAgICAgYXV0byAmYmEgPSBlLT5DYXN0PEJvdW5kQWdncmVnYXRlRXhwcmVz
c2lvbj4oKTsKLSAgICAgICAgYXV0byBmbiA9IFN0cmluZ1V0aWw6OlVwcGVyKGJhLmZ1bmN0aW9u
Lm5hbWUpOworICAgICAgICBhdXRvIGZuID0gU3RyaW5nVXRpbDo6VXBwZXIoYmEuZnVuY3Rpb24u
R2V0TmFtZSgpKTsKICAgICAgICAgaWYgKGZuICE9ICJTVU0iICYmIGZuICE9ICJNSU4iICYmIGZu
ICE9ICJNQVgiKSB7CiAgICAgICAgICAgICBuYXRpdmVfc2FmZSA9IGZhbHNlOwogICAgICAgICAg
ICAgYnJlYWs7CkBAIC0xMDYsNyArMTA2LDcgQEAgU2lua1Jlc3VsdFR5cGUgUGh5c2ljYWxBZ2dK
b2luOjpTaW5rKEV4ZWN1dGlvbkNvbnRleHQgJmN0eCwgRGF0YUNodW5rICZjaHVuaywgT3AKICAg
ICAgICAgVmVjdG9yIGh2KExvZ2ljYWxUeXBlOjpIQVNILCBuKTsgaHYuRmxhdHRlbihuKTsKICAg
ICAgICAgVmVjdG9yT3BlcmF0aW9uczo6SGFzaChjaHVuay5kYXRhW2NvbC5idWlsZF9rZXlfY29s
c1swXV0sIGh2LCBuKTsKICAgICAgICAgZm9yIChpZHhfdCBpPTE7aTxjb2wuYnVpbGRfa2V5X2Nv
bHMuc2l6ZSgpO2krKykgVmVjdG9yT3BlcmF0aW9uczo6Q29tYmluZUhhc2goaHYsIGNodW5rLmRh
dGFbY29sLmJ1aWxkX2tleV9jb2xzW2ldXSwgbik7Ci0gICAgICAgIGF1dG8gaCA9IEZsYXRWZWN0
b3I6OkdldERhdGE8aGFzaF90Pihodik7CisgICAgICAgIGF1dG8gaCA9IEZsYXRWZWN0b3I6Okdl
dERhdGFNdXRhYmxlPGhhc2hfdD4oaHYpOwogICAgICAgICBBcHBseUFnZ0pvaW5UZXN0SGFzaEJp
dHMoaCwgbik7CiAgICAgICAgIC8vIEV4dHJhY3QgaW50ZWdlciBrZXkgdmFsdWVzIGZvciBkaXJl
Y3QgbW9kZSBkZXRlY3Rpb24KICAgICAgICAgYXV0byBia2kgPSBjb2wuYnVpbGRfa2V5X2NvbHNb
MF07CmRpZmYgLS1naXQgYS9zcmMvYWdnam9pbl9zb3VyY2UuY3BwIGIvc3JjL2FnZ2pvaW5fc291
cmNlLmNwcAppbmRleCBlMDViMTI1Li4yMmVlZmQzIDEwMDY0NAotLS0gYS9zcmMvYWdnam9pbl9z
b3VyY2UuY3BwCisrKyBiL3NyYy9hZ2dqb2luX3NvdXJjZS5jcHAKQEAgLTE2Miw3ICsxNjIsNyBA
QCBPcGVyYXRvclJlc3VsdFR5cGUgUGh5c2ljYWxBZ2dKb2luOjpFeGVjdXRlSW50ZXJuYWwoRXhl
Y3V0aW9uQ29udGV4dCAmY3R4LCBEYXRhQwogICAgICAgICBWZWN0b3IgaHYoTG9naWNhbFR5cGU6
OkhBU0gsIG4pOyBodi5GbGF0dGVuKG4pOwogICAgICAgICBWZWN0b3JPcGVyYXRpb25zOjpIYXNo
KGlucHV0LmRhdGFbY29sLnByb2JlX2tleV9jb2xzWzBdXSwgaHYsIG4pOwogICAgICAgICBmb3Ig
KGlkeF90IGk9MTtpPGNvbC5wcm9iZV9rZXlfY29scy5zaXplKCk7aSsrKSBWZWN0b3JPcGVyYXRp
b25zOjpDb21iaW5lSGFzaChodiwgaW5wdXQuZGF0YVtjb2wucHJvYmVfa2V5X2NvbHNbaV1dLCBu
KTsKLSAgICAgICAgYXV0byBoID0gRmxhdFZlY3Rvcjo6R2V0RGF0YTxoYXNoX3Q+KGh2KTsKKyAg
ICAgICAgYXV0byBoID0gRmxhdFZlY3Rvcjo6R2V0RGF0YU11dGFibGU8aGFzaF90Pihodik7CiAg
ICAgICAgIEFwcGx5QWdnSm9pblRlc3RIYXNoQml0cyhoLCBuKTsKIAogICAgICAgICBpZiAoc2lu
ay5idWlsZF9zbG90X2hhc2hfbW9kZSAmJiBzYW1lX2tleXMpIHsKZGlmZiAtLWdpdCBhL3NyYy9h
Z2dqb2luX3NvdXJjZV9yZXN1bHRfaGFzaC5jcHAgYi9zcmMvYWdnam9pbl9zb3VyY2VfcmVzdWx0
X2hhc2guY3BwCmluZGV4IDUyMDdiZDYuLjZmNWM4YTcgMTAwNjQ0Ci0tLSBhL3NyYy9hZ2dqb2lu
X3NvdXJjZV9yZXN1bHRfaGFzaC5jcHAKKysrIGIvc3JjL2FnZ2pvaW5fc291cmNlX3Jlc3VsdF9o
YXNoLmNwcApAQCAtMTEsNyArMTEsNyBAQCBPcGVyYXRvclJlc3VsdFR5cGUgRXhlY3V0ZVJlc3Vs
dEhhc2hTb3VyY2VQYXRoKGNvbnN0IFBoeXNpY2FsQWdnSm9pbiAmb3AsIEV4ZWN1dAogICAgIGJv
b2wgdW5ncm91cGVkID0gY29sLmdyb3VwX2NvbHMuZW1wdHkoKTsKICAgICBpZiAodW5ncm91cGVk
KSB7CiAgICAgICAgIGdodi5GbGF0dGVuKG4pOwotICAgICAgICBnaCA9IEZsYXRWZWN0b3I6Okdl
dERhdGE8aGFzaF90PihnaHYpOworICAgICAgICBnaCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRh
YmxlPGhhc2hfdD4oZ2h2KTsKICAgICAgICAgZm9yIChpZHhfdCByID0gMDsgciA8IG47IHIrKykg
Z2hbcl0gPSAwOwogICAgIH0gZWxzZSBpZiAoc2FtZV9rZXlzKSB7CiAgICAgICAgIGdoID0gaDsK
QEAgLTIxLDcgKzIxLDcgQEAgT3BlcmF0b3JSZXN1bHRUeXBlIEV4ZWN1dGVSZXN1bHRIYXNoU291
cmNlUGF0aChjb25zdCBQaHlzaWNhbEFnZ0pvaW4gJm9wLCBFeGVjdXQKICAgICAgICAgZm9yIChp
ZHhfdCBpID0gMTsgaSA8IGNvbC5ncm91cF9jb2xzLnNpemUoKTsgaSsrKSB7CiAgICAgICAgICAg
ICBWZWN0b3JPcGVyYXRpb25zOjpDb21iaW5lSGFzaChnaHYsIGlucHV0LmRhdGFbY29sLmdyb3Vw
X2NvbHNbaV1dLCBuKTsKICAgICAgICAgfQotICAgICAgICBnaCA9IEZsYXRWZWN0b3I6OkdldERh
dGE8aGFzaF90PihnaHYpOworICAgICAgICBnaCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxl
PGhhc2hfdD4oZ2h2KTsKICAgICAgICAgQXBwbHlBZ2dKb2luVGVzdEhhc2hCaXRzKGdoLCBuKTsK
ICAgICB9CiAKQEAgLTIyMiw3ICsyMjIsNyBAQCBPcGVyYXRvclJlc3VsdFR5cGUgRXhlY3V0ZVJl
c3VsdEhhc2hTb3VyY2VQYXRoKGNvbnN0IFBoeXNpY2FsQWdnSm9pbiAmb3AsIEV4ZWN1dAogICAg
ICAgICBmb3IgKGlkeF90IGEgPSAwOyBhIDwgbmE7IGErKykgewogICAgICAgICAgICAgYXV0byBh
aSA9IGNvbC5hZ2dfaW5wdXRfY29sc1thXTsKICAgICAgICAgICAgIGlmIChhaSA9PSBEQ29uc3Rh
bnRzOjpJTlZBTElEX0lOREVYIHx8IGFpID49IGlucHV0LkNvbHVtbkNvdW50KCkpIHsKLSAgICAg
ICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhPGludDY0X3Q+KHBheWxv
YWRfY2h1bmsuZGF0YVthXSk7CisgICAgICAgICAgICAgICAgYXV0byAqZHN0ID0gRmxhdFZlY3Rv
cjo6R2V0RGF0YU11dGFibGU8aW50NjRfdD4ocGF5bG9hZF9jaHVuay5kYXRhW2FdKTsKICAgICAg
ICAgICAgICAgICBmb3IgKGlkeF90IG0gPSAwOyBtIDwgbWM7IG0rKykgewogICAgICAgICAgICAg
ICAgICAgICBkc3RbbV0gPSAoaW50NjRfdClyb3dfYmNbbWF0Y2hfc2VsLmdldF9pbmRleChtKV07
CiAgICAgICAgICAgICAgICAgfQpAQCAtMjMxLDEzICsyMzEsMTMgQEAgT3BlcmF0b3JSZXN1bHRU
eXBlIEV4ZWN1dGVSZXN1bHRIYXNoU291cmNlUGF0aChjb25zdCBQaHlzaWNhbEFnZ0pvaW4gJm9w
LCBFeGVjdXQKICAgICAgICAgICAgIGF1dG8gcHR5cGUgPSBpbnB1dC5kYXRhW2FpXS5HZXRUeXBl
KCkuSW50ZXJuYWxUeXBlKCk7CiAgICAgICAgICAgICBpZiAocHR5cGUgPT0gUGh5c2ljYWxUeXBl
OjpET1VCTEUpIHsKICAgICAgICAgICAgICAgICBhdXRvICpzcmMgPSBGbGF0VmVjdG9yOjpHZXRE
YXRhPGRvdWJsZT4oaW5wdXQuZGF0YVthaV0pOwotICAgICAgICAgICAgICAgIGF1dG8gKmRzdCA9
IEZsYXRWZWN0b3I6OkdldERhdGE8ZG91YmxlPihwYXlsb2FkX2NodW5rLmRhdGFbYV0pOworICAg
ICAgICAgICAgICAgIGF1dG8gKmRzdCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGRvdWJs
ZT4ocGF5bG9hZF9jaHVuay5kYXRhW2FdKTsKICAgICAgICAgICAgICAgICBmb3IgKGlkeF90IG0g
PSAwOyBtIDwgbWM7IG0rKykgewogICAgICAgICAgICAgICAgICAgICBhdXRvIHIgPSBtYXRjaF9z
ZWwuZ2V0X2luZGV4KG0pOwogICAgICAgICAgICAgICAgICAgICBkc3RbbV0gPSBzcmNbcl0gKiBy
b3dfYmNbcl07CiAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgfSBlbHNlIHsKLSAgICAg
ICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9yOjpHZXREYXRhPGRvdWJsZT4ocGF5bG9h
ZF9jaHVuay5kYXRhW2FdKTsKKyAgICAgICAgICAgICAgICBhdXRvICpkc3QgPSBGbGF0VmVjdG9y
OjpHZXREYXRhTXV0YWJsZTxkb3VibGU+KHBheWxvYWRfY2h1bmsuZGF0YVthXSk7CiAjZGVmaW5l
IE5BVElWRV9QQVlMT0FEX0xPT1AoVFlQRSkgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBcCiAgICAgeyAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBcCiAgICAgICAgIGF1dG8gKnNyYyA9
IEZsYXRWZWN0b3I6OkdldERhdGE8VFlQRT4oaW5wdXQuZGF0YVthaV0pOyAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICBcCkBAIC0yNzAsNyArMjcwLDcgQEAgT3BlcmF0
b3JSZXN1bHRUeXBlIEV4ZWN1dGVSZXN1bHRIYXNoU291cmNlUGF0aChjb25zdCBQaHlzaWNhbEFn
Z0pvaW4gJm9wLCBFeGVjdXQKIAogICAgICAgICBWZWN0b3IgZ3JvdXBfaGFzaGVzKExvZ2ljYWxU
eXBlOjpIQVNILCBtYyk7CiAgICAgICAgIGdyb3VwX2hhc2hlcy5GbGF0dGVuKG1jKTsKLSAgICAg
ICAgYXV0byAqZ2hkID0gRmxhdFZlY3Rvcjo6R2V0RGF0YTxoYXNoX3Q+KGdyb3VwX2hhc2hlcyk7
CisgICAgICAgIGF1dG8gKmdoZCA9IEZsYXRWZWN0b3I6OkdldERhdGFNdXRhYmxlPGhhc2hfdD4o
Z3JvdXBfaGFzaGVzKTsKICAgICAgICAgZm9yIChpZHhfdCBtID0gMDsgbSA8IG1jOyBtKyspIGdo
ZFttXSA9IGdoW21hdGNoX3NlbC5nZXRfaW5kZXgobSldOwogCiAgICAgICAgIHVuc2FmZV92ZWN0
b3I8aWR4X3Q+IGZpbHRlcjsKZGlmZiAtLWdpdCBhL3NyYy9pbmNsdWRlL2FnZ2pvaW5fcnVudGlt
ZS5ocHAgYi9zcmMvaW5jbHVkZS9hZ2dqb2luX3J1bnRpbWUuaHBwCmluZGV4IDRjNGJjZWYuLjU1
Y2UyMTQgMTAwNjQ0Ci0tLSBhL3NyYy9pbmNsdWRlL2FnZ2pvaW5fcnVudGltZS5ocHAKKysrIGIv
c3JjL2luY2x1ZGUvYWdnam9pbl9ydW50aW1lLmhwcApAQCAtMzQ0LDEyICszNDQsMTIgQEAgaW5s
aW5lIENvbXByZXNzSW5mbyBFeHRyYWN0Q29tcHJlc3NJbmZvKExvZ2ljYWxPcGVyYXRvciAmb3As
IGlkeF90IGlkeCkgewogICAgIGF1dG8gJmV4cHIgPSBwcm9qLmV4cHJlc3Npb25zW2lkeF07CiAg
ICAgaWYgKGV4cHItPkdldEV4cHJlc3Npb25DbGFzcygpICE9IEV4cHJlc3Npb25DbGFzczo6Qk9V
TkRfRlVOQ1RJT04pIHJldHVybiBpbmZvOwogICAgIGF1dG8gJmZ1bmMgPSBleHByLT5DYXN0PEJv
dW5kRnVuY3Rpb25FeHByZXNzaW9uPigpOwotICAgIGlmIChmdW5jLmZ1bmN0aW9uLm5hbWUuZmlu
ZCgiX19pbnRlcm5hbF9jb21wcmVzc19pbnRlZ3JhbCIpID09IHN0cmluZzo6bnBvcykgewotICAg
ICAgICBpZiAoZnVuYy5mdW5jdGlvbi5uYW1lLmZpbmQoImNvbXByZXNzX3N0cmluZyIpID09IHN0
cmluZzo6bnBvcykgcmV0dXJuIGluZm87CisgICAgaWYgKGZ1bmMuZnVuY3Rpb24uR2V0TmFtZSgp
LmZpbmQoIl9faW50ZXJuYWxfY29tcHJlc3NfaW50ZWdyYWwiKSA9PSBzdHJpbmc6Om5wb3MpIHsK
KyAgICAgICAgaWYgKGZ1bmMuZnVuY3Rpb24uR2V0TmFtZSgpLmZpbmQoImNvbXByZXNzX3N0cmlu
ZyIpID09IHN0cmluZzo6bnBvcykgcmV0dXJuIGluZm87CiAgICAgICAgIGluZm8uaGFzX2NvbXBy
ZXNzID0gdHJ1ZTsKICAgICAgICAgaW5mby5pc19zdHJpbmdfY29tcHJlc3MgPSB0cnVlOwotICAg
ICAgICBpbmZvLmNvbXByZXNzZWRfdHlwZSA9IGZ1bmMucmV0dXJuX3R5cGU7Ci0gICAgICAgIGlm
ICghZnVuYy5jaGlsZHJlbi5lbXB0eSgpKSBpbmZvLm9yaWdpbmFsX3R5cGUgPSBmdW5jLmNoaWxk
cmVuWzBdLT5yZXR1cm5fdHlwZTsKKyAgICAgICAgaW5mby5jb21wcmVzc2VkX3R5cGUgPSBmdW5j
LkdldFJldHVyblR5cGUoKTsKKyAgICAgICAgaWYgKCFmdW5jLmNoaWxkcmVuLmVtcHR5KCkpIGlu
Zm8ub3JpZ2luYWxfdHlwZSA9IGZ1bmMuY2hpbGRyZW5bMF0tPkdldFJldHVyblR5cGUoKTsKICAg
ICAgICAgcmV0dXJuIGluZm87CiAgICAgfQogICAgIC8vIEl0J3MgYSBjb21wcmVzcyBmdW5jdGlv
bi4gRXh0cmFjdCBvZmZzZXQgZnJvbSBzZWNvbmQgY2hpbGQgKGNvbnN0YW50KS4KQEAgLTM1OCw4
ICszNTgsOCBAQCBpbmxpbmUgQ29tcHJlc3NJbmZvIEV4dHJhY3RDb21wcmVzc0luZm8oTG9naWNh
bE9wZXJhdG9yICZvcCwgaWR4X3QgaWR4KSB7CiAgICAgYXV0byAmY29uc3RhbnQgPSBmdW5jLmNo
aWxkcmVuWzFdLT5DYXN0PEJvdW5kQ29uc3RhbnRFeHByZXNzaW9uPigpOwogICAgIC8vIFRoZSBv
ZmZzZXQgaXMgdGhlIG1pbl92YWwgY29uc3RhbnQg4oCUIGV4dHJhY3QgYXMgaW50NjQKICAgICBp
bmZvLmhhc19jb21wcmVzcyA9IHRydWU7Ci0gICAgaW5mby5jb21wcmVzc2VkX3R5cGUgPSBmdW5j
LnJldHVybl90eXBlOwotICAgIGluZm8ub3JpZ2luYWxfdHlwZSA9IGZ1bmMuY2hpbGRyZW5bMF0t
PnJldHVybl90eXBlOworICAgIGluZm8uY29tcHJlc3NlZF90eXBlID0gZnVuYy5HZXRSZXR1cm5U
eXBlKCk7CisgICAgaW5mby5vcmlnaW5hbF90eXBlID0gZnVuYy5jaGlsZHJlblswXS0+R2V0UmV0
dXJuVHlwZSgpOwogICAgIC8vIEV4dHJhY3Qgb2Zmc2V0IHZhbHVlIGFzIGludDY0LiBSYXcgVUlO
VDY0IG9mZnNldHMgb3V0c2lkZSB0aGUgc2lnbmVkIHJhbmdlCiAgICAgLy8gYXJlIG5vdCBzYWZl
IGZvciB0aGUgc2lnbmVkLW9mZnNldCBkaXJlY3QvY29tcHJlc3MgbG9naWMsIHNvIGRyb3AgY29t
cHJlc3MgaW5mby4KICAgICBhdXRvICZ2YWwgPSBjb25zdGFudC52YWx1ZTsK
PATCH_B64
fi

log_success "Extension patch files created"

# Step 5: Install vcpkg dependencies
if [ "$SKIP_VCPKG" = false ]; then
    log_info "Step 5: Installing vcpkg dependencies (this takes 15-20 minutes)..."
    cd "$VCPKG_DIR"
    
    log_info "Installing AWS SDK (~5 min)..."
    ./vcpkg install --recurse aws-sdk-cpp[core,s3,transfer,config,sts,sso,identity-management,rds,cloudformation]
    
    log_info "Installing Azure SDK (~3 min)..."
    ./vcpkg install azure-storage-blobs-cpp azure-storage-files-datalake-cpp azure-identity-cpp
    
    log_info "Installing Roaring..."
    ./vcpkg install roaring
    
    log_info "Installing libmariadb (for mysql_scanner)..."
    ./vcpkg install libmariadb

    if [ "$WITH_SPATIAL" = true ]; then
        log_info "Installing spatial dependencies (GDAL/PROJ/GEOS/SQLite)..."
        ./vcpkg install gdal[geos] proj geos expat sqlite3[rtree] curl openssl zlib
    fi
    if [ "$WITH_ROBUST_RPT" = true ]; then
        log_info "Installing robust RPT dependencies (OpenSSL)..."
        ./vcpkg install openssl
    fi
    if [ "$WITH_AGGJOIN" = true ]; then
        log_info "aggjoin has no extra vcpkg dependencies"
    fi
    
    log_success "vcpkg dependencies installed"
    cd "$DUCKDB_DIR"
else
    log_warning "Skipping vcpkg dependency installation (--skip-vcpkg)"
fi

# Step 5b: Prepare OpenIVM source with recursive submodules
OPENIVM_LOCAL_DIR=""
if [ "$WITH_OPENIVM_LOADABLE" = true ]; then
    log_info "Step 5b: Preparing OpenIVM source with recursive submodules..."
    OPENIVM_LOCAL_DIR="$DUCKDB_DIR/build/openivm-local-src"
    if [ ! -d "$OPENIVM_LOCAL_DIR/.git" ]; then
        git clone https://github.com/ila/openivm "$OPENIVM_LOCAL_DIR"
    fi
    git -C "$OPENIVM_LOCAL_DIR" fetch origin
    git -C "$OPENIVM_LOCAL_DIR" checkout 974a7b29da0f9b8f876a05626da427cc4bcfa05d
    git -C "$OPENIVM_LOCAL_DIR" reset --hard 974a7b29da0f9b8f876a05626da427cc4bcfa05d
    git -C "$OPENIVM_LOCAL_DIR" submodule sync --recursive
    # OpenIVM build only needs LPTS plus its DuckLake nested submodule.
    # Avoid pulling other nested LPTS submodules (duckdb clone, sqlstorm, skills).
    git -C "$OPENIVM_LOCAL_DIR" submodule update --init third_party/lpts
    git -C "$OPENIVM_LOCAL_DIR/third_party/lpts" submodule update --init third_party/ducklake
    git -C "$OPENIVM_LOCAL_DIR/third_party/lpts" reset --hard HEAD
    log_info "Applying OpenIVM compatibility patch for current DuckDB APIs..."
    apply_patch_if_needed "$OPENIVM_LOCAL_DIR" "$BUILD_SCRIPT_DIR/patches/openivm-current-duckdb.patch" \
        "OpenIVM compatibility patch"
    log_info "Disabling OpenIVM native benchmark/tool targets for static builds..."
    python3 - "$OPENIVM_LOCAL_DIR/CMakeLists.txt" <<'PY'
from pathlib import Path
import re
path = Path(__import__("sys").argv[1])
text = path.read_text()
pattern = r"\n# Test and benchmark tools - only build for native platforms\nif\(NOT EMSCRIPTEN AND NOT WIN32\)\n.*?\nendif\(\)\n"
new_text, count = re.subn(pattern, "\n", text, flags=re.S)
if count != 1:
    raise SystemExit("failed to strip OpenIVM native tool targets")
path.write_text(new_text)
PY
    log_info "Applying OpenIVM runtime patch..."
    apply_patch_if_needed "$OPENIVM_LOCAL_DIR" "$BUILD_SCRIPT_DIR/patches/openivm-active-runtime.patch" \
        "OpenIVM runtime patch"
    log_success "OpenIVM source prepared at $OPENIVM_LOCAL_DIR"
fi

# Step 6: Configure build
log_info "Step 6: Configuring CMake (fetches extensions)..."
if [ "$WITH_OPENIVM_LOADABLE" = true ]; then
    BUILD_DIR="$DUCKDB_DIR/build/release-static-openivm-loadable"
else
    BUILD_DIR="$DUCKDB_DIR/build/release-static"
fi
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
sanitize_dirty_fetchcontent_deps
cd "$DUCKDB_DIR"

# Create minimal vcpkg.json to avoid manifest mode issues
echo '{"name":"duckdb","version":"1.0.0"}' > vcpkg.json

if [ "$ROBUST_BISECT_MINIMAL_EXTENSIONS" = true ]; then
    BUILD_EXTENSIONS="autocomplete;icu;tpcds;tpch;json;parquet"
    EXPECTED_EXTENSIONS=6
else
    BUILD_EXTENSIONS="autocomplete;icu;tpcds;tpch;fts;json;parquet;sqlite_scanner;postgres_scanner;mysql_scanner;httpfs;excel;vss;inet;avro;aws;azure;iceberg;ducklake;delta;unity_catalog"
    EXPECTED_EXTENSIONS=24
fi
if [ "$WITH_SPATIAL" = true ]; then
    BUILD_EXTENSIONS="${BUILD_EXTENSIONS};spatial"
    EXPECTED_EXTENSIONS=$((EXPECTED_EXTENSIONS + 1))
fi
if [ "$WITH_ROBUST_RPT" = true ]; then
    BUILD_EXTENSIONS="${BUILD_EXTENSIONS};robust"
    EXPECTED_EXTENSIONS=$((EXPECTED_EXTENSIONS + 1))
fi
if [ "$WITH_AGGJOIN" = true ]; then
    BUILD_EXTENSIONS="${BUILD_EXTENSIONS};aggjoin"
    EXPECTED_EXTENSIONS=$((EXPECTED_EXTENSIONS + 1))
fi
if [ "$WITH_OPENIVM_LOADABLE" = true ]; then
    BUILD_EXTENSIONS="${BUILD_EXTENSIONS};openivm"
fi

# Note: --allow-multiple-definition is required because postgres_scanner
# shares some common helper functions with other static extensions.
if [ "$WITH_OPENIVM_LOADABLE" = true ]; then
    DUCKDB_OPENIVM_DIRECTORY="$OPENIVM_LOCAL_DIR" cmake -S "$DUCKDB_DIR" -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$VCPKG_DIR/scripts/buildsystems/vcpkg.cmake" \
      -DVCPKG_BUILD=1 \
      -DVCPKG_MANIFEST_MODE=OFF \
      -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
      -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
      -DBUILD_EXTENSIONS="$BUILD_EXTENSIONS" \
      .
else
    cmake -S "$DUCKDB_DIR" -B "$BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$VCPKG_DIR/scripts/buildsystems/vcpkg.cmake" \
      -DVCPKG_BUILD=1 \
      -DVCPKG_MANIFEST_MODE=OFF \
      -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
      -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-multiple-definition" \
      -DBUILD_EXTENSIONS="$BUILD_EXTENSIONS" \
      .
fi
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

if [ "$WITH_OPENIVM_LOADABLE" = true ]; then
    log_info "Step 8b: Building OpenIVM as a loadable extension..."
    cmake --build "$BUILD_DIR" -j"$NUM_CORES" --target openivm_loadable_extension
    log_success "OpenIVM loadable extension built"
fi

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

if [ "$COPY_TESTS" = true ]; then
    log_info "Step 10: Running COPY repro validation..."
    run_copy_repro_validation
fi

if [ "$WITH_OPENIVM_LOADABLE" = true ]; then
    log_info "Step 10: Verifying OpenIVM loadable extension..."
    OPENIVM_LOADABLE_PATH="$BUILD_DIR/extension/openivm/openivm.duckdb_extension"
    if [ ! -f "$OPENIVM_LOADABLE_PATH" ]; then
        log_error "OpenIVM loadable extension not found at $OPENIVM_LOADABLE_PATH"
        exit 1
    fi
    ./duckdb -unsigned -c "LOAD '$OPENIVM_LOADABLE_PATH'; SELECT extension_name, loaded FROM duckdb_extensions() WHERE extension_name='openivm';" >/dev/null
    log_success "OpenIVM loadable extension built and loadable at $OPENIVM_LOADABLE_PATH"

    log_info "Step 10b: Verifying OpenIVM metadata with direct probe..."
    if [ ! -x "$BUILD_SCRIPT_DIR/scripts/validate-openivm-meta.sh" ]; then
        log_error "OpenIVM metadata probe not found or not executable at $BUILD_SCRIPT_DIR/scripts/validate-openivm-meta.sh"
        exit 1
    fi
    "$BUILD_SCRIPT_DIR/scripts/validate-openivm-meta.sh" "$BUILD_DIR"
    log_success "OpenIVM metadata probe passed"
fi

echo ""
echo -e "${BLUE}To use DuckDB:${NC}"
echo -e "  cd $BUILD_DIR"
echo -e "  ./duckdb"
echo ""
