#!/usr/bin/env bash
# Permissive replay (paper section 4) plus the operational controls PLAN
# specifies that had no implementation: access log, response cap, maintain's
# rollover check and abandoned-run sweep, pinned file-hash algorithm.
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null

# ---------------------------------------------------------------------------
# Permissive replay: "events are re-emitted from the log and the cache serves
# any request whose hash matches; behaviors whose hashes do not match get fresh
# calls". The plan reports hit/miss per recorded request.
# ---------------------------------------------------------------------------
R=$(new_run "replay")
q1=$("$AG" emit --run "$R" --type llm.requested --payload '{"model":"m","prompt":"a"}')
s1=$(printf '%s' "$q1" | jq -r .seq)
"$AG" emit --run "$R" --type llm.responded --caused-by "$s1" --payload '{"model":"m","text":"A"}' >/dev/null
q2=$("$AG" emit --run "$R" --type tool.requested --payload '{"name":"search","args":{"q":"x"}}')
s2=$(printf '%s' "$q2" | jq -r .seq)
"$AG" emit --run "$R" --type tool.responded --caused-by "$s2" --payload '{"name":"search","rows":3}' >/dev/null
# a request with no recorded answer -> must be reported as a miss
"$AG" emit --run "$R" --type llm.requested --payload '{"model":"m","prompt":"unanswered"}' >/dev/null

plan=$("$AG" replay --run "$R")
t_ok $? "permissive replay runs without --strict"
t_is "$(printf '%s' "$plan" | jq -s length)" 3 "one plan entry per recorded request"
t_is "$(printf '%s' "$plan" | jq -s '[.[]|select(.cache=="hit")]|length')" 2 "both answered requests are cache hits"
t_is "$(printf '%s' "$plan" | jq -s '[.[]|select(.cache=="miss")]|length')" 1 "the unanswered request is a miss"
t_is "$(printf '%s' "$plan" | jq -s -r '.[0].response.text')" A "a hit carries the recorded response payload"
t_is "$(printf '%s' "$plan" | jq -s -r '.[1].response.rows')" 3 "tool responses are served the same way"
t_is "$(printf '%s' "$plan" | jq -s -r '.[2].response')" null "a miss carries no response"
t_ok "$(printf '%s' "$plan" | jq -s -e '.[0].request_hash|test("^[0-9a-f]{64}$")' >/dev/null; echo $?)" \
     "plan entries name the request hash the caller can probe"

# a fork inherits the shared prefix's cache: replaying the child re-uses the
# parent's recorded responses instead of re-executing them (paper section 5).
C=$("$AG" fork "$R" "$s2" | jq -r .run)
cplan=$("$AG" replay --run "$C")
t_is "$(printf '%s' "$cplan" | jq -s '[.[]|select(.cache=="hit")]|length')" 1 \
     "fork's shared prefix serves from the parent's recorded response"

# strict replay still works and is still the divergence detector
"$AG" events --run "$R" | jq -c '{type:.type, payload:.payload}' | "$AG" replay --run "$R" --strict >/dev/null
t_ok $? "strict replay unaffected"

# ---------------------------------------------------------------------------
# Access log (PLAN 10.7 / OWASP A09) — did not exist at all.
# ---------------------------------------------------------------------------
LOG="$AG_DIR/ag-access.log"
rm -f "$LOG"
{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"ag.nope"}'; } | "$AG" rpc-child >/dev/null 2>&1
t_ok "$([ -f "$LOG" ]; echo $?)" "access log is created"
t_is "$(t_mode "$LOG")" 600 "access log is mode 0600"
t_ok "$([ "$(wc -l < "$LOG")" -ge 1 ]; echo $?)" "requests are logged"
t_ok "$(grep -q 'ag.ping' "$LOG"; echo $?)" "the method name is logged"

# log injection: control characters and newlines in a method/id never break a line
rm -f "$LOG"
before=0
req=$(jq -nc '{jsonrpc:"2.0",id:"a\nbc",method:"ag.ping"}')
printf '%s\n' "$req" | "$AG" rpc-child >/dev/null 2>&1
lines=$(wc -l < "$LOG" | tr -d ' ')
t_is "$lines" 1 "a request id containing a newline still produces exactly one log line"
t_ok "$(LC_ALL=C grep -qv '[[:cntrl:]]' "$LOG"; echo $?)" "no control characters reach the log"
# tokens are never logged
rm -f "$LOG"
TOK='secret-token-abcdef123456'
printf '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":{"auth":"%s"}}\n' "$TOK" \
    | AG_TOKEN="$TOK" "$AG" rpc-child >/dev/null 2>&1
grep -q "$TOK" "$LOG"
t_fails $? "the token never appears in the access log"

# failed auth is logged (A09 requires it)
rm -f "$LOG"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":{"auth":"wrong-but-long-enough"}}' \
    | AG_TOKEN="$TOK" "$AG" rpc-child >/dev/null 2>&1
t_ok "$(grep -q -- '-32003' "$LOG"; echo $?)" "auth failures are logged with their code"

# rotation
rm -f "$LOG" "$LOG".1
head -c 200000 /dev/zero | tr '\0' 'x' > "$LOG"
AG_ACCESS_LOG_MAX=1000 "$AG" maintain >/dev/null 2>&1
t_ok "$([ -f "$LOG".1 ]; echo $?)" "oversize access log is rotated to .1"

