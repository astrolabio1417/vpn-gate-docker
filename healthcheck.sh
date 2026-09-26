#!/bin/sh
# Reports health to Docker. Independent of the entrypoint's watchdog on
# purpose: this one only observes, the watchdog acts.
[ -d /sys/class/net/tun0 ] && pidof openvpn > /dev/null 2>&1 || exit 1

curl -fsS --max-time 10 \
    --socks5-hostname "127.0.0.1:${PROXY_PORT:-1080}" \
    "${CHECK_URL:-https://api.ipify.org}" > /dev/null 2>&1
