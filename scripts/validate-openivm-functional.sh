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

cat > "$RUNNER_CPP" <<'CPP'
#include "duckdb.hpp"
#include "duckdb/main/config.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;

struct Failure {
    std::string file;
    int line;
    std::string phase;
    std::string message;
};

struct ExecContext {
    std::string dbpath;
    int thread_id = -1;
    std::unordered_map<std::string, int> vars;
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

static std::vector<std::string> SplitWS(const std::string &s) {
    std::vector<std::string> parts;
    std::string current;
    for (char c : s) {
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
            if (!current.empty()) {
                parts.push_back(current);
                current.clear();
            }
        } else {
            current.push_back(c);
        }
    }
    if (!current.empty()) {
        parts.push_back(current);
    }
    return parts;
}

struct Runner {
    std::string openivm_ext_path;
    std::vector<Failure> failures;
    std::vector<std::string> loaded_exts;
    std::unique_ptr<duckdb::DuckDB> db;
    std::unique_ptr<duckdb::Connection> con;

    static void EnsureParentDir(const std::string &path) {
        if (path == ":memory:") {
            return;
        }
        auto parent = fs::path(path).parent_path();
        if (!parent.empty()) {
            fs::create_directories(parent);
        }
    }

    void OpenDatabaseHandle(const std::string &dbpath, std::unique_ptr<duckdb::DuckDB> &db_handle,
                            std::unique_ptr<duckdb::Connection> &con_handle) {
        duckdb::DBConfig config;
        config.SetOptionByName("allow_unsigned_extensions", duckdb::Value(true));
        config.SetOptionByName("allow_community_extensions", duckdb::Value(true));
        EnsureParentDir(dbpath);
        db_handle = std::make_unique<duckdb::DuckDB>(dbpath, &config);
        con_handle = std::make_unique<duckdb::Connection>(*db_handle);
        for (const auto &ext : loaded_exts) {
            auto res = con_handle->Query(ext);
            if (!res || res->HasError()) {
                throw std::runtime_error("Failed to load extension on reopen: " +
                                         (res ? res->GetError() : std::string("null result")));
            }
        }
    }

    void OpenDatabase(const std::string &dbpath) {
        OpenDatabaseHandle(dbpath, db, con);
    }

