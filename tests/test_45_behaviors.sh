#!/usr/bin/env bash
# Behaviours — the paper's reactive core (section 3):
#   "behaviors ... react to changes in the graph and emit new events. No
#    component instructs another; coordination happens entirely through the
#    shared graph."
# A behaviour declares a subscription (event type + optional predicate + a
# graph-shape pattern in a Cypher subset) and a body. The runtime owns matching,
# dispatch, provenance and fire-once; the body is an external program.
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null
B="$TDIR/bodies"; mkdir -p "$B"

# body: answer an open question raised by a claim
cat > "$B/answer.sh" <<'EOF'
#!/usr/bin/env bash
m=$(cat)
q=$(printf '%s' "$m" | jq -r '.bind.q.id')
c=$(printf '%s' "$m" | jq -r '.bind.c.id')
printf '{"type":"object.created","payload":{"kind":"answer","data":{"to":"%s","from":"%s"}}}\n' "$q" "$c"
printf '{"type":"relation.created","payload":{"src":"%s","kind":"answered_by","dst":"answer#1"}}\n' "$q"
EOF
chmod +x "$B/answer.sh"

# ---------------------------------------------------------------------------
# registration
# ---------------------------------------------------------------------------
out=$("$AG" behavior-add --name answer_open_question --on object.created \
        --match '(c:claim)-[:addresses]->(q:question)' \
        --absent 'q-[:answered_by]->' -- "$B/answer.sh")
t_ok $? "behavior-add registers a subscription"
t_is "$(echo "$out" | jq -r .behavior)" answer_open_question "the behaviour is named"
t_is "$(echo "$out" | jq -r '.argv[0]')" "$B/answer.sh" "the body is stored as an argv array"
t_is "$("$AG" behaviors | jq -s length)" 1 "behaviors lists it"

# bad patterns are rejected at registration, not at fire time
for bad in 'claim' '(c:claim)-[addresses]->(q)' '(c:claim)->(q:question)' \
           '(a)-[:r]->(b)-[:r]->(c)-[:r]->(d)' '(C:Claim)'; do
    "$AG" behavior-add --name tmp_bad --on object.created --match "$bad" -- /bin/true >/dev/null 2>&1
    t_is $? 2 "invalid pattern rejected: ${bad:0:34}"
done
"$AG" behavior-add --name tmp_bad --on object.created \
      --match '(c:claim)' --where 'c.data IS NOT NULL; DROP TABLE ag_nodes' -- /bin/true >/dev/null 2>&1
t_is $? 2 "--where containing a statement separator is refused"
"$AG" behavior-add --name tmp_bad --on object.created --match '(c:claim)' >/dev/null 2>&1
t_is $? 2 "a behaviour with no body is refused"

# ---------------------------------------------------------------------------
# the paper's worked example, end to end
# ---------------------------------------------------------------------------
R=$(new_run diligence)
"$AG" emit --run "$R" --type object.created --payload '{"kind":"question","data":{"q":"is it safe?"}}' >/dev/null
"$AG" emit --run "$R" --type object.created --payload '{"kind":"claim","data":{"c":"it is safe"}}' >/dev/null
"$AG" emit --run "$R" --type relation.created --payload '{"src":"claim#1","kind":"addresses","dst":"question#1"}' >/dev/null

res=$("$AG" react --run "$R")
t_ok $? "react runs"
t_is "$(echo "$res" | jq -r .fired)" 1 "the behaviour fired once"
t_is "$(echo "$res" | jq -r .quiesced)" true "the graph quiesced"

