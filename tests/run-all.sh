#!/usr/bin/env bash
# tests/run-all.sh — run every test file, aggregate results.
#
# CONCURRENCY IS BOUNDED ON PURPOSE. Every test file spawns sqlite engines, and
# the server tests additionally spawn socat plus one child per connection, so
# launching all ~46 at once oversubscribes the machine by an order of magnitude.
# Under that load a case that normally takes 200 ms blows the 5 s per-case
# budget, and the suite fails in parallel while passing serially — flakiness,
# which is worse than slowness. Bounding the pool keeps every test on a
# responsive machine, and is usually FASTER overall because nothing thrashes.
#
#   JOBS=n bash run-all.sh    override the pool size (default: half the cores)
cd "$(dirname "$0")" || exit 1
mkdir -p .out
rm -f .out/*.log 2>/dev/null

if [ -z "${JOBS:-}" ]; then
    cores=$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) )
    JOBS=$(( cores / 2 ))
    [ "$JOBS" -lt 2 ] && JOBS=2
    [ "$JOBS" -gt 8 ] && JOBS=8
fi
echo "# JOBS=$JOBS (bounded; see comment above)"

declare -a names=() pids=()
running=0
for t in test_*.sh; do
    bash "$t" > ".out/$t.log" 2>&1 &
    pids+=("$!"); names+=("$t")
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
        wait -n 2>/dev/null || wait "${pids[0]}" 2>/dev/null
        running=$((running - 1))
    fi
done

fails=0
i=0
for pid in "${pids[@]}"; do
    name=${names[$i]}; i=$((i+1))
    if wait "$pid"; then
        printf '%-32s PASS\n' "$name"
    else
        printf '%-32s FAIL\n' "$name"
        sed 's/^/    /' ".out/$name.log"
        fails=$((fails+1))
    fi
done
echo "--------------------------------"
if [ "$fails" -eq 0 ]; then
    echo "all ${#names[@]} test files passed"
else
    echo "$fails/${#names[@]} test files FAILED"
    exit 1
fi
