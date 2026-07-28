#!/usr/bin/env bash
# The three surfaces PLAN specifies that had no implementation at all:
# ag_scan (§7.5/§9), ag_insights (§4.2/§7.5), ag_migrate (§9/§8.5b).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null

# ---------------------------------------------------------------------------
# ag_insights — cost/token/latency, read entirely off the VIRTUAL ctx columns.
# ---------------------------------------------------------------------------
R=$(new_run insights)
q=$("$AG" emit --run "$R" --type llm.requested --payload '{"model":"gpt-4o","p":"a"}')
qs=$(printf '%s' "$q" | jq -r .seq)
"$AG" emit --run "$R" --type llm.responded --caused-by "$qs" --payload '{"model":"gpt-4o","t":"a"}' \
      --ctx '{"estimated_cost_usd":0.02,"usage":{"total_tokens":250},"dur_ms":900}' >/dev/null
"$AG" emit --run "$R" --type llm.responded --payload '{"model":"gpt-4o","t":"b"}' \
      --ctx '{"estimated_cost_usd":0.03,"usage":{"total_tokens":150},"dur_ms":100}' >/dev/null
"$AG" emit --run "$R" --type tool.responded --payload '{"name":"search"}' --ctx '{"dur_ms":40}' >/dev/null
"$AG" emit --run "$R" --type tool.responded --payload '{"name":"search"}' --ctx '{"dur_ms":60}' >/dev/null

ins=$("$AG" insights --run "$R")
t_ok $? "insights --run succeeds"
t_is "$(echo "$ins" | jq -r .scope)" "$R" "scope names the run"
t_is "$(echo "$ins" | jq -r .cost_usd)" 0.05 "cost summed from ctx"
t_is "$(echo "$ins" | jq -r .tokens)" 400 "tokens summed from ctx"
t_is "$(echo "$ins" | jq -r .dur_ms)" 1100 "latency summed from ctx"
t_is "$(echo "$ins" | jq -r '.by_model[]|select(.model=="gpt-4o")|"\(.n),\(.cost_usd),\(.dur_ms_min),\(.dur_ms_avg),\(.dur_ms_max)"')" \
     "3,0.05,100,500,900" "per-model n/cost/min/avg/max"
t_is "$(echo "$ins" | jq -r '.by_tool[]|select(.tool=="search")|"\(.n),\(.dur_ms_min),\(.dur_ms_avg),\(.dur_ms_max),\(.dur_ms_total)"')" \
     "2,40,50,60,100" "per-tool latency distribution"
t_is "$(echo "$ins" | jq -r '.cache|"\(.requests),\(.answered)"')" "1,1" "cache request/answered counts"
t_is "$(echo "$ins" | jq -r '.by_type[]|select(.type=="tool.responded")|.n')" 2 "per-type breakdown"

# whole-store scope
sins=$("$AG" insights)
t_is "$(echo "$sins" | jq -r .scope)" store "insights with no --run reports store scope"
t_ok "$([ "$(echo "$sins" | jq -r .cost_usd)" = 0.05 ]; echo $?)" "store cost matches the only run"
"$AG" insights --run "$R" --limit 0 >/dev/null 2>&1
t_is $? 2 "insights validates --limit"
"$AG" insights --run 'not-a-run' >/dev/null 2>&1
t_is $? 2 "insights validates --run"

# ---------------------------------------------------------------------------
# ag_scan — raw SQL, one read-only process per segment, :seg bound.
# ---------------------------------------------------------------------------
out=$("$AG" scan "SELECT json_object('seg', :seg, 'n', count(*)) FROM run_events;")
t_ok $? "scan runs"
t_is "$(echo "$out" | jq -r .seg)" 1 "the segment id is bound as :seg"
t_is "$(echo "$out" | jq -r .n)" 6 "scan sees the segment's events"

out=$("$AG" scan "SELECT json_object('t', t.name, 'n', count(*)) FROM run_events e JOIN cat.event_types t ON t.tid=e.tid GROUP BY t.name ORDER BY t.name;")
t_ok $? "scan can join the catalog (attached read-only as cat)"
t_is "$(echo "$out" | jq -sr 'map(select(.t=="llm.responded"))[0].n')" 2 "catalog join returns correct rows"

# READ-ONLY BY CONSTRUCTION, not by blacklist: the connection itself is readonly.
err=$("$AG" scan "DELETE FROM run_events;" 2>&1 >/dev/null); rc=$?
t_is "$rc" 2 "scan refuses a DELETE"
t_like "$err" "*readonly*" "the refusal comes from the engine, not a keyword filter"
t_is "$("$SQ" "$AG_DIR/seg-000001.db" 'SELECT count(*) FROM run_events;')" 6 "no rows were deleted"
"$AG" scan "UPDATE run_events SET seq = 99;" >/dev/null 2>&1
t_is $? 2 "scan refuses an UPDATE"
"$AG" scan "CREATE TABLE evil(x);" >/dev/null 2>&1
t_is $? 2 "scan refuses DDL"
"$AG" scan "ATTACH '$TDIR/evil.db' AS evil; CREATE TABLE evil.x(a);" >/dev/null 2>&1
t_is $? 2 "scan cannot attach-and-create a new database"
t_ok "$([ ! -f "$TDIR/evil.db" ]; echo $?)" "no side-effect file was created"
"$AG" scan "SELECT nope FROM nothing;" >/dev/null 2>&1
t_is $? 2 "a bad query fails loudly instead of silently returning nothing"
"$AG" scan >/dev/null 2>&1
t_is $? 2 "scan without SQL is a usage error"
"$AG" scan --parallel 0 "SELECT 1;" >/dev/null 2>&1
t_is $? 2 "scan validates --parallel"

