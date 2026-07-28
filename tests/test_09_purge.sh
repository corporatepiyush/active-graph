#!/usr/bin/env bash
# purge: a run's own events are deleted; co-resident runs are untouched; the
# operation is idempotent/resumable; purged rids are never reattached (PLAN §13).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null

# victim with many events + a keeper that must survive untouched
V=$(new_run victim)
n=$(for i in $(seq 1 50); do printf '{"type":"x.tick","payload":{"i":%d}}\n' "$i"; done | "$AG" emit-batch --run "$V" | jq -r '.count')
t_is "$n" 50 "victim has 50 events"
K=$(new_run keeper)
for i in 1 2 3; do "$AG" emit --run "$K" --type x.note --payload "{\"kind\":\"n\",\"data\":{\"i\":$i}}" >/dev/null; done
ridV=$(rid_of "$V")

out=$("$AG" purge --run "$V"); rc=$?
t_is "$rc" 0 "purge succeeds"
t_is "$(echo "$out" | jq -r '.purged_events')" 51 "purge reports 51 deleted events (50 + run.started)"

# victim events physically gone; reads signal purged, not silent-empty
"$AG" events --run "$V" >/dev/null 2>&1; t_ok "$([ $? -ne 0 ]; echo $?)" "purged run's events read as an error, not empty"
t_is "$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE rid=$ridV;")" 0 "no victim rows remain in the segment"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT status FROM runs WHERE run_id='$V';")" purged "victim run tombstoned"

# keeper is completely untouched (concurrent-run isolation)
t_is "$("$AG" events --run "$K" | jq -s length)" 4 "keeper still has all its events (3 + run.started)"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA integrity_check;')" ok "store integrity intact after purge"

# AUTOINCREMENT: a fresh run gets a rid ABOVE the purged one — no orphan reattach
A=$(new_run after); ridA=$(rid_of "$A")
t_ok "$([ "$ridA" -gt "$ridV" ]; echo $?)" "new run's rid ($ridA) is above the purged rid ($ridV) — no reuse"

# idempotent / resumable: purging again is safe and deletes nothing more
out2=$("$AG" purge --run "$V"); rc2=$?
t_is "$rc2" 0 "re-purge of an already-purged run is safe (resumable)"
t_is "$(echo "$out2" | jq -r '.purged_events')" 0 "re-purge deletes zero additional events"

# purge with an unpurged fork child is refused until the child goes first
P=$(new_run parent); "$AG" emit --run "$P" --type object.created --payload '{"kind":"doc","data":{"a":1}}' >/dev/null
"$AG" run-end --run "$P" >/dev/null
C=$("$AG" fork "$P" 1 | jq -r .run)
"$AG" purge --run "$P" >/dev/null 2>&1; t_is $? 2 "parent purge blocked while an unpurged fork child exists"
"$AG" purge --run "$C" >/dev/null 2>&1
"$AG" purge --run "$P" >/dev/null 2>&1; t_is $? 0 "parent purge proceeds once the child is purged"

# kill -9 mid-purge: the operation must be resumable (WAL rollback + idempotent sweep)
V2=$(new_run victim2)
for i in $(seq 1 100); do printf '{"type":"x.tick","payload":{"i":%d}}\n' "$i"; done | "$AG" emit-batch --run "$V2" >/dev/null
V2_COUNT=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE rid=$(rid_of "$V2");")
t_ok "$([ "$V2_COUNT" -gt 50 ]; echo $?)" "victim2 populated ($V2_COUNT rows)"
# start purge in background, kill it immediately
"$AG" purge --run "$V2" >/dev/null 2>&1 &
VPID=$!
for _ in $(seq 1 100); do kill -0 "$VPID" 2>/dev/null && break; sleep 0.02; done
kill -9 "$VPID" 2>/dev/null; wait "$VPID" 2>/dev/null
# store is still consistent after the crash
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA integrity_check;')" ok "catalog integrity ok after kill -9 mid-purge"
# a second purge attempt completes the job
out2=$("$AG" purge --run "$V2"); rc2=$?
t_is "$rc2" 0 "re-purge after kill -9 completes successfully"
t_is "$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE rid=$(rid_of "$V2");")" 0 "all victim2 rows deleted after resumed purge"

t_done
