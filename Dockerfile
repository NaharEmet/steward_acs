# ============================================================
# Stage 1: Build
# ============================================================
FROM hexpm/elixir:1.17.3-erlang-27.2.1-alpine-3.21 AS build

# Install build dependencies
RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Cache deps layer
COPY mix.exs mix.lock ./
COPY config/ ./config/
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy source
COPY lib/ ./lib/
COPY priv/ ./priv/
COPY assets/ ./assets/

# Compile
ENV MIX_ENV=prod
RUN mix compile

# Build assets
RUN mix assets.deploy

# Build release
RUN mix release

# ============================================================
# Stage 2: Runtime
# ============================================================
FROM alpine:3.21 AS app

RUN apk add --no-cache libstdc++ ncurses-libs openssl bash ca-certificates

WORKDIR /app

# Copy release from build stage
COPY --from=build /app/_build/prod/rel/steward_acs ./

EXPOSE 4000
EXPOSE 4001

ENV MIX_ENV=prod

# Default to SQLite (PostgreSQL requires PG* env vars)
ENV DATABASE_PATH=/app/data/acs.sqlite
ENV ACS_CLUSTER_NAME=default
ENV AUDITOR_INTERVAL=30000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:4000/health || exit 1

# Create data directory
RUN mkdir -p /app/data

CMD ["bin/steward_acs", "start"]
