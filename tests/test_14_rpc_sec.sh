#!/usr/bin/env bash
# RPC security: token enforcement, oversize/garbage frames answered-or-dropped
# without crashing, and the connection surviving bad input (PLAN §13 test_14).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null
TOK='super-secret-token-1234'
# drive the stdio dispatcher directly (the documented test entry point)
rpc()      { printf '%s\n' "$1" | "$AG" rpc-child 2>/dev/null; }
rpc_tok()  { printf '%s\n' "$1" | AG_TOKEN="$TOK" "$AG" rpc-child 2>/dev/null; }

# no token configured: ping works without any auth field
t_is "$(rpc '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}' | jq -r .result.ok)" true "no-token server answers ping"

# token configured: request WITHOUT a valid auth is rejected -32003
r=$(rpc_tok '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}')
t_is "$(echo "$r" | jq -r .error.code)" "-32003" "missing auth -> unauthorized"
r=$(rpc_tok '{"jsonrpc":"2.0","id":2,"method":"ag.ping","params":{"auth":"wrong"}}')
t_is "$(echo "$r" | jq -r .error.code)" "-32003" "wrong auth -> unauthorized"
r=$(rpc_tok "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ag.ping\",\"params\":{\"auth\":\"$TOK\"}}")
t_is "$(echo "$r" | jq -r .result.ok)" true "correct auth -> authorized"

# three bad tokens on one connection -> the connection is dropped; a 4th frame
# after the limit is NOT answered
multi=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":{"auth":"x"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"ag.ping","params":{"auth":"y"}}' \
  '{"jsonrpc":"2.0","id":3,"method":"ag.ping","params":{"auth":"z"}}' \
  '{"jsonrpc":"2.0","id":4,"method":"ag.ping","params":{"auth":"w"}}' | AG_TOKEN="$TOK" "$AG" rpc-child 2>/dev/null)
t_is "$(echo "$multi" | jq -s length)" 3 "connection dropped after 3 auth failures (4th unanswered)"

# oversize frame: with a tiny cap, an over-cap line is chopped into invalid JSON
# (parse errors) but the server keeps going and answers a following valid frame
big=$(printf 'A%.0s' $(seq 1 500))
two=$(printf '{"x":"%s"}\n{"jsonrpc":"2.0","id":9,"method":"ag.ping"}\n' "$big" | AG_MAX_FRAME=100 "$AG" rpc-child 2>/dev/null)
t_ok "$(echo "$two" | jq -s 'any(.[]; .error.code == -32700 or .error.code == -32600)' | grep -q true; echo $?)" "over-cap frame answered with an error, not a crash"
t_is "$(echo "$two" | jq -s '[.[] | select(.result.ok==true)] | length')" 1 "server survives the oversize frame and answers the next valid one"

# a garbage (non-JSON) frame -> parse error, connection survives
gj=$(printf '%s\n%s\n' 'not json at all' '{"jsonrpc":"2.0","id":7,"method":"ag.ping"}' | "$AG" rpc-child 2>/dev/null)
t_is "$(echo "$gj" | jq -s '.[0].error.code')" "-32700" "non-JSON frame -> parse error"
t_is "$(echo "$gj" | jq -s '.[1].result.ok')" true "connection survives a garbage frame"

# an unknown method is a clean -32601, not a crash
t_is "$(rpc '{"jsonrpc":"2.0","id":1,"method":"ag.nope"}' | jq -r .error.code)" "-32601" "unknown method -> method not found"

t_done
