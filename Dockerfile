# syntax=docker/dockerfile:1

# --- Dev image (local docker-compose.yml) ---
FROM elixir:1.17-alpine AS dev

RUN apk add --no-cache build-base git curl sqlite-dev

WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

RUN mix compile

ENV MIX_ENV=dev
EXPOSE 4001

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f "http://localhost:${PORT:-4001}/mcp/health" || exit 1

CMD ["sh", "-c", "mix ecto.migrate && mix phx.server"]

# --- Release build ---
FROM elixir:1.17-alpine AS build

RUN apk add --no-cache build-base git sqlite-dev

WORKDIR /app

ENV MIX_ENV=prod

ARG REPO_ADAPTER=postgres
ENV REPO_ADAPTER=${REPO_ADAPTER}

ARG SECRET_KEY_BASE=build_time_secret_key_base_not_used_at_runtime
ENV SECRET_KEY_BASE=${SECRET_KEY_BASE}

ARG COOKIE_SIGNING_SALT
ENV COOKIE_SIGNING_SALT=${COOKIE_SIGNING_SALT}

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

RUN if [ -z "$COOKIE_SIGNING_SALT" ]; then \
      export COOKIE_SIGNING_SALT=$(printf '%s' "$SECRET_KEY_BASE" | sha256sum | awk '{print $1}' | cut -c1-16); \
    fi && \
    mix compile && \
    mix assets.deploy && \
    mix release

# --- Production runtime ---
FROM alpine:3.19 AS release

RUN apk add --no-cache libstdc++ openssl ncurses-libs curl sqlite-libs bash libgcc

RUN addgroup -S acs && adduser -S acs -G acs

WORKDIR /app

COPY --from=build /app/_build/shared/rel/steward_acs ./
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && chown -R acs:acs /app

USER acs

ENV HOME=/app \
    MIX_ENV=prod \
    PORT=4001

EXPOSE 4001

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f "http://localhost:${PORT}/mcp/health" || exit 1

ENTRYPOINT ["/entrypoint.sh"]
