# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#   - https://hub.docker.com/_/debian/tags - for the runner image
#
# Find builder and runner images on Docker Hub or https://bob.hex.pm/docker

ARG ELIXIR_VERSION=1.20.3
ARG OTP_VERSION=28.1.1
ARG DEBIAN_VERSION=trixie-20260803-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib
COPY sidecar sidecar

RUN mix compile

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates python3 \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

# Persistent SQLite / data directory (mount a volume or Render disk here).
RUN mkdir -p /data \
  && chown nobody:nogroup /data \
  && chown nobody:nogroup /app

ENV MIX_ENV="prod"
ENV DATABASE_PATH="/data/isthmus.db"
ENV PORT="4000"
ENV ISTHMUS_RNS_SIDECAR="/app/sidecar/rns_sidecar.py"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/isthmus ./
COPY --from=builder --chown=nobody:root /app/sidecar ./sidecar

USER nobody

EXPOSE 4000

# Healthcheck for Docker / compose (Render uses HTTP health checks separately).
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD ["sh", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT:-4000} && printf 'GET /healthz HTTP/1.0\\r\\n\\r\\n' >&3 && cat <&3 | grep -q ok"]

CMD ["/app/bin/server"]
