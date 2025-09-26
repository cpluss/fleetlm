# syntax=docker/dockerfile:1

########################################
# Build image                                                               #
########################################
ARG ELIXIR_VERSION=1.15.7
ARG DEBIAN_VERSION=bookworm-slim

FROM elixir:${ELIXIR_VERSION}-slim AS build

ENV LANG=C.UTF-8 \
    MIX_ENV=prod

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      curl \
      git \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix deps.get --only ${MIX_ENV} && \
    mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Compile application to ensure colocated hooks are generated before bundling assets
RUN mix compile
RUN mix assets.deploy
RUN mix release

########################################
# Runtime image                                                             #
########################################
FROM debian:${DEBIAN_VERSION} AS app

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    SHELL=/bin/bash \
    PHX_SERVER=true

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN groupadd --gid 1000 app && \
    useradd --uid 1000 --gid app --home /app --shell /bin/bash app

COPY --from=build /app/_build/prod/rel/fleetlm ./fleetlm
COPY docker-entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh && \
    chown -R app:app /app

USER app

EXPOSE 4000

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["start"]
