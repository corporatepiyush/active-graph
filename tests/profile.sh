#!/usr/bin/env bash
# tests/profile.sh — exercise EVERY command flow and EVERY documented option
# against a seeded store, timing each invocation.
#
# This is not a test file (run-all.sh globs test_*.sh, so it is not picked up).
# It answers two questions the test suite deliberately does not:
#
#   1. COVERAGE — does every option actually do something, and does it fail
#      the way it says it does? A flag that is parsed but ignored, or that
#      returns rc 0 with empty output, passes every test that never names it.
#   2. COST — where does the wall clock go? Each invocation is a fresh process
#      plus an sqlite engine handshake, so the interesting number is not the
#      total but the MARGINAL cost over `version` (which answers before the
#      store is even opened).
#
# Output: NDJSON of every probe to $OUT/probes.ndjson plus a ranked report.
#   bash tests/profile.sh              # default scale
#   AG_PROF_N=2000 bash tests/profile.sh
set -o pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AG="$ROOT/active-graph.sh"
: "${AG_PROF_N:=300}"      # events seeded into the big run
OUT=${AG_PROF_OUT:-$ROOT/tests/.out/profile}
mkdir -p "$OUT"
: > "$OUT/probes.ndjson"

TDIR=$(mktemp -d "${TMPDIR:-/tmp}/agprof.XXXXXXXX")
export AG_DIR="$TDIR/store"
export AG_REQ_DEADLINE_S=5
trap 'rm -rf "$TDIR"' EXIT

N_PROBE=0 N_ANOM=0
# p <expect:ok|err> <label> -- cmd...   (stdin comes from $PSTDIN if set)
p() {
    local expect=$1 label=$2; shift 3
    local t0=${EPOCHREALTIME/./} rc out err
    err=$("${@}" 2>&1 >"$OUT/last.out" ); rc=$?
    local t1=${EPOCHREALTIME/./}
    local us=$(( t1 - t0 ))
    out=$(wc -c <"$OUT/last.out" | tr -d ' ')
    N_PROBE=$((N_PROBE+1))
    local anom=''
    case $expect in
        ok)  (( rc == 0 )) || anom="expected success, rc=$rc" ;;
        err) (( rc != 0 )) || anom="expected failure, rc=0" ;;
    esac
    [[ -z $anom && $expect == ok && -n ${PNONEMPTY:-} && $out -eq 0 ]] \
        && anom="rc=0 but produced no output"
    [[ -n $anom ]] && { N_ANOM=$((N_ANOM+1)); printf '  !! %-38s %s\n' "$label" "$anom" >&2
                        [[ -n $err ]] && printf '     err: %.200s\n' "$err" >&2; }
    printf '{"label":%s,"cmd":%s,"rc":%d,"us":%d,"out_bytes":%d,"expect":"%s","anom":%s,"err":%s}\n' \
        "$(jq -Rn --arg v "$label" '$v')" \
        "$(jq -Rn --arg v "$*" '$v')" \
        "$rc" "$us" "$out" "$expect" \
        "$(jq -Rn --arg v "$anom" '$v')" \
        "$(jq -Rn --arg v "${err:0:300}" '$v')" >> "$OUT/probes.ndjson"
    unset PNONEMPTY
    return 0
}
# pin <expect> <label> <stdin-data> -- cmd...
pin() {
    local expect=$1 label=$2 data=$3; shift 3
    printf '%s' "$data" > "$OUT/stdin.tmp"
    p "$expect" "$label" "$@" < "$OUT/stdin.tmp"
}
say() { printf '\n### %s\n' "$*" >&2; }

# ---------------------------------------------------------------- seed -------
say "seed (N=$AG_PROF_N)"
"$AG" init >/dev/null || { echo "init failed" >&2; exit 1; }
BIG=$("$AG" run-start --goal 'profile big run' --tags '["prof","big"]' | jq -r .run)
SMALL=$("$AG" run-start --goal 'profile small run' | jq -r .run)

