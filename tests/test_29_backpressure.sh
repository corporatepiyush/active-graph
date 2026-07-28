#!/usr/bin/env bash
# backpressure & failure recovery: a committed response the client never received
# is safely retryable via idem (no duplicate), and a client that hangs up early
# does not take the server down — SIGPIPE is ignored and the next client is served
# (PLAN §13 test_29 / §16 caveat).
. "$(dirname "$0")/harness.bash"
require_socat
"$AG" init >/dev/null

# committed-then-dropped is retryable: an emit whose reply was lost can be
# resent with the same idem key and yields the SAME seq, not a second row
R=$(new_run idem)
s1=$("$AG" emit --run "$R" --type x.act --idem k1 --payload '{"kind":"n","data":{"v":1}}' | jq -r .seq)
s2=$("$AG" emit --run "$R" --type x.act --idem k1 --payload '{"kind":"n","data":{"v":1}}' | jq -r .seq)
t_is "$s1" "$s2" "retry with same idem returns the original seq (idempotent)"
t_is "$("$AG" events --run "$R" --type x.act | jq -s length)" 1 "no duplicate row created by the retry"

# SIGPIPE: a client that disconnects before reading its reply must not kill the
# server; a subsequent client is still served.
SOCK="$AG_DIR/ag.sock"
"$AG" serve >"$TDIR/s.log" 2>&1 &
SPID=$!
trap 'kill "$SPID" 2>/dev/null; pkill -f "UNIX-LISTEN:$SOCK" 2>/dev/null; _harness_cleanup' EXIT
for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
t_ok "$([ -S "$SOCK" ]; echo $?)" "server listening"

# rude client: send a request and immediately drop the connection (never read)
( printf '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}\n' | nc -w 1 -U "$SOCK" >/dev/null 2>&1 & sleep 0.5; kill %1 2>/dev/null ) 2>/dev/null
sleep 1
t_ok "$(kill -0 "$SPID" 2>/dev/null; echo $?)" "server process still alive after a client hangs up early"

# a well-behaved client that follows is served normally
r=$(ipc_call '{"jsonrpc":"2.0","id":2,"method":"ag.ping"}' "$SOCK")
t_is "$(printf '%s' "$r" | jq -s 'any(.[]; .result.ok==true)' 2>/dev/null)" true "next client is served after the rude disconnect"

# REGRESSION: a normal request/response client writes its frame and half-closes.
# socat holds the reply direction open for -t seconds after that half-close, and
# its DEFAULT IS 0.5s — `serve` did not pass -t, so every reply slower than half
# a second was discarded and the client saw a clean EOF with no reply and no
# error. A 1.2s ag.wait is comfortably past that default and comfortably inside
# the 2s request deadline the harness runs with.
slow=$(ipc_call "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ag.wait\",\"params\":{\"run\":\"$R\",\"since_seq\":999999,\"timeout_ms\":1200}}" "$SOCK")
t_is "$(printf '%s' "$slow" | jq -r '.result.events | type' 2>/dev/null)" array \
     "a reply slower than socat's 0.5s default half-close timeout still reaches a half-closed client"

# the store is uncorrupted throughout
t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA integrity_check;')" ok "catalog integrity intact after backpressure"

kill "$SPID" 2>/dev/null; pkill -f "UNIX-LISTEN:$SOCK" 2>/dev/null
t_done