# ---------------------------------------------------------------------------
# Response cap (PLAN 10.6) — ag.events had no bound at all.
# ---------------------------------------------------------------------------
RB=$(new_run "bigresp")
for i in $(seq 1 20); do
    printf '{"type":"x.big","payload":{"blob":"%s"}}\n' "$(head -c 3000 /dev/zero | tr '\0' q)"
done | "$AG" emit-batch --run "$RB" >/dev/null
out=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.events","params":{"run":"%s","limit":100}}\n' "$RB" \
      | AG_MAX_RESP=2000 "$AG" rpc-child)
t_is "$(printf '%s' "$out" | jq -r .error.code)" -32603 "oversize response is refused with -32603"
t_like "$(printf '%s' "$out" | jq -r .error.message)" "*paginate*" "the error tells the client to paginate"
out=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.events","params":{"run":"%s","limit":100}}\n' "$RB" \
      | "$AG" rpc-child)
t_ok "$(printf '%s' "$out" | jq -e '.result.events|length == 21' >/dev/null; echo $?)" \
     "under the default cap the same request succeeds"

# ---------------------------------------------------------------------------
# maintain: rollover check + abandoned-run sweep (PLAN 7.1 / 7.4).
# ---------------------------------------------------------------------------
X="$TDIR/rollstore"
AG_DIR="$X" "$AG" init >/dev/null
XR=$(AG_DIR="$X" "$AG" run-start --goal grow | jq -r .run)
# A payload this size cannot be an ARGV STRING: Linux caps a single argument
# at 128 KiB (MAX_ARG_STRLEN), so passing it as --payload fails with E2BIG there
# while it works on macOS. Use the file form, which is portable.
BIG=$(big_payload_file "$TDIR/big-payload.json" doc 300000)
AG_DIR="$X" "$AG" emit --run "$XR" --type object.created "--payload@$BIG" >/dev/null
AG_DIR="$X" "$AG" run-end --run "$XR" >/dev/null
t_is "$("$SQ" "$X/ag-catalog.db" "SELECT count(*) FROM segments WHERE state='active';")" 1 "one active segment before maintain"
AG_DIR="$X" AG_SEG_MAX_BYTES=262144 "$AG" maintain >/dev/null 2>&1
t_ok "$([ "$("$SQ" "$X/ag-catalog.db" 'SELECT count(*) FROM segments;')" -ge 2 ]; echo $?)" \
     "maintain rolls over an over-threshold segment (run_start is no longer the only trigger)"
t_is "$("$SQ" "$X/ag-catalog.db" "SELECT count(*) FROM segments WHERE state='active';")" 1 "still exactly one active segment"

# abandoned run: catalog row with zero events, older than the grace period
Y="$TDIR/sweepstore"
AG_DIR="$Y" "$AG" init >/dev/null
YR=$(AG_DIR="$Y" "$AG" run-start --goal abandoned | jq -r .run)
yrid=$("$SQ" "$Y/ag-catalog.db" "SELECT rid FROM runs WHERE run_id='$YR';")
"$SQ" "$Y/seg-000001.db" "DELETE FROM run_events WHERE rid=$yrid;"
"$SQ" "$Y/ag-catalog.db" "UPDATE runs SET started_ms = started_ms - 7200000 WHERE rid=$yrid;"
t_is "$("$SQ" "$Y/ag-catalog.db" "SELECT status FROM runs WHERE rid=$yrid;")" live "precondition: run still marked live"
AG_DIR="$Y" "$AG" maintain >/dev/null 2>&1
t_is "$("$SQ" "$Y/ag-catalog.db" "SELECT status FROM runs WHERE rid=$yrid;")" failed \
     "maintain sweeps an event-less run past the grace period to 'failed'"
# a young event-less run must NOT be swept
YR2=$(AG_DIR="$Y" "$AG" run-start --goal fresh | jq -r .run)
AG_DIR="$Y" "$AG" maintain >/dev/null 2>&1
t_is "$("$SQ" "$Y/ag-catalog.db" "SELECT status FROM runs WHERE run_id='$YR2';")" live "a fresh run is left alone"

# ---------------------------------------------------------------------------
# File hash algorithm is pinned and recorded (it used to silently switch
# between sha256 and sha3 depending on which binary was installed).
# ---------------------------------------------------------------------------
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT value FROM config WHERE key='file_hash_algo';")" \
     sha256 "the store records the file hash algorithm it was created with"
t_is "$("$AG" doctor | jq -r .file_hash)" sha256 "doctor reports the algorithm"
t_is "$("$AG" doctor | jq -r .hash_ok)" true "doctor confirms a usable hash tool"
"$SQ" "$AG_DIR/ag-catalog.db" "UPDATE config SET value='sha3-256' WHERE key='file_hash_algo';"
err=$("$AG" init 2>&1 >/dev/null); rc=$?
t_fails "$rc" "a store sealed under a different hash algorithm is refused"
t_like "$err" "*sha3-256*" "the error names the recorded algorithm"
"$SQ" "$AG_DIR/ag-catalog.db" "UPDATE config SET value='sha256' WHERE key='file_hash_algo';"

t_done
