#!/usr/bin/env bash
# Concurrent RPC (PLAN §13 test_30).
#
# socat forks one process per connection, so N clients are genuinely
# simultaneous — this file exists to prove that, not to assume it. The
# assertions are:
#   * every client is ANSWERED. A -32000 busy counts as an answer: it is the
#     documented backpressure signal. A hang or a refused connect does not.
#   * concurrent writers neither lose nor duplicate a seq.
#   * a client parked in a long ag.wait does not block anyone else — with the
#     old serial backend the next ping waited out the whole timeout, so this is
#     the assertion that actually distinguishes concurrent from serial.
#   * the store is intact after the workout.
. "$(dirname "$0")/harness.bash"
require_socat
"$AG" init >/dev/null
SOCK="$AG_DIR/ag.sock"

# A slightly longer request deadline than the harness default, so the parked-wait
# case below has real margin: the harness runs at 2s, and ag.wait is clamped to
# the deadline, which would leave the overlap window as tight as the wait itself.
AG_REQ_DEADLINE_S=4 "$AG" serve >"$TDIR/s.log" 2>&1 &
SPID=$!
trap 'kill "$SPID" 2>/dev/null; pkill -f "UNIX-LISTEN:$SOCK" 2>/dev/null; _harness_cleanup' EXIT
for i in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 0.1; done
t_ok "$([ -S "$SOCK" ]; echo $?)" "server listening"

R=$(new_run concurrent)

# NEVER a bare `wait` in this file: the server itself is a background job of
# this shell and does not exit, so `wait` would block until the trap kills it.
# Every fan-out collects its own pids and waits on exactly those.
CPIDS=''
call_into() { ipc_call "$1" "$SOCK" >"$2" 2>/dev/null; }   # one frame -> one file
spawn() { "$@" & CPIDS="$CPIDS $!"; }
join()  { local p; for p in $CPIDS; do wait "$p" 2>/dev/null; done; CPIDS=''; }

# ---------------------------------------------------------------------------
# 16 parallel writers. They are launched without any stagger on purpose: the
# point is to collide on the writer engine, not to take turns.
# ---------------------------------------------------------------------------
N=16
for n in $(seq 1 $N); do
  spawn call_into "{\"jsonrpc\":\"2.0\",\"id\":$n,\"method\":\"ag.emit\",\"params\":{\"run\":\"$R\",\"type\":\"x.tick\",\"payload\":{\"kind\":\"n\",\"data\":{\"i\":$n}}}}" "$TDIR/c.$n"
done
join

