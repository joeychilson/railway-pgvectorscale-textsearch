#!/bin/bash
# pgtext-lib.sh — shared helpers for this image.
#
# Sourced by:
#   - pgtext-entrypoint.sh      (container entrypoint, runs as root, every boot)
#   - zz-init-textsearch.sh     (initdb hook, runs as postgres, first boot only)
#
# Everything here must be idempotent and must never leave postgresql.conf in
# a state postgres cannot boot from.

PGTEXT_BLOCK_BEGIN="# >>> pg_textsearch managed block - regenerated on every boot, do not edit >>>"
PGTEXT_BLOCK_END="# <<< pg_textsearch managed block <<<"

# pg_textsearch's BM25 index needs shared memory, so it must be preloaded.
# pg_stat_statements is kept because the base image expects it.
PGTEXT_PRELOAD_LIBRARIES="pg_stat_statements,pg_textsearch"

# Extensions auto-created in the target database on first boot and ensured on
# every boot after.
PGTEXT_EXTENSIONS="vector,vectorscale,pg_textsearch"

pgtext_target_db() {
  echo "${POSTGRES_DB:-${POSTGRES_USER:-postgres}}"
}

# Rewrite the managed block at the END of postgresql.conf. Position matters:
# the last occurrence of a setting wins, and the base image's init-ssl.sh
# appends its own shared_preload_libraries line during initdb — ours must
# come after it. postgresql.auto.conf (ALTER SYSTEM) still overrides us,
# which is the desired escape hatch for operators.
pgtext_write_managed_conf() {
  local conf="$1"
  [ -f "$conf" ] || return 0
  local tmp="${conf}.pgtext.tmp"

  awk -v b="$PGTEXT_BLOCK_BEGIN" -v e="$PGTEXT_BLOCK_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    skip != 1 {print}
  ' "$conf" > "$tmp"

  {
    echo "$PGTEXT_BLOCK_BEGIN"
    echo "shared_preload_libraries = '${PGTEXT_PRELOAD_LIBRARIES}'"
    echo "$PGTEXT_BLOCK_END"
  } >> "$tmp"

  # write-in-place (not mv) to preserve the file's owner and mode
  cat "$tmp" > "$conf"
  rm -f "$tmp"
  echo "pgtext: refreshed managed config (preload: ${PGTEXT_PRELOAD_LIBRARIES})"
}

# Create the default extensions in the target database and bring any
# already-installed extension's SQL up to the version this image ships.
# pgvectorscale's shared library is version-named (vectorscale-X.Y.Z.so), so
# the ALTER EXTENSION UPDATE pass is what makes image upgrades safe for
# existing databases. Assumes it runs as a user that can connect over the
# local socket as POSTGRES_USER (initdb hook: postgres OS user; entrypoint:
# via gosu).
pgtext_create_extensions() {
  local db user ext rc=0
  db=$(pgtext_target_db)
  user="${POSTGRES_USER:-postgres}"
  local psql=(psql -X -v ON_ERROR_STOP=1 --no-password -h /var/run/postgresql -p 5432 -U "$user" -d "$db")

  local IFS=','
  for ext in $PGTEXT_EXTENSIONS; do
    if "${psql[@]}" -qc "CREATE EXTENSION IF NOT EXISTS \"${ext}\" CASCADE;" >/dev/null 2>&1; then
      echo "pgtext: extension ready: ${ext}"
    else
      echo "pgtext: WARNING could not create extension: ${ext}" >&2
      rc=1
    fi
  done

  # The original (pre-rebuild) image shipped pg_textsearch as an unversioned
  # dev build ('0.1.1-dev') with no ALTER EXTENSION upgrade path to released
  # versions. Recreate it when nothing depends on it; if the user created
  # BM25 indexes against the dev build, dropping is not ours to decide —
  # log what they need to run instead (dev-build indexes are not compatible
  # with the released library anyway).
  "${psql[@]}" -qc "DO \$\$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension
                  WHERE extname = 'pg_textsearch' AND extversion LIKE '%dev%') THEN
        BEGIN
          DROP EXTENSION pg_textsearch;
          CREATE EXTENSION pg_textsearch;
          RAISE NOTICE 'pgtext: recreated pg_textsearch (dev build -> %)',
            (SELECT default_version FROM pg_available_extensions WHERE name = 'pg_textsearch');
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'pgtext: pg_textsearch is a dev build with no upgrade path and could not be recreated automatically (%). Drop its bm25 indexes, then run: DROP EXTENSION pg_textsearch; CREATE EXTENSION pg_textsearch; and recreate the indexes.', SQLERRM;
        END;
      END IF;
    END\$\$;" >/dev/null || rc=1

  "${psql[@]}" -qc "DO \$\$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT name, installed_version, default_version
                 FROM pg_available_extensions
                WHERE installed_version IS NOT NULL
                  AND default_version <> installed_version
      LOOP
        BEGIN
          EXECUTE format('ALTER EXTENSION %I UPDATE', r.name);
          RAISE NOTICE 'pgtext: updated extension % (% -> %)',
            r.name, r.installed_version, r.default_version;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'pgtext: could not update extension % (% -> %): %',
            r.name, r.installed_version, r.default_version, SQLERRM;
        END;
      END LOOP;
    END\$\$;" >/dev/null || rc=1

  return $rc
}

# Fork a background job that waits for the real postmaster (only it binds
# TCP — the initdb-time temporary server is socket-only) and then ensures
# extensions exist and are up to date. This is what delivers extension
# updates to existing volumes after an image upgrade. Disable with
# POSTGRES_ENSURE_EXTENSIONS=off.
pgtext_fork_ensure_extensions() {
  [ "${POSTGRES_ENSURE_EXTENSIONS:-on}" = "off" ] && return 0
  (
    deadline=$(( $(date +%s) + 900 ))
    until pg_isready -q -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" 2>/dev/null; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "pgtext: timed out waiting for postgres; skipping extension ensure" >&2
        exit 1
      fi
      sleep 3
    done
    for attempt in 1 2 3; do
      if gosu postgres bash -c 'source /usr/local/bin/pgtext-lib.sh && pgtext_create_extensions'; then
        exit 0
      fi
      echo "pgtext: extension ensure attempt ${attempt} had errors, retrying in 10s..." >&2
      sleep 10
    done
    echo "pgtext: WARNING extension ensure finished with errors" >&2
  ) &
}
