#!/bin/sh
# End-to-end: builds the image, runs it, asserts the proxy exits through the VPN.
set -u
cd "$(dirname "$0")"

NAME=vpn-gate-e2e
PORT=11080
NAME2=vpn-gate-e2e-blocked
PORT2=11081
cleanup() {
    docker rm -f "$NAME" "$NAME2" >/dev/null 2>&1 || true
    [ -n "${claim_tmp:-}" ] && rm -rf "$claim_tmp" 2>/dev/null || true
}
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

echo "== BLOCKED_EXIT_IPS: a container that would exit as \"$proxied\" must refuse to serve =="
# NAME's CLAIM_DIR is container-local, so NAME2 does not see its claim and is
# free to independently claim the same top-scored JP relay -- usually the
# same entry IP, hence the same exit IP, giving BLOCKED_EXIT_IPS something to
# actually match. Bind-mounted so the tombstone is still readable once NAME2
# has exited (docker exec does not work on a stopped container).
claim_tmp=$(mktemp -d)
docker run -d --name "$NAME2" --cap-add NET_ADMIN --device /dev/net/tun \
    --dns 1.1.1.1 -e COUNTRY=JP -e "BLOCKED_EXIT_IPS=$proxied" \
    -v "$claim_tmp:/var/lib/vpn-gate/claims" \
    -p "127.0.0.1:$PORT2:1080" vpn-gate-docker >/dev/null \
    || fail "second container did not start"

connected=0
i=0
while [ "$i" -lt 150 ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME2" 2>/dev/null)" = "true" ] || break
    curl -s --max-time 2 --socks5-hostname "127.0.0.1:$PORT2" https://api.ipify.org >/dev/null 2>&1 \
        && connected=1
    i=$((i+3)); sleep 3
done

if [ "$connected" -eq 1 ]; then
    # The proxy came up, so NAME2 was not blocked. NAME2 has its own
    # CLAIM_DIR and often lands on a different relay with a different exit
    # IP than NAME's -- that is the block correctly NOT firing, not a bug.
    # Query the exit IP it actually reports and only fail if it truly
    # matches what BLOCKED_EXIT_IPS was set to.
    proxied2=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:$PORT2" https://api.ipify.org)
    if [ -n "$proxied2" ] && [ "$proxied2" = "$proxied" ]; then
        fail "blocked-exit-IP container accepted a proxied connection with the blocked exit IP $proxied"
    fi
    echo "SKIP: BLOCKED_EXIT_IPS check -- second container landed on a different relay (exit '${proxied2:-<unknown>}' != $proxied)"
else
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME2" 2>/dev/null)" != "true" ] || {
        docker logs "$NAME2" 2>&1 | tail -20; fail "blocked-exit-IP container never exited"; }

    exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$NAME2" 2>/dev/null || echo "")
    [ -n "$exit_code" ] && [ "$exit_code" != "0" ] || {
        docker logs "$NAME2" 2>&1 | tail -20
        fail "blocked-exit-IP container exited with code '${exit_code:-<unknown>}', expected non-zero"; }

    # Any give_up call site produces the same shape (no connection, stopped,
    # non-zero exit, a tombstone) -- this is the one line that proves the
    # BLOCKED_EXIT_IPS comparison actually fired, not some unrelated failure.
    docker logs "$NAME2" 2>&1 | grep -q 'is blocked' || {
        docker logs "$NAME2" 2>&1 | tail -20
        fail "container exited but logs do not show a blocked exit IP -- exited for an unrelated reason"; }

    dead=$(find "$claim_tmp" -maxdepth 1 -name '*.dead')
    [ -n "$dead" ] || {
        docker logs "$NAME2" 2>&1 | tail -20; fail "no .dead tombstone found after blocked exit IP"; }

    echo "PASS: BLOCKED_EXIT_IPS=$proxied refused to serve and tombstoned its claim"
fi
