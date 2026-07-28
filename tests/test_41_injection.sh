#!/usr/bin/env bash
# Regressions for the security review. Every case below was a WORKING exploit or
# a confirmed silent-corruption bug before the fix; each assertion pins the
# specific property that closed it.
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null

# ---------------------------------------------------------------------------
# S1: second-order SQL injection through a stored object payload.
# ag_explain pasted a json_object() result back into the next query as
# json('<text>'), so object data controlled SQL. The PoC ran writefile() and
# wrote an arbitrary file as the server user.
# ---------------------------------------------------------------------------
R=$(new_run "inject")
MARK="$TDIR/PWNED"
rm -f "$MARK"
PAY=$(jq -nc --arg m "$MARK" '{kind:"doc",data:{x:("'"'"'||writefile('"'"'" + $m + "'"'"','"'"'pwned'"'"')||'"'"'")}}')
"$AG" emit --run "$R" --type object.created --payload "$PAY" >/dev/null
t_ok $? "payload with SQL metacharacters is accepted and stored"

out=$(timeout "$AG_T_MAX" "$AG" explain --run "$R" --obj 'doc#1'); rc=$?
t_is "$rc" 0 "explain returns on an injection-shaped payload"
t_ok "$([ ! -e "$MARK" ]; echo $?)" "S1: writefile() did NOT execute (no file created)"
t_is "$(printf '%s' "$out" | jq -r '.object.data.x')" \
     "'||writefile('$MARK','pwned')||'" "S1: payload round-trips byte-exact, never evaluated"

# ---------------------------------------------------------------------------
# S2: the same primitive with an UNBALANCED quote used to hang the engine
# forever (the sqlite3 shell waited for the string to close; nothing on the read
# path has a timeout). A hang is worse than an error: in nc serve mode it wedges
# the listener permanently.
# ---------------------------------------------------------------------------
R2=$(new_run "quote")
"$AG" emit --run "$R2" --type object.created --payload '{"kind":"doc","data":{"name":"O'"'"'Brien"}}' >/dev/null
t0=$SECONDS
out=$(timeout "$AG_T_MAX" "$AG" explain --run "$R2" --obj 'doc#1'); rc=$?
dt=$((SECONDS - t0))
t_is "$rc" 0 "S2: unbalanced quote in data does not hang explain (${dt}s)"
t_ok "$([ "$dt" -lt 25 ]; echo $?)" "S2: completed well inside the timeout"
t_is "$(printf '%s' "$out" | jq -r '.object.data.name')" "O'Brien" "S2: apostrophe preserved exactly"

# every read surface must survive the same data
t_ok "$(timeout "$AG_T_MAX" "$AG" graph --run "$R2" >/dev/null 2>&1; echo $?)" "S2: graph survives"
t_ok "$(timeout "$AG_T_MAX" "$AG" events --run "$R2" >/dev/null 2>&1; echo $?)" "S2: events survives"
t_ok "$(timeout "$AG_T_MAX" "$AG" diff "$R" "$R2" >/dev/null 2>&1; echo $?)" "S2: diff survives"

# ---------------------------------------------------------------------------
# S3: the engine wire protocol was injectable from any client-supplied text.
# ---------------------------------------------------------------------------
# S3a: a value beginning with an engine diagnostic prefix was classified as an
# error and silently became the empty string.
r=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ag.run_start","params":{"goal":"Error: something"}}' \
    | timeout "$AG_T_MAX" "$AG" rpc-child)
RUN=$(printf '%s' "$r" | jq -r .result.run)
t_like "$RUN" "r*" "S3a: run_start with an Error:-prefixed goal succeeds"
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT goal FROM runs WHERE run_id='$RUN';")" \
     "Error: something" "S3a: goal stored verbatim, not swallowed as a diagnostic"

for pfx in 'Runtime error near x' 'Parse error: nope' 'Error near line 1'; do
    r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.run_start","params":{"goal":"%s"}}\n' "$pfx" \
        | timeout "$AG_T_MAX" "$AG" rpc-child)
    RUN=$(printf '%s' "$r" | jq -r .result.run)
    t_is "$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT goal FROM runs WHERE run_id='$RUN';")" \
         "$pfx" "S3a: '${pfx:0:20}...' survives intact"
done

# S3b: a multi-line value was truncated at the first newline.
req=$(jq -nc '{jsonrpc:"2.0",id:2,method:"ag.run_start",params:{goal:"line1\nline2\nline3"}}')
RUN=$(printf '%s\n' "$req" | timeout "$AG_T_MAX" "$AG" rpc-child | jq -r .result.run)
got=$("$SQ" "$AG_DIR/ag-catalog.db" "SELECT goal FROM runs WHERE run_id='$RUN';")
t_is "$got" "$(printf 'line1\nline2\nline3')" "S3b: multi-line goal is not truncated"

# S3c: a value containing the request terminator used to end the read early, so
# one request consumed another's output. The terminator now carries a per-process
# nonce no client can observe.
G=$(for i in $(seq 1 40); do printf 'AG_DONE:%d\n' "$i"; done)
POISON=$(jq -nc --arg g "$G" '{jsonrpc:"2.0",id:1,method:"ag.run_start",params:{goal:$g}}')
resp=$( { printf '%s\n' "$POISON"
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"ag.ping","params":{}}'
          printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"ag.ping","params":{}}'; } \
        | timeout "$AG_T_MAX" "$AG" rpc-child)
t_is "$(printf '%s' "$resp" | sed -n 1p | jq -r '.id')" 1 "S3c: poisoned request answers its own id"
t_is "$(printf '%s' "$resp" | sed -n 1p | jq -r 'has("result")')" true \
     "S3c: poisoned request succeeds (no cross-request error leakage)"
