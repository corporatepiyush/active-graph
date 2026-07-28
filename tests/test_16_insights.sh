#!/usr/bin/env bash
# insights: cost/token/latency aggregation vs hand-computed fixtures, and the
# whole-store rollup — a sealed segment's finalized seg_stats must equal what a
# live scan of the same events would have produced (PLAN §13 test_16, §8d).
. "$(dirname "$0")/harness.bash"
export AG_SEG_MAX_BYTES=262144   # so a big payload forces a rollover
# A payload this size cannot be an ARGV STRING: Linux caps a single argument
# at 128 KiB (MAX_ARG_STRLEN), so passing it as --payload fails with E2BIG there
# while it works on macOS. Use the file form, which is portable.
BIG=$(big_payload_file "$TDIR/big-payload.json" doc 300000)
st() { "$AG" stats; }
"$AG" init >/dev/null

# empty store: zeroed totals, empty breakdowns
s=$(st)
t_is "$(echo "$s" | jq -c '[.events,.runs,.blobs]')" "[0,0,0]" "empty store stats are zero"
t_is "$(echo "$s" | jq -c '.models')" "[]" "empty store has no model rows"
t_is "$(echo "$s" | jq -c '.tools')"  "[]" "empty store has no tool rows"

# run 1 (seg-1): 2 gpt-4o calls + 1 tool; a big object rolls the segment
R1=$(new_run r1)
"$AG" emit --run "$R1" --type llm.responded  --payload '{"model":"gpt-4o"}' --ctx '{"estimated_cost_usd":0.01,"usage":{"total_tokens":100}}' >/dev/null
"$AG" emit --run "$R1" --type llm.responded  --payload '{"model":"gpt-4o"}' --ctx '{"estimated_cost_usd":0.02,"usage":{"total_tokens":200}}' >/dev/null
"$AG" emit --run "$R1" --type tool.responded --payload '{"name":"search"}'  --ctx '{"dur_ms":50}' >/dev/null
"$AG" emit --run "$R1" --type object.created "--payload@$BIG" >/dev/null
"$AG" run-end --run "$R1" >/dev/null

# single-segment fixtures (still active/draining, live scan)
s=$(st)
t_is "$(echo "$s" | jq -c '[.runs,.blobs]')" "[1,1]" "one run, one offloaded blob"
t_is "$(echo "$s" | jq -r '.models[] | select(.model=="gpt-4o") | "\(.n),\(.cost_usd),\(.tokens)"')" "2,0.03,300" "gpt-4o cost/tokens summed from ctx"
t_is "$(echo "$s" | jq -r '.tools[] | select(.tool=="search") | "\(.n),\(.dur_ms)"')" "1,50" "tool latency summed from ctx"

# run 2 forces rollover into seg-2: adds gpt-4o + claude + another search
R2=$(new_run r2)
"$AG" emit --run "$R2" --type llm.responded  --payload '{"model":"gpt-4o"}' --ctx '{"estimated_cost_usd":0.03,"usage":{"total_tokens":300}}' >/dev/null
"$AG" emit --run "$R2" --type llm.responded  --payload '{"model":"claude"}' --ctx '{"estimated_cost_usd":0.05,"usage":{"total_tokens":500}}' >/dev/null
"$AG" emit --run "$R2" --type tool.responded --payload '{"name":"search"}'  --ctx '{"dur_ms":70}' >/dev/null
"$AG" run-end --run "$R2" >/dev/null
t_like "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT group_concat(state) FROM segments;")" "*draining*active*" "store has rolled over (seg-1 draining, seg-2 active)"

# whole-store fixtures while BOTH segments are live (union across segments)
live=$(st)
t_is "$(echo "$live" | jq -r '.models[] | select(.model=="gpt-4o") | "\(.n),\(.cost_usd),\(.tokens)"')" "3,0.06,600" "cross-segment gpt-4o merged (2 in seg-1 + 1 in seg-2)"
t_is "$(echo "$live" | jq -r '.models[] | select(.model=="claude") | "\(.n),\(.cost_usd),\(.tokens)"')" "1,0.05,500" "claude only in seg-2"
t_is "$(echo "$live" | jq -r '.tools[]  | select(.tool=="search")  | "\(.n),\(.dur_ms)"')" "2,120" "search latency merged across segments"
t_is "$(echo "$live" | jq -c '[.events,.runs,.blobs]')" "[11,2,1]" "whole-store totals across live segments"

# seal seg-1: its rollup replaces the live scan. Stats MUST be byte-identical —
# the finalized seg_stats rollup == what a live scan produced.
"$AG" maintain >/dev/null 2>&1
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT state FROM segments WHERE seg_id=1;")" sealed "seg-1 sealed by maintain"
sealed=$(st)
t_is "$(echo "$sealed" | jq -S -c .)" "$(echo "$live" | jq -S -c .)" "sealed-segment rollup equals the prior live scan (no drift)"

# a second rollover + seal: three segments, two sealed, one live — still exact
R3=$(new_run r3)
"$AG" emit --run "$R3" --type llm.responded --payload '{"model":"gpt-4o"}' --ctx '{"estimated_cost_usd":0.10,"usage":{"total_tokens":1000}}' >/dev/null
"$AG" emit --run "$R3" --type object.created "--payload@$BIG" >/dev/null
"$AG" run-end --run "$R3" >/dev/null
R4=$(new_run r4)   # forces seg-3
"$AG" maintain >/dev/null 2>&1
final=$(st)
t_is "$(echo "$final" | jq -r '.models[] | select(.model=="gpt-4o") | "\(.n),\(.cost_usd),\(.tokens)"')" "4,0.16,1600" "gpt-4o totals span 2 sealed + 1 live segment"
t_is "$(echo "$final" | jq -c '[.runs,.blobs]')" "[4,2]" "run and blob totals across all segments"

t_done
