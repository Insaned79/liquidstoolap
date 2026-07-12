# syntax=docker/dockerfile:1

FROM debian:bookworm-slim AS release

ARG LIQUID_STOOLAP_VERSION=latest
ARG LIQUID_STOOLAP_ARCH=linux-x86_64
WORKDIR /release
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    if [ "$LIQUID_STOOLAP_VERSION" = "latest" ]; then \
      curl --retry 3 --connect-timeout 20 -fsSL \
        -o /tmp/liquidstoolap-latest.json \
        https://api.github.com/repos/Insaned79/liquidstoolap/releases/latest; \
      tag="$(grep -m 1 '"tag_name"' /tmp/liquidstoolap-latest.json \
        | cut -d '"' -f 4 \
        | sed 's/^v//')"; \
    else \
      tag="${LIQUID_STOOLAP_VERSION#v}"; \
    fi; \
    test -n "$tag"; \
    curl --retry 3 --connect-timeout 20 -fL \
      -o /tmp/liquidstoolap.tar.gz \
      "https://github.com/Insaned79/liquidstoolap/releases/download/v${tag}/liquidstoolap-server-${tag}-${LIQUID_STOOLAP_ARCH}.tar.gz"; \
    tar -xzf /tmp/liquidstoolap.tar.gz --strip-components=1

FROM debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.title="Liquid Stoolap"
LABEL org.opencontainers.image.description="Free Pascal REST server for the embedded Stoolap database"
LABEL org.opencontainers.image.source="https://github.com/Insaned79/liquidstoolap"
LABEL org.opencontainers.image.licenses="MIT"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=release /release/liquidstoolap /usr/local/bin/liquidstoolap
COPY --from=release /release/libstoolap.so /opt/liquidstoolap/libstoolap.so
COPY docker/config.docker.ini /opt/liquidstoolap/config.example.ini

WORKDIR /data
VOLUME ["/data"]
EXPOSE 8321

CMD ["liquidstoolap", "serve", "--config", "/data/config.ini"]