# multi-segment + --parallel: every segment is visited exactly once
X="$TDIR/multi"
# A payload this size cannot be an ARGV STRING: Linux caps a single argument
# at 128 KiB (MAX_ARG_STRLEN), so passing it as --payload fails with E2BIG there
# while it works on macOS. Use the file form, which is portable.
BIG=$(big_payload_file "$TDIR/big-payload.json" doc 300000)
AG_DIR="$X" "$AG" init >/dev/null
for i in 1 2 3; do
    XR=$(AG_DIR="$X" AG_SEG_MAX_BYTES=262144 "$AG" run-start --goal "s$i" | jq -r .run)
    AG_DIR="$X" "$AG" emit --run "$XR" --type object.created "--payload@$BIG" >/dev/null
    AG_DIR="$X" "$AG" run-end --run "$XR" >/dev/null
done
AG_DIR="$X" "$AG" maintain >/dev/null 2>&1
nseg=$("$SQ" "$X/ag-catalog.db" "SELECT count(*) FROM segments WHERE state IN ('active','draining','sealed','archived');")
t_ok "$([ "$nseg" -ge 3 ]; echo $?)" "store has $nseg segments (mixed sealed + active)"
res=$(AG_DIR="$X" "$AG" scan --parallel 4 "SELECT json_object('seg', :seg, 'n', count(*)) FROM run_events;")
t_is "$(echo "$res" | jq -s length)" "$nseg" "--parallel visits every segment exactly once"
t_is "$(echo "$res" | jq -s '[.[].seg]|sort|unique|length')" "$nseg" "each segment reports once (no duplicates)"
tot=$(echo "$res" | jq -s 'map(.n)|add')
t_is "$tot" "$("$AG_DIR"/../../../dev/null 2>/dev/null; echo "$(AG_DIR="$X" "$AG" stats | jq -r .events)")" \
     "scan totals equal ag_stats' whole-store event count"
sealed_only=$(AG_DIR="$X" "$AG" scan --sealed-only "SELECT json_object('seg', :seg) FROM run_events LIMIT 1;")
nsealed=$("$SQ" "$X/ag-catalog.db" "SELECT count(*) FROM segments WHERE state IN ('sealed','archived');")
t_is "$(echo "$sealed_only" | jq -s length)" "$nsealed" "--sealed-only restricts to sealed segments"

# scan must not be reachable over RPC (PLAN: CLI-only power tool)
r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ag.scan","params":{"sql":"SELECT 1"}}' | "$AG" rpc-child)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32601 "ag.scan is not an RPC method"

