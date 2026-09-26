#!/bin/sh
# Offline tests for generate-config.sh. No network, no privileges, no sleeps
# (staleness is aged deterministically with `touch -t`, never with a real
# wait). Every invocation gets its own CLAIM_DIR under mktemp -d so claims
# never leak between assertions and no test ever touches /var/lib.
set -u
cd "$(dirname "$0")/.."

pass=0; fail=0
check() { # check <description> <condition-result>
    if [ "$2" = "0" ]; then pass=$((pass+1)); echo "  ok   - $1"
    else fail=$((fail+1)); echo "  FAIL - $1"; fi
}

# One scratch parent for every claim dir this run creates, so a single
# `rm -rf` on EXIT catches all of them -- a per-call variable update would
# not survive `d=$(mkclaimdir)`, which runs the function in a subshell.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkclaimdir() { mktemp -d -p "$scratch"; }

# CCYYMMDDhhmm.ss for `touch -t`, offset by $1 seconds (may be negative).
# Verified on alpine:3.21 to work for both past and future timestamps.
stamp() { date -d "@$(( $(date +%s) + $1 ))" +%Y%m%d%H%M.%S; }

claimed_ip_of() { printf '%s\n' "$1" | grep -m1 '^# claimed ' | awk '{ print $3 }'; }

sorted_ips=$(awk -F, 'NF==15 && $1 !~ /^[*#]/' test/fixture.csv | sort -t, -k3,3 -nr | cut -d, -f2)
top_ip=$(printf '%s\n' "$sorted_ips" | sed -n '1p')

d=$(mkclaimdir)
OUT=$(MAX_SERVERS=5 COUNTRY= CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv); rc=$?
check "exits 0 on the fixture" "$rc"

n=$(printf '%s\n' "$OUT" | grep -c '^remote ')
[ "$n" -eq 1 ]; check "emits exactly one remote line (got $n)" "$?"

c=$(printf '%s\n' "$OUT" | grep -c '^# claimed ')
[ "$c" -eq 1 ]; check "emits exactly one # claimed marker (got $c)" "$?"

printf '%s\n' "$OUT" | grep -qE '^remote [0-9.]+ [0-9]+ (tcp|udp)$'; \
    check "the remote line has host, port and proto" "$?"

claimed=$(claimed_ip_of "$OUT")
[ -f "$d/$claimed/beat" ]; check "a beat file is created under the claim" "$?"

for tag in ca cert key; do
    printf '%s\n' "$OUT" | grep -q "<$tag>" && printf '%s\n' "$OUT" | grep -q "</$tag>"
    check "<$tag> block present and closed" "$?"
done

printf '%s\n' "$OUT" | grep -q -- '-----BEGIN CERTIFICATE-----'; \
    check "cert blocks contain real PEM data" "$?"

printf '%s\n' "$OUT" | grep -q '^remote-random'; r=$?
[ "$r" -ne 0 ]; check "does NOT set remote-random" "$?"

# CRLF must not survive into the output
printf '%s' "$OUT" | grep -q "$(printf '\r')"; r=$?
[ "$r" -ne 0 ]; check "output contains no carriage returns" "$?"

d=$(mkclaimdir)
JP=$(MAX_SERVERS=5 COUNTRY=jp CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv 2>/dev/null); rc=$?
check "lowercase COUNTRY=jp is accepted" "$rc"
jn=$(printf '%s\n' "$JP" | grep -c '^remote ')
[ "$jn" -eq 1 ]; check "COUNTRY=jp yields the one required remote (got $jn)" "$?"

# Unsatisfiable filter must fail loudly, not silently fall back
d=$(mkclaimdir)
MAX_SERVERS=5 COUNTRY=ZZ CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "unsatisfiable COUNTRY=ZZ exits non-zero" "$?"

# Blocklist: a banned exit IP must not come back after a restart
d=$(mkclaimdir)
BLK=$(MAX_SERVERS=32 BLOCKED_IPS="$top_ip" CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv)
blk_ip=$(claimed_ip_of "$BLK")
[ "$blk_ip" != "$top_ip" ]; check "BLOCKED_IPS excludes $top_ip from claiming" "$?"

d=$(mkclaimdir)
all_ips=$(printf '%s\n' "$sorted_ips" | paste -sd,)
MAX_SERVERS=32 BLOCKED_IPS="$all_ips" CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "blocking every server exits non-zero" "$?"

