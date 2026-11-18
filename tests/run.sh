#!/bin/bash
# Regression suite for the plugin's scripts. Runs anywhere with bash, python3, jq and git;
# needs no GitHub (gh is stubbed) and touches nothing outside a scratch directory.
#   tests/run.sh            run everything
#   tests/run.sh lock       one group: lock | guard | watcher | cleanup | changelog | install | shift | sweep | publish | merge
set -u
here=$(cd "$(dirname "$0")/.." && pwd -P)
# The caller's environment must not leak into the scripts under test.
unset AGENTLOCK_AS AGENTLOCK_OWNER AGENTLOCK_POLL AGENTLOCK_DEFAULT_TTL SS_ARGS
# An absolute, existing scratch directory, or nothing runs: a failed mktemp must not send
# the stub gh to /bin or the trap's rm anywhere else.
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-team-tests.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT   # set first, so the refusal below still removes what mktemp made
work=$(cd "$work" && pwd -P) || exit 1
case "$work" in /*/*) ;; *) echo "refusing scratch dir $work" >&2; exit 1 ;; esac
export AGENTLOCK_DIR="$work/locks"; mkdir -p "$AGENTLOCK_DIR"
L="$here/scripts/agentlock"
fail=0; pass=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
want="${1:-all}"
case "$want" in all|lock|guard|watcher|cleanup|changelog|install|shift|sweep|publish|merge) ;; *) echo "unknown group: $want (lock|guard|watcher|cleanup|changelog|install|shift|sweep|publish|merge)" >&2; exit 2 ;; esac
run() { [ "$want" = all ] || [ "$want" = "$1" ]; }

if run lock; then echo "lock"
  AGENTLOCK_OWNER=A $L acquire sim:x --ttl 2m >/dev/null
  AGENTLOCK_OWNER=B $L acquire sim:x --ttl 2m >/dev/null 2>&1; check "other session refused" $? 1
  AGENTLOCK_OWNER=A $L acquire sim:x --ttl 2m >/dev/null; check "same owner refreshes" $? 0
  AGENTLOCK_OWNER=A AGENTLOCK_AS=b1 $L acquire sim:y --ttl 2m >/dev/null
  AGENTLOCK_OWNER=A AGENTLOCK_AS=b2 $L acquire sim:y --ttl 2m >/dev/null 2>&1; check "builders of one session exclude each other" $? 1
  (sleep 1; AGENTLOCK_OWNER=A AGENTLOCK_AS=b1 $L release sim:y >/dev/null) & AGENTLOCK_POLL=1 AGENTLOCK_OWNER=A AGENTLOCK_AS=b2 $L acquire sim:y --ttl 2m --wait 10s >/dev/null; check "wait then acquire" $? 0
  AGENTLOCK_OWNER=A $L acquire sim:z --ttl 1s >/dev/null; sleep 2; AGENTLOCK_OWNER=B $L acquire sim:z --ttl 1m >/dev/null 2>&1; check "stale by ttl is taken over" $? 0
  AGENTLOCK_OWNER=B $L acquire quiet --ttl 1m >/dev/null 2>&1; check "quiet refused while others hold" $? 1
  AGENTLOCK_OWNER=A $L release-all >/dev/null; AGENTLOCK_OWNER=B $L release-all >/dev/null
  check "release-all leaves nothing" "$($L status)" "no locks"
  # Mixed-version window: a 0.3.15 binary (locks directly under the root, dirs without info stale)
  # must not treat locks/ as one stale lock and delete every live lock in it. The marker file is what stops it.
  [ -f "$AGENTLOCK_DIR/locks/info" ] && ok "marker for pre-0.4.0 binaries written" || bad "no locks/info marker"
  AGENTLOCK_OWNER=A $L acquire info --ttl 1m >/dev/null 2>&1; check "'info' cannot be a resource name while the marker exists" $? 1
  if git -C "$here" show 4ab2d13:scripts/agentlock > "$work/agentlock-0.3.15" 2>/dev/null; then
    chmod +x "$work/agentlock-0.3.15"
    AGENTLOCK_OWNER=A $L acquire ui --ttl 2m >/dev/null
    "$work/agentlock-0.3.15" clean >/dev/null 2>&1
    [ -f "$AGENTLOCK_DIR/locks/ui/info" ] && ok "0.3.15 clean leaves locks/ alone" || bad "0.3.15 clean deleted locks/"
    mkdir -p "$AGENTLOCK_DIR/waits/ui"; printf 'owner=agentlock-0.4.0-marker\nacquired=1\nexpires=0\nreason=not-a-lock\n' > "$AGENTLOCK_DIR/waits/info"; printf 'owner=W\npid=%s\nsince=1\nexpires=0\nreason=r\n' "$$" > "$AGENTLOCK_DIR/waits/ui/0000000001.$$"
    "$work/agentlock-0.3.15" clean >/dev/null 2>&1
    [ -f "$AGENTLOCK_DIR/waits/ui/0000000001.$$" ] && ok "0.3.15 clean leaves waits/ alone, thanks to its marker" || bad "0.3.15 clean deleted waits/"
    rm -rf "$AGENTLOCK_DIR/waits"
    AGENTLOCK_OWNER=A $L release ui >/dev/null
  else echo "  skip 0.3.15 clean (commit 4ab2d13 not in this clone)"; fi
  # A session started before the update still holds locks directly under the root; those must exclude this layout.
  mkdir -p "$AGENTLOCK_DIR/ui"; printf 'owner=OLD\npid=%s\nacquired=%s\nexpires=0\nreason=old\n' $$ "$(date +%s)" > "$AGENTLOCK_DIR/ui/info"
  AGENTLOCK_OWNER=A $L acquire ui --ttl 1m >/dev/null 2>&1; check "a live pre-0.4.0 lock excludes a new acquire" $? 1
  AGENTLOCK_OWNER=A $L acquire quiet --ttl 1m >/dev/null 2>&1; check "a live pre-0.4.0 lock blocks quiet" $? 1
  AGENTLOCK_POLL=1 AGENTLOCK_OWNER=A $L wait ui 1s >/dev/null 2>&1; check "wait sees a pre-0.4.0 lock" $? 1
  $L status | grep -q "^ui: .*\[pre-0.4.0 copy\]" && ok "status lists the pre-0.4.0 lock" || bad "status hides the pre-0.4.0 lock"
  AGENTLOCK_OWNER=A $L release ui >/dev/null 2>&1; check "release of a legacy lock held by another is refused" $? 1
  AGENTLOCK_OWNER=A $L release ui --force 2>/dev/null | grep -q "pre-0.4.0" && [ ! -d "$AGENTLOCK_DIR/ui" ] && ok "release --force removes a legacy lock" || bad "release --force cannot remove a legacy lock"
  AGENTLOCK_OWNER=A $L acquire ui --ttl 1m >/dev/null 2>&1; check "free after the forced release" $? 0; AGENTLOCK_OWNER=A $L release ui >/dev/null
  mkdir -p "$AGENTLOCK_DIR/ui"; printf 'owner=OLD\npid=%s\nacquired=%s\nexpires=0\nreason=old\n' $$ "$(date +%s)" > "$AGENTLOCK_DIR/ui/info"
  AGENTLOCK_OWNER=OLD $L acquire ui --ttl 1m >/dev/null 2>&1; check "the same session may take its own name in the new layout" $? 0
  AGENTLOCK_OWNER=OLD $L release ui >/dev/null
  dead=$(sh -c 'echo $$'); printf 'owner=OLD\npid=%s\nacquired=%s\nexpires=0\n' "$dead" "$(date +%s)" > "$AGENTLOCK_DIR/ui/info"
  AGENTLOCK_OWNER=A $L acquire ui --ttl 1m >/dev/null 2>&1; check "a dead pre-0.4.0 lock does not exclude" $? 0
  AGENTLOCK_OWNER=A $L release ui >/dev/null; $L clean >/dev/null
  [ -d "$AGENTLOCK_DIR/ui" ] && bad "clean left the stale pre-0.4.0 lock" || ok "clean removes the stale pre-0.4.0 lock"
  [ -f "$AGENTLOCK_DIR/locks/info" ] && ok "clean leaves locks/ and its marker alone" || bad "clean removed locks/ or its marker"
  # The old copy's mkdir comes before its info write: a fresh bare directory is busy, an aged one is ignored and kept.
  mkdir -p "$AGENTLOCK_DIR/ui"; AGENTLOCK_OWNER=A $L acquire ui --ttl 1m >/dev/null 2>&1; check "a fresh bare pre-0.4.0 dir is busy" $? 1
  touch -t 202001010000 "$AGENTLOCK_DIR/ui"; AGENTLOCK_OWNER=A $L acquire ui --ttl 1m >/dev/null 2>&1; check "an aged bare pre-0.4.0 dir is ignored" $? 0
  [ -d "$AGENTLOCK_DIR/ui" ] && ok "the aged bare dir is kept by acquire" || bad "acquire deleted a bare legacy dir"; rmdir "$AGENTLOCK_DIR/ui"
  mkdir -p "$AGENTLOCK_DIR/sim:x"; AGENTLOCK_OWNER=A $L acquire quiet --ttl 1m >/dev/null 2>&1; check "a fresh bare pre-0.4.0 dir blocks quiet" $? 1; rmdir "$AGENTLOCK_DIR/sim:x"
  # A bare directory under the root is not a lock: release must never delete it, aged or fresh, forced or not.
  mkdir -p "$AGENTLOCK_DIR/backup"; echo keep > "$AGENTLOCK_DIR/backup/data"; touch -t 202001010000 "$AGENTLOCK_DIR/backup"
  AGENTLOCK_OWNER=A $L release backup >/dev/null 2>&1; AGENTLOCK_OWNER=A $L release backup --force >/dev/null 2>&1
  [ -f "$AGENTLOCK_DIR/backup/data" ] && ok "release leaves a bare directory under the root alone" || bad "release deleted a bare directory under the root"
  rm -rf "$AGENTLOCK_DIR/backup"
  mkdir -p "$AGENTLOCK_DIR/sim:y"; printf 'owner=OLD\npid=%s\nacquired=%s\nexpires=0\n' $$ "$(date +%s)" > "$AGENTLOCK_DIR/sim:y/info"
  AGENTLOCK_OWNER=OLD $L release sim:y >/dev/null 2>&1; check "a session releases its own legacy lock without --force" $? 0
  [ -d "$AGENTLOCK_DIR/sim:y" ] && bad "own legacy lock not removed" || ok "own legacy lock removed"
  AGENTLOCK_OWNER=A $L release ui >/dev/null
  # Before any new-layout lock exists, status and clean must still see legacy locks (the guard's holder list is status).
  r2="$work/locks2"; mkdir -p "$r2/ui"; printf 'owner=OLD\npid=%s\nacquired=%s\nexpires=0\nreason=old\n' $$ "$(date +%s)" > "$r2/ui/info"
  AGENTLOCK_DIR="$r2" $L status | grep -q "^ui: .*\[pre-0.4.0 copy\]" && ok "status lists a legacy lock with no locks/ yet" || bad "status blind without locks/"
  AGENTLOCK_DIR="$r2" $L status ui | grep -q "owner=OLD" && ok "status <res> shows the legacy holder" || bad "status <res> blind"
  AGENTLOCK_DIR="$r2" AGENTLOCK_POLL=1 AGENTLOCK_OWNER=A $L wait ui 1s 2>&1 | grep -q "still held: owner=OLD" && ok "wait names the legacy holder" || bad "wait names the wrong holder"
  # The clock crossing a second between two reads once ended a 1 s wait before it began (exit 1, no output): a date that
  # steps one second per call reproduces that; the deadline now comes from one read.
  mkdir -p "$work/stepdate"; printf '#!/bin/bash\nn=$(cat "$STEP_FILE"); echo $((n+1)) > "$STEP_FILE"; echo $((1700000000 + n))\n' > "$work/stepdate/date"; chmod +x "$work/stepdate/date"; echo 0 > "$work/stepdate/n"
  out=$(STEP_FILE="$work/stepdate/n" PATH="$work/stepdate:$PATH" AGENTLOCK_DIR="$r2" AGENTLOCK_POLL=1 AGENTLOCK_OWNER=A $L wait ui 1s 2>&1); rc=$?
  printf '%s' "$out" | grep -q "still held: owner=OLD" && ok "a 1 s wait across a second boundary still waits and reports the holder" || bad "wait across a second boundary: rc=$rc, output '$out'"
  printf 'owner=OLD\npid=%s\nacquired=%s\nexpires=0\n' "$dead" "$(date +%s)" > "$r2/ui/info"
  AGENTLOCK_DIR="$r2" $L status | grep -q "^ui: .*\[pre-0.4.0 copy\] \[STALE\]" && ok "status lists a stale legacy lock as stale" || bad "status hides a stale legacy lock"
  AGENTLOCK_DIR="$r2" $L clean >/dev/null
  [ -d "$r2/ui" ] && bad "clean blind without locks/" || ok "clean removes a stale legacy lock with no locks/ yet"
  if [ -x "$work/agentlock-0.3.15" ]; then
    AGENTLOCK_OWNER=OLD "$work/agentlock-0.3.15" acquire sim:x --ttl 1m >/dev/null 2>&1
    AGENTLOCK_OWNER=A $L acquire sim:x --ttl 1m >/dev/null 2>&1; check "a lock taken by the real 0.3.15 binary excludes a new acquire" $? 1
    AGENTLOCK_OWNER=OLD "$work/agentlock-0.3.15" release sim:x >/dev/null 2>&1
    AGENTLOCK_OWNER=A $L acquire sim:x --ttl 1m >/dev/null 2>&1; check "released by 0.3.15, free for the new copy" $? 0
    AGENTLOCK_OWNER=A $L release sim:x >/dev/null
  fi
  AGENTLOCK_OWNER=B $L acquire quiet --ttl 1m >/dev/null; AGENTLOCK_OWNER=A $L acquire sim:x --ttl 1m >/dev/null 2>&1; check "nothing handed out under quiet" $? 1
  AGENTLOCK_OWNER=B $L release quiet >/dev/null
  # Mutual exclusion under concurrency: exactly one of many parallel acquirers may win.
  won=$(for i in $(seq 1 40); do ( AGENTLOCK_OWNER="P$i" $L acquire ui --ttl 1m >/dev/null 2>&1 && echo won ) & done; wait)
  check "40 parallel acquires, one success" "$(printf '%s\n' "$won" | grep -c won)" 1
  wins=$(for i in $(seq 1 40); do AGENTLOCK_OWNER="P$i" $L check ui && echo 1; done | wc -l | tr -d ' ')
  check "40 parallel acquires, one holder" "$wins" 1
  $L release ui --force >/dev/null
  mkdir -p "$AGENTLOCK_DIR/locks/bare"; touch -t 202001010000 "$AGENTLOCK_DIR/locks/bare"
  AGENTLOCK_OWNER=A $L acquire bare --ttl 1m >/dev/null 2>&1; check "an aged dir without info is taken over" $? 0
  mkdir -p "$AGENTLOCK_DIR/locks/fresh"; AGENTLOCK_OWNER=A $L acquire fresh --ttl 1m >/dev/null 2>&1; check "a fresh dir without info is busy" $? 1
  AGENTLOCK_OWNER=A $L release-all >/dev/null; rmdir "$AGENTLOCK_DIR/locks/fresh"
  $L release ui --force >/dev/null
  # stock macOS has no `timeout`; run the call with a watchdog that kills it after 5 s
  bounded() { ( "$@" >/dev/null 2>&1 & p=$!; ( sleep 5; kill $p 2>/dev/null ) & w=$!; wait $p; r=$?; kill $w 2>/dev/null; exit $r ); }
  AGENTLOCK_OWNER=A bounded $L acquire . --ttl 1m; check "bad resource name '.' fails fast" $? 1
  AGENTLOCK_OWNER=A bounded $L acquire "$(printf 'a%.0s' $(seq 1 300))" --ttl 1m; check "a name mkdir cannot create fails, no hang" $? 1
  AGENTLOCK_OWNER=A $L acquire ok --ttl 5x >/dev/null 2>&1; check "bad ttl refused" $? 1
  [ -d "$AGENTLOCK_DIR/locks/ok" ] && bad "bad ttl still created a lock" || ok "bad ttl creates nothing"
  AGENTLOCK_OWNER=A $L acquire ui --ttl >/dev/null 2>&1; check "missing --ttl value refused" $? 1
  AGENTLOCK_OWNER=A $L acquire sim:w --wait --reason "bare wait" --ttl 1m >/dev/null 2>&1; check "a bare --wait before other options is accepted (was 'one resource per call')" $? 0
  AGENTLOCK_OWNER=A $L renew sim:w --ttl 2m 2>/dev/null | grep -q "renewed sim:w" && ok "renew with --ttl refreshes a held lock" || bad "renew did not refresh"
  AGENTLOCK_OWNER=B $L renew sim:w --ttl 2m 2>&1 >/dev/null | grep -q "held by someone else" && ok "renew of another session's lock is refused as held by someone else" || bad "renew by another owner was not refused with the holder named"
  AGENTLOCK_OWNER=A $L renew sim:free 2>&1 >/dev/null | grep -q "not held" && ok "renew of a free resource says not held and takes nothing" || bad "renew acquired or was silent"
  [ -d "$AGENTLOCK_DIR/locks/sim:free" ] && bad "renew created a lock" || ok "renew created no lock"
  # A bare renew keeps the lock's own ttl: a 2 h lock stays a 2 h lock, not the default.
  AGENTLOCK_OWNER=A $L release sim:w >/dev/null; AGENTLOCK_OWNER=A $L acquire sim:w --ttl 2h >/dev/null; sleep 1
  AGENTLOCK_OWNER=A $L renew sim:w >/dev/null; left=$(AGENTLOCK_OWNER=A $L status sim:w | sed 's/.* \([0-9]*\)s left.*/\1/')
  [ "$left" -gt 7100 ] && ok "a bare renew keeps the lock's own ttl ($left s left)" || bad "a bare renew shortened the lock to $left s"
  age=$(AGENTLOCK_OWNER=A $L status sim:w | sed 's/.*age=\([0-9]*\)s.*/\1/'); [ "$age" -ge 1 ] && ok "renew leaves the lock's age alone" || bad "renew reset the age to $age"
  AGENTLOCK_OWNER=A $L renew sim:w --ttl 0 >/dev/null; sleep 1; AGENTLOCK_OWNER=A $L check sim:w; check "renew --ttl 0 means no expiry, as on acquire" $? 0
  AGENTLOCK_OWNER=A $L release sim:w >/dev/null; AGENTLOCK_OWNER=A $L acquire sim:w --ttl 10s >/dev/null; sleep 6
  AGENTLOCK_OWNER=A $L renew sim:w >/dev/null; left=$(AGENTLOCK_OWNER=A $L status sim:w | sed 's/.* \([0-9]*\)s left.*/\1/')
  [ "$left" -ge 9 ] && ok "a bare renew in the lock's last seconds really renews ($left s left)" || bad "renew in the last seconds was silently skipped: $left s left"
  AGENTLOCK_OWNER=A $L release sim:w >/dev/null
  # Older info files (no ttl= line): the ttl is expires minus acquired; a file with no acquired has no ttl, not a 56-year one.
  AGENTLOCK_OWNER=A $L acquire sim:old --ttl 1m >/dev/null; sed -i.bak '/^ttl=/d' "$AGENTLOCK_DIR/locks/sim:old/info"; rm -f "$AGENTLOCK_DIR/locks/sim:old/info.bak"
  AGENTLOCK_OWNER=A $L renew sim:old 2>/dev/null | grep -q "renewed" && ok "a 0.4.11 lock without a ttl line renews by expires minus acquired" || bad "old-format lock not renewed"
  AGENTLOCK_OWNER=A $L release sim:old >/dev/null
  # A --wait whose shell is gone stops waiting instead of sitting on the queue for its whole limit; a ps that
  # answers nothing is unknown, not gone.
  mkdir -p "$work/nops"; printf '#!/bin/bash\n# answers once, then fails: a ps that works at start and hiccups later\n[ -e "%s/ps.once" ] && exit 1; touch "%s/ps.once"; exec /bin/ps "$@"\n' "$work/nops" "$work/nops" > "$work/nops/ps"; chmod +x "$work/nops/ps"
  AGENTLOCK_OWNER=A $L acquire sim:p --ttl 1m >/dev/null
  ( sleep 2; AGENTLOCK_OWNER=A $L release sim:p >/dev/null ) & PATH="$work/nops:$PATH" AGENTLOCK_POLL=1 AGENTLOCK_OWNER=B $L acquire sim:p --ttl 1m --wait 10s >/dev/null 2>&1; check "a failing ps does not end the wait: the lock is acquired once released" $? 0
  AGENTLOCK_OWNER=B $L release sim:p >/dev/null
  # The lock name carries this suite's pid: the pgrep below is machine-wide and once saw another suite's waiter (round 47).
  # Wait tickets: the oldest live waiter is served first; a plain acquire steps behind live waiters; dead tickets are dropped.
  AGENTLOCK_OWNER=A $L acquire q1 --ttl 1m >/dev/null
  ( AGENTLOCK_POLL=1 AGENTLOCK_OWNER=W1 $L acquire q1 --ttl 1m --wait 40s --reason first >/dev/null 2>&1; echo $? > "$work/w1.rc" ) & wq1=$!
  sleep 1.5
  ( AGENTLOCK_POLL=1 AGENTLOCK_OWNER=W2 $L acquire q1 --ttl 1m --wait 40s --reason second >/dev/null 2>&1; echo $? > "$work/w2.rc" ) & wq2=$!
  sleep 1.5
  [ -f "$AGENTLOCK_DIR/waits/info" ] && grep -q '^expires=0$' "$AGENTLOCK_DIR/waits/info" && ok "the first ticket writes the waits/ marker a pre-0.4.0 clean respects" || bad "no waits/info marker after a wait"
  st=$($L status); printf '%s\n' "$st" | grep -q "waiting on q1: owner=W1 .*reason=first" && printf '%s\n' "$st" | grep -q "waiting on q1: owner=W2 .*reason=second" && [ "$(printf '%s\n' "$st" | grep -c 'waiting on q1')" = 2 ] && ok "status lists the waiters with their reasons" || bad "waiters not listed: $st"
  [ "$(printf '%s\n' "$st" | grep 'waiting on q1' | head -1 | grep -c 'owner=W1')" = 1 ] && ok "the first waiter is listed first" || bad "order: $st"
  AGENTLOCK_OWNER=B $L acquire q1 --ttl 1m >/dev/null 2>&1; check "a plain acquire while waiters are in line is refused" $? 1
  AGENTLOCK_OWNER=B $L acquire q1 --ttl 1m 2>&1 >/dev/null | grep -q "has 2 waiter(s) ahead of you (first: owner=W1" && ok "the refusal names the count and the first waiter" || bad "refusal text: $(AGENTLOCK_OWNER=B $L acquire q1 --ttl 1m 2>&1)"
  $L status q1 | grep -q "waiting on q1: owner=W1" && ok "status <resource> lists that resource's waiters" || bad "status q1: $($L status q1)"
  t1=$(ls "$AGENTLOCK_DIR/waits/q1" | head -1); rm -f "$AGENTLOCK_DIR/waits/q1/$t1"; sleep 2.5
  [ -f "$AGENTLOCK_DIR/waits/q1/$t1" ] && ok "a ticket removed under a waiter is written again under its own name on the next poll" || bad "ticket not rewritten: $(ls "$AGENTLOCK_DIR/waits/q1")"
  AGENTLOCK_OWNER=A $L release q1 >/dev/null; sleep 3
  [ "$(cat "$work/w1.rc" 2>/dev/null)" = 0 ] && [ ! -f "$work/w2.rc" ] && $L status | grep -q "^q1: owner=W1 " && ok "the first waiter gets the lock when it frees; the second keeps waiting" || bad "handover: w1=$(cat "$work/w1.rc" 2>/dev/null) w2=$(cat "$work/w2.rc" 2>/dev/null) $($L status)"
  $L status | grep -q "waiting on q1: owner=W2" && ! $L status | grep -q "waiting on q1: owner=W1" && ok "the served waiter's ticket is gone, the other's stays" || bad "tickets after handover: $($L status)"
  AGENTLOCK_OWNER=W1 $L release q1 >/dev/null; sleep 3
  [ "$(cat "$work/w2.rc" 2>/dev/null)" = 0 ] && $L status | grep -q "^q1: owner=W2 " && ! $L status | grep -q "waiting on q1" && ok "the second waiter gets it next, and no ticket remains" || bad "second handover: w2=$(cat "$work/w2.rc" 2>/dev/null) $($L status)"
  wait $wq1 $wq2 2>/dev/null; AGENTLOCK_OWNER=W2 $L release q1 >/dev/null
  # A dead ticket (its waiter gone) is dropped by the next party that looks, and does not block a plain acquire.
  mkdir -p "$AGENTLOCK_DIR/waits/q1"; printf 'owner=ghost\npid=4194300\nsince=1\nreason=gone\n' > "$AGENTLOCK_DIR/waits/q1/0000000001.4194300"
  AGENTLOCK_OWNER=B $L acquire q1 --ttl 1m >/dev/null 2>&1; check "a dead waiter's ticket does not block a plain acquire" $? 0
  [ ! -e "$AGENTLOCK_DIR/waits/q1/0000000001.4194300" ] && ok "the dead ticket is dropped" || bad "dead ticket kept"
  AGENTLOCK_OWNER=B $L release q1 >/dev/null
  # A live ticket with the lock free: a plain acquire is refused (the behaviour that is new), a ticket past its deadline is not a ticket.
  printf 'owner=L\npid=%s\nsince=%s\nexpires=%s\nreason=live\n' "$$" "$(date +%s)" "$(( $(date +%s) + 600 ))" > "$AGENTLOCK_DIR/waits/q1/$(date +%s).$$"
  AGENTLOCK_OWNER=B $L acquire q1 --ttl 1m >/dev/null 2>&1; check "a live ticket refuses a plain acquire even when the lock is free" $? 1
  rm -f "$AGENTLOCK_DIR/waits/q1/"*; printf 'owner=L\npid=%s\nsince=1\nexpires=2\nreason=over\n' "$$" > "$AGENTLOCK_DIR/waits/q1/0000000001.$$"
  AGENTLOCK_OWNER=B $L acquire q1 --ttl 1m >/dev/null 2>&1; check "a ticket past its deadline does not block, whatever its pid" $? 0
  [ -z "$(ls "$AGENTLOCK_DIR/waits/q1")" ] && ok "the expired ticket is dropped" || bad "expired ticket kept"
  AGENTLOCK_OWNER=B $L release q1 >/dev/null
  printf 'owner=L\npid=%s\nsince=1\nexpires=2\nreason=over\n' "$$" > "$AGENTLOCK_DIR/waits/q1/0000000001.$$"; $L clean >/dev/null; [ -z "$(ls "$AGENTLOCK_DIR/waits/q1")" ] && ok "clean reaps tickets too" || bad "clean left a ticket"
  # waits/ created this very second with nothing held: a quiet must not see it as a bare pre-0.4.0 lock (five seconds of grace would hide the bug).
  rm -rf "$AGENTLOCK_DIR/waits"; mkdir -p "$AGENTLOCK_DIR/waits/x"; AGENTLOCK_OWNER=Q $L acquire quiet --ttl 1m >/dev/null 2>&1; check "a fresh waits/ is not a lock to quiet's check" $? 0; AGENTLOCK_OWNER=Q $L release quiet >/dev/null
  # A half-written ticket left behind (writer killed between write and mv) is not a ticket and is reaped once old.
  mkdir -p "$AGENTLOCK_DIR/waits/q1"; printf 'owner=K\npid=4194300\nsince=1\nexpires=2\nreason=k\n' > "$AGENTLOCK_DIR/waits/q1/0000000001.4194300.tmp.4194300"; touch -t 202001010000 "$AGENTLOCK_DIR/waits/q1/0000000001.4194300.tmp.4194300"
  AGENTLOCK_OWNER=B $L acquire q1 --ttl 1m >/dev/null 2>&1; check "a leftover half-written ticket does not block a plain acquire" $? 0
  [ -z "$(ls "$AGENTLOCK_DIR/waits/q1")" ] && ok "the old half-written ticket is reaped" || bad "tmp ticket kept: $(ls "$AGENTLOCK_DIR/waits/q1")"
  AGENTLOCK_OWNER=B $L release q1 >/dev/null
  # A young half-written ticket (a rewrite in progress: live pid, future deadline, within the grace) is not a ticket either, and is left for its writer.
  printf 'owner=K\npid=%s\nsince=%s\nexpires=%s\nreason=k\n' "$$" "$(date +%s)" "$(( $(date +%s) + 600 ))" > "$AGENTLOCK_DIR/waits/q1/$(date +%s).$$.tmp.$$"
  AGENTLOCK_OWNER=B $L acquire q1 --ttl 1m >/dev/null 2>&1; check "a half-written ticket in progress does not count as a waiter" $? 0
  [ -n "$(ls "$AGENTLOCK_DIR/waits/q1")" ] && ok "a young half-written ticket is left for its writer" || bad "young tmp ticket removed"
  rm -f "$AGENTLOCK_DIR/waits/q1/"*; AGENTLOCK_OWNER=B $L release q1 >/dev/null
  # The headline property, deterministically: an older live ticket on a free resource makes a waiter defer until it is gone.
  printf 'owner=O\npid=%s\nsince=1\nexpires=%s\nreason=older\n' "$$" "$(( $(date +%s) + 600 ))" > "$AGENTLOCK_DIR/waits/q1/0000000001.$$"
  ( AGENTLOCK_POLL=1 AGENTLOCK_OWNER=W4 $L acquire q1 --ttl 1m --wait 30s >/dev/null 2>&1; echo $? > "$work/w4.rc" ) & wq4=$!
  sleep 2.5; [ ! -d "$AGENTLOCK_DIR/locks/q1" ] && [ "$(ls "$AGENTLOCK_DIR/waits/q1" | wc -l | tr -d ' ')" = 2 ] && ok "a waiter defers to an older live ticket on a free resource, holding its own" || bad "deferral: lock=$(ls -d "$AGENTLOCK_DIR/locks/q1" 2>/dev/null) tickets=$(ls "$AGENTLOCK_DIR/waits/q1")"
  rm -f "$AGENTLOCK_DIR/waits/q1/0000000001.$$"; sleep 2.5
  [ "$(cat "$work/w4.rc" 2>/dev/null)" = 0 ] && $L status q1 | grep -q "^q1: owner=W4 " && ok "the waiter takes the lock once the older ticket is gone" || bad "after older ticket gone: $(cat "$work/w4.rc" 2>/dev/null) $($L status q1)"
  wait $wq4 2>/dev/null; AGENTLOCK_OWNER=W4 $L release q1 >/dev/null
  # with --wait behind a holder: once it has the lock, its ticket is gone while the command runs.
  AGENTLOCK_OWNER=A $L acquire q1 --ttl 1m >/dev/null
  ( AGENTLOCK_POLL=1 AGENTLOCK_OWNER=W5 $L with q1 --ttl 1m --wait 30s -- sleep 6 >/dev/null 2>&1 ) & wq5=$!
  sleep 1.5; AGENTLOCK_OWNER=A $L release q1 >/dev/null; sleep 2.5
  $L status q1 | grep -q "^q1: owner=W5 " && ! $L status q1 | grep -q "waiting on q1" && ok "with --wait drops its ticket when it takes the lock, while its command runs" || bad "with ticket: $($L status q1)"
  wait $wq5 2>/dev/null
  # A waiter blocked by someone else's quiet takes its ticket too: after the measurement, a newcomer's plain acquire is refused.
  AGENTLOCK_OWNER=Q $L acquire quiet --ttl 1m >/dev/null
  ( AGENTLOCK_POLL=1 AGENTLOCK_OWNER=W6 $L acquire q1 --ttl 1m --wait 30s >/dev/null 2>&1; echo $? > "$work/w6.rc" ) & wq6=$!
  sleep 2.5; [ -n "$(ls "$AGENTLOCK_DIR/waits/q1" 2>/dev/null)" ] && ok "a waiter blocked by a quiet holds a ticket" || bad "no ticket under quiet"
  AGENTLOCK_OWNER=Q $L release quiet >/dev/null; AGENTLOCK_OWNER=N $L acquire q1 --ttl 1m >/dev/null 2>&1; check "after the measurement a newcomer's plain acquire is refused, the waiter is first" $? 1
  sleep 2.5; [ "$(cat "$work/w6.rc" 2>/dev/null)" = 0 ] && ok "the waiter that waited through the quiet gets the lock" || bad "w6: $(cat "$work/w6.rc" 2>/dev/null) $($L status)"
  wait $wq6 2>/dev/null; AGENTLOCK_OWNER=W6 $L release q1 >/dev/null
  $L clean >/dev/null; check "clean exits 0 with waits/ present" $? 0
  rm -rf "$AGENTLOCK_DIR/waits"; $L clean >/dev/null; check "clean exits 0 without waits/" $? 0
  mkdir -p "$AGENTLOCK_DIR/waits"; printf 'owner=agentlock-0.4.0-marker\nacquired=1\nexpires=0\nreason=not-a-lock\n' > "$AGENTLOCK_DIR/waits/info"   # the marker present, as after any wait
  AGENTLOCK_OWNER=A $L acquire waits --ttl 1m >/dev/null 2>&1; check "a resource named waits is an ordinary lock, marker present" $? 0; AGENTLOCK_OWNER=A $L release waits >/dev/null
  # The holder's own re-acquire with a live ticket in line; a waiter behind a pre-0.4.0 lock holds a ticket whose expiry is its deadline.
  AGENTLOCK_OWNER=A $L acquire q1 --ttl 1m >/dev/null; mkdir -p "$AGENTLOCK_DIR/waits/q1"; printf 'owner=O\npid=%s\nsince=1\nexpires=%s\nreason=older\n' "$$" "$(( $(date +%s) + 600 ))" > "$AGENTLOCK_DIR/waits/q1/0000000001.$$"
  AGENTLOCK_OWNER=A $L acquire q1 --ttl 1m 2>&1 | grep -q "already held q1" && ok "the holder's re-acquire ignores a live ticket in line" || bad "holder refused by the line: $(AGENTLOCK_OWNER=A $L acquire q1 --ttl 1m 2>&1)"
  rm -f "$AGENTLOCK_DIR/waits/q1/"*; AGENTLOCK_OWNER=A $L release q1 >/dev/null
  mkdir -p "$AGENTLOCK_DIR/lg1"; printf 'owner=old\npid=%s\nacquired=%s\nexpires=%s\nreason=legacy\n' "$$" "$(date +%s)" "$(( $(date +%s) + 600 ))" > "$AGENTLOCK_DIR/lg1/info"   # a pre-0.4.0 lock held by a live pid
  ( AGENTLOCK_POLL=1 AGENTLOCK_OWNER=W7 exec $L acquire lg1 --ttl 1m --wait 20s >/dev/null 2>&1 ) & wq7=$!   # exec: the kill below reaches the tool itself
  sleep 2.5; t7=$(ls "$AGENTLOCK_DIR/waits/lg1" 2>/dev/null | head -1)
  [ -n "$t7" ] && ok "a waiter behind a pre-0.4.0 lock holds a ticket" || bad "no ticket behind a legacy lock"
  e7=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/waits/lg1/$t7" 2>/dev/null); nowq=$(date +%s)
  [ -n "$e7" ] && [ "$e7" -gt $(( nowq + 10 )) ] && [ "$e7" -le $(( nowq + 20 )) ] && ok "a waiter's own ticket expires with its wait" || bad "ticket expiry: $e7 vs now $nowq"
  kill -TERM $wq7 2>/dev/null; wait $wq7 2>/dev/null; sleep 1; rm -rf "$AGENTLOCK_DIR/lg1" "$AGENTLOCK_DIR/waits/lg1"
  mkdir -p "$AGENTLOCK_DIR/waits/x.tmp.y"; printf 'owner=O\npid=%s\nsince=1\nexpires=%s\nreason=r\n' "$$" "$(( $(date +%s) + 600 ))" > "$AGENTLOCK_DIR/waits/x.tmp.y/0000000001.$$"; touch -t 202001010000 "$AGENTLOCK_DIR/waits/x.tmp.y/0000000001.$$"
  AGENTLOCK_OWNER=B $L acquire x.tmp.y --ttl 1m >/dev/null 2>&1; check "a resource whose name holds .tmp. keeps its tickets: the plain acquire is refused" $? 1; rm -rf "$AGENTLOCK_DIR/waits/x.tmp.y"
  # A waiter whose shell is killed leaves no ticket: its own trap, or the next party's reaping.
  AGENTLOCK_OWNER=A $L acquire q1 --ttl 1m >/dev/null
  ( AGENTLOCK_POLL=1 AGENTLOCK_OWNER=W3 exec $L acquire q1 --ttl 1m --wait 40s >/dev/null 2>&1 ) & wq3=$!
  sleep 1.5; [ -n "$(ls "$AGENTLOCK_DIR/waits/q1" 2>/dev/null)" ] && ok "a waiting acquire holds a ticket" || bad "no ticket while waiting"
  kill -TERM $wq3 2>/dev/null; wait $wq3 2>/dev/null; sleep 1
  [ -z "$(ls "$AGENTLOCK_DIR/waits/q1" 2>/dev/null)" ] && ok "a killed waiter's ticket is gone" || bad "ticket left by a killed waiter: $(ls "$AGENTLOCK_DIR/waits/q1")"
  AGENTLOCK_OWNER=A $L acquire q1 --ttl 1m >/dev/null 2>&1; check "the holder's own re-acquire ignores the line" $? 0
  AGENTLOCK_OWNER=A $L release q1 >/dev/null
  # A re-acquire of an own lock refreshes but never shortens: with 1 h left, --ttl 1m leaves the expiry; --ttl 2h moves it out.
  AGENTLOCK_OWNER=A $L acquire ra --ttl 1h >/dev/null; e1=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/locks/ra/info")
  out=$(AGENTLOCK_OWNER=A $L acquire ra --ttl 1m); rc=$?; e2=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/locks/ra/info")
  [ $rc = 0 ] && [ "$e2" = "$e1" ] && printf '%s' "$out" | grep -q "never shortens a lock, renew extends it" && ok "re-acquire with a shorter ttl keeps the expiry and says so" || bad "shorter re-acquire: rc=$rc $e1 -> $e2: $out"
  out=$(AGENTLOCK_OWNER=A $L acquire ra --ttl 2h); e3=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/locks/ra/info")
  [ "$e3" -gt "$e1" ] && printf '%s' "$out" | grep -q "ttl refreshed to 7200s" && ok "re-acquire with a longer ttl moves the expiry out" || bad "longer re-acquire: $e1 -> $e3: $out"
  out=$(AGENTLOCK_OWNER=A $L acquire ra --ttl 0); e4=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/locks/ra/info")
  [ "$e4" = 0 ] && printf '%s' "$out" | grep -q "now with no expiry" && ok "re-acquire with --ttl 0 extends a timed lock to no expiry" || bad "ttl 0 re-acquire: $e4: $out"
  out=$(AGENTLOCK_OWNER=A $L acquire ra --ttl 1m); e5=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/locks/ra/info")
  [ "$e5" = 0 ] && printf '%s' "$out" | grep -q "no expiry (kept" && ok "re-acquire of a lock without expiry keeps it so" || bad "unlimited re-acquire: $e5: $out"
  # A stale own lock (anchor pid dead, same owner after a resume) is not kept: the re-acquire rewrites it, so it is live again.
  AGENTLOCK_OWNER=A $L release ra >/dev/null; AGENTLOCK_OWNER=A $L acquire ra --ttl 1h >/dev/null; sed -i.bak 's/^pid=.*/pid=4194300/' "$AGENTLOCK_DIR/locks/ra/info"; rm -f "$AGENTLOCK_DIR/locks/ra/info.bak"
  grep -q '^ttl=3600$' "$AGENTLOCK_DIR/locks/ra/info" || bad "stale fixture is not a fresh 1 h lock"
  out=$(AGENTLOCK_OWNER=A $L acquire ra --ttl 10m); rc=$?
  [ $rc = 0 ] && printf '%s' "$out" | grep -q "ttl refreshed to 600s" && AGENTLOCK_OWNER=A $L check ra >/dev/null 2>&1 && ! AGENTLOCK_OWNER=B $L acquire ra --ttl 1m >/dev/null 2>&1 && ok "a stale own lock is rewritten by a re-acquire, not kept: it is held again and refused to others" || bad "stale own re-acquire: rc=$rc $out / $($L status 2>&1 | grep ra)"
  AGENTLOCK_OWNER=A $L release ra >/dev/null
  h=$($L --help); printf '%s' "$h" | grep -q "never shortens it" && printf '%s' "$h" | tail -1 | grep -q "^  AGENTLOCK_AS=<name> agentlock" && ok "agentlock --help prints the whole header, to its AGENTLOCK_AS line" || bad "agentlock --help last line: $(printf '%s' "$h" | tail -1)"
  AGENTLOCK_OWNER=A $L acquire ui --ttl 1m >/dev/null; AGENTLOCK_OWNER=A $L acquire "orphan$$" --ttl 1m >/dev/null
  ( AGENTLOCK_POLL=1 AGENTLOCK_OWNER=W exec bash -c "$L acquire orphan$$ --wait 30s >/dev/null 2>&1; echo waiter-exit=\$? > '$work/waiter.rc'" ) & wsh=$!
  sleep 1.5; { kill -KILL $wsh; wait $wsh; } 2>/dev/null; sleep 3
  pgrep -f "agentlock acquire orphan$$ --wait 30s$" >/dev/null && bad "an orphaned --wait kept waiting" || ok "an orphaned --wait gives up when its shell is gone"
  pkill -f "agentlock acquire orphan$$ --wait 30s$" 2>/dev/null
  # A wait started detached, `( … & )`, has no shell from the start: it gives up at its first poll instead of waiting its limit.
  # The child starts a second after its subshell has exited, so the waiter is reparented before bash reads its parent
  # (a `while kill -0 $PPID` loop would not do: in sh, PPID follows the reparenting to pid 1, which is alive).
  ( sh -c 'sleep 1; exec env AGENTLOCK_POLL=1 AGENTLOCK_OWNER=W "$0" acquire "$1" --wait 25s >/dev/null 2>&1' "$L" "orphan$$" & ); sleep 4
  pgrep -f "agentlock acquire orphan$$ --wait 25s$" >/dev/null && bad "a detached --wait kept waiting" || ok "a detached --wait gives up at once"
  pkill -f "agentlock acquire orphan$$ --wait 25s$" 2>/dev/null; AGENTLOCK_OWNER=A $L release ui >/dev/null; AGENTLOCK_OWNER=A $L release "orphan$$" >/dev/null
  AGENTLOCK_OWNER=A $L release sim:w >/dev/null
  AGENTLOCK_OWNER=A $L with sim:w --wait --ttl 1m -- true >/dev/null 2>&1; check "with: a bare --wait is accepted" $? 0
  cp "$here/hooks/guard.conf.example" "$AGENTLOCK_DIR/guard.conf"; mkdir -p "$AGENTLOCK_DIR/locks"; touch "$AGENTLOCK_DIR/locks/afile"
  AGENTLOCK_OWNER=A $L acquire afile --ttl 1m >/dev/null 2>&1; check "a name that is a file is refused" $? 1
  [ -f "$AGENTLOCK_DIR/locks/afile" ] && ok "the file survives" || bad "the file was deleted"; rm -f "$AGENTLOCK_DIR/locks/afile"
  [ -f "$AGENTLOCK_DIR/guard.conf" ] && ok "guard.conf untouched by acquire" || bad "guard.conf gone"
  AGENTLOCK_OWNER=A $L acquire r --ttl 1m --reason "$(printf 'x\nexpires=0')" >/dev/null; grep -q '^expires=0$' "$AGENTLOCK_DIR/locks/r/info" && bad "reason injected a key" || ok "newline in reason stripped"
  AGENTLOCK_OWNER=A $L release r >/dev/null
  AGENTLOCK_OWNER=A $L acquire ui --ttl 1m >/dev/null; AGENTLOCK_OWNER=A $L with ui -- true; check "with on a held resource runs" $? 0; AGENTLOCK_OWNER=A $L check ui; check "with on a held resource keeps the outer lock" $? 0
  e1=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/locks/ui/info"); sleep 2; AGENTLOCK_OWNER=A $L with ui -- true; e2=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/locks/ui/info")
  [ "$e2" -ge $(( e1 + 2 )) ] && ok "with on a held resource extends it (quiet is extended this way, not by the guard)" || bad "with on a held resource left the expiry at $e1 -> $e2"
  AGENTLOCK_OWNER=A $L release ui >/dev/null
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b1 $L acquire quiet --ttl 1m >/dev/null; AGENTLOCK_OWNER=S $L acquire ui --ttl 1m >/dev/null 2>&1; check "a builder's quiet blocks its own session's other owners too (five overlaps in one shift)" $? 1
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b2 $L acquire sim:q --ttl 1m >/dev/null 2>&1; check "a builder's quiet blocks a sibling builder" $? 1
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b1 $L acquire sim:q --ttl 1m >/dev/null 2>&1; check "the quiet holder itself may still take what it needs" $? 0
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b1 $L release sim:q >/dev/null
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b1 $L release quiet >/dev/null; AGENTLOCK_OWNER=S AGENTLOCK_AS=b2 $L acquire sim:q --ttl 1m >/dev/null
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b1 $L acquire quiet --ttl 1m >/dev/null 2>&1; check "quiet waits for a sibling builder's lock as for another session's" $? 1
  # Both locks at once (a race or an expiry, never the normal path): the sibling's with on its own lock is refused under the quiet.
  mv "$AGENTLOCK_DIR/locks/sim:q" "$work/hidden"; AGENTLOCK_OWNER=S AGENTLOCK_AS=b1 $L acquire quiet --ttl 1m >/dev/null; mv "$work/hidden" "$AGENTLOCK_DIR/locks/sim:q"
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b2 $L with sim:q -- true 2>/dev/null; check "with on a lock held across a sibling's quiet is refused" $? 1
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b2 $L release sim:q >/dev/null
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b2 $L free quiet; check "free: quiet held by a sibling is not free" $? 1
  AGENTLOCK_OWNER=S AGENTLOCK_AS=b1 $L free quiet; check "free: my own lock counts as free for me" $? 0
  AGENTLOCK_OWNER=S $L free sim:nothing; check "free: an untaken resource is free" $? 0
  AGENTLOCK_OWNER=S $L status >/dev/null; check "status is a report: exit 0 with locks held" $? 0
  v=$(jq -r .version "$here/.claude-plugin/plugin.json")   # an oracle independent of the tool's own reading
  [ -n "$v" ] && [ "$($L version)" = "$v" ] && ok "version prints the manifest's version ($v)" || bad "version printed '$($L version)', manifest says '$v'"
  [ "$($L --version)" = "$v" ] && ok "--version is the same" || bad "--version differs"
  mkdir -p "$work/vt/scripts" "$work/vt/.claude-plugin"; cp "$L" "$work/vt/scripts/agentlock"; printf '{"name":"x","author":{"name":"a","version":"9.9.9"},"version":"1.2.3"}\n' > "$work/vt/.claude-plugin/plugin.json"
  [ "$("$work/vt/scripts/agentlock" version)" = "1.2.3" ] && ok "version reads the top-level key, not a nested one" || bad "version read '$("$work/vt/scripts/agentlock" version)' from a manifest with a nested version"
  printf '{"name":"x"}\n' > "$work/vt/.claude-plugin/plugin.json"; out=$("$work/vt/scripts/agentlock" version); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q '^unknown (no version' && ok "version without a version key says unknown and exits 1" || bad "version on a manifest without the key: rc=$rc '$out'"
  rm -rf "$work/vt/.claude-plugin"; out=$("$work/vt/scripts/agentlock" version); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q '^unknown (no plugin.json' && ok "version without a manifest says unknown and exits 1" || bad "version without a manifest: rc=$rc '$out'"
  AGENTLOCK_OWNER=S $L release-all >/dev/null
