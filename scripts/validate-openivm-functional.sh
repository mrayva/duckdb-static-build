#!/bin/bash
set -euo pipefail

# Validate OpenIVM functionally against a DuckDB build tree that contains
# a loadable openivm.duckdb_extension artifact.
#
# Usage:
#   ./scripts/validate-openivm-functional.sh <build-dir> [core|full]

BUILD_DIR="${1:-}"
SUITE="${2:-core}"

if [ -z "$BUILD_DIR" ]; then
    echo "usage: $0 <build-dir> [core|full]" >&2
    exit 2
fi

if [ "$SUITE" != "core" ] && [ "$SUITE" != "full" ]; then
    echo "invalid suite: $SUITE (expected core or full)" >&2
    exit 2
fi

require_file() {
    local path="$1"
    if [ ! -e "$path" ]; then
        echo "required path missing: $path" >&2
        exit 2
    fi
}

DUCKDB_DIR="$(cd "$BUILD_DIR/../.." && pwd)"
OPENIVM_EXT="$BUILD_DIR/extension/openivm/openivm.duckdb_extension"
LIBDUCKDB_DIR="$BUILD_DIR/src"
OPENIVM_TEST_DIR="$DUCKDB_DIR/build/openivm-local-src/test/sql"
RUNNER_CPP="$(mktemp /tmp/openivm_slt_runner.XXXXXX.cpp)"
RUNNER_BIN="$(mktemp /tmp/openivm_slt_runner.XXXXXX)"
LOG_PATH="/tmp/openivm_${SUITE}_validation.log"

cleanup() {
    rm -f "$RUNNER_CPP" "$RUNNER_BIN"
}
trap cleanup EXIT

require_file "$BUILD_DIR/duckdb"
require_file "$OPENIVM_EXT"
require_file "$LIBDUCKDB_DIR/libduckdb.so"
require_file "$OPENIVM_TEST_DIR"
require_file "$DUCKDB_DIR/src/include/duckdb.hpp"

cat > "$RUNNER_CPP" <<'EOF'
#include "duckdb.hpp"
#include "duckdb/main/config.hpp"
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

struct Failure {
    std::string file;
    int line;
    std::string phase;
    std::string message;
};

static std::string Trim(const std::string &s) {
    auto start = s.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    auto end = s.find_last_not_of(" \t\r\n");
    return s.substr(start, end - start + 1);
}

static bool StartsWith(const std::string &s, const std::string &prefix) {
    return s.rfind(prefix, 0) == 0;
}

static std::string ReplaceAll(std::string s, const std::string &from, const std::string &to) {
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
    return s;
}

struct Runner {
    std::string openivm_ext_path;
    std::vector<Failure> failures;
    std::vector<std::string> loaded_exts;
    std::unique_ptr<duckdb::DuckDB> db;
    std::unique_ptr<duckdb::Connection> con;

    void OpenDatabase(const std::string &dbpath) {
        duckdb::DBConfig config;
        config.SetOptionByName("allow_unsigned_extensions", duckdb::Value(true));
        config.SetOptionByName("allow_community_extensions", duckdb::Value(true));
        db = std::make_unique<duckdb::DuckDB>(dbpath, &config);
        con = std::make_unique<duckdb::Connection>(*db);
        for (const auto &ext : loaded_exts) {
            auto res = con->Query(ext);
            if (!res || res->HasError()) {
                throw std::runtime_error("Failed to load extension on reopen: " +
                                         (res ? res->GetError() : std::string("null result")));
            }
        }
    }

    static void EnsureParentDir(const std::string &path) {
        auto parent = fs::path(path).parent_path();
        if (!parent.empty()) {
            fs::create_directories(parent);
        }
    }

    bool ExecSQL(const std::string &sql, std::string &error) {
        auto res = con->Query(sql);
        if (!res) {
            error = "null result";
            return false;
        }
        if (res->HasError()) {
            error = res->GetError();
            return false;
        }
        return true;
    }

    bool LoadRequirement(const std::string &name, std::string &error) {
        std::string stmt;
        if (name == "openivm") {
            stmt = "LOAD '" + openivm_ext_path + "'";
        } else {
            stmt = "LOAD " + name;
        }
        if (std::find(loaded_exts.begin(), loaded_exts.end(), stmt) == loaded_exts.end()) {
            loaded_exts.push_back(stmt);
        }
        return ExecSQL(stmt, error);
    }

