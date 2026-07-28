#!/usr/bin/env bash
# env fingerprint: every run records the exact environment + harness build that
# produced it; the build id flips when the script is modified (PLAN §13 test_17).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null
envof() { "$SQ" "$AG_DIR/ag-catalog.db" "SELECT json(env) FROM runs WHERE run_id='$1';"; }
fld()   { "$SQ" "$AG_DIR/ag-catalog.db" "SELECT env->>'$2' FROM runs WHERE run_id='$1';"; }

R=$(new_run fp)
e=$(envof "$R")
for k in harness build os bash sqlite; do
  t_ok "$(echo "$e" | jq -e --arg k "$k" 'has($k)' >/dev/null; echo $?)" "run env carries '$k'"
done

# fields reflect the REAL environment, not placeholders
t_is "$(fld "$R" bash)"   "$("$AG" doctor | jq -r .bash)"            "env.bash matches the running bash"
t_is "$(fld "$R" sqlite)" "$("$SQ" :memory: 'SELECT sqlite_version();')" "env.sqlite matches the resolved sqlite"
t_like "$(fld "$R" os)"   "*$(uname -s)*"                            "env.os carries the real uname"

# build id == first 12 hex of the script's sha256 (a content fingerprint)
# sha256sum on Linux/busybox, shasum on macOS - try both, order-independent
want=$(sha256sum "$AG" 2>/dev/null | cut -c1-12); [ -n "$want" ] || want=$(shasum -a 256 "$AG" | cut -c1-12)
t_is "$(fld "$R" build)" "$want" "env.build is the script's content hash"

# a MODIFIED harness build records a DIFFERENT build id (dirty-tree flag flips)
cp "$AG" "$TDIR/ag_edited.sh"; printf '\n# a change\n' >> "$TDIR/ag_edited.sh"; chmod +x "$TDIR/ag_edited.sh"
R2=$(AG_DIR="$AG_DIR" "$TDIR/ag_edited.sh" run-start --goal fp2 | jq -r .run)
t_ok "$([ "$(fld "$R2" build)" != "$(fld "$R" build)" ]; echo $?)" "edited build records a flipped build id"
want2=$(sha256sum "$TDIR/ag_edited.sh" 2>/dev/null | cut -c1-12)
[ -n "$want2" ] || want2=$(shasum -a 256 "$TDIR/ag_edited.sh" | cut -c1-12)
t_is "$(fld "$R2" build)" "$want2" "flipped id matches the edited script's hash"

# forks inherit their OWN fingerprint (recorded at fork time), still well-formed
"$AG" emit --run "$R" --type object.created --payload '{"kind":"doc","data":{"a":1}}' >/dev/null
"$AG" run-end --run "$R" >/dev/null
F=$("$AG" fork "$R" 1 | jq -r .run)
t_ok "$(echo "$(envof "$F")" | jq -e 'has("build") and has("sqlite")' >/dev/null; echo $?)" "forked run also carries a full env fingerprint"

t_done
