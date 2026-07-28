#!/usr/bin/env bash
# The socat serving backend under abuse. socat is the ONLY backend: it forks one
# process per connection, which is what makes connections separable, an accepted
# socket handable to a worker, and one peer's abandoned frame harmless to the
# next. Those are correctness properties, so they are asserted here rather than
# assumed.
. "$(dirname "$0")/harness.bash"
require_socat

"$AG" init >/dev/null
SOCK="$AG_DIR/ag.sock"

# Serving without socat must REFUSE, not degrade to something with different
# correctness properties. Prove it with a PATH that has no socat on it.
NOSOCAT="$TDIR/nosocat"; mkdir -p "$NOSOCAT"
for b in bash sqlite3 nc jq stat head tr sed grep cat rm mkdir printf sleep dd awk; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$NOSOCAT/$b" 2>/dev/null
done
SQBIN=$(command -v "$SQ" 2>/dev/null || echo "$SQ")
err=$(env PATH="$NOSOCAT" AG_SQLITE="$SQBIN" AG_DIR="$AG_DIR" "$AG" serve --transport ipc 2>&1 >/dev/null); rc=$?
t_fails "$rc" "serve REFUSES to start without socat"
t_like "$err" "*socat is required*" "the refusal names socat"
t_like "$err" "*install*" "and tells you how to install it"
t_ok "$([ ! -S "$SOCK" ]; echo $?)" "a refused start leaves no socket behind"
t_ok "$([ ! -f "$AG_DIR/ag-serve.pid" ]; echo $?)" "and no pidfile behind"
t_is "$(env PATH="$NOSOCAT" AG_SQLITE="$SQBIN" AG_DIR="$AG_DIR" "$AG" doctor | jq -r .serve_ok)" false \
     "doctor reports serve_ok=false without socat"

start_server() {  # extra env assignments as args
    rm -f "$SOCK" "$AG_DIR/ag-serve.pid"
    env "$@" "$AG" serve --transport ipc >"$TDIR/serve.log" 2>&1 &
    SPID=$!
    local i
    for i in $(seq 1 100); do [ -S "$SOCK" ] && return 0; sleep 0.05; done
    return 1
}
stop_server() {
    kill "$SPID" 2>/dev/null
    pkill -f "UNIX-LISTEN:$SOCK" 2>/dev/null
    wait "$SPID" 2>/dev/null
    rm -f "$SOCK"
}
call() { ipc_call "$1" "$SOCK"; }
alive() { kill -0 "$SPID" 2>/dev/null; }

start_server
t_ok $? "socat backend binds the IPC endpoint"
t_ok "$(grep -q 'backend: socat' "$TDIR/serve.log"; echo $?)" "startup announces the socat backend"
t_ok "$(grep -q 'max-children' "$TDIR/serve.log"; echo $?)" "and states the concurrency cap"
trap 'stop_server; _harness_cleanup' EXIT

# ---------------------------------------------------------------------------
# sequential clients: every one must be served, none refused
# ---------------------------------------------------------------------------
ok=0
for i in $(seq 1 12); do
    r=$(call "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"ag.ping\"}")
    [ "$(printf '%s' "$r" | jq -r '.id' 2>/dev/null)" = "$i" ] && ok=$((ok+1))
done
t_is "$ok" 12 "12 sequential clients each get their own answer back"
t_ok "$(alive; echo $?)" "server still running"

# real work over the socket, not just ping
r=$(call '{"jsonrpc":"2.0","id":50,"method":"ag.run_start","params":{"goal":"over-nc"}}')
RUN=$(printf '%s' "$r" | jq -r .result.run)
t_like "$RUN" "r*" "run_start works over nc"
r=$(call "{\"jsonrpc\":\"2.0\",\"id\":51,\"method\":\"ag.emit\",\"params\":{\"run\":\"$RUN\",\"type\":\"x.n\",\"payload\":{\"a\":1}}}")
t_is "$(printf '%s' "$r" | jq -r .result.seq)" 2 "emit works over nc"

# ---------------------------------------------------------------------------
# CONCURRENCY — the property nc could not provide at all.
# ---------------------------------------------------------------------------
outdir="$TDIR/conc"; mkdir -p "$outdir"
pids=""
for i in $(seq 1 8); do
    ( call "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"ag.ping\"}" > "$outdir/$i" ) & pids="$pids $!"
done
for p in $pids; do wait "$p" 2>/dev/null; done
got=0
for i in $(seq 1 8); do [ "$(jq -r '.id' < "$outdir/$i" 2>/dev/null)" = "$i" ] && got=$((got+1)); done
t_is "$got" 8 "8 CONCURRENT clients each get their own answer"

# concurrent WRITERS: SQLite serialises them; none may be lost or duplicated
WR=$(call '{"jsonrpc":"2.0","id":200,"method":"ag.run_start","params":{"goal":"conc"}}' | jq -r .result.run)
pids=""
for i in $(seq 1 8); do
    ( call "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"ag.emit\",\"params\":{\"run\":\"$WR\",\"type\":\"x.c\",\"payload\":{\"i\":$i}}}" >/dev/null ) &
    pids="$pids $!"