    bool ExecSQL(duckdb::Connection &connection, const std::string &sql, std::string &error) {
        auto res = connection.Query(sql);
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

    bool LoadRequirement(duckdb::Connection &connection, const std::string &name, std::string &error) {
        std::string stmt;
        if (name == "openivm") {
            stmt = "LOAD '" + openivm_ext_path + "'";
        } else {
            stmt = "LOAD " + name;
        }
        if (std::find(loaded_exts.begin(), loaded_exts.end(), stmt) == loaded_exts.end()) {
            loaded_exts.push_back(stmt);
        }
        return ExecSQL(connection, stmt, error);
    }

    bool HandleInstallStatement(duckdb::Connection &connection, const std::string &sql, std::string &error,
                                bool &handled) {
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
        return LoadRequirement(connection, ext, error);
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

    static std::string ExpandVars(std::string s, const std::string &test_dir,
                                  const std::unordered_map<std::string, int> &vars) {
        s = ReplaceAll(std::move(s), "__TEST_DIR__", test_dir);
        for (const auto &kv : vars) {
            s = ReplaceAll(std::move(s), "${" + kv.first + "}", std::to_string(kv.second));
        }
        return s;
    }

    static std::string CollectSQL(const std::vector<std::string> &lines, size_t &i, const std::string &test_dir,
                                  const std::unordered_map<std::string, int> &vars, bool stop_on_separator) {
        std::string sql;
        for (; i < lines.size(); i++) {
            auto trimmed = Trim(lines[i]);
            if (trimmed.empty()) {
                break;
            }
            if (stop_on_separator && trimmed == "----") {
                break;
            }
            sql += ExpandVars(lines[i], test_dir, vars);
            sql += '\n';
        }
        return sql;
    }

    static std::vector<std::string> CollectExpected(const std::vector<std::string> &lines, size_t &i,
                                                    const std::string &test_dir,
                                                    const std::unordered_map<std::string, int> &vars) {
        std::vector<std::string> expected;
        for (; i < lines.size(); i++) {
            if (Trim(lines[i]).empty()) {
                break;
            }
            expected.push_back(ExpandVars(lines[i], test_dir, vars));
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

    static bool EvalOnlyIf(const std::string &expr, int thread_id) {
        if (thread_id < 0) {
            return false;
        }
        if (StartsWith(expr, "threadid>=")) {
            return thread_id >= std::stoi(expr.substr(std::string("threadid>=").size()));
        }
        if (StartsWith(expr, "threadid<=")) {
            return thread_id <= std::stoi(expr.substr(std::string("threadid<=").size()));
        }
        if (StartsWith(expr, "threadid=")) {
            return thread_id == std::stoi(expr.substr(std::string("threadid=").size()));
        }
        if (StartsWith(expr, "threadid>")) {
            return thread_id > std::stoi(expr.substr(std::string("threadid>").size()));
        }
        if (StartsWith(expr, "threadid<")) {
            return thread_id < std::stoi(expr.substr(std::string("threadid<").size()));
        }
        return false;
    }

    static size_t FindMatchingEndloop(const std::vector<std::string> &lines, size_t start) {
        int depth = 0;
        for (size_t i = start; i < lines.size(); i++) {
            auto line = Trim(lines[i]);
            if (StartsWith(line, "loop ") || StartsWith(line, "concurrentloop ")) {
                depth++;
            } else if (line == "endloop") {
                depth--;
                if (depth == 0) {
                    return i;
                }
            }
        }
        return lines.size();
    }

    bool ExecuteRange(const std::vector<std::string> &lines, size_t begin, size_t end, const std::string &path,
                      const std::string &test_dir, ExecContext &ctx, std::unique_ptr<duckdb::DuckDB> &db_handle,
                      std::unique_ptr<duckdb::Connection> &con_handle, Failure &failure) {
        bool has_guard = false;
        bool guard_value = true;

        for (size_t i = begin; i < end; i++) {
            std::string line = Trim(lines[i]);
            if (line.empty() || StartsWith(line, "#")) {
                continue;
            }

            if (StartsWith(line, "onlyif ")) {
                bool pred = EvalOnlyIf(Trim(line.substr(7)), ctx.thread_id);
                if (has_guard) {
                    guard_value = guard_value && pred;
                } else {
                    has_guard = true;
                    guard_value = pred;
                }
                continue;
            }

            bool run_current = !has_guard || guard_value;
            has_guard = false;
            guard_value = true;

            if (StartsWith(line, "require ")) {
                if (!run_current) {
                    continue;
                }
                std::string req = Trim(line.substr(8));
                std::string err;
                if (!LoadRequirement(*con_handle, req, err)) {
                    failure = Failure{path, int(i + 1), "require", err};
                    return false;
                }
                continue;
            }

            if (StartsWith(line, "load ")) {
                if (!run_current) {
                    continue;
                }
                ctx.dbpath = ExpandVars(Trim(line.substr(5)), test_dir, ctx.vars);
                EnsureParentDir(ctx.dbpath);
                try {
                    OpenDatabaseHandle(ctx.dbpath, db_handle, con_handle);
                } catch (std::exception &ex) {
                    failure = Failure{path, int(i + 1), "load", ex.what()};
                    return false;
                }
                continue;
            }

            if (StartsWith(line, "statement ok")) {
                i++;
                int sql_line = int(i + 1);
                std::string sql = CollectSQL(lines, i, test_dir, ctx.vars, false);
                if (!run_current) {
                    continue;
                }
                std::string err;
                bool handled_install = false;
                if (!HandleInstallStatement(*con_handle, sql, err, handled_install)) {
                    failure = Failure{path, sql_line, "statement ok", err + "\nSQL:\n" + sql};
                    return false;
                }
                if (handled_install) {
                    continue;
                }
                if (!ExecSQL(*con_handle, sql, err)) {
                    failure = Failure{path, sql_line, "statement ok", err + "\nSQL:\n" + sql};
                    return false;
                }
                continue;
            }

            if (StartsWith(line, "statement error")) {
                i++;
                int sql_line = int(i + 1);
                std::string sql = CollectSQL(lines, i, test_dir, ctx.vars, true);
                if (i >= lines.size() || Trim(lines[i]) != "----") {
                    failure = Failure{path, sql_line, "statement error", "missing ---- separator"};
                    return false;
                }
                i++;
                auto expected = CollectExpected(lines, i, test_dir, ctx.vars);
                if (!run_current) {
                    continue;
                }
                std::string expected_msg;
                for (size_t k = 0; k < expected.size(); k++) {
                    if (k) {
                        expected_msg += "\n";
                    }
                    expected_msg += expected[k];
                }
                std::string err;
                if (ExecSQL(*con_handle, sql, err)) {
                    failure = Failure{path, sql_line, "statement error",
                                      "expected error but statement succeeded\nSQL:\n" + sql};
                    return false;
                }
                if (!expected_msg.empty() && err.find(expected_msg) == std::string::npos) {
                    failure = Failure{path, sql_line, "statement error",
                                      "error mismatch\nExpected substring: " + expected_msg +
                                          "\nActual: " + err + "\nSQL:\n" + sql};
                    return false;
                }
                continue;
            }

            if (StartsWith(line, "query ")) {
                i++;
                int sql_line = int(i + 1);
                std::string sql = CollectSQL(lines, i, test_dir, ctx.vars, true);
                if (i >= lines.size() || Trim(lines[i]) != "----") {
                    failure = Failure{path, sql_line, "query", "missing ---- separator"};
                    return false;
                }
                i++;
                auto expected = CollectExpected(lines, i, test_dir, ctx.vars);
                if (!run_current) {
                    continue;
                }
                auto res = con_handle->Query(sql);
                if (!res || res->HasError()) {
                    failure = Failure{path, sql_line, "query",
                                      std::string("query failed: ") +
                                          (res ? res->GetError() : "null result") + "\nSQL:\n" + sql};
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
                    failure = Failure{path, sql_line, "query", msg};
                    return false;
                }
                continue;
            }

            if (StartsWith(line, "loop ")) {
                size_t block_end = FindMatchingEndloop(lines, i);
                if (block_end >= lines.size()) {
                    failure = Failure{path, int(i + 1), "parse", "unterminated loop"};
                    return false;
                }
                auto parts = SplitWS(line);
                if (parts.size() != 4) {
                    failure = Failure{path, int(i + 1), "parse", "unsupported loop syntax: " + line};
                    return false;
                }
                if (run_current) {
                    const std::string var_name = parts[1];
                    int start = std::stoi(parts[2]);
                    int finish = std::stoi(parts[3]);
                    for (int value = start; value < finish; value++) {
                        ctx.vars[var_name] = value;
                        if (!ExecuteRange(lines, i + 1, block_end, path, test_dir, ctx, db_handle, con_handle,
                                          failure)) {
                            return false;
                        }
                    }
                    ctx.vars.erase(var_name);
                }
                i = block_end;
                continue;
            }

            if (StartsWith(line, "concurrentloop ")) {
                size_t block_end = FindMatchingEndloop(lines, i);
                if (block_end >= lines.size()) {
                    failure = Failure{path, int(i + 1), "parse", "unterminated concurrentloop"};
                    return false;
                }
                auto parts = SplitWS(line);
                if (parts.size() != 4 || parts[1] != "threadid") {
                    failure = Failure{path, int(i + 1), "parse", "unsupported concurrentloop syntax: " + line};
                    return false;
                }
                if (run_current) {
                    int start = std::stoi(parts[2]);
                    int finish = std::stoi(parts[3]);
                    struct ThreadOutcome {
                        bool ok = true;
                        Failure failure;
                    };
                    std::vector<ThreadOutcome> outcomes(size_t(std::max(0, finish - start)));
                    std::vector<std::thread> threads;
                    threads.reserve(outcomes.size());
                    for (int thread_id = start; thread_id < finish; thread_id++) {
                        size_t outcome_idx = size_t(thread_id - start);
                        threads.emplace_back([&, thread_id, outcome_idx]() {
                            ExecContext child_ctx = ctx;
                            child_ctx.thread_id = thread_id;
                            std::unique_ptr<duckdb::DuckDB> thread_db;
                            std::unique_ptr<duckdb::Connection> thread_con;
                            try {
                                thread_con = std::make_unique<duckdb::Connection>(*db_handle);
                                for (const auto &ext : loaded_exts) {
                                    auto res = thread_con->Query(ext);
                                    if (!res || res->HasError()) {
                                        throw std::runtime_error(
                                            "Failed to load extension on thread connection: " +
                                            (res ? res->GetError() : std::string("null result")));
                                    }
                                }
                            } catch (std::exception &ex) {
                                outcomes[outcome_idx].ok = false;
                                outcomes[outcome_idx].failure = Failure{path, int(i + 1), "concurrentloop", ex.what()};
                                return;
                            }
                            Failure local_failure;
                            if (!ExecuteRange(lines, i + 1, block_end, path, test_dir, child_ctx, thread_db,
                                              thread_con, local_failure)) {
                                outcomes[outcome_idx].ok = false;
                                outcomes[outcome_idx].failure = std::move(local_failure);
                            }
                        });
                    }
                    for (auto &thread : threads) {
                        thread.join();
                    }
                    for (auto &outcome : outcomes) {
                        if (!outcome.ok) {
                            failure = std::move(outcome.failure);
                            return false;
                        }
                    }
                    con_handle = std::make_unique<duckdb::Connection>(*db_handle);
                    for (const auto &ext : loaded_exts) {
                        auto res = con_handle->Query(ext);
                        if (!res || res->HasError()) {
                            failure = Failure{path, int(i + 1), "concurrentloop",
                                              "failed to reload extension on main connection: " +
                                                  (res ? res->GetError() : std::string("null result"))};
                            return false;
                        }
                    }
                }
                i = block_end;
                continue;
            }

            if (line == "endloop") {
                failure = Failure{path, int(i + 1), "parse", "unexpected endloop"};
                return false;
            }

            failure = Failure{path, int(i + 1), "parse", "unsupported directive: " + line};
            return false;
        }
        return true;
    }

    bool RunTestFile(const std::string &path) {
        std::string test_name = fs::path(path).stem().string();
        std::string test_dir = "/tmp/openivm-functional/" + test_name;
        fs::remove_all(test_dir);
        fs::create_directories(test_dir);
        loaded_exts.clear();

        ExecContext ctx;
        ctx.dbpath = test_dir + "/main.duckdb";
        OpenDatabase(ctx.dbpath);

        auto lines = ReadLines(path);
        Failure failure;
        if (!ExecuteRange(lines, 0, lines.size(), path, test_dir, ctx, db, con, failure)) {
            failures.push_back(std::move(failure));
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
CPP

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
