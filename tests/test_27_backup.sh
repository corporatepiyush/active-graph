#!/usr/bin/env bash
# integrity + backup + drop of sealed segments (PLAN 7.2, milestone 8d)
. "$(dirname "$0")/harness.bash"
export AG_SEG_MAX_BYTES=262144
# A payload this size cannot be an ARGV STRING: Linux caps a single argument
# at 128 KiB (MAX_ARG_STRLEN), so passing it as --payload fails with E2BIG there
# while it works on macOS. Use the file form, which is portable.
BIG=$(big_payload_file "$TDIR/big-payload.json" doc 300000)
state() { "$SQ" "$AG_DIR/ag-catalog.db" "SELECT state FROM segments WHERE seg_id=$1;"; }

"$AG" init >/dev/null
R1=$(new_run r1); "$AG" emit --run "$R1" --type object.created "--payload@$BIG" >/dev/null
"$AG" run-end --run "$R1" >/dev/null
R2=$(new_run r2)                 # rollover: seg1 draining
"$AG" seal --seg 1 >/dev/null    # seg1 sealed

# verify-files: clean sealed segment passes
out=$("$AG" verify-files); rc=$?
t_is "$rc" 0 "verify-files passes on a clean sealed segment"
t_is "$(printf '%s' "$out" | jq -c '.corrupt')" '[]' "no corruption reported"
t_is "$(printf '%s' "$out" | jq '.checked')" 1 "one sealed segment checked"

# MULTI-SEGMENT: verify-files and backup must visit EVERY sealed segment, not
# just the first. They read the segment list as one row per segment; a
# group_concat(...,char(10)) through the first-line-only scalar reader made both
# silently single-segment regardless of store size.
MS="$TDIR/multi"
AG_DIR="$MS" "$AG" init >/dev/null
for i in 1 2 3; do
    MR=$(AG_DIR="$MS" "$AG" run-start --goal "m$i" | jq -r .run)
    AG_DIR="$MS" "$AG" emit --run "$MR" --type object.created "--payload@$BIG" >/dev/null
    AG_DIR="$MS" "$AG" run-end --run "$MR" >/dev/null
done
AG_DIR="$MS" "$AG" maintain >/dev/null 2>&1
nsealed=$("$SQ" "$MS/ag-catalog.db" "SELECT count(*) FROM segments WHERE state='sealed';")
t_ok "$([ "$nsealed" -ge 2 ]; echo $?)" "multi-segment store has $nsealed sealed segments"
mout=$(AG_DIR="$MS" "$AG" verify-files)
t_is "$(printf '%s' "$mout" | jq '.checked')" "$nsealed" "verify-files checks ALL sealed segments"
mb=$(AG_DIR="$MS" "$AG" backup "$TDIR/mbak")
t_is "$(printf '%s' "$mb" | jq '.sealed_copied|length')" "$nsealed" "backup copies ALL sealed segments"
# corrupt the LAST sealed segment: a single-segment scan would miss it
last=$("$SQ" "$MS/ag-catalog.db" "SELECT seg_id FROM segments WHERE state='sealed' ORDER BY seg_id DESC LIMIT 1;")
lastp=$("$SQ" "$MS/ag-catalog.db" "SELECT path FROM segments WHERE seg_id=$last;")
chmod u+w "$lastp"; printf 'Z' | dd of="$lastp" bs=1 seek=5000 count=1 conv=notrunc 2>/dev/null; chmod 400 "$lastp"
mout=$(AG_DIR="$MS" "$AG" verify-files 2>/dev/null); rc=$?
t_is "$rc" 1 "corruption in the LAST segment is detected"
t_is "$(printf '%s' "$mout" | jq -c '.corrupt')" "[$last]" "the correct segment is named"

