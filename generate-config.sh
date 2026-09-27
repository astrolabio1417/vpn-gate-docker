#!/bin/sh
# VPN Gate CSV on stdin -> OpenVPN config on stdout.
# Emits exactly ONE remote: the highest-scoring relay this process can claim
# under CLAIM_DIR (see README). A second remote would let openvpn's own
# connect-retry dial a sibling container's already-claimed relay, so
# multi-container distinctness depends entirely on the claim made here, not
# on anything openvpn does with the file.
set -eu

COUNTRY="${COUNTRY:-}"
MAX_SERVERS="${MAX_SERVERS:-32}"
BLOCKED_IPS="${BLOCKED_IPS:-}"
CLAIM_DIR="${CLAIM_DIR:-/var/lib/vpn-gate/claims}"
CLAIM_TTL="${CLAIM_TTL:-300}"
TOMBSTONE_TTL="${TOMBSTONE_TTL:-900}"

case "$MAX_SERVERS" in
    ''|*[!0-9]*)
        echo "generate-config: MAX_SERVERS='$MAX_SERVERS' must be a non-negative integer" >&2
        exit 1
        ;;
esac

# A future mtime (backwards clock jump) must read as "ancient", not as
# "not yet stale" -- otherwise a clock jump on one host freezes every
# container out of every relay it once touched.
AGE_ANCIENT=999999999