# the effect is IN THE LOG, with full provenance
ev=$("$AG" events --run "$R")
t_is "$(echo "$ev" | jq -s '[.[]|select(.type=="behavior.started")]|length')" 1 "behavior.started recorded"
t_is "$(echo "$ev" | jq -s '[.[]|select(.type=="behavior.completed")]|length')" 1 "behavior.completed recorded"
sseq=$(echo "$ev" | jq -s -r '.[]|select(.type=="behavior.started")|.seq')
trig=$(echo "$ev" | jq -s -r '.[]|select(.type=="behavior.started")|.caused_by')
t_ok "$([ -n "$trig" ] && [ "$trig" != null ]; echo $?)" "behavior.started points at the event that completed the pattern"
t_is "$(echo "$ev" | jq -s "[.[]|select(.actor==\"answer_open_question\")]|length")" 2 "the body's two events are attributed to the behaviour"
t_is "$(echo "$ev" | jq -s "[.[]|select(.actor==\"answer_open_question\")|.caused_by]|unique|.[0]")" "$sseq" \
     "every emitted event is caused_by the behavior.started"
t_is "$(echo "$ev" | jq -s -r '.[]|select(.type=="behavior.completed")|.payload.ok')" true "completion records success"
t_is "$(echo "$ev" | jq -s -r '.[]|select(.type=="behavior.completed")|.payload.emitted')" 2 "completion records the emit count"

# and the graph actually changed
t_is "$("$AG" graph --run "$R" --kind answer | jq -r .id)" "answer#1" "the answer node exists in the projection"
t_is "$("$AG" graph --run "$R" --edges --kind answered_by | jq -r .src)" "question#1" "the answered_by edge exists"

# ---------------------------------------------------------------------------
# fire-once, and the dedupe key lives in the LOG (so it survives replay/fork)
# ---------------------------------------------------------------------------
res=$("$AG" react --run "$R")
t_is "$(echo "$res" | jq -r .fired)" 0 "re-running the reactor fires nothing new"
t_is "$("$AG" events --run "$R" | jq -s length)" "$(echo "$ev" | jq -s length)" "no events were added"
t_ok "$("$AG" events --run "$R" --type behavior.started | jq -e '.payload.fire_key|test("answer_open_question\\|")' >/dev/null; echo $?)" \
     "the fire key is recorded in the behavior.started payload"

# a SECOND, distinct match fires again (fire-once is per match, not per behaviour)
"$AG" emit --run "$R" --type object.created --payload '{"kind":"question","data":{"q":"second?"}}' >/dev/null
"$AG" emit --run "$R" --type object.created --payload '{"kind":"claim","data":{"c":"second claim"}}' >/dev/null
"$AG" emit --run "$R" --type relation.created --payload '{"src":"claim#2","kind":"addresses","dst":"question#2"}' >/dev/null
res=$("$AG" react --run "$R")
t_is "$(echo "$res" | jq -r .fired)" 1 "a new match fires the same behaviour again"

# ---------------------------------------------------------------------------
# --absent really guards: an already-answered question must not re-fire
# ---------------------------------------------------------------------------
R2=$(new_run guarded)
"$AG" emit --run "$R2" --type object.created --payload '{"kind":"question","data":{"q":"x"}}' >/dev/null
"$AG" emit --run "$R2" --type object.created --payload '{"kind":"claim","data":{"c":"y"}}' >/dev/null
"$AG" emit --run "$R2" --type object.created --payload '{"kind":"answer","data":{"a":"pre-existing"}}' >/dev/null
"$AG" emit --run "$R2" --type relation.created --payload '{"src":"claim#1","kind":"addresses","dst":"question#1"}' >/dev/null
"$AG" emit --run "$R2" --type relation.created --payload '{"src":"question#1","kind":"answered_by","dst":"answer#1"}' >/dev/null
res=$("$AG" react --run "$R2")
t_is "$(echo "$res" | jq -r .fired)" 0 "--absent suppresses the fire when the edge already exists"

# ---------------------------------------------------------------------------
# --where predicate over node data
# ---------------------------------------------------------------------------
cat > "$B/flag.sh" <<'EOF'
#!/usr/bin/env bash
m=$(cat); i=$(printf '%s' "$m" | jq -r '.bind.r.id')
printf '{"type":"object.created","payload":{"kind":"flag","data":{"on":"%s"}}}\n' "$i"
EOF
chmod +x "$B/flag.sh"
"$AG" behavior-add --name flag_high_risk --on object.created \
      --match '(r:risk)' --where "r.data ->> '\$.severity' >= 8" -- "$B/flag.sh" >/dev/null
R3=$(new_run predicate)
"$AG" emit --run "$R3" --type object.created --payload '{"kind":"risk","data":{"severity":3}}' >/dev/null
"$AG" emit --run "$R3" --type object.created --payload '{"kind":"risk","data":{"severity":9}}' >/dev/null
res=$("$AG" react --run "$R3")
t_is "$(echo "$res" | jq -r .fired)" 1 "--where fires only for the matching node"
t_is "$("$AG" graph --run "$R3" --kind flag | jq -r .data.on)" "risk#2" "it fired for the high-severity risk"

# ---------------------------------------------------------------------------
# cascade: one behaviour's output satisfies another's pattern
# ---------------------------------------------------------------------------
"$AG" behavior-remove --all >/dev/null
cat > "$B/mk_b.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"type":"object.created","payload":{"kind":"beta","data":{"n":1}}}\n'
EOF
cat > "$B/mk_c.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"type":"object.created","payload":{"kind":"gamma","data":{"n":1}}}\n'
EOF
chmod +x "$B/mk_b.sh" "$B/mk_c.sh"
"$AG" behavior-add --name a_to_b --on object.created --match '(a:alpha)' -- "$B/mk_b.sh" >/dev/null
"$AG" behavior-add --name b_to_c --on object.created --match '(b:beta)'  -- "$B/mk_c.sh" >/dev/null
R4=$(new_run cascade)
"$AG" emit --run "$R4" --type object.created --payload '{"kind":"alpha","data":{"n":1}}' >/dev/null
res=$("$AG" react --run "$R4")
t_ok "$([ "$(echo "$res" | jq -r .rounds)" -ge 2 ]; echo $?)" "the cascade needed more than one round"
t_is "$(echo "$res" | jq -r .fired)" 2 "both behaviours fired"
t_is "$("$AG" graph --run "$R4" --kind gamma | jq -r .id)" "gamma#1" "the second-order effect reached the graph"
t_is "$(echo "$res" | jq -r .quiesced)" true "the cascade quiesced"

# a mutually-triggering pair must be BOUNDED, not spin forever
"$AG" behavior-remove --all >/dev/null
cat > "$B/loop.sh" <<'EOF'
#!/usr/bin/env bash
m=$(cat)
n=$(printf '%s' "$m" | jq -r '.bind.p.data.n // 0')
printf '{"type":"object.created","payload":{"kind":"ping","data":{"n":%s}}}\n' "$((n+1))"
EOF
chmod +x "$B/loop.sh"
"$AG" behavior-add --name pingpong --on object.created --match '(p:ping)' -- "$B/loop.sh" >/dev/null
R5=$(new_run loop)
"$AG" emit --run "$R5" --type object.created --payload '{"kind":"ping","data":{"n":1}}' >/dev/null
t0=$SECONDS
res=$("$AG" react --run "$R5" --max-rounds 3)
dt=$((SECONDS - t0))
t_is "$(echo "$res" | jq -r .rounds)" 3 "--max-rounds bounds a self-triggering cascade"
t_is "$(echo "$res" | jq -r .quiesced)" false "it reports that it did NOT quiesce"
t_ok "$([ "$dt" -lt 120 ]; echo $?)" "the bound is enforced promptly (${dt}s)"

# ---------------------------------------------------------------------------
# body failures are recorded, never silently swallowed, never fatal
# ---------------------------------------------------------------------------
"$AG" behavior-remove --all >/dev/null
printf '#!/bin/sh\ncat >/dev/null\necho "boom" >&2\nexit 3\n' > "$B/fail.sh"; chmod +x "$B/fail.sh"
"$AG" behavior-add --name failing --on object.created --match '(d:doc)' -- "$B/fail.sh" >/dev/null
R6=$(new_run failing)
"$AG" emit --run "$R6" --type object.created --payload '{"kind":"doc","data":{"a":1}}' >/dev/null
res=$("$AG" react --run "$R6")
t_ok $? "a failing body does not fail the reactor"
t_is "$("$AG" events --run "$R6" --type behavior.completed | jq -r .payload.ok)" false "failure is recorded in behavior.completed"
t_ok "$("$AG" events --run "$R6" --type behavior.completed | jq -e '.payload.error|length > 0' >/dev/null; echo $?)" "the error text is captured"

printf '#!/bin/sh\ncat >/dev/null\necho "not json at all"\n' > "$B/junk.sh"; chmod +x "$B/junk.sh"
"$AG" behavior-add --name junk --on object.created --match '(e:evidence)' -- "$B/junk.sh" >/dev/null
R7=$(new_run junk)
"$AG" emit --run "$R7" --type object.created --payload '{"kind":"evidence","data":{"a":1}}' >/dev/null
"$AG" react --run "$R7" >/dev/null
t_ok $? "a body emitting garbage does not fail the reactor"
t_is "$("$AG" events --run "$R7" --type behavior.completed | jq -r .payload.ok)" false "invalid body output is reported as a failure"

# a hanging body is bounded by AG_BEHAVIOR_TIMEOUT_S
printf '#!/bin/sh\ncat >/dev/null\nsleep 20\n' > "$B/hang.sh"; chmod +x "$B/hang.sh"
"$AG" behavior-remove --all >/dev/null
"$AG" behavior-add --name hanging --on object.created --match '(h:hang)' -- "$B/hang.sh" >/dev/null
R8=$(new_run hang)
"$AG" emit --run "$R8" --type object.created --payload '{"kind":"hang","data":{"a":1}}' >/dev/null
t0=$SECONDS
AG_BEHAVIOR_TIMEOUT_S=3 "$AG" react --run "$R8" >/dev/null 2>&1
dt=$((SECONDS - t0))
t_ok "$([ "$dt" -lt 15 ]; echo $?)" "a hanging body is killed at AG_BEHAVIOR_TIMEOUT_S (${dt}s)"
t_is "$("$AG" events --run "$R8" --type behavior.completed | jq -r .payload.ok)" false "the timeout is recorded as a failure"

# ---------------------------------------------------------------------------
# integrity: bodies cannot forge lifecycle events or lie about provenance
# ---------------------------------------------------------------------------
"$AG" behavior-remove --all >/dev/null
cat > "$B/forge.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"type":"behavior.started","payload":{"behavior":"forged","fire_key":"x|y"}}\n'
EOF
chmod +x "$B/forge.sh"
"$AG" behavior-add --name forger --on object.created --match '(f:forge)' -- "$B/forge.sh" >/dev/null
R9=$(new_run forge)
"$AG" emit --run "$R9" --type object.created --payload '{"kind":"forge","data":{"a":1}}' >/dev/null
"$AG" react --run "$R9" >/dev/null
t_is "$("$AG" events --run "$R9" --type behavior.completed | jq -r .payload.ok)" false "a body cannot emit behavior.started"
t_is "$("$AG" events --run "$R9" --type behavior.started | jq -s length)" 1 "only the runtime's behavior.started exists"
"$AG" emit --run "$R9" --type behavior.started --payload '{"behavior":"x","fire_key":"y"}' >/dev/null 2>&1
t_is $? 2 "behavior.started is runtime-reserved on the public emit path too"

# argv is an ARRAY: no shell interpretation of arguments
"$AG" behavior-remove --all >/dev/null
cat > "$B/echoarg.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"type":"object.created","payload":{"kind":"got","data":{"arg":"%s"}}}\n' "$1"
EOF
chmod +x "$B/echoarg.sh"
"$AG" behavior-add --name argtest --on object.created --match '(t:trigger)' -- "$B/echoarg.sh" '$(id); `id`; a b' >/dev/null
RA=$(new_run argv)
"$AG" emit --run "$RA" --type object.created --payload '{"kind":"trigger","data":{"a":1}}' >/dev/null
"$AG" react --run "$RA" >/dev/null
t_is "$("$AG" graph --run "$RA" --kind got | jq -r .data.arg)" '$(id); `id`; a b' \
     "argv is passed verbatim as one argument, never through a shell"

# ---------------------------------------------------------------------------
# determinism: a reacted run replays clean and forks correctly
# ---------------------------------------------------------------------------
"$AG" events --run "$R" | jq -c '{type:.type, payload:.payload}' | "$AG" replay --run "$R" --strict >/dev/null
t_ok $? "a run driven by behaviours passes strict replay"
t_is "$("$AG" verify --run "$R" | jq -r .ok)" true "its payload hashes verify"
FK=$("$AG" fork "$R" 8 | jq -r .run)
t_ok $? "a reacted run can be forked"
t_is "$("$AG" events --run "$FK" | jq -s length)" 8 "the fork shares the reacted prefix"

# behavior-remove
t_is "$("$AG" behaviors | jq -s length)" 1 "one behaviour remains registered"
"$AG" behavior-remove --name argtest >/dev/null
t_is "$("$AG" behaviors | jq -s length)" 0 "behavior-remove drops it"
"$AG" behavior-remove --name nope >/dev/null 2>&1
t_is $? 2 "removing an unknown behaviour is an error"

# RPC: react and behaviors are exposed; registration is not (it takes SQL)
r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ag.behavior_add","params":{}}' | "$AG" rpc-child)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32601 "ag.behavior_add is not an RPC method"
r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ag.behaviors"}' | "$AG" rpc-child)
t_ok "$(printf '%s' "$r" | jq -e '.result.behaviors' >/dev/null; echo $?)" "ag.behaviors lists over RPC"
RR=$(new_run rpcreact)
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.react","params":{"run":"%s"}}\n' "$RR" | "$AG" rpc-child)
t_ok "$(printf '%s' "$r" | jq -e '.result.fired == 0' >/dev/null; echo $?)" "ag.react runs over RPC"

t_done
