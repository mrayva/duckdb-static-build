# DuckDB Static Build Kit

Build DuckDB with 24 statically-linked core extensions.
Optionally include `spatial` for a 25-extension build.

## Quick Start

```bash
# First build in a clean clone (recommended)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --clean

# Subsequent builds in same tree (faster)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --skip-vcpkg

# Include spatial (requires GDAL/PROJ/GEOS/SQLite vcpkg deps)
./build-duckdb-static.sh --duckdb-dir /tmp/duckdb-clean/duckdbsrc --with-spatial --clean
```

## What This Produces

- Binary: `<duckdb-dir>/build/release-static/duckdb`
- Size: typically ~149-150MB
- 24 statically linked extensions loaded at runtime (25 with `--with-spatial`)

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