fi

if run guard; then echo "guard"
  cp "$here/hooks/guard.conf.example" "$AGENTLOCK_DIR/guard.conf"
  g() { printf '%s' "{\"session_id\":\"$1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$2${3:+,\"run_in_background\":$3}}}" | $L guard >/dev/null 2>&1; echo $?; }
  gm() { printf '%s' "{\"session_id\":\"$1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$2}}" | $L guard 2>&1 >/dev/null | sed -n 's/.*needs a lock on: *//p' | head -1; }   # which locks a block names
  # Built-in rules, no config: the watcher must be a background command; no wait loop on pgrep.
  check "watcher in a plain call is blocked" "$(g Z '"python3 /p/scripts/watch-github.py --role engineering --exit-on-input --max-minutes 110"')" 2
  check "watcher with & in a plain call is blocked" "$(g Z '"( python3 /p/scripts/watch-github.py --role engineering --exit-on-input & )"')" 2
  check "watcher as a background command passes" "$(g Z '"python3 /p/scripts/watch-github.py --role engineering --exit-on-input --max-minutes 110"' true)" 0
  check "watcher --once in a plain call passes" "$(g Z '"python3 /p/scripts/watch-github.py --role engineering --once"')" 0
  check "a pgrep for the watcher inside a kill loop is a mention, not a start" "$(g Z '"for p in $(pgrep -f \"watch-github.py --role engineering\"); do kill $p; done"')" 0
  check "a one-shot kill loop over pgrep is a cleanup, not a wait" "$(g Z '"for p in $(pgrep -f /x/run.sh); do kill $p; done"')" 0
  check "a TERM loop, a sleep, then a KILL loop are two cleanups, not one wait" "$(g Z '"for p in $(pgrep -f /x/run.sh); do kill -TERM $p; done; sleep 2; for p in $(pgrep -f /x/run.sh); do kill -KILL $p; done"')" 0
  check "a while loop that sleeps before its pgrep is a wait" "$(g Z '"while :; do sleep 2; pgrep -f /x/run.sh || break; done"')" 2
  check "a busy while loop on pgrep is a wait" "$(g Z '"while [ -n \"$(pgrep -f /x/run.sh)\" ]; do :; done"')" 2
  check "a wait loop over pgrep that sleeps is still blocked" "$(g Z '"for i in 1 2 3; do pgrep -f /x/run.sh || break; sleep 3; done"')" 2
  check "a watcher start after a semicolon is a start" "$(g Z '"cd /r; python3 scripts/watch-github.py --role engineering --exit-on-input"')" 2
  check "a watcher start by path without python is a start" "$(g Z '"/p/scripts/watch-github.py --role design --exit-on-input"')" 2
  check "reading the watcher file passes" "$(g Z '"sed -n 1,40p scripts/watch-github.py"')" 0
  check "a wait loop on pgrep is blocked" "$(g Z '"until ! pgrep -f /x/run.sh >/dev/null; do sleep 3; done"')" 2
  check "a while loop on pgrep is blocked" "$(g Z '"while pgrep -qf /x/run.sh; do sleep 5; done"')" 2
  check "a quoted pgrep in a loop test is blocked" "$(g Z '"until [ -z \"$(pgrep -f /x/run.sh)\" ]; do sleep 3; done"')" 2
  check "a multi-line loop on pgrep is blocked" "$(g Z '"while true; do\n  pgrep -f /x/run.sh || break\n  sleep 3\ndone"')" 2
  check "a for loop on pgrep is blocked" "$(g Z '"for i in $(seq 1 200); do pgrep -f /x/run.sh || break; sleep 3; done"')" 2
  check "grep for the watcher command passes" "$(g Z '"grep -n watch-github.py --role scripts/*.md"')" 0
  check "echo of the watcher command into a note passes" "$(g Z '"echo python3 w/watch-github.py --role engineering >> notes.md"')" 0
  check "a quoted watcher start in a plain call is blocked" "$(g Z '"bash -c \"python3 /p/scripts/watch-github.py --role engineering --exit-on-input\" &"')" 2
  check "a start by a path with an x in it is a start (0.4.14's regex stopped at x, 2, 7)" "$(g Z '"python3 /Users/max/proj/scripts/watch-github.py --role engineering --exit-on-input"')" 2
  check "a start by a quoted path is a start" "$(g Z '"python3 \"$PLUGIN/scripts/watch-github.py\" --role engineering --exit-on-input"')" 2
  check "a start inside a single-quoted bash -c string is a start" "$(g Z "\"bash -c 'python3 /p/scripts/watch-github.py --role engineering'\"")" 2
  check "a start with a python option is a start" "$(g Z '"python3 -u /p/scripts/watch-github.py --role design --exit-on-input"')" 2
  check "a start under caffeinate -i is a start" "$(g Z '"caffeinate -i python3 /p/scripts/watch-github.py --role design"')" 2
  check "a start through uv run is a start" "$(g Z '"uv run scripts/watch-github.py --role design"')" 2
  check "a start on the second line of a call is a start (round 2: the newline was folded to a space)" "$(g Z '"export WATCH_LOG=/tmp/w.log\npython3 scripts/watch-github.py --role engineering --exit-on-input"')" 2
  check "a read-only first line does not shield a start on the second" "$(g Z '"echo hi\npython3 scripts/watch-github.py --role engineering"')" 2
  check "a start by a path quoted in part is a start" "$(g Z '"python3 \"$PLUGIN\"/scripts/watch-github.py --role engineering --exit-on-input"')" 2
  check "a start inside bash -lc is a start" "$(g Z '"bash -lc \"python3 /p/scripts/watch-github.py --role engineering\""')" 2
  check "a backslash-continued start is one start" "$(g Z '"python3 scripts/watch-github.py \\\n  --role engineering --exit-on-input"')" 2
  check "an apostrophe in a comment does not hide the start on the next line" "$(g Z "\"# it's time\npython3 /p/scripts/watch-github.py --role engineering\"")" 2
  check "the start command quoted on its own line in a commit message is a mention" "$(g Z '"git commit -m \"line one\npython3 scripts/watch-github.py --role x\""')" 0
  check "the start command quoted on its own line in an issue body is a mention" "$(g Z "\"gh issue comment 5 --body 'start it:\npython3 scripts/watch-github.py --role engineering'\"")" 0
  check "nice before acquire still grants" "$(g Z '"nice agentlock acquire sim:x --ttl 1m && xcrun simctl boot X"')" 0
  check "the start command inside a heredoc body is text (a README written with cat <<EOF)" "$(g Z "\"cat > README.md <<'EOF'\n## Watcher\n\npython3 scripts/watch-github.py --role engineering --exit-on-input --max-minutes 110\nEOF\"")" 0
  check "a <<- body with a tabbed terminator is text" "$(g Z '"cat <<-EOF > n.md\n\tpython3 scripts/watch-github.py --role engineering\n\tEOF"')" 0
  check "a start after a heredoc with an apostrophe in its body is a start" "$(g Z '"cat <<EOF > n.md\nit'"'"'s\nEOF\npython3 scripts/watch-github.py --role engineering"')" 2
  check "a start under timeout is a start" "$(g Z '"timeout 600 python3 /p/scripts/watch-github.py --role engineering"')" 2
  check "a start inside a shell named by path with -c is a start" "$(g Z '"/bin/bash -c \"python3 /p/scripts/watch-github.py --role engineering\""')" 2
  check "a start after a heredoc with a quoted delimiter is a start (the closing quote is the delimiter's)" "$(g Z "\"cat > n.md <<'EOF'\nline one\nEOF\npython3 /p/scripts/watch-github.py --role engineering\"")" 2
  check "a quoted-delimiter body with an apostrophe is blanked, not folded" "$(g Z "\"cat > n.md <<'EOF'\nIt's here:\npython3 scripts/watch-github.py --role engineering\nEOF\"")" 0
  check "a here-string is not a heredoc opener" "$(g Z '"grep x <<< foo\npython3 /p/scripts/watch-github.py --role engineering"')" 2
  check "a start under timeout with a valued option is a start" "$(g Z '"timeout -k 5 600 python3 /p/scripts/watch-github.py --role engineering"')" 2
  check "a macOS test run without ui is blocked, for ui alone" "$(gm Z '"xcodebuild -scheme X -destination platform=macOS test"')" "ui"
  check "a read-only first command does not shield a watcher start after it" "$(g Z '"echo starting; ( python3 /p/scripts/watch-github.py --role engineering --exit-on-input & )"')" 2
  check "a read-only first command does not shield a pgrep loop after it" "$(g Z '"ls >/dev/null; until ! pgrep -f /x/run.sh; do sleep 3; done"')" 2
  check "a loop followed by a pgrep listing on the next line passes" "$(g Z '"for f in a.png b.png; do cp $f out/; done\npgrep -fl watch-github"')" 0
  check "a comment with the word for, then a pgrep listing, passes" "$(g Z '"cd /r  # check for leftovers\npgrep -fl run.sh"')" 0
  check "a test run with no destination needs sim alone" "$(gm Z '"xcodebuild -scheme X test"')" "sim"
  check "a test run followed by a pipe still needs sim" "$(gm Z '"xcodebuild -scheme X test | xcpretty"')" "sim"
  check "a backslash-continued simulator test run needs sim" "$(gm Z '"xcodebuild -scheme X \\\n  -destination \"platform=iOS Simulator,name=iPhone 16e\" \\\n  test"')" "sim"
  check "a backslash-continued macOS test run (test on line 1) needs ui alone" "$(gm Z '"xcodebuild test -project P.xcodeproj \\\n  -destination platform=macOS"')" "ui"
  check "a trailing backslash inside a quoted heredoc body does not swallow the terminator" "$(g Z '"cat > n.md <<'"'"'EOT'"'"'\nnote: use xcrun simctl boot \\\nEOT\necho done"')" 0
  check "an escaped backslash at the end of a line is not a continuation" "$(gm Z '"xcodebuild -scheme X\\\\\ntest"')" ""
  check "a heredoc opened on a continued line still joins with the next line" "$(gm Z '"cat <<EOT \\\n| osascript\nactivate\nEOT\necho done"')" "ui"
  check "a heredoc opener inside quotes does not stop later joins" "$(gm Z '"echo \"<<EOT\" > x\nxcodebuild -scheme X \\\n  test"')" "sim"
  check "a here-string is not a heredoc opener and does not stop later joins" "$(gm Z '"grep x <<< foo\nxcodebuild -scheme X \\\n  test"')" "sim"
  # Config rules see only the segments that run something; acquire && command grants the lock for the line.
  check "a grep whose pattern names tools is text, not a tool" "$(g Z '"ps -axo pid,command | grep devicectl device install"')" 0   # unquoted: the guard cuts a quoted string to its first word
  check "an echo that names a tool is text" "$(g Z '"echo xcrun devicectl device install app"')" 0
  check "a tool after a text segment still needs its lock" "$(gm Z '"grep foo log; xcrun devicectl device install app --device 1 x.app"')" "device"
  check "devicectl list needs no lock" "$(g Z '"xcrun devicectl list devices"')" 0
  check "devicectl device info needs no lock" "$(g Z '"xcrun devicectl device info details --device 00008130"')" 0
  check "devicectl device process launch needs the device" "$(gm Z '"xcrun devicectl device process launch --device 00008130 com.x.app"')" "device"
  check "devicectl manage needs the device" "$(gm Z '"xcrun devicectl manage pair --device 00008130"')" "device"
  check "an option between devicectl and its verb still needs the device" "$(gm Z '"xcrun devicectl -v device install app --device 00008130 x.app"')" "device"
  check "options with values between devicectl and its verb still need the device" "$(gm Z '"xcrun devicectl -j out.json --timeout 5 device install app --device 00008130 x.app"')" "device"
  check "options before a read still need nothing" "$(g Z '"xcrun devicectl -j out.json device info details --device 00008130"')" 0
  check "an option value starting with s is a value, not the end of the match" "$(gm Z '"xcrun devicectl -j status.json device install app --device 00008130 x.app"')" "device"
  check "an option value with an escaped space is one value" "$(gm Z '"xcrun devicectl -j out\\ file.json device install app --device 00008130 x.app"')" "device"
  check "a read, then acquire && an acting verb: the read needs nothing and the chain is granted" "$(g Z '"xcrun devicectl list devices; agentlock acquire device:00008130 --ttl 10m --reason x && xcrun devicectl device install app --device 00008130 x.app"')" 0
  check "text piped into a shell keeps every segment" "$(gm Z '"echo xcrun simctl boot X | sh"')" "sim"
  check "acquire && command needs no lock held yet" "$(g Z '"agentlock acquire device:00008130 --ttl 30m --reason install && xcrun devicectl device install app --device 00008130 x.app"')" 0
  check "acquire ; command is not a grant" "$(gm Z '"agentlock acquire device:00008130 --ttl 30m; xcrun devicectl device install app --device 00008130 x.app"')" "device"
  check "acquire of another resource && command still needs the right lock" "$(gm Z '"agentlock acquire sim:x --ttl 30m && xcrun devicectl device install app --device 1 x.app"')" "device"
  check "a command substitution inside an echo still runs a tool" "$(gm Z '"echo $(xcrun simctl boot X)"')" "sim"
  check "a backtick substitution inside a head still runs a tool" "$(gm Z '"head -1 `xcrun devicectl device install app --device 1 x.app`"')" "device"
  check "a process substitution inside a cat still runs a tool" "$(gm Z '"cat <(xcrun simctl boot X)"')" "sim"
  check "a grant does not reach back before the acquire" "$(gm Z '"xcrun simctl boot X; agentlock acquire sim:x --ttl 1m && true"')" "sim"
  check "a grant ends at the semicolon" "$(gm Z '"agentlock acquire sim:x --ttl 1m && echo ok; xcrun simctl boot X"')" "sim"
  check "a grant ends at ||" "$(gm Z '"agentlock acquire sim:x --ttl 1m && true || xcrun simctl boot X"')" "sim"
  check "the word agentlock inside an echo grants nothing" "$(gm Z '"echo agentlock acquire sim:x --ttl 1m && xcrun simctl boot X"')" "sim"
  check "a command merely ending in agentlock grants nothing" "$(gm Z '"notagentlock acquire sim:x --ttl 1m && xcrun simctl boot X"')" "sim"
  check "acquire piped somewhere grants nothing" "$(gm Z '"agentlock acquire sim:x --ttl 1m | tee log && xcrun simctl boot X"')" "sim"
  check "with X -- command piped into a filter is granted X" "$(g Z '"agentlock with device:00008130 -- xcrun devicectl device install app --device 1 x.app | grep iPhone"')" 0
  check "with X grants only X" "$(gm Z '"agentlock with sim:x -- xcrun devicectl device install app --device 1 x.app | grep iPhone"')" "device"
  check "a with grant ends at the && after its chain (with releases X there)" "$(gm Z '"agentlock with sim:x -- xcrun simctl boot X && xcodebuild test -scheme X -destination \"platform=iOS Simulator,name=iPhone 16e\""')" "sim"
  check "with --ttl before the resource grants the resource" "$(g Z '"agentlock with --ttl 1m sim:x -- xcrun simctl boot X | cat"')" 0
  check "acquire --ttl before the resource grants the resource" "$(g Z '"agentlock acquire --ttl 1m sim:x && xcrun simctl boot X"')" 0
  check "a grant is void when the same rule matched before the acquire in the chain" "$(gm Z '"xcrun simctl boot X && agentlock acquire sim:x --ttl 1m && xcrun simctl boot Y"')" "sim"
  check "a grant after an unrelated command in the chain holds" "$(g Z '"cd /tmp && agentlock acquire sim:x --ttl 1m && xcrun simctl boot X"')" 0
  check "text piped into dash keeps every segment" "$(gm Z '"echo xcrun simctl boot X | dash"')" "sim"
  check "a command substitution inside double quotes runs a tool" "$(gm Z '"udid=\"$(xcrun simctl boot test)\"; echo $udid"')" "sim"
  check "a quoted destination inside a quoted substitution is still a test run" "$(gm Z '"out=\"$(xcodebuild -scheme X -destination \"platform=iOS Simulator,name=iPhone 16e\" test)\""')" "sim"
  check "a quoted macOS destination inside a quoted substitution needs ui" "$(gm Z '"out=\"$(xcodebuild -scheme X -destination \"platform=macOS\" test 2>&1)\""')" "ui"
  check "prose around a substitution stays data" "$(g Z '"gh issue comment 5 --body \"$(date): use xcrun simctl boot\""')" 0
  check "an agentlock acquire inside an echoed substitution string grants nothing" "$(gm Z '"echo \"$(date) && agentlock acquire sim:x --ttl 1m\" && xcrun simctl boot X"')" "sim"
  check "an escaped dollar-paren is literal" "$(g Z '"echo \"cost \\$(xcrun simctl boot X) dollars\""')" 0
  check "arithmetic expansion is not a substitution" "$(g Z '"echo \"$(( devicectl ))\""')" 0
  check "a substitution nested in arithmetic is lifted" "$(gm Z '"x=\"$(( $(xcrun simctl boot X | wc -l) + 1 ))\""')" "sim"
  check "a quoted substitution inside backticks is lifted" "$(gm Z '"echo \"`echo \"$(xcrun simctl boot X)\"`\""')" "sim"
  check "a backtick span ending mid-string cannot hide the next statement" "$(gm Z '"echo \"`echo \"a`\" ; xcrun simctl boot X ; echo \"b\""')" "sim"
  check "a substitution with nested quotes is read to its end" "$(gm Z '"echo \"$(xcrun simctl boot \"iPhone 16e\") done\""')" "sim"
  check "an apostrophe in double quotes does not hide a later quoted substitution" "$(gm Z '"git commit -m \"don'"'"'t break\" && out=\"$(xcodebuild -scheme X test)\""')" "sim"
  check "an apostrophe in a comment does not hide a quoted substitution on the next line" "$(gm Z '"cd /r  # it'"'"'s here\nudid=\"$(xcrun simctl boot X)\""')" "sim"
  check "a backslash inside single quotes is literal and the quote closes" "$(gm Z '"printf '"'"'%s\\n'"'"' '"'"'a\\'"'"'; udid=\"$(xcrun simctl boot X)\""')" "sim"
  check "ANSI-C quoting with an escaped apostrophe does not hide a later substitution" "$(gm Z '"git commit -m $'"'"'Fix it\\'"'"'s thing'"'"' && out=\"$(xcodebuild -scheme X test)\""')" "sim"
  check "a comment with an apostrophe inside a multi-line quoted substitution" "$(gm Z '"out=\"$(\n# don'"'"'t boot twice\nxcrun simctl boot X\n)\""')" "sim"
  check "a comment with a stray parenthesis inside a quoted substitution" "$(gm Z '"out=\"$(\n# note: a) b\nxcrun simctl boot X\n)\""')" "sim"
  check "an unclosed quoted substitution cannot pair its quote with the lifted text" "$(gm Z '"echo \"$(xcrun simctl boot X ; echo \"done\""')" "sim"
  check "a comment after a closing parenthesis is a comment" "$(gm Z '"(cd /tmp; ls)# it'"'"'s\nudid=\"$(xcrun simctl boot X)\""')" "sim"
  check "a substitution inside a comment runs nothing" "$(g Z '"ls  # $(xcrun simctl boot X)"')" 0
  check "a tool named in a comment runs nothing" "$(g Z '"echo a;#comment xcrun simctl boot X"')" 0
  deep=$(python3 -c 'print("$(" * 1500 + "xcrun simctl boot X" + ")" * 1500)')
  check "pathological nesting that breaks the preprocessing falls back to the raw command, not to allowing" "$(gm Z "\"$deep\"")" "sim"
  check "a backtick substitution inside double quotes runs a tool" "$(gm Z '"echo \"`xcrun simctl boot X`\""')" "sim"
  check "a quoted substitution of a test run needs its lock" "$(gm Z '"out=\"$(xcodebuild -scheme X -destination id=Y test)\""')" "sim"
  check "a quoted substitution without a tool stays allowed" "$(g Z '"git commit -m \"built at $(date)\""')" 0
  check "a single-quoted substitution is data" "$(g Z '"echo '"'"'$(xcrun simctl boot X)'"'"'"')" 0
  check "text piped into nice sh keeps every segment" "$(gm Z '"echo xcrun simctl boot X | nice sh"')" "sim"
  check "a simulator-destination test run needs sim" "$(g Z '"xcodebuild -scheme X -destination \"platform=iOS Simulator,name=iPhone 16e\" test"')" 2
  check "a test run with a build setting and no destination needs sim" "$(g Z '"xcodebuild -scheme X CODE_SIGNING_ALLOWED=NO test"')" 2
  check "a name= destination needs sim" "$(g Z '"xcodebuild -scheme X -destination \"name=iPhone 16e\" test"')" 2
  # The built-ins hold without a guard.conf; the config rules need one.
  mkdir -p "$work/noconf"
  check "no guard.conf: the watcher rule still holds" "$(AGENTLOCK_DIR="$work/noconf" g Z '"python3 /p/scripts/watch-github.py --role design --exit-on-input"')" 2
  check "no guard.conf: config rules do not apply" "$(AGENTLOCK_DIR="$work/noconf" g Z '"xcrun simctl boot X"')" 0
  check "a wait loop on kill -0 passes" "$(g Z '"until ! kill -0 1234 2>/dev/null; do sleep 3; done"')" 0
  check "pgrep outside a loop passes" "$(g Z '"pgrep -fl watch-github"')" 0
  check "xcodebuild test without a lock is blocked, for sim alone" "$(gm Z '"xcodebuild -scheme X -destination id=Y test"')" "sim"
  check "action-first: xcodebuild test with a macOS destination needs ui alone" "$(gm Z '"xcodebuild test -scheme X -destination platform=macOS"')" "ui"
  check "action-first: xcodebuild test with a device destination needs sim and device" "$(gm Z '"xcodebuild test -scheme X -destination \"platform=iOS,id=00008130-ABC\""')" "sim device"
  check "action-first: xcodebuild test with a simulator id needs sim alone" "$(gm Z '"xcodebuild test -scheme X -destination id=Y"')" "sim"
  check "action in the middle: project, test, then a macOS destination needs ui alone" "$(gm Z '"xcodebuild -project P.xcodeproj test -destination platform=macOS"')" "ui"
  check "simctl boot without lock blocked" "$(g Z '"xcrun simctl boot X"')" 2
  check "simctl list allowed" "$(g Z '"xcrun simctl list"')" 0
  check "heredoc body ignored" "$(g Z '"cat > n.md <<EOF\nUse xcrun xctrace\nEOF\necho done"')" 0
  check "quoted text ignored" "$(g Z '"gh issue comment 5 --body \"use xcrun simctl boot\""')" 0
  check "quoted device name still a command" "$(g Z '"xcrun simctl boot \"iPhone 16e\""')" 2
  check "DeviceHub needs ui" "$(g Z '"open -b com.apple.dt.Devices"')" 2
  AGENTLOCK_OWNER=S1 AGENTLOCK_AS=b1 $L acquire sim:x --ttl 1m >/dev/null
  check "session counts its builder's lock" "$(g S1 '"xcrun simctl boot X"')" 0
  # A guarded command extends the held lock by its ttl: a batch keeps its lock while commands keep coming.
  AGENTLOCK_OWNER=S1 $L release-all >/dev/null; AGENTLOCK_OWNER=S1 $L acquire sim:x --ttl 10s >/dev/null; sleep 2
  g S1 '"xcrun simctl boot X"' >/dev/null; left=$(AGENTLOCK_OWNER=S1 $L status sim:x | sed 's/.* \([0-9]*\)s left.*/\1/')
  [ "$left" -ge 9 ] && ok "a guarded command refreshed the lock to its full ttl ($left s left)" || bad "guarded command did not refresh: $left s left"
  AGENTLOCK_OWNER=S1 $L release-all >/dev/null; AGENTLOCK_OWNER=S1 $L acquire sim:x --ttl 3s >/dev/null; sleep 1
  g S1 '"xcrun simctl boot X"' >/dev/null; left=$(AGENTLOCK_OWNER=S1 $L status sim:x | sed 's/.* \([0-9]*\)s left.*/\1/')
  [ "$left" -le 2 ] && ok "a lock in its last seconds is not refreshed (a waiter may be taking it over)" || bad "near-expiry lock refreshed: $left s left"
  AGENTLOCK_OWNER=S1 $L release-all >/dev/null; AGENTLOCK_OWNER=S1 $L acquire sim:x --ttl 3s >/dev/null; sleep 4
  AGENTLOCK_OWNER=S1 $L check sim:x; check "control: without a guarded command the lock expires" $? 1
  # Two builders of one session on two simulators: the guarded command refreshes every family lock the session holds.
  AGENTLOCK_OWNER=S1 $L release-all >/dev/null
  AGENTLOCK_OWNER=S1 AGENTLOCK_AS=b1 $L acquire sim:iPhone-15 --ttl 1h >/dev/null; AGENTLOCK_OWNER=S1 AGENTLOCK_AS=b2 $L acquire sim:iPhone-16e --ttl 20s >/dev/null; sleep 2
  g S1 '"xcrun simctl boot iPhone-16e"' >/dev/null; left=$(AGENTLOCK_OWNER=S1 $L status sim:iPhone-16e | sed 's/.* \([0-9]*\)s left.*/\1/')
  [ "$left" -ge 19 ] && ok "the second builder's lock was refreshed too ($left s left)" || bad "second family lock not refreshed: $left s left"
  age=$(AGENTLOCK_OWNER=S1 $L status sim:iPhone-15 | sed 's/.*age=\([0-9]*\)s.*/\1/'); [ "$age" -ge 2 ] && ok "a refresh leaves the age alone" || bad "refresh reset the age to $age"
  AGENTLOCK_OWNER=S1 $L release-all >/dev/null
  # A malformed info file (no acquired line, no ttl line) has no ttl: the guard must not refresh it into a permanent lock.
  AGENTLOCK_OWNER=S1 $L acquire sim:old --ttl 1m >/dev/null; sed -i.bak '/^ttl=/d; /^acquired=/d' "$AGENTLOCK_DIR/locks/sim:old/info"; rm -f "$AGENTLOCK_DIR/locks/sim:old/info.bak"
  before=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/locks/sim:old/info"); g S1 '"xcrun simctl boot old"' >/dev/null; after=$(sed -n 's/^expires=//p' "$AGENTLOCK_DIR/locks/sim:old/info")
  [ "$before" = "$after" ] && ok "a malformed info without acquired is not refreshed into a permanent lock" || bad "malformed info refreshed: $before -> $after"
  AGENTLOCK_OWNER=S1 $L release sim:old --force >/dev/null
  AGENTLOCK_OWNER=S1 $L release-all >/dev/null; AGENTLOCK_OWNER=S1 AGENTLOCK_AS=b1 $L acquire sim:x --ttl 1m >/dev/null
  check "xcodebuild test under the session's sim lock passes (no ui needed)" "$(g S1 '"xcodebuild -scheme X -destination id=Y test"')" 0
  check "a macOS test run under sim only is blocked" "$(g S1 '"xcodebuild -scheme X -destination platform=macOS test"')" 2
  AGENTLOCK_OWNER=S1 $L release-all >/dev/null; AGENTLOCK_OWNER=S1 $L acquire ui --ttl 1m >/dev/null
  check "a macOS test run under ui alone passes (no sim needed)" "$(g S1 '"xcodebuild -scheme X -destination platform=macOS,arch=arm64 test"')" 0
  check "a macOS destination with an id under ui alone passes" "$(g S1 '"xcodebuild -scheme X -destination \"platform=macOS,arch=arm64,id=0000FE00-1234\" test"')" 0
  check "a simulator test run under ui alone is blocked" "$(g S1 '"xcodebuild -scheme X -destination id=Y test"')" 2
  check "a test run with a build setting under ui alone is blocked (needs sim)" "$(g S1 '"xcodebuild -scheme X CODE_SIGNING_ALLOWED=NO test"')" 2
  AGENTLOCK_OWNER=S1 $L acquire sim:x --ttl 1m >/dev/null
  check "a device-destination test run under sim alone is blocked (needs device too)" "$(g S1 '"xcodebuild -scheme X -destination \"platform=iOS,id=00008130-ABC\" test"')" 2
  AGENTLOCK_OWNER=S1 $L acquire device:00008130-ABC --ttl 1m >/dev/null
  check "a device-destination test run under sim and device passes" "$(g S1 '"xcodebuild -scheme X -destination \"platform=iOS,id=00008130-ABC\" test"')" 0
  AGENTLOCK_OWNER=S1 $L release sim:x >/dev/null; AGENTLOCK_OWNER=S1 $L release device:00008130-ABC >/dev/null
  AGENTLOCK_OWNER=S1 $L release ui >/dev/null; AGENTLOCK_OWNER=S1 AGENTLOCK_AS=b1 $L acquire sim:x --ttl 1m >/dev/null
  check "other session still blocked" "$(g S2 '"xcrun simctl boot X"')" 2
  AGENTLOCK_OWNER=S1 $L release-all >/dev/null
  check "quoted Simulator app name still matches" "$(g Z '"open -a \"Simulator\""')" 2
  check "xcresult path is not the test action" "$(g Z '"xcodebuild -scheme X build -resultBundlePath test.xcresult"')" 0
  check "xctrace list needs no lock" "$(g Z '"xcrun xctrace list devices"')" 0
  check "simctl bootstatus needs no lock" "$(g Z '"xcrun simctl bootstatus X"')" 0
  check "grep for osascript is not osascript" "$(g Z '"grep -r osascript ."')" 0
  check "grep for osascript after a pipe is not osascript" "$(g Z '"cat log | grep osascript"')" 0
  check "AppleScript piped into osascript needs ui" "$(g Z '"printf activate | osascript"')" 2
  check "AppleScript redirected into osascript needs ui" "$(g Z '"osascript < activate.scpt"')" 2
  check "a heredoc piped into osascript needs ui" "$(g Z '"cat <<EOT | osascript\ntell application \"Finder\" to activate\nEOT"')" 2
  check "a heredoc piped into simctl needs sim" "$(g Z '"cat <<EOT | xargs xcrun simctl boot\nX\nEOT"')" 2
  check "grep for osascript with a redirect is not osascript" "$(g Z '"grep osascript < log.txt"')" 0
  check "a quoted alternation holds no command" "$(g Z '"grep -E \"foo|osascript\" x"')" 0
  check "a path ending in osascript is not the command" "$(g Z '"sort /tmp/osascript < f"')" 0
  check "an apostrophe in double quotes hides nothing" "$(g Z '"git commit -m \"don'"'"'t break\" && osascript -e '"'"'tell app \"Finder\" to activate'"'"'"')" 2
  check "a backslash escape in double quotes keeps the string closed" "$(g Z '"printf \"it'"'"'s ok\\n\" && osascript -e '"'"'tell app \"Finder\" to activate'"'"'"')" 2
  check "escaped quotes inside quoted prose stay prose" "$(g Z '"gh issue comment 5 --body \"see \\\"xcrun simctl boot\\\" in the log\""')" 0
  check "an escaped apostrophe outside quotes opens no run" "$(g Z '"echo don\\'"'"'t; osascript -e '"'"'x'"'"'"')" 2
  check "ANSI-C quoting with an escaped apostrophe hides nothing" "$(g Z '"git commit -m $'"'"'Fix it\\'"'"'s thing'"'"' && osascript -e '"'"'activate'"'"'"')" 2
  check "a backslash-newline inside quotes does not end the string" "$(g Z '"echo \"a\\\nb\" ; osascript -e '"'"'x'"'"' ; echo \"c\""')" 2
  check "a backslash-newline inside quoted prose is still prose" "$(g Z '"git commit -m \"a\" -m \"line\\\ncontinued; osascript -e y\""')" 0
  check "a heredoc with a backslash-quoted delimiter is blanked" "$(g Z '"cat <<\\EOT\nit'"'"'s\nEOT\nosascript -e '"'"'x'"'"'"')" 2
  check "osascript inside a brace group needs ui" "$(g Z '"{ osascript < a.scpt; }"')" 2
  check "osascript under time needs ui" "$(g Z '"time osascript < a.scpt"')" 2
  check "osascript as an if condition needs ui" "$(g Z '"if osascript < a.scpt; then echo y; fi"')" 2
  check "an apostrophe in double quotes, then a quiet osascript" "$(g Z '"echo \"it'"'"'s\"; osascript -e '"'"'activate'"'"'"')" 2
  check "agentlock as a trailing word is no bypass" "$(g Z '"xcrun simctl boot X; agentlock status"')" 2
  check "agentlock as the command passes" "$(g Z '"AGENTLOCK_AS=b agentlock acquire sim:x"')" 0
  check "agentlock first then a simctl command is no bypass" "$(g Z '"agentlock status; xcrun simctl boot X"')" 2
  check "backgrounded agentlock then a simctl command is no bypass" "$(g Z '"agentlock status & xcrun simctl boot X"')" 2
  check "redirection with & is not a split" "$(g Z '"agentlock with sim:x -- xcrun simctl boot X 2>&1"')" 0
  check "env prefix before agentlock passes" "$(g Z '"env AGENTLOCK_AS=b1 agentlock with sim:x -- xcrun simctl boot X"')" 0
  check "osascript with a heredoc needs ui" "$(g Z '"osascript <<EOT\ntell application \"Finder\"\nEOT"')" 2
  AGENTLOCK_OWNER=S3 AGENTLOCK_AS=b1 $L acquire quiet --ttl 1m >/dev/null
  check "a builder's quiet blocks its own session's builds too (the guard cannot tell whose command it is)" "$(g S3 '"xcodebuild -scheme X build"')" 2
  check "the measurer runs its command through agentlock with quiet" "$(g S3 '"AGENTLOCK_AS=b1 agentlock with quiet -- swift test"')" 0
  check "the measurer's command piped into a filter passes" "$(g S3 '"AGENTLOCK_AS=b1 agentlock with quiet -- swift test | tee /tmp/t.log"')" 0
  check "with quiet covers the simulator too: the measurer holds the machine" "$(g S3 '"AGENTLOCK_AS=b1 agentlock with quiet -- xcodebuild test -scheme X -destination \"platform=iOS Simulator,name=iPhone 16e\" 2>&1 | xcpretty"')" 0
  check "with quiet grants nothing after a semicolon" "$(g S3 '"AGENTLOCK_AS=b1 agentlock with quiet -- true; xcodebuild -scheme X build"')" 2
  check "with quiet grants nothing after &&" "$(g S3 '"AGENTLOCK_AS=b1 agentlock with quiet -- swift test && xcodebuild -scheme X build"')" 2
  check "swift test under a sibling's quiet is blocked" "$(g S3 '"swift test --filter Timing"')" 2
  check "other session blocked under quiet" "$(g S4 '"xcodebuild -scheme X build"')" 2
  AGENTLOCK_OWNER=S3 $L release-all >/dev/null
  printf 'ui\t\\b(screencapture\n' >> "$AGENTLOCK_DIR/guard.conf"
  check "a bad regex blocks instead of allowing" "$(g Z '"git status"')" 2
  $L check-conf >/dev/null 2>&1; check "check-conf reports the bad regex" $? 1
  cp "$here/hooks/guard.conf.example" "$AGENTLOCK_DIR/guard.conf"; $L check-conf >/dev/null; check "check-conf passes the example" $? 0
  printf 'zz\t\\bgit status\\b' >> "$AGENTLOCK_DIR/guard.conf"   # no trailing newline, a rule the example lacks
  check "last rule without newline still applies" "$(g Z '"git status"')" 2
fi

if run watcher; then echo "watcher"
  mkdir -p "$work/bin" "$work/repo/.agent-team"
  cat > "$work/bin/gh" <<'GH'
#!/bin/bash
url="${@: -1}"
case "$url" in
  *"/pulls/comments?"*) echo '[{"id":9,"updated_at":"2026-11-03T08:00:00Z","pull_request_url":"https://api.github.com/repos/x/y/pulls/13","path":"Foo.swift","line":42,"body":"Is this retained?"},{"id":10,"updated_at":"2026-11-03T08:00:30Z","pull_request_url":"https://api.github.com/repos/x/y/pulls/13","path":"Bar.swift","line":7,"body":"[engineering]\nFixed."}]' ;;
  *"/issues/comments?"*) echo '[{"id":4,"updated_at":"2026-11-03T08:01:00Z","issue_url":"https://api.github.com/repos/x/y/issues/9","body":"[design]\nchatter on an idea"},{"id":5,"updated_at":"2026-11-03T08:03:00Z","issue_url":"https://api.github.com/repos/x/y/issues/9","body":"Do this one now."},{"id":6,"updated_at":"2026-11-03T08:02:30Z","issue_url":"https://api.github.com/repos/x/y/issues/12","body":"[engineering]\nmy own comment"},{"id":11,"updated_at":"2026-11-03T08:02:35Z","issue_url":"https://api.github.com/repos/x/y/issues/13","body":"[engineering]\nanswered"},{"id":12,"updated_at":"2026-11-03T08:02:36Z","issue_url":"https://api.github.com/repos/x/y/issues/14","body":"Owner here: not yet."},{"id":13,"updated_at":"2026-11-03T08:02:40Z","issue_url":"https://api.github.com/repos/x/y/issues/15","body":"[engineering]\nanswered too"}]' ;;
  *"/issues?"*) echo '[{"id":102,"number":9,"created_at":"2026-10-20T00:00:00Z","updated_at":"2026-11-03T08:02:00Z","state":"open","title":"Old owner idea","labels":[{"name":"idea"}],"body":"owner wrote this"},{"id":103,"number":20,"created_at":"2026-11-03T08:03:00Z","updated_at":"2026-11-03T08:03:00Z","state":"open","title":"New owner idea","labels":[{"name":"idea"}],"body":"just filed"},{"id":104,"number":12,"created_at":"2026-11-03T08:02:30Z","updated_at":"2026-11-03T08:02:30Z","state":"open","title":"Review round","labels":[{"name":"for-engineering"}],"body":"[design]\nround"},{"id":109,"number":13,"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-03T08:02:35Z","state":"open","title":"Old round we answered","labels":[{"name":"for-engineering"}],"body":"[design]\nold round"},{"id":110,"number":14,"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-03T08:02:36Z","state":"open","title":"Old round the owner answered","labels":[{"name":"for-engineering"}],"body":"[design]\nold round 2"},{"id":111,"number":15,"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-03T08:02:50Z","state":"closed","title":"Old round we answered, then the owner closed","labels":[{"name":"for-engineering"}],"body":"[design]\nold round 3"},{"id":105,"number":30,"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-03T08:02:40Z","state":"open","title":"Pushed PR","labels":[],"body":"Tier: standard","pull_request":{}},{"id":106,"number":31,"created_at":"2026-11-03T08:02:50Z","updated_at":"2026-11-03T08:02:50Z","state":"open","title":"New PR","labels":[],"body":"Tier: standard","pull_request":{}},{"id":112,"number":33,"created_at":"2026-11-03T08:02:52Z","updated_at":"2026-11-03T08:02:52Z","state":"open","title":"Design housekeeping","labels":[],"body":"[design]\nHousekeeping.","pull_request":{}},{"id":113,"number":34,"created_at":"2026-11-03T08:02:53Z","updated_at":"2026-11-03T08:02:53Z","state":"open","title":"Design docs for engineering","labels":[{"name":"for-engineering"}],"body":"[design]\nTier: low","pull_request":{}},{"id":107,"number":32,"created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-03T08:02:45Z","state":"open","title":"Labelled PR","labels":[{"name":"for-engineering"}],"body":"[design]\nlook","pull_request":{}}]' ;;
  *) exit 1 ;;
