#!/usr/bin/env bash
# reader pool (--readers N / AG_READERS): read ops route to read-only engines,
# writes stay on the writer. Readers open every data surface read-only at the
# FILE level (?mode=ro / ?immutable=1) — that both rejects data writes AND still
# permits the temp-db writes that _bindv needs. Regression guard: a query_only
# reader silently unbound :run and returned EMPTY results (PLAN §13 test_34).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null

R=$(new_run r)
"$AG" emit --run "$R" --type llm.responded  --payload '{"model":"m1"}' --ctx '{"estimated_cost_usd":0.5,"usage":{"total_tokens":42}}' >/dev/null
"$AG" emit --run "$R" --type object.created --payload '{"kind":"doc","data":{"a":1}}' >/dev/null
"$AG" emit --run "$R" --type object.created --payload '{"kind":"doc","data":{"b":2}}' >/dev/null

# baseline (writer-served) results to compare against
base_events=$("$AG" events --run "$R" | jq -c '.seq' | paste -sd, -)
base_stats=$("$AG" stats | jq -S -c .)
t_is "$base_events" "1,2,3,4" "baseline: events served correctly by the writer"

# same read ops through a reader pool must be IDENTICAL (not silently empty)
for N in 1 2 4; do
  ev=$(AG_READERS=$N "$AG" events --run "$R" | jq -c '.seq' | paste -sd, -)
  t_is "$ev" "$base_events" "events via --readers $N match the writer (bind :run works on readers)"
  st=$(AG_READERS=$N "$AG" stats | jq -S -c .)
  t_is "$st" "$base_stats" "stats via --readers $N match the writer"
done

# a read op that binds AND verifies (verify walks lineage via :run) works on a reader
AG_READERS=2 "$AG" verify --run "$R" >/dev/null 2>&1
t_ok $? "verify --run succeeds through a reader (was broken: unbound :run)"

# writes are never served by a reader: emit routes to the writer and succeeds
AG_READERS=2 "$AG" emit --run "$R" --type x.note --payload '{"kind":"n","data":{"v":1}}' >/dev/null 2>&1
t_ok $? "emit under --readers still routes to the writer and commits"
t_is "$(AG_READERS=2 "$AG" events --run "$R" | jq -c '.seq' | paste -sd, -)" "1,2,3,4,5" "the reader sees the writer's committed row"

# a reader's data files are read-only at the FILE level: a direct INSERT into the
# catalog opened ?mode=ro is rejected by SQLite (this is what stops a reader from
# ever mutating data, now that query_only is gone).
out=$("$SQ" "file:$AG_DIR/ag-catalog.db?mode=ro" "INSERT INTO actors(aid,name) VALUES(999,'x');" 2>&1)
t_like "$out" "*readonly*" "reader's ?mode=ro catalog rejects direct INSERT (data stays immutable)"

# readers see a consistent snapshot while the writer streams a storm of events
R2=$(new_run storm)
( for i in $(seq 1 40); do "$AG" emit --run "$R2" --type x.tick --payload "{\"kind\":\"n\",\"data\":{\"i\":$i}}" >/dev/null 2>&1; done ) &
WPID=$!
race_ok=1
for _ in $(seq 1 15); do
  sleep 0.05
  n=$(AG_READERS=3 "$AG" events --run "$R2" 2>/dev/null | jq -c '.seq' | wc -l | tr -d ' ')
  [[ $n =~ ^[0-9]+$ ]] || { race_ok=0; break; }   # never empty/garbage, never a hang
done
wait "$WPID" 2>/dev/null
t_ok "$([ "$race_ok" -eq 1 ]; echo $?)" "readers return well-formed snapshots throughout a write storm (no empty/hang)"
t_is "$("$AG" events --run "$R2" | jq -c '.seq' | wc -l | tr -d ' ')" 41 "all 40 storm events + run.started present after the storm"

# WAL stays bounded: readers don't hold long-lived transactions that prevent
# checkpointing. After the write storm with active readers, a TRUNCATE
# checkpoint should succeed with busy=0 (no readers blocking cleanup).
ckpt=$("$SQ" "$AG_DIR/ag-catalog.db" "PRAGMA wal_checkpoint(TRUNCATE);")
busy=$(echo "$ckpt" | cut -d'|' -f1)
t_is "$busy" 0 "WAL checkpoint after write storm: no reader blocks cleanup (busy=0)"

# concurrent reads under a write storm: AG_READERS=2 with many CLI reads in
# parallel with a writer. The writer must not be blocked by reader activity;
# all reads must complete (no hang), and the write must commit.
R3=$(new_run pool)
( for i in $(seq 1 20); do "$AG" emit --run "$R3" --type x.note --payload "{\"i\":$i}" >/dev/null 2>&1; done ) &
W3=$!
readers_ok=1
for _ in $(seq 1 20); do
  sleep 0.05
  n=$(AG_READERS=2 "$AG" events --run "$R3" 2>/dev/null | jq -s length)
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n == 0 )); then readers_ok=0; break; fi
done
wait "$W3" 2>/dev/null
t_ok "$([ "$readers_ok" -eq 1 ]; echo $?)" "reader pool (AG_READERS=2) handles concurrent reads without hang"
t_is "$("$AG" events --run "$R3" | jq -s length)" 21 "write completed alongside reader-heavy workload (20 + run.started)"

# explain works through a reader pool (requires projected objects)
R4=$(new_run explain)
"$AG" emit --run "$R4" --type object.created --payload '{"kind":"doc","data":{"x":1}}' >/dev/null
"$AG" project --run "$R4" >/dev/null
OBJ=$("$AG" graph --run "$R4" --kind doc | jq -r .id)
AG_READERS=2 "$AG" explain --run "$R4" --obj "$OBJ" >/dev/null 2>&1
t_ok $? "explain --run works through a reader pool"

t_done
