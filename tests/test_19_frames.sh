#!/usr/bin/env bash
# frames: deterministic ids, membership in payload, reconvergence (PLAN test_19)
. "$(dirname "$0")/harness.bash"

R=$(new_run "frames")

f1=$("$AG" frame-open --run "$R" | jq -r .frame)
t_is "$f1" f1 "first frame is f1"
f2=$("$AG" frame-open --run "$R" | jq -r .frame)
t_is "$f2" f2 "second frame is f2 (deterministic counter)"

# events inside a frame carry membership in the (hashed) payload
"$AG" emit --run "$R" --type x.work --payload '{"frame":"f1","step":1}' >/dev/null
"$AG" emit --run "$R" --type x.work --payload '{"frame":"f2","step":1}' >/dev/null
"$AG" emit --run "$R" --type x.work --payload '{"frame":"f1","step":2}' >/dev/null

# interleaved frames share the run's globally monotonic seq space
seqs=$("$AG" events --run "$R" --type x.work | jq -r '"\(.seq):\(.payload.frame)"' | paste -sd, -)
t_is "$seqs" "4:f1,5:f2,6:f1" "interleaved frames, one seq space"

# close with reconvergence result
out=$("$AG" frame-close --run "$R" --frame f1 --result '{"answer":42}')
t_ok $? "frame-close accepted"
res=$("$AG" events --run "$R" --type frame.closed | jq -r .payload.result.answer)
t_is "$res" 42 "reconvergence result recorded"

# frame-close validation
"$AG" frame-close --run "$R" --frame not-a-frame >/dev/null 2>&1
t_is $? 2 "bad frame id rejected"

# parent_frame recorded for nested frames
f3=$("$AG" frame-open --run "$R" --parent f2 | jq -r .frame)
pf=$("$AG" events --run "$R" --type frame.opened | jq -r "select(.payload.frame==\"$f3\").payload.parent_frame")
t_is "$pf" f2 "nested frame records parent_frame"

# frame ids survive fork lineage (child continues the counter)
F=$("$AG" fork "$R" 8 | jq -r .run)
f4=$("$AG" frame-open --run "$F" | jq -r .frame)
t_is "$f4" f4 "fork continues frame numbering from lineage"
t_done
