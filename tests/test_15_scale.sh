#!/usr/bin/env bash
# scale smoke: a few thousand events must append, scan, and probe within a sane
# envelope and stay correct. Timings are TAP diagnostics (visible in history, not
# hard gates); correctness is asserted (PLAN §13 test_15 / D1-D4).
# NOTE on N: ag_emit_batch does ~13 synchronous coprocess round-trips PER event
# (validate/intern/insert over FIFOs), so real append throughput is ~40 ev/s and
# the paper's 100k target is a multi-minute SOAK, not a CI unit. Default to a
# CI-sized N and expose AG_SCALE_N to drive the full 100k soak on demand.
. "$(dirname "$0")/harness.bash"
: "${AG_SCALE_N:=1000}"   # CI-sized; AG_SCALE_N=100000 for the full soak
"$AG" init >/dev/null

R=$(new_run scale)

# bulk append via batched single-txn inserts (chunks keep the NDJSON build cheap)
chunk=5000; appended=0
t0=$(date +%s)
i=0
while [ "$i" -lt "$AG_SCALE_N" ]; do
  end=$(( i + chunk )); [ "$end" -gt "$AG_SCALE_N" ] && end=$AG_SCALE_N
  c=$(awk -v a="$((i+1))" -v b="$end" 'BEGIN{for(k=a;k<=b;k++) printf "{\"type\":\"x.tick\",\"payload\":{\"i\":%d}}\n", k}' \
      | "$AG" emit-batch --run "$R" | jq -r '.count')
  appended=$(( appended + c ))
  i=$end
done
tapp=$(( $(date +%s) - t0 ))
t_is "$appended" "$AG_SCALE_N" "appended all $AG_SCALE_N events"
t_diag "append: $AG_SCALE_N events in ${tapp}s (~$(( AG_SCALE_N / (tapp>0?tapp:1) ))/s)"

# total event count == N + run.started, contiguous, no dupes
tot=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE rid=$(rid_of "$R");")
t_is "$tot" "$(( AG_SCALE_N + 1 ))" "segment holds N+1 rows (events + run.started)"
mm=$("$SQ" "$AG_DIR/seg-000001.db" "SELECT min(seq)||'/'||max(seq)||'/'||count(DISTINCT seq) FROM run_events WHERE rid=$(rid_of "$R");")
t_is "$mm" "1/$(( AG_SCALE_N + 1 ))/$(( AG_SCALE_N + 1 ))" "seqs are contiguous 1..N+1 with no duplicates"

# bytes/row envelope (D-guard): the WAL-inclusive logical size stays bounded
bytes=$("$SQ" "$AG_DIR/seg-000001.db" 'SELECT page_count*page_size FROM pragma_page_count, pragma_page_size;')
per=$(( bytes / (AG_SCALE_N + 1) ))
t_diag "segment size ${bytes}B (~${per}B/row)"
t_ok "$([ "$per" -lt 4096 ]; echo $?)" "bytes/row within envelope (~${per}B, < 4096)"

# a cache probe is fast even at scale: emit an llm response, look it up
hx=$("$AG" emit --run "$R" --type llm.responded --payload '{"model":"m","text":"scaleprobe"}' | jq -r .hash)
tp=$(date +%s%N 2>/dev/null || echo 0)
hit=$("$AG" cache-lookup "$hx" | jq -r .payload.text)
t_is "$hit" "scaleprobe" "content-addressed cache hit at scale"

# a replay/verify scan over the whole run passes
t0=$(date +%s); "$AG" verify --run "$R" >/dev/null 2>&1; vr=$?; tver=$(( $(date +%s) - t0 ))
t_is "$vr" 0 "verify scans the full run cleanly"
t_diag "verify scan of $AG_SCALE_N events in ${tver}s"

# stats aggregates the whole store without choking
s=$("$AG" stats)
t_is "$(echo "$s" | jq -r .events)" "$(( AG_SCALE_N + 2 ))" "stats counts every event (N + run.started + llm.responded)"

# integrity holds after the whole workout
t_is "$("$SQ" "$AG_DIR/seg-000001.db" 'PRAGMA integrity_check;')" ok "segment integrity ok at scale"

t_done