done
for p in $pids; do wait "$p" 2>/dev/null; done
n=$("$AG" events --run "$WR" | jq -s length)
t_is "$n" 9 "8 concurrent emits all landed exactly once (+ run.started)"
seqs=$("$AG" events --run "$WR" | jq -r .seq | sort -n | tr '\n' ',')
t_is "$seqs" "1,2,3,4,5,6,7,8,9," "sequence numbers are contiguous with no gaps or duplicates"

# ISOLATION: one connection sending garbage must not affect a concurrent peer.
( printf '{"jsonrpc":"2.0","id":300,'; sleep 1 ) | socat -t 2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 &
BADP=$!
r=$(call '{"jsonrpc":"2.0","id":301,"method":"ag.ping"}')
t_is "$(printf '%s' "$r" | jq -r .id)" 301 "a peer mid-garbage cannot corrupt another peer's frame"
t_is "$(printf '%s' "$r" | jq -r .result.ok)" true "and that peer still gets a correct answer"
kill "$BADP" 2>/dev/null; wait "$BADP" 2>/dev/null
t_ok "$(alive; echo $?)" "server alive throughout"

# ---------------------------------------------------------------------------
# a wedged reader must cost AG_REQ_DEADLINE_S, not the server
# ---------------------------------------------------------------------------
( printf '{"jsonrpc":"2.0","id":80,"method":"ag.events","params":{"run":"%s","limit":10}}\n' "$RUN"
  sleep 1 ) | socat -t 2 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 &
WEDGE=$!
sleep 0.5
t_ok "$(alive; echo $?)" "server alive while a client refuses to read its response"
kill "$WEDGE" 2>/dev/null; wait "$WEDGE" 2>/dev/null
sleep 0.5
r=$(call '{"jsonrpc":"2.0","id":81,"method":"ag.ping"}')
t_is "$(printf '%s' "$r" | jq -r .result.ok)" true "server serves again after the wedged client goes away"
stop_server

# ---------------------------------------------------------------------------
# AUTH. With socat every connection is its own process, so the per-connection
# 3-strike counter alone would let a client reconnect for three more guesses
# forever. A shared record enforces a cross-connection lockout (PLAN 12/A07),
# and the server must survive all of it.
# ---------------------------------------------------------------------------
TOK='sock-token-abcdef123456'
rm -f "$AG_DIR/.auth-fails"
start_server AG_TOKEN="$TOK" AG_AUTH_COOLDOWN_S=1 AG_AUTH_MAX_FAILS=4 AG_AUTH_WINDOW_S=60
t_ok $? "server starts with a token configured"

r=$(call "{\"jsonrpc\":\"2.0\",\"id\":90,\"method\":\"ag.ping\",\"params\":{\"auth\":\"$TOK\"}}")
t_is "$(printf '%s' "$r" | jq -r .result.ok)" true "a correct token is accepted"
r=$(call '{"jsonrpc":"2.0","id":91,"method":"ag.ping"}')
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32003 "a missing token is rejected"

# each guess on its OWN connection: without shared state this is unlimited
for i in 1 2 3 4 5; do
    call "{\"jsonrpc\":\"2.0\",\"id\":$i,\"method\":\"ag.ping\",\"params\":{\"auth\":\"wrong-but-long-enough\"}}" >/dev/null
done
t_ok "$([ -f "$AG_DIR/.auth-fails" ]; echo $?)" "failures are recorded across connections"
t_ok "$([ "$(wc -l < "$AG_DIR/.auth-fails")" -ge 4 ]; echo $?)" "each guess counted once"

# past the threshold even the CORRECT token is refused during the cooldown
r=$(call "{\"jsonrpc\":\"2.0\",\"id\":95,\"method\":\"ag.ping\",\"params\":{\"auth\":\"$TOK\"}}")
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32003 "lockout applies once the window threshold is crossed"
t_like "$(printf '%s' "$r" | jq -r .error.message)" "*rate limited*" "the client is told it is rate limited"
t_ok "$(grep -q 'auth_lockout' "$AG_DIR/ag-access.log"; echo $?)" "the lockout is recorded in the access log"
t_ok "$(alive; echo $?)" "server SURVIVES sustained auth failures (no self-inflicted DoS)"
grep -q "$TOK" "$AG_DIR/ag-access.log" 2>/dev/null
t_fails $? "the token never reaches the access log"

# clearing the record restores service — the lockout is a window, not a ban
rm -f "$AG_DIR/.auth-fails"
r=$(call "{\"jsonrpc\":\"2.0\",\"id\":96,\"method\":\"ag.ping\",\"params\":{\"auth\":\"$TOK\"}}")
t_is "$(printf '%s' "$r" | jq -r .result.ok)" true "service resumes once the failure window empties"
stop_server

# ---------------------------------------------------------------------------
# endpoint hygiene
# ---------------------------------------------------------------------------
t_ok "$([ ! -S "$SOCK" ]; echo $?)" "the socket is removed when the server stops"
start_server
t_ok $? "a fresh server binds the same path again"
t_is "$(t_mode "$AG_DIR")" 700 "the store dir is still 0700"
# single-instance guard still holds under the nc backend
"$AG" serve --transport ipc >"$TDIR/serve2.log" 2>&1
t_fails $? "a second nc server is refused"
t_ok "$(grep -qE 'already listening|another server is running' "$TDIR/serve2.log"; echo $?)" "the refusal names the live server"
stop_server

t_done