esac
GH
  chmod +x "$work/bin/gh"; echo "2026-11-03T07:00:00Z" > "$work/repo/.agent-team/watch-engineering.cursor"
  mkdir -p "$work/whome"   # an empty HOME: the caller's own plugin cache must not reach the watcher under test
  out=$(cd "$work/repo" && HOME="$work/whome" PATH="$work/bin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --once)
  check "item count" "$(printf '%s' "$out" | head -1 | sed 's/.*(\([0-9]*\) items).*/\1/')" 10
  # No cursor file (a fresh container): the watcher lists the last day, not the last five minutes. The stub answers an
  # issue updated two hours ago when since is earlier than that; with --catch-up-hours 1 since is later, and the issue stays unlisted.
  mkdir -p "$work/nocur/.agent-team" "$work/nocurbin"; two_h_ago=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  printf '#!/bin/bash\nurl="${@: -1}"\ncase "$url" in *"/issues?"*) since="${url##*since=}"; since="${since%%%%&*}"; if [ "%s" \> "$since" ]; then echo %s; else echo "[]"; fi ;; *) echo "[]" ;; esac\n' "$two_h_ago" "'[{\"id\":501,\"number\":77,\"created_at\":\"$two_h_ago\",\"updated_at\":\"$two_h_ago\",\"state\":\"open\",\"title\":\"Question for you\",\"labels\":[],\"body\":\"[design]\\nis this fixed?\"}]'" > "$work/nocurbin/gh"; chmod +x "$work/nocurbin/gh"
  nout=$(cd "$work/nocur" && HOME="$work/whome" PATH="$work/nocurbin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --once 2>&1)
  printf '%s' "$nout" | grep -q "#77 issue by design" && ok "watcher: with no cursor it lists the last day, so a question posted two hours before a fresh start is seen" || bad "no-cursor catch-up: $nout"
  rm -f "$work/nocur/.agent-team/watch-engineering."*
  nout=$(cd "$work/nocur" && HOME="$work/whome" PATH="$work/nocurbin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --once --catch-up-hours 1 2>&1)
  printf '%s' "$nout" | grep -q "#77 issue" && bad "catch-up of 1 h listed a 2 h old issue" || ok "watcher: --catch-up-hours bounds the catch-up"
  printf '%s' "$out" | grep -q "#15 issue by design, closed" && ok "an old issue the owner acted on after our comment is listed" || bad "owner action after our comment missed"
  printf '%s' "$out" | grep -q "#13 issue" && bad "an old issue bumped by our own comment listed" || ok "an old issue bumped by our own comment does not wake"
  printf '%s' "$out" | grep -q "#14 issue by design" && ok "an old issue bumped by the owner's comment is listed" || bad "owner-bumped old issue missing"
  printf '%s' "$out" | grep -q "#30 PR" && bad "a PR updated by a push listed" || ok "a PR updated by a push does not wake"
  printf '%s' "$out" | grep -q "#31 PR" && ok "a new PR is listed once" || bad "new PR missing"
  printf '%s' "$out" | grep -q "#33 PR" && bad "the other role's unlabelled PR listed" || ok "the other role's housekeeping PR does not wake"
  printf '%s' "$out" | grep -q "#34 PR by design" && ok "the other role's PR labelled for this role is listed" || bad "labelled design PR missing"
  printf '%s' "$out" | grep -q "#32 PR by design" && ok "a PR labelled for the role is listed on update" || bad "labelled PR missing"
  printf '%s' "$out" | grep -q "#20 issue by owner" && ok "new owner idea listed" || bad "new owner idea missing"
  printf '%s' "$out" | grep -q "#9 issue" && bad "old idea's issue line listed" || ok "old idea's issue line skipped"
  printf '%s' "$out" | grep -q "#9 comment by owner" && ok "owner comment on idea wakes" || bad "owner comment on idea missing"
  # The watcher tells the session when a newer plugin is installed than the copy it runs (a session keeps its copy).
  printf '%s' "$out" | grep -q "This session runs plugin" && bad "a plugin note with no newer copy installed" || ok "no plugin note when no newer copy is installed"
  mkdir -p "$work/whome/.claude/plugins/cache/mp/agent-team/99.0.0/.claude-plugin" "$work/whome/.claude/plugins/cache/mp/agent-team/0.0.1/.claude-plugin"
  printf '{"version":"99.0.0"}\n' > "$work/whome/.claude/plugins/cache/mp/agent-team/99.0.0/.claude-plugin/plugin.json"; printf '{"version":"0.0.1"}\n' > "$work/whome/.claude/plugins/cache/mp/agent-team/0.0.1/.claude-plugin/plugin.json"
  mkdir -p "$work/wstate" "$work/wbin"; echo "2026-11-03T07:00:00Z" > "$work/wstate/watch-engineering.cursor"; printf '#!/bin/bash\necho "[]"\n' > "$work/wbin/gh"; chmod +x "$work/wbin/gh"
  out2=$(cd "$work/repo" && HOME="$work/whome" PATH="$work/bin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --once --state-dir "$work/wstate")
  printf '%s' "$out2" | grep -q "^\[watcher\] This session runs plugin $(jq -r .version "$here/.claude-plugin/plugin.json"); 99.0.0 is installed" && ok "the summary carries the plugin note when a newer copy is installed" || bad "no plugin note with a newer copy: $(printf '%s' "$out2" | tail -2)"
  out2=$(cd "$work/repo" && HOME="$work/whome" PATH="$work/wbin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --once --state-dir "$work/wstate")   # a gh that answers nothing: nothing new
  printf '%s' "$out2" | grep -q "nothing new" && printf '%s' "$out2" | grep -q "99.0.0 is installed" && ok "the nothing-new exit carries the plugin note too" || bad "plugin note missing on the nothing-new exit: $out2"
  # A malformed cache manifest must not kill the watcher (it runs after the cursor is written: a crash loses the tick's items).
  mkdir -p "$work/whome/.claude/plugins/cache/mp/agent-team/bad1/.claude-plugin" "$work/whome/.claude/plugins/cache/mp/agent-team/bad2/.claude-plugin"
  mkdir -p "$work/whome/.claude/plugins/cache/mp/agent-team/bad3/.claude-plugin" "$work/whome/.claude/plugins/cache/mp/agent-team/bad4/.claude-plugin"
  printf '[1,2]\n' > "$work/whome/.claude/plugins/cache/mp/agent-team/bad1/.claude-plugin/plugin.json"; printf '{"version": null}\n' > "$work/whome/.claude/plugins/cache/mp/agent-team/bad2/.claude-plugin/plugin.json"
  printf 'not json' > "$work/whome/.claude/plugins/cache/mp/agent-team/bad3/.claude-plugin/plugin.json"; printf '{"version": "9.9.' > "$work/whome/.claude/plugins/cache/mp/agent-team/bad4/.claude-plugin/plugin.json"   # not JSON; truncated by an update in progress
  out2=$(cd "$work/repo" && HOME="$work/whome" PATH="$work/wbin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --once --state-dir "$work/wstate" 2>&1); rc=$?
  [ $rc = 0 ] && printf '%s' "$out2" | grep -q "99.0.0 is installed" && ok "malformed cache manifests are skipped, the note still names the newest real one" || bad "malformed manifest broke the watcher: rc=$rc $out2"
  # The watcher's own manifest missing (a copy outside the plugin tree): no note, no crash.
  mkdir -p "$work/wcopy/scripts"; cp "$here/scripts/watch-github.py" "$work/wcopy/scripts/"
  out2=$(cd "$work/repo" && HOME="$work/whome" PATH="$work/wbin:$PATH" python3 "$work/wcopy/scripts/watch-github.py" --role engineering --repo x/y --once --state-dir "$work/wstate" 2>&1); rc=$?
  [ $rc = 0 ] && ! printf '%s' "$out2" | grep -q "is installed" && ok "a watcher copy without its own manifest runs and prints no note" || bad "own manifest missing: rc=$rc $out2"
  printf '%s' "$out" | grep -q "chatter" && bad "agent chatter on idea listed" || ok "agent chatter on idea skipped"
  printf '%s' "$out" | grep -q "(on Foo.swift:42) Is this retained" && ok "owner inline comment with location" || bad "owner inline comment missing"
  printf '%s' "$out" | grep -q "Fixed" && bad "own inline comment listed" || ok "own inline comment skipped"
  printf '%s' "$out" | grep -q "my own comment" && bad "own comment listed" || ok "own comment skipped"
  printf '%s' "$out" | grep -q "#12 issue by design" && ok "issue from the other role listed" || bad "design's issue missing"
  check "cursor advanced to the newest timestamp" "$(cat "$work/repo/.agent-team/watch-engineering.cursor")" "2026-11-03T08:03:00Z"
  grep -q "^9$" "$work/repo/.agent-team/watch-engineering.ideas" && ok "idea numbers remembered" || bad "ideas file missing #9"
  # Seed the seen file past the old 500-key cap, so a cap-based pruning would drop the comment at the cursor.
  for i in $(seq 1 600); do echo "issue:$i:2026-11-03T08:03:00Z"; done >> "$work/repo/.agent-team/watch-engineering.seen"
  # Next tick: only an agent comment on the old idea, whose issue does not change; still skipped, nothing replayed.
  cat > "$work/bin/gh" <<'GH'
#!/bin/bash
url="${@: -1}"
case "$url" in
  *"/pulls/comments?"*) echo '[]' ;;
  *"/issues/comments?"*) echo '[{"id":7,"updated_at":"2026-11-03T08:10:00Z","issue_url":"https://api.github.com/repos/x/y/issues/9","body":"[design]\nedited chatter"},{"id":5,"updated_at":"2026-11-03T08:03:00Z","issue_url":"https://api.github.com/repos/x/y/issues/9","body":"Do this one now."},{"id":8,"updated_at":"2026-11-03T08:11:00Z","issue_url":"https://api.github.com/repos/x/y/issues/12","body":"Second tick control."}]' ;;
  *"/issues?"*) echo '[{"id":1108,"number":41,"created_at":"2026-11-03T08:11:00Z","updated_at":"2026-11-03T08:11:00Z","state":"open","title":"PR opened as the newest event","labels":[],"body":"Tier: low","pull_request":{}}]' ;;
  *) exit 1 ;;
esac
GH
  out=$(cd "$work/repo" && PATH="$work/bin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --once)
  printf '%s' "$out" | grep -q "edited chatter" && bad "agent comment on a remembered idea listed" || ok "agent comment on a remembered idea skipped"
  printf '%s' "$out" | grep -q "Do this one now" && bad "comment at the cursor replayed" || ok "comment at the cursor not replayed"
  printf '%s' "$out" | grep -q "Second tick control" && ok "second tick lists the new owner comment" || bad "second tick listed nothing (stub or API failure would hide the negatives)"
  printf '%s' "$out" | grep -q "#41 PR" && ok "a PR opened as the tick's newest event is listed" || bad "newest-event PR missing"
  # Third tick: that PR's first push. Its creation time equals the cursor, so only the seen set tells it is known.
  cat > "$work/bin/gh" <<'GH'
#!/bin/bash
url="${@: -1}"
case "$url" in
  *"/pulls/comments?"*|*"/issues/comments?"*) echo '[]' ;;
  *"/issues?"*) echo '[{"id":1108,"number":41,"created_at":"2026-11-03T08:11:00Z","updated_at":"2026-11-03T08:12:00Z","state":"open","title":"PR opened as the newest event","labels":[],"body":"Tier: low","pull_request":{}}]' ;;
  *) exit 1 ;;