# one wide, realistic run: tool calls with ctx cost/token fields, blobs over the
# 512 B offload threshold, and a chain of caused-by links.
FILLER=$(printf 'x%.0s' $(seq 1 600))
seed_ndjson() {  # $1 = count
    local i
    for (( i=1; i<=$1; i++ )); do
        printf '{"type":"tool.requested","actor":"agent","payload":{"tool":"search","q":"item-%d","filler":"%s"},"ctx":{"model":"claude-opus-5","tokens_in":%d,"tokens_out":%d,"cost_usd":0.0%03d,"dur_ms":%d}}\n' \
            "$i" "$FILLER" "$((100+i))" "$((50+i))" "$((i%999))" "$((10+i%90))"
        printf '{"type":"tool.responded","actor":"tool","payload":{"ok":true,"n":%d}}\n' "$i"
    done
}
seed_ndjson "$AG_PROF_N" > "$TDIR/seed.ndjson"
seed_ndjson 20          > "$TDIR/seed-small.ndjson"

t0=${EPOCHREALTIME/./}
"$AG" emit-batch --run "$BIG" < "$TDIR/seed.ndjson" >/dev/null
t1=${EPOCHREALTIME/./}
BATCH_US=$(( t1 - t0 )); BATCH_EV=$(( AG_PROF_N * 2 ))
printf '# batch: %d events in %d ms = %d us/event (%d ev/s)\n' \
    "$BATCH_EV" "$((BATCH_US/1000))" "$((BATCH_US/BATCH_EV))" \
    "$(( BATCH_EV * 1000000 / BATCH_US ))" >&2
"$AG" emit-batch --run "$SMALL" < "$TDIR/seed-small.ndjson" >/dev/null

# objects, so graph/explain/diff/project have something to chew on
for i in 1 2 3; do
    "$AG" emit --run "$BIG"   --type object.created --payload "{\"kind\":\"doc\",\"title\":\"t$i\"}" >/dev/null
    "$AG" emit --run "$SMALL" --type object.created --payload "{\"kind\":\"doc\",\"title\":\"s$i\"}" >/dev/null
done
OBJ=doc#1
"$AG" emit --run "$BIG" --type object.updated \
    --payload "{\"id\":\"$OBJ\",\"patch\":{\"title\":\"t1b\"}}" >/dev/null
"$AG" emit --run "$BIG" --type relation.created \
    --payload "{\"src\":\"$OBJ\",\"kind\":\"cites\",\"dst\":\"doc#2\"}" >/dev/null
FORKED=$("$AG" fork "$BIG" 10 | jq -r .run)
PURGED=$("$AG" run-start --goal 'to be purged' | jq -r .run)
"$AG" emit --run "$PURGED" --type x.note --payload '{"a":1}' >/dev/null
"$AG" purge --run "$PURGED" >/dev/null
ENDED=$("$AG" run-start --goal 'ended' | jq -r .run)
"$AG" run-end --run "$ENDED" --status done >/dev/null
CACHE_HASH=$("$AG" events --run "$BIG" --limit 1 | jq -r '.payload_hash // empty')
printf '# runs: BIG=%s SMALL=%s FORK=%s PURGED=%s ENDED=%s\n' \
    "$BIG" "$SMALL" "$FORKED" "$PURGED" "$ENDED" >&2

# ------------------------------------------------------------- baseline ------
say 'baseline / help surface'
p ok  'version'                       -- "$AG" version
p ok  'help'                          -- "$AG" help
p ok  'help emit'                     -- "$AG" help emit
p ok  'help event-types'              -- "$AG" help event-types
p ok  'help patterns'                 -- "$AG" help patterns
p ok  'help rpc'                      -- "$AG" help rpc
p ok  'help exit-codes'               -- "$AG" help exit-codes
p ok  'help env'                      -- "$AG" help env
p ok  'help files'                    -- "$AG" help files
p ok  'emit --help'                   -- "$AG" emit --help
p ok  'init (idempotent reopen)'      -- "$AG" init
p err 'unknown command'               -- "$AG" no-such-command
p err 'bare invocation'               -- "$AG"

