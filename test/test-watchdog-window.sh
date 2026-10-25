#!/bin/sh
# Offline tests for the watchdog's 3-of-last-5 failure window. Loads the real
# record_check() from entrypoint.sh. No network, no privileges.
set -u
cd "$(dirname "$0")/.."

pass=0; fail=0
check() { # check <description> <condition-result>
    if [ "$2" = "0" ]; then pass=$((pass+1)); echo "  ok   - $1"
    else fail=$((fail+1)); echo "  FAIL - $1"; fi
}

eval "$(sed -n '/^record_check() {$/,/^}$/p' entrypoint.sh)"
command -v record_check > /dev/null 2>&1; check "record_check loaded from entrypoint.sh" "$?"
if [ "$fail" -ne 0 ]; then echo "passed: $pass  failed: $fail"; exit 1; fi

run_seq() { hist=""; for r in $1; do record_check "$r"; done; [ "$fails" -ge 3 ]; }

for s in "F F F" "F P F F" "F P F P F"; do
    run_seq "$s"; check "gives up on: $s" "$?"
done
for s in "F P P F P P F" "F F P P P P F F" "F F" "F F P P P F"; do
    run_seq "$s"; [ "$?" -ne 0 ]; check "keeps going on: $s" "$?"
done

! grep -q 'fails=0' entrypoint.sh; check "no fails=0 reset in entrypoint.sh" "$?"
n=$(grep -c 'hist=""' entrypoint.sh)
[ "$n" -eq 1 ]; check "hist reset only once, before the loop (got $n)" "$?"
for r in P F; do
    n=$(grep -c "record_check $r" entrypoint.sh)
    [ "$n" -eq 1 ]; check "record_check $r called once in the loop (got $n)" "$?"
done

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