esac
GH
  out=$(cd "$work/repo" && PATH="$work/bin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --once)
  printf '%s' "$out" | grep -q "#41 PR" && bad "a known PR listed again on its first push" || ok "a known PR is not listed again on a push"
  # The default relative state dir, with the cwd deleted while the watcher waits on the API: exit 3, not a traceback.
  mkdir -p "$work/gone/.agent-team"; printf '#!/bin/bash\nsleep 2; echo "[]"\n' > "$work/slowbin-gh"; mkdir -p "$work/slowbin"; mv "$work/slowbin-gh" "$work/slowbin/gh"; chmod +x "$work/slowbin/gh"
  ( cd "$work/gone" && (sleep 1; rm -rf "$work/gone") & cd "$work/gone" && PATH="$work/slowbin:$PATH" python3 "$here/scripts/watch-github.py" --role design --repo x/y --once >/dev/null 2>"$work/gone.err" ); rc=$?
  check "vanished cwd with the default state dir: exit 3" $rc 3
  # The schedule: an activity stamp 5 h old puts the watcher in the slow tier (checking every --slow-interval), not stopped
  # (the stop is a week by default); --idle-hours 4 stops it on that stamp; --idle-hours 0 stops at the first tick.
  mkdir -p "$work/idle/.agent-team"; printf '#!/bin/bash\necho "[]"\n' > "$work/idlebin-gh"; mkdir -p "$work/idlebin"; mv "$work/idlebin-gh" "$work/idlebin/gh"; chmod +x "$work/idlebin/gh"
  echo "2026-11-03T07:00:00Z" > "$work/idle/.agent-team/watch-engineering.cursor"; python3 -c 'import time; print(time.time() - 5*3600)' > "$work/idle/.agent-team/watch-engineering.active"
  out=$( cd "$work/idle" && PATH="$work/idlebin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --exit-on-input --max-minutes 0.02 --interval 1 --slow-interval 7 2>&1 ); check "a 5 h old stamp does not stop the watcher (the stop is a week), exit 3 at the limit" $? 3
  printf '%s' "$out" | grep -q "checking every 7 s" && ok "after --slow-after hours it checks at --slow-interval" || bad "slow tier not applied: $out"
  python3 -c 'import time; print(time.time() - 60)' > "$work/idle/.agent-team/watch-engineering.active"
  out=$( cd "$work/idle" && PATH="$work/idlebin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --exit-on-input --max-minutes 0.02 --interval 1 --slow-interval 7 2>&1 )
  printf '%s' "$out" | grep -q "checking every 1 s" && ok "a fresh stamp keeps the fast interval" || bad "fast tier not applied: $out"
  python3 -c 'import time; print(time.time() - 5*3600)' > "$work/idle/.agent-team/watch-engineering.active"
  ( cd "$work/idle" && PATH="$work/idlebin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --exit-on-input --max-minutes 0.02 --interval 1 --idle-hours 4 >/dev/null 2>&1 ); check "the stamp is kept across restarts: --idle-hours 4 stops on a 5 h old one, exit 2" $? 2
  ( cd "$work/idle" && PATH="$work/idlebin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --exit-on-input --max-minutes 0.02 --interval 1 --idle-hours 4 --fresh >/dev/null 2>&1 ); check "--fresh resets the stamp: --idle-hours 4 no longer stops, exit 3" $? 3
  age=$(python3 -c 'import time,sys; print(int(time.time() - float(open(sys.argv[1]).read())))' "$work/idle/.agent-team/watch-engineering.active"); [ "$age" -lt 30 ] && ok "--fresh wrote a stamp of now" || bad "stamp after --fresh is $age s old"
  ( cd "$work/idle" && PATH="$work/idlebin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --exit-on-input --max-minutes 0.02 --interval 1 --idle-hours 0 >/dev/null 2>&1 ); check "exit-on-input: the idle stop still exists (--idle-hours 0 stops at once), exit 2" $? 2
  ( cd "$work/idle" && PATH="$work/idlebin:$PATH" python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --once --idle-hours 0 >/dev/null 2>&1 ); check "--once ignores the idle stop (control)" $? 0
fi

if run cleanup; then echo "cleanup"
  mkdir -p "$work/pc/bin" "$work/pc/origin.git" "$work/pc/junk"
  printf '#!/bin/bash\ncase "$*" in *"--json state"*) echo MERGED ;; *headRefName*) echo feature ;; *) exit 0 ;; esac\n' > "$work/pc/bin/gh"; chmod +x "$work/pc/bin/gh"
  ( cd "$work/pc" && git init -q --bare origin.git && git clone -q origin.git repo 2>/dev/null && cd repo \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init && git branch -M main && git push -q origin main 2>/dev/null \
    && git checkout -q -b feature && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m f && git push -q origin feature 2>/dev/null \
    && git checkout -q main && git worktree add -q ../wt feature 2>/dev/null \
    && mkdir -p build ../wt/build .agent-team/hooks && touch build/junk ../wt/build/junk "$work/pc/junk/stale.log" \
    && printf '#!/bin/bash\necho "hook got: $1"; exit 7\n' > .agent-team/hooks/worktree-removed && chmod +x .agent-team/hooks/worktree-removed )
  wt_real=$(cd "$work/pc/wt" && pwd -P)
  out=$(cd "$work/pc/wt" && PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 7 --worktree . --also build/junk --also /no/such/dir/Applications --also "$work/pc/repo/missing-build/Library" --also /Applications --also "$work/pc/repo" --also "$work/pc/junk/stale.log" 2>&1); rc=$?
  check "exit 0 despite failing hook" $rc 0
  printf '%s' "$out" | grep -qxF "hook got: $wt_real" && ok "hook got the worktree's absolute path" || bad "hook path wrong: $(printf '%s' "$out" | grep 'hook got' | head -1)"
  printf '%s' "$out" | grep -q "exit 7); continuing" && ok "failing hook warns and continues" || bad "no warning for failing hook"
  [ -d "$work/pc/wt" ] && bad "worktree still there" || ok "worktree removed"
  git -C "$work/pc/repo" show-ref --verify --quiet refs/heads/feature && bad "local branch survived" || ok "local branch deleted"
  git -C "$work/pc/repo" ls-remote --exit-code --heads origin feature >/dev/null 2>&1 && bad "remote branch survived" || ok "remote branch deleted"
  [ -e "$work/pc/repo/build/junk" ] && ok "main checkout's file kept" || bad "main checkout's file deleted"
  [ -e "$work/pc/junk/stale.log" ] && bad "exact --also path not removed" || ok "exact --also path removed"
  printf '%s' "$out" | grep -q "refusing a path this close to the root: /Applications" && ok "/Applications refused" || bad "/Applications not refused"
  printf '%s' "$out" | grep -q "not found: /no/such/dir/Applications" && ok "missing parent is not found" || bad "missing parent mishandled"
  printf '%s' "$out" | grep -Eq "refusing(: | the repo).*pc/repo$" && ok "repo root refused" || bad "repo root not refused"
  out=$(cd "$work/pc/repo" && PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 8 --worktree . 2>&1); check "main checkout as worktree refused" $? 1
  # Depth refusals: nothing this close to the root or directly under HOME, even when it exists.
  mkdir -p "$work/fakehome/Library" "$work/fakehome/deeper/x"; touch "$work/fakehome/Library/keep" "$work/fakehome/deeper/x/go"
  out=$(cd "$work/pc/repo" && HOME="$work/fakehome" PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 9 --also "$work/fakehome/Library" --also "$work/fakehome/deeper/x/go" 2>&1)
  [ -e "$work/fakehome/Library/keep" ] && ok "a folder directly under HOME is refused" || bad "HOME/Library was deleted"
  [ -e "$work/fakehome/deeper/x/go" ] && bad "a deep exact path was kept" || ok "a deep exact path is removed"
  # A failed local removal stops before the remote branch and exits 1.
  ( cd "$work/pc/repo" && git checkout -q -b feature3 && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m h && git push -q origin feature3 2>/dev/null && git checkout -q main && git worktree add -q ../wt3 feature3 2>/dev/null && git worktree lock ../wt3 )
  printf '#!/bin/bash\ncase "$*" in *"--json state"*) echo MERGED ;; *headRefName*) echo feature3 ;; *) exit 0 ;; esac\n' > "$work/pc/bin/gh"
  out=$(cd "$work/pc/repo" && PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 10 --worktree ../wt3 2>&1); rc=$?
  check "locked worktree: exit 1" $rc 1
  git -C "$work/pc/repo" ls-remote --exit-code --heads origin feature3 >/dev/null 2>&1 && ok "remote branch kept after a failed local cleanup" || bad "remote branch deleted despite failure"
  # Locked and gone: prune cannot drop a locked registration, and the script must say so rather than claim a prune.
  rm -rf "$work/pc/wt3"
  out=$(cd "$work/pc/repo" && PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 10 --worktree ../wt3 2>&1); rc=$?
  check "locked and vanished worktree: exit 1" $rc 1
  printf '%s' "$out" | grep -q "could not prune .*wt3 (locked?)" && ok "locked and vanished: honest message" || bad "locked and vanished: claimed success: $out"
  git -C "$work/pc/repo" show-ref --verify --quiet refs/heads/feature3 && ok "branch kept while the worktree is locked" || bad "branch deleted while the worktree is locked"
  git -C "$work/pc/repo" worktree unlock ../wt3
  out=$(cd "$work/pc/repo" && PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 10 --worktree ../wt3 2>&1); rc=$?
  check "unlocked and vanished worktree: exit 0" $rc 0
  printf '%s' "$out" | grep -q "pruned .*wt3" && ok "unlocked and vanished: pruned" || bad "unlocked and vanished: not pruned: $out"
  git -C "$work/pc/repo" show-ref --verify --quiet refs/heads/feature3 && bad "branch kept after the prune" || ok "branch deleted after the prune"
  # A worktree directory with regex characters is still recognised (the branch name is ordinary).
  ( cd "$work/pc/repo" && git checkout -q -b feature4 && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m i && git push -q origin feature4 2>/dev/null && git checkout -q main && git worktree add -q "../wt[4]" feature4 2>/dev/null )
  [ -d "$work/pc/wt[4]" ] || bad "test setup: bracketed worktree not created"
  printf '#!/bin/bash\ncase "$*" in *"--json state"*) echo MERGED ;; *headRefName*) echo feature4 ;; *) exit 0 ;; esac\n' > "$work/pc/bin/gh"
  out=$(cd "$work/pc/repo" && PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 11 --worktree "../wt[4]" 2>&1); rc=$?
  check "worktree path with brackets: exit 0" $rc 0
  [ -d "$work/pc/wt[4]" ] && bad "bracketed worktree kept" || ok "bracketed worktree removed"
  # A merge whose PR body said "Closes #N" closed a decision issue: pr-cleanup reopens it, and leaves an ordinary issue closed.
  ( cd "$work/pc/repo" && git checkout -q -b feature6 && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m k && git push -q origin feature6 2>/dev/null && git checkout -q main )
  cat > "$work/pc/bin/gh" <<GH
#!/bin/bash
case "\$*" in
  *"--json state"*"pr view"*|"pr view"*"--json state"*) echo MERGED ;;
  *headRefName*) echo feature6 ;;
  *"--json body"*) printf 'Tier: low\\nCloses #735 and fixes #12; see #99\\nResolves fzwo/project#736, closes: https://github.com/fzwo/project/issues/737, fixes other/repo#9\\ndisclosed #3, prefixes #4, unfixed #5\\nFixes #738 (closed by the owner last week)\\n' ;;
  *"--json mergedAt"*) echo 2026-11-06T20:00:00Z ;;
  "issue view 738 --json labels"*) printf 'decision\\n' ;;
  "issue view 738 --json state"*) echo CLOSED ;;
  "issue view 738 --json closedAt"*) echo 2026-11-01T09:00:00Z ;;
  *"--json closedAt"*) echo 2026-11-06T20:00:04Z ;;
  "issue view 3 --json labels"*|"issue view 4 --json labels"*|"issue view 5 --json labels"*) printf 'decision\\n' ;;
  "issue view 3 --json state"*|"issue view 4 --json state"*|"issue view 5 --json state"*) echo CLOSED ;;
  "repo view"*) echo fzwo/project ;;
  "issue view 735 --json labels"*|"issue view 736 --json labels"*|"issue view 737 --json labels"*) printf 'decision\\n' ;;
  "issue view 735 --json state"*|"issue view 736 --json state"*|"issue view 737 --json state"*) echo CLOSED ;;
  "issue view 9 "*) echo "another repo's issue was looked up" >> "$work/pc/reopened"; exit 1 ;;
  "issue view 12 --json labels"*) printf 'bug\\n' ;;
  "issue view 12 --json state"*) echo CLOSED ;;
  "issue reopen"*) echo "\$*" >> "$work/pc/reopened"; exit 0 ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$work/pc/bin/gh"
  out=$(cd "$work/pc/repo" && PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 13 2>&1); rc=$?
  check "cleanup after a merge that closed a decision: exit 0" $rc 0
  grep -q "^issue reopen 735 " "$work/pc/reopened" 2>/dev/null && ok "a decision issue closed by the merge is reopened" || bad "decision issue not reopened: $out"
  grep -q "^issue reopen 12 " "$work/pc/reopened" 2>/dev/null && bad "an ordinary closed issue was reopened" || ok "an ordinary issue stays closed"
  grep -q "^issue reopen 736 " "$work/pc/reopened" && grep -q "^issue reopen 737 " "$work/pc/reopened" && ok "owner/repo#N and URL forms are taken" || bad "link forms missed: $(cat "$work/pc/reopened")"
  grep -q "another repo" "$work/pc/reopened" && bad "another repo's issue number was looked up" || ok "another repo's issue is never touched"
  grep -q "^issue reopen 738 " "$work/pc/reopened" && bad "a decision closed before the merge was reopened" || ok "a decision the owner closed earlier stays closed"
  printf '%s' "$out" | grep -q "reopened #735" && ok "the reopen is reported" || bad "reopen not reported: $out"
  grep -q "^issue reopen 3 \|^issue reopen 4 \|^issue reopen 5 " "$work/pc/reopened" && bad "a word ending in a keyword (disclosed, unfixed) counted as closing" || ok "a word that merely ends in a keyword does not count"
  # gh failing on an issue: a warning, the number skipped, the script goes on.
  ( cd "$work/pc/repo" && git checkout -q -b feature7 && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m l && git push -q origin feature7 2>/dev/null && git checkout -q main )
  printf '#!/bin/bash\ncase "$*" in *"--json state"*) echo MERGED ;; *headRefName*) echo feature7 ;; *"--json body"*) echo "Closes #800" ;; "repo view"*) echo fzwo/project ;; "issue view"*) exit 1 ;; *) exit 0 ;; esac\n' > "$work/pc/bin/gh"
  out=$(cd "$work/pc/repo" && PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 14 2>&1); rc=$?
  check "an unreadable issue does not stop the cleanup" $rc 0
  printf '%s' "$out" | grep -q "warning: could not read issue #800" && ok "an unreadable issue is warned about" || bad "no warning for an unreadable issue: $out"
  # A registered worktree whose directory is already gone is pruned, and the branch still goes.
  ( cd "$work/pc/repo" && git checkout -q -b feature5 && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m j && git push -q origin feature5 2>/dev/null && git checkout -q main && git worktree add -q ../wt5 feature5 2>/dev/null && rm -rf ../wt5 )
  printf '#!/bin/bash\ncase "$*" in *"--json state"*) echo MERGED ;; *headRefName*) echo feature5 ;; *) exit 0 ;; esac\n' > "$work/pc/bin/gh"
  out=$(cd "$work/pc/repo" && PATH="$work/pc/bin:$PATH" bash "$here/scripts/pr-cleanup.sh" 12 --worktree ../wt5 2>&1); rc=$?
  check "vanished worktree directory: exit 0" $rc 0
  git -C "$work/pc/repo" show-ref --verify --quiet refs/heads/feature5 && bad "branch of the vanished worktree kept" || ok "branch of the vanished worktree deleted"
