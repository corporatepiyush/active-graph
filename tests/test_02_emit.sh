#!/usr/bin/env bash
# emit: seq allocation, validation, constraints (PLAN test_02)
. "$(dirname "$0")/harness.bash"

R=$(new_run "emit test")
t_like "$R" "r*-*" "run created"

s=$("$AG" emit --run "$R" --type llm.requested --actor llm --payload '{"a":1}' | jq .seq)
t_is "$s" 2 "first emit gets seq 2 (run.started took 1)"
s=$("$AG" emit --run "$R" --type tool.requested --payload '{"name":"grep"}' | jq .seq)
t_is "$s" 3 "seq monotonic"

# caused_by must point backwards
"$AG" emit --run "$R" --type x.note --payload '{}' --caused-by 999 >/dev/null 2>&1
t_fails $? "caused_by >= seq rejected"
s=$("$AG" emit --run "$R" --type x.note --payload '{"n":1}' --caused-by 2 | jq .seq)
t_is "$s" 4 "valid caused_by accepted"

# unknown run
"$AG" emit --run r1234567890-abcd --type x.note --payload '{}' >/dev/null 2>&1
t_is $? 3 "unknown run -> exit 3"

# bad run id shape
"$AG" emit --run not-a-run --type x.note --payload '{}' >/dev/null 2>&1
t_is $? 2 "malformed run id -> exit 2"

# payload must be an object
"$AG" emit --run "$R" --type x.note --payload '[1,2]' >/dev/null 2>&1
t_fails $? "array payload rejected"
"$AG" emit --run "$R" --type x.note --payload 'not json' >/dev/null 2>&1
t_fails $? "non-JSON payload rejected"

# seq=0 is rejected (seq starts at 1; run.started occupies seq 1, first emit gets 2)
"$SQ" "$AG_DIR/seg-000001.db" "INSERT INTO run_events(rid,seq,tid,aid,payload,ts_ms) VALUES($(rid_of "$R"),0,17,1,'{}',0);" 2>/dev/null
t_fails $? "seq=0 violates CHECK(seq >= 1)"

# payload/body_ref discriminator: exactly one present per row
n=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE (payload IS NULL) = (body_ref IS NULL);")
t_is "$n" 0 "every row has payload XOR body_ref (discriminator invariant)"

# unknown event type without x. prefix
"$AG" emit --run "$R" --type made.up --payload '{}' >/dev/null 2>&1
t_fails $? "unknown non-custom type rejected"

# custom x. type interned and usable
s=$("$AG" emit --run "$R" --type x.custom_thing --payload '{"k":"v"}' | jq .seq)
t_is "$s" 5 "custom x.* type accepted"

# payload via stdin
s=$(printf '{"stdin":true}' | "$AG" emit --run "$R" --type x.note --payload - | jq .seq)
t_is "$s" 6 "payload from stdin"

# ended run refuses emits
"$AG" run-end --run "$R" --status done >/dev/null
"$AG" emit --run "$R" --type x.note --payload '{}' >/dev/null 2>&1
t_fails $? "emit to ended run rejected"

# run.ended recorded + status flipped
st=$("$AG" events --run "$R" --type run.ended | jq -r '.payload.status')
t_is "$st" done "run.ended payload records status"
t_done
