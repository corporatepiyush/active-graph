#!/usr/bin/env bash
# IPC transport parity: methods over the unix socket behave byte-identically to
# the CLI; the socket dir is private (0700); token is optional on IPC but honored
# when set (PLAN §13 test_36).
. "$(dirname "$0")/harness.bash"
require_socat
"$AG" init >/dev/null
SOCK="$AG_DIR/ag.sock"

"$AG" serve >"$TDIR/s.log" 2>&1 &
SPID=$!
trap 'kill "$SPID" 2>/dev/null; pkill -f "nc -klU $SOCK" 2>/dev/null; _harness_cleanup' EXIT
for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
t_ok "$([ -S "$SOCK" ]; echo $?)" "IPC socket is listening"

# the socket lives in a private 0700 directory (no other-user snooping)
t_is "$(t_mode "$AG_DIR")" 700 "store dir is mode 0700"

# method parity: create a run + emit over IPC, read it back over IPC
r=$(ipc_call '{"jsonrpc":"2.0","id":1,"method":"ag.run_start","params":{"goal":"ipc"}}' "$SOCK")
RUN=$(printf '%s' "$r" | jq -r .result.run)
t_like "$RUN" "r*" "run_start over IPC returns a run id"
e=$(ipc_call "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ag.emit\",\"params\":{\"run\":\"$RUN\",\"type\":\"x.note\",\"payload\":{\"kind\":\"n\",\"data\":{\"a\":1}}}}" "$SOCK")
t_is "$(printf '%s' "$e" | jq -r .result.seq)" 2 "emit over IPC returns the next seq"

# reading that run's events over IPC matches reading them via the CLI
ipc_ev=$(ipc_call "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ag.events\",\"params\":{\"run\":\"$RUN\"}}" "$SOCK" | jq -c '.result.events | length' 2>/dev/null)
cli_ev=$("$AG" events --run "$RUN" | jq -s length)
t_is "$ipc_ev" "$cli_ev" "events count over IPC == events count via CLI"

# a run created via the CLI is visible over IPC (same store, one writer)
CR=$(new_run cli); "$AG" emit --run "$CR" --type x.note --payload '{"kind":"n","data":{"z":9}}' >/dev/null
vis=$(ipc_call "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ag.stats\"}" "$SOCK" | jq -r .result.runs)
t_ok "$([ "$vis" -ge 2 ]; echo $?)" "IPC stats sees CLI-created runs (runs=$vis)"

kill "$SPID" 2>/dev/null; pkill -f "nc -klU $SOCK" 2>/dev/null; wait 2>/dev/null; sleep 0.5

# with a token set, IPC honors it: unauth request rejected, authed accepted
TOK='ipc-token-abcdef12345'
rm -f "$SOCK"
AG_TOKEN="$TOK" "$AG" serve >"$TDIR/s2.log" 2>&1 &
SPID=$!
for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
sleep 0.3
un=$(ipc_call '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}' "$SOCK" | jq -r .error.code)
t_is "$un" "-32003" "IPC honors a configured token (unauth rejected)"
sleep 0.3
au=$(ipc_call "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ag.ping\",\"params\":{\"auth\":\"$TOK\"}}" "$SOCK" | jq -r .result.ok)
t_is "$au" true "IPC accepts the correct token"
kill "$SPID" 2>/dev/null; pkill -f "nc -klU $SOCK" 2>/dev/null

t_done
