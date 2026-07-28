#!/usr/bin/env bash
# strict replay verification: event-by-event hash comparison (PLAN test_07)
. "$(dirname "$0")/harness.bash"

R=$(new_run "replay")
"$AG" emit --run "$R" --type llm.requested --payload '{"model":"m","p":"q"}' >/dev/null
"$AG" emit --run "$R" --type llm.responded --payload '{"model":"m","a":"r"}' >/dev/null
"$AG" emit --run "$R" --type x.note --payload '{"n":3}' >/dev/null

stream() { "$AG" events --run "$R" | jq -c '{type:.type, payload:.payload}'; }

# byte-identical stream verifies clean
out=$(stream | "$AG" replay --run "$R" --strict)
t_ok $? "identical stream passes strict replay"
t_is "$(printf '%s' "$out" | jq .events)" 4 "all 4 events compared"

# one mutated payload -> divergence naming the exact seq + both hashes
out=$(stream | jq -c 'if .payload.n==3 then .payload={n:999} else . end' \
      | "$AG" replay --run "$R" --strict 2>/dev/null); rc=$?
t_is "$rc" 7 "divergence exits with replay-divergence code 7"
t_is "$(printf '%s' "$out" | jq .divergence.seq)" 4 "divergent seq named exactly"
t_like "$(printf '%s' "$out" | jq -r .divergence.expected_hash)" "????????????????????????????????????????????????????????????????" "expected hash reported"

# wrong type at same payload -> divergence
out=$(stream | jq -c 'if .type=="x.note" then .type="x.other" else . end' \
      | "$AG" replay --run "$R" --strict 2>/dev/null); rc=$?
t_is "$rc" 7 "type mismatch is a divergence"

# short stream -> divergence (missing events)
out=$(stream | head -2 | "$AG" replay --run "$R" --strict 2>/dev/null); rc=$?
t_is "$rc" 7 "truncated stream is a divergence"
t_like "$(printf '%s' "$out" | jq -r .divergence.reason)" "*shorter*" "reason says shorter"

# long stream -> divergence (extra events)
out=$( { stream; echo '{"type":"x.note","payload":{"extra":1}}'; } \
      | "$AG" replay --run "$R" --strict 2>/dev/null); rc=$?
t_is "$rc" 7 "over-long stream is a divergence"

# permissive probe path: responded hash is servable from cache
h=$("$AG" events --run "$R" --type llm.responded | jq -r .hash)
t_is "$("$AG" cache-lookup "$h" | jq -r .hit)" true "permissive replay serves from cache by hash"
t_done
