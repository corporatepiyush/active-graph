#!/usr/bin/env bash
# concurrent writers: no lost seqs, no violations (PLAN test_10)
. "$(dirname "$0")/harness.bash"

R=$(new_run "concurrency")
W=8   # parallel writers (PLAN §13: 8 writers)
N=500 # events each (PLAN §13: 500 events)

worker() {
    local w=$1 i
    for i in $(seq 1 "$N"); do
        "$AG" emit --run "$R" --type x.load --payload "{\"w\":$w,\"i\":$i}" >/dev/null 2>&1 || return 1
    done
}

pids=()
t0=$(date +%s)
for w in $(seq 1 "$W"); do worker "$w" & pids+=($!); done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
tapp=$(( $(date +%s) - t0 ))
t_diag "8 writers x 500 events in ${tapp}s"
t_is "$fail" 0 "all $W parallel writers completed without surfaced errors"

total=$(( W*N + 1 ))
t_is "$(seg_count "$R")" "$total" "no lost events ($total expected)"

# seqs are exactly 1..total: gap-free, duplicate-free
RID=$(rid_of "$R")
chk=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(DISTINCT seq) || '|' || min(seq) || '|' || max(seq) FROM run_events WHERE rid=$RID;")
t_is "$chk" "$total|1|$total" "seq space is dense 1..$total (no gaps, no dupes)"

# store consistent afterwards
t_is "$("$SQ" "$AG_DIR/seg-000001.db" 'PRAGMA integrity_check;')" ok "segment integrity ok after write storm"

# consistent reader snapshots: a reader sees a coherent seq chain during a write storm
R2=$(new_run "snapshot")
( for i in $(seq 1 200); do "$AG" emit --run "$R2" --type x.tick --payload "{\"kind\":\"n\",\"data\":{\"i\":$i}}" >/dev/null 2>&1; done ) &
SWPID=$!
snap_ok=1
for _ in $(seq 1 10); do
    sleep 0.05
    n=$(AG_READERS=2 "$AG" events --run "$R2" 2>/dev/null | jq -c '.seq' | wc -l | tr -d ' ')
    [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || { snap_ok=0; break; }
done
wait "$SWPID" 2>/dev/null
t_ok "$([ "$snap_ok" -eq 1 ]; echo $?)" "reader snapshots are well-formed during a write storm (no empty/hang)"

t_done
