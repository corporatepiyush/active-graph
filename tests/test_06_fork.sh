#!/usr/bin/env bash
# forks: shared prefix via lineage, no row copying (PLAN test_06, section 9.3)
. "$(dirname "$0")/harness.bash"

P=$(new_run "parent")
"$AG" emit --run "$P" --type x.a --payload '{"i":1}' >/dev/null   # seq 2
"$AG" emit --run "$P" --type x.b --payload '{"i":2}' >/dev/null   # seq 3
"$AG" emit --run "$P" --type x.c --payload '{"i":3}' >/dev/null   # seq 4

C=$("$AG" fork "$P" 3 | jq -r .run)
t_like "$C" "r*-*" "fork created"

# child sees parent's 1..3 but NOT 4
seqs=$("$AG" events --run "$C" | jq -s 'map(.seq)|join(",")' -r)
t_is "$seqs" "1,2,3" "child lineage = parent prefix 1..3"

# prefix rows are NOT copied - child has zero own rows yet
t_is "$(seg_count "$C")" 0 "no rows copied at fork (O(1) fork)"

# child continues at seq 4, independent of parent's seq 4
s=$("$AG" emit --run "$C" --type x.d --payload '{"child":1}' | jq .seq)
t_is "$s" 4 "child's own events start at fork_seq+1"

# parent's seq-4 event is invisible to child; child's own seq 4 shows instead
t4=$("$AG" events --run "$C" --since 3 | jq -r .type)
t_is "$t4" x.d "child seq 4 is the child's event, not the parent's"

# nested fork (grandchild at 4 = includes child's own event)
G=$("$AG" fork "$C" 4 | jq -r .run)
gs=$("$AG" events --run "$G" | jq -s 'map(.seq)|join(",")' -r)
t_is "$gs" "1,2,3,4" "grandchild composes cutoffs across two hops"
gt=$("$AG" events --run "$G" --since 3 | jq -r .type)
t_is "$gt" x.d "grandchild sees child's event at seq 4"

# fork beyond parent's max seq rejected
"$AG" fork "$P" 999 >/dev/null 2>&1
t_fails $? "fork beyond parent max seq rejected"

# forking is NON-DESTRUCTIVE: the paper's fork "proceeds with its own
# independent log" and says nothing about closing the parent. The parent stays
# live and emittable unless the caller explicitly asks otherwise.
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT status FROM runs WHERE run_id='$P';")" live "parent stays live after a fork"
"$AG" emit --run "$P" --type x.after --payload '{"still":"writable"}' >/dev/null
t_ok $? "parent still accepts events after being forked"

# --close-parent is the opt-in that terminates it
P2=$(new_run parent2)
"$AG" emit --run "$P2" --type x.a --payload '{"a":1}' >/dev/null
"$AG" fork "$P2" 1 --close-parent >/dev/null
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT status FROM runs WHERE run_id='$P2';")" forked "--close-parent marks the parent forked"
"$AG" emit --run "$P2" --type x.b --payload '{"b":1}' >/dev/null 2>&1
t_fails $? "a closed parent rejects further events"

# purging a parent is blocked while unpurged children exist
"$AG" purge --run "$P" >/dev/null 2>&1
t_fails $? "purge of a forked parent blocked (children exist)"
t_done
