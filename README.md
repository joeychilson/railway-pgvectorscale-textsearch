# railway-pgvectorscale-textsearch

**PostgreSQL 18 with [pgvector](https://github.com/pgvector/pgvector),
[pgvectorscale](https://github.com/timescale/pgvectorscale), and
[pg_textsearch](https://github.com/timescale/pg_textsearch)** — vector search
plus true BM25 ranking for hybrid search, built for
[Railway](https://railway.com). It extends Railway's official
[`postgres-ssl`](https://github.com/railwayapp-templates/postgres-ssl) image,
so you keep self-signed SSL, pgBackRest WAL archiving / point-in-time
recovery, and Railway's volume conventions.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/postgresql-with-pgvectorscale-and-pgtext?referralCode=NhCCIt&utm_medium=integration&utm_source=template&utm_campaign=generic)

## What's inside

| Extension | What it gives you |
|---|---|
| `vector` (pgvector, from PGDG) | Vector similarity search: `vector` type, HNSW + IVFFlat indexes |
| `vectorscale` (pgvectorscale, prebuilt release package) | StreamingDiskANN index + statistical binary quantization — pgvector at bigger scale, lower memory |
| `pg_textsearch` (compiled from the pinned release tag) | True BM25 ranking with Block-Max WAND — Elasticsearch-quality keyword search |

All three are created automatically in your database on first boot.
`pg_textsearch` requires `shared_preload_libraries`, and this image manages
that for you: a managed block at the end of `postgresql.conf` is regenerated
on every boot, so the preload list is always correct — including on volumes
initialized by older versions of this image that didn't set it.

## How updates are delivered (and why nothing breaks)

- Images are published **only** from GitHub releases, under **immutable
  version tags** (`X.Y.Z`, `X.Y`, `sha-<commit>`). A tag you deploy is never
  mutated underneath you. (The pre-existing `latest` tag is frozen at the
  original build and will not move.)
- On every boot, a background task creates the default extensions if missing
  and runs `ALTER EXTENSION ... UPDATE` to bring installed extensions up to
  the version the image ships. pgvectorscale's shared library is
  version-named, so this step is what makes image upgrades safe for existing
  databases. Disable with `POSTGRES_ENSURE_EXTENSIONS=off`.
- Postgres **minor** upgrades ride along with new image releases and are safe
  for your data volume. **Major** upgrades (e.g. 18 → 19) require a
  dump/restore or logical replication, as with any Postgres — never just
  switch the image tag across a major version.
- Railway's [image auto-updates](https://docs.railway.com/deployments/image-auto-updates)
  work with the semver tags: enable them on your service to be offered
  patch/minor bumps during a maintenance window you choose.
- This repo was previously named `railway-pg-vectorscale-textsearch`. Every
  release is still published under the old image name
  (`ghcr.io/joeychilson/railway-pg-vectorscale-textsearch`) as well, so
  deployments created before the rename keep receiving updates. New
  deployments should use the current name.

## Usage examples

### Vector search with pgvectorscale

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

### BM25 text search with pg_textsearch

```sql
CREATE INDEX ON documents USING bm25(content) WITH (text_config='english');

-- Lower score = better match (<@> returns the negative BM25 score)
SELECT id, content, content <@> 'search query' AS score
FROM documents
ORDER BY content <@> 'search query'
LIMIT 10;
```

### Hybrid search (vector + text)

```sql
SELECT id, content,
       (embedding <=> $1) AS vector_score,
       (content <@> $2) AS text_score
FROM documents
ORDER BY 0.7 * (embedding <=> $1) + 0.3 * (content <@> $2)
LIMIT 10;
```

### Tuning

```sql
-- pg_textsearch
SET pg_textsearch.default_limit = 1000;
SET pg_textsearch.bulk_load_threshold = 100000;
SET pg_textsearch.memtable_spill_threshold = 800000;

-- pgvectorscale: query accuracy vs speed
SET diskann.query_search_list_size = 100;
SET diskann.query_rescore = 50;
```

## Deploying manually (outside the template)

1. Create a service from the image
   `ghcr.io/joeychilson/railway-pgvectorscale-textsearch:<version>`.
2. **Attach a volume at `/var/lib/postgresql/data`** (the base image refuses
   to boot on Railway without it — this protects your data).
3. Set variables:

   | Variable | Value |
   |---|---|
   | `PGDATA` | `/var/lib/postgresql/data/pgdata` |
   | `POSTGRES_USER` | `postgres` |
   | `POSTGRES_PASSWORD` | a strong secret |
   | `POSTGRES_DB` | `railway` |
   | `DATABASE_URL` | `postgresql://${{POSTGRES_USER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{POSTGRES_DB}}` |

4. Add a TCP proxy on port `5432` if you want external access.

## Upgrading from the original image (`:latest` / `sha-3a11be2`)

Deployments created from this template before the rebuild run an image with
no SSL and an unversioned dev build of pg_textsearch (`0.1.1-dev`) whose BM25
ranking queries don't work in their documented form. That image will not
change. Because both images are PostgreSQL 18, you can switch **in place**:
edit your service's image to the current version tag and redeploy. On first
boot the image generates SSL certificates for the existing volume, fixes
`shared_preload_libraries`, updates `vector` to the shipped version, and —
if you never created a BM25 index — replaces the dev build of pg_textsearch
with the released version automatically. Your data is untouched.

The one manual case: if you created BM25 indexes on the old image, the dev
build can't be dropped automatically (your indexes depend on it, and their
on-disk format is not compatible with the released library). The boot log
prints a warning; run:

```sql
DROP INDEX <your bm25 indexes>;
DROP EXTENSION pg_textsearch;
CREATE EXTENSION pg_textsearch;
-- recreate your bm25 indexes
```

Prefer a clean start? Dump/restore works too:
`pg_dump -Fc "$OLD_DATABASE_URL" | pg_restore -d "$NEW_DATABASE_URL" --no-owner`

## Local development

```bash
docker compose up -d --build
./test/smoke-test.sh $(docker compose images -q postgres)
```

The smoke test boots the image, verifies SSL, the preload list, and all three
extensions, builds `diskann` and `bm25` indexes, queries them, and restarts
the container to prove data survives. CI runs it before any image is
published.

## Environment variables (image-specific)

| Variable | Default | Purpose |
|---|---|---|
| `POSTGRES_ENSURE_EXTENSIONS` | `on` | `off` disables the boot-time extension create/update task |
| `SSL_CERT_DAYS` | `820` | Self-signed cert validity (base image) |
| `WAL_ARCHIVE_*` / `WAL_RECOVER_FROM_*` | – | pgBackRest WAL archiving & PITR (base image; see its README) |

## Documentation

- [pgvectorscale](https://github.com/timescale/pgvectorscale)
- [pg_textsearch](https://github.com/timescale/pg_textsearch)
- [pgvector](https://github.com/pgvector/pgvector)
- [Railway Docs](https://docs.railway.com/)

## License

MIT License