case "$CLAIM_DIR" in
    /*) ;;
    *)
        echo "generate-config: CLAIM_DIR='$CLAIM_DIR' must be an absolute path" >&2
        exit 1
        ;;
esac

case "$CLAIM_TTL" in
    ''|*[!0-9]*)
        echo "generate-config: CLAIM_TTL='$CLAIM_TTL' must be a non-negative integer" >&2
        exit 1
        ;;
esac

case "$TOMBSTONE_TTL" in
    ''|*[!0-9]*)
        echo "generate-config: TOMBSTONE_TTL='$TOMBSTONE_TTL' must be a non-negative integer" >&2
        exit 1
        ;;
esac

# mkdir -p fails here (not just returns empty) when a path component exists
# and is not a directory -- that is a real misconfiguration, not "already
# claimed", so it must be a hard error like everything else in this block.
if ! mkdir -p "$CLAIM_DIR" 2>/dev/null; then
    echo "generate-config: could not create CLAIM_DIR='$CLAIM_DIR'" >&2
    exit 1
fi

# Probe writability with a real mkdir instead of relying on the claim loop:
# a `mkdir "$CLAIM_DIR/$ip"` failure there cannot tell "no permission" apart
# from "someone already holds it", and silently treating the former as the
# latter would degrade straight to every container sharing one relay.
# mktemp, not "$CLAIM_DIR/.probe.$$": sibling containers have separate PID
# namespaces and an identical startup path, so $$ is very likely the SAME
# number in all of them. The old rm-then-mkdir pair then raced -- one
# container's rm deleted another's probe and the loser exited claiming the
# directory was unwritable. Measured 399 false "not writable" exits in 400
# rounds with a fixed PID, i.e. exactly the `ps:scale`/reboot case.
if ! probe=$(mktemp -d "$CLAIM_DIR/.probe.XXXXXX" 2>/dev/null); then
    echo "generate-config: CLAIM_DIR='$CLAIM_DIR' is not writable" >&2
    exit 1
fi
rm -rf "$probe" 2>/dev/null || true

# The mount-point NOTE lives in entrypoint.sh, not here: it runs once per
# container start there, but every offline test invokes this script
# directly, which turned it into 20+ lines of noise per test run for zero
# extra signal.

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The API serves CRLF; base64 -d fails on a trailing \r.
tr -d '\r' > "$work/raw.csv"

# Data rows: 15 fields, excluding the "*" and "#" header lines.
awk -F, 'NF==15 && $1 !~ /^[*#]/' "$work/raw.csv" > "$work/rows.csv"

if [ ! -s "$work/rows.csv" ]; then
    echo "generate-config: API returned no parseable server rows" >&2
    exit 1
fi

if [ -n "$COUNTRY" ]; then
    printf '%s' "$COUNTRY" | tr -d ' ' | tr ',' '\n' | tr 'a-z' 'A-Z' | sed '/^$/d' > "$work/want"
    awk -F, 'NR==FNR { want[$1]; next } toupper($7) in want' \
        "$work/want" "$work/rows.csv" > "$work/kept.csv"
    mv "$work/kept.csv" "$work/rows.csv"

    if [ ! -s "$work/rows.csv" ]; then
        echo "generate-config: no servers matched COUNTRY='$COUNTRY'" >&2
        exit 1
    fi
fi

# Entry IPs (field 2, as the API lists them) an operator wants excluded
# across restarts. A token ending in "." blocks a subnet prefix instead of
# one address -- e.g. "219.100.37." for a whole NATed farm.
if [ -n "$BLOCKED_IPS" ]; then
    printf '%s' "$BLOCKED_IPS" | tr -d ' ' | tr ',' '\n' | sed '/^$/d' > "$work/blocked"

    # A BLOCKED_IPS value that normalises to nothing (",", " ", ",,") leaves
    # $work/blocked empty. NR==FNR then never goes false, so the awk below
    # would treat the whole server list as blocklist entries and print
    # nothing -- an empty blocklist must be a no-op, not a pool wipe.
    if [ -s "$work/blocked" ]; then
        awk -F, 'NR==FNR { bad[FNR]=$1; n=FNR; next }
                 { for (i=1; i<=n; i++)
                       if ($2 == bad[i] || (bad[i] ~ /\.$/ && index($2, bad[i]) == 1)) next
                   print }' \
            "$work/blocked" "$work/rows.csv" > "$work/kept.csv"
        mv "$work/kept.csv" "$work/rows.csv"

        if [ ! -s "$work/rows.csv" ]; then
            echo "generate-config: BLOCKED_IPS excluded every server" >&2
            exit 1
        fi
    fi
fi

# Column 3 is Score. MAX_SERVERS is how far down this list a container may
# walk looking for a claimable relay -- it MUST exceed the container count
# with margin, or siblings run out of candidates before they run out of
# rivals.
sort -t, -k3,3 -nr "$work/rows.csv" | head -n "$MAX_SERVERS" > "$work/top.csv"

# mtime of $1, in whole seconds. Falls back from GNU/busybox `stat -c %Y` to
# `date -r`; either missing mtime (the path vanished mid-check) or a future
# mtime (clock skew) reads as maximally old, never as "not yet stale".
age_of() {
    mtime=$(stat -c %Y "$1" 2>/dev/null) || mtime=$(date -r "$1" +%s 2>/dev/null) || mtime=""
    if [ -z "$mtime" ]; then
        echo "$AGE_ANCIENT"
        return
    fi
    now=$(date +%s)
    if [ "$mtime" -gt "$now" ]; then
        echo "$AGE_ANCIENT"
        return
    fi
    echo $((now - mtime))
}

# A live claim's age comes from its heartbeat; a claim nobody has beaten
# yet (or whose beat was itself stolen away) falls back to the directory's
# own mtime.
claim_age() {
    beat="$CLAIM_DIR/$1/beat"
    if [ -e "$beat" ]; then
        age_of "$beat"
    else
        age_of "$CLAIM_DIR/$1"
    fi
}

# A tombstone younger than TOMBSTONE_TTL blocks its IP outright. An expired
# one is cleared here so it does not have to be rechecked by every future run.
# Ages off <ip>.dead/beat when present, exactly like claim_age: entrypoint
# tombstones by renaming the claim dir, and rename(2) does not update the
# renamed inode's mtime, so the DIRECTORY's mtime is still claim time -- a
# container that ran longer than TOMBSTONE_TTL would otherwise emit a
# tombstone born already expired. entrypoint also touches the tombstone
# after the rename; this fallback keeps the reader correct on its own.
is_tombstoned() {
    tomb="$CLAIM_DIR/$1.dead"
    [ -e "$tomb" ] || return 1
    if [ -e "$tomb/beat" ]; then
        tombage=$(age_of "$tomb/beat")
    else
        tombage=$(age_of "$tomb")
    fi
    if [ "$tombage" -lt "$TOMBSTONE_TTL" ]; then
        return 0
    fi
    rm -rf "$tomb" 2>/dev/null || true
    return 1
}

# A random-ish token identifying THIS process as the owner of whatever
# claim it is about to write. entrypoint.sh compares this against the file
# on disk before releasing, tombstoning, or heartbeating a claim, so a
# container that has been stolen from can tell and does nothing further to
# a relay it no longer owns.
make_owner_token() {
    host=$(hostname 2>/dev/null) || host="unknown"
    rand=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || rand=""
    [ -n "$rand" ] || rand=$$
    printf '%s-%s-%s' "$host" "$$" "$rand"
}

# Writes the beat and owner files for a claim dir this process just
# created. `: > file` and a bare `> file` are POSIX special-builtin/grammar
# forms whose redirection failure kills the WHOLE shell under set -eu, even
# inside an if/|| guard -- confirmed on dash and busybox ash. `printf` is
# an ordinary utility, so the same failure (e.g. a rival deletes the dir a
# moment later) is just a normal, catchable nonzero exit status here.
finish_claim() {
    ip=$1
    printf '' > "$CLAIM_DIR/$ip/beat" 2>/dev/null || return 1
    printf '%s' "$(make_owner_token)" > "$CLAIM_DIR/$ip/owner" 2>/dev/null || return 1
    return 0
}

# mkdir is the only thing that ever decides ownership of "$CLAIM_DIR/$ip"
# itself; it is the only atomic op available, it fails if the slot is
# already held, and it alone is what a rival's identical claim_ip() races
# against. Everything below exists only to arbitrate WHO gets to delete a
# stale claim before recreating it -- deletion is not atomic, so two
# processes must never be allowed to run it concurrently on the same IP.
claim_ip() {
    ip=$1
    if mkdir "$CLAIM_DIR/$ip" 2>/dev/null; then
        if finish_claim "$ip"; then
            return 0
        fi
        rm -rf "$CLAIM_DIR/$ip" 2>/dev/null || true
        return 1
    fi

    if [ "$(claim_age "$ip")" -lt "$CLAIM_TTL" ]; then
        return 1
    fi

    # Stale. A previous design deleted the old claim with `mv` on the
    # theory that a loser's `mv` off a vanished source would fail -- false:
    # the winner recreates the same path microseconds later, so a loser's
    # `mv` can succeed against the WINNER's fresh claim and destroy it.
    # mkdir must stay the only thing that decides ownership; a lock is
    # needed solely to stop two processes from deleting the stale claim at
    # the same time. Bucket the lock by wall-clock time instead of ever
    # deleting the CURRENT bucket's lock: two stealers contending for the
    # same bucket still race on an atomic `mkdir`, and a stealer that dies
    # holding a lock is simply never revisited once the clock moves to the
    # next bucket -- the IP becomes stealable again within one CLAIM_TTL
    # window either way. Do NOT delete a lock in the bucket the clock is
    # currently in: that reintroduces the exact delete-then-recreate race
    # this design replaces.
    now=$(date +%s)
    if [ "$CLAIM_TTL" -gt 0 ]; then
        bucket=$((now / CLAIM_TTL))
    else
        bucket=$now
    fi

    # Opportunistic sweep, strictly-past buckets only: this cannot race,
    # because no process can still be minting a lock name derived from a
    # bucket the clock has already left. Left unswept, a crash-looping
    # container leaves one orphaned lock dir per candidate IP per
    # CLAIM_TTL window forever -- an unbounded inode leak in a directory
    # nobody watches. Do NOT extend this to the current bucket ($bucket
    # itself): a lock in THAT bucket may still be legitimately held by a
    # rival stealer this instant, and deleting it is the exact race the
    # bucketing scheme exists to prevent.
    for old in "$CLAIM_DIR/$ip".steal.*; do
        [ -d "$old" ] || continue
        oldbucket=${old##*.steal.}
        case "$oldbucket" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$oldbucket" -lt "$bucket" ]; then
            rm -rf "$old" 2>/dev/null || true
        fi
    done

    mkdir "$CLAIM_DIR/$ip.steal.$bucket" 2>/dev/null || return 1

    # Exclusive now. Re-verify staleness: the holder may have heartbeated
    # in the moments between our first check and winning this lock.
    if [ "$(claim_age "$ip")" -lt "$CLAIM_TTL" ]; then
        return 1
    fi

    rm -rf "$CLAIM_DIR/$ip" 2>/dev/null || true

    # A cold claimer with no idea a steal is in progress can still land
    # here first and recreate "$ip" between our rm -rf and this mkdir.
    # That is fine and must stay fine: our mkdir simply fails and we walk
    # to the next candidate exactly like any other lost race. mkdir
    # decides, always -- winning the steal lock only earns the RIGHT to
    # attempt the recreate, not the recreate itself.
    if mkdir "$CLAIM_DIR/$ip" 2>/dev/null; then
        if finish_claim "$ip"; then
            return 0
        fi
        rm -rf "$CLAIM_DIR/$ip" 2>/dev/null || true
    fi
    return 1
}

claimed_ip=""
remote_line=""
while IFS= read -r row; do
    ip=$(printf '%s' "$row" | cut -d, -f2)

    # CSV data must never name a path. A malformed IP field is skipped, not
    # sanitized -- there is no safe way to claim a path we cannot trust.
    if ! printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        continue
    fi

    is_tombstoned "$ip" && continue
    claim_ip "$ip" || continue

    printf '%s' "$row" | cut -d, -f15 | base64 -d 2>/dev/null | tr -d '\r' \
        > "$work/one.ovpn" 2>/dev/null || true

    hp=""
    pr=""
    if [ -s "$work/one.ovpn" ]; then
        # Protocols are mixed across servers; never assume tcp.
        hp=$(awk '/^remote /{ print $2" "$3; exit }' "$work/one.ovpn")
        pr=$(awk '/^proto /{ print tolower($2); exit }' "$work/one.ovpn")
    fi

    if [ -z "$hp" ] || [ -z "$pr" ]; then
        # Our decode failed, not the relay -- release rather than
        # tombstone, since a tombstone is a claim about relay health.
        rm -rf "$CLAIM_DIR/$ip" 2>/dev/null || true
        continue
    fi

    claimed_ip="$ip"
    owner_token=$(cat "$CLAIM_DIR/$ip/owner" 2>/dev/null) || owner_token=""
    remote_line="remote $hp $pr"
    cp "$work/one.ovpn" "$work/certs.ovpn"
    break
done < "$work/top.csv"

if [ -z "$claimed_ip" ]; then
    echo "generate-config: could not claim a relay -- every candidate in the top $MAX_SERVERS was tombstoned, held by another container, or undecodable" >&2
    exit 1
fi

echo "# Generated by generate-config.sh -- do not edit by hand."
echo "# claimed $claimed_ip"
echo "# owner $owner_token"
cat <<'HEADER'
# Exactly one remote. Do NOT add a second one or `remote-random`: this
# container's distinctness from its siblings comes from the CLAIM_DIR
# coordination above, not from anything openvpn does with this file, and a
# second remote would let connect-retry dial a sibling's claimed relay.
client
dev tun
nobind
persist-key
resolv-retry infinite
connect-retry 2
connect-retry-max 3
server-poll-timeout 10
ping 10
ping-restart 30
cipher AES-128-CBC
data-ciphers AES-128-CBC:AES-256-GCM:AES-128-GCM
auth SHA1
auth-nocache
verb 3
HEADER

echo
echo "$remote_line"
echo
# All servers ship an identical CA/cert/key.
for tag in ca cert key; do
    sed -n "/<$tag>/,/<\/$tag>/p" "$work/certs.ovpn"
done