# ------------------------------------------------------------- lifecycle -----
say 'run lifecycle'
p ok 'run-start bare'                 -- "$AG" run-start
p ok 'run-start --goal'               -- "$AG" run-start --goal 'g'
p ok 'run-start --goal --tags'        -- "$AG" run-start --goal 'g' --tags '["a","b"]'
R1=$("$AG" run-start --goal parent | jq -r .run)
"$AG" emit --run "$R1" --type x.note --payload '{"n":1}' >/dev/null
"$AG" emit --run "$R1" --type x.note --payload '{"n":2}' >/dev/null
p ok 'run-start --parent --at-seq'    -- "$AG" run-start --parent "$R1" --at-seq 1
p ok 'run-start --parent --close-parent' -- "$AG" run-start --parent "$R1" --at-seq 1 --close-parent
p err 'run-start --tags not-json'     -- "$AG" run-start --tags 'not json'
p err 'run-start --at-seq no parent'  -- "$AG" run-start --at-seq 1
p err 'run-start --parent missing'    -- "$AG" run-start --parent 'r_nope' --at-seq 1
p err 'run-start --goal (no value)'   -- "$AG" run-start --goal
p err 'emit --type eats next flag'    -- "$AG" emit --run "$SMALL" --type --payload '{"a":1}'
p err 'events --limit eats next flag' -- "$AG" events --run "$SMALL" --limit --type x.note

R2=$("$AG" run-start --goal ops | jq -r .run)
p ok  'emit minimal'                  -- "$AG" emit --run "$R2" --type x.note --payload '{"a":1}'
p ok  'emit --actor'                  -- "$AG" emit --run "$R2" --type x.note --payload '{"a":2}' --actor bob
p ok  'emit --ctx'                    -- "$AG" emit --run "$R2" --type x.note --payload '{"a":3}' --ctx '{"cost_usd":0.5,"tokens_in":10,"tokens_out":5,"dur_ms":7}'
p ok  'emit --caused-by'              -- "$AG" emit --run "$R2" --type x.note --payload '{"a":4}' --caused-by 1
p ok  'emit --idem (first)'           -- "$AG" emit --run "$R2" --type x.note --payload '{"a":5}' --idem k1
p ok  'emit --idem (replay)'          -- "$AG" emit --run "$R2" --type x.note --payload '{"a":5}' --idem k1
printf '{"a":6}' > "$TDIR/pl.json"
p ok  'emit --payload@FILE'           -- "$AG" emit --run "$R2" --type x.note --payload@"$TDIR/pl.json"
pin ok 'emit --payload - (stdin)' '{"a":7}' -- "$AG" emit --run "$R2" --type x.note --payload -
head -c 600 /dev/zero | tr '\0' y > "$TDIR/blob.txt"
p ok  'emit blob-offload (>512B)'     -- "$AG" emit --run "$R2" --type x.note --payload "{\"big\":\"$(cat "$TDIR/blob.txt")\"}"
p err 'emit missing --type'           -- "$AG" emit --run "$R2" --payload '{}'
p err 'emit missing --run'            -- "$AG" emit --type x.note --payload '{}'
p err 'emit bad json payload'         -- "$AG" emit --run "$R2" --type x.note --payload '{oops'
p err 'emit reserved type run_started' -- "$AG" emit --run "$R2" --type run.started --payload '{}'
p err 'emit unknown run'              -- "$AG" emit --run 'r_00000000000000000000000000' --type x.note --payload '{}'
p err 'emit --caused-by non-numeric'  -- "$AG" emit --run "$R2" --type x.note --payload '{}' --caused-by abc
p err 'emit --ctx not-json'           -- "$AG" emit --run "$R2" --type x.note --payload '{}' --ctx 'x'
p err 'emit --payload@ missing file'  -- "$AG" emit --run "$R2" --type x.note --payload@/nope/nope
p err 'emit into ended run'           -- "$AG" emit --run "$ENDED" --type x.note --payload '{}'
p err 'emit into purged run'          -- "$AG" emit --run "$PURGED" --type x.note --payload '{}'

pin ok  'emit-batch 20'  "$(cat "$TDIR/seed-small.ndjson")" -- "$AG" emit-batch --run "$R2"
pin err 'emit-batch bad line' '{"type":"x.note","payload":{}}
{oops}' -- "$AG" emit-batch --run "$R2"
pin err 'emit-batch reserved type' '{"type":"run.ended","payload":{}}' -- "$AG" emit-batch --run "$R2"
pin err 'emit-batch empty stdin' '' -- "$AG" emit-batch --run "$R2"
# regression: a stream whose last line has no newline used to lose that event
# silently (rc 0, count one short). Both events must land.
NLRUN=$("$AG" run-start --goal 'no trailing newline' | jq -r .run)
pin ok 'emit-batch no trailing NL' '{"type":"x.a","payload":{}}
{"type":"x.b","payload":{}}' -- "$AG" emit-batch --run "$NLRUN"
p ok 'emit-batch NL: both events landed' -- \
    bash -c '[ "$("'"$AG"'" events --run "'"$NLRUN"'" --type x.b | wc -l | tr -d " ")" = 1 ]'
