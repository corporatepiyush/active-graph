#!/usr/bin/env bash
# regression tests for black-box review findings F1-F5
. "$(dirname "$0")/harness.bash"

"$AG" init >/dev/null
R=$(new_run "harden")

# F1: a trailing option with no value must EXIT, never hang.
for spec in "run-start --goal" "emit --run" "emit --type" "events --run" \
            "run-end --run" "purge --run" "verify --run" "wait --run" \
            "graph --kind" "project --run" "explain --obj" "frame-close --frame"; do
    t0=$SECONDS
    ( eval "\"\$AG\" $spec" </dev/null >/dev/null 2>&1 )
    dt=$((SECONDS - t0))
    t_ok "$([ "$dt" -lt 30 ]; echo $?)" "F1: '$spec <missing>' exits (${dt}s), no hang"
done

# F2: caller-supplied object ids are REJECTED by default — the paper requires ids
# come from the runtime's deterministic generator, and a caller-chosen id can
# collide with a later minted one (the projection then resolves it
# last-write-wins, so identical logs could project to different graphs).
"$AG" emit --run "$R" --type object.created --payload '{"kind":"doc","id":"doc#1","data":{"a":1}}' >/dev/null 2>&1
t_is $? 2 "F2: explicit object id rejected by default"
out=$("$AG" emit --run "$R" --type object.created --payload '{"kind":"doc","id":"doc#1","data":{"a":1}}' 2>&1 >/dev/null)
t_like "$out" "*AG_ALLOW_EXPLICIT_ID*" "F2: error names the override"
# batch path enforces the same rule
printf '%s\n' '{"type":"object.created","payload":{"kind":"doc","id":"doc#9","data":{}}}' \
    | "$AG" emit-batch --run "$R" >/dev/null 2>&1
t_is $? 2 "F2: batch path rejects explicit ids too"

# with the escape hatch on, a duplicate must still not brick projection
export AG_ALLOW_EXPLICIT_ID=1
"$AG" emit --run "$R" --type object.created --payload '{"kind":"doc","id":"doc#1","data":{"a":1}}' >/dev/null
"$AG" emit --run "$R" --type object.created --payload '{"kind":"doc","id":"doc#1","data":{"b":2}}' >/dev/null
out=$("$AG" project --run "$R"); rc=$?
t_ok "$rc" "F2: project survives duplicate explicit id"
t_is "$(printf '%s' "$out" | jq .nodes)" 1 "F2: duplicate id collapses to one node"
t_is "$("$AG" graph --run "$R" | jq -c 'select(.id=="doc#1").data')" '{"b":2}' "F2: last write wins"
# and projection still works for later good events
"$AG" emit --run "$R" --type object.created --payload '{"kind":"claim","data":{"x":1}}' >/dev/null
t_ok "$("$AG" project --run "$R" >/dev/null; echo $?)" "F2: projection not permanently bricked"
unset AG_ALLOW_EXPLICIT_ID

# F3: forged lifecycle events rejected on the public path
for lt in run.started run.ended frame.opened frame.closed; do
    "$AG" emit --run "$R" --type "$lt" --payload '{}' >/dev/null 2>&1
    t_is $? 2 "F3: emit --type $lt rejected"
done
# runtime's own lifecycle path still works and keeps status consistent
"$AG" run-end --run "$R" --status done >/dev/null
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT status FROM runs WHERE run_id='$R';")" done "F3: run-end still flips status"
# no stray run.ended slipped into the log via the public path
n=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE rid=$(rid_of "$R") AND tid=2;")
t_is "$n" 1 "F3: exactly one run.ended (the runtime's)"

# F4: rpc-child bounds its line read (no unbounded buffer / hang)
t0=$SECONDS
head -c 3000000 /dev/zero | tr '\0' z | "$AG" rpc-child >/dev/null 2>&1
dt=$((SECONDS - t0))
t_ok "$([ "$dt" -lt 60 ]; echo $?)" "F4: 3MB no-newline input handled bounded (${dt}s)"

# F5: malformed numeric env config fails closed, never reaches SQL
out=$(AG_BLOB_MIN="0); DROP TABLE seg.blobs; --" "$AG" run-start 2>&1); rc=$?
t_is "$rc" 2 "F5: injection-shaped AG_BLOB_MIN rejected"
t_like "$out" "*must be a non-negative integer*" "F5: clear config error"
t_is "$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM sqlite_schema WHERE name='blobs';")" 1 "F5: blobs table intact"
out=$(AG_CHAIN="2" "$AG" run-start 2>&1); rc=$?
t_is "$rc" 2 "F5: AG_CHAIN must be 0/1"

# F6: constraint violations are classified with their real message, not a
# generic -32603 (the rollback used to wipe AG_ERR before it was read)
R6=$(new_run "f6")
"$AG" emit --run "$R6" --type x.a --payload '{}' >/dev/null
out=$("$AG" emit --run "$R6" --type x.b --payload '{}' --caused-by 99 2>&1); rc=$?
t_is "$rc" 2 "F6: caused_by violation -> params error (2), not internal (1)"
t_like "$out" "*CHECK constraint failed*caused_by*" "F6: real SQLite error surfaced, not empty"

# F7: reads on a purged run are explicit, not silently empty
R7=$(new_run "f7")
"$AG" emit --run "$R7" --type x.z --payload '{}' >/dev/null
"$AG" purge --run "$R7" >/dev/null
"$AG" events --run "$R7" >/dev/null 2>&1
t_is $? 3 "F7: events on purged run -> unknown/unavailable (3), not silent 0"
"$AG" graph --run "$R7" >/dev/null 2>&1
t_is $? 3 "F7: graph on purged run -> error"
"$AG" verify --run "$R7" >/dev/null 2>&1
t_is $? 3 "F7: verify on purged run -> error"
out=$("$AG" events --run "$R7" 2>&1)
t_like "$out" "*purged*" "F7: message says purged"

