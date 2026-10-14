# PostgreSQL with pgvectorscale and pg_textsearch on Railway

[![Release](https://img.shields.io/github/v/release/joeychilson/railway-pgvectorscale-textsearch)](https://github.com/joeychilson/railway-pgvectorscale-textsearch/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Railway template for PostgreSQL 18 with
[pgvector](https://github.com/pgvector/pgvector),
[pgvectorscale](https://github.com/timescale/pgvectorscale), and
[pg_textsearch](https://github.com/timescale/pg_textsearch) for vector, BM25,
and hybrid search. The image builds on Railway's
[`postgres-ssl`](https://github.com/railwayapp-templates/postgres-ssl) image, so
it keeps SSL, pgBackRest WAL archiving, point-in-time recovery, and Railway's
volume checks.

## Deploy

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/postgresql-with-pgvectorscale-and-pgtext?referralCode=NhCCIt&utm_medium=integration&utm_source=template&utm_campaign=generic)

The template creates one `Postgres` service with:

- The `ghcr.io/joeychilson/railway-pgvectorscale-textsearch` image for amd64 and
  arm64.
- A volume at `/var/lib/postgresql/data`.
- A generated `POSTGRES_PASSWORD`.
- `DATABASE_URL` for private networking and `DATABASE_PUBLIC_URL` through a TCP
  proxy on port `5432`.
- The `vector`, `vectorscale`, and `pg_textsearch` extensions, created in the
  default database.

| Extension | Adds |
|---|---|
| `vector` | Vector types, similarity search, and HNSW and IVFFlat indexes |
| `vectorscale` | StreamingDiskANN indexes and statistical binary quantization |
| `pg_textsearch` | BM25 ranking with Block-Max WAND |

pg_textsearch must be in `shared_preload_libraries`. The image adds it on new
volumes and on every boot of an existing one.

To deploy the image without the template, use
`ghcr.io/joeychilson/railway-pgvectorscale-textsearch:<version>`, attach a
volume at `/var/lib/postgresql/data`, and set the variables below. The base
image refuses to start on Railway without that volume, so a missing volume
can't lose data.

## Usage

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

`<@>` returns the negative BM25 score, so lower values are better matches.

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

## Configuration

| Variable | Value | Purpose |
|---|---|---|
| `PGDATA` | `/var/lib/postgresql/data/pgdata` | Data directory |
| `POSTGRES_USER` | `postgres` | Database user |
| `POSTGRES_PASSWORD` | Generated | Database password |
| `POSTGRES_DB` | `railway` | Default database |
| `DATABASE_URL` | Generated | Connection string over private networking |
| `DATABASE_PUBLIC_URL` | Generated | Connection string through the TCP proxy |
| `POSTGRES_ENSURE_EXTENSIONS` | `on` | Set to `off` to stop creating and updating extensions on boot |
| `SSL_CERT_DAYS` | `820` | Lifetime of the self-signed certificate |
| `WAL_ARCHIVE_*`, `WAL_RECOVER_FROM_*` | Optional | pgBackRest archiving and recovery settings from `postgres-ssl` |

Other services in the project connect with:

```text
postgresql://${{POSTGRES_USER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{POSTGRES_DB}}
```

## Updates

Each release is published as
`ghcr.io/joeychilson/railway-pgvectorscale-textsearch:X.Y.Z` and moves the `X.Y`
tag to it. The Railway template deploys `X.Y` with patch auto-updates on, so a
deployment that keeps that setting picks up patch releases in Railway's nightly
update window. A minor or major release starts a new `X.Y` tag, and its release
notes say what to change before you move to it.

Releases are also published as `ghcr.io/joeychilson/railway-pg-vectorscale-textsearch`,
the name from before the repo was renamed, so older deployments keep getting
updates. New deployments should use the current name.

On every boot, a background job creates missing extensions and runs
`ALTER EXTENSION ... UPDATE` when the image ships newer extension SQL, so
existing databases stay in step with the libraries in the image. PostgreSQL
minor versions upgrade in place. A PostgreSQL major upgrade needs a dump and
restore or logical replication; never point an existing volume at a new major
version.

[Renovate](https://docs.renovatebot.com) bumps PostgreSQL minor versions,
pgvector, pgvectorscale, and pg_textsearch. The bump merges after the smoke
test passes on amd64 and arm64, and the merge publishes a patch release.
pgvectorscale minor updates wait for review while it is on 0.x. The release
policy for all of these templates is in
[railway-templates](https://github.com/joeychilson/railway-templates#releases).

### Upgrading from the original image

The original `latest` and `sha-3a11be2` images have PostgreSQL 18 without SSL
and an unversioned development build of pg_textsearch (`0.1.1-dev`). They stay
available but get no updates.

The PostgreSQL major version is the same, so a deployment without BM25 indexes
can switch straight to a current tag. On its first boot the image creates SSL
certificates, updates `shared_preload_libraries`, and replaces the development
extension when nothing depends on it.

BM25 indexes from the development build use an incompatible on-disk format.
Drop them before recreating the extension:

```sql
DROP INDEX <bm25_index>;
DROP EXTENSION pg_textsearch;
CREATE EXTENSION pg_textsearch;
-- Recreate the BM25 indexes.
```

A dump and restore into a new service also works:

```text
pg_dump -Fc "$OLD_DATABASE_URL" | pg_restore -d "$NEW_DATABASE_URL" --no-owner
```

## Development

```text
docker build -t railway-pgvectorscale-textsearch:test .
./test/smoke-test.sh railway-pgvectorscale-textsearch:test
```

The smoke test checks SSL, the preload setting, all three extensions and their
versions, StreamingDiskANN and BM25 queries, data after a restart, and a clean
shutdown on SIGTERM.

## License

[MIT](LICENSE)