p err 'emit-batch missing --run'      -- "$AG" emit-batch < /dev/null

p ok 'run-end'                        -- "$AG" run-end --run "$R2"
RFAIL=$("$AG" run-start --goal 'will fail' | jq -r .run)
p ok 'run-end --status failed'        -- "$AG" run-end --run "$RFAIL" --status failed
p err 'run-end bad status'            -- "$AG" run-end --run "$SMALL" --status sideways
p err 'run-end twice'                 -- "$AG" run-end --run "$R2"

# --------------------------------------------------------------- reads -------
say 'reads (against N='"$BATCH_EV"' events)'
PNONEMPTY=1 p ok 'events (full run)'        -- "$AG" events --run "$BIG"
PNONEMPTY=1 p ok 'events --limit 10'        -- "$AG" events --run "$BIG" --limit 10
PNONEMPTY=1 p ok 'events --type'            -- "$AG" events --run "$BIG" --type tool.requested
PNONEMPTY=1 p ok 'events --since'           -- "$AG" events --run "$BIG" --since 100
PNONEMPTY=1 p ok 'events --type --since --limit' -- "$AG" events --run "$BIG" --type tool.requested --since 50 --limit 25
p ok  'events (small run)'            -- "$AG" events --run "$SMALL"
p ok  'events (forked, lineage)'      -- "$AG" events --run "$FORKED"
p err 'events unknown run'            -- "$AG" events --run 'r_00000000000000000000000000'
p err 'events purged run'             -- "$AG" events --run "$PURGED"
p err 'events --limit negative'       -- "$AG" events --run "$BIG" --limit -5
p err 'events --since non-numeric'    -- "$AG" events --run "$BIG" --since abc

PNONEMPTY=1 p ok 'verify'             -- "$AG" verify --run "$BIG"
PNONEMPTY=1 p ok 'verify --chain'     -- "$AG" verify --run "$BIG" --chain
p ok 'verify (fork)'                  -- "$AG" verify --run "$FORKED" --chain
p err 'verify purged'                 -- "$AG" verify --run "$PURGED"

PNONEMPTY=1 p ok 'stats'              -- "$AG" stats
PNONEMPTY=1 p ok 'insights'           -- "$AG" insights
PNONEMPTY=1 p ok 'insights --run'     -- "$AG" insights --run "$BIG"
PNONEMPTY=1 p ok 'insights --limit 5' -- "$AG" insights --limit 5
p err 'insights --limit garbage'      -- "$AG" insights --limit 'x; DROP TABLE runs'

PNONEMPTY=1 p ok 'scan count'         -- "$AG" scan 'SELECT count(*) FROM run_events'
PNONEMPTY=1 p ok 'scan group-by'      -- "$AG" scan 'SELECT tid, count(*) FROM run_events GROUP BY tid'
p ok  'scan --sealed-only'            -- "$AG" scan --sealed-only 'SELECT count(*) FROM run_events'
p err 'scan write attempt'            -- "$AG" scan 'DELETE FROM run_events'
p ok  'scan --parallel 4'             -- "$AG" scan --parallel 4 'SELECT count(*) FROM run_events'
p err 'scan --parallel 0'             -- "$AG" scan --parallel 0 'SELECT 1'
p err 'scan dot-command (.shell)'     -- "$AG" scan "$(printf 'SELECT 1;\n.shell echo pwned')"
p err 'scan dot-command (.output)'    -- "$AG" scan "$(printf '.output /tmp/ag-should-not-exist\nSELECT 1;')"
p ok  'scan indented float literal'   -- "$AG" scan "$(printf 'SELECT 1 +\n .5;')"
p err 'scan no sql'                   -- "$AG" scan

