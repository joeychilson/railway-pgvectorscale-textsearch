# syntax=docker/dockerfile:1.7

# PostgreSQL 18 with pgvector, pgvectorscale, and pg_textsearch (BM25),
# built for Railway.
#
# Base: Railway's official postgres-ssl image (self-signed SSL, pgBackRest
# WAL archiving / PITR, volume-mount guards, stale-pid cleanup).
#
# Version pins — bump these to upgrade:
ARG PG_MAJOR=18
ARG BASE_IMAGE=ghcr.io/railwayapp-templates/postgres-ssl:18
ARG PGVECTORSCALE_VERSION=0.9.1
ARG PG_TEXTSEARCH_VERSION=1.4.0

# -----------------------------------------------------------------------------
# Builder: compile pg_textsearch (C, PGXS) against the same postgres the base
# image is built from, and fetch pgvectorscale's prebuilt release .deb.
# -----------------------------------------------------------------------------
FROM postgres:${PG_MAJOR} AS builder
ARG PG_MAJOR
ARG PGVECTORSCALE_VERSION
ARG PG_TEXTSEARCH_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      postgresql-server-dev-${PG_MAJOR} \
      curl \
      ca-certificates \
      unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN curl -fsSL "https://github.com/timescale/pg_textsearch/archive/refs/tags/v${PG_TEXTSEARCH_VERSION}.tar.gz" | tar xz \
    && make -C "pg_textsearch-${PG_TEXTSEARCH_VERSION}" -j"$(nproc)" \
    && make -C "pg_textsearch-${PG_TEXTSEARCH_VERSION}" install DESTDIR=/out

RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL -o /tmp/vectorscale.zip \
       "https://github.com/timescale/pgvectorscale/releases/download/${PGVECTORSCALE_VERSION}/pgvectorscale-${PGVECTORSCALE_VERSION}-pg${PG_MAJOR}-${arch}.zip" \
    && mkdir -p /debs \
    && unzip /tmp/vectorscale.zip -d /debs \
    && ls /debs/*.deb

# -----------------------------------------------------------------------------
# Final image
# -----------------------------------------------------------------------------
FROM ${BASE_IMAGE}
ARG PG_MAJOR

COPY --from=builder /out/ /
COPY --from=builder /debs/ /tmp/debs/

# pgvector from PGDG (already configured in the official postgres base image),
# pgvectorscale from the fetched release .deb.
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-${PG_MAJOR}-pgvector \
      /tmp/debs/*.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/debs

# Build-time sanity check: every advertised extension must be installable.
RUN set -eux; \
    for ext in vector vectorscale pg_textsearch; do \
      test -f "/usr/share/postgresql/${PG_MAJOR}/extension/${ext}.control"; \
    done; \
    test -f "/usr/lib/postgresql/${PG_MAJOR}/lib/pg_textsearch.so"; \
    ls "/usr/lib/postgresql/${PG_MAJOR}/lib/" | grep -q vectorscale

COPY --chmod=755 pgtext-lib.sh /usr/local/bin/pgtext-lib.sh
COPY --chmod=755 entrypoint.sh /usr/local/bin/pgtext-entrypoint.sh
# "zz-" prefix: docker-entrypoint runs initdb.d scripts in sorted order and the
# base image's init-ssl.sh appends its own shared_preload_libraries line to
# postgresql.conf — ours must run after it so our (superset) list wins.
COPY --chmod=755 zz-init-textsearch.sh /docker-entrypoint-initdb.d/zz-init-textsearch.sh

ENTRYPOINT ["pgtext-entrypoint.sh"]
# Redeclared because setting ENTRYPOINT resets any inherited CMD. Port is
# pinned to 5432 (Railway's TCP proxy expects it), matching the base image.
CMD ["postgres", "-p", "5432", "-c", "listen_addresses=*"]
