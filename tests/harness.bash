# tests/harness.bash — minimal TAP harness. Source from each test file.
# Deliberately bash-3.2-compatible so any /bin/bash can run the tests;
# the script under test re-execs itself into bash >= 5.3.
set -o pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AG="$ROOT/active-graph.sh"
SQ=${AG_SQLITE:-/opt/homebrew/opt/sqlite/bin/sqlite3}
[ -x "$SQ" ] || SQ=$(command -v sqlite3)

TDIR=$(mktemp -d "${TMPDIR:-/tmp}/agtest.XXXXXXXX")
export AG_DIR="$TDIR/store"
_harness_cleanup() { rm -rf "$TDIR"; }
trap _harness_cleanup EXIT

# Every individual test case must finish inside AG_T_MAX seconds. Anything that
# needs to observe a timeout drives the RUNTIME's own knobs down instead of
# sleeping: a test that waits 30s to watch a 30s deadline expire is a slow test,
# not a thorough one.
: "${AG_T_MAX:=5}"
export AG_REQ_DEADLINE_S=${AG_REQ_DEADLINE_S:-2}
export AG_AUTH_COOLDOWN_S=${AG_AUTH_COOLDOWN_S:-1}
export AG_BEHAVIOR_TIMEOUT_S=${AG_BEHAVIOR_TIMEOUT_S:-3}

: "${FUZZN:=200}"   # generative-fuzz iterations; raise for a deep run, lower
                    # under emulation. Every fuzz loop reads this one knob.

T_N=0 T_FAIL=0
t_ok()    { local rc=$1; shift; T_N=$((T_N+1)); if [ "$rc" -eq 0 ]; then echo "ok $T_N - $*"; else echo "not ok $T_N - $*"; T_FAIL=$((T_FAIL+1)); fi; }
t_fails() { local rc=$1; shift; T_N=$((T_N+1)); if [ "$rc" -ne 0 ]; then echo "ok $T_N - $*"; else echo "not ok $T_N - $*"; T_FAIL=$((T_FAIL+1)); fi; }
t_is()    { local got=$1 want=$2; shift 2; T_N=$((T_N+1)); if [ "$got" = "$want" ]; then echo "ok $T_N - $*"; else echo "not ok $T_N - $* [got=$(printf '%.160s' "$got") want=$(printf '%.160s' "$want")]"; T_FAIL=$((T_FAIL+1)); fi; }
t_like()  { local got=$1 pat=$2; shift 2; T_N=$((T_N+1)); case $got in $pat) echo "ok $T_N - $*" ;; *) echo "not ok $T_N - $* [got=$(printf '%.160s' "$got")]"; T_FAIL=$((T_FAIL+1)) ;; esac; }
t_diag()  { echo "# $*"; }
t_done()  { echo "1..$T_N"; if [ "$T_FAIL" -eq 0 ]; then exit 0; else exit 1; fi; }

# t_within DESC CMD... — run under the per-case budget and fail on overrun.
# Reports the elapsed seconds so a case creeping toward the cap is visible
# before it starts failing intermittently.
t_within() {
    local desc=$1; shift
    local s=$SECONDS
    timeout "$AG_T_MAX" "$@" >/dev/null 2>&1
    local rc=$? dt=$((SECONDS - s))
    if [ "$rc" -eq 124 ]; then
        T_N=$((T_N+1)); T_FAIL=$((T_FAIL+1))
        echo "not ok $T_N - $desc [TIMED OUT after ${AG_T_MAX}s]"
        return 1
    fi
    T_N=$((T_N+1)); echo "ok $T_N - $desc (${dt}s)"
    return 0
}

# helpers
new_run() {  # [goal] -> prints run id
    "$AG" run-start --goal "${1:-test}" | jq -r .run
}
rid_of() {  # run_id -> numeric rid (runs table lives in the CATALOG)
    "$SQ" "$AG_DIR/ag-catalog.db" "SELECT rid FROM runs WHERE run_id='$1';"
}
seg_count() {  # run_id -> event count in the segment
    "$SQ" "$AG_DIR/seg-000001.db" "SELECT count(*) FROM run_events WHERE rid=$(rid_of "$1");"
}
# Portable file mode. GNU/busybox first: busybox `stat -f` is "filesystem
# status" and SUCCEEDS with default output, so a BSD-first probe never falls
# through and returns a whole stat dump instead of a mode.
t_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Search a BINARY file (a .db or its -wal) for a literal string.
# LC_ALL=C is not optional: busybox grep in a UTF-8 locale silently finds
# NOTHING in binary content, so a "the secret is gone" assertion would pass
# whether or not the secret was actually gone. Returns 0 when present.
t_in_file() {  # t_in_file <file> <literal>
    [ -f "$1" ] || return 1
    LC_ALL=C grep -aqF "$2" "$1" 2>/dev/null
}
# ...and across a database plus its sidecars, since a row may still be in the WAL
t_in_db() {  # t_in_db <db-path> <literal>
    local f
    for f in "$1" "$1-wal" "$1-shm"; do t_in_file "$f" "$2" && return 0; done
    return 1
}

# Options BEFORE the positional argument: Alpine's OpenBSD nc (musl getopt)
# does not permute, so `nc -U <path> -w 5` reads -w and 5 as extra positionals
# and dies with "cannot use port with -U".
# Send one frame, return as soon as the reply arrives.
# The old form was `( printf ...; sleep 3 ) | nc` — the sleep existed only to
# hold the connection open long enough for a reply, so EVERY call cost 3s of
# doing nothing. socat exits when head closes the pipe, so a call now costs
# what the server actually takes (milliseconds).
ipc_call() {  # frame, socket -> first response line
    printf '%s\n' "$1" | socat -t "${AG_T_MAX:-5}" - "UNIX-CONNECT:$2" 2>/dev/null | head -1
}

# Write a large payload to a file and echo the path: payloads over 128 KiB
# cannot be passed as an argv string on Linux (MAX_ARG_STRLEN).
big_payload_file() {  # $1 = dest path, $2 = kind, $3 = bytes (default 300000)
    local n=${3:-300000}
    printf '{"kind":"%s","data":{"blob":"' "$2" > "$1"
    head -c "$n" /dev/zero | tr '\0' x >> "$1"
    printf '"}}' >> "$1"
    printf '%s' "$1"
}
tcp_call() {  # frame, port -> first response line
    printf '%s\n' "$1" | socat -t "${AG_T_MAX:-5}" - "TCP:127.0.0.1:$2" 2>/dev/null | head -1
}

# socat is the ONLY serving backend. A host without it cannot serve at all, so
# server tests skip cleanly instead of silently exercising something else.
require_socat() {
    command -v socat >/dev/null 2>&1 && return 0
    echo "1..0 # SKIP socat not installed - 'serve' requires it (brew/apk/apt/pkg install socat)"
    exit 0
}