# bitrot/tamper: flip a byte -> detected
chmod u+w "$AG_DIR/seg-000001.db"
printf 'Z' | dd of="$AG_DIR/seg-000001.db" bs=1 seek=5000 count=1 conv=notrunc 2>/dev/null
chmod 400 "$AG_DIR/seg-000001.db"
out=$("$AG" verify-files 2>/dev/null); rc=$?
t_is "$rc" 1 "verify-files fails on a tampered sealed segment"
t_is "$(printf '%s' "$out" | jq -c '.corrupt')" '[1]' "the corrupt segment is named"

# quarantine isolates the bad segment; other runs stay queryable
"$AG" verify-files --quarantine >/dev/null 2>&1
t_is "$(state 1)" quarantined "corrupt segment quarantined"
t_is "$("$AG" events --run "$R2" | jq -s length)" 1 "runs in healthy segments remain readable"
# a read that needs the quarantined segment fails clearly (not silently wrong)
"$AG" events --run "$R1" >/dev/null 2>&1
t_ok "$([ $? -ne 0 ]; echo $?)" "reading a run in a quarantined segment errors"

# fresh store for backup + drop (quarantine left seg1 unusable)
rm -rf "$AG_DIR"; "$AG" init >/dev/null
B1=$(new_run b1); "$AG" emit --run "$B1" --type object.created "--payload@$BIG" >/dev/null
"$AG" run-end --run "$B1" >/dev/null
B2=$(new_run b2)
"$AG" seal --seg 1 >/dev/null

# backup: sealed file copied + verified, catalog + active snapshotted
dest="$TDIR/backup1"
out=$("$AG" backup "$dest")
t_is "$(printf '%s' "$out" | jq -c '.sealed_copied')" '[1]' "backup copies the sealed segment"
t_ok "$([ -f "$dest/seg-000001.db" ]; echo $?)" "sealed segment present in backup"
t_ok "$([ -f "$dest/ag-catalog.db" ]; echo $?)" "catalog snapshot present in backup"
t_ok "$([ -f "$dest/seg-000002.db" ]; echo $?)" "active segment snapshot present in backup"
# backup copy is byte-faithful (hash matches source)
h_src=$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT lower(hex(file_sha3)) FROM segments WHERE seg_id=1;")
h_bkp=$( (command -v sha256sum >/dev/null && sha256sum "$dest/seg-000001.db" || shasum -a 256 "$dest/seg-000001.db") | cut -d' ' -f1)
t_is "$h_bkp" "$h_src" "backed-up sealed file matches the recorded hash"

# incremental: second backup re-copies nothing (sealed file already present)
out=$("$AG" backup "$dest")
t_is "$(printf '%s' "$out" | jq -c '.sealed_copied')" '[]' "second backup is incremental (no re-copy)"

# drop: purge a sealed-segment run is a tombstone; maintain reclaims the file
p=$("$AG" purge --run "$B1")
t_is "$(printf '%s' "$p" | jq -r '.mode')" tombstone "purge of a sealed-segment run is a tombstone"
t_is "$(printf '%s' "$p" | jq '.purged_events')" 0 "tombstone deletes zero rows physically"
t_is "$(state 1)" sealed "segment still sealed until fully purged + dropped"
t_ok "$([ -f "$AG_DIR/seg-000001.db" ]; echo $?)" "file still present before drop"
d=$("$AG" maintain 2>/dev/null)
t_is "$(printf '%s' "$d" | jq -c '.dropped')" '[1]' "maintain drops the fully-purged segment"
t_is "$(state 1)" dropped "segment marked dropped"
t_ok "$([ ! -f "$AG_DIR/seg-000001.db" ]; echo $?)" "segment file unlinked (bytes reclaimed)"

# store stays consistent; the surviving run is unaffected
t_is "$("$AG" init | jq -r .ok)" true "store consistent after drop"
t_is "$("$AG" events --run "$B2" | jq -s length)" 1 "surviving run still readable"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA integrity_check;')" ok "catalog integrity after drop"
t_done