# ---------------------------------------------------------------------------
# P1-P4: findings from the profiling pass (tests/profile.sh). Each one was
# SILENT — rc 0, plausible output, nothing in any log.
# ---------------------------------------------------------------------------

# P1: `read` returns non-zero on a final line with no trailing newline AND sets
# the variable, so a plain `while read` loop set it and then discarded it. An
# unterminated last line is the normal case (jq -c, here-strings, partial socket
# writes), and losing it looked exactly like success.
RP1=$(new_run "p1")
printf '{"type":"x.a","payload":{}}\n{"type":"x.b","payload":{}}' | "$AG" emit-batch --run "$RP1" >/dev/null 2>&1
t_is $? 0 "P1: emit-batch accepts a stream with no trailing newline"
t_is "$("$AG" events --run "$RP1" --type x.b | wc -l | tr -d ' ')" 1 \
     "P1: the unterminated LAST event is stored, not silently dropped"
t_is "$("$AG" events --run "$RP1" | wc -l | tr -d ' ')" 3 "P1: and nothing else changed"

# same trap in strict replay: dropping the candidate's last line made a
# byte-identical stream report a divergence that was not there
"$AG" events --run "$RP1" | jq -c '{type,payload}' > "$TDIR/cand.ndjson"
printf '%s' "$(cat "$TDIR/cand.ndjson")" | "$AG" replay --run "$RP1" --strict >/dev/null 2>&1
t_is $? 0 "P1: replay --strict matches a candidate with no trailing newline"

# P2: the `scan` sandbox is -readonly + query_only, but the SQL is PIPED to the
# sqlite3 CLI, which treats a line starting with '.' as a dot-command. .shell
# was arbitrary command execution out of a read-only sandbox.
PWN="$TDIR/pwned"
"$AG" scan "$(printf 'SELECT 1;\n.shell touch %s' "$PWN")" >/dev/null 2>&1
t_fails $? "P2: scan REFUSES SQL containing a dot-command line"
t_ok "$([ ! -e "$PWN" ]; echo $?)" "P2: and .shell did not run"
"$AG" scan "$(printf '.output %s\nSELECT 1;' "$PWN")" >/dev/null 2>&1
t_fails $? "P2: scan refuses a leading .output too"
t_ok "$([ ! -e "$PWN" ]; echo $?)" "P2: and no file was written"
t_is "$("$AG" scan 'SELECT count(*) FROM run_events' | head -1)" \
     "$("$SQ" "$AG_DIR/seg-000001.db" 'SELECT count(*) FROM run_events;')" \
     "P2: ordinary scan SQL still works"
t_is "$("$AG" scan "$(printf 'SELECT 1 +\n .5;')" | head -1)" "1.5" \
     "P2: a float literal is still expressible, indented by one space"

# P3: frame-close only checked the id SHAPE, so it appended a valid frame.closed
# for a frame nobody ever opened, and a second one when closed twice. The log is
# the source of truth; a close with no open makes it lie.
RP3=$(new_run "p3")
F3=$("$AG" frame-open --run "$RP3" | jq -r .frame)
"$AG" frame-close --run "$RP3" --frame "$F3" >/dev/null 2>&1
t_is $? 0 "P3: closing an open frame works"
"$AG" frame-close --run "$RP3" --frame "$F3" >/dev/null 2>&1
t_fails $? "P3: closing the SAME frame twice is refused"
"$AG" frame-close --run "$RP3" --frame f99 >/dev/null 2>&1
t_fails $? "P3: closing a frame that was never opened is refused"
"$AG" frame-open --run "$RP3" --parent f99 >/dev/null 2>&1
t_fails $? "P3: nesting under a frame that was never opened is refused"
"$AG" frame-open --run "$RP3" --parent "$F3" >/dev/null 2>&1
t_fails $? "P3: nesting under a CLOSED frame is refused"
t_is "$("$AG" events --run "$RP3" --type frame.closed | wc -l | tr -d ' ')" 1 \
     "P3: exactly one frame.closed reached the log"

# P4: a value-taking flag with nothing after it was accepted as empty, which for
# a FILTER reads as success: `events --type` printed everything, `insights --run`
# reported the whole store, `run-start --goal` made a run with no goal, rc 0.
RP4=$(new_run "p4")
"$AG" emit --run "$RP4" --type x.one --payload '{}' >/dev/null
"$AG" run-start --goal >/dev/null 2>&1
t_fails $? "P4: run-start --goal with no value is refused"
out=$("$AG" events --run "$RP4" --type 2>&1); rc=$?
t_is "$rc" 2 "P4: events --type with no value is refused, not treated as 'no filter'"
t_like "$out" "*missing value for --type*" "P4: and the message names the flag"
"$AG" insights --run >/dev/null 2>&1
t_fails $? "P4: insights --run with no value is refused"
"$AG" emit --run "$RP4" --type x.two --payload >/dev/null 2>&1
t_fails $? "P4: emit --payload with no value is refused"
# ...but a value that merely LOOKS like a flag is still a value
printf '{"ok":true}' | "$AG" emit --run "$RP4" --type x.three --payload - >/dev/null 2>&1
t_is $? 0 "P4: --payload - (documented) still works"
"$AG" run-start --goal '-dash-leading-goal' >/dev/null 2>&1
t_is $? 0 "P4: a goal starting with a dash is still accepted"

t_done