# COUNTRY filter must run before claiming, not after: the fixture's two
# highest-scored rows are deliberately non-JP, so a regression that let
# claiming see the unfiltered pool would hand one of them straight out.
d=$(mkclaimdir)
JPGUARD=$(MAX_SERVERS=32 COUNTRY=JP CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv)
jpguard_ip=$(claimed_ip_of "$JPGUARD")
case "$jpguard_ip" in
    203.0.113.10|203.0.113.20) leaked=1 ;;
    *) leaked=0 ;;
esac
[ "$leaked" -eq 0 ]; check "COUNTRY=JP never claims a non-JP IP (got $jpguard_ip)" "$?"

# MAX_SERVERS still caps the candidate pool, even though only one remote is
# ever emitted: pre-claim the top scorer, then a MAX_SERVERS=1 run has no
# row 2 to fall back to and must fail rather than reach past its own cap.
d=$(mkclaimdir)
mkdir -p "$d/$top_ip"
: > "$d/$top_ip/beat"
MAX_SERVERS=1 CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "MAX_SERVERS caps the pool (top claimed, MAX_SERVERS=1 can't reach row 2)" "$?"

# --- claim/steal/tombstone mechanics ---

d=$(mkclaimdir)
mkdir -p "$d/$top_ip"
: > "$d/$top_ip/beat"
FRESH=$(CLAIM_TTL=60 CLAIM_DIR="$d" MAX_SERVERS=32 ./generate-config.sh < test/fixture.csv)
fresh_ip=$(claimed_ip_of "$FRESH")
[ "$fresh_ip" != "$top_ip" ]; check "a fresh claim is NOT stolen" "$?"

d=$(mkclaimdir)
mkdir -p "$d/$top_ip"
: > "$d/$top_ip/beat"
touch -t "$(stamp -7200)" "$d/$top_ip/beat"
STALE=$(CLAIM_TTL=60 CLAIM_DIR="$d" MAX_SERVERS=32 ./generate-config.sh < test/fixture.csv)
stale_ip=$(claimed_ip_of "$STALE")
[ "$stale_ip" = "$top_ip" ]; check "a stale claim (old beat) is stolen" "$?"

d=$(mkclaimdir)
mkdir -p "$d/$top_ip"
: > "$d/$top_ip/beat"
touch -t "$(stamp 3600)" "$d/$top_ip/beat"
FUTURE=$(CLAIM_TTL=60 CLAIM_DIR="$d" MAX_SERVERS=32 ./generate-config.sh < test/fixture.csv)
future_ip=$(claimed_ip_of "$FUTURE")
[ "$future_ip" = "$top_ip" ]; check "a future-dated beat (clock skew) reads as ancient and is stolen" "$?"

d=$(mkclaimdir)
mkdir -p "$d/$top_ip"
touch -t "$(stamp -7200)" "$d/$top_ip"
NOBEAT=$(CLAIM_TTL=60 CLAIM_DIR="$d" MAX_SERVERS=32 ./generate-config.sh < test/fixture.csv)
nobeat_ip=$(claimed_ip_of "$NOBEAT")
[ "$nobeat_ip" = "$top_ip" ]; check "a beat-less claim ages off the directory's own mtime" "$?"

d=$(mkclaimdir)
: > "$d/$top_ip.dead"
FRESHDEAD=$(TOMBSTONE_TTL=60 CLAIM_DIR="$d" MAX_SERVERS=32 ./generate-config.sh < test/fixture.csv)
freshdead_ip=$(claimed_ip_of "$FRESHDEAD")
[ "$freshdead_ip" != "$top_ip" ]; check "a fresh tombstone blocks its IP" "$?"
[ ! -e "$d/$top_ip" ]; check "a tombstoned IP gets no live claim dir" "$?"

d=$(mkclaimdir)
: > "$d/$top_ip.dead"
touch -t "$(stamp -7200)" "$d/$top_ip.dead"
EXPIREDDEAD=$(TOMBSTONE_TTL=60 CLAIM_DIR="$d" MAX_SERVERS=32 ./generate-config.sh < test/fixture.csv)
expireddead_ip=$(claimed_ip_of "$EXPIREDDEAD")
[ "$expireddead_ip" = "$top_ip" ]; check "an expired tombstone is reclaimable" "$?"

