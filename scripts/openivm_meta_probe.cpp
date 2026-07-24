#include "duckdb.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/extension_helper.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

using namespace duckdb;

static void Run(Connection &con, const std::string &sql) {
	auto res = con.Query(sql);
	if (!res || res->HasError()) {
		std::cerr << "SQL error for: " << sql << "\n";
		if (res) {
			std::cerr << res->GetError() << std::endl;
		}
		std::exit(1);
	}
	std::cout << "SQL ok: " << sql << std::endl;
}

static std::string ValueToString(const Value &value) {
	return value.IsNull() ? "NULL" : value.ToString();
}

static void ExpectRows(Connection &con, const std::string &label, const std::string &sql, idx_t expected_rows) {
	auto res = con.Query(sql);
	std::cout << "--- " << label << " ---\n";
	if (!res || res->HasError()) {
		std::cerr << "SQL error for: " << sql << "\n";
		if (res) {
			std::cerr << res->GetError() << std::endl;
		}
		std::exit(1);
	}
	if (res->RowCount() != expected_rows) {
		std::cerr << "Unexpected rowcount for: " << sql << " expected=" << expected_rows
		          << " got=" << res->RowCount() << std::endl;
		std::exit(1);
	}
	std::cout << "rows=" << res->RowCount() << " cols=" << res->ColumnCount() << std::endl;
	for (idx_t r = 0; r < res->RowCount(); r++) {
		std::cout << r << ": ";
		for (idx_t c = 0; c < res->ColumnCount(); c++) {
			if (c) {
				std::cout << " | ";
			}
			std::cout << ValueToString(res->GetValue(c, r));
		}
		std::cout << std::endl;
	}
}

int main(int argc, char **argv) {
	if (argc != 2) {
		std::cerr << "usage: " << argv[0] << " <duckdb-build-dir>" << std::endl;
		return 1;
	}

	std::string build_dir = argv[1];
	std::string openivm_ext = build_dir + "/extension/openivm/openivm.duckdb_extension";
	std::string core_functions_ext = build_dir + "/extension/core_functions/core_functions.duckdb_extension";

	case_insensitive_map_t<Value> options;
	options["allow_unsigned_extensions"] = Value(true);
	DBConfig config(options, false);
	config.options.load_extensions = false;
	DuckDB db(nullptr, &config);
	Connection con(db);

	Run(con, "LOAD '" + openivm_ext + "'");
	Run(con, "LOAD '" + core_functions_ext + "'");

	Run(con, "CREATE TABLE saj_l (id INT, x INT)");
	Run(con, "CREATE TABLE saj_r (rid INT, y INT)");
	Run(con, "INSERT INTO saj_l VALUES (1, 10), (1, 10), (2, 20), (3, 30), (4, 40)");
	Run(con, "INSERT INTO saj_r VALUES (100, 8), (101, 100), (102, 41)");
	Run(con, "CREATE MATERIALIZED VIEW mv_saj_semi AS SELECT l.id, l.x FROM saj_l l SEMI JOIN saj_r r ON l.x BETWEEN r.y - 2 AND r.y + 2");

	Run(con, "CREATE TABLE exists_l (id INT, x INT, keep BOOLEAN)");
	Run(con, "CREATE TABLE exists_r (rid INT, y INT, active BOOLEAN)");
	Run(con, "INSERT INTO exists_l VALUES (1, 10, true), (1, 10, true), (2, 20, true), (3, 30, false), (4, 40, true)");
	Run(con, "INSERT INTO exists_r VALUES (10, 8, true), (11, 20, false), (12, 99, true)");
	Run(con, "CREATE MATERIALIZED VIEW mv_exists_semi AS SELECT l.id, l.x FROM exists_l l WHERE l.keep AND EXISTS (SELECT 1 FROM exists_r r WHERE r.active AND l.x BETWEEN r.y - 2 AND r.y + 2)");

	ExpectRows(con,
	           "metadata summary",
	           "SELECT view_name, type, semi_anti_aux_meta_json IS NULL, length(semi_anti_aux_meta_json) "
	           "FROM openivm_views WHERE view_name IN ('mv_saj_semi','mv_exists_semi') ORDER BY view_name",
	           2);

	ExpectRows(con,
	           "direct saj json",
	           "SELECT semi_anti_aux_meta_json FROM openivm_views WHERE view_name = 'mv_saj_semi'",
	           1);

	ExpectRows(con,
	           "direct exists json",
	           "SELECT semi_anti_aux_meta_json FROM openivm_views WHERE view_name = 'mv_exists_semi'",
	           1);

	return 0;
}