    bool HandleInstallStatement(const std::string &sql, std::string &error, bool &handled) {
        handled = false;
        auto trimmed = Trim(sql);
        if (!StartsWith(trimmed, "INSTALL ") || trimmed.find('\n') != std::string::npos) {
            return true;
        }
        auto ext = Trim(trimmed.substr(std::string("INSTALL ").size()));
        if (!ext.empty() && ext.back() == ';') {
            ext.pop_back();
        }
        ext = Trim(ext);
        if (ext.empty()) {
            return true;
        }
        handled = true;
        return LoadRequirement(ext, error);
    }

    static std::vector<std::string> ReadLines(const std::string &path) {
        std::ifstream in(path);
        std::vector<std::string> lines;
        std::string line;
        while (std::getline(in, line)) {
            if (!line.empty() && line.back() == '\r') {
                line.pop_back();
            }
            lines.push_back(line);
        }
        return lines;
    }

    static std::string CollectSQL(const std::vector<std::string> &lines, size_t &i, const std::string &test_dir,
                                  bool stop_on_separator) {
        std::string sql;
        for (; i < lines.size(); i++) {
            auto trimmed = Trim(lines[i]);
            if (trimmed.empty()) {
                break;
            }
            if (stop_on_separator && trimmed == "----") {
                break;
            }
            sql += ReplaceAll(lines[i], "__TEST_DIR__", test_dir);
            sql += '\n';
        }
        return sql;
    }

    static std::vector<std::string> CollectExpected(const std::vector<std::string> &lines, size_t &i,
                                                    const std::string &test_dir) {
        std::vector<std::string> expected;
        for (; i < lines.size(); i++) {
            if (Trim(lines[i]).empty()) {
                break;
            }
            expected.push_back(ReplaceAll(lines[i], "__TEST_DIR__", test_dir));
        }
        return expected;
    }

    static std::vector<std::string> FlattenResult(duckdb::MaterializedQueryResult &res) {
        std::vector<std::string> out;
        for (duckdb::idx_t r = 0; r < res.RowCount(); r++) {
            std::string row;
            for (duckdb::idx_t c = 0; c < res.ColumnCount(); c++) {
                if (c > 0) {
                    row += '\t';
                }
                row += res.GetValue(c, r).ToString();
            }
            out.push_back(row);
        }
        return out;
    }

