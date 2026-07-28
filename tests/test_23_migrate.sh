#!/usr/bin/env bash
# schema versioning: the store stamps user_version at create; any open re-checks
# it and fails CLOSED on a mismatch (drift/tamper/old build) rather than reading a
# schema it doesn't understand (PLAN §13 test_23, §8.5b).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null

# fresh store: user_version is set and matches on every db
uv=$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA user_version;')
t_ok "$([ "$uv" -ge 1 ]; echo $?)" "catalog stamped with a non-zero user_version ($uv)"
t_is "$("$SQ" "$AG_DIR/seg-000001.db" 'PRAGMA user_version;')" "$uv" "segment carries the same schema version"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT value FROM config WHERE key='ag_version';")" "0.2.0" "config records the harness version"

# a normal reopen succeeds (version matches)
R=$(new_run r); "$AG" emit --run "$R" --type x.note --payload '{"kind":"n","data":{"a":1}}' >/dev/null
t_is "$("$AG" events --run "$R" | jq -s length)" 2 "store reopens cleanly when versions agree"

# TAMPER: bump the catalog user_version to a future value the binary won't accept
"$SQ" "$AG_DIR/ag-catalog.db" "PRAGMA user_version = $((uv + 100));"
out=$("$AG" run-start --goal after 2>&1); rc=$?
t_ok "$([ $rc -ne 0 ]; echo $?)" "open fails closed on a user_version mismatch"
t_like "$out" "*user_version*" "error names the version mismatch"
t_like "$out" "*migrate*" "error points at migration"

# restore the correct version -> the very same store opens again (no data lost)
"$SQ" "$AG_DIR/ag-catalog.db" "PRAGMA user_version = $uv;"
t_is "$("$AG" events --run "$R" | jq -s length)" 2 "store is usable again once the version is corrected"

# schema fingerprint is an independent guard: dropping an index (schema drift)
# is caught even though user_version still matches
"$SQ" "$AG_DIR/ag-catalog.db" "DROP INDEX IF EXISTS idx_runs_parent;"
out2=$("$AG" run-start --goal drift 2>&1); rc2=$?
t_ok "$([ $rc2 -ne 0 ]; echo $?)" "schema drift (dropped index) is rejected"
t_like "$out2" "*fingerprint*" "error names the schema fingerprint mismatch"

t_done
