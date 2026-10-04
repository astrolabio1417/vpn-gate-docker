#!/bin/sh
# PID 1: builds the config, runs openvpn + gost, exits on any tunnel failure
# so the container's restart policy fetches a fresh list and a fresh claim.
set -eu

CONF=/etc/openvpn/vpngate.ovpn
OVPN_LOG=/tmp/openvpn.log
API=https://www.vpngate.net/api/iphone/
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
CHECK_URL="${CHECK_URL:-https://api.ipify.org}"
BLOCKED_EXIT_IPS="${BLOCKED_EXIT_IPS:-}"
PROXY_PORT="${PROXY_PORT:-1080}"
PROXY_DNS="${PROXY_DNS:-1.1.1.1:53/tcp,8.8.8.8:53/tcp}"
PROXY_DNS_TTL="${PROXY_DNS_TTL:--1s}"
CLAIM_DIR="${CLAIM_DIR:-/var/lib/vpn-gate/claims}"

ovpn_pid=""
gost_pid=""
CLAIMED_IP=""
OWNER_TOKEN=""

log() { echo "[entrypoint] $*"; }

# Validated early (moved up from the watchdog loop) because the CLAIM_TTL
# warning right below needs a clean number to compare against.
case "$CHECK_INTERVAL" in
    ''|*[!0-9]*) log "CHECK_INTERVAL='$CHECK_INTERVAL' is not a number; using 30"; CHECK_INTERVAL=30 ;;
esac

# CLAIM_TTL is fully validated in generate-config.sh; here it only feeds a
# startup warning, so a garbage value just skips the warning rather than
# failing the container a second time for the same reason.
case "${CLAIM_TTL:-300}" in
    ''|*[!0-9]*) claim_ttl_for_check="" ;;
    *) claim_ttl_for_check="${CLAIM_TTL:-300}" ;;
esac

# The real max gap between heartbeats is CHECK_INTERVAL once steady-state
# (wait_for_tunnel heartbeats every second on its own, so the slow initial
# connect is not part of this), plus however long the watchdog's own health
# checks can run before the NEXT heartbeat: the DNS check uses --max-time 15
# once, the proxy check --max-time 10 every tick, so 15 covers both.
if [ -n "$claim_ttl_for_check" ] && [ $((CHECK_INTERVAL + 15)) -ge "$claim_ttl_for_check" ]; then
    log "WARNING: CHECK_INTERVAL+15 ($((CHECK_INTERVAL + 15))) >= CLAIM_TTL ($claim_ttl_for_check)"
    log "WARNING: a live container could be judged stale and a sibling could steal its claim"
fi

# Not a hard error: a single container's own CLAIM_DIR is never a mount
# point either, and that must keep working. This is the one signal a
# forgotten `dokku storage:mount` still gets, since it cannot be a failure.
# Checked here, once per container start, rather than in generate-config.sh,
# which every offline test also invokes directly.
if ! awk -v d="$CLAIM_DIR" '$5==d { f=1 } END { exit !f }' /proc/self/mountinfo 2>/dev/null; then
    log "NOTE CLAIM_DIR='$CLAIM_DIR' is not a mount point -- this container's claims are private unless a shared volume (e.g. dokku storage:mount) is bound there"
fi

# True only if we are still the confirmed owner of CLAIMED_IP: the on-disk
# token must match the one we wrote at claim time. A mismatch means a
# sibling stole this claim after judging it stale -- log it and touch
# nothing further, since the directory now belongs to a different process.
owns_claim() {
    [ -n "$CLAIMED_IP" ] && [ -n "$OWNER_TOKEN" ] || return 1
    current=$(cat "$CLAIM_DIR/$CLAIMED_IP/owner" 2>/dev/null) || return 1
    [ "$current" = "$OWNER_TOKEN" ]
}

release_claim() {
    [ -n "$CLAIMED_IP" ] || return 0
    if owns_claim; then
        rm -rf "$CLAIM_DIR/$CLAIMED_IP" 2>/dev/null || true
    else
        log "claim on $CLAIMED_IP was stolen; not releasing another container's claim"
    fi
}