# ------------------------------------------------------------ projection -----
say 'projection / graph'
PNONEMPTY=1 p ok 'project BIG'        -- "$AG" project --run "$BIG"
PNONEMPTY=1 p ok 'project (rebuild)'  -- "$AG" project --run "$BIG"
PNONEMPTY=1 p ok 'project SMALL'      -- "$AG" project --run "$SMALL"
PNONEMPTY=1 p ok 'graph'              -- "$AG" graph --run "$BIG"
PNONEMPTY=1 p ok 'graph --nodes'      -- "$AG" graph --run "$BIG" --nodes
p ok 'graph --edges'                  -- "$AG" graph --run "$BIG" --edges
p ok 'graph --kind doc'               -- "$AG" graph --run "$BIG" --kind doc
p ok 'graph --from OBJ'               -- "$AG" graph --run "$BIG" --from "$OBJ"
p ok 'graph --to OBJ'                 -- "$AG" graph --run "$BIG" --to "$OBJ"
PNONEMPTY=1 p ok 'explain object'     -- "$AG" explain --run "$BIG" --obj "$OBJ"
p err 'explain unknown obj'           -- "$AG" explain --run "$BIG" --obj nope
p err 'explain missing --obj'         -- "$AG" explain --run "$BIG"
PNONEMPTY=1 p ok 'diff BIG SMALL'     -- "$AG" diff "$BIG" "$SMALL"
PNONEMPTY=1 p ok 'diff self'          -- "$AG" diff "$BIG" "$BIG"
p err 'diff one arg'                  -- "$AG" diff "$BIG"
p err 'graph purged'                  -- "$AG" graph --run "$PURGED"

# ---------------------------------------------------------------- frames -----
say 'frames / fork / cache / replay'
F=$("$AG" frame-open --run "$SMALL" | jq -r '.frame // empty')
p ok  'frame-open'                    -- "$AG" frame-open --run "$SMALL"
p ok  'frame-open --parent'           -- "$AG" frame-open --run "$SMALL" --parent "$F"
p ok  'frame-close'                   -- "$AG" frame-close --run "$SMALL" --frame "$F"
p ok  'frame-close --result'          -- "$AG" frame-close --run "$SMALL" --frame f2 --result '{"ok":true}'
p err 'frame-close unknown frame'     -- "$AG" frame-close --run "$SMALL" --frame f99
p err 'frame-close twice'             -- "$AG" frame-close --run "$SMALL" --frame "$F"
p err 'frame-open --parent unknown'   -- "$AG" frame-open --run "$SMALL" --parent f99

p ok  'fork mid-run'                  -- "$AG" fork "$BIG" 25
p ok  'fork --close-parent'           -- "$AG" fork "$SMALL" 5 --close-parent
p err 'fork seq beyond end'           -- "$AG" fork "$BIG" 999999
p err 'fork no seq'                   -- "$AG" fork "$BIG"

if [[ -n $CACHE_HASH ]]; then
    p ok 'cache-lookup hit'           -- "$AG" cache-lookup "$CACHE_HASH"
    p ok 'cache-lookup --by request'  -- "$AG" cache-lookup "$CACHE_HASH" --by request
    p ok 'cache-lookup --by any'      -- "$AG" cache-lookup "$CACHE_HASH" --by any
fi
p err 'cache-lookup bad hash'         -- "$AG" cache-lookup 'zzzz'
PNONEMPTY=1 p ok 'cache-lookup miss ({"hit":false})' -- "$AG" cache-lookup "$(printf 'a%.0s' {1..64})"

PNONEMPTY=1 p ok 'replay'             -- "$AG" replay --run "$SMALL"
"$AG" replay --run "$SMALL" > "$TDIR/replay.ndjson" 2>/dev/null
# the strict dialect is {type, payload}, not the permissive plan (see help)
"$AG" events --run "$SMALL" | jq -c '{type,payload}' > "$TDIR/cand.ndjson"
pin ok  'replay --strict (match)'   "$(cat "$TDIR/cand.ndjson")" -- "$AG" replay --run "$SMALL" --strict
pin ok  'replay --strict (no trailing NL)' "$(perl -0pe 's/\n\z//' < "$TDIR/cand.ndjson")" -- "$AG" replay --run "$SMALL" --strict
pin err 'replay --strict (diverge)' '{"seq":1,"type":"nope","payload":{}}' -- "$AG" replay --run "$SMALL" --strict
p err 'replay purged'                 -- "$AG" replay --run "$PURGED"

