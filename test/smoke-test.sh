#!/usr/bin/env bash
# Boot the image in docker and exercise everything the template advertises:
# SSL on, pg_textsearch preloaded, vector + vectorscale + pg_textsearch
# installed, a diskann index and a bm25 index that actually build and answer
# queries, and a restart that keeps data and re-runs the extension updater.
# CI runs this before any image is published.
#
# Usage: ./test/smoke-test.sh <image>
set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image>}"
NAME="pgtext-smoke-$$"

cleanup() {
  docker logs "$NAME" 2>&1 | tail -40 || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm -f "${NAME}-data" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$NAME" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=railway \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v "${NAME}-data:/var/lib/postgresql/data" \
  "$IMAGE" >/dev/null

sql() { docker exec "$NAME" psql -X -U postgres -d railway -tAc "$1"; }

wait_ready() {
  for _ in $(seq 1 60); do
    if docker exec "$NAME" pg_isready -q -h 127.0.0.1 -U postgres 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: postgres did not become ready" >&2
  exit 1
}

wait_extension() {
  local ext="$1"
  for _ in $(seq 1 30); do
    if [ "$(sql "SELECT count(*) FROM pg_extension WHERE extname = '$ext'")" = "1" ]; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: extension $ext was never created" >&2
  exit 1
}

echo "==> waiting for first boot"
wait_ready
wait_extension vector
wait_extension vectorscale
wait_extension pg_textsearch

echo "==> ssl"
test "$(sql 'SHOW ssl')" = "on"

echo "==> pg_textsearch is preloaded"
sql "SHOW shared_preload_libraries" | grep -q pg_textsearch

echo "==> installed extensions"
sql "SELECT extname || ' ' || extversion FROM pg_extension
     WHERE extname IN ('vector','vectorscale','pg_textsearch') ORDER BY extname"

echo "==> extension SQL matches the version shipped in the image"
test "$(sql "SELECT count(*) FROM pg_available_extensions
             WHERE name IN ('vector','vectorscale','pg_textsearch')
               AND installed_version IS DISTINCT FROM default_version")" = "0"

echo "==> vector + diskann index"
sql "CREATE TABLE smoke_items (id bigserial PRIMARY KEY, embedding vector(3))" >/dev/null
sql "INSERT INTO smoke_items (embedding)
     SELECT ('[' || i || ',' || i+1 || ',' || i+2 || ']')::vector
     FROM generate_series(1, 100) i" >/dev/null
sql "CREATE INDEX ON smoke_items USING diskann (embedding vector_cosine_ops)" >/dev/null
test -n "$(sql "SELECT id FROM smoke_items ORDER BY embedding <=> '[5,6,7]' LIMIT 1")"

echo "==> bm25 index (this is what breaks without shared_preload_libraries)"
sql "CREATE TABLE smoke_docs (id bigserial PRIMARY KEY, content text)" >/dev/null
sql "INSERT INTO smoke_docs (content) VALUES
     ('PostgreSQL is a powerful database system'),
     ('BM25 is an effective ranking function'),
     ('Full text search with custom scoring')" >/dev/null
sql "CREATE INDEX smoke_docs_idx ON smoke_docs USING bm25(content) WITH (text_config='english')" >/dev/null
test -n "$(sql "SELECT id FROM smoke_docs ORDER BY content <@> 'database system' LIMIT 1")"

echo "==> restart: data survives and the ensure job re-runs cleanly"
docker restart "$NAME" >/dev/null
wait_ready
test "$(sql 'SELECT count(*) FROM smoke_items')" = "100"
test -n "$(sql "SELECT id FROM smoke_docs ORDER BY content <@> 'ranking' LIMIT 1")"

echo "PASS"
trap - EXIT
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker volume rm -f "${NAME}-data" >/dev/null 2>&1 || true
