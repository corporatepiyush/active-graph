#!/usr/bin/env bash
# sealing: drained segment -> immutable single file (PLAN 7.2, milestone 8c)
. "$(dirname "$0")/harness.bash"
export AG_SEG_MAX_BYTES=262144
# A payload this size cannot be an ARGV STRING: Linux caps a single argument
# at 128 KiB (MAX_ARG_STRLEN), so passing it as --payload fails with E2BIG there
# while it works on macOS. Use the file form, which is portable.
BIG=$(big_payload_file "$TDIR/big-payload.json" doc 300000)
state() { "$SQ" "$AG_DIR/ag-catalog.db" "SELECT state FROM segments WHERE seg_id=$1;"; }
fill_and_end() {  # $1=run : write enough to push its segment over threshold, then end
    "$AG" emit --run "$1" --type object.created --payload '{"kind":"doc","data":{"a":1}}' >/dev/null
    "$AG" emit --run "$1" --type llm.responded --actor llm --payload '{"model":"m","text":"t"}' >/dev/null
    "$AG" emit --run "$1" --type tool.responded --payload '{"name":"grep"}' --ctx '{"dur_ms":42}' >/dev/null
    "$AG" emit --run "$1" --type object.created "--payload@$BIG" >/dev/null
    "$AG" run-end --run "$1" >/dev/null       # adds run.ended -> 6 events total (with run.started)
}

"$AG" init >/dev/null
R1=$(new_run r1); fill_and_end "$R1"        # R1 in seg1, terminal, seg1 now > threshold
R2=$(new_run r2)                            # rollover: seg1 draining, seg2 active

# refuse to seal a segment that still has a live run
"$AG" emit --run "$R2" --type object.created "--payload@$BIG" >/dev/null   # push seg2
new_run pushnew >/dev/null                   # roll again; seg2 draining but R2 still live
"$AG" seal --seg 2 >/dev/null 2>&1
t_is $? 2 "refuse to seal a segment with a live run"
t_is "$(state 2)" draining "refused seal leaves segment draining (not stuck sealing)"

# seal drained seg1
out=$("$AG" seal --seg 1 2>/dev/null)
t_like "$out" '*"sealed":*1*' "seal seals drained segment 1"
t_is "$(state 1)" sealed "segment 1 is sealed"

# sealed = one file, chmod 400, metadata + rollups recorded
t_is "$(ls "$AG_DIR"/seg-000001.db* 2>/dev/null | wc -l | tr -d ' ')" 1 "sealed segment is a single file"
perm=$(t_mode "$AG_DIR/seg-000001.db")
t_is "$perm" 400 "sealed file is chmod 400"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT length(file_sha3)||'|'||event_count||'|'||run_count FROM segments WHERE seg_id=1;")" "32|6|1" "sha3(32B)+event_count(6)+run_count(1) recorded"
t_ok "$([ "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT count(*) FROM seg_stats WHERE seg_id=1;")" -ge 1 ]; echo $?)" "rollups written at seal"

# immutable reads still work
t_is "$("$AG" events --run "$R1" | jq -s length)" 6 "events readable from sealed segment"
t_is "$("$AG" verify --run "$R1" | jq -r .ok)" true "verify works on sealed segment"

# fork whose parent lives in a sealed segment (ids continue across the boundary)
F=$("$AG" fork "$R1" 5 | jq -r .run)
"$AG" emit --run "$F" --type object.created --payload '{"kind":"doc","data":{"c":1}}' >/dev/null
t_is "$("$AG" graph --run "$F" --kind doc | jq -r .id | paste -sd, -)" "doc#1,doc#2,doc#3" "ids continue from sealed-parent lineage"
t_is "$("$AG" verify --run "$F" | jq -r .ok)" true "verify spans sealed + active segments"

# crash-resume: force the sealed seg back to 'sealing' with lost hash -> re-seal recovers
"$SQ" "$AG_DIR/ag-catalog.db" "UPDATE segments SET state='sealing', file_sha3=NULL WHERE seg_id=1;"
"$AG" seal --seg 1 >/dev/null 2>&1
t_is "$(state 1)" sealed "interrupted seal (state=sealing) resumes to sealed"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT length(file_sha3) FROM segments WHERE seg_id=1;")" 32 "hash recomputed on resume"

# idempotent: re-sealing a sealed segment is a no-op success
"$AG" seal --seg 1 >/dev/null 2>&1
t_is $? 0 "re-seal of a sealed segment is idempotent"

# maintain auto-seals drained segments (seg2 becomes drainable once R2 ends)
"$AG" run-end --run "$R2" >/dev/null
m=$("$AG" maintain 2>/dev/null)
t_like "$m" '*2*' "maintain auto-seals the newly-drained segment 2"
t_is "$(state 2)" sealed "segment 2 sealed by maintain"

# reopen across sealed + active segments
t_is "$("$AG" init | jq -r .ok)" true "store reopens with sealed segments present"
t_done