# Automatic and time-boxed, unlike BLOCKED_IPS: this says "this relay just
# failed", not "never use this relay again". See README.
tombstone_claim() {
    [ -n "$CLAIMED_IP" ] || return 0
    if owns_claim; then
        rm -rf "$CLAIM_DIR/$CLAIMED_IP.dead" 2>/dev/null || true
        # touch after the mv: rename(2) does NOT update the renamed inode's
        # mtime, and nothing else ever did either -- the claim dir's mtime
        # was fixed at claim time and the heartbeat only touches <ip>/beat
        # inside it. Without this, a container that ran longer than
        # TOMBSTONE_TTL produced a tombstone born already expired, and
        # re-claimed the relay that had just killed it on the first restart.
        mv "$CLAIM_DIR/$CLAIMED_IP" "$CLAIM_DIR/$CLAIMED_IP.dead" 2>/dev/null &&
            touch "$CLAIM_DIR/$CLAIMED_IP.dead" 2>/dev/null || true
    else
        log "claim on $CLAIMED_IP was stolen; not tombstoning another container's claim"
    fi
}

# A down-but-retrying container still owns its relay -- called every second
# while waiting for the tunnel, then once per watchdog tick thereafter, in
# both cases before any health check. Writes <ip>/beat, never <ip> itself:
# touch creates no missing parent, so if the claim is gone this just fails
# quietly instead of resurrecting a plain file that would block `mkdir`
# from ever reclaiming that slot. Silently skipped (no log) on a stolen
# claim -- this runs every second, and release/tombstone already log the
# one time it actually matters.
heartbeat_claim() {
    owns_claim && touch "$CLAIM_DIR/$CLAIMED_IP/beat" 2>/dev/null || true
}

