#!/usr/bin/env bash
# graph projection: deterministic ids, patches, rebuild idempotency (PLAN test_08)
. "$(dirname "$0")/harness.bash"

R=$(new_run "project")
"$AG" emit --run "$R" --type object.created --payload '{"kind":"company","data":{"name":"Acme"}}' >/dev/null
"$AG" emit --run "$R" --type object.created --payload '{"kind":"company","data":{"name":"Globex"}}' >/dev/null
"$AG" emit --run "$R" --type object.created --payload '{"kind":"doc","data":{"t":"memo"}}' >/dev/null
"$AG" emit --run "$R" --type object.updated --payload '{"id":"company#1","patch":{"score":9}}' >/dev/null
"$AG" emit --run "$R" --type relation.created --payload '{"src":"doc#1","kind":"addresses","dst":"company#1"}' >/dev/null

out=$("$AG" project --run "$R")
t_ok $? "projection builds"
t_is "$(printf '%s' "$out" | jq .nodes)" 3 "3 nodes"
t_is "$(printf '%s' "$out" | jq .edges)" 1 "1 edge"

# deterministic ids: per-kind counters, assigned at emit time
ids=$("$AG" graph --run "$R" | jq -r .id | paste -sd, -)
t_is "$ids" "company#1,company#2,doc#1" "ids are <kind>#<n> in creation order"

# ids live in the hashed payload (determinism contract)
pid=$("$AG" events --run "$R" --since 1 --limit 1 | jq -r .payload.id)
t_is "$pid" "company#1" "assigned id recorded inside the event payload"

# patch applied via JSON MergePatch
sc=$("$AG" graph --run "$R" --kind company | jq -r 'select(.id=="company#1").data.score')
t_is "$sc" 9 "object.updated patch applied to node data"

# rebuild is idempotent: byte-identical node set
a=$("$AG" graph --run "$R" | jq -cS . | shasum | cut -d' ' -f1)
"$AG" project --run "$R" >/dev/null
b=$("$AG" graph --run "$R" | jq -cS . | shasum | cut -d' ' -f1)
t_is "$b" "$a" "wholesale rebuild reproduces identical graph"

# edges + reverse filter
e=$("$AG" graph --run "$R" --edges --to 'company#1' | jq -r .src)
t_is "$e" "doc#1" "inbound edge traversal (--to)"

# explain: provenance chain
x=$("$AG" explain --run "$R" --obj 'doc#1')
t_is "$(printf '%s' "$x" | jq -r .object.kind)" doc "explain returns the node"
t_is "$(printf '%s' "$x" | jq -r '.chain[0].type')" object.created "chain includes creating event"

# fork: child projection sees prefix objects and continues id numbering
F=$("$AG" fork "$R" 6 | jq -r .run)
"$AG" emit --run "$F" --type object.created --payload '{"kind":"company","data":{"name":"Initech"}}' >/dev/null
fids=$("$AG" graph --run "$F" --kind company | jq -r .id | paste -sd, -)
t_is "$fids" "company#1,company#2,company#3" "fork continues parent's id numbering"
# parent unaffected
pn=$("$AG" graph --run "$R" --kind company | jq -s length)
t_is "$pn" 2 "parent projection unaffected by child"

# projection is disposable: delete the file, rebuild works
rm -f "$AG_DIR/ag-proj.db" "$AG_DIR/ag-proj.db-wal" "$AG_DIR/ag-proj.db-shm"
"$AG" project --run "$R" >/dev/null
t_ok $? "proj db deleted -> rebuilt from the log"

# edges deduped by PK: emitting the same relation twice yields one edge
R2=$(new_run "dedup")
"$AG" emit --run "$R2" --type object.created --payload '{"kind":"a","data":{}}' >/dev/null
"$AG" emit --run "$R2" --type object.created --payload '{"kind":"b","data":{}}' >/dev/null
"$AG" emit --run "$R2" --type relation.created --payload '{"src":"a#1","kind":"links","dst":"b#1"}' >/dev/null
"$AG" emit --run "$R2" --type relation.created --payload '{"src":"a#1","kind":"links","dst":"b#1"}' >/dev/null
"$AG" project --run "$R2" >/dev/null
t_is "$("$AG" graph --run "$R2" --edges | jq -s length)" 1 "duplicate relation collapsed to 1 edge (PK dedup)"

# "disposable" has to mean disposable in every direction, not just deletion.
# A projection whose SCHEMA is stale must be thrown away and rebuilt in place —
# and that rebuild used to fail every single time, because the teardown left the
# engine's stderr fifo behind and the respawn tripped over it. Repeated because
# the first failure deleted the file, so attempt two "passed" for the wrong
# reason and hid the bug.
for i in 1 2; do
    "$SQ" "$AG_DIR/ag-proj.db" 'PRAGMA user_version=1;' 2>/dev/null
    n=$("$AG" graph --run "$R2" --edges 2>/dev/null | jq -s length)
    t_is "$n" 1 "stale projection schema rebuilds in place and answers (attempt $i)"
done

# a projection that is not a database at all is still just a file to discard
printf 'not a database at all' > "$AG_DIR/ag-proj.db"
n=$(AG_ENG_HANDSHAKE_S=2 timeout "$AG_T_MAX" "$AG" graph --run "$R2" --edges 2>/dev/null | jq -s length)
t_is "$n" 1 "a corrupt projection is discarded and rebuilt, not reported"
t_done
