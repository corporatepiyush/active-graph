#!/usr/bin/env bash
# idempotent emit: retries are exactly-once (PLAN test_18, 8.1 in round-2)
. "$(dirname "$0")/harness.bash"

R=$(new_run "idem")

r1=$("$AG" emit --run "$R" --type x.op --payload '{"n":1}' --idem key-A)
s1=$(printf '%s' "$r1" | jq .seq)
t_is "$s1" 2 "first emit with idem key"

# same key again: same seq back, no new row, flagged as replay
r2=$("$AG" emit --run "$R" --type x.op --payload '{"n":1}' --idem key-A)
t_is "$(printf '%s' "$r2" | jq .seq)" "$s1" "retry returns the SAME seq"
t_is "$(printf '%s' "$r2" | jq .idem_replayed)" true "retry flagged idem_replayed"

n=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE idem='key-A';")
t_is "$n" 1 "exactly one row for the key"

# different key -> new event
s3=$("$AG" emit --run "$R" --type x.op --payload '{"n":1}' --idem key-B | jq .seq)
t_is "$s3" 3 "different key emits normally"

# idem scoped per run: same key in another run is independent
R2=$(new_run "idem2")
s4=$("$AG" emit --run "$R2" --type x.op --payload '{"n":9}' --idem key-A | jq .seq)
t_is "$s4" 2 "idem keys are per-run, not global"

# invalid key charset rejected
"$AG" emit --run "$R" --type x.op --payload '{}' --idem 'bad key!' >/dev/null 2>&1
t_is $? 2 "invalid idem charset rejected"
t_done