t_is "$(printf '%s' "$resp" | sed -n 2p | jq -r '.result.ok')" true "S3c: next request unaffected"
t_is "$(printf '%s' "$resp" | sed -n 3p | jq -r '.result.ok')" true "S3c: and the one after"
t_is "$(printf '%s' "$resp" | grep -c '^{')" 3 "S3c: exactly three responses, no desync"

# and with a nonce-shaped guess
G2=$(printf 'AG_DONE:deadbeefdeadbeef:1\nAG_DONE:0000000000000000:2\n')
POISON2=$(jq -nc --arg g "$G2" '{jsonrpc:"2.0",id:7,method:"ag.run_start",params:{goal:$g}}')
resp=$( { printf '%s\n' "$POISON2"; printf '%s\n' '{"jsonrpc":"2.0","id":8,"method":"ag.ping"}'; } \
        | timeout "$AG_T_MAX" "$AG" rpc-child)
t_is "$(printf '%s' "$resp" | sed -n 2p | jq -r '.id')" 8 "S3c: guessed nonce does not desync either"

# ---------------------------------------------------------------------------
# S4: purge left offloaded payloads (everything over AG_BLOB_MIN) in the segment
# file while reporting mode "physical". The PoC recovered an SSN with grep.
# ---------------------------------------------------------------------------
nblobs() { "$SQ" "$AG_DIR/seg-000001.db" 'SELECT count(*) FROM blobs;'; }
b0=$(nblobs)
V=$(new_run "pii")
SECRET="SSN-123-45-6789-$(head -c 2000 /dev/zero | tr '\0' A)"
"$AG" emit --run "$V" --type x.pii --payload "$(jq -nc --arg s "$SECRET" '{secret:$s}')" >/dev/null
t_is "$(nblobs)" "$((b0+1))" "S4: large payload was offloaded to blobs"
t_ok "$(t_in_db "$AG_DIR/seg-000001.db" SSN-123-45-6789; echo $?)" \
     "S4: (precondition) the secret is on disk before the purge"
out=$("$AG" purge --run "$V")
t_is "$(printf '%s' "$out" | jq -r .mode)" physical "S4: purge reports a physical delete"
t_ok "$([ "$(printf '%s' "$out" | jq -r .purged_blobs)" -ge 1 ]; echo $?)" "S4: purge reports the blobs it removed"
t_is "$(nblobs)" "$b0" "S4: the victim's blob row is gone, others untouched"
t_ok "$(t_in_file "$AG_DIR/seg-000001.db" SSN-123-45-6789; test $? -ne 0; echo $?)" \
     "S4: the secret bytes are gone from the segment file"
t_ok "$(t_in_file "$AG_DIR/seg-000001.db-wal" SSN-123-45-6789; test $? -ne 0; echo $?)" \
     "S4: and gone from the WAL"

# a blob still referenced by a surviving run must NOT be collected
b0=$(nblobs)
K=$(new_run "keeper")
SHARED=$(jq -nc --arg s "shared-$(head -c 1000 /dev/zero | tr '\0' B)" '{v:$s}')
"$AG" emit --run "$K" --type x.big --payload "$SHARED" >/dev/null
V2=$(new_run "victim2")
"$AG" emit --run "$V2" --type x.big --payload "$SHARED" >/dev/null
t_is "$(nblobs)" "$((b0+1))" "content-addressed blob is shared by two runs, stored once"
"$AG" purge --run "$V2" >/dev/null
t_is "$(nblobs)" "$((b0+1))" "S4: a blob another live run references is kept"
t_is "$("$AG" events --run "$K" --type x.big | jq -r .payload.v | head -c 7)" "shared-" "S4: keeper's payload still readable"

# ---------------------------------------------------------------------------
# S8: the store directory mode is the only portable access control for the IPC
# socket and the db files. A pre-existing world-writable AG_DIR was accepted
# silently and doctor reported ok:true.
# ---------------------------------------------------------------------------
W="$TDIR/wideopen"; mkdir -m 0777 "$W"
err=$(AG_DIR="$W" "$AG" init 2>&1 >/dev/null); rc=$?
if [ "$(t_mode "$W")" = 700 ]; then
    t_is "$rc" 0 "S8: a world-writable store dir is tightened to 0700"
else
    t_fails "$rc" "S8: a store dir that cannot be tightened is refused"
    t_like "$err" "*0700*" "S8: error explains the requirement"
fi
W2="$TDIR/wideopen2"; mkdir -m 0755 "$W2"
AG_DIR="$W2" "$AG" init >/dev/null 2>&1
t_is "$(t_mode "$W2")" 700 "S8: 0755 store dir is tightened too"
t_is "$(AG_DIR="$W2" "$AG" doctor | jq -r .dir_ok)" true "S8: doctor reports dir_ok"

# ---------------------------------------------------------------------------
# S10: error JSON was hand-rolled with only '"' escaped, so a message carrying a
# backslash or a control character produced invalid (or injectable) JSON.
# ---------------------------------------------------------------------------
err=$("$AG" emit --run 'r000000000-0000' --type 'x.a\b"c' --payload '{}' 2>&1 >/dev/null)
printf '%s' "$err" | jq -e . >/dev/null 2>&1
t_ok $? "S10: CLI error output is valid JSON with backslashes and quotes in the message"
err=$("$AG" emit --run "$(printf 'r000000000-00\t0')" --type x.a --payload '{}' 2>&1 >/dev/null)
printf '%s' "$err" | jq -e . >/dev/null 2>&1
t_ok $? "S10: control characters in a message do not break the JSON"
t_ok "$("$AG" doctor | jq -e . >/dev/null 2>&1; echo $?)" "S10: doctor emits valid JSON"

t_done