# ---------------------------------------------------------------------------
# ag_migrate — a real v1 store, built by the previous released script, is
# brought forward with its data intact.
# ---------------------------------------------------------------------------
V1="$TDIR/v1.sh"
if git -C "$ROOT" show HEAD:active-graph.sh > "$V1" 2>/dev/null && [ -s "$V1" ]; then
  chmod +x "$V1"
  M="$TDIR/legacy"
  if AG_DIR="$M" "$V1" init >/dev/null 2>&1; then
    LR=$(AG_DIR="$M" "$V1" run-start --goal legacy | jq -r .run)
    lq=$(AG_DIR="$M" "$V1" emit --run "$LR" --type llm.requested --payload '{"model":"m","p":"q"}')
    lqs=$(printf '%s' "$lq" | jq -r .seq)
    AG_DIR="$M" "$V1" emit --run "$LR" --type llm.responded --caused-by "$lqs" --payload '{"model":"m","t":"a"}' >/dev/null
    AG_DIR="$M" "$V1" emit --run "$LR" --type object.created --payload '{"kind":"doc","data":{"a":1}}' >/dev/null
    AG_DIR="$M" "$V1" emit --run "$LR" --type object.created --payload '{"kind":"doc","data":{"a":2}}' >/dev/null
    AG_DIR="$M" "$V1" run-end --run "$LR" >/dev/null
    before=$(AG_DIR="$M" "$V1" events --run "$LR" | jq -sc 'map({seq,type,payload})')
    # The "legacy" store is whatever the last COMMITTED build produces, so the
    # version step under test moves with the repo. Assert the relationship, not
    # a literal: older than current, and current after migrating.
    OLDV=$("$SQ" "$M/ag-catalog.db" 'PRAGMA user_version;')
    CURV=$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA user_version;')

    if [ "$OLDV" = "$CURV" ]; then
      # HEAD already ships the current schema, so there is no step to exercise.
      # Assert the no-op contract instead of pretending to test a migration.
      t_ok 0 "committed build is already schema v$CURV - no migration step to test"
      t_is "$(AG_DIR="$M" "$AG" migrate | jq -r .migrated)" false "migrate is a no-op on a current store"
      t_is "$(AG_DIR="$M" "$AG" events --run "$LR" | jq -sc 'map({seq,type,payload})')" "$before" \
           "a current-schema store opens and reads unchanged"
      t_is "$("$SQ" "$M/ag-catalog.db" "SELECT count(*) FROM sqlite_schema WHERE name='behaviors';")" 1 \
           "the behaviors table is present"
      "$SQ" "$M/ag-catalog.db" 'PRAGMA user_version=99;'
      err=$(AG_DIR="$M" "$AG" migrate 2>&1 >/dev/null); rc=$?
      t_fails "$rc" "a store newer than the binary is refused"
      t_like "$err" "*NEWER*" "the error says the store is newer"
      "$SQ" "$M/ag-catalog.db" "PRAGMA user_version=$CURV;"
      t_done
    fi
    t_ok 0 "legacy store is schema v$OLDV, current build is v$CURV"

    # the new build must REFUSE it rather than read a schema it doesn't know
    err=$(AG_DIR="$M" "$AG" events --run "$LR" 2>&1 >/dev/null); rc=$?
    t_fails "$rc" "the current build refuses a v1 store"
    t_like "$err" "*migrate*" "the refusal points at migrate"

    dry=$(AG_DIR="$M" "$AG" migrate --dry-run)
    t_is "$(echo "$dry" | jq -r .migrated)" false "--dry-run changes nothing"
    t_is "$("$SQ" "$M/ag-catalog.db" 'PRAGMA user_version;')" "$OLDV" "--dry-run left the version alone"

    mig=$(AG_DIR="$M" "$AG" migrate)
    t_ok $? "migrate succeeds"
    t_is "$(echo "$mig" | jq -r '"\(.from)->\(.to),\(.migrated)"')" "$OLDV->$CURV,true" "migrate reports the version step"
    t_is "$("$SQ" "$M/ag-catalog.db" 'PRAGMA user_version;')" "$CURV" "catalog is now v$CURV"
    t_is "$("$SQ" "$M/seg-000001.db" 'PRAGMA user_version;')" "$CURV" "segment is now v$CURV"

    after=$(AG_DIR="$M" "$AG" events --run "$LR" | jq -sc 'map({seq,type,payload})')
    t_is "$after" "$before" "every event survives the migration byte-exact"
    t_is "$("$SQ" "$M/seg-000001.db" "SELECT group_concat(obj_kind||'#'||obj_n,',') FROM run_events WHERE obj_n IS NOT NULL ORDER BY seq;")" \
         "doc#1,doc#2" "object ordinals are present after migration (backfilled when coming from v1)"
    lqh=$(AG_DIR="$M" "$AG" events --run "$LR" --type llm.requested | jq -r .hash)
    t_is "$(AG_DIR="$M" "$AG" cache-lookup "$lqh" --by request | jq -r .hit)" true \
         "req_hash is backfilled from caused_by, so legacy data gains the request-keyed cache"
    t_is "$(AG_DIR="$M" "$AG" replay --run "$LR" | jq -r .cache)" hit "permissive replay works on migrated data"

    # ids must continue from where the legacy store left off
    LF=$(AG_DIR="$M" "$AG" fork "$LR" 5 | jq -r .run)
    AG_DIR="$M" "$AG" emit --run "$LF" --type object.created --payload '{"kind":"doc","data":{"a":3}}' >/dev/null
    t_is "$(AG_DIR="$M" "$AG" events --run "$LF" --since 5 | jq -r .payload.id)" "doc#3" \
         "the deterministic id sequence continues across the migration"

    t_is "$("$SQ" "$M/seg-000001.db" 'PRAGMA integrity_check;')" ok "migrated segment passes integrity_check"
    t_is "$(AG_DIR="$M" "$AG" verify --run "$LR" | jq -r .ok)" true "payload hashes still verify after migration"
    t_is "$("$SQ" "$M/ag-catalog.db" "SELECT count(*) FROM sqlite_schema WHERE name='behaviors';")" 1 \
         "the behaviors table exists after migration"
    t_ok "$(AG_DIR="$M" "$AG" behaviors >/dev/null 2>&1; echo $?)" "the behaviour registry is usable on a migrated store"
    t_is "$(AG_DIR="$M" "$AG" migrate | jq -r .migrated)" false "migrate is idempotent"

    # a future schema is refused, not guessed at
    "$SQ" "$M/ag-catalog.db" 'PRAGMA user_version=99;'
    err=$(AG_DIR="$M" "$AG" migrate 2>&1 >/dev/null); rc=$?
    t_fails "$rc" "a store newer than the binary is refused"
    t_like "$err" "*NEWER*" "the error says the store is newer"
    "$SQ" "$M/ag-catalog.db" "PRAGMA user_version=$CURV;"
  else
    t_ok 0 "(skip) legacy build could not create a store on this host"
  fi
else
  t_ok 0 "(skip) no committed previous build to migrate from"
fi

t_done