    bool RunTestFile(const std::string &path) {
        std::string test_name = fs::path(path).stem().string();
        std::string test_dir = "/tmp/openivm-functional/" + test_name;
        fs::remove_all(test_dir);
        fs::create_directories(test_dir);
        loaded_exts.clear();
        OpenDatabase(":memory:");

        auto lines = ReadLines(path);
        for (size_t i = 0; i < lines.size(); i++) {
            std::string line = Trim(lines[i]);
            if (line.empty() || StartsWith(line, "#")) {
                continue;
            }

            if (StartsWith(line, "require ")) {
                std::string req = Trim(line.substr(8));
                std::string err;
                if (!LoadRequirement(req, err)) {
                    failures.push_back(Failure{path, int(i + 1), "require", err});
                    return false;
                }
                continue;
            }

            if (StartsWith(line, "load ")) {
                std::string dbpath = ReplaceAll(Trim(line.substr(5)), "__TEST_DIR__", test_dir);
                EnsureParentDir(dbpath);
                try {
                    OpenDatabase(dbpath);
                } catch (std::exception &ex) {
                    failures.push_back(Failure{path, int(i + 1), "load", ex.what()});
                    return false;
                }
                continue;
            }

            if (StartsWith(line, "statement ok")) {
                i++;
                std::string sql = CollectSQL(lines, i, test_dir, false);
                std::string err;
                bool handled_install = false;
                if (!HandleInstallStatement(sql, err, handled_install)) {
                    failures.push_back(Failure{path, int(i + 1), "statement ok", err + "\nSQL:\n" + sql});
                    return false;
                }
                if (handled_install) {
                    continue;
                }
                if (!ExecSQL(sql, err)) {
                    failures.push_back(Failure{path, int(i + 1), "statement ok", err + "\nSQL:\n" + sql});
                    return false;
                }
                continue;
            }

            if (StartsWith(line, "statement error")) {
                i++;
                int sql_line = int(i + 1);
                std::string sql = CollectSQL(lines, i, test_dir, true);
                if (i >= lines.size() || Trim(lines[i]) != "----") {
                    failures.push_back(Failure{path, sql_line, "statement error", "missing ---- separator"});
                    return false;
                }
                i++;
                auto expected = CollectExpected(lines, i, test_dir);
                std::string expected_msg;
                for (size_t k = 0; k < expected.size(); k++) {
                    if (k) {
                        expected_msg += "\n";
                    }
                    expected_msg += expected[k];
                }
                std::string err;
                if (ExecSQL(sql, err)) {
                    failures.push_back(Failure{path, sql_line, "statement error",
                                               "expected error but statement succeeded\nSQL:\n" + sql});
                    return false;
                }
                if (!expected_msg.empty() && err.find(expected_msg) == std::string::npos) {
                    failures.push_back(Failure{path, sql_line, "statement error",
                                               "error mismatch\nExpected substring: " + expected_msg +
                                                   "\nActual: " + err + "\nSQL:\n" + sql});
                    return false;
                }
                continue;
            }

            if (StartsWith(line, "query ")) {
                i++;
                int sql_line = int(i + 1);
                std::string sql = CollectSQL(lines, i, test_dir, true);
                if (i >= lines.size() || Trim(lines[i]) != "----") {
                    failures.push_back(Failure{path, sql_line, "query", "missing ---- separator"});
                    return false;
                }
                i++;
                auto expected = CollectExpected(lines, i, test_dir);
                auto res = con->Query(sql);
                if (!res || res->HasError()) {
                    failures.push_back(Failure{path, sql_line, "query",
                                               std::string("query failed: ") +
                                                   (res ? res->GetError() : "null result") + "\nSQL:\n" + sql});
                    return false;
                }
                auto actual = FlattenResult(*res);
                if (actual != expected) {
                    std::string msg = "result mismatch\nSQL:\n" + sql + "\nExpected:\n";
                    for (const auto &row : expected) {
                        msg += row + "\n";
                    }
                    msg += "Actual:\n";
                    for (const auto &row : actual) {
                        msg += row + "\n";
                    }
                    failures.push_back(Failure{path, sql_line, "query", msg});
                    return false;
                }
                continue;
            }

            failures.push_back(Failure{path, int(i + 1), "parse", "unsupported directive: " + line});
            return false;
        }
        return true;
    }
};

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: openivm_slt_runner <openivm_extension_path> <testfile> [testfile ...]\n";
        return 2;
    }

    Runner runner;
    runner.openivm_ext_path = argv[1];

    int passed = 0;
    for (int i = 2; i < argc; i++) {
        std::string path = argv[i];
        std::cerr << "RUN " << path << "\n";
        if (runner.RunTestFile(path)) {
            passed++;
            std::cerr << "PASS " << path << "\n";
        } else {
            const auto &f = runner.failures.back();
            std::cerr << "FAIL " << path << " @ line " << f.line << " [" << f.phase << "]\n";
            std::cerr << f.message << "\n";
        }
    }
    std::cerr << "SUMMARY passed=" << passed << " failed=" << runner.failures.size() << "\n";
    return runner.failures.empty() ? 0 : 1;
}
EOF

g++ -std=c++17 -O2 -I"$DUCKDB_DIR/src/include" "$RUNNER_CPP" \
    -L"$LIBDUCKDB_DIR" -lduckdb -Wl,-rpath,"$LIBDUCKDB_DIR" -o "$RUNNER_BIN"

if [ "$SUITE" = "core" ]; then
    mapfile -t TEST_FILES < <(find "$OPENIVM_TEST_DIR" -maxdepth 1 -type f \( -name 'ivm_*.test' -o -name 'mv_*.test' \) | sort)
else
    mapfile -t TEST_FILES < <(find "$OPENIVM_TEST_DIR" -maxdepth 1 -type f -name '*.test' | sort)
fi

if [ "${#TEST_FILES[@]}" -eq 0 ]; then
    echo "no OpenIVM tests found in $OPENIVM_TEST_DIR" >&2
    exit 2
fi

echo "Running OpenIVM $SUITE suite against $BUILD_DIR"
echo "Log: $LOG_PATH"
set +e
"$RUNNER_BIN" "$OPENIVM_EXT" "${TEST_FILES[@]}" 2>&1 | tee "$LOG_PATH"
RUNNER_EXIT=${PIPESTATUS[0]}
set -e

echo ""
echo "Validation log written to $LOG_PATH"
exit "$RUNNER_EXIT"