fi

if run changelog; then echo "changelog"
  mkdir -p "$work/cl" && ( cd "$work/cl" && git init -q )
  f=$(cd "$work/cl" && "$here/scripts/changelog-new.sh" engineering "Overnight Line! v2" --issue 570 --pr 582)
  check "slug" "$(basename "$f" | sed 's/^[0-9-]*-engineering-//')" "overnight-line-v2.md"
  grep -q "Issue: #570  PR: #582" "$f" && ok "header" || bad "header"
  grep -q '^- *$' "$f" && bad "a stray empty bullet in the new entry" || ok "no stray bullet placeholder in the new entry"
  ( cd "$work/cl" && "$here/scripts/changelog-render.sh" -n 1 | grep -q "engineering: overnight line v2" ) && ok "render" || bad "render"
  ( cd "$work/cl" && "$here/scripts/changelog-new.sh" owner x >/dev/null 2>&1 ); check "bad role refused" $? 1
fi

if run install; then echo "install"
  # install-mac.sh against a stub claude, a fake HOME with a versioned plugin cache, and a link dir of its own.
  im="$work/im"; mkdir -p "$im/bin" "$im/home"
  printf '#!/bin/bash\ncase "$*" in --version) echo "stub 0.0" ;; "plugin install"*) echo "already installed"; exit 1 ;; *) echo "stub: $*" ;; esac\n' > "$im/bin/claude"; chmod +x "$im/bin/claude"
  cache="$im/home/.claude/plugins/cache/fzwo/agent-team"
  for v in 0.3.15 0.4.0 0.4.1-beta 0.10.0; do
    mkdir -p "$cache/$v/scripts" "$cache/$v/hooks"; cp "$here/hooks/guard.conf.example" "$cache/$v/hooks/"
    printf '#!/bin/bash\necho "stub-agentlock %s $*"\n' "$v" > "$cache/$v/scripts/agentlock"; chmod +x "$cache/$v/scripts/agentlock"
  done
  # Pre-0.4.0 locks: one to move, one whose name already exists under locks/, one bare dir that is not a lock.
  mkdir -p "$im/home/.agentlock/sim:x" "$im/home/.agentlock/ui" "$im/home/.agentlock/locks/ui" "$im/home/.agentlock/noinfo"
  echo owner=old > "$im/home/.agentlock/sim:x/info"; echo owner=old > "$im/home/.agentlock/ui/info"
  out=$(HOME="$im/home" PATH="$im/bin:$PATH" bash "$here/scripts/install-mac.sh" --bin-dir "$im/link" 2>&1); check "install-mac.sh with an installed plugin: exit 0" $? 0
  check "the linked wrapper runs the newest installed copy, by number" "$(HOME="$im/home" "$im/link/agentlock" whoami)" "stub-agentlock 0.10.0 whoami"
  [ -f "$im/home/.agentlock/guard.conf" ] && ok "guard.conf written from the example" || bad "guard.conf not written"
  [ -f "$im/home/.agentlock/locks/sim:x/info" ] && [ ! -e "$im/home/.agentlock/sim:x" ] && ok "pre-0.4.0 lock moved into locks/ (without a guard.conf too)" || bad "pre-0.4.0 lock not moved"
  [ -d "$im/home/.agentlock/ui" ] && printf '%s' "$out" | grep -q "left pre-0.4.0 lock ~/.agentlock/ui in place" && ok "colliding pre-0.4.0 lock left, with a message" || bad "colliding lock handled silently or moved: $out"
  [ -d "$im/home/.agentlock/noinfo" ] && [ ! -e "$im/home/.agentlock/locks/noinfo" ] && ok "a bare directory is not migrated" || bad "bare directory migrated"
  grep -q '^expires=0$' "$im/home/.agentlock/locks/info" 2>/dev/null && ok "migration leaves the marker that protects locks/ from a pre-0.4.0 clean" || bad "no marker after migration"
  mkdir -p "$im/home/bin"; ln -sfn "$here/scripts/agentlock" "$im/home/bin/agentlock"   # the pre-wrapper link an older install left
  mkdir -p "$im/home/.agentlock/waits/q1"; printf 'owner=agentlock-0.4.0-marker\nacquired=1\nexpires=0\nreason=not-a-lock\n' > "$im/home/.agentlock/waits/info"; printf 'owner=W\npid=%s\nsince=1\nexpires=0\nreason=r\n' "$$" > "$im/home/.agentlock/waits/q1/0000000001.$$"   # 0.4.29's wait tickets, with their marker: not a pre-0.4.0 lock
  # The kept guard.conf: one rule edited, one removed, one of the owner's own added; the installer names the first two.
  python3 - "$im/home/.agentlock/guard.conf" <<'PYX'
