#!/bin/bash
# First-boot hook, run by docker-entrypoint.sh during initdb (as the postgres
# OS user, against the socket-only temporary server).
#
# The "zz-" prefix makes this run after the base image's init-ssl.sh, which
# appends its own shared_preload_libraries line — our managed block must land
# after it in postgresql.conf so our superset list wins.
set -e

source /usr/local/bin/pgtext-lib.sh

pgtext_write_managed_conf "$PGDATA/postgresql.conf"

# pg_textsearch can't CREATE EXTENSION until it's preloaded; restart the
# temporary server to pick up shared_preload_libraries. pg_ctl reuses
# postmaster.opts, so the socket-only listen config is preserved.
echo "pgtext: restarting temporary server to load preload libraries"
pg_ctl -D "$PGDATA" -m fast -w restart

# Extension creation failures are logged but don't abort initdb — the
# ensure-extensions job retries on this and every subsequent boot.
pgtext_create_extensions \
  || echo "pgtext: WARNING some extensions failed during initdb; will retry after startup" >&2
