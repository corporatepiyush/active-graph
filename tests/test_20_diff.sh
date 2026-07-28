#!/usr/bin/env bash
# structural diff between runs (PLAN test_20, paper section 5.2)
. "$(dirname "$0")/harness.bash"

R=$(new_run "diff")
"$AG" emit --run "$R" --type object.created --payload '{"kind":"doc","data":{"title":"orig"}}' >/dev/null
"$AG" emit --run "$R" --type object.created --payload '{"kind":"claim","data":{"text":"c1"}}' >/dev/null

# identical runs -> empty diff
d=$("$AG" diff "$R" "$R")
t_is "$(printf '%s' "$d" | jq '.objects.added|length')" 0 "self-diff: no added"
t_is "$(printf '%s' "$d" | jq '.objects.changed|length')" 0 "self-diff: no changed"
t_is "$(printf '%s' "$d" | jq '.relations.added|length')" 0 "self-diff: no relations"

# fork and mutate the child
F=$("$AG" fork "$R" 3 | jq -r .run)
"$AG" emit --run "$F" --type object.updated --payload '{"id":"doc#1","patch":{"title":"edited"}}' >/dev/null
"$AG" emit --run "$F" --type object.created --payload '{"kind":"finding","data":{"sev":"high"}}' >/dev/null
"$AG" emit --run "$F" --type relation.created --payload '{"src":"finding#1","kind":"addresses","dst":"doc#1"}' >/dev/null

d=$("$AG" diff "$R" "$F")
t_is "$(printf '%s' "$d" | jq '.objects.added|length')" 1 "one object added in fork"
t_is "$(printf '%s' "$d" | jq -r '.objects.added[0].id')" "finding#1" "added object identified"
t_is "$(printf '%s' "$d" | jq '.objects.changed|length')" 1 "one object changed"
t_is "$(printf '%s' "$d" | jq -r '.objects.changed[0].from.title')" orig "changed: from-state"
t_is "$(printf '%s' "$d" | jq -r '.objects.changed[0].to.title')" edited "changed: to-state"
t_is "$(printf '%s' "$d" | jq '.objects.removed|length')" 0 "nothing removed"
t_is "$(printf '%s' "$d" | jq '.relations.added|length')" 1 "one relation added"
t_is "$(printf '%s' "$d" | jq '.patches|length')" 1 "patch after fork point reported"
t_is "$(printf '%s' "$d" | jq -r '.patches[0].id')" "doc#1" "patch names its object"

# reverse direction: the fork's additions appear as removals
d=$("$AG" diff "$F" "$R")
t_is "$(printf '%s' "$d" | jq '.objects.removed|length')" 1 "reverse diff: added becomes removed"

# unrelated runs: diff still works, patches empty (no shared prefix)
Q=$(new_run "other")
"$AG" emit --run "$Q" --type object.created --payload '{"kind":"doc","data":{"title":"x"}}' >/dev/null
d=$("$AG" diff "$R" "$Q")
t_is "$(printf '%s' "$d" | jq '.patches|length')" 0 "no patch report without ancestry"
t_is "$(printf '%s' "$d" | jq '.objects.changed|length')" 1 "same deterministic id, different data -> changed"

# cross-segment diff: fork, seal the parent's segment, then diff. The diff must
# still produce correct results even when the parent's events live in a sealed
# segment that requires ATTACH + lineage CTE.
F2=$("$AG" fork "$R" 3 | jq -r .run)
"$AG" emit --run "$F2" --type object.created --payload '{"kind":"patch","data":{"fix":"x"}}' >/dev/null
"$AG" run-end --run "$R" >/dev/null 2>&1
"$AG" run-start --goal "roll-seal" >/dev/null 2>&1
"$AG" seal --all >/dev/null 2>&1
d2=$("$AG" diff "$R" "$F2")
t_is "$(printf '%s' "$d2" | jq '.objects.added|length')" 1 "cross-segment diff: one object added"
t_is "$(printf '%s' "$d2" | jq -r '.objects.added[0].id')" "patch#1" "cross-segment diff: added object identified"
t_done
