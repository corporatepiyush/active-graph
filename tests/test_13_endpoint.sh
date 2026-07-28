#!/usr/bin/env bash
# endpoint acquisition: IPC default, stale socket, flag cross-validation (PLAN test_13)
. "$(dirname "$0")/harness.bash"
require_socat

"$AG" init >/dev/null
SOCK="$AG_DIR/ag.sock"

# default transport is IPC at $AG_DIR/ag.sock
"$AG" serve >"$TDIR/serve1.log" 2>&1 &
SPID=$!
trap 'kill "$SPID" 2>/dev/null; _harness_cleanup' EXIT
for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
t_ok "$([ -S "$SOCK" ]; echo $?)" "IPC socket appears at default path"
grep -q 'listening on unix:' "$TDIR/serve1.log"
t_ok $? "debug line announces unix endpoint"

# live round-trip over the socket (client must hold the connection open for
# the reply - piping printf straight into nc EOFs too early)
r=$(ipc_call '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}' "$SOCK")
t_is "$(printf '%s' "$r" | jq -r .result.ok 2>/dev/null)" true "ping over IPC socket"

# second server on same socket refused while first is alive
"$AG" serve >"$TDIR/serve2.log" 2>&1
t_fails $? "second server refused on live socket"
grep -qE 'already listening|another server is running' "$TDIR/serve2.log"
t_ok $? "error names the live server"

# stale socket: kill server hard, leave socket file, next serve cleans it
kill -9 "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
pkill -f "nc -klU $SOCK" 2>/dev/null; sleep 0.3
[ -S "$SOCK" ] || "$SQ" :memory: 'SELECT 1;' >/dev/null  # (socket may already be gone; both fine)
"$AG" serve >"$TDIR/serve3.log" 2>&1 &
SPID=$!
for i in $(seq 1 50); do grep -q 'backend:' "$TDIR/serve3.log" && break; sleep 0.1; done
sleep 0.3
r=$(ipc_call '{"jsonrpc":"2.0","id":2,"method":"ag.ping"}' "$SOCK")
t_is "$(printf '%s' "$r" | jq -r .result.ok 2>/dev/null)" true "server recovers after stale socket"
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
pkill -f "nc -klU $SOCK" 2>/dev/null

# flag cross-validation fails closed
"$AG" serve --port 5000 >/dev/null 2>&1
t_is $? 2 "--port with default ipc transport -> usage error"
"$AG" serve --transport tcp --socket /tmp/x.sock >/dev/null 2>&1
t_is $? 2 "--socket with tcp transport -> usage error"
"$AG" serve --transport bogus >/dev/null 2>&1
t_is $? 2 "unknown transport -> usage error"
"$AG" serve --token abc >/dev/null 2>&1
t_is $? 2 "--token on argv refused"

# socket path length guard (sun_path limit)
LONG=$(printf 'x%.0s' $(seq 1 120))
"$AG" serve --socket "/tmp/$LONG.sock" >/dev/null 2>&1
t_is $? 2 "socket path >100 bytes rejected"

# port probe: free-port detection works and prints debug lines
err=$( { "$AG" serve --transport tcp >"$TDIR/tcp.log" 2>&1 & echo $!; } )
TPID=$err
for i in $(seq 1 50); do grep -q 'selected free port' "$TDIR/tcp.log" && break; sleep 0.1; done
grep -q 'selected free port' "$TDIR/tcp.log"
t_ok $? "tcp mode scans and announces a free port"
PORT=$(sed -n 's/.*selected free port \([0-9]*\).*/\1/p' "$TDIR/tcp.log" | head -1)
sleep 0.3
r=$(tcp_call '{"jsonrpc":"2.0","id":3,"method":"ag.ping"}' "$PORT")
t_is "$(printf '%s' "$r" | jq -r .result.ok 2>/dev/null)" true "ping over scanned TCP port"
kill "$TPID" 2>/dev/null; wait "$TPID" 2>/dev/null
pkill -f "nc -kl 127.0.0.1 $PORT" 2>/dev/null

# explicit TCP port bind: --port on a known free port (use a wide range to
# reduce collision with the 39 other parallel test files)
FREE_PORT=$(( (RANDOM % 50000) + 10000 ))
"$AG" serve --transport tcp --port "$FREE_PORT" >"$TDIR/ep.log" 2>&1 &
EPID=$!
trap 'kill "$SPID" 2>/dev/null; kill "$EPID" 2>/dev/null; pkill -f "nc -kl 127.0.0.1 $FREE_PORT" 2>/dev/null; _harness_cleanup' EXIT
for i in $(seq 1 50); do grep -q 'listening on' "$TDIR/ep.log" 2>/dev/null && break; sleep 0.1; done
sleep 0.3
r=$(tcp_call '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}' "$FREE_PORT")
t_is "$(printf '%s' "$r" | jq -r .result.ok 2>/dev/null)" true "ping over explicit TCP port $FREE_PORT"
kill "$EPID" 2>/dev/null; wait "$EPID" 2>/dev/null
pkill -f "nc -kl 127.0.0.1 $FREE_PORT" 2>/dev/null; sleep 0.2

# explicit port busy: --port on an already-bound port -> hard error
"$AG" serve --transport tcp --port "$FREE_PORT" >"$TDIR/busy1.log" 2>&1 &
BPID=$!
for i in $(seq 1 50); do grep -q 'listening on' "$TDIR/busy1.log" 2>/dev/null && break; sleep 0.1; done
"$AG" serve --transport tcp --port "$FREE_PORT" >"$TDIR/busy2.log" 2>&1
t_fails $? "second server on explicit busy port fails"
kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
pkill -f "nc -kl 127.0.0.1 $FREE_PORT" 2>/dev/null
t_done
