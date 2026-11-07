#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-${DUCKDB_BUILD_DIR:-${HOME}/duckdbsrc/build/release-static}}"

if [[ -x "$TARGET_DIR/test/unittest" ]]; then
	BUILD_DIR="$TARGET_DIR"
elif [[ -x "$TARGET_DIR/build/release-static/test/unittest" ]]; then
	BUILD_DIR="$TARGET_DIR/build/release-static"
else
	echo "DuckDB unittest binary not found under: $TARGET_DIR" >&2
	echo "Pass a DuckDB build directory or source checkout, or set DUCKDB_BUILD_DIR." >&2
	exit 2
fi

find_registered_driver() {
	local info registry path
	if [[ -n "${ODBC_DRIVER_LIBRARY:-}" ]]; then
		printf '%s\n' "$ODBC_DRIVER_LIBRARY"
		return 0
	fi

	if command -v odbcinst >/dev/null 2>&1; then
		info="$(odbcinst -q -d -n 'DuckDB Driver' 2>/dev/null || true)"
		path="$(printf '%s\n' "$info" | sed -n -E 's/^[[:space:]]*[Dd]river[[:space:]]*=[[:space:]]*//p' | head -n 1)"
		if [[ -n "$path" ]]; then
			printf '%s\n' "$path"
			return 0
		fi
	fi

	local system_dir="${ODBCSYSINI:-/etc}"
	local driver_file="${ODBCINSTINI:-odbcinst.ini}"
	for registry in "$system_dir/$driver_file" "$HOME/.odbcinst.ini"; do
		[[ -r "$registry" ]] || continue
		path="$(awk '
			BEGIN { in_driver = 0 }
			tolower($0) ~ /^[[:space:]]*\[duckdb driver\][[:space:]]*$/ { in_driver = 1; next }
			in_driver && /^[[:space:]]*\[/ { exit }
			in_driver && tolower($0) ~ /^[[:space:]]*driver[[:space:]]*=/ {
				sub(/^[^=]*=[[:space:]]*/, "")
				sub(/[[:space:]]+$/, "")
				print
				exit
			}
		' "$registry")"
		if [[ -n "$path" ]]; then
			printf '%s\n' "$path"
			return 0
		fi
	done
	return 1
}

if ! DRIVER_LIBRARY="$(find_registered_driver)"; then
	echo "DuckDB ODBC driver is not registered. Set ODBC_DRIVER_LIBRARY to libduckdb_odbc.so." >&2
	exit 2
fi
DRIVER_LIBRARY="${DRIVER_LIBRARY%\"}"
DRIVER_LIBRARY="${DRIVER_LIBRARY#\"}"
if [[ ! -r "$DRIVER_LIBRARY" ]]; then
	echo "DuckDB ODBC driver library is not readable: $DRIVER_LIBRARY" >&2
	exit 2
fi

ODBC_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/duckdb-odbc-tests.XXXXXX")"
trap 'rm -rf "$ODBC_CONFIG_DIR"' EXIT
cat > "$ODBC_CONFIG_DIR/odbcinst.ini" <<EOF
[DuckDB Driver]
Description=DuckDB ODBC Driver
Driver=$DRIVER_LIBRARY
EOF

export ODBCSYSINI="$ODBC_CONFIG_DIR"
export ODBCINSTINI=odbcinst.ini
export ODBC_CONN_STRING='Driver={DuckDB Driver};threads=1;'

echo "DuckDB ODBC driver: $DRIVER_LIBRARY"
echo "Running DuckDB-backed ODBC SQL tests from: $BUILD_DIR"
echo "Other DBMS-specific tests remain gated on their own servers and connection strings."

cd "$BUILD_DIR"
"$BUILD_DIR/test/unittest" \
	'*test/sql/duckdb/*,*test/sql/connect.test,*test/sql/close.test' \
	--reporter compact --durations yes
