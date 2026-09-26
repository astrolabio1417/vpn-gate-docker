#!/bin/sh
# End-to-end: builds the image, runs it, asserts the proxy exits through the VPN.
set -u
cd "$(dirname "$0")"

NAME=vpn-gate-e2e
PORT=11080
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }

echo "== offline generator tests =="
./test/test-generate-config.sh || fail "generator tests failed"

echo "== building =="
docker build -q -t vpn-gate-docker . >/dev/null || fail "build failed"

size=$(docker images vpn-gate-docker --format '{{.Size}}')
echo "image size: $size"

echo "== starting container =="
cleanup
docker run -d --name "$NAME" --cap-add NET_ADMIN --device /dev/net/tun \
    --dns 1.1.1.1 -e COUNTRY=JP -p "127.0.0.1:$PORT:1080" vpn-gate-docker >/dev/null \
    || fail "container did not start"

echo "== waiting for tunnel (up to 150s) =="
i=0
while [ "$i" -lt 150 ]; do
    docker logs "$NAME" 2>&1 | grep -q 'proxy listening' && break
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ] || break
    i=$((i+5)); sleep 5
done
docker logs "$NAME" 2>&1 | grep -q 'proxy listening' || {
    docker logs "$NAME" 2>&1 | tail -20; fail "tunnel never came up"; }

direct=$(curl -s --max-time 15 https://api.ipify.org)
proxied=$(curl -s --max-time 25 --socks5-hostname "127.0.0.1:$PORT" https://api.ipify.org)
echo "direct : $direct"
echo "proxied: $proxied"

[ -n "$direct" ] || fail "no response without the proxy -- no baseline to compare against"
[ -n "$proxied" ] || fail "no response through the proxy"
[ "$direct" != "$proxied" ] || fail "proxied IP equals direct IP -- traffic is not using the tunnel"

# ipinfo.io returns 403 to VPN Gate exit IPs, so it cannot be used here.
# api.country.is answers from those ranges and returns {"ip":...,"country":"JP"}.
country=$(curl -s --max-time 25 --socks5-hostname "127.0.0.1:$PORT" https://api.country.is \
    | sed -n 's/.*"country":"\([A-Z][A-Z]\)".*/\1/p')
echo "exit country: $country"
[ "$country" = "JP" ] || fail "COUNTRY=JP requested but exited via '${country:-<no answer>}'"

echo "PASS: proxy exits through a Japanese VPN Gate server"

echo "== claim check =="
claimed_from_log=$(docker logs "$NAME" 2>&1 | grep -m1 '^\[entrypoint\] claimed ' | awk '{print $3}')
# A live claim is a directory holding an owner token, not merely any entry
# that is not a tombstone: `<ip>.steal.<bucket>` lock dirs and `.probe.*`
# leftovers also live here, and counting those would fail this assertion for
# reasons that have nothing to do with how many relays are claimed.
live_claims=$(docker exec "$NAME" sh -c '
    for d in /var/lib/vpn-gate/claims/*; do
        case "$d" in *.dead) continue ;; esac
        [ -f "$d/owner" ] && basename "$d"
    done' 2>/dev/null || true)
live_count=$(printf '%s\n' "$live_claims" | grep -c .)
echo "claimed (log): $claimed_from_log"
echo "live claim(s) on disk: $live_claims"
[ "$live_count" -eq 1 ] || fail "expected exactly one live claim, found $live_count"
[ "$live_claims" = "$claimed_from_log" ] || \
    fail "live claim '$live_claims' does not match the logged claim '$claimed_from_log'"

echo "PASS: exactly one live claim ($claimed_from_log), and it matches the log"