p ok  'wait --timeout 200 (no data)'  -- "$AG" wait --run "$SMALL" --since 99999 --timeout 200
p ok  'wait (data ready)'             -- "$AG" wait --run "$SMALL" --since 1 --timeout 200
p ok  'wait --types'                  -- "$AG" wait --run "$SMALL" --types x.note,tool.requested --since 1 --timeout 200
p err 'wait --timeout garbage'        -- "$AG" wait --run "$SMALL" --timeout abc

# ----------------------------------------------------------- behaviours ------
say 'behaviours'
p ok  'behavior-add'                  -- "$AG" behavior-add --name b1 --on object.created --match '(d:doc)' -- printf '{"type":"x.echoed","payload":{"a":1}}\n'
p ok  'behavior-add --absent'         -- "$AG" behavior-add --name b4 --on object.created --match '(d:doc)' --absent 'd-[:seen]->' -- printf '\n'
p ok  'behavior-add --where'          -- "$AG" behavior-add --name b3 --on object.created --match '(d:doc)' --where "d.data ->> '\$.title' IS NOT NULL" -- printf '\n'
p ok  'behavior-add (replace by name)' -- "$AG" behavior-add --name b3 --on object.created --match '(d:doc)' -- printf '\n'
p ok  'behavior-add 2-hop pattern'    -- "$AG" behavior-add --name b5 --on relation.created --match '(a:doc)-[:cites]->(b:doc)' -- printf '\n'
PNONEMPTY=1 p ok 'behaviors'          -- "$AG" behaviors
p err 'behavior-add no --on'          -- "$AG" behavior-add --name b9 --match '(d:doc)' -- printf '\n'
p err 'behavior-add no --match'       -- "$AG" behavior-add --name b9 --on object.created -- printf '\n'
p err 'behavior-add no argv'          -- "$AG" behavior-add --name b9 --on object.created --match '(d:doc)'
p err 'behavior-add bad pattern'      -- "$AG" behavior-add --name b9 --on object.created --match 'not a pattern' -- printf '\n'
p err 'behavior-add --where with ;'   -- "$AG" behavior-add --name b9 --on object.created --match '(d:doc)' --where '1=1; DROP TABLE runs' -- printf '\n'
p err 'behavior-add bad name'         -- "$AG" behavior-add --name 'Bad Name' --on object.created --match '(d:doc)' -- printf '\n'
R3=$("$AG" run-start --goal react | jq -r .run)
"$AG" emit --run "$R3" --type object.created --payload '{"kind":"doc","title":"react me"}' >/dev/null
p ok  'react --once'                  -- "$AG" react --run "$R3" --once
p ok  'react --max-rounds 2'          -- "$AG" react --run "$R3" --max-rounds 2
p ok  'react (converge)'              -- "$AG" react --run "$R3"
p err 'react --max-rounds 0'          -- "$AG" react --run "$R3" --max-rounds 0
p ok  'behavior-remove --name'        -- "$AG" behavior-remove --name b5
p err 'behavior-remove unknown'       -- "$AG" behavior-remove --name nope
p ok  'behavior-remove --all'         -- "$AG" behavior-remove --all

# ------------------------------------------------------------ maintenance ----
say 'maintenance / segments / backup'
p ok 'doctor'                         -- "$AG" doctor
p ok 'migrate --dry-run'              -- "$AG" migrate --dry-run
p ok 'migrate'                        -- "$AG" migrate
p ok 'maintain'                       -- "$AG" maintain
p ok 'verify-files'                   -- "$AG" verify-files
p ok 'verify-files --quarantine'      -- "$AG" verify-files --quarantine
p ok 'seal --all (none drained)'      -- "$AG" seal --all
p err 'seal --seg 999'                -- "$AG" seal --seg 999
p ok 'backup'                         -- "$AG" backup "$TDIR/bak"
p ok 'backup (incremental re-run)'    -- "$AG" backup "$TDIR/bak"
p err 'backup no dest'                -- "$AG" backup
p ok 'purge'                          -- "$AG" purge --run "$ENDED"
# purge is documented as batched and RESUMABLE, which requires re-running it
# on an already-purged run to be a no-op rather than an error.
p ok  'purge twice (idempotent)'      -- "$AG" purge --run "$ENDED"
p err 'segment-rewrite live run'      -- "$AG" segment-rewrite "$SMALL"

