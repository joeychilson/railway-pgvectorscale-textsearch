# Deploy and Host PostgreSQL with pgvectorscale and pg_textsearch with Railway

PostgreSQL 18 with pgvector, pgvectorscale, and pg_textsearch, for vector, BM25
keyword, and hybrid search in one database. pgvectorscale adds StreamingDiskANN
indexes for large embedding tables, and pg_textsearch adds BM25 ranking. All
three extensions are created for you in the default database.

## About Hosting PostgreSQL with pgvectorscale and pg_textsearch

The template runs one PostgreSQL service from a tested image for amd64 and
arm64, with a volume at `/var/lib/postgresql/data` and a generated password.
The image builds on Railway's own `postgres-ssl` image, so it keeps SSL,
pgBackRest WAL archiving, point-in-time recovery, and Railway's volume checks.
pg_textsearch has to be preloaded, and the image keeps
`shared_preload_libraries` correct on every boot. It also creates missing
extensions and updates their SQL to match the image, so an image update never
leaves a database on an old extension version. Patch releases install
automatically during Railway's nightly update window.

## Common Use Cases

- Hybrid search that ranks by both meaning and keywords
- Retrieval-augmented generation (RAG) with BM25 and vector retrieval
- Full-text search with BM25 ranking instead of `ts_rank`
- Storing embeddings and documents next to the relational data they describe

## Dependencies for PostgreSQL with pgvectorscale and pg_textsearch Hosting

- None. Applications connect with `DATABASE_URL`.

### Deployment Dependencies

- [pgvector](https://github.com/pgvector/pgvector)
- [pgvectorscale](https://github.com/timescale/pgvectorscale)
- [pg_textsearch](https://github.com/timescale/pg_textsearch)
- [Template source and full README](https://github.com/joeychilson/railway-pgvectorscale-textsearch)

### Implementation Details

Connect other services with the `DATABASE_URL` reference variable. It uses
private networking, and `DATABASE_PUBLIC_URL` goes through the TCP proxy.

```sql
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT,
    embedding VECTOR(1536)
);

CREATE INDEX ON documents USING diskann (embedding vector_cosine_ops);
CREATE INDEX ON documents USING bm25(content) WITH (text_config='english');

-- BM25: <@> returns the negative score, so lower is better.
SELECT id FROM documents ORDER BY content <@> 'search query' LIMIT 10;

-- Hybrid
SELECT id FROM documents
ORDER BY 0.7 * (embedding <=> $1) + 0.3 * (content <@> $2)
LIMIT 10;
```

### Why Deploy PostgreSQL with pgvectorscale and pg_textsearch on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will
host your infrastructure so you don't have to deal with configuration, while
allowing you to vertically and horizontally scale it.

By deploying PostgreSQL with pgvectorscale and pg_textsearch on Railway, you are
one step closer to supporting a complete full-stack application with minimal
burden. Host your servers, databases, AI agents, and more on Railway.
