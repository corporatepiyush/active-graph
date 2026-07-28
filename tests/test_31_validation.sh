#!/usr/bin/env bash
# strict input validation over RPC: fail-closed everywhere (PLAN test_31)
. "$(dirname "$0")/harness.bash"

"$AG" init >/dev/null
rpc() { "$AG" rpc-child 2>/dev/null; }

code_of() { printf '%s' "$1" | jq -r .error.code; }

# emit without run
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.emit","params":{"type":"x.a","payload":{}}}\n' | rpc)
t_is "$(code_of "$r")" -32602 "emit missing run -> -32602"

# malformed run id
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.emit","params":{"run":"../etc/passwd","type":"x.a","payload":{}}}\n' | rpc)
t_is "$(code_of "$r")" -32602 "path-traversal-shaped run id rejected"

# unknown run (well-formed id)
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.emit","params":{"run":"r1234567890-abcd","type":"x.a","payload":{}}}\n' | rpc)
t_is "$(code_of "$r")" -32001 "unknown run -> -32001"

# events limit out of range
RUN=$(new_run vtest)
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.events","params":{"run":"%s","limit":999999}}\n' "$RUN" | rpc)
t_is "$(code_of "$r")" -32602 "limit beyond max rejected"
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.events","params":{"run":"%s","limit":0}}\n' "$RUN" | rpc)
t_is "$(code_of "$r")" -32602 "limit 0 rejected"

# non-integer since_seq
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.events","params":{"run":"%s","since_seq":"abc"}}\n' "$RUN" | rpc)
t_is "$(code_of "$r")" -32602 "non-integer since_seq rejected"

# actor pattern
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.emit","params":{"run":"%s","type":"x.a","payload":{},"actor":"BAD ACTOR"}}\n' "$RUN" | rpc)
t_is "$(code_of "$r")" -32602 "bad actor pattern rejected"

# idem pattern
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.emit","params":{"run":"%s","type":"x.a","payload":{},"idem":"no spaces!"}}\n' "$RUN" | rpc)
t_is "$(code_of "$r")" -32602 "bad idem pattern rejected"

# payload not an object
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.emit","params":{"run":"%s","type":"x.a","payload":[1,2]}}\n' "$RUN" | rpc)
t_is "$(code_of "$r")" -32602 "array payload rejected"

# run_end bad status
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.run_end","params":{"run":"%s","status":"exploded"}}\n' "$RUN" | rpc)
t_is "$(code_of "$r")" -32602 "invalid status rejected"

# NUL escape anywhere in frame
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":{"auth":"a\\u0000b"}}\n' | rpc)
t_is "$(code_of "$r")" -32600 "frame containing \\u0000 rejected before parse"

# unknown params named in error
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":{"bogus":true}}\n' | rpc)
t_is "$(code_of "$r")" -32602 "unknown param on ag.ping named in error"
t_like "$(printf '%s' "$r" | jq -r .error.message)" "*bogus*" "error message names the unknown param"

# wrong param type: string where object expected (params must be object or absent)
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":"bad"}\n' | rpc)
t_is "$(code_of "$r")" -32602 "string params rejected"

# id-as-object: should be rejected
r=$(printf '{"jsonrpc":"2.0","id":{"foo":1},"method":"ag.ping"}\n' | rpc)
t_is "$(code_of "$r")" -32600 "object id rejected"

# timeout_ms out of range on ag.wait — must not crash
RUN2=$(new_run vwait)
r=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.wait","params":{"run":"%s","timeout_ms":999999}}\n' "$RUN2" | rpc)
rc=$(code_of "$r")
t_ok "$([[ $rc == -32602 || $rc == -32004 ]]; echo $?)" "timeout_ms out of range answered with error (no crash)"

# positional params (array) already tested above (test 12)

# generative fuzz: FUZZN malformed frames; server must answer or stay silent,
# never crash, and the store must stay intact
for i in $(seq 1 "$FUZZN"); do
    head -c $((RANDOM % 200 + 1)) /dev/urandom | LC_ALL=C tr -d '\000\n'
    echo
done | rpc >/dev/null 2>&1
t_ok $? "$FUZZN-frame fuzz: dispatcher survives"
"$AG" init >/dev/null 2>&1
t_ok $? "store schema still verifies after fuzz"
t_done
