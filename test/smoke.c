// Links libduckdb_static.a, registers the compiled-in extensions and uses each
// one, with autoloading and autoinstall impossible: if anything were missing
// from the archive, this would fail rather than download it.
//
// Usage: smoke v<duckdb version> <extension>=<version>...

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "duckdb.h"
#include "duckdb_static_extension.h"

int32_t duckdb_register_static_extensions(void);

static duckdb_connection con;

static void fail(const char *what, const char *detail) {
	fprintf(stderr, "FAIL %s: %s\n", what, detail ? detail : "");
	exit(1);
}

static void run(const char *sql) {
	duckdb_result r;
	if (duckdb_query(con, sql, &r) == DuckDBError) {
		fail(sql, duckdb_result_error(&r));
	}
	duckdb_destroy_result(&r);
}

// The query must fail with an error containing `want`.
static void refused(const char *sql, const char *want) {
	duckdb_result r;
	if (duckdb_query(con, sql, &r) != DuckDBError) {
		fail(sql, "succeeded, should have been refused");
	}
	if (!strstr(duckdb_result_error(&r), want)) {
		fail(sql, duckdb_result_error(&r));
	}
	printf("ok   %-60.60s refused\n", sql);
	duckdb_destroy_result(&r);
}

// The first column of the first row, as text; the caller frees it.
static char *scalar(const char *sql) {
	duckdb_result r;
	if (duckdb_query(con, sql, &r) == DuckDBError) {
		fail(sql, duckdb_result_error(&r));
	}
	if (duckdb_row_count(&r) < 1) {
		fail(sql, "no rows");
	}
	char *value = duckdb_value_varchar(&r, 0, 0);
	duckdb_destroy_result(&r);
	if (!value) {
		fail(sql, "NULL");
	}
	return value;
}

static void expect(const char *sql, const char *want) {
	char *got = scalar(sql);
	if (strcmp(got, want) != 0) {
		fprintf(stderr, "FAIL %s: got %s, want %s\n", sql, got, want);
		exit(1);
	}
	printf("ok   %-60.60s = %s\n", sql, got);
	duckdb_free(got);
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fail("usage", "smoke v<version> <extension>=<version>...");
	}
	if (duckdb_register_static_extensions() != 0) {
		fail("duckdb_register_static_extensions", "an extension did not register");
	}
	duckdb_database db;
	if (duckdb_open(NULL, &db) == DuckDBError || duckdb_connect(db, &con) == DuckDBError) {
		fail("open", "in-memory database");
	}

	expect("SELECT version()", argv[1]);

	// Every extension: loadable, statically linked, at the pinned version.
	char sql[512];
	for (int i = 2; i < argc; i++) {
		char name[128];
		const char *eq = strchr(argv[i], '=');
		if (!eq || (size_t)(eq - argv[i]) >= sizeof(name)) {
			fail("argument", argv[i]);
		}
		memcpy(name, argv[i], eq - argv[i]);
		name[eq - argv[i]] = 0;
		snprintf(sql, sizeof(sql), "LOAD %s", name);
		run(sql);
		snprintf(sql, sizeof(sql),
		         "SELECT install_mode || ' ' || extension_version FROM duckdb_extensions() "
		         "WHERE extension_name = '%s' AND loaded",
		         name);
		char want[160];
		snprintf(want, sizeof(want), "STATICALLY_LINKED %s", eq + 1);
		expect(sql, want);
	}

	// And use them.
	expect("SELECT ('{\"a\": 42}'::JSON)->>'a'", "42");                                    // json
	expect("SELECT strftime(TIMESTAMPTZ '2024-01-01 00:00:00+00' AT TIME ZONE 'Asia/Tokyo', '%H')", "09"); // icu
	run("COPY (SELECT range AS v FROM range(1000)) TO 'smoke.parquet' (FORMAT parquet)"); // parquet
	expect("SELECT sum(v) FROM read_parquet('smoke.parquet')", "499500");
	run("ATTACH 'ducklake:smoke.ducklake' AS lake (DATA_PATH 'smoke-data/')");           // ducklake
	run("CREATE TABLE lake.t AS SELECT range AS v FROM range(10)");
	expect("SELECT sum(v) FROM lake.t", "45");
	expect("SELECT count(*) > 0 FROM duckdb_functions() WHERE function_name LIKE 'postgres%'", "true");   // postgres
	expect("SELECT count(*) > 0 FROM duckdb_secret_types() WHERE type = 's3'", "true");              // httpfs
	expect("SELECT count(*) > 0 FROM duckdb_functions() WHERE function_name LIKE 'quack%'", "true");     // quack

	// gatekeeper: allow one table, then enforce on a fresh connection.
	run("CREATE TABLE secrets AS SELECT 'x' AS token");
	run("CALL gatekeeper_configure(allowed_tables := [{schema_path: ['main'], 'table': 't'}])");
	expect("SELECT code FROM gatekeeper_validate('SELECT * FROM secrets')", "forbidden");
	duckdb_disconnect(&con);
	if (duckdb_connect(db, &con) == DuckDBError) {
		fail("connect", "second connection");
	}
	run("CREATE TABLE t AS SELECT range AS v FROM range(4)");
	run("CALL gatekeeper_enforce()");
	expect("WITH w AS (SELECT v FROM t) SELECT string_agg(v::VARCHAR, ',' ORDER BY v) FROM w", "0,1,2,3");
	refused("SELECT * FROM secrets", "Permission Error");
	refused("SELECT getenv('HOME')", "Permission Error");

	duckdb_disconnect(&con);
	duckdb_close(&db);
	printf("all good\n");
	return 0;
}