# The shape entrypoint.sh actually produces: a claim dir renamed to .dead.
# The tests above stage `: > <ip>.dead`, a freshly created FILE, which the
# product never creates -- and that is how a tombstone born already expired
# shipped green. rename(2) leaves the directory's mtime at claim time, so a
# long-lived container's tombstone must still age off its beat.
d=$(mkclaimdir)
mkdir -p "$d/$top_ip"
: > "$d/$top_ip/beat"
touch -t "$(stamp -7200)" "$d/$top_ip"
mv "$d/$top_ip" "$d/$top_ip.dead"
RENAMEDDEAD=$(TOMBSTONE_TTL=900 CLAIM_DIR="$d" MAX_SERVERS=32 ./generate-config.sh < test/fixture.csv)
renameddead_ip=$(claimed_ip_of "$RENAMEDDEAD")
[ "$renameddead_ip" != "$top_ip" ]; check "a renamed tombstone from a long-lived claim still blocks" "$?"

d=$(mkclaimdir)
mkdir -p "$d/$top_ip"
: > "$d/$top_ip/beat"
touch -t "$(stamp -7200)" "$d/$top_ip/beat"
touch -t "$(stamp -7200)" "$d/$top_ip"
mv "$d/$top_ip" "$d/$top_ip.dead"
OLDBEATDEAD=$(TOMBSTONE_TTL=900 CLAIM_DIR="$d" MAX_SERVERS=32 ./generate-config.sh < test/fixture.csv)
oldbeatdead_ip=$(claimed_ip_of "$OLDBEATDEAD")
[ "$oldbeatdead_ip" = "$top_ip" ]; check "a renamed tombstone whose beat is old IS reclaimable" "$?"

# --- distinctness under real contention ---

d=$(mkclaimdir)
seq_ips=""
i=0
while [ "$i" -lt 6 ]; do
    out=$(MAX_SERVERS=32 CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv)
    seq_ips="$seq_ips$(claimed_ip_of "$out")
"
    i=$((i+1))
done
seq_ips=$(printf '%s\n' "$seq_ips" | sed '/^$/d')
seq_distinct=$(printf '%s\n' "$seq_ips" | sort -u | wc -l)
[ "$seq_distinct" -eq 6 ]; check "6 sequential runs yield 6 distinct claimed IPs (got $seq_distinct)" "$?"
expected_order=$(printf '%s\n' "$sorted_ips" | head -6)
[ "$seq_ips" = "$expected_order" ]; check "6 sequential claims land in descending score order" "$?"

# Concurrent, COLD dir: no claim exists yet, so every claimer takes the
# plain mkdir path. This is the case the original steal bug's own
# concurrency test covered, and cold claiming was never broken by it.
# Redirect straight to a file rather than piping through `grep -m1`: a
# reader that stops early SIGPIPEs generate-config.sh, which skips its own
# EXIT trap and leaks its scratch dir -- confirmed reproducible in isolation.
d=$(mkclaimdir)
outdir=$(mktemp -d -p "$scratch")
i=0
while [ "$i" -lt 8 ]; do
    ( MAX_SERVERS=32 CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv \
        > "$outdir/$i" 2>/dev/null ) &
    i=$((i+1))
