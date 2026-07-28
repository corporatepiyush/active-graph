#!/usr/bin/env bash
# injection safety: hostile bytes are stored byte-exact, never executed (PLAN test_03)
. "$(dirname "$0")/harness.bash"

R=$(new_run "binding")

emit_roundtrip() {  # $1 = payload json; returns 0 if stored byte-exact
    local p=$1 seq got want
    seq=$("$AG" emit --run "$R" --type x.hostile --payload "$p" | jq .seq) || return 1
    got=$("$AG" events --run "$R" --since $((seq-1)) --limit 1 | jq -cS .payload)
    want=$(printf '%s' "$p" | jq -cS .)
    [ "$got" = "$want" ]
}

emit_roundtrip '{"sql":"'\''; DROP TABLE runs; --"}';        t_ok $? "single-quote SQL injection stored inert"
emit_roundtrip '{"cmd":"$(rm -rf /tmp/nope)"}';               t_ok $? "command substitution stored inert"
emit_roundtrip '{"tick":"`reboot`"}';                         t_ok $? "backticks stored inert"
emit_roundtrip '{"q":"she said \"hi\" & <script>alert(1)</script>"}'; t_ok $? "quotes/angle brackets"
emit_roundtrip '{"nl":"line1\nline2\ttabbed"}';               t_ok $? "escaped newline/tab round-trip"
emit_roundtrip '{"uni":"héllo wörld 日本語 🎉"}';               t_ok $? "unicode round-trip"
emit_roundtrip '{"fmt":"%s%d%n"}';                            t_ok $? "printf format strings inert"
emit_roundtrip '{"param":":run OR 1=1"}';                     t_ok $? "sqlite named-param-lookalike inert"

# a moderately large payload (~100KB) survives byte-exact through blob path
big=$(jq -cn '{data: ("x" * 100000)}')
emit_roundtrip "$big"; t_ok $? "100KB payload round-trips byte-exact"

# NUL byte in payload: bash's read strips NUL before the script sees it, so
# the JSON arrives without the NUL and is stored cleanly (known §16 limitation).
# Verify the payload is stored WITHOUT the NUL (stripped, not rejected or crashed).
nulf="$TDIR/nul_payload.json"
printf '{"k":"has\x00byte"}' > "$nulf"
nul_seq=$("$AG" emit --run "$R" --type x.nul --payload - < "$nulf" | jq -r .seq)
nul_got=$("$AG" events --run "$R" --since $((nul_seq-1)) --limit 1 | jq -r .payload.k)
t_is "$nul_got" "hasbyte" "NUL byte stripped by bash read; stored without NUL, no crash"

# payload at the 1MiB cap boundary: slightly under passes, slightly over is rejected
big1m="$TDIR/big1m.json"
jq -cn --argjson n 1000000 '{data: ("A" * $n)}' > "$big1m"
seq1m=$("$AG" emit --run "$R" --type x.hostile --payload - < "$big1m" | jq -r .seq)
got1m=$("$AG" events --run "$R" --since $((seq1m-1)) --limit 1 | jq -cS '.payload')
want1m=$(jq -cS . < "$big1m")
t_is "$got1m" "$want1m" "payload at 1MiB boundary round-trips byte-exact"

big_over="$TDIR/big_over.json"
jq -cn --argjson n 2000000 '{data: ("B" * $n)}' > "$big_over"
"$AG" emit --run "$R" --type x.hostile --payload - < "$big_over" >/dev/null 2>&1
t_fails $? "payload exceeding AG_MAX_PAYLOAD (2MB) rejected"

# schema untouched after all hostility
n=$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT count(*) FROM sqlite_schema WHERE name='runs';")
t_is "$n" 1 "runs table still exists (no injection executed)"

# fuzz: FUZZN random-ish strings as payload values, all must round-trip or be
# rejected cleanly (exit 2) - never crash, never corrupt
bad=0
for i in $(seq 1 "$FUZZN"); do
    v=$(LC_ALL=C tr -dc 'a-zA-Z0-9 ~!@#$%^&*()_+={}[]|;:<>,.?/\\'"'"'"-' < /dev/urandom | head -c 40)
    p=$(jq -cn --arg v "$v" '{v:$v}') || continue
    if ! emit_roundtrip "$p"; then bad=$((bad+1)); fi
done
t_is "$bad" 0 "$FUZZN-case fuzz: all round-tripped byte-exact"
t_done
