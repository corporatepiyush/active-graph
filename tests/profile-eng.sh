#!/usr/bin/env bash
# tests/profile-eng.sh — white-box companion to profile.sh.
#
# profile.sh measures what a command COSTS. This measures WHERE that cost goes,
# by sourcing active-graph.sh (its `_main` is guarded by a BASH_SOURCE check)
# and wrapping `_eng`, the single chokepoint every SQL round trip passes
# through. For each flow it reports round-trip count, total engine time, and
# the slowest individual statements — which is the only way to tell "this
# command is slow because SQLite is slow" from "this command is slow because
# it asks SQLite 40 questions in a row".
set -o pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${AG_PROF_N:=200}"
TDIR=$(mktemp -d "${TMPDIR:-/tmp}/agprofeng.XXXXXXXX")
export AG_DIR="$TDIR/store"
trap 'rm -rf "$TDIR"' EXIT

source "$ROOT/active-graph.sh"

PROF_ON=0
declare -a PROF_US=() PROF_SQL=()
PROF_N=0 PROF_TOTAL=0
eval "_eng_orig() $(declare -f _eng | tail -n +2)"
_eng() {
    (( PROF_ON )) || { _eng_orig "$@"; return $?; }
    local t0=${EPOCHREALTIME/./} rc
    _eng_orig "$@"; rc=$?
    local dt=$(( ${EPOCHREALTIME/./} - t0 ))
    PROF_N=$((PROF_N+1)); PROF_TOTAL=$((PROF_TOTAL+dt))
    PROF_US+=("$dt"); PROF_SQL+=("${2//$'\n'/ }")
    return $rc
}
prof_reset() { PROF_N=0 PROF_TOTAL=0; PROF_US=() PROF_SQL=(); PROF_ON=1; }
prof_report() {  # $1 = label, $2 = wall us
    PROF_ON=0
    printf '%-28s wall=%6dms  engine=%6dms  round-trips=%3d\n' \
        "$1" "$(( $2 / 1000 ))" "$(( PROF_TOTAL / 1000 ))" "$PROF_N"
    local i
    for i in "${!PROF_US[@]}"; do
        printf '%s\t%s\n' "${PROF_US[$i]}" "${PROF_SQL[$i]}"
    done | sort -rn | head -3 | while IFS=$'\t' read -r us sql; do
        (( us > 2000 )) && printf '      %5dms  %.110s\n' "$((us/1000))" "$sql"
    done
    return 0
}
# flow <label> -- cmd...
flow() {
    local label=$1; shift 2
    prof_reset
    local t0=${EPOCHREALTIME/./}
    "$@" >/dev/null 2>&1
    prof_report "$label" "$(( ${EPOCHREALTIME/./} - t0 ))"
}

# ---- ag_open on its own: every command pays this before it does anything ----
prof_reset
t0=${EPOCHREALTIME/./}
ag_open || { echo "open failed: $AG_ERR" >&2; exit 1; }
prof_report 'ag_open (fresh store)' "$(( ${EPOCHREALTIME/./} - t0 ))"

ag_close
AG_OPENED=0
prof_reset
t0=${EPOCHREALTIME/./}
ag_open
prof_report 'ag_open (existing store)' "$(( ${EPOCHREALTIME/./} - t0 ))"

# ---- and where inside ag_open the non-engine time goes -----------------------
# ag_open is paid by literally every command, so a millisecond here is a
# millisecond on all 30 of them.
step() {  # step <label> <cmd...>
    local label=$1; shift
    local t0=${EPOCHREALTIME/./}
    "$@" >/dev/null 2>&1
    printf '    %-24s %6d us\n' "$label" "$(( ${EPOCHREALTIME/./} - t0 ))"
}
echo "  ag_open step breakdown (cold, one fresh process's worth of work):"
ag_close; AG_OPENED=0; AG_SQLITE_OK=''
step 'mktemp -d'        mktemp -d "${TMPDIR:-/tmp}/agstep.XXXXXX"
step '_sqlite_resolve'  _sqlite_resolve
step '_sqlite_resolve x2' _sqlite_resolve
AG_TMP=${ mktemp -d "${TMPDIR:-/tmp}/agstep2.XXXXXX"; }
step '_platform_init'   _platform_init
step '_fs_guard'        _fs_guard "$AG_DIR"
step '_dir_guard'       _dir_guard "$AG_DIR"
step '_build_id'        _build_id
step '_engine_spawn w'  _engine_spawn w "$AG_DIR/ag-catalog.db" "${ _engine_init_sql rw; }"
AG_ENG_MODE[w]=rw
step '_store_check'     _store_check
AG_OPENED=1

BIG=$(ag_run_start --goal 'eng profile' | sed 's/.*"run":"\([^"]*\)".*/\1/')
[[ $BIG == r* ]] || { echo "could not capture run id: $BIG" >&2; exit 1; }
FILLER=$(printf 'x%.0s' $(seq 1 600))
{
    for (( i=1; i<=AG_PROF_N; i++ )); do
        printf '{"type":"tool.requested","actor":"agent","payload":{"tool":"s","q":"i%d","f":"%s"},"ctx":{"model":"m","tokens_in":%d,"tokens_out":9,"cost_usd":0.001,"dur_ms":12}}\n' "$i" "$FILLER" "$i"
        printf '{"type":"tool.responded","actor":"tool","payload":{"ok":true,"n":%d}}\n' "$i"
    done
} > "$TDIR/seed.ndjson"

echo
echo "--- flows (run has $(( AG_PROF_N * 2 )) events) ---"
flow 'emit-batch (N events)'  -- ag_emit_batch --run "$BIG" < "$TDIR/seed.ndjson"
flow 'emit (single)'          -- ag_emit --run "$BIG" --type x.note --payload '{"a":1}'
flow 'emit (blob offload)'    -- ag_emit --run "$BIG" --type x.note --payload "{\"b\":\"$FILLER\"}"
flow 'emit (idem)'            -- ag_emit --run "$BIG" --type x.note --payload '{"a":2}' --idem k1
flow 'events (full)'          -- ag_events --run "$BIG"
flow 'events --limit 10'      -- ag_events --run "$BIG" --limit 10
flow 'verify'                 -- ag_verify --run "$BIG"
flow 'verify --chain'         -- ag_verify --run "$BIG" --chain
flow 'project'                -- ag_project --run "$BIG"
flow 'graph'                  -- ag_graph --run "$BIG"
flow 'stats'                  -- ag_stats
flow 'insights'               -- ag_insights
flow 'scan'                   -- ag_scan 'SELECT count(*) FROM run_events'
flow 'replay'                 -- ag_replay --run "$BIG"
flow 'run-start'              -- ag_run_start --goal x
flow 'fork'                   -- ag_fork "$BIG" 10
flow 'maintain'               -- ag_maintain
flow 'doctor'                 -- ag_doctor
ag_close
