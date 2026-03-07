# Build and run the Kora web app (Phoenix). For production use DATABASE_PATH and SECRET_KEY_BASE.
FROM elixir:1.15.7-erlang-26.2.2-debian-bookworm-20240312-slim

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency manifests
COPY mix.exs mix.lock ./

# Fetch prod dependencies (no --only prod to get all for compile; we run in prod)
RUN mix deps.get

# Copy config and source
COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

# Compile and build assets
RUN mix compile
RUN mix assets.deploy

# Create data dir for SQLite (overridable via volume)
RUN mkdir -p /app/data

# Defaults; override with -e or env_file. SECRET_KEY_BASE must be set for prod.
ENV MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    DATABASE_PATH=/app/data/kora.db

# Create DB if missing, migrate, then start the server
CMD mix ecto.create 2>/dev/null || true && \
    mix ecto.migrate && \
    exec mix phx.server