# force a rollover so a SEALED segment exists, then re-profile the readers
say 'segmented store (rollover + seal)'
export AG_SEG_MAX_BYTES=262144
RO=$("$AG" run-start --goal rollover | jq -r .run)
"$AG" emit-batch --run "$RO" < "$TDIR/seed.ndjson" >/dev/null 2>&1
"$AG" run-end --run "$RO" >/dev/null 2>&1
p ok 'run-start (triggers rollover)'  -- "$AG" run-start --goal 'after rollover'
p ok 'maintain (seals drained)'       -- "$AG" maintain
SEGS=$(ls "$AG_DIR"/seg-*.db 2>/dev/null | wc -l | tr -d ' ')
printf '# segments on disk: %s\n' "$SEGS" >&2
PNONEMPTY=1 p ok 'stats (multi-segment)'   -- "$AG" stats
PNONEMPTY=1 p ok 'scan (multi-segment)'    -- "$AG" scan 'SELECT count(*) FROM run_events'
p ok 'verify-files (sealed present)'  -- "$AG" verify-files
p ok 'events across segments'         -- "$AG" events --run "$RO" --limit 5
p ok 'backup (with sealed segs)'      -- "$AG" backup "$TDIR/bak2"

# --------------------------------------------------------------- RPC ---------
# The 21 methods in AG_RPC_ALLOWED are a second front door with its own parser,
# and profile.sh covered none of them. They are also where the ~80 ms of
# per-invocation setup goes away: the server opens the store once, so a request
# costs what the request costs. That difference is the point of `serve`, and it
# is only visible if both sides are measured.
say 'RPC surface (socat / IPC)'
if command -v socat >/dev/null 2>&1; then
    SOCK="$AG_DIR/ag.sock"
    rm -f "$SOCK" "$AG_DIR/ag-serve.pid"
    "$AG" serve --transport ipc > "$TDIR/serve.log" 2>&1 &
    SPID=$!
    for _ in $(seq 1 100); do [[ -S $SOCK ]] && break; sleep 0.05; done
    if [[ -S $SOCK ]]; then
        # rpc <expect> <label> <frame>   — one request, one reply, timed
        rpc() {
            local expect=$1 label=$2 frame=$3
            local t0=${EPOCHREALTIME/./}
            local out; out=$(printf '%s\n' "$frame" | socat -t 5 - "UNIX-CONNECT:$SOCK" 2>/dev/null | head -1)
            local us=$(( ${EPOCHREALTIME/./} - t0 ))
            N_PROBE=$((N_PROBE+1))
            local anom=''
            case $expect in
                ok)  [[ $out == *'"result"'* ]] || anom="expected result, got: ${out:0:120}" ;;
                err) [[ $out == *'"error"'*  ]] || anom="expected error, got: ${out:0:120}" ;;
            esac
            [[ -n $anom ]] && { N_ANOM=$((N_ANOM+1)); printf '  !! %-38s %s\n' "$label" "$anom" >&2; }
            printf '{"label":%s,"cmd":"rpc","rc":0,"us":%d,"out_bytes":%d,"expect":"%s","anom":%s,"err":""}\n' \
                "$(jq -Rn --arg v "rpc $label" '$v')" "$us" "${#out}" "$expect" \
                "$(jq -Rn --arg v "$anom" '$v')" >> "$OUT/probes.ndjson"
        }
        RR=$(printf '{"jsonrpc":"2.0","id":1,"method":"ag.run_start","params":{"goal":"rpc"}}\n' \
             | socat -t 5 - "UNIX-CONNECT:$SOCK" 2>/dev/null | head -1 | jq -r '.result.run // empty')
        rpc ok  'ag.ping'        '{"jsonrpc":"2.0","id":1,"method":"ag.ping","params":{}}'
        rpc ok  'ag.run_start'   '{"jsonrpc":"2.0","id":2,"method":"ag.run_start","params":{"goal":"g","tags":["t"]}}'
        rpc ok  'ag.emit'        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ag.emit\",\"params\":{\"run\":\"$RR\",\"type\":\"x.note\",\"payload\":{\"a\":1}}}"
        rpc ok  'ag.emit_batch'  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ag.emit_batch\",\"params\":{\"run\":\"$RR\",\"events\":[{\"type\":\"x.a\",\"payload\":{}},{\"type\":\"x.b\",\"payload\":{}}]}}"
        rpc ok  'ag.events'      "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ag.events\",\"params\":{\"run\":\"$RR\"}}"
        rpc ok  'ag.events big'  "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"ag.events\",\"params\":{\"run\":\"$BIG\"}}"
        rpc ok  'ag.stats'       '{"jsonrpc":"2.0","id":7,"method":"ag.stats","params":{}}'
        rpc ok  'ag.insights'    '{"jsonrpc":"2.0","id":8,"method":"ag.insights","params":{}}'
        rpc ok  'ag.behaviors'   '{"jsonrpc":"2.0","id":9,"method":"ag.behaviors","params":{}}'
        rpc ok  'ag.project'     "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"ag.project\",\"params\":{\"run\":\"$BIG\"}}"
        rpc ok  'ag.graph'       "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"ag.graph\",\"params\":{\"run\":\"$BIG\"}}"
        rpc ok  'ag.explain'     "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"ag.explain\",\"params\":{\"run\":\"$BIG\",\"obj\":\"$OBJ\"}}"
        rpc ok  'ag.diff'        "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"ag.diff\",\"params\":{\"a\":\"$BIG\",\"b\":\"$SMALL\"}}"
        rpc ok  'ag.replay'      "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"ag.replay\",\"params\":{\"run\":\"$BIG\"}}"
        rpc ok  'ag.cache_lookup' "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"ag.cache_lookup\",\"params\":{\"hash\":\"$(printf 'a%.0s' {1..64})\"}}"
        rpc ok  'ag.wait'        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"ag.wait\",\"params\":{\"run\":\"$RR\",\"since_seq\":1,\"timeout_ms\":200}}"
        rpc ok  'ag.frame_open'  "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"ag.frame_open\",\"params\":{\"run\":\"$RR\"}}"
        rpc ok  'ag.frame_close' "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"ag.frame_close\",\"params\":{\"run\":\"$RR\",\"frame\":\"f1\"}}"
        rpc err 'ag.frame_close f99 (never opened)' "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"ag.frame_close\",\"params\":{\"run\":\"$RR\",\"frame\":\"f99\"}}"
        rpc ok  'ag.fork'        "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"ag.fork\",\"params\":{\"run\":\"$RR\",\"seq\":1}}"
        rpc ok  'ag.react'       "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"ag.react\",\"params\":{\"run\":\"$RR\",\"once\":true}}"
        rpc ok  'ag.run_end'     "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"ag.run_end\",\"params\":{\"run\":\"$RR\"}}"
        rpc err 'method not allowlisted (ag.scan)' '{"jsonrpc":"2.0","id":23,"method":"ag.scan","params":{}}'
        rpc err 'unknown param rejected'  "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"ag.events\",\"params\":{\"run\":\"$BIG\",\"nope\":1}}"
        rpc err 'malformed JSON frame'    '{"jsonrpc":"2.0",'
        rpc err 'missing method'          '{"jsonrpc":"2.0","id":25,"params":{}}'
    else
        printf '  !! serve did not bind; RPC surface unprofiled\n' >&2
        N_ANOM=$((N_ANOM+1))
    fi
    kill "$SPID" 2>/dev/null
    pkill -f "UNIX-LISTEN:$SOCK" 2>/dev/null
    wait "$SPID" 2>/dev/null
    rm -f "$SOCK"
else
    printf '  -- socat not installed; RPC surface skipped\n' >&2
fi

# ---------------------------------------------------------------- report -----
say 'report'
jq -s '
  def ms: .us/1000;
  {
    probes: length,
    anomalies: [.[] | select(.anom != "")] | length,
    total_ms: (map(.us) | add / 1000 | floor)
  }' "$OUT/probes.ndjson" >&2
printf '\n--- slowest 25 probes (ms) ---\n' >&2
jq -r 'select(.rc==0) | "\(.us/1000|floor)\t\(.label)"' "$OUT/probes.ndjson" \
    | sort -rn | head -25 >&2
printf '\n--- anomalies ---\n' >&2
jq -r 'select(.anom != "") | "\(.label)\n    \(.anom)\n    \(.err[0:200])"' \
    "$OUT/probes.ndjson" >&2
printf '\nprobes=%d anomalies=%d  (raw: %s)\n' "$N_PROBE" "$N_ANOM" "$OUT/probes.ndjson" >&2
exit 0
