#!/bin/bash
# Entrypoint: keeps shared_preload_libraries correct on every boot, forks the
# extension ensure/update task, then hands off to the postgres-ssl base
# image's wrapper (SSL certs, pgBackRest, volume guards). Deliberately no
# `set -e` — a failure in our extras must never stop postgres from booting
# with whatever configuration is already on disk.

source /usr/local/bin/pgtext-lib.sh

# The base wrapper (re)generates SSL certificates when they're missing,
# expiring, or not x509v3 — and init-ssl.sh appends its own config lines
# (including a shared_preload_libraries line) to postgresql.conf when it
# runs. Our managed block must stay LAST so its preload list wins, so mirror
# the wrapper's conditions and run the cert script BEFORE writing the block;
# the wrapper then finds valid certs and appends nothing. This matters for
# volumes migrated from a non-SSL image and for cert-renewal boots.
SSL_CERT="/var/lib/postgresql/data/certs/server.crt"
INIT_SSL_SCRIPT="/docker-entrypoint-initdb.d/init-ssl.sh"
if [ -n "${PGDATA:-}" ] && [ -f "$PGDATA/postgresql.conf" ]; then
  if [ ! -f "$SSL_CERT" ] \
     || ! openssl x509 -noout -text -in "$SSL_CERT" 2>/dev/null | grep -q "DNS:localhost" \
     || ! openssl x509 -checkend 2592000 -noout -in "$SSL_CERT" 2>/dev/null; then
    echo "pgtext: running SSL cert setup ahead of managed config write"
    bash "$INIT_SSL_SCRIPT" || echo "pgtext: WARNING cert setup failed; base wrapper will retry" >&2
  fi
fi

# Refresh the managed config on already-initialized volumes (first boot is
# handled by zz-init-textsearch.sh during initdb, when postgresql.conf
# doesn't exist yet at this point).
if [ -n "${PGDATA:-}" ] && [ -f "$PGDATA/PG_VERSION" ] && [ -f "$PGDATA/postgresql.conf" ]; then
  pgtext_write_managed_conf "$PGDATA/postgresql.conf" \
    || echo "pgtext: WARNING failed to refresh managed config" >&2
fi

pgtext_fork_ensure_extensions

exec /usr/local/bin/wrapper.sh "$@"
