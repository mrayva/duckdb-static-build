# DuckDB Static Build Kit

Build DuckDB with 24 statically linked core extensions.
Optionally include `spatial`, and optionally include `openivm` in either stable or active mode.

## Quick Start

```bash
# First build in a clean clone (recommended)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --clean

# Subsequent builds in same tree (faster)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --skip-vcpkg

# Include spatial (requires GDAL/PROJ/GEOS/SQLite vcpkg deps)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --with-spatial --clean

# Include openivm in the stable default profile
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --with-openivm --clean

# Include openivm with runtime hooks and tests enabled
# This active profile is still experimental and not functionally validated yet.
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --with-openivm-active --clean
```

## What This Produces

- Binary: `<duckdb-dir>/build/release-static/duckdb`
- Size: typically ~149-150MB
- 24 statically linked extensions loaded at runtime
- Add 1 loaded extension for `--with-spatial`
- Add 1 loaded extension for `--with-openivm` or `--with-openivm-active`
- 26 loaded extensions when both optional flags are enabled

Current known-good verification matrix:
- `--skip-vcpkg --with-spatial`
- `--skip-vcpkg --with-spatial --with-openivm`
- The current validated `--with-spatial --with-openivm` path produces `26` loaded extensions and a `199M` binary on the current snapshot

## Extensions Included (24)

| Category | Extensions |
|----------|------------|
| Core | autocomplete, icu, json, parquet, core_functions, jemalloc, shell |
| Benchmarks | tpcds, tpch |
| Search | fts, vss |
| Database Connectors | sqlite_scanner, postgres_scanner, mysql_scanner |
| File Formats | excel, avro |
| Cloud Storage | httpfs, aws, azure |
| Table Formats | iceberg, ducklake, delta |
| Catalogs | unity_catalog |
| Networking | inet |

## Spatial Status

`spatial` is available through `--with-spatial` and is intentionally not part of the default build.

The spatial integration does three extra things:
- Enables DuckDB's `spatial` config by removing `DONT_LINK`.
- Patches spatial's memvfs SQLite open flags so the embedded PROJ database can be opened as a URI.
- Regenerates spatial's embedded `proj_db.c` from the matching vcpkg `proj.db`, avoiding PROJ database layout mismatches.

If you use `--skip-vcpkg`, the spatial dependencies must already exist in `~/vcpkg`.

See [build-instructions.md](/home/mrayva/duckdbbld/build-instructions.md) for a dedicated spatial section.

## OpenIVM Status

`openivm` is available through `--with-openivm`.

The stable `--with-openivm` profile builds and starts cleanly, but intentionally keeps OpenIVM runtime hooks inert.

`--with-openivm-active` is the explicitly active profile. It re-enables OpenIVM runtime hooks, adds OpenIVM `test/sql` discovery, and attempts an OpenIVM smoke check plus selected OpenIVM sqllogictests.

That active profile is currently buildable, but it is not functionally validated on this DuckDB snapshot. The remaining failures are in OpenIVM runtime behavior after build, not in source fetch or compile integration.

The active profile builds into `<duckdb-dir>/build/release-static-openivm-active/duckdb` so it does not overwrite the stable default build.

Both profiles still do source preparation before the static build consumes OpenIVM, so upstream DuckDB or OpenIVM refreshes may require patch refreshes.

## Files

| File | Description |
|------|-------------|
| `build-duckdb-static.sh` | Automated build script |
| `build-instructions.md` | Full build/runbook (clean env + troubleshooting) |
| `README.md` | Summary |

## Requirements

- Linux x64
- Git, CMake 3.15+, GCC/G++, Make
- Rust toolchain (for delta extension)
- vcpkg
- `xxd` for spatial builds
- ~20GB free disk if doing fresh dependency setup
