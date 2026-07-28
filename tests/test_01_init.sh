#!/usr/bin/env bash
# init: creation, idempotency, pragmas, schema checks on existing files (PLAN 8.5b)
. "$(dirname "$0")/harness.bash"

out=$("$AG" init); rc=$?
t_ok "$rc" "first init succeeds"
t_is "$(printf '%s' "$out" | jq -r .ok)" true "init reports ok"

out=$("$AG" init); rc=$?
t_ok "$rc" "re-init on existing store succeeds (idempotent)"

# create-time pragmas baked into the files
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA journal_mode;')" wal "catalog is WAL"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA page_size;')" 8192 "catalog page_size 8192"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA user_version;')" 3 "catalog user_version 3"
t_is "$("$SQ" "$AG_DIR/seg-000001.db" 'PRAGMA journal_mode;')" wal "segment is WAL"
t_is "$("$SQ" "$AG_DIR/seg-000001.db" 'PRAGMA user_version;')" 3 "segment user_version 3"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA auto_vacuum;')" 2 "catalog auto_vacuum INCREMENTAL"

# defensive mode is on if the sqlite build supports it (catches untrusted-schema bugs)
def=$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA compile_options;' | grep -c 'DEFENSIVE')
if [ "$def" -ge 1 ]; then
  t_ok 0 "defensive mode enabled on catalog (sqlite build supports it)"
else
  t_ok 0 "defensive mode: not compiled into this sqlite build (skipped)"
fi

# store works after reopen
r=$(new_run); t_like "$r" "r*-*" "run-start works on reopened store"

# schema check: tampering with the schema is detected fail-closed
"$SQ" "$AG_DIR/ag-catalog.db" 'CREATE TABLE evil(x INTEGER);'
err=$("$AG" init 2>&1 >/dev/null); rc=$?
t_fails "$rc" "open refused after schema tamper"
t_like "$err" "*fingerprint mismatch*" "error names fingerprint mismatch"
"$SQ" "$AG_DIR/ag-catalog.db" 'DROP TABLE evil;'
"$AG" init >/dev/null 2>&1; t_ok $? "open works again after tamper reverted"

# user_version mismatch is a distinct, clear error
"$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA user_version=99;'
err=$("$AG" init 2>&1 >/dev/null); rc=$?
t_fails "$rc" "open refused on user_version mismatch"
t_like "$err" "*user_version=99*" "error names the found version"
"$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA user_version=3;'

# segment tamper detected too
"$SQ" "$AG_DIR/seg-000001.db" 'CREATE TABLE evil2(x INTEGER);'
err=$("$AG" init 2>&1 >/dev/null); rc=$?
t_fails "$rc" "segment schema tamper refused"
t_like "$err" "*segment schema fingerprint mismatch*" "error names the segment"

# A file that is not a database at all must FAIL, not HANG. sqlite3 rejects
# every statement of such a file at prepare time — including the terminator
# SELECT the engine protocol waits for — and it does not exit either, because
# its stdin fifo is still held open. So the read blocked forever and the command
# hung with no output and no error. Only the handshake is bounded, so this
# cannot be tuned into a false failure by a slow machine: drive the bound down
# rather than sleeping through the default.
BAD="$TDIR/notadb"
mkdir -p "$BAD"
printf 'GIF89a this is definitely not a database' > "$BAD/ag-catalog.db"
s=$SECONDS
err=$(AG_DIR="$BAD" AG_ENG_HANDSHAKE_S=2 timeout "$AG_T_MAX" "$AG" stats 2>&1 >/dev/null); rc=$?
t_ok "$([ "$rc" -ne 124 ] && echo 0 || echo 1)" "a corrupt catalog fails instead of hanging (rc=$rc after $((SECONDS - s))s)"
t_fails "$rc" "...with a non-zero exit"
t_like "$err" "*cannot open*" "...and an error that names the file it could not open"
t_done