import sys; p=sys.argv[1]; out=[]
for l in open(p):
    if l.startswith("sim\t"): out.append("sim\tmy-own-sim-rule\n")
    elif l.startswith("device\t"): continue
    else: out.append(l)
out.append("port:3000\tnpm run dev\n"); open(p,"w").write("".join(out))
PYX
  out=$(HOME="$im/home" PATH="$im/bin:$PATH" bash "$here/scripts/install-mac.sh" --bin-dir "$im/link" 2>&1); check "second run: exit 0" $? 0
  [ "$(readlink "$im/home/bin/agentlock")" = "$im/home/.agentlock/agentlock" ] && printf '%s' "$out" | grep -q "repointed the older link" && ok "an older ~/bin link is repointed at the wrapper" || bad "older ~/bin link left: $(readlink "$im/home/bin/agentlock")"
  printf '%s' "$out" | grep -q "kept existing" && printf '%s' "$out" | grep -q "stub-agentlock 0.10.0 check-conf" && ok "a kept guard.conf is checked with check-conf" || bad "kept guard.conf not checked: $out"
  [ -f "$im/home/.agentlock/waits/q1/0000000001.$$" ] && [ ! -e "$im/home/.agentlock/locks/waits" ] && ! printf '%s' "$out" | grep -q "pre-0.4.0 lock waits" && ok "the installer leaves waits/ and its tickets where they are" || bad "waits/ migrated: $(ls "$im/home/.agentlock/locks" 2>/dev/null) $(printf '%s' "$out" | grep waits)"
  printf '%s' "$out" | grep -q "kept existing ~/.agentlock/guard.conf; against this version's example it differs in: sim; lacks: device; compare with" && ok "a kept guard.conf is compared with the example rule by rule: the edited and the missing rule are named, the owner's own is not" || bad "kept conf comparison: $(printf '%s' "$out" | grep 'kept existing')"
  cp "$here/hooks/guard.conf.example" "$im/home/.agentlock/guard.conf"
  out=$(HOME="$im/home" PATH="$im/bin:$PATH" bash "$here/scripts/install-mac.sh" --bin-dir "$im/link" 2>&1); printf '%s' "$out" | grep -q "every rule of this version's example is in it unchanged" && ok "a kept guard.conf equal to the example is reported as such" || bad "equal conf: $(printf '%s' "$out" | grep 'kept existing')"
  # No installed copy at all: the link must still run something, and the script must say what.
  # Also no locks/ at all: the installer creates it with the marker, so the old copy's clean is safe from install time.
  rm -rf "$im/home/.claude" "$im/home/.agentlock/locks" "$im/home/.agentlock/ui"   # ui too: a legacy lock to migrate would make the old installer create locks/ itself
  out=$(HOME="$im/home" PATH="$im/bin:$PATH" bash "$here/scripts/install-mac.sh" --bin-dir "$im/link" 2>&1); check "no installed copy: exit 0" $? 0
  printf '%s' "$out" | grep -q "no installed copy of the plugin" && ok "no installed copy: said so" || bad "no installed copy: silent: $out"
  grep -Fq "exec \"$here/scripts/agentlock\"" "$im/home/.agentlock/agentlock" && ok "wrapper falls back to the checkout's copy" || bad "wrapper does not run the checkout's copy"
  HOME="$im/home" "$im/link/agentlock" status >/dev/null 2>&1; check "fallback wrapper runs" $? 0
  grep -q '^expires=0$' "$im/home/.agentlock/locks/info" 2>/dev/null && ok "installer creates locks/ with the marker when neither exists" || bad "no locks/info after an install without locks"
fi

if run shift; then echo "shift"
  # shift-start.sh --leftovers: a loop naming the folder and a watcher whose cwd is the folder are listed; another
  # project's watcher is not; nothing is killed. (The full start needs tmux and claude; the Mac verifies that.)
  sd="$work/shift/repo (v2) [x]"; so="$work/shift/other"; sib="$work/shift/repo (v2) [x]2"; sibc="$sd copy"; pl="$work/shift/plain"
  mkdir -p "$sd/.agent-team" "$so/.agent-team" "$sib" "$sibc" "$pl" "$work/shift/bin"
  printf '#!/bin/bash\necho "[]"\n' > "$work/shift/bin/gh"; chmod +x "$work/shift/bin/gh"
  # Bounded, and in the EXIT trap before the first one starts: an interrupted suite must not leave the very kind of
  # process this listing is about. Freeze the loops before reaping their sleeps, or a loop starts its next sleep in between.
  lp=""; wp=""; op=""; sp=""; cp_=""; dp=""; qp=""
  stop_standins() { kill -STOP $lp $sp $cp_ $dp $qp 2>/dev/null; pkill -P "$lp,$sp,$cp_,$dp,$qp" 2>/dev/null; kill -KILL $lp $sp $cp_ $dp $qp 2>/dev/null; kill $wp $op 2>/dev/null; }
  trap 'stop_standins; rm -rf "$work"' EXIT
  bash -c "cd '$sd' && for i in 1 2 3 4 5; do sleep 60; done" >/dev/null 2>&1 & lp=$!
  ( cd "$sd" && PATH="$work/shift/bin:$PATH" exec python3 "$here/scripts/watch-github.py" --role engineering --repo x/y --interval 60 --exit-on-input --max-minutes 5 >/dev/null 2>&1 ) & wp=$!
  ( cd "$so" && PATH="$work/shift/bin:$PATH" exec python3 "$here/scripts/watch-github.py" --role design --repo x/y --interval 60 --exit-on-input --max-minutes 5 >/dev/null 2>&1 ) & op=$!
  bash -c "cd '$sib' && for i in 1 2 3 4 5; do sleep 60; done" >/dev/null 2>&1 & sp=$!   # names a sibling folder, Project2 to Project
  bash -c "cd '$sibc' && for i in 1 2 3 4 5; do sleep 60; done" >/dev/null 2>&1 & cp_=$!   # a quoted sibling with a space, "Project copy"
  bash -c "ls $pl>/dev/null; for i in 1 2 3 4 5; do sleep 60; done" >/dev/null 2>&1 & dp=$!   # the folder followed by a shell delimiter (no pipeline: a subshell's sleep would escape the reaping)
  bash -c "for i in 1 2 3 4 5; do sleep 60; done; eval 'ls $pl'" >/dev/null 2>&1 & qp=$!   # the folder unquoted inside a quoted string: a closing quote follows it
  sleep 2
  out=$(bash "$here/scripts/shift-start.sh" --leftovers "$sd" 2>&1); rc=$?
  check "--leftovers exits 0" $rc 0
  printf '%s\n' "$out" | grep -q "^ *$lp " && ok "a loop naming the folder is listed" || bad "loop not listed: $out"
  printf '%s\n' "$out" | grep -q "^ *$wp .*watch-github.py --role engineering" && ok "the folder's own watcher is listed" || bad "own watcher not listed: $out"
  printf '%s\n' "$out" | grep -q "^ *$op " && bad "another project's watcher listed as a leftover" || ok "another project's watcher is not listed"
  printf '%s\n' "$out" | grep -q "^ *$sp " && bad "a process naming a sibling folder (name prefix) listed as a leftover" || ok "a sibling folder's process is not listed"
  printf '%s\n' "$out" | grep -q "^ *$cp_ " && bad "a quoted sibling with a space ('… copy') listed as a leftover" || ok "a quoted sibling with a space is not listed"
  kill -0 $lp 2>/dev/null && kill -0 $wp 2>/dev/null && kill -0 $op 2>/dev/null && kill -0 $sp 2>/dev/null && kill -0 $cp_ 2>/dev/null && kill -0 $dp 2>/dev/null && ok "nothing was killed" || bad "the listing killed something"
  out=$(bash "$here/scripts/shift-start.sh" --leftovers "$pl" 2>&1)
  printf '%s\n' "$out" | grep -q "^ *$dp " && ok "the folder followed by a redirect is listed" || bad "folder before a delimiter not listed: $out"
  printf '%s\n' "$out" | grep -q "^ *$qp " && ok "the folder followed by a closing quote is listed" || bad "folder before a closing quote not listed: $out"
  out=$(bash "$here/scripts/shift-start.sh" --leftovers "$so" 2>&1)
  printf '%s\n' "$out" | grep -q "^ *$op " && ok "the other folder lists its own watcher" || bad "other folder's watcher not listed: $out"
  # --began: the start is read from the state file on origin/main or in the working tree, not from the screen.
  mkdir -p "$work/shift/remote.git" "$work/shift/sr"; ( cd "$work/shift/remote.git" && git init -q --bare )
  ( cd "$work/shift/sr" && git init -q && git remote add origin "$work/shift/remote.git" && mkdir -p .agent-team && printf 'Shift: 6 ended 2026-11-06\n' > .agent-team/state.md && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m s && git branch -M main && git push -q origin main 2>/dev/null )
  ( cd "$work/shift/sr" && bash "$here/scripts/shift-start.sh" --began 7 . ); check "--began: not started yet, exit 1" $? 1
  ( cd "$work/shift/sr" && printf 'Shift: 7 started 2026-11-06\n' > .agent-team/state.md && bash "$here/scripts/shift-start.sh" --began 7 . ); check "--began: the working tree says started, exit 0" $? 0
  ( cd "$work/shift/sr" && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m s7 && git push -q origin main && git checkout -q -b elsewhere && printf 'Shift: 6 ended 2026-11-06\n' > .agent-team/state.md && bash "$here/scripts/shift-start.sh" --began 7 . ); check "--began: origin/main says started while the tree does not, exit 0" $? 0
  ( cd "$work/shift/sr" && bash "$here/scripts/shift-start.sh" --began 8 . ); check "--began: a later shift is not started, exit 1" $? 1
  ( cd "$work/shift/sr" && git checkout -q main && printf 'Shift: 7 ended 2026-11-06\n' > .agent-team/state.md && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m e7 && git push -q origin main 2>/dev/null && bash "$here/scripts/shift-start.sh" --began 7 . ); check "--began: an ended shift did begin (tree and origin both say ended), exit 0" $? 0
  ( cd "$work/shift/sr" && bash "$here/scripts/shift-start.sh" --began 6 . ); check "--began: an earlier shift than the current one did begin, exit 0" $? 0
  ( cd "$work/shift/sr" && bash "$here/scripts/shift-start.sh" --began 8 . ); check "--began: a later shift than an ended one has not, exit 1" $? 1
  ( cd "$work/shift/sr" && bash "$here/scripts/shift-start.sh" --began x . 2>/dev/null ); check "--began: a bad number is a bad call, exit 2" $? 2
  bash "$here/scripts/shift-start.sh" --began 7 "$work/shift/nowhere" 2>/dev/null; check "--began: a missing folder is a bad call, exit 2" $? 2
  out=$(cd "$work/shift/sr" && git remote set-url origin /nonexistent/remote.git && bash "$here/scripts/shift-start.sh" --began 9 . 2>&1; git remote set-url origin "$work/shift/remote.git")   # 9: the tree does not answer, so the fetch is reached
  printf '%s' "$out" | grep -q "could not fetch origin/main" && ok "--began says when origin/main cannot be read" || bad "a failed fetch was silent: $out"
  h=$(bash "$here/scripts/shift-start.sh" --help); printf '%s' "$h" | grep -q -- '--began N' && [ "$(printf "%s" "$h" | tail -1)" = "long tool timeout; the tmux session survives the script either way. Needs tmux (brew install tmux)." ] && ok "--help prints the whole header" || bad "--help is cut short or misses --began: $(printf '%s' "$h" | tail -1)"
  [ -z "$(ls -d "${TMPDIR:-/tmp}"/shift-start.* 2>/dev/null)" ] && ok "--began leaves no scratch git directory behind" || bad "scratch git directory left: $(ls -d "${TMPDIR:-/tmp}"/shift-start.*)"
  # The fetch never touches the session's own repository: FETCH_HEAD stays as it was.
  ( cd "$work/shift/sr" && git checkout -q main && rm -f .git/FETCH_HEAD && bash "$here/scripts/shift-start.sh" --began 7 . >/dev/null; [ ! -e .git/FETCH_HEAD ] ) && ok "--began does not fetch in the repository itself" || bad "--began fetched in the session's repository"
  # The start itself, with tmux and claude stubbed (the Mac verifies the real ones): the successor case, run from inside
  # the ending shift's own tmux session, leaves that session alone, closes older ended ones, and clears Claude Code's
  # nesting markers for the new claude; from a terminal the ended previous session is closed as before.
  tl="$work/shift/tmux.log"; ta="$work/shift/tmux.alive"; tc="$work/shift/tmux.cur"; mkdir -p "$work/shift/home"
  cat > "$work/shift/bin/tmux" <<'STUB'
#!/bin/bash
echo "$*" >> "$TMUX_STUB_LOG"
case "$1" in
  has-session) grep -qx "${3#=}" "$TMUX_STUB_ALIVE" ;;
  display-message) cat "$TMUX_STUB_CUR" ;;
  list-panes) case "$*" in *pane_pid*) printf '%s\n' 4194305 "${TMUX_STUB_PANEPID:-4194306}" ;;   # two panes: the owner's extra window first, the shift's own second (pids above any real one)
      *) n="${4#=}"; if [ "$n" = "${TMUX_STUB_DISC:-none}" ]; then printf '%%0\n%%disc\n'; elif [ "$n" = "${TMUX_STUB_AUTH:-none}" ]; then printf '%%auth\n'; else printf '%%0\n'; fi ;; esac ;;   # pane ids: the archived session's text sits in its second pane
  kill-session) grep -vx "${3#=}" "$TMUX_STUB_ALIVE" > "$TMUX_STUB_ALIVE.t"; mv "$TMUX_STUB_ALIVE.t" "$TMUX_STUB_ALIVE" ;;
  new-session) echo "$4" >> "$TMUX_STUB_ALIVE" ;;
  show-environment) printf '%s\n' "-CLAUDE_GONE" "CLAUDE_SERVER_LEAK=x_CLAUDE_INVAL=1" "TERM=screen" ;;   # a removed variable, a flattened multi-line value, an unrelated one
  run-shell) ;;
  capture-pane) case "$*" in *" %disc"*) printf '%s\n' "Remote Control disconnected — this session was ended or archived from another" "  device or app (code 4090)" ;;
    *" %auth"*) echo "Remote Control disconnected — run /login to restore Remote Control" ;; *) echo "shift $TMUX_STUB_N started" ;; esac ;;
