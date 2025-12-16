FROM postgres:18 AS builder

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    libssl-dev \
    pkg-config \
    jq \
    postgresql-server-dev-18 \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

RUN cd /tmp && \
    git clone --branch v0.8.1 https://github.com/pgvector/pgvector.git && \
    cd pgvector && \
    make && \
    make install

RUN cd /tmp && \
    git clone --branch 0.9.0 https://github.com/timescale/pgvectorscale.git && \
    cd pgvectorscale/pgvectorscale && \
    cargo install --locked cargo-pgrx --version $(cargo metadata --format-version 1 | jq -r '.packages[] | select(.name == "pgrx") | .version') && \
    cargo pgrx init --pg18 /usr/bin/pg_config && \
    cargo pgrx install --release

RUN cd /tmp && \
    git clone https://github.com/timescale/pg_textsearch.git && \
    cd pg_textsearch && \
    make && \
    make install

FROM postgres:18

COPY --from=builder /usr/share/postgresql/18/extension/vector--*.sql /usr/share/postgresql/18/extension/
COPY --from=builder /usr/share/postgresql/18/extension/vector.control /usr/share/postgresql/18/extension/
COPY --from=builder /usr/lib/postgresql/18/lib/vector.so /usr/lib/postgresql/18/lib/

COPY --from=builder /usr/share/postgresql/18/extension/vectorscale--*.sql /usr/share/postgresql/18/extension/
COPY --from=builder /usr/share/postgresql/18/extension/vectorscale.control /usr/share/postgresql/18/extension/
COPY --from=builder /usr/lib/postgresql/18/lib/vectorscale*.so /usr/lib/postgresql/18/lib/

COPY --from=builder /usr/share/postgresql/18/extension/pg_textsearch--*.sql /usr/share/postgresql/18/extension/
COPY --from=builder /usr/share/postgresql/18/extension/pg_textsearch.control /usr/share/postgresql/18/extension/
COPY --from=builder /usr/lib/postgresql/18/lib/pg_textsearch*.so /usr/lib/postgresql/18/lib/

COPY --chmod=644 init-extensions.sql /docker-entrypoint-initdb.d/

EXPOSE 5432
