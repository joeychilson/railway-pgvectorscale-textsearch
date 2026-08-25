# pgvectorscale and pg_textsearch on Railway

[![CI](https://github.com/joeychilson/railway-pgvectorscale-textsearch/actions/workflows/ci.yml/badge.svg)](https://github.com/joeychilson/railway-pgvectorscale-textsearch/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/joeychilson/railway-pgvectorscale-textsearch)](https://github.com/joeychilson/railway-pgvectorscale-textsearch/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Railway template for running PostgreSQL 18 with
[pgvector](https://github.com/pgvector/pgvector),
[pgvectorscale](https://github.com/timescale/pgvectorscale), and
[pg_textsearch](https://github.com/timescale/pg_textsearch) for vector, BM25,
and hybrid search.

The image extends Railway's
[`postgres-ssl`](https://github.com/railwayapp-templates/postgres-ssl) image
while preserving SSL, pgBackRest WAL archiving, point-in-time recovery, and
Railway's volume conventions.

## Deployment

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/postgresql-with-pgvectorscale-and-pgtext?referralCode=NhCCIt&utm_medium=integration&utm_source=template&utm_campaign=generic)

The template creates all three extensions automatically:

| Extension | Purpose |
|---|---|
| `vector` | Vector values, similarity search, and HNSW and IVFFlat indexes |
| `vectorscale` | StreamingDiskANN indexes and statistical binary quantization |
| `pg_textsearch` | BM25 ranking with Block-Max WAND |

The image also manages `shared_preload_libraries` for `pg_textsearch` on new
and existing volumes.

For a manual Railway deployment:

1. Use `ghcr.io/joeychilson/railway-pgvectorscale-textsearch:<version>`.
2. Attach a volume at `/var/lib/postgresql/data`.
3. Configure the PostgreSQL variables below.
4. Add a TCP proxy on port `5432` only when external access is required.

The base image refuses to start on Railway without the volume to protect the
database from accidental data loss.

## Configuration

| Variable | Value | Purpose |
|---|---|---|
| `PGDATA` | `/var/lib/postgresql/data/pgdata` | PostgreSQL data directory |
| `POSTGRES_USER` | `postgres` | Database user |
| `POSTGRES_PASSWORD` | Secret | Required database password |
| `POSTGRES_DB` | `railway` | Default database |
| `DATABASE_URL` | Template-generated | Private Railway connection string |
| `POSTGRES_ENSURE_EXTENSIONS` | `on` | Set to `off` to disable automatic extension creation and updates |
| `SSL_CERT_DAYS` | `820` | Self-signed certificate validity |
| `WAL_ARCHIVE_*` | Optional | pgBackRest WAL archiving settings |
| `WAL_RECOVER_FROM_*` | Optional | pgBackRest recovery settings |

The template uses this private connection string:

```text
postgresql://${{POSTGRES_USER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{POSTGRES_DB}}
```

## Examples

### Vector search

```sql
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT,
    embedding VECTOR(1536)
);

CREATE INDEX ON documents USING diskann (embedding vector_cosine_ops);

SELECT id, content
FROM documents
ORDER BY embedding <=> '[0.1, 0.2, ...]'
LIMIT 10;
```

### BM25 search

```sql
CREATE INDEX ON documents USING bm25(content) WITH (text_config='english');

SELECT id, content, content <@> 'search query' AS score
FROM documents
ORDER BY content <@> 'search query'
LIMIT 10;
```

Lower `<@>` scores are better matches because the operator returns the
negative BM25 score.

### Hybrid search

```sql
SELECT id,
       content,
       embedding <=> $1 AS vector_score,
       content <@> $2 AS text_score
FROM documents
ORDER BY 0.7 * (embedding <=> $1) + 0.3 * (content <@> $2)
LIMIT 10;
```

### Tuning

```sql
SET pg_textsearch.default_limit = 1000;
SET pg_textsearch.bulk_load_threshold = 100000;
SET pg_textsearch.memtable_spill_threshold = 800000;

SET diskann.query_search_list_size = 100;
SET diskann.query_rescore = 50;
```

## Updates

Images are published only from GitHub releases. Exact `X.Y.Z` and
`sha-<commit>` tags are immutable, while `X.Y` tracks the latest patch release
in that minor line. The historical `latest` tag is frozen at the original
build and does not receive updates. Use the `X.Y` channel with Railway image
auto-updates to receive reviewed patch releases.

On each boot, a background task creates missing extensions and runs
`ALTER EXTENSION ... UPDATE` when the image contains newer extension SQL. This
keeps existing databases aligned with the libraries shipped in the image.

PostgreSQL minor upgrades can use the existing volume. A PostgreSQL major
upgrade requires a dump and restore or logical replication; never switch an
existing volume directly between major versions.

A weekly workflow checks for new pgvectorscale and pg_textsearch releases and
opens pull requests. Each update is smoke-tested and reviewed before a GitHub
release publishes the image. The wrapper version is independent from
PostgreSQL and the extensions; see [RELEASING.md](RELEASING.md) for the release
policy.

This repository was previously named `railway-pg-vectorscale-textsearch`.
Releases are also published under the previous GHCR package name so existing
deployments continue to receive updates. New deployments should use the current
name.

## Upgrading from the original image

The original `latest` and `sha-3a11be2` images contain PostgreSQL 18 without
SSL and an unversioned development build of pg_textsearch (`0.1.1-dev`). Those
images remain available but do not receive updates.

Because the PostgreSQL major version is unchanged, deployments without BM25
indexes can switch directly to a current version tag. On first boot, the image
creates SSL certificates, updates `shared_preload_libraries`, and replaces the
development extension when nothing depends on it.

If the old database contains BM25 indexes, remove them before recreating the
extension because their on-disk format is incompatible with the released
library:

```sql
DROP INDEX <bm25_index>;
DROP EXTENSION pg_textsearch;
CREATE EXTENSION pg_textsearch;
-- Recreate the BM25 indexes.
```

A dump and restore into a new service is also supported:

```text
pg_dump -Fc "$OLD_DATABASE_URL" | \
  pg_restore -d "$NEW_DATABASE_URL" --no-owner
```

## Development

```text
docker build -t railway-pgvectorscale-textsearch:test .
./test/smoke-test.sh railway-pgvectorscale-textsearch:test
```

The smoke test verifies SSL, the preload configuration, all three extensions,
extension-version alignment, StreamingDiskANN and BM25 queries, and data
persistence after a restart.

## License

[MIT](LICENSE)