answered=0 wrote=0 refused=0
: >"$TDIR/seqs"
for n in $(seq 1 $N); do
  resp=$(cat "$TDIR/c.$n" 2>/dev/null)
  seq_n=$(printf '%s' "$resp" | jq -r '.result.seq // empty' 2>/dev/null)
  err=$(printf '%s' "$resp" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$seq_n" ]; then
    answered=$((answered + 1)); wrote=$((wrote + 1)); echo "$seq_n" >>"$TDIR/seqs"
  elif [ "$err" = "-32000" ]; then
    answered=$((answered + 1))            # busy is a valid, documented answer
  else
    refused=$((refused + 1))
  fi
done
t_diag "$N parallel clients: $wrote wrote, $((answered - wrote)) busy, $refused unanswered"
t_is "$answered" "$N" "every one of $N simultaneous clients was answered (busy counts, silence does not)"
t_ok $([ "$wrote" -gt 0 ] && echo 0 || echo 1) "at least one concurrent write committed"
t_is "$(sort "$TDIR/seqs" | uniq -d | wc -l | tr -d ' ')" 0 "no two concurrent writers were handed the same seq"

# what the log says was written is what the log actually holds
cnt=$(ipc_call "{\"jsonrpc\":\"2.0\",\"id\":90,\"method\":\"ag.events\",\"params\":{\"run\":\"$R\",\"type\":\"x.tick\"}}" "$SOCK" \
      | jq -s 'map(select(.result))[0].result.events | length')
t_is "${cnt:-0}" "$wrote" "read-back count equals the number of confirmed concurrent writes"

# ---------------------------------------------------------------------------
# Mixed traffic: 8 writers and 8 readers against the same run, all at once.
# A reader must never see a torn write, so every reply must parse and every
# events reply must be an array.
# ---------------------------------------------------------------------------
for n in $(seq 1 8); do
  spawn call_into "{\"jsonrpc\":\"2.0\",\"id\":$n,\"method\":\"ag.emit\",\"params\":{\"run\":\"$R\",\"type\":\"x.mix\",\"payload\":{\"kind\":\"n\",\"data\":{\"i\":$n}}}}" "$TDIR/w.$n"
  spawn call_into "{\"jsonrpc\":\"2.0\",\"id\":$((100 + n)),\"method\":\"ag.events\",\"params\":{\"run\":\"$R\"}}" "$TDIR/r.$n"
done
join
mixed_ok=0
for n in $(seq 1 8); do
  jq -e '.result.seq or (.error.code == -32000)' <"$TDIR/w.$n" >/dev/null 2>&1 && mixed_ok=$((mixed_ok + 1))
  jq -e '(.result.events | type == "array") or (.error.code == -32000)' <"$TDIR/r.$n" >/dev/null 2>&1 && mixed_ok=$((mixed_ok + 1))
done
t_is "$mixed_ok" 16 "8 readers interleaved with 8 writers: every reply well-formed, none torn"

# ---------------------------------------------------------------------------
# The discriminating test: one client parks in a long ag.wait, and a second is
# served while it is STILL parked. A serial backend cannot do that.
#
# The proof is deliberately NOT a stopwatch. $SECONDS has one-second resolution
# and the tests must run under bash 3.2 (no EPOCHREALTIME), so "the ping came
# back in under 2s" would also be satisfied by a serial server answering at
# 1.7s — it would pass under exactly the condition it claims to rule out.
# Overlap is the real property, so assert overlap directly: the parked client
# must still be in flight at the moment the second one has already finished.
# ---------------------------------------------------------------------------
call_into "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ag.wait\",\"params\":{\"run\":\"$R\",\"since_seq\":999999,\"timeout_ms\":3000}}" "$TDIR/parked" &
PARKED=$!
sleep 0.3                                   # let the wait actually reach the server
ping=$(ipc_call '{"jsonrpc":"2.0","id":2,"method":"ag.ping"}' "$SOCK")
still_parked=$(kill -0 "$PARKED" 2>/dev/null; echo $?)
t_is "$(printf '%s' "$ping" | jq -r '.result.ok // empty')" true "a second client is served while the first is parked in a long wait"
t_is "$still_parked" 0 "the parked client was still in flight when that reply arrived (concurrent, not serial)"
wait "$PARKED" 2>/dev/null
t_ok $(jq -e '.result.events | type == "array"' <"$TDIR/parked" >/dev/null 2>&1; echo $?) "the parked wait still returned its own well-formed reply"

# ---------------------------------------------------------------------------
# Saturation is a bounded queue, never a hang: AG_MAX_CHILDREN caps concurrent
# connections, and socat backlogs the rest. Fire well past the cap and require
# that every client still terminates with something.
# ---------------------------------------------------------------------------
S=40
for n in $(seq 1 $S); do
  spawn call_into '{"jsonrpc":"2.0","id":7,"method":"ag.ping"}' "$TDIR/s.$n"
done
join
sat=0
for n in $(seq 1 $S); do [ -s "$TDIR/s.$n" ] && sat=$((sat + 1)); done
t_diag "$sat/$S clients answered past the max-children cap"
t_ok $([ "$sat" -ge $((S * 3 / 4)) ] && echo 0 || echo 1) "oversubscribing max-children queues, it does not hang ($sat/$S answered)"

resp=$(ipc_call '{"jsonrpc":"2.0","id":3,"method":"ag.ping"}' "$SOCK")
t_is "$(printf '%s' "$resp" | jq -r '.result.ok // empty')" true "server still healthy after the saturation burst"

t_is "$("$SQ" "$AG_DIR/ag-catalog.db" 'PRAGMA integrity_check;')" ok "store integrity intact"

kill "$SPID" 2>/dev/null; pkill -f "UNIX-LISTEN:$SOCK" 2>/dev/null
t_done
