FROM alpine:3.21

# ponytail: gost v2.12.0 is pinned but unmaintained upstream (last release
# Oct 2024) while sitting on a trust boundary. Localhost-only publishing in
# docker-compose.yml is what contains this. Upgrade path is
# `--build-arg GOST_VERSION=3.3.0`, which switches to the maintained v3 line
# at the cost of a 64.6MB image instead of 29.2MB.
ARG GOST_VERSION=2.12.0
ARG TARGETARCH

RUN apk add --no-cache openvpn curl \
 && curl -fsSL "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/bin gost \
 && chmod +x /usr/bin/gost

WORKDIR /app
COPY generate-config.sh entrypoint.sh healthcheck.sh /app/
RUN chmod +x /app/generate-config.sh /app/entrypoint.sh /app/healthcheck.sh

ENV COUNTRY="" \
    MAX_SERVERS=32 \
    BLOCKED_EXIT_IPS="" \
    CLAIM_DIR=/var/lib/vpn-gate/claims \
    CLAIM_TTL=300 \
    TOMBSTONE_TTL=900 \
    CHECK_INTERVAL=30 \
    CHECK_URL=https://api.ipify.org \
    PROXY_PORT=1080

EXPOSE 1080

# start-period is generous: a first connect was measured at ~20s including a
# rejected attempt.
HEALTHCHECK --interval=30s --timeout=15s --start-period=90s --retries=3 \
  CMD /app/healthcheck.sh

ENTRYPOINT ["/app/entrypoint.sh"]
