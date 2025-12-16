# railway-pg-vectorscale-textsearch

A Docker container for PostgreSQL 18 with pgvectorscale and pg_textsearch for deploying on Railway or any Docker host.

## Features

- **PostgreSQL 18** - Latest PostgreSQL with modern features
- **pgvector** - Vector similarity search
- **pgvectorscale** - StreamingDiskANN index for high-performance embedding search
- **pg_textsearch** - BM25 ranked text search

## Quick Start

### Build the image

```bash
docker build -t pg-vectorscale-textsearch .
```

### Run the container

```bash
docker run -d \
  --name postgres-vectors \
  -e POSTGRES_PASSWORD=mysecretpassword \
  -p 5432:5432 \
  pg-vectorscale-textsearch
```

### Connect and verify extensions

```bash
psql -h localhost -U postgres -d postgres
```

```sql
-- Extensions are auto-enabled, but you can verify:
\dx

-- Should show:
--  pg_textsearch
--  vector
--  vectorscale
```

## Usage Examples

### Vector Search with pgvectorscale

```sql
-- Create a table with embeddings
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT,
    embedding VECTOR(1536)
);

-- Create a StreamingDiskANN index
CREATE INDEX ON documents USING diskann (embedding vector_cosine_ops);

-- Query similar documents
SELECT id, content
FROM documents
ORDER BY embedding <=> '[0.1, 0.2, ...]'
LIMIT 10;
```

### BM25 Text Search with pg_textsearch

```sql
-- Create a table with text content
CREATE TABLE articles (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    body TEXT
);

-- Create a BM25 index
CREATE INDEX ON articles USING bm25(body) WITH (text_config='english');

-- Search with BM25 ranking (lower score = better match)
SELECT title, body <@> 'search query' AS score
FROM articles
ORDER BY body <@> 'search query'
LIMIT 10;
```

### Hybrid Search (Vector + Text)

```sql
-- Table with both embeddings and text
CREATE TABLE hybrid_docs (
    id BIGSERIAL PRIMARY KEY,
    content TEXT,
    embedding VECTOR(1536)
);

-- Create both indexes
CREATE INDEX ON hybrid_docs USING diskann (embedding vector_cosine_ops);
CREATE INDEX ON hybrid_docs USING bm25(content) WITH (text_config='english');

-- Combine vector and text search with weighted scoring
SELECT id, content,
       (embedding <=> $1) AS vector_score,
       (content <@> $2) AS text_score
FROM hybrid_docs
ORDER BY 0.7 * (embedding <=> $1) + 0.3 * (content <@> $2)
LIMIT 10;
```

## Configuration

### pg_textsearch Settings

```sql
-- Set default query limit
SET pg_textsearch.default_limit = 1000;

-- Configure bulk load thresholds
SET pg_textsearch.bulk_load_threshold = 100000;
SET pg_textsearch.memtable_spill_threshold = 800000;
```

### pgvectorscale Settings

```sql
-- Tune query accuracy vs speed
SET diskann.query_search_list_size = 100;
SET diskann.query_rescore = 50;
```

## Documentation

- [pgvectorscale](https://github.com/timescale/pgvectorscale)
- [pg_textsearch](https://github.com/timescale/pg_textsearch)
- [pgvector](https://github.com/pgvector/pgvector)
- [Railway Docs](https://docs.railway.app/)

## License

MIT License
