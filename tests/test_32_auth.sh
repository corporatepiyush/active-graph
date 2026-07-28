#!/usr/bin/env bash
# auth posture: no token on argv, token-file must be 0600, weak tokens refused,
# non-loopback binds need token+consent, the token never appears in logs, and
# repeated bad tokens drop the connection (PLAN §13 test_32 / §12 A07).
# NOTE: every "refused" case fails BEFORE the server binds, so it is checked
# synchronously (no backgrounding) — deterministic even under a loaded CI.
. "$(dirname "$0")/harness.bash"
require_socat
"$AG" init >/dev/null
TOK='a-sufficiently-long-token'

# a token on the command line is refused (it would show up in ps)
"$AG" serve --token "$TOK" >/dev/null 2>&1
t_is $? 2 "--token on argv refused"

# a token file must be exactly mode 0600
tf="$TDIR/tok"; printf '%s' "$TOK" > "$tf"; chmod 644 "$tf"
err=$("$AG" serve --token-file "$tf" 2>&1 >/dev/null)
t_like "$err" "*0600*" "token file not 0600 is refused with a clear error"

# a token shorter than 16 chars is refused (loopback tcp: fails at the length gate)
err=$(AG_TOKEN='short' "$AG" serve --transport tcp --bind 127.0.0.1 2>&1 >/dev/null)
t_like "$err" "*16*" "token shorter than 16 chars refused"

# binding a non-loopback address requires BOTH a token and --allow-remote
err=$(AG_TOKEN="$TOK" "$AG" serve --transport tcp --bind 203.0.113.7 2>&1 >/dev/null)
t_like "$err" "*non-loopback*" "non-loopback bind without --allow-remote refused"
err=$("$AG" serve --transport tcp --bind 203.0.113.7 --allow-remote 2>&1 >/dev/null)
t_like "$err" "*non-loopback*token*" "non-loopback bind without a token refused"

# the token value never appears in the server's logs (poll for readiness, no
# fixed sleeps — robust under load)
SOCK="$AG_DIR/ag.sock"
SECRETTOK='zzz-topsecret-marker-9999'
chmod 600 "$tf"; printf '%s' "$SECRETTOK" > "$tf"
AG_TOKEN="$SECRETTOK" "$AG" serve --token-file "$tf" >"$TDIR/log.out" 2>&1 &
SPID=$!
trap 'kill "$SPID" 2>/dev/null; pkill -f "nc -klU $SOCK" 2>/dev/null; _harness_cleanup' EXIT
for i in $(seq 1 100); do grep -q 'listening on unix:' "$TDIR/log.out" && break; sleep 0.1; done
sleep 0.2
kill "$SPID" 2>/dev/null; pkill -f "nc -klU $SOCK" 2>/dev/null; wait 2>/dev/null
t_ok "$(grep -q "$SECRETTOK" "$TDIR/log.out"; test $? -ne 0; echo $?)" "token value is absent from server logs"

# three bad tokens on one connection drops it (no 4th answer) — pipe-driven
dropped=$(printf '%s\n%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":{"auth":"bad1"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"ag.ping","params":{"auth":"bad2"}}' \
  '{"jsonrpc":"2.0","id":3,"method":"ag.ping","params":{"auth":"bad3"}}' \
  '{"jsonrpc":"2.0","id":4,"method":"ag.ping","params":{"auth":"bad4"}}' \
  | AG_TOKEN="$TOK" "$AG" rpc-child 2>/dev/null | jq -s length)
t_is "$dropped" 3 "connection dropped after 3 bad tokens (4th unanswered)"

t_done
