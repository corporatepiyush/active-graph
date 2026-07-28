#!/usr/bin/env bash
# ag_wait: long-poll change notification (PLAN test_21, 9.7)
. "$(dirname "$0")/harness.bash"

R=$(new_run "wait")

# timeout path: no matching event -> empty output, rc 0, returns promptly
t0=$(date +%s)
out=$("$AG" wait --run "$R" --types x.never --timeout 700)
rc=$?; t1=$(date +%s)
t_is "$rc" 0 "timeout exits 0"
t_is "$out" "" "timeout yields empty result"
t_ok "$(( t1 - t0 <= 15 ? 0 : 1 ))" "timeout returned promptly"

# event already present -> immediate return
"$AG" emit --run "$R" --type x.ready --payload '{"r":1}' >/dev/null
out=$("$AG" wait --run "$R" --types x.ready --timeout 5000)
t_is "$(printf '%s' "$out" | jq -r .type)" x.ready "pre-existing event returns immediately"

# cross-process notification: emit from another process while waiting
S=$(printf '%s' "$out" | jq .seq)
( sleep 1; "$AG" emit --run "$R" --type x.go --payload '{"n":1}' >/dev/null ) &
BG=$!
t0=$(date +%s)
out=$("$AG" wait --run "$R" --types x.go --since "$S" --timeout 15000)
t1=$(date +%s)
wait "$BG"
t_is "$(printf '%s' "$out" | jq -r .type)" x.go "wait caught the cross-process emit"
t_ok "$(( t1 - t0 <= 30 ? 0 : 1 ))" "returned within budget after the emit"

# type filter: non-matching emits don't wake the result set
( sleep 0.5; "$AG" emit --run "$R" --type x.noise --payload '{}' >/dev/null ) &
BG=$!
out=$("$AG" wait --run "$R" --types x.go2 --since "$S" --timeout 2500)
wait "$BG"
t_is "$out" "" "non-matching type ignored (timeout, empty)"

# validation
"$AG" wait --run "$R" --timeout 999999 >/dev/null 2>&1
t_is $? 2 "timeout beyond 60000ms rejected"
"$AG" wait --run "$R" --types 'BAD TYPE' >/dev/null 2>&1
t_is $? 2 "invalid type token rejected"
t_done