esac
STUB
  printf '#!/bin/bash\nexit 0\n' > "$work/shift/bin/claude"; chmod +x "$work/shift/bin/tmux" "$work/shift/bin/claude"
  printf '#!/bin/bash\n# the owner'"'"'s login shell: sets two pieces of Claude Code configuration (two, so a list matched wrongly shows)\n[ "$1" = -lic ] && { echo __shift_start_env__; echo CLAUDE_OWNER_CONF=1; echo HOME=x; echo CLAUDE_CODE_USE_BEDROCK=1; echo CLAUDE_EFFORT=high; exit 0; }\nexit 1\n' > "$work/shift/bin/fakeshell"; chmod +x "$work/shift/bin/fakeshell"
  printf '#!/bin/bash\nexit 0\n' > "$work/shift/bin/handoffshell"; chmod +x "$work/shift/bin/handoffshell"   # a profile that execs another shell: exit 0, nothing printed
  printf '#!/bin/bash\nexit 1\n' > "$work/shift/bin/brokenshell"; chmod +x "$work/shift/bin/brokenshell"   # a login shell that fails under env -i (a profile that execs tmux)
  start() { ( cd "$work/shift/sr" && HOME="$work/shift/home" PATH="$work/shift/bin:$PATH" SHELL="$work/shift/bin/fakeshell" TMUX_STUB_LOG="$tl" TMUX_STUB_ALIVE="$ta" TMUX_STUB_CUR="$tc" TMUX_STUB_N=8 CLAUDECODE=1 CLAUDE_TEST_LEAK=1 CLAUDE_OWNER_CONF=1 CLAUDE_CODE_USE_BEDROCK=1 "$@" bash "$here/scripts/shift-start.sh" ${SS_ARGS---close-ended} . 2>&1 ); }   # SS_ARGS unset: --close-ended (the closing tests); SS_ARGS='': the default
  : > "$tl"; printf 'sr-shift-7\nsr-shift-6\n' > "$ta"; echo sr-shift-7 > "$tc"
  out=$(start env TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0); rc=$?
  check "successor: the start from inside the ended shift's session exits 0" $rc 0
  grep -q '^kill-session -t =sr-shift-6$' "$tl" && ok "successor: an older ended session is closed" || bad "older session not closed: $(cat "$tl")"
  grep -q '^kill-session -t =sr-shift-7$' "$tl" && bad "successor: the script closed the session it runs in" || ok "successor: the session running the script is left alone"
  printf '%s' "$out" | grep -q "shift 7's own session is starting this one" && ok "successor: says it is the own session" || bad "no note on the own session: $out"
  grep -q '^new-session -d -s sr-shift-8 -c .* env .*-u CLAUDECODE .*claude --remote-control sr shift 8 ' "$tl" && ok "successor: the new claude starts with the nesting marker cleared" || bad "new-session line: $(grep new-session "$tl")"
  grep -q '^new-session .* -u CLAUDE_CODE_ENTRYPOINT .* -u CLAUDE_TEST_LEAK .*claude ' "$tl" && ok "successor: a session's CLAUDE variable the login shell does not set is cleared" || bad "a CLAUDE variable was not cleared: $(grep new-session "$tl")"
  grep -q '^new-session .* -u CLAUDE_OWNER_CONF \| -u CLAUDE_CODE_USE_BEDROCK ' "$tl" && bad "successor: the owner's configuration from the login shell was cleared: $(grep new-session "$tl")" || ok "successor: both pieces of the owner's configuration set by the login shell survive"
  grep -q '^new-session .* -u CLAUDE_PID ' "$tl" && grep -q '^new-session .* -u CLAUDE_CODE_SESSION_ID ' "$tl" && ok "successor: the known session-state names are cleared" || bad "known names missing: $(grep new-session "$tl")"
  grep -q '^new-session .* -u CLAUDE_EFFORT ' "$tl" && bad "successor: a known name the owner's shell sets was cleared" || ok "successor: a known name the owner's login shell sets (CLAUDE_EFFORT) stays"
  grep -q '^new-session .* -u CLAUDE_SERVER_LEAK .*claude ' "$tl" && ok "successor: the tmux server's own CLAUDE variables are cleared too" || bad "the server's variable was not cleared: $(grep new-session "$tl")"
  grep -q '^new-session .* -u CLAUDE_GONE \| -u CLAUDE_INVAL \| -u TERM ' "$tl" && bad "a removed, embedded or unrelated server variable was taken as a name: $(grep new-session "$tl")" || ok "successor: only real names from the server's environment are cleared"
  grep -q '^new-session .*claude --remote-control sr shift 8 --model opus --permission-mode auto /agent-team:shift chained$' "$tl" && ok "successor: the new shift is told it is chained" || bad "first message: $(grep new-session "$tl")"
  grep -q "^run-shell -b sleep 600; tmux kill-session -t '=sr-shift-7'$" "$tl" && ok "successor: the ended session is scheduled to close after the start" || bad "no close scheduled: $(cat "$tl")"
  printf '%s' "$out" | grep -q "the ended session sr-shift-7 closes in 10 min" && ok "successor: says when the ended session closes" || bad "no close note: $out"
  printf '%s' "$out" | grep -q 'started "sr shift 8"' && ok "successor: reports the start" || bad "no start report: $out"
  pv=$(jq -r .version "$here/.claude-plugin/plugin.json")
  printf '%s' "$out" | grep -q "plugin $pv)" && ok "the start report names the plugin version (this copy's, no installed one under the scratch HOME)" || bad "no plugin version in the start report: $out"
  # With installed copies under the HOME's plugin cache, the newest of them is what the new session loads and is named.
  # Versions unlike this checkout's, so the fallback cannot pass for the branch, and shaped to trap a lexical sort.
  for cv in 0.40.9 0.40.18 0.40.10; do mkdir -p "$work/shift/home/.claude/plugins/cache/mp/agent-team/$cv/.claude-plugin"; printf '{"version":"%s"}\n' "$cv" > "$work/shift/home/.claude/plugins/cache/mp/agent-team/$cv/.claude-plugin/plugin.json"; done
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(start env TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0); rc=$?
  printf '%s' "$out" | grep -q "plugin 0.40.18)" && ok "the start report names the newest installed copy over this copy's own version" || bad "installed copies ignored or missorted: $out"
  rm -rf "$work/shift/home/.claude"
  # The owner asked the ended session for this start: not chained; and a shorter close.
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(cd "$work/shift/sr" && HOME="$work/shift/home" PATH="$work/shift/bin:$PATH" SHELL="$work/shift/bin/fakeshell" TMUX_STUB_LOG="$tl" TMUX_STUB_ALIVE="$ta" TMUX_STUB_CUR="$tc" TMUX_STUB_N=8 CLAUDECODE=1 TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0 bash "$here/scripts/shift-start.sh" --not-chained --close-ended --close-after 3 . 2>&1); rc=$?
  check "--not-chained from the own session: exits 0" $rc 0
  grep -q '^new-session .*/agent-team:shift$' "$tl" && ok "--not-chained: the successor is not told it is chained" || bad "first message: $(grep new-session "$tl")"
  grep -q "^run-shell -b sleep 180; tmux kill-session -t '=sr-shift-7'$" "$tl" && ok "--close-after 3: the close is scheduled after 180 s" || bad "close line: $(grep run-shell "$tl")"
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(SS_ARGS="--close-after 2" start env TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0); rc=$?
  grep -q "^run-shell -b sleep 120; tmux kill-session -t '=sr-shift-7'$" "$tl" && ok "--close-after alone implies --close-ended (a 0.4.18 habit keeps working)" || bad "--close-after without --close-ended closed nothing: $(cat "$tl")"
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(start env -u TMUX -u CLAUDECODE); rc=$?
  check "from a terminal: the start exits 0" $rc 0
  grep -q '^new-session .* -u CLAUDECODE .*claude ' "$tl" && ok "from a terminal: the known session-state names are still cleared" || bad "known names not cleared from a terminal: $(grep new-session "$tl")"
  grep -q '^new-session .* -u CLAUDE_TEST_LEAK ' "$tl" && bad "from a terminal: an unknown CLAUDE variable of the owner's shell was cleared" || ok "from a terminal: the terminal's own CLAUDE variables are left alone"
  grep -q '^new-session .* -u CLAUDE_SERVER_LEAK ' "$tl" && ok "from a terminal: the tmux server's stale variables are still cleared" || bad "from a terminal the server's stale variable survived: $(grep new-session "$tl")"
  grep -q '^kill-session -t =sr-shift-7$' "$tl" && ok "from a terminal: the ended previous session is closed" || bad "previous session not closed: $(cat "$tl")"
  grep -q '^new-session .*/agent-team:shift$' "$tl" && ok "from a terminal: the new shift is not chained" || bad "first message: $(grep new-session "$tl")"
  grep -q '^run-shell' "$tl" && bad "from a terminal: a close was scheduled" || ok "from a terminal: no close scheduled"
  # The default: nothing closes an ended shift's session (the owner prefers ended chats to stay in the app's active list).
  : > "$tl"; printf 'sr-shift-7\nsr-shift-6\n' > "$ta"; echo sr-shift-7 > "$tc"
  out=$(SS_ARGS= start env TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0); rc=$?
  check "default (no --close-ended), successor start: exits 0" $rc 0
  grep -q '^kill-session' "$tl" && bad "default: an ended session was closed: $(cat "$tl")" || ok "default: no ended session is closed at a successor start"
  grep -q '^run-shell' "$tl" && bad "default: a close of the own session was scheduled" || ok "default: the own session is not scheduled to close"
  printf '%s' "$out" | grep -q "it stays open until you archive it in the app" && ok "default: says the own session stays open" || bad "default: no note on the own session: $out"
  printf '%s' "$out" | grep -q "ended shifts' sessions still open .*sr-shift-6" && ok "default: the leftover is listed with how to end it" || bad "default: leftover not listed: $out"
  # A session the owner archived in the app (its pane says Remote Control disconnected) is closed by default; the other stays.
  : > "$tl"; printf 'sr-shift-7\nsr-shift-6\nsr-shift-5\n' > "$ta"; echo sr-shift-7 > "$tc"
  out=$(SS_ARGS= start env TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0 TMUX_STUB_DISC=sr-shift-6); rc=$?
  check "default, an archived session among the open ones: exits 0" $rc 0
  grep -q '^kill-session -t =sr-shift-6$' "$tl" && ok "default: the session the owner archived in the app is closed" || bad "archived session not closed: $(cat "$tl")"
  grep -q '^kill-session -t =sr-shift-5$\|^kill-session -t =sr-shift-7$' "$tl" && bad "default: a session the owner did not archive was closed: $(cat "$tl")" || ok "default: sessions the owner did not archive stay open"
  printf '%s' "$out" | grep -q "closed the tmux session of shift 6: ended, and its Remote Control was ended or archived from the app" && ok "default: says why the archived one was closed (the pane text wrapped at a word)" || bad "no note on the archived close: $out"
  printf '%s' "$out" | grep -q "still open in the app .*sr-shift-5" && ok "default: the open one is still listed" || bad "open one not listed: $out"
  # The own session already archived by the owner while the shift finished: said so, not closed, and still chained.
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"; echo sr-shift-7 > "$tc"
  out=$(SS_ARGS= start env TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0 TMUX_STUB_DISC=sr-shift-7); rc=$?
  printf '%s' "$out" | grep -q "it is already archived in the app, so the next start closes it" && ok "default: an own session already archived says so" || bad "own archived session: $out"
  grep -q '^kill-session\|^run-shell' "$tl" && bad "default: the own archived session was closed or scheduled: $(cat "$tl")" || ok "default: the own archived session is neither closed nor scheduled"
  # A disconnect for another reason (a login needed) is not an archive: the chat is still active in the app, the session stays.
  : > "$tl"; printf 'sr-shift-7\nsr-shift-5\n' > "$ta"
  out=$(SS_ARGS= start env TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0 TMUX_STUB_AUTH=sr-shift-5); rc=$?
  grep -q '^kill-session' "$tl" && bad "default: a session disconnected for a login was closed as archived: $(cat "$tl")" || ok "default: a disconnect that is not an archive keeps the session open"
  printf '%s' "$out" | grep -q "still open in the app .*sr-shift-5" && ok "default: the login-disconnected session is listed as open" || bad "not listed: $out"
  grep -q '^new-session .*/agent-team:shift chained$' "$tl" && ok "default: the successor is still told it is chained" || bad "default: first message: $(grep new-session "$tl")"
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(SS_ARGS= start env -u TMUX -u CLAUDECODE); rc=$?
  check "default, from a terminal: exits 0" $rc 0
  grep -q '^kill-session' "$tl" && bad "default, from a terminal: the ended previous session was closed" || ok "default, from a terminal: the ended previous session stays open"
  printf '%s' "$out" | grep -q "still open .*sr-shift-7" && ok "default, from a terminal: the open session is listed" || bad "default, from a terminal: not listed: $out"
  # TMUX set without TMUX_PANE (a tmux run-shell job): display-message would name the most recently created session, here
  # the leftover; the script must not take that as its own session, so the leftover is closed and the start is not chained.
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"; echo sr-shift-7 > "$tc"
  out=$(start env -u TMUX_PANE TMUX=/tmp/tmux-1/default,1,0); rc=$?
  check "TMUX without TMUX_PANE: the start exits 0" $rc 0
  grep -q '^kill-session -t =sr-shift-7$' "$tl" && ok "TMUX without TMUX_PANE: the session name is not trusted, the leftover is closed" || bad "the leftover was spared on a name read without a pane: $(cat "$tl")"
  grep -q '^new-session .*/agent-team:shift$' "$tl" && ok "TMUX without TMUX_PANE: the start is not marked chained" || bad "first message: $(grep new-session "$tl")"
  # A login shell that fails under env -i: the owner's configuration cannot be told from state, so only the known names go.
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(start env SHELL="$work/shift/bin/brokenshell" TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0); rc=$?
  check "a failing login shell: the start still exits 0" $rc 0
  grep -q '^new-session .* -u CLAUDECODE .*claude ' "$tl" && ok "a failing login shell: the known names are cleared" || bad "known names not cleared: $(grep new-session "$tl")"
  grep -q '^new-session .* -u CLAUDE_OWNER_CONF \| -u CLAUDE_TEST_LEAK \| -u CLAUDE_SERVER_LEAK ' "$tl" && bad "a failing login shell: unknown names were cleared although the owner's set could not be read: $(grep new-session "$tl")" || ok "a failing login shell: only the known names are cleared"
  # The probe through a real login shell: bash with a HOME whose profile exports a CLAUDE variable (the Mac could not edit
  # the owner's .zshrc for this; here HOME is the suite's). The variable survives, the session's leak does not.
  mkdir -p "$work/shift/home2"; printf 'export CLAUDE_TEST_CONF=1\n' > "$work/shift/home2/.bash_profile"
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(start env HOME="$work/shift/home2" SHELL=/bin/bash CLAUDE_TEST_CONF=1 TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0); rc=$?
  check "a real bash login shell as the probe: the start exits 0" $rc 0
  grep -q '^new-session .* -u CLAUDE_TEST_CONF ' "$tl" && bad "the real login shell's export was cleared: $(grep new-session "$tl")" || ok "a real login shell's CLAUDE export survives the clearing"
  grep -q '^new-session .* -u CLAUDE_TEST_LEAK ' "$tl" && ok "a real login shell as the probe: the session's leak is still cleared" || bad "leak not cleared with a real shell: $(grep new-session "$tl")"
  # A profile that hands off to another shell: exit 0 with nothing printed is not an answer either.
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(start env SHELL="$work/shift/bin/handoffshell" TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0); rc=$?
  check "a login shell that prints nothing: the start still exits 0" $rc 0
  grep -q '^new-session .* -u CLAUDE_OWNER_CONF \| -u CLAUDE_TEST_LEAK ' "$tl" && bad "a silent login shell was taken as 'the owner sets nothing': $(grep new-session "$tl")" || ok "a login shell that prints nothing is not an answer: only the known names are cleared"
  ( cd "$work/shift/sr" && bash "$here/scripts/shift-start.sh" . --close-after 2>/dev/null ); check "--close-after without a value is a bad call, exit 2" $? 2
  ( cd "$work/shift/sr" && bash "$here/scripts/shift-start.sh" . --model 2>/dev/null ); check "--model without a value is a bad call, exit 2" $? 2
  # Without TMUX in the environment, the own session is still recognised: its pane's shell is an ancestor of the script.
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(start env -u TMUX TMUX_STUB_PANEPID=$$); rc=$?
  check "successor without TMUX in the environment: exits 0" $rc 0
  grep -q '^kill-session -t =sr-shift-7$' "$tl" && bad "the own session was closed when TMUX was not passed on" || ok "the own session is recognised by its pane's shell without TMUX"
  printf '%s' "$out" | grep -q "shift 7's own session is starting this one" && ok "successor without TMUX: says the own session stays" || bad "no note: $out"
  ( cd "$work/shift/sr" && printf 'Shift: 7 started 2026-11-06\n' > .agent-team/state.md && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m s7b && git push -q origin main 2>/dev/null )
  : > "$tl"; printf 'sr-shift-7\n' > "$ta"
  out=$(start env TMUX=/tmp/tmux-1/default,1,0 TMUX_PANE=%0); rc=$?
  check "successor before the state file says ended: refused" $rc 1
  printf '%s' "$out" | grep -q "merge the state file with 'Shift: 7 ended' first" && ok "successor: the refusal says what to merge" || bad "wrong refusal: $out"
  grep -q '^new-session' "$tl" && bad "a session was started although the previous one is not marked ended" || ok "nothing started"
  # The running shift may live in a session named for an older one (the first project's shift 11 ran in shift 10's session): while the
  # state file shows the previous shift started, an alive session of the project refuses the start and nothing is closed.
  : > "$tl"; printf 'sr-shift-6\n' > "$ta"
  out=$(start env -u TMUX -u CLAUDECODE); rc=$?
  check "previous shift started, an older-named session alive: refused" $rc 1
  printf '%s' "$out" | grep -q "shift 7 is still running .* sr-shift-6" && ok "the refusal names the alive session" || bad "wrong refusal: $out"
  grep -q '^kill-session' "$tl" && bad "a session was closed while the previous shift may be running in it" || ok "nothing closed while the previous shift may be running"
  grep -q '^new-session' "$tl" && bad "a start while the previous shift may be running" || ok "nothing started"
  # No session alive at all: the previous shift died without ending, the normal failure, and the start goes ahead.
  : > "$tl"; : > "$ta"
  out=$(start env -u TMUX -u CLAUDECODE); rc=$?
  check "previous shift started, no session alive: the start goes ahead (it died without ending)" $rc 0
  grep -q '^new-session' "$tl" && ok "the new shift is started after a dead predecessor" || bad "nothing started: $out"
  ( cd "$work/shift/sr" && printf 'Shift: 7 ended 2026-11-06\n' > .agent-team/state.md && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m e7b && git push -q origin main 2>/dev/null )
  stop_standins; wait $lp $wp $op $sp $cp_ $dp $qp 2>/dev/null
  trap 'rm -rf "$work"' EXIT
fi