done
wait
conc_ips=$(grep -h -m1 '^# claimed ' "$outdir"/* 2>/dev/null | awk '{ print $3 }')
rm -rf "$outdir"
conc_count=$(printf '%s\n' "$conc_ips" | grep -c .)
conc_distinct=$(printf '%s\n' "$conc_ips" | sort -u | wc -l)
ok=1
[ "$conc_count" -eq 8 ] || ok=0
[ "$conc_distinct" -eq 8 ] || ok=0
[ "$ok" -eq 1 ]; check "8 concurrent runs (cold dir) yield 8 distinct claimed IPs (count=$conc_count distinct=$conc_distinct)" "$?"

# Concurrent, dir full of STALE claims: N claimers must all steal, none
# cold-claim. This is the scenario a cold-dir concurrency test cannot catch,
# because deletion (the part that was not atomic) only ever happens on the
# steal path -- reproduces QA's finding that a non-atomic mv-based steal
# handed out duplicate claims here 29 of 30 rounds. MAX_SERVERS is pinned to
# the SAME size as the claimer count and the stale-claim count (6/6/6), not
# left at the generous default: a larger pool would let a losing stealer
# just cold-claim a fresh, never-contended IP instead of retrying the steal,
# which is a materially weaker test than it looks.
d=$(mkclaimdir)
for ip in $(printf '%s\n' "$sorted_ips" | head -6); do
    mkdir -p "$d/$ip"
    printf '' > "$d/$ip/beat"
    touch -t "$(stamp -7200)" "$d/$ip/beat"
done
outdir=$(mktemp -d -p "$scratch")
i=0
while [ "$i" -lt 6 ]; do
    ( CLAIM_TTL=60 CLAIM_DIR="$d" MAX_SERVERS=6 ./generate-config.sh < test/fixture.csv \
        > "$outdir/out.$i" 2>"$outdir/err.$i"
      echo "$?" > "$outdir/rc.$i" ) &
    i=$((i+1))
done
wait
steal_ips=$(grep -h -m1 '^# claimed ' "$outdir"/out.* 2>/dev/null | awk '{ print $3 }')
steal_count=$(printf '%s\n' "$steal_ips" | grep -c .)
steal_distinct=$(printf '%s\n' "$steal_ips" | sort -u | wc -l)
bad_rc=$(cat "$outdir"/rc.* 2>/dev/null | grep -cv '^0$')
rm -rf "$outdir"
ok=1
[ "$steal_count" -eq 6 ] || ok=0
[ "$steal_distinct" -eq 6 ] || ok=0
[ "$bad_rc" -eq 0 ] || ok=0
[ "$ok" -eq 1 ]; check "6 concurrent claimers vs 6 pre-staged STALE claims, pool size == claimer count (every claimer forced to steal): 6 distinct, zero duplicates, zero bad exits (count=$steal_count distinct=$steal_distinct bad_rc=$bad_rc)" "$?"

# Sweep: stage lock dirs from several past buckets plus one in the CURRENT
# bucket, then claim. Only the past-bucket locks may be removed -- the
# current-bucket one might be a rival's live, in-progress steal lock, and
# removing it would be exactly the race the bucketing scheme prevents.
d=$(mkclaimdir)
mkdir -p "$d/$top_ip"
printf '' > "$d/$top_ip/beat"
touch -t "$(stamp -7200)" "$d/$top_ip/beat"
now=$(date +%s)
ttl=60
current_bucket=$((now / ttl))
past1="$d/$top_ip.steal.$((current_bucket - 1))"
past2="$d/$top_ip.steal.$((current_bucket - 5))"
curlock="$d/$top_ip.steal.$current_bucket"
mkdir -p "$past1" "$past2" "$curlock"
CLAIM_TTL=$ttl CLAIM_DIR="$d" MAX_SERVERS=32 ./generate-config.sh < test/fixture.csv >/dev/null
ok=1
[ -d "$past1" ] && ok=0
[ -d "$past2" ] && ok=0
[ -d "$curlock" ] || ok=0
[ "$ok" -eq 1 ]; check "steal-lock sweep removes only strictly-past-bucket locks, never the current bucket's" "$?"

# Exhaustion: cap the pool to 3 and fully claim it, then a 4th run has
# nothing left in its own MAX_SERVERS window to try.
d=$(mkclaimdir)
i=0
while [ "$i" -lt 3 ]; do
    MAX_SERVERS=3 CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv >/dev/null
    i=$((i+1))
done
MAX_SERVERS=3 CLAIM_DIR="$d" ./generate-config.sh < test/fixture.csv >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "exhausting the MAX_SERVERS pool exits non-zero" "$?"

# --- CLAIM_DIR validation ---

CLAIM_DIR=relative/claims MAX_SERVERS=5 ./generate-config.sh < test/fixture.csv >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "a relative CLAIM_DIR fails loudly" "$?"

# /dev/null is not a directory, so no path under it can ever be created --
# an ENOTDIR stand-in for "unwritable" that works whether or not the test
# runner is root (chmod 000 would not block root).
CLAIM_DIR=/dev/null/claims MAX_SERVERS=5 ./generate-config.sh < test/fixture.csv >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check "an unwritable CLAIM_DIR (ENOTDIR) fails loudly" "$?"

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
