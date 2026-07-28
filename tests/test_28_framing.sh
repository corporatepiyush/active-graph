#!/usr/bin/env bash
# framing & protocol edges: NUL rejection, notification silence, batch handling,
# blank-line skipping, id echo — the server always answers-or-drops, never
# executes malformed input (PLAN §13 test_28/§10).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null
rpc() { printf '%s\n' "$1" | "$AG" rpc-child 2>/dev/null; }

# a frame carrying the literal 6-char  escape is rejected outright
# (-32600) — it must never reach SQL, where a decoded NUL truncates C strings
NULESC=$(printf '\\u0000')
t_is "$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ag.ping\",\"params\":{\"x\":\"$NULESC\"}}" | jq -r .error.code)" "-32600" "literal backslash-u-0000 escape in frame rejected"

# a notification (no id) produces NO response line, but is still processed
R=$(new_run notif)
out=$(printf '%s\n%s\n' \
  "{\"jsonrpc\":\"2.0\",\"method\":\"ag.emit\",\"params\":{\"run\":\"$R\",\"type\":\"x.note\",\"payload\":{\"kind\":\"n\",\"data\":{\"a\":1}}}}" \
  '{"jsonrpc":"2.0","id":5,"method":"ag.ping"}' | "$AG" rpc-child 2>/dev/null)
t_is "$(echo "$out" | jq -s length)" 1 "notification yields no response (only the ping replies)"
t_is "$(echo "$out" | jq -s '.[0].id')" 5 "the id-bearing request still gets its reply"
t_is "$("$AG" events --run "$R" --type x.note | jq -s length)" 1 "the notification's side effect (emit) DID happen"

# blank / whitespace-only lines between frames are skipped, not errors
multi=$(printf '\n%s\n\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}' \
  '{"jsonrpc":"2.0","id":2,"method":"ag.ping"}' | "$AG" rpc-child 2>/dev/null)
t_is "$(echo "$multi" | jq -s length)" 2 "blank lines skipped; both real frames answered"

# a batch array is answered as an array of responses; a notification in the batch
# is silent (2 responses for 3 requests)
batch='[{"jsonrpc":"2.0","id":1,"method":"ag.ping"},{"jsonrpc":"2.0","method":"ag.ping"},{"jsonrpc":"2.0","id":2,"method":"ag.ping"}]'
b=$(rpc "$batch")
t_is "$(echo "$b" | jq 'type')" '"array"' "batch answered with a JSON array"
t_is "$(echo "$b" | jq 'length')" 2 "batch drops the notification response (2 of 3)"

# id types are echoed faithfully: string and null
t_is "$(rpc '{"jsonrpc":"2.0","id":"abc","method":"ag.ping"}' | jq -r .id)" "abc" "string id echoed"
t_is "$(rpc '{"jsonrpc":"2.0","id":null,"method":"ag.nope"}' | jq -r '.id')" "null" "null id echoed on error"

# wrong protocol version and wrong params type are rejected
t_is "$(rpc '{"jsonrpc":"1.0","id":1,"method":"ag.ping"}' | jq -r .error.code)" "-32600" "jsonrpc != 2.0 rejected"
t_is "$(rpc '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":[1,2]}' | jq -r .error.code)" "-32602" "array params rejected"

t_done
