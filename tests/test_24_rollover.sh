#!/usr/bin/env bash
# segment rollover + cross-segment lineage (PLAN 7.2 / 7.3, milestone 8b)
. "$(dirname "$0")/harness.bash"
export AG_SEG_MAX_BYTES=262144   # minimum; fresh segment ~80KB, so a couple of
                                 # large-payload events push the active seg over
# A payload this size cannot be an ARGV STRING: Linux caps a single argument
# at 128 KiB (MAX_ARG_STRLEN), so passing it as --payload fails with E2BIG there
# while it works on macOS. Use the file form, which is portable.
BIG=$(big_payload_file "$TDIR/big-payload.json" doc 300000)
segstate() { "$SQ" "$AG_DIR/ag-catalog.db" "SELECT group_concat(seg_id||':'||state,' ') FROM segments;"; }
pinned()   { "$SQ" "$AG_DIR/ag-catalog.db" "SELECT seg_id FROM runs WHERE run_id='$1';"; }

"$AG" init >/dev/null

# config floor: a too-small threshold is rejected (would roll forever)
out=$(AG_SEG_MAX_BYTES=1000 "$AG" run-start 2>&1); rc=$?
t_is "$rc" 2 "sub-256KB threshold rejected"

# a fresh store does NOT roll over on the first runs
R1=$(new_run r1)
t_is "$(segstate)" "1:active" "fresh segment stays active (no premature rollover)"
"$AG" emit --run "$R1" --type object.created --payload '{"kind":"doc","data":{"a":1}}' >/dev/null  # doc#1
"$AG" emit --run "$R1" --type object.created "--payload@$BIG" >/dev/null                            # doc#2, seg > 256KB
"$AG" run-end --run "$R1" >/dev/null

# next run_start rolls over
R2=$(new_run r2)
t_is "$(segstate)" "1:draining 2:active" "over-threshold active segment rolls; old one drains"
t_is "$(pinned "$R2")" 2 "new run pins to the new active segment"
t_is "$(pinned "$R1")" 1 "prior run stays pinned to its original segment"
t_ok "$([ -f "$AG_DIR/seg-000002.db" ]; echo $?)" "segment-2 file created"

# a run never spans segments: R2's events are all in seg-2
"$AG" emit --run "$R2" --type object.created --payload '{"kind":"claim","data":{"z":1}}' >/dev/null
n1=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE rid=$(rid_of "$R2");")
n2=$("$SQ" "$AG_DIR/seg-000002.db" "SELECT count(*) FROM run_events WHERE rid=$(rid_of "$R2");")
t_is "$n1" 0 "R2 has no rows in seg-1"
t_ok "$([ "$n2" -ge 2 ]; echo $?)" "R2's events live in seg-2"

# CROSS-SEGMENT FORK: fork the finished R1 (in seg-1); child pins to active seg-2
F=$("$AG" fork "$R1" 3 | jq -r .run)
t_is "$(pinned "$F")" 2 "fork pins to the current active segment (not the parent's)"
"$AG" emit --run "$F" --type object.created --payload '{"kind":"doc","data":{"child":1}}' >/dev/null

# deterministic ids continue ACROSS the segment boundary (approach A: id is a
# pure function of the log lineage, faithful to the paper's determinism contract)
ids=$("$AG" graph --run "$F" --kind doc | jq -r .id | paste -sd, -)
t_is "$ids" "doc#1,doc#2,doc#3" "object ids continue parent's numbering across segments"

# lineage reads span both files
seqs=$("$AG" events --run "$F" | jq -s 'map(.seq)|join(",")' -r)
t_is "$seqs" "1,2,3,4" "fork lineage reads parent prefix (seg-1) + own events (seg-2)"

# the fork's own new event physically lives in seg-2, shared prefix is NOT copied
fn1=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE rid=$(rid_of "$F");")
t_is "$fn1" 0 "fork copied zero prefix rows into seg-1 (O(1) fork preserved)"

# verify recomputes hashes across both segments
t_is "$("$AG" verify --run "$F" | jq -r .ok)" true "verify passes across segment boundary"

# structural diff across segments
d=$("$AG" diff "$R1" "$F")
t_is "$(printf '%s' "$d" | jq '.objects.added|length')" 1 "cross-segment diff detects the added object"

# reopen: the store re-verifies and picks the right active segment
out=$("$AG" init); t_is "$(printf '%s' "$out" | jq -r .ok)" true "store reopens across multiple segments"
t_is "$(segstate)" "1:draining 2:active" "segment states persist across reopen"

# chained multi-rollover: push seg-2 over and roll again
"$AG" emit --run "$R2" --type object.created "--payload@$BIG" >/dev/null
"$AG" run-end --run "$R2" >/dev/null
R3=$(new_run r3)
t_is "$(pinned "$R3")" 3 "second rollover pins to seg-3"
t_like "$(segstate)" "*3:active*" "three-segment store consistent"