if run sweep; then echo "sweep"
  # tmp-sweep.sh: only the three debris shapes, only old, only with --delete; the rest of the directory is untouched.
  sw="$work/sweep/T"; mkdir -p "$sw"
  plant() { ( cd "$sw" && for n in aaaaaa bbbbbb cccccc dddddd; do mkdir -p TemporaryDirectory.$n; : > TemporaryDirectory.$n/.keep-directory; done
    echo x > TemporaryDirectory.cccccc/extra; mkdir -p ibtoold-4194301/IB ibtoold-4194302/IB ibtoold-4194303 "ibtoold-$$/IB" keepme
    mkfifo ibtoold-4194301/IB/a.HostToRemote ibtoold-4194301/IB/a.RemoteToHost "ibtoold-$$/IB/b.HostToRemote"   # a finished tool's channels; a live pid's channels
    mkfifo ibtoold-4194302/IB/c.HostToRemote; echo y > ibtoold-4194302/IB/notes   # a regular file beside the pipes: not the shape
    mkdir -p ibtoold-4194304/IB; mkfifo ibtoold-4194304/IB/d.HostToRemote   # the shape, but new: stays
    mkdir -p ibtoold-4194305/IB; ln -s ../../ibtoold-4194301/IB/a.HostToRemote ibtoold-4194305/IB/link   # a symlink to a pipe: not the shape, stays
    mkdir -p ibtoold-4194306; ln -s ../ibtoold-4194301/IB ibtoold-4194306/IB   # IB itself a symlink to another tool's pipes: not the shape, stays
    mkdir -p targets/lonely targets/pipes; : > targets/lonely/.keep-directory; mkfifo targets/pipes/p.HostToRemote; : > targets/zero.lock   # targets of depth-1 symlinks: must survive
    ln -s targets/lonely TemporaryDirectory.linkdr; ln -s targets/pipes ibtoold-4194307; ln -s targets/zero.lock _Users_link_x.lock   # symlinks at depth 1: not the shapes
    mkdir -p ibtoold-4194308/IB; mkfifo ibtoold-4194308/IB/e.HostToRemote; : > ibtoold-4194308/IB/.hidden   # a dotfile beside the pipes: not the shape
    mkdir -p ibtoold-4194309/IB; mkfifo ibtoold-4194309/IB/f.HostToRemote; : > ibtoold-4194309/.hiddenfile   # a dotfile beside IB: not the shape
    : > "$(printf '_Users_tab\tx.lock')"   # old, held open during the run, with a name lsof escapes: the whole class must then stay
    : > _Users_new_x.lock   # the shape, but new: stays
    : > _Users_held_x.lock   # old, held open by a process during the run: stays
    mkdir -p TemporaryDirectory.eeeeee; echo content > TemporaryDirectory.eeeeee/.keep-directory   # old, marker with content: stays
    : > _private_var_folders_zz_T_proj-ios-build-abc_dd_SourcePackages_x.lock; : > _Users_me_x.lock; echo z > _private_var_folders_full.lock; : > other.lock; echo k > keepme/file
    mkdir -p instruments_old.ktrace/corespace instruments_new.ktrace other.ktrace keepme/instruments_nested.ktrace; echo t > instruments_old.ktrace/corespace/data; ln -s targets/pipes instruments_link.ktrace   # an old bundle (goes), a new one, another tool's, a symlink (stay)
    touch -h -t 202001010000 instruments_link.ktrace 2>/dev/null || true; touch -t 202001010000 instruments_old.ktrace other.ktrace keepme/instruments_nested.ktrace   # the nested one is old but below depth 1: stays
    touch -h -t 202001010000 TemporaryDirectory.linkdr ibtoold-4194307 _Users_link_x.lock 2>/dev/null || true
    touch -t 202001010000 targets/lonely targets/pipes targets/zero.lock ibtoold-4194308 ibtoold-4194309 "$(printf '_Users_tab\tx.lock')"
    touch -t 202001010000 TemporaryDirectory.aaaaaa TemporaryDirectory.bbbbbb TemporaryDirectory.cccccc TemporaryDirectory.eeeeee ibtoold-4194301 ibtoold-4194302 ibtoold-4194303 ibtoold-4194305 ibtoold-4194306 "ibtoold-$$" _private_var_folders_zz_T_proj-ios-build-abc_dd_SourcePackages_x.lock _Users_me_x.lock _Users_held_x.lock _private_var_folders_full.lock other.lock keepme ); }
  plant
  # The lock class is gated on build tools running on the machine; the Mac that runs this suite usually has one, so the
  # counting runs see a pgrep that finds nothing. One run under the real PATH checks the exit status only.
  mkdir -p "$work/sweep/nobuild"; printf '#!/bin/bash\nexit 1\n' > "$work/sweep/nobuild/pgrep"; chmod +x "$work/sweep/nobuild/pgrep"
  sweep() { PATH="$work/sweep/nobuild:$PATH" bash "$here/scripts/tmp-sweep.sh" "$@"; }
  bash "$here/scripts/tmp-sweep.sh" "$sw" >/dev/null 2>&1; check "sweep: a report run under the real PATH exits 0" $? 0
  out=$(sweep --warn-entries 5 "$sw" 2>&1); rc=$?
  check "sweep: a report run exits 0" $rc 0
  [ "$(ls -A "$sw" | wc -l | tr -d ' ')" = 30 ] && ok "sweep: a report run removes nothing" || bad "a report run removed something: $(ls -A "$sw")"
  printf '%s' "$out" | grep -q "^warning: 30 entries" && ok "sweep: warns above the entry threshold" || bad "no entry warning: $out"
  printf '%s' "$out" | grep -q "Instruments .ktrace bundles: 2; debris .*: 1; would remove: 1" && ok "sweep: counts the old trace bundle, not the new one, the symlink or another tool's .ktrace" || bad "ktrace count: $out"
  printf '%s' "$out" | grep -q "TemporaryDirectory.\* folders: 5; debris .*: 2; would remove: 2" && ok "sweep: counts the lone-marker folders older than a day, not the new one, the one with extra content or the one whose marker has content" || bad "TemporaryDirectory count: $out"
  printf '%s' "$out" | grep -q "ibtoold-\* folders: 9; debris .*: 2; would remove: 2" && ok "sweep: counts the dead tools' old pipe folders and the empty one, not the live pid's, the new one, the ones with a file, a dotfile or a symlink" || bad "ibtoold count: $out"
  if command -v lsof >/dev/null 2>&1; then
    printf '%s' "$out" | grep -q "lock files: 6; debris .*: 4; would remove: 4" && ok "sweep: counts the old zero-length path-named lock files, not the full one, the new one, the symlink or other names" || bad "lock count: $out"
    # A held lock whose name lsof escapes (a tab): the script cannot match it, so the whole class stays and the report says so.
    ( exec 3<"$sw/$(printf '_Users_tab\tx.lock')"; sleep 20 ) & tholder=$!; sleep 0.5
    out=$(sweep --delete "$sw" 2>&1); trc=$?
    kill $tholder 2>/dev/null; wait $tholder 2>/dev/null
    [ $trc = 0 ] && [ -f "$sw/_Users_me_x.lock" ] && printf '%s' "$out" | grep -q "a name this script cannot match, so lock files are left alone" && ok "sweep: an open lock lsof names in escaped form keeps the whole class" || bad "escaped-name hold: rc=$trc $out / $(ls -A "$sw" | tr '\n' ' ')"
    rm -rf "$sw"; mkdir -p "$sw"; plant; rm -f "$sw/$(printf '_Users_tab\tx.lock')"
  else
    rm -f "$sw/$(printf '_Users_tab\tx.lock')"
  fi
  # During the deleting run a process holds one old lock open: it must stay.
  ( exec 3<"$sw/_Users_held_x.lock"; sleep 20 ) & holder=$!; sleep 0.5
  out=$(sweep --delete "$sw" 2>&1); rc=$?
  kill $holder 2>/dev/null; wait $holder 2>/dev/null
  [ $rc = 0 ] && ok "sweep: --delete exits 0" || bad "sweep: --delete exited $rc: $out"
  left=$(ls -A "$sw" | sort | tr '\n' ' ')
  sorted_words() { printf '%s\n' $1 | sort | tr '\n' ' '; }   # the expected list is compared as a set: the suite's pid sorts anywhere
  if command -v lsof >/dev/null 2>&1; then left_want="TemporaryDirectory.cccccc TemporaryDirectory.dddddd TemporaryDirectory.eeeeee _Users_held_x.lock _Users_new_x.lock _private_var_folders_full.lock ibtoold-$$ ibtoold-4194302 ibtoold-4194304 ibtoold-4194305 ibtoold-4194306 ibtoold-4194307 ibtoold-4194308 ibtoold-4194309 TemporaryDirectory.linkdr _Users_link_x.lock targets keepme other.lock instruments_new.ktrace instruments_link.ktrace other.ktrace "; else left_want="TemporaryDirectory.cccccc TemporaryDirectory.dddddd TemporaryDirectory.eeeeee _Users_held_x.lock _Users_me_x.lock _Users_new_x.lock _private_var_folders_full.lock _private_var_folders_zz_T_proj-ios-build-abc_dd_SourcePackages_x.lock ibtoold-$$ ibtoold-4194302 ibtoold-4194304 ibtoold-4194305 ibtoold-4194306 ibtoold-4194307 ibtoold-4194308 ibtoold-4194309 TemporaryDirectory.linkdr _Users_link_x.lock targets keepme other.lock instruments_new.ktrace instruments_link.ktrace other.ktrace "; fi
  left_want=$(sorted_words "$left_want")
  [ "$left" = "$left_want" ] && ok "sweep: --delete removes exactly the debris and leaves the rest (the held lock, the new items and the marker with content stay)" || bad "sweep left '$left', wanted '$left_want'"
  [ -f "$sw/keepme/file" ] && [ -d "$sw/keepme/instruments_nested.ktrace" ] && ok "sweep: an unrelated folder keeps its content, an old bundle below depth 1 included" || bad "keepme touched: $(ls -A "$sw/keepme")"
  [ -p "$sw/ibtoold-$$/IB/b.HostToRemote" ] && ok "sweep: a live tool's pipes stay" || bad "a live pid's ibtoold folder was touched"
  [ -L "$sw/ibtoold-4194305/IB/link" ] && ok "sweep: a symlink to a pipe inside IB/ is not a pipe, the folder stays" || bad "the folder with a symlink was swept"
  [ -L "$sw/ibtoold-4194306/IB" ] && ok "sweep: an IB that is itself a symlink keeps its folder" || bad "the folder whose IB is a symlink was swept"
  [ -d "$sw/targets/pipes" ] && [ ! -e "$sw/instruments_old.ktrace" ] && ok "sweep: the old trace bundle is gone, the symlink's target bundle is untouched" || bad "ktrace: $(ls -A "$sw" | grep ktrace)"
  [ -f "$sw/targets/lonely/.keep-directory" ] && [ -p "$sw/targets/pipes/p.HostToRemote" ] && [ -f "$sw/targets/zero.lock" ] && ok "sweep: the targets of depth-1 symlinks are untouched" || bad "a symlink's target was touched: $(ls -AR "$sw/targets")"
  # A build tool running on the machine: the lock class is left alone this time, and the report says so.
  rm -rf "$sw"; mkdir -p "$sw" "$work/sweep/build"; plant
  printf '#!/bin/bash\ncase "$*" in *swift-build*) exit 0 ;; *) exit 1 ;; esac\n' > "$work/sweep/build/pgrep"; chmod +x "$work/sweep/build/pgrep"   # a build tool runs, Instruments does not
  out=$(PATH="$work/sweep/build:$PATH" bash "$here/scripts/tmp-sweep.sh" --delete "$sw" 2>&1); rc=$?
  [ $rc = 0 ] && [ -f "$sw/_Users_me_x.lock" ] && printf '%s' "$out" | grep -q "a Swift or Xcode build tool is running: lock files are left alone" && ok "sweep: with a build tool running the lock files stay and the report says why" || bad "gate: rc=$rc $out / $(ls -A "$sw")"
  [ ! -d "$sw/TemporaryDirectory.aaaaaa" ] && ok "sweep: with a build tool running the folders are still swept" || bad "folders not swept under the gate"
  [ ! -e "$sw/instruments_old.ktrace" ] && ok "sweep: a build tool does not gate the trace bundles" || bad "ktrace gated by a build tool: $out"
  rm -rf "$sw"; mkdir -p "$sw" "$work/sweep/trace"; plant
  printf '#!/bin/bash\ncase "$*" in *xctrace*) exit 0 ;; *) exit 1 ;; esac\n' > "$work/sweep/trace/pgrep"; chmod +x "$work/sweep/trace/pgrep"   # Instruments runs, no build tool
  out=$(PATH="$work/sweep/trace:$PATH" bash "$here/scripts/tmp-sweep.sh" --delete "$sw" 2>&1); rc=$?
  [ $rc = 0 ] && [ -d "$sw/instruments_old.ktrace" ] && printf '%s' "$out" | grep -q "Instruments .ktrace bundles: 2; debris .*: 0; removed: 0 (Instruments or xctrace is running: trace bundles are left alone" && ok "sweep: with Instruments running the trace bundles stay, counted, and the report says why" || bad "ktrace gate: rc=$rc $out"
  [ ! -f "$sw/_Users_me_x.lock" ] && [ ! -d "$sw/TemporaryDirectory.aaaaaa" ] && ok "sweep: Instruments does not gate the other classes" || bad "other classes gated by Instruments"
  # Without lsof the lock files cannot be told from open ones: they stay, and the report says why.
  rm -rf "$sw"; mkdir -p "$sw" "$work/sweep/nolsof"; plant
  for t in bash ls find rm rmdir wc tr cat sed sort head mkdir pwd dirname basename touch kill mkfifo sleep; do p=$(command -v $t) && ln -sf "$p" "$work/sweep/nolsof/$t"; done
  out=$(PATH="$work/sweep/nolsof" bash "$here/scripts/tmp-sweep.sh" --delete "$sw" 2>&1); rc=$?
  check "sweep without lsof: exits 0" $rc 0
  [ -f "$sw/_Users_me_x.lock" ] && printf '%s' "$out" | grep -q "lsof not found: lock files are left alone" && ok "sweep without lsof: lock files stay and the report says why" || bad "without lsof: $out / $(ls -A "$sw")"
  [ ! -d "$sw/TemporaryDirectory.aaaaaa" ] && ok "sweep without lsof: the folders are still swept" || bad "folders not swept without lsof"
  # The refusal, by message, not exit code (2 is also "no such directory"). //etc and // are what bash keeps of a doubled slash.
  # The given-name check (macOS: /etc given, /private/etc resolved) cannot be built here without root; /private/etc is tried for the Mac's run.
  ln -s /etc "$work/sweep/to-etc"; refused=1; for d in / // "$HOME" /usr //usr /etc /etc/ //etc "$work/sweep/to-etc"; do out=$(bash "$here/scripts/tmp-sweep.sh" --delete "$d" 2>&1); [ $? = 2 ] && printf '%s' "$out" | grep -q "refusing to sweep" || { refused=""; bad "sweep accepted $d: $out"; }; done; [ -z "$refused" ] || ok "sweep: refuses /, the home, system directories, with a trailing or a doubled slash, and a symlink to one"
  mkdir -p "$work/sweep/cdp2/scratch" "$work/sweep/elsewhere/scratch"; : > "$work/sweep/elsewhere/scratch/x"; out=$(cd "$work/sweep/cdp2" && CDPATH="$work/sweep/elsewhere" bash "$here/scripts/tmp-sweep.sh" scratch 2>&1); printf '%s' "$out" | grep -q "cdp2/scratch: 0 entries" && ok "sweep: a relative directory is the one named, not CDPATH's match" || bad "CDPATH match swept: $out"
  [ -d /private/etc ] && { bash "$here/scripts/tmp-sweep.sh" /private/etc 2>&1 | grep -q "refusing to sweep" && ok "sweep: refuses /private/etc (macOS)" || bad "sweep accepted /private/etc"; } || true
  bash "$here/scripts/tmp-sweep.sh" --delete "$work/sweep/nowhere" >/dev/null 2>&1; check "sweep: a missing directory is a bad call, exit 2" $? 2
  TMPDIR= bash "$here/scripts/tmp-sweep.sh" >/dev/null 2>&1; check "sweep: no TMPDIR and no argument is a bad call, exit 2" $? 2
  h=$(bash "$here/scripts/tmp-sweep.sh" --help); printf '%s' "$h" | grep -q -- '--age-hours' && [ "$(printf '%s' "$h" | tail -1)" = "are not debris; the project's worktree hook removes those." ] && ok "sweep: --help prints the whole header" || bad "sweep --help: $(printf '%s' "$h" | tail -1)"
fi

if run merge; then echo "merge"
  # pr-merge.sh: refuses while main has moved past the branch, while GitHub has not computed mergeability or reports a
  # conflict; merges, waits for MERGED, prints the next steps. gh is a stub driven by files; git is a real repo with an origin.
  mg="$work/merge"; mkdir -p "$mg/bin" "$mg/stub"; gitm() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
  cat > "$mg/bin/gh" <<'GH'
#!/bin/bash
d="$STUB"; echo "$*" >> "$d/calls"
case "$*" in
  "pr view "*"--json state"*) if [ -f "$d/state-reads" ]; then r=$(( $(cat "$d/state-reads") + 1 )); echo $r > "$d/state-reads"; [ -f "$d/merged-visible-at" ] && [ "$r" -lt "$(cat "$d/merged-visible-at")" ] && { echo OPEN; exit 0; }; fi; cat "$d/state" ;;
  "pr view "*"--json baseRefName"*) echo main ;;
  "pr view "*"--json headRefName"*) echo feature ;;
  "pr view "*"--json mergeable"*) n=$(cat "$d/polls" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$d/polls"
    [ "$n" = 1 ] && [ -f "$d/on-first-poll" ] && . "$d/on-first-poll"   # the world moves while the script waits
    [ -f "$d/err-at" ] && [ "$n" = "$(cat "$d/err-at")" ] && { echo "HTTP 502 Bad Gateway" >&2; exit 1; }
    if [ -f "$d/flip-at" ] && [ "$n" -ge "$(cat "$d/flip-at")" ]; then echo MERGEABLE; else cat "$d/mergeable"; fi ;;
  "pr merge "*) if [ -f "$d/merge-fails" ]; then echo "GraphQL: Pull Request is not mergeable" >&2; exit 1; fi; echo "$*" > "$d/merge-call"; echo MERGED > "$d/state"; echo 0 > "$d/state-reads"; echo merged ;;
  *) echo "stub gh: $*" >&2; exit 1 ;;
esac
GH
  chmod +x "$mg/bin/gh"
  git init -q --bare "$mg/origin.git" && git -C "$mg/origin.git" symbolic-ref HEAD refs/heads/main
  gitm clone -q "$mg/origin.git" "$mg/co" 2>/dev/null; ( cd "$mg/co" && gitm commit -q --allow-empty -m base1 && gitm push -q origin HEAD:main && gitm checkout -q -b feature && gitm commit -q --allow-empty -m f1 && gitm push -q origin feature && gitm checkout -q main )
  gitm clone -q "$mg/origin.git" "$mg/other" 2>/dev/null   # another agent's clone: its pushes are not in co's origin/* until fetched
  reset_stub() { rm -f "$mg/stub/"*; echo OPEN > "$mg/stub/state"; echo MERGEABLE > "$mg/stub/mergeable"; }
  pm() { ( cd "$mg/co" && STUB="$mg/stub" PR_MERGE_POLL=0 PATH="$mg/bin:$PATH" bash "$here/scripts/pr-merge.sh" "$@" ); }
  reset_stub; echo MERGED > "$mg/stub/state"; pm 7 >/dev/null 2>&1; check "merge: a PR that is not OPEN is refused, exit 1" $? 1
  reset_stub; echo CLOSED > "$mg/stub/state"; out=$(pm 7 2>&1); printf '%s' "$out" | grep -q "is CLOSED, not OPEN" && ! grep -q "pr merge" "$mg/stub/calls" && ok "merge: a closed PR: the message says so and nothing is merged" || bad "closed PR: $out"
  # main moves past the branch: refused with the instruction; no merge call.
  ( cd "$mg/other" && gitm pull -q --ff-only origin main && gitm commit -q --allow-empty -m base2 && gitm push -q origin HEAD:main )
  reset_stub; out=$(pm 7 2>&1); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q "origin/main has 1 commit(s) that #7 (feature) does not. Merge main into feature, rerun the build and the tests the PR touches" && ! grep -q "pr merge" "$mg/stub/calls" && ok "merge: main moved past the branch: refused with the instruction, nothing merged" || bad "main moved: rc=$rc $out"
  # the branch takes main in: the check passes
  ( cd "$mg/co" && gitm fetch -q origin && gitm checkout -q feature && gitm merge -q --no-edit origin/main && gitm push -q origin feature && gitm checkout -q main )
  reset_stub; echo CONFLICTING > "$mg/stub/mergeable"; out=$(pm 7 2>&1); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q "CONFLICTING" && ! grep -q "pr merge" "$mg/stub/calls" && ok "merge: CONFLICTING is refused, nothing merged" || bad "conflicting: rc=$rc $out"
  reset_stub; echo UNKNOWN > "$mg/stub/mergeable"; out=$(pm 7 --wait-mergeable 2 2>&1); rc=$?   # 2 s: with a 1 s wait a second boundary once let a single poll through
  [ $rc = 1 ] && printf '%s' "$out" | grep -q "still UNKNOWN after 2s" && printf '%s' "$out" | grep -q "never merge on UNKNOWN" && ! grep -q "pr merge" "$mg/stub/calls" && [ "$(cat "$mg/stub/polls")" -ge 2 ] && ok "merge: UNKNOWN that stays is refused after the wait, polled, nothing merged" || bad "unknown: rc=$rc polls=$(cat "$mg/stub/polls" 2>/dev/null) $out"
  reset_stub; echo UNKNOWN > "$mg/stub/mergeable"; echo 3 > "$mg/stub/flip-at"; out=$(pm 7 --wait-mergeable 30 2>&1); rc=$?
  hs=$(git -C "$mg/co" rev-parse origin/feature)
  [ $rc = 0 ] && [ "$(cat "$mg/stub/polls")" -ge 3 ] && [ "$(cat "$mg/stub/merge-call")" = "pr merge 7 --merge --match-head-commit $hs" ] && printf '%s' "$out" | grep -q "merged #7 (feature into main, merge), shown MERGED" && printf '%s' "$out" | grep -q "Next: pr-cleanup.sh 7" && ok "merge: UNKNOWN that turns MERGEABLE is merged once it does, naming the head commit checked, MERGED confirmed, next steps printed" || bad "flip: rc=$rc polls=$(cat "$mg/stub/polls" 2>/dev/null) call=$(cat "$mg/stub/merge-call" 2>/dev/null) $out"
  # The base moves while the script waits for mergeability: the check after the wait refuses; nothing merged.
  ( cd "$mg/other" && gitm pull -q --ff-only origin main )
  reset_stub; echo UNKNOWN > "$mg/stub/mergeable"; echo 2 > "$mg/stub/flip-at"; printf 'cd %s && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m base3 && git push -q origin HEAD:main\n' "$mg/other" > "$mg/stub/on-first-poll"
  out=$(pm 7 --wait-mergeable 30 2>&1); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q "origin/main has 1 commit(s) that #7 (feature) does not" && [ ! -f "$mg/stub/merge-call" ] && ok "merge: a base that moves during the wait is caught by the check after it, nothing merged" || bad "moved during wait: rc=$rc $out"
  ( cd "$mg/co" && gitm fetch -q origin && gitm checkout -q feature && gitm merge -q --no-edit origin/main && gitm push -q origin feature && gitm checkout -q main )
  # A gh error while polling counts as unknown until the deadline, not as a crash.
  reset_stub; echo UNKNOWN > "$mg/stub/mergeable"; echo 1 > "$mg/stub/err-at"; echo 2 > "$mg/stub/flip-at"; out=$(pm 7 --wait-mergeable 30 2>&1); rc=$?
  [ $rc = 0 ] && ok "merge: a gh error on a poll is waited out like UNKNOWN" || bad "gh error on poll: rc=$rc $out"
  # MERGED shows only on the third state read after the merge: the script waits for it.
  reset_stub; echo 3 > "$mg/stub/merged-visible-at"; out=$(pm 7 2>&1); rc=$?
  [ $rc = 0 ] && [ "$(cat "$mg/stub/state-reads")" -ge 3 ] && printf '%s' "$out" | grep -q "shown MERGED" && ok "merge: MERGED is polled for, not assumed" || bad "merged poll: rc=$rc reads=$(cat "$mg/stub/state-reads" 2>/dev/null) $out"
  reset_stub; out=$(pm 7 --method squash 2>&1); rc=$?
  [ $rc = 0 ] && grep -q -- "^pr merge 7 --squash --match-head-commit" "$mg/stub/merge-call" && printf '%s' "$out" | grep -q "(feature into main, squash)" && ok "merge: --method squash is passed through" || bad "squash: rc=$rc $(cat "$mg/stub/merge-call" 2>/dev/null) $out"
  pm 7 --method fast >/dev/null 2>&1; check "merge: an unknown --method is a usage error, exit 2" $? 2
  # The dry run runs the check after the wait too: the base moves during the wait, the dry run refuses like the real run.
  ( cd "$mg/other" && gitm pull -q --ff-only origin main )
  reset_stub; echo UNKNOWN > "$mg/stub/mergeable"; echo 2 > "$mg/stub/flip-at"; printf 'cd %s && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m base5 && git push -q origin HEAD:main\n' "$mg/other" > "$mg/stub/on-first-poll"
  out=$(pm 7 --dry-run --wait-mergeable 30 2>&1); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q "origin/main has 1 commit(s)" && [ ! -f "$mg/stub/merge-call" ] && ok "merge: --dry-run runs the check after the wait too" || bad "dry run after wait: rc=$rc $out"
  ( cd "$mg/co" && gitm fetch -q origin && gitm checkout -q feature && gitm merge -q --no-edit origin/main && gitm push -q origin feature && gitm checkout -q main )
  reset_stub; out=$(pm 7 --dry-run 2>&1); rc=$?
  [ $rc = 0 ] && printf '%s' "$out" | grep -q "dry run: #7 (feature into main, merge) would merge at $(git -C "$mg/co" rev-parse origin/feature); every check passed, nothing merged" && [ ! -f "$mg/stub/merge-call" ] && [ "$(cat "$mg/stub/state")" = OPEN ] && ok "merge: --dry-run on a current PR passes every check, says what would merge, merges nothing" || bad "dry run: rc=$rc $out"
  [ -z "$(git -C "$mg/co" for-each-ref refs/pr-merge)" ] && ok "merge: the script's own refs are gone after its runs, refused and merged alike" || bad "refs left: $(git -C "$mg/co" for-each-ref refs/pr-merge)"
  # A behind PR is refused before any mergeability poll: the first check is the fast path.
  ( cd "$mg/other" && gitm pull -q --ff-only origin main && gitm commit -q --allow-empty -m base4 && gitm push -q origin HEAD:main )
  reset_stub; echo UNKNOWN > "$mg/stub/mergeable"; out=$(pm 7 --wait-mergeable 2 2>&1); rc=$?   # 2 s: with a 1 s wait a second boundary once let a single poll through
  [ $rc = 1 ] && [ ! -f "$mg/stub/polls" ] && printf '%s' "$out" | grep -q "origin/main has 1 commit(s)" && ok "merge: a behind PR is refused before mergeability is polled" || bad "fast path: rc=$rc polls=$(cat "$mg/stub/polls" 2>/dev/null) $out"
  reset_stub; pm 7 --dry-run >/dev/null 2>&1; check "merge: --dry-run on a behind PR exits 1 like the real run" $? 1
  ( cd "$mg/co" && gitm fetch -q origin && gitm checkout -q feature && gitm merge -q --no-edit origin/main && gitm push -q origin feature && gitm checkout -q main )
  reset_stub; : > "$mg/stub/merge-fails"; out=$(pm 7 2>&1); rc=$?
  [ $rc = 1 ] && printf '%s' "$out" | grep -q "gh pr merge refused #7; nothing was merged. Do not close the issue" && [ "$(cat "$mg/stub/state")" = OPEN ] && ok "merge: a refused gh pr merge exits 1 and says not to close the issue" || bad "merge refused: rc=$rc $out"
  pm x >/dev/null 2>&1; check "merge: a non-numeric PR is a usage error, exit 2" $? 2
  out=$(pm 7 8 2>&1); rc=$?; [ $rc = 2 ] && printf '%s' "$out" | grep -q "one PR number, not two (7 and 8)" && ok "merge: two PR numbers are a usage error, exit 2, that names both" || bad "two numbers: rc=$rc $out"
  pm --dry-run >/dev/null 2>&1; check "merge: no PR number is a usage error, exit 2" $? 2
  reset_stub; out=$(pm --dry-run 7 2>&1); rc=$?; [ $rc = 0 ] && printf '%s' "$out" | grep -q "dry run: #7" && ok "merge: the options may come before the PR number" || bad "options first: rc=$rc $out"
  pm 7 --bogus >/dev/null 2>&1; check "merge: an unknown option is a usage error, exit 2" $? 2
  h=$(bash "$here/scripts/pr-merge.sh" --help); printf '%s' "$h" | grep -q -- '--wait-mergeable' && [ "$(printf '%s' "$h" | tail -1)" = "default 5) is for the tests." ] && ok "merge: --help prints the whole header" || bad "merge --help: $(printf '%s' "$h" | tail -1)"
fi

if run publish; then echo "publish"
  if [ -f "$here/tests/publish.sh" ]; then . "$here/tests/publish.sh"; else echo "  (skipped: tests/publish.sh is kept out of the public copy, with scripts/publish-subs.py)"; fi
fi

echo; echo "passed $pass, failed $fail"; [ $fail -eq 0 ]
