# DuckDB Static Build Kit

Build DuckDB with 24 statically-linked core extensions.
Optionally include `spatial` and experimental `robust-labs/robust` RPT.

## Quick Start

```bash
# First build in a clean clone (recommended)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --clean

# Subsequent builds in same tree (faster)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --skip-vcpkg

# Include spatial (requires GDAL/PROJ/GEOS/SQLite vcpkg deps)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --with-spatial --clean

# Include robust RPT (experimental)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --with-robust-rpt --clean
```

## What This Produces

- Binary: `<duckdb-dir>/build/release-static/duckdb`
- Size: typically ~149-150MB
- 24 statically linked extensions loaded at runtime
- 25 with either `--with-spatial` or `--with-robust-rpt`
- 26 with both optional extensions

## Extensions Included (24)

| Category | Extensions |
|----------|-----------|
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

`spatial` is available through `--with-spatial` and is intentionally not part of the default 24-extension build.

The spatial integration does three extra things:
- Enables DuckDB's `spatial` config by removing `DONT_LINK`.
- Patches spatial's memvfs SQLite open flags so the embedded PROJ database can be opened as a URI.
- Regenerates spatial's embedded `proj_db.c` from the matching vcpkg `proj.db`, avoiding PROJ database layout mismatches.

If you use `--skip-vcpkg`, the spatial dependencies must already exist in `~/vcpkg`.

See [build-instructions.md](/home/mrayva/duckdbbld/build-instructions.md) for a dedicated spatial section.

## Robust RPT Status

`robust-labs/robust` is available through `--with-robust-rpt` and is intentionally not part of the default build.

The integration pins `robust` to commit `5ec7800e000291e27f7433cb513ba606fc675fc1` and applies a compatibility patch for current DuckDB source:
- Adds the missing `probe_empty_registry.hpp` required by the upstream robust code.
- Updates DuckDB API drift around `TableIndex`, `ProjectionIndex`, expression type access, and dynamic table filters.
- Uses OpenSSL from vcpkg.

This path is experimental because it patches upstream extension code. Keep it separate from the default build unless you are specifically testing robust/RPT behavior.

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
- ~20GB free disk if doing fresh dependency setup
