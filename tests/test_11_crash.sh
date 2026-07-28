#!/usr/bin/env bash
# crash safety: kill -9 during a write must leave the store consistent — no
# torn rows, no half-applied transaction (WAL + atomic commit) (PLAN §13).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null

# commit a known-good prefix first
R=$(new_run crash)
for i in 1 2 3 4 5; do "$AG" emit --run "$R" --type x.tick --payload "{\"kind\":\"n\",\"data\":{\"i\":$i}}" >/dev/null; done
before=$("$AG" events --run "$R" | jq -s length)
t_is "$before" 6 "prefix committed: 6 events (5 + run.started)"

# a large single-transaction batch, killed -9 mid-flight. emit-batch is ONE txn,
# so the crash must roll it back wholesale — never a partial batch.
# NB: AG_MAX_BATCH must be raised here. With the default (1000) an 8000-element
# batch is REJECTED before any work happens, the kill lands on an already-dead
# process, and the all-or-nothing assertion below passes without ever testing a
# crash mid-transaction.
CRASHN=${CRASHN:-4000}
bf="$TDIR/batch.ndjson"
awk -v n="$CRASHN" 'BEGIN{for(i=1;i<=n;i++)printf "{\"type\":\"x.tick\",\"payload\":{\"i\":%d}}\n", i}' > "$bf"
AG_MAX_BATCH=$((CRASHN + 1)) "$AG" emit-batch --run "$R" < "$bf" >/dev/null 2>&1 &
CLIP=$!
for _ in $(seq 1 100); do kill -0 "$CLIP" 2>/dev/null && break; sleep 0.02; done
kill -9 "$CLIP" 2>/dev/null
wait "$CLIP" 2>/dev/null
# the killed CLI closes its engine's input FIFO -> the sqlite child sees EOF and
# aborts the uncommitted txn. Give any orphan a moment to exit.
sleep 1

# reopen a FRESH process and inspect
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA integrity_check;')" ok "catalog integrity ok after kill -9"
t_is "$("$SQ" "$AG_DIR/seg-000001.db" 'PRAGMA integrity_check;')" ok "segment integrity ok after kill -9"
after=$("$AG" events --run "$R" | jq -s length)
# either the batch fully committed (6+8000) or fully rolled back (6) — never in between
t_ok "$([ "$after" -eq 6 ] || [ "$after" -eq $((CRASHN + 6)) ]; echo $?)" \
     "batch is all-or-nothing after crash (events=$after, expected 6 or $((CRASHN + 6)))"

# whatever survived is a contiguous seq with no gaps or duplicates
seqs=$("$AG" events --run "$R" | jq -r '.seq' | sort -n)
maxseq=$(echo "$seqs" | tail -1)
distinct=$(echo "$seqs" | sort -u | wc -l | tr -d ' ')
total=$(echo "$seqs" | wc -l | tr -d ' ')
t_is "$distinct" "$total" "no duplicate seqs after crash"
t_is "$maxseq" "$total" "seqs are contiguous 1..N after crash (max=$maxseq, count=$total)"

# store is fully usable afterwards: a new emit lands on the next seq
h=$("$AG" emit --run "$R" --type x.note --payload '{"kind":"n","data":{"post":1}}' | jq -r '.seq')
t_is "$h" "$(( total + 1 ))" "post-crash emit continues at the next contiguous seq"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA integrity_check;')" ok "integrity still ok after post-crash write"

t_done
