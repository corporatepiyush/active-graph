#!/usr/bin/env bash
# JSON-RPC 2.0 protocol compliance via rpc-child on stdio (PLAN test_12)
. "$(dirname "$0")/harness.bash"

"$AG" init >/dev/null

rpc() {  # send one or more frames on stdin, print responses
    "$AG" rpc-child 2>/dev/null
}

# ping: result + id echo (integer id)
r=$(printf '{"jsonrpc":"2.0","id":7,"method":"ag.ping"}\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .result.ok)" true "ping returns ok"
t_is "$(printf '%s' "$r" | jq -r .id)" 7 "integer id echoed"
t_is "$(printf '%s' "$r" | jq -r .jsonrpc)" "2.0" "jsonrpc version present"

# string id echoed as string
r=$(printf '{"jsonrpc":"2.0","id":"abc-1","method":"ag.ping"}\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .id)" "abc-1" "string id echoed"

# -32700 parse error
r=$(printf 'this is not json\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32700 "parse error -> -32700"
t_is "$(printf '%s' "$r" | jq -r .id)" null "parse error id is null"

# -32600 invalid request (non-object)
r=$(printf '"just a string"\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32600 "non-object frame -> -32600"

# wrong jsonrpc version
r=$(printf '{"jsonrpc":"1.0","id":1,"method":"ag.ping"}\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32600 "jsonrpc 1.0 -> -32600"

# -32601 method not found
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.nope"}\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32601 "unknown method -> -32601"

# -32602 unknown params named in error
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":{"bogus":1}}\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32602 "unknown param -> -32602"
t_like "$(printf '%s' "$r" | jq -r .error.message)" "*bogus*" "offending param named"

# params as array rejected
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":[1]}\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32602 "positional params -> -32602"

# id as object -> invalid
r=$(printf '{"jsonrpc":"2.0","id":{"x":1},"method":"ag.ping"}\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32600 "object id -> -32600"

# notification: executes but produces NO response frame
r=$(printf '{"jsonrpc":"2.0","method":"ag.ping"}\n{"jsonrpc":"2.0","id":9,"method":"ag.ping"}\n' | rpc)
t_is "$(printf '%s\n' "$r" | jq -s length)" 1 "notification is silent; only id-9 answered"
t_is "$(printf '%s' "$r" | jq -r .id)" 9 "the answered frame is the request"

# batch: array of requests -> array of responses; notification omitted
r=$(printf '[{"jsonrpc":"2.0","id":1,"method":"ag.ping"},{"jsonrpc":"2.0","method":"ag.ping"},{"jsonrpc":"2.0","id":2,"method":"ag.nope"}]\n' | rpc)
t_is "$(printf '%s' "$r" | jq 'length')" 2 "batch: 2 responses (notification omitted)"
t_is "$(printf '%s' "$r" | jq -r '.[1].error.code')" -32601 "batch preserves per-item errors"

# empty batch -> -32600
r=$(printf '[]\n' | rpc)
t_is "$(printf '%s' "$r" | jq -r .error.code)" -32600 "empty batch -> -32600"

# full flow over RPC: run_start -> emit -> events -> run_end
r=$(printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"ag.run_start","params":{"goal":"rpc flow"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"ag.ping"}' | rpc)
RUN=$(printf '%s\n' "$r" | jq -r 'select(.id==1).result.run')
t_like "$RUN" "r*-*" "run_start over RPC"

r=$(printf '{"jsonrpc":"2.0","id":3,"method":"ag.emit","params":{"run":"%s","type":"llm.responded","payload":{"model":"m","text":"t"},"idem":"rpc-1"}}\n' "$RUN" | rpc)
t_is "$(printf '%s' "$r" | jq -r .result.seq)" 2 "emit over RPC returns seq"

r=$(printf '{"jsonrpc":"2.0","id":4,"method":"ag.events","params":{"run":"%s"}}\n' "$RUN" | rpc)
t_is "$(printf '%s' "$r" | jq -r '.result.events | length')" 2 "events over RPC returns array"
t_is "$(printf '%s' "$r" | jq -r '.result.events[1].payload.text')" t "payload intact over RPC"

# events with type filter
r=$(printf '{"jsonrpc":"2.0","id":10,"method":"ag.events","params":{"run":"%s","type":"llm.responded"}}\n' "$RUN" | rpc)
t_is "$(printf '%s' "$r" | jq -r '.result.events | length')" 1 "events type filter over RPC"

# ag.stats over RPC
r=$(printf '{"jsonrpc":"2.0","id":11,"method":"ag.stats"}\n' | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result.events >/dev/null 2>&1; echo $?)" "stats over RPC returns events field"

# ag.fork over RPC
r=$(printf '{"jsonrpc":"2.0","id":12,"method":"ag.fork","params":{"run":"%s","seq":2}}\n' "$RUN" | rpc)
FORK=$(printf '%s' "$r" | jq -r .result.run)
t_like "$FORK" "r*-*" "fork over RPC creates a new run"

# ag.graph over RPC (nodes) — use the forked run's parent before forking status
# Actually, the run was already forked (status=forked), so test graph on the fork child
r=$(printf '{"jsonrpc":"2.0","id":13,"method":"ag.graph","params":{"run":"%s"}}\n' "$FORK" | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result.items >/dev/null 2>&1; echo $?)" "graph over RPC returns items"

# ag.graph edges over RPC
r=$(printf '{"jsonrpc":"2.0","id":14,"method":"ag.graph","params":{"run":"%s","what":"edges"}}\n' "$FORK" | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result.items >/dev/null 2>&1; echo $?)" "graph edges over RPC returns items"

# ag.project over RPC
r=$(printf '{"jsonrpc":"2.0","id":15,"method":"ag.project","params":{"run":"%s"}}\n' "$FORK" | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result >/dev/null 2>&1; echo $?)" "project over RPC succeeds"

# ag.explain, frame_open, frame_close, run_end on a FRESH live run
R2=$(new_run rpc2)
"$AG" emit --run "$R2" --type object.created --payload '{"kind":"doc","data":{"a":1}}' >/dev/null
r=$(printf '{"jsonrpc":"2.0","id":16,"method":"ag.explain","params":{"run":"%s","obj":"doc#1"}}\n' "$R2" | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result >/dev/null 2>&1; echo $?)" "explain over RPC returns result"

# ag.diff over RPC
r=$(printf '{"jsonrpc":"2.0","id":17,"method":"ag.diff","params":{"a":"%s","b":"%s"}}\n' "$R2" "$R2" | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result >/dev/null 2>&1; echo $?)" "diff of run with itself over RPC succeeds"

# ag.frame_open / ag.frame_close over RPC
r=$(printf '{"jsonrpc":"2.0","id":18,"method":"ag.frame_open","params":{"run":"%s"}}\n' "$R2" | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result >/dev/null 2>&1; echo $?)" "frame_open over RPC succeeds"
r=$(printf '{"jsonrpc":"2.0","id":19,"method":"ag.frame_close","params":{"run":"%s","frame":"f1"}}\n' "$R2" | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result >/dev/null 2>&1; echo $?)" "frame_close over RPC succeeds"

# ag.run_end over RPC
r=$(printf '{"jsonrpc":"2.0","id":20,"method":"ag.run_end","params":{"run":"%s","status":"done"}}\n' "$R2" | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result >/dev/null 2>&1; echo $?)" "run_end over RPC succeeds"

# ag.wait over RPC with short timeout
r=$(printf '{"jsonrpc":"2.0","id":21,"method":"ag.wait","params":{"run":"%s","timeout_ms":100}}\n' "$R2" | rpc)
t_ok "$(printf '%s' "$r" | jq -e .result >/dev/null 2>&1; echo $?)" "wait over RPC with short timeout returns"
t_done