cleanup() {
    [ -n "$gost_pid" ] && kill "$gost_pid" 2>/dev/null || true
    [ -n "$ovpn_pid" ] && kill "$ovpn_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; release_claim; exit 130' INT
trap 'cleanup; release_claim; exit 143' TERM

if [ ! -c /dev/net/tun ]; then
    log "creating /dev/net/tun"
    mkdir -p /dev/net
    if ! mknod /dev/net/tun c 10 200; then
        log "ERROR: could not create /dev/net/tun."
        log "ERROR: run with --device /dev/net/tun --cap-add NET_ADMIN."
        exit 1
    fi
    chmod 600 /dev/net/tun
fi

mkdir -p /etc/openvpn
log "fetching server list"
if ! curl -fsS --max-time 60 "$API" -o /tmp/vpngate.csv; then
    log "ERROR: could not fetch the VPN Gate server list"
    exit 1
fi

log "generating config (COUNTRY='${COUNTRY:-any}' MAX_SERVERS=${MAX_SERVERS:-32} CLAIM_DIR='$CLAIM_DIR')"
if ! /app/generate-config.sh < /tmp/vpngate.csv > "$CONF"; then
    log "ERROR: could not claim a relay (see generate-config.sh output above)"
    exit 1
fi
CLAIMED_IP=$(grep -m1 '^# claimed ' "$CONF" | awk '{ print $3 }')
OWNER_TOKEN=$(grep -m1 '^# owner ' "$CONF" | awk '{ print $3 }')
log "claimed $CLAIMED_IP"

# All failure paths from here on funnel through give_up(): stop_proxy runs
# first because a listening gost leaks over eth0 the moment tun0 dies, then
# openvpn is killed, then the claim is tombstoned so the next container (or
# our own restart) does not immediately re-claim the same dead relay.
give_up() {
    stop_proxy
    if [ -n "$ovpn_pid" ]; then
        kill "$ovpn_pid" 2>/dev/null || true
        wait "$ovpn_pid" 2>/dev/null || true
    fi
    tombstone_claim
    log "$1"
    exit 1
}

start_openvpn() {
    : > "$OVPN_LOG"
    openvpn --config "$CONF" > "$OVPN_LOG" 2>&1 &
    ovpn_pid=$!
    log "openvpn started (pid $ovpn_pid)"
}

# 120s ceiling: a first connect measures ~20s, a rejected attempt costs
# another. Heartbeats every second here, not just once per watchdog tick,
# so a slow first connect can never widen the real gap between beats past
# CHECK_INTERVAL -- without this, the true max gap included this whole
# 120s ceiling, which the CLAIM_TTL warning below did not account for.
wait_for_tunnel() {
    i=0
    while [ "$i" -lt 120 ]; do
        heartbeat_claim
        grep -q 'Initialization Sequence Completed' "$OVPN_LOG" && return 0
        kill -0 "$ovpn_pid" 2>/dev/null || return 1
        i=$((i+1)); sleep 1
    done
    return 1
}

start_proxy() {
    gost -L ":$PROXY_PORT?dns=$PROXY_DNS&ttl=$PROXY_DNS_TTL" &
    gost_pid=$!
    log "proxy listening on :$PROXY_PORT (pid $gost_pid)"
}

stop_proxy() {
    [ -n "$gost_pid" ] || return 0
    kill "$gost_pid" 2>/dev/null || true
    wait "$gost_pid" 2>/dev/null || true
    gost_pid=""
    log "proxy stopped"
}

current_remote() {
    grep -oE 'Peer Connection Initiated with \[AF_INET\][0-9.]+' "$OVPN_LOG" \
        | tail -1 | sed 's/.*\]//'
}

record_check() {
    hist="$hist$1"
    [ "${#hist}" -le 5 ] || hist=${hist#?}
    fails=$(printf %s "$hist" | tr -d P)
    fails=${#fails}
}

start_openvpn
if ! wait_for_tunnel; then
    give_up "no server came up; exiting so a fresh list and a fresh claim are made"
fi
log "tunnel up via $(current_remote)"

# The default container resolver dies once `redirect-gateway def1` is pushed,
# so every proxied lookup fails while the tunnel still looks healthy.
if [ -z "$BLOCKED_EXIT_IPS" ]; then
    # Hot default path, unchanged: no BLOCKED_EXIT_IPS means nothing below
    # ever compares against exit_ip, so one flaky fetch costs nothing.
    if ! exit_ip=$(curl -fsS --max-time 15 "$CHECK_URL" 2>/dev/null); then
        log "WARNING: DNS/connectivity check failed through the tunnel."
        log "WARNING: run this container with --dns 1.1.1.1 (compose: dns: [1.1.1.1])."
    fi
else
    # BLOCKED_EXIT_IPS asks us to refuse specific exits; that promise is
    # only as good as the exit IP we can confirm, so this path fails
    # CLOSED instead of open: retry past one transient failure, and if the
    # exit IP still cannot be confirmed, refuse to serve rather than let an
    # unverified relay through.
    attempt=1
    exit_ip=""
    while [ "$attempt" -le 3 ]; do
        exit_ip=$(curl -fsS --max-time 15 "$CHECK_URL" 2>/dev/null) || exit_ip=""
        exit_ip=$(printf '%s' "$exit_ip" | tr -d ' \t\n\r')
        if [ -n "$exit_ip" ]; then
            break
        fi
        if [ "$attempt" -lt 3 ]; then
            sleep 2
        fi
        attempt=$((attempt+1))
    done
    if [ -z "$exit_ip" ]; then
        log "WARNING: DNS/connectivity check failed through the tunnel."
        log "WARNING: run this container with --dns 1.1.1.1 (compose: dns: [1.1.1.1])."
        give_up "could not determine exit IP after 3 attempts; refusing to serve with BLOCKED_EXIT_IPS set"
    fi
fi
# CHECK_URL is operator-configurable and may not return a bare IP; trim
# whitespace/newlines so a well-formed body still compares cleanly, and let
# anything else pass through silently -- it just will not match a blocklist.
exit_ip=$(printf '%s' "${exit_ip:-}" | tr -d ' \t\n\r')

if [ -n "$exit_ip" ] && [ -n "$BLOCKED_EXIT_IPS" ] && \
   printf '%s' "$BLOCKED_EXIT_IPS" | tr -d ' ' | tr ',' '\n' | sed '/^$/d' | grep -qxF "$exit_ip"; then
    give_up "exit IP $exit_ip (via entry $CLAIMED_IP) is blocked; tombstoned so the restart claims another relay"
fi

start_proxy

hist=""
while :; do
    # busybox ash defers a trap until a foreground child exits; backgrounding
    # lets `wait` return as soon as TERM/INT fires instead of after CHECK_INTERVAL.
    sleep "$CHECK_INTERVAL" & wait "$!" || true

    heartbeat_claim

    if ! kill -0 "$ovpn_pid" 2>/dev/null; then
        give_up "openvpn exited; exiting so a fresh list and a fresh claim are made"
    fi

    if [ ! -d /sys/class/net/tun0 ]; then
        # openvpn is still alive and may recover this on its own via its
        # own connect-retry; stop the proxy meanwhile so a dead tunnel
        # cannot leak client traffic out over eth0.
        log "tunnel gone; proxy offline"
        stop_proxy
        continue
    fi
    [ -n "$gost_pid" ] || start_proxy

    if curl -fsS --max-time 10 --socks5-hostname "127.0.0.1:$PROXY_PORT" \
            "$CHECK_URL" > /dev/null 2>&1; then
        record_check P
        continue
    fi
    record_check F
    log "proxy check failed ($fails/3 in last 5)"
    if [ "$fails" -ge 3 ]; then
        give_up "proxy checks failed 3 of the last 5; exiting so a fresh claim is made"
    fi
done