# concurrent rollover: N processes racing on an over-threshold active segment
# must produce exactly one new active (no double-active, no lost runs)
CR=$(new_run cr); "$AG" emit --run "$CR" --type object.created "--payload@$BIG" >/dev/null
"$AG" run-end --run "$CR" >/dev/null
before=$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT count(*) FROM runs;")
for i in $(seq 1 8); do "$AG" run-start --goal "race$i" >/dev/null 2>&1 & done
wait
act=$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT count(*) FROM segments WHERE state='active';")
t_is "$act" 1 "concurrent rollover leaves exactly ONE active segment"
after=$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT count(*) FROM runs;")
t_is "$after" "$((before + 8))" "all 8 racing run-starts succeeded (none lost to contention)"
orphans=$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT count(*) FROM runs r WHERE NOT EXISTS(SELECT 1 FROM segments s WHERE s.seg_id=r.seg_id);")
t_is "$orphans" 0 "no run pinned to a non-existent segment"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA integrity_check;')" ok "catalog integrity after concurrent rollover"

# --- stale rollover-lock reaping (crash recovery, PLAN 7.2) --------------------
# The mkdir(2) rollover mutex is abandoned if the holder is kill -9'd between
# acquiring and releasing it; without reaping that wedges EVERY future rollover
# (spin -> BUSY) forever, freezing write availability once a segment fills.
LOCK="$AG_DIR/.rollover.lock"
active_seg() { "$SQ" "$AG_DIR/ag-catalog.db" "SELECT seg_id FROM segments WHERE state='active';"; }
push_over() { local r; r=$(new_run "$1"); "$AG" emit --run "$r" --type object.created "--payload@$BIG" >/dev/null; "$AG" run-end --run "$r" >/dev/null; }

# a lock abandoned by a DEAD holder is reaped so the next rollover proceeds
push_over ov1
mkdir "$LOCK"; printf '%s' 999999 > "$LOCK/pid"     # simulate kill -9 mid-rollover
prev=$(active_seg)
start=$(date +%s)
R=$("$AG" run-start --goal after-dead-lock 2>/dev/null); rc=$?
t_diag "run-start after dead-holder lock took $(( $(date +%s) - start ))s"
t_is "$rc" 0 "run-start reaps a dead-holder rollover lock instead of wedging"
t_ok "$([ ! -d "$LOCK" ]; echo $?)" "dead-holder lock is gone after reaping"
t_ok "$([ "$(active_seg)" -gt "$prev" ]; echo $?)" "rollover proceeded once the stale lock was reaped"

# a lock held by a LIVE process must NOT be stolen (safety: no wrong reap)
mkdir "$LOCK"; printf '%s' "$$" > "$LOCK/pid"        # $$ = this (alive) test process
"$AG" maintain >/dev/null 2>&1
t_ok "$([ -d "$LOCK" ]; echo $?)" "ag maintain leaves a live-holder lock intact"
rm -f "$LOCK/pid"; rmdir "$LOCK"

# ag maintain proactively reaps a dead-holder lock even absent rollover pressure
mkdir "$LOCK"; printf '%s' 999999 > "$LOCK/pid"
"$AG" maintain >/dev/null 2>&1
t_ok "$([ ! -d "$LOCK" ]; echo $?)" "ag maintain reaps a dead-holder rollover lock"

# a lock with no attributable holder (crash in the mkdir->pid-write window) is
# reaped only once it is older than the stale threshold, never while fresh
mkdir "$LOCK"                                        # no pid file written yet
AG_ROLLOVER_LOCK_STALE_S=0 "$AG" maintain >/dev/null 2>&1
t_ok "$([ ! -d "$LOCK" ]; echo $?)" "no-pid lock past the stale threshold is reaped"
mkdir "$LOCK"
AG_ROLLOVER_LOCK_STALE_S=99999 "$AG" maintain >/dev/null 2>&1
t_ok "$([ -d "$LOCK" ]; echo $?)" "recent no-pid lock within the threshold is preserved"
rmdir "$LOCK"

# a truncated/garbage pid file (a crash can leave a partial write) must not
# defeat reaping: 'abc' must not block rmdir, and '0' must not be read as a live
# holder (kill -0 0 signals our own process group and always succeeds).
for junk in abc 0; do
  mkdir "$LOCK"; printf '%s' "$junk" > "$LOCK/pid"
  AG_ROLLOVER_LOCK_STALE_S=0 "$AG" maintain >/dev/null 2>&1
  t_ok "$([ ! -d "$LOCK" ]; echo $?)" "garbage pid file '$junk' is reaped when stale (not a permanent wedge)"
  rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null
done

t_done
