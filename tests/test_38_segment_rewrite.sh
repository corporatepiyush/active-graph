#!/usr/bin/env bash
# segment-rewrite: GDPR-grade hard-delete of one run's data out of a SEALED,
# immutable segment while co-resident runs stay byte-intact (PLAN 7.2 / §16).
. "$(dirname "$0")/harness.bash"
export AG_SEG_MAX_BYTES=262144
# A payload this size cannot be an ARGV STRING: Linux caps a single argument
# at 128 KiB (MAX_ARG_STRLEN), so passing it as --payload fails with E2BIG there
# while it works on macOS. Use the file form, which is portable.
BIG=$(big_payload_file "$TDIR/big-payload.json" doc 300000)
segstate() { "$SQ" "$AG_DIR/ag-catalog.db" "SELECT state FROM segments WHERE seg_id=$1;"; }
"$AG" init >/dev/null

# victim run (PII) + bystander run, both pinned to seg-1; a big object rolls it
V=$("$AG" run-start --goal 'SECRET-goal' --tags '["pii-tag"]' | jq -r .run)
"$AG" emit --run "$V" --type x.note        --payload '{"kind":"n","data":{"ssn":"SSN-111-22-3333"}}' >/dev/null
"$AG" emit --run "$V" --type object.created --payload '{"kind":"doc","data":{"secret":"victim-body"}}' >/dev/null
B=$(new_run keep)
"$AG" emit --run "$B" --type x.note        --payload '{"kind":"n","data":{"ok":"bystander"}}' >/dev/null
"$AG" emit --run "$B" --type object.created "--payload@$BIG" >/dev/null
"$AG" run-end --run "$V" >/dev/null; "$AG" run-end --run "$B" >/dev/null
RJ=$(new_run roll); "$AG" run-end --run "$RJ" >/dev/null   # rollover -> seg-2; end it so seg-2 can seal later
"$AG" maintain >/dev/null 2>&1     # seal seg-1
t_is "$(segstate 1)" sealed "seg-1 sealed and immutable"
t_ok "$(t_in_db "$AG_DIR/seg-000001.db" SSN-111; echo $?)" "victim PII is present in the sealed file before erasure"

# erasure on a non-sealed run is rejected (regular purge covers that path)
Vactive=$(new_run active-victim); "$AG" emit --run "$Vactive" --type x.note --payload '{"kind":"n","data":{"a":1}}' >/dev/null
"$AG" segment-rewrite "$Vactive" >/dev/null 2>&1
t_is $? 2 "segment-rewrite refuses a run whose segment is not sealed"
"$AG" run-end --run "$Vactive" >/dev/null   # don't leave it live (would block later seals)
"$AG" segment-rewrite bogus-run >/dev/null 2>&1; t_is $? 2 "unknown run rejected"
"$AG" segment-rewrite >/dev/null 2>&1;            t_is $? 2 "missing arg rejected with usage error"

# THE erasure
out=$("$AG" segment-rewrite "$V"); rc=$?
t_is "$rc" 0 "segment-rewrite succeeds on the sealed victim"
t_is "$(echo "$out" | jq -r '.mode')" "segment-rewrite" "reports segment-rewrite mode"

# victim bytes are physically gone from the file (not just tombstoned)
t_ok "$(t_in_db "$AG_DIR/seg-000001.db" SSN-111; test $? -ne 0; echo $?)" "victim event payload erased from the file"
t_ok "$(t_in_db "$AG_DIR/seg-000001.db" victim-body; test $? -ne 0; echo $?)" "victim blob erased from the file"
t_ok "$(grep -qa SECRET-goal "$AG_DIR/ag-catalog.db"; test $? -ne 0; echo $?)" "victim goal PII scrubbed from the catalog"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT status||'|'||goal||'|'||tags FROM runs WHERE run_id='$V';")" "purged||[]" "run tombstoned + goal/tags scrubbed"
"$AG" events --run "$V" >/dev/null 2>&1; t_ok "$([ $? -ne 0 ]; echo $?)" "erased run now reads as purged"

# bystander is untouched, byte-for-byte
t_is "$("$AG" events --run "$B" | jq -s length)" 4 "bystander keeps all its events"
t_is "$("$AG" graph  --run "$B" | jq -rc .id | paste -sd, -)" "doc#1" "bystander projection intact"
t_ok "$(t_in_db "$AG_DIR/seg-000001.db" bystander; echo $?)" "bystander data still present in the rewritten file"

# the rewritten segment is consistent and its recomputed hash is trusted
t_is "$(segstate 1)" sealed "segment re-sealed after rewrite"
t_is "$("$SQ" "file:$AG_DIR/seg-000001.db?immutable=1" 'PRAGMA integrity_check;')" ok "rewritten segment passes integrity_check"
t_is "$("$AG" verify-files 2>/dev/null | jq -c '.corrupt')" "[]" "verify-files trusts the recomputed hash (no false corruption)"

# fork-child guard: a run with an unpurged sealed-segment fork can't be erased yet
V2=$(new_run v2); "$AG" emit --run "$V2" --type object.created --payload '{"kind":"doc","data":{"z":1}}' >/dev/null
"$AG" emit --run "$V2" --type object.created "--payload@$BIG" >/dev/null; "$AG" run-end --run "$V2" >/dev/null
CH=$("$AG" fork "$V2" 1 | jq -r .run)
RJ2=$(new_run roll2); "$AG" run-end --run "$RJ2" >/dev/null; "$AG" maintain >/dev/null 2>&1
"$AG" segment-rewrite "$V2" >/dev/null 2>&1; t_is $? 2 "erasure blocked while an unpurged fork child exists"
"$AG" purge --run "$CH" >/dev/null 2>&1
"$AG" segment-rewrite "$V2" >/dev/null 2>&1; t_is $? 0 "erasure proceeds once the child is purged"

t_done
