#!/usr/bin/env bash
# tamper-evident hash chain (PLAN test_33, section 12/A08)
. "$(dirname "$0")/harness.bash"
export AG_CHAIN=1

R=$(new_run "chain")
"$AG" emit --run "$R" --type llm.requested --payload '{"model":"m","p":1}' >/dev/null
"$AG" emit --run "$R" --type llm.responded --payload '{"model":"m","a":1}' >/dev/null
"$AG" emit --run "$R" --type x.note --payload '{"i":3}' >/dev/null

v=$("$AG" verify --run "$R" --chain)
t_is "$(printf '%s' "$v" | jq -r .ok)" true "pristine chain verifies"

# every event carries a chain value when AG_CHAIN=1
n=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE chain IS NULL AND rid=$(rid_of "$R");")
t_is "$n" 0 "all events chained"

# fork continues the chain via runs.chain_seed
C=$("$AG" fork "$R" 3 | jq -r .run)
seed=$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT count(*) FROM runs WHERE run_id='$C' AND chain_seed IS NOT NULL;")
t_is "$seed" 1 "fork captured chain_seed"
"$AG" emit --run "$C" --type x.child --payload '{"c":1}' >/dev/null
v=$("$AG" verify --run "$C" --chain)
t_is "$(printf '%s' "$v" | jq -r .ok)" true "fork's chain verifies across lineage"

# payload tamper detected by hash recomputation (exact seq named).
# rid of the first run in a fresh store is 1 by construction.
"$SQ" "$AG_DIR/seg-000001.db" "UPDATE run_events SET payload=jsonb('{\"model\":\"m\",\"p\":999}') WHERE rid=1 AND seq=2;"
v=$("$AG" verify --run "$R" 2>/dev/null); rc=$?
t_fails "$rc" "verify fails after payload tamper"
t_is "$(printf '%s' "$v" | jq -r .first_bad.seq)" 2 "tampered seq named exactly"

# restore payload, then tamper the CHAIN value: hash passes, chain catches it
"$SQ" "$AG_DIR/seg-000001.db" "UPDATE run_events SET payload=jsonb('{\"model\":\"m\",\"p\":1}') WHERE rid=1 AND seq=2;"
"$SQ" "$AG_DIR/seg-000001.db" "UPDATE run_events SET chain=zeroblob(32) WHERE rid=1 AND seq=3;"
v=$("$AG" verify --run "$R" 2>/dev/null); rc=$?
t_ok "$rc" "hash-only verify passes (payloads intact)"
v=$("$AG" verify --run "$R" --chain 2>/dev/null); rc=$?
t_fails "$rc" "--chain verify fails on chain tamper"
t_is "$(printf '%s' "$v" | jq -r .first_bad.kind)" chain "flagged as chain break"
t_done
