#!/usr/bin/env bash
# active-graph.sh — ActiveGraph (arXiv:2605.21997): one bash file over SQLite.
#
# Append-only log is truth; the graph is a disposable projection.
#
# Contract: PLAN.md. Needs bash >= 5.3, sqlite3 >= 3.53.3. Apache-2.0.

# ---- bash >= 5.3 gate -------------------------------------------------------
# Must parse under bash 3.2 (macOS default). No 5.x syntax above this block.
if [ -z "${BASH_VERSINFO:-}" ] \
   || [ "${BASH_VERSINFO[0]}" -lt 5 ] \
   || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE:-}" != "$0" ]; then
        echo "active-graph: bash >= 5.3 required to source this library (have ${BASH_VERSION:-?})" >&2
        return 70 2>/dev/null || exit 70
    fi
    for _ag_b in /opt/homebrew/bin/bash /usr/local/bin/bash \
                 /home/linuxbrew/.linuxbrew/bin/bash /usr/local/opt/bash/bin/bash; do
        if [ -x "$_ag_b" ] && "$_ag_b" -c '(( BASH_VERSINFO[0]*100 + BASH_VERSINFO[1] >= 503 ))' 2>/dev/null; then
            exec "$_ag_b" "$0" "$@"
        fi
    done
    echo "active-graph: bash >= 5.3 required (found ${BASH_VERSION:-?}); try: $0 setup" >&2
    exit 70
fi

set -o pipefail
export LC_ALL=C
umask 077

# ---- constants & configuration (env-overridable) ----------------------------
readonly AG_VERSION="0.2.0"
readonly AG_SCHEMA_VERSION=3
readonly AG_SQLITE_MIN=3053003          # 3.53.3 as major*1e6+minor*1e3+patch

: "${AG_DIR:=$PWD/.activegraph}"
: "${AG_READERS:=2}"                    # extra read-only engines (--readers), PLAN 8.5
: "${AG_CHAIN:=0}"                      # 1 = tamper-evident hash chain
: "${AG_BLOB_MIN:=512}"                 # payloads > this (bytes) go to blobs
: "${AG_SEG_MAX_BYTES:=68719476736}"    # 64 GiB: active segment rolls over past this
: "${AG_ROLLOVER_LOCK_STALE_S:=30}"     # reap a rollover lock older than this w/ no live holder
: "${AG_MAX_PAYLOAD:=1048576}"          # 1 MiB payload cap
: "${AG_MAX_FRAME:=1048576}"            # 1 MiB RPC frame cap
: "${AG_MAX_RESP:=8388608}"             # 8 MiB response cap (PLAN 10.6)
: "${AG_MAX_RESULT:=67108864}"          # 64 MiB cap on a single result BUFFER
: "${AG_BEHAVIOR_TIMEOUT_S:=60}"        # max wall time for one behavior body
: "${AG_REACT_MAX_ROUNDS:=100}"         # cascade bound for the reactor loop
: "${AG_MAX_BATCH:=1000}"               # max elements in an RPC batch / emit-batch
: "${AG_MAX_CHILDREN:=32}"
: "${AG_REQ_DEADLINE_S:=30}"
# Bounds an engine's FIRST reply only (_engine_spawn). Too short breaks a slow
# store; too long only delays reporting a dead engine.
: "${AG_ENG_HANDSHAKE_S:=30}"
: "${AG_LIMIT_MAX:=10000}"
: "${AG_LIMIT_DEFAULT:=1000}"
: "${AG_CACHE_KB:=262144}"              # writer cache (KiB); rpc children drop to 32 MiB
: "${AG_HEAP_LIMIT:=268435456}"         # PRAGMA hard_heap_limit for server engines
: "${AG_ACCESS_LOG_MAX:=8388608}"       # rotate ag-access.log past this
: "${AG_RUN_GRACE_S:=3600}"             # sweep event-less 'live' runs older than this
: "${AG_AUTH_COOLDOWN_S:=5}"            # lockout duration after sustained auth failures
: "${AG_AUTH_WINDOW_S:=60}"             # window over which auth failures accumulate
: "${AG_AUTH_MAX_FAILS:=10}"            # failures within the window before lockout
: "${AG_ALLOW_EXPLICIT_ID:=0}"          # 1 = accept caller-supplied object.created ids
: "${AG_DEBUG:=0}"

# runtime state
declare -A AG_FIN=() AG_FOUT=() AG_EPID=()   # engine fds/pids by name (w r0 r1..)
AG_TMP='' AG_OUT='' AG_ERR='' AG_CODE=0 AG_MSG=''
declare -i AG_SEQREQ=0 AG_NAPFD=-1 AG_RR=0 AG_AUTH_FAILS=0
AG_OPENED=0 AG_TOKEN_SHA='' AG_SELF='' AG_PIDFILE='' AG_PEER='-' AG_HEAP_ON=''
AG_FILE_HASH_ALGO='' AG_ENG_DEADLINE_S=''   # set only around an engine handshake

# JSON-RPC-aligned internal error codes (CLI maps them to exit codes)
readonly AG_E_BUSY=-32000 AG_E_NORUN=-32001 AG_E_DIVERGE=-32002 \
         AG_E_AUTH=-32003 AG_E_STORAGE=-32005 AG_E_SCHEMA=-32010 \
         AG_E_PARAMS=-32602 AG_E_INTERNAL=-32603

# =============================================================================
# small helpers
# =============================================================================
_dbg()  { if (( AG_DEBUG )); then printf '[ag:debug] %s\n' "$*" >&2; fi; }
_note() { printf '[ag:debug] %s\n' "$*" >&2; }        # always-on debug notes
_fail() { AG_CODE=$1; shift; AG_MSG=$*; return 1; }   # library-safe error

# JSON string escaping for paths that run without an engine. Escaping only '"'
# left backslashes, newlines and control chars injectable.
_json_esc() {  # $1 -> REPLY = a complete JSON string literal
        # split declarations: `local s=$1 n=${#s}` expands ${#s} before `local s`
    local s=$1
    local out='' c i n=${#s}
    for (( i=0; i<n; i++ )); do
        c=${s:i:1}
        case $c in
            '"')   out+='\"' ;;
            '\')   out+='\\' ;;
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            *)     if [[ $c < ' ' ]]; then printf -v c '\\u%04x' "'$c"; fi; out+=$c ;;
        esac
    done
    REPLY="\"$out\""
}
_emit_error_json() {  # $1=code $2=message -> JSON-RPC error line
    _json_esc "$2"
    printf '{"jsonrpc":"2.0","id":null,"error":{"code":%s,"message":%s}}\n' "$1" "$REPLY"
}
_cli_error_json() {  # $1=code $2=message -> CLI error line
    _json_esc "$2"
    printf '{"error":{"code":%s,"message":%s}}\n' "$1" "$REPLY"
}

_self_path() {  # absolute path to this script (for socat EXEC)
    local s=${BASH_SOURCE[0]}
    [[ $s == /* ]] || s=$PWD/$s
    AG_SELF=$s
}

# Build fingerprint: short hash of this script, recorded in each run's env.
# Editing the file flips it (single-file analogue of a git dirty flag).
AG_BUILD_ID=''
_build_id() {  # cache once; empty if the file can't be hashed
    [[ -n $AG_BUILD_ID ]] && { printf '%s' "$AG_BUILD_ID"; return 0; }
    local h; h=${ _file_hash "$AG_SELF"; }
    [[ $h =~ ^[0-9a-f]{12} ]] && AG_BUILD_ID=${h:0:12} || AG_BUILD_ID=unknown
    printf '%s' "$AG_BUILD_ID"
}

_ver_num() {  # "3.53.3" -> 3053003
    local a b c
    IFS=. read -r a b c _ <<<"$1"
    printf '%d' $(( ${a:-0}*1000000 + ${b:-0}*1000 + ${c:-0} ))
}

# =============================================================================
# platform probe (PLAN 8.6): probe once, define functions
# =============================================================================
_platform_init() {
        # BSD vs GNU stat, decided by behaviour. $OSTYPE only picks which to try
        # first, saving a fork; the other is tried if it fails.
    case $OSTYPE in darwin*|*bsd*|dragonfly*) AG_STAT=try_bsd ;; *) AG_STAT=try_gnu ;; esac
    _p_stat() {      # _p_stat <gnu-fmt> <bsd-fmt> <file...>
        local out
        case $AG_STAT in
            gnu) stat -c"$1" "${@:3}" 2>/dev/null; return $? ;;
            bsd) stat -f"$2" "${@:3}" 2>/dev/null; return $? ;;
        esac
        local -a order=(gnu bsd); [[ $AG_STAT == try_bsd ]] && order=(bsd gnu)
        local f
        for f in "${order[@]}"; do
            if [[ $f == gnu ]]; then out=${ stat -c"$1" "${@:3}" 2>/dev/null; }
            else                     out=${ stat -f"$2" "${@:3}" 2>/dev/null; }
            fi
                        # Shape test, not exit status: busybox `stat -f` is "filesystem status"
                        # and can exit 0 with an unrelated report. Every format here yields digits.
            if [[ $out =~ ^[0-9]+([ $'\n'][0-9]+)*$ ]]; then
                AG_STAT=$f; printf '%s' "$out"; return 0
            fi
        done
        return 1
    }
    _p_fsize() { _p_stat %s  %z   "$1"; }
    _p_fmode() { _p_stat %a  %Lp  "$1"; }
    _p_mtime() { _p_stat %Y  %m   "$1"; }
    _p_fuid()  { _p_stat %u  %u   "$1"; }
        # Streaming hash: never readfile() a 64GB segment. Algorithm PINNED to
        # sha256 — a sha3 fallback hashed the same store differently per host.
    AG_FILE_HASH_ALGO=sha256
    if command -v sha256sum >/dev/null 2>&1; then
        _file_hash() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
    elif command -v shasum >/dev/null 2>&1; then
        _file_hash() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
    elif command -v openssl >/dev/null 2>&1; then
        _file_hash() { openssl dgst -sha256 -r "$1" 2>/dev/null | cut -d' ' -f1; }
    else
        _file_hash() { AG_FILE_HASH_ALGO=''; printf ''; }
    fi
        # Sub-second sleep: read -t on a never-ready fifo, created on FIRST USE.
        # It costs a fork, and almost no command ever naps.
    _nap() {
        if [[ -n $AG_TMP ]] && mkfifo "$AG_TMP/nap" 2>/dev/null; then
            exec {AG_NAPFD}<>"$AG_TMP/nap"
            _nap() { read -r -t "$1" -u "$AG_NAPFD" _ 2>/dev/null || :; }
        else
            _nap() { sleep "$1"; }     # no fifo (or already made): fall back
        fi
        _nap "$1"
    }
        # /dev/tcp may be compiled out of bash; PLAN 8.6 wants an `nc -z` fallback.
        #
        # Probed on first port check: the cheap branch fails everywhere (nothing
        # listens on port 1), so the 2-fork branch ran on every invocation.
    AG_HAVE_DEVTCP=''
    _p_port_probe() {
        AG_HAVE_DEVTCP=0
        if { exec {_agp}<>/dev/tcp/127.0.0.1/1; } 2>/dev/null; then
            exec {_agp}>&- 2>/dev/null; AG_HAVE_DEVTCP=1
        elif [[ ! -e /dev/tcp ]] && ! bash -c ': </dev/tcp/127.0.0.1/1' 2>&1 | grep -qi 'no such file'; then
            AG_HAVE_DEVTCP=1     # connection refused (not "unsupported") means it works
        fi
        if (( AG_HAVE_DEVTCP )); then
            _p_port_busy() { local fd; { exec {fd}<>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null || return 1
                             exec {fd}>&- 2>/dev/null; return 0; }
        elif command -v nc >/dev/null 2>&1; then
            _p_port_busy() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }
        else
            _p_port_busy() { return 1; }   # cannot probe: treat every port as free
        fi
    }
    _p_port_busy() { _p_port_probe; _p_port_busy "$1"; }
}

# =============================================================================
# access log (PLAN 10.7 / OWASP A09): one line per RPC request. Fields are
# control-stripped and capped (CWE-117); tokens and payloads never logged.
# =============================================================================
AG_ACCESS_FD=-1
_access_open() {
    (( AG_ACCESS_FD >= 0 )) && return 0
    [[ -n $AG_DIR && -d $AG_DIR ]] || return 1
    local f="$AG_DIR/ag-access.log"
    exec {AG_ACCESS_FD}>>"$f" 2>/dev/null || { AG_ACCESS_FD=-1; return 1; }
    chmod 600 "$f" 2>/dev/null || :
}
_lf() {  # sanitise one log field: printable only, capped -> REPLY
    local v=${1//[![:print:]]/}
    REPLY=${v:0:120}
}
_access_log() {  # ts peer method id code dur_ms bytes_in bytes_out
    _access_open || return 0
    printf '%s %s %s %s %s %s %s %s\n' \
        "${EPOCHREALTIME%.*}" "${| _lf "${AG_PEER:--}"; }" "${| _lf "$1"; }" \
        "${| _lf "$2"; }" "$3" "$4" "$5" "$6" >&"$AG_ACCESS_FD" 2>/dev/null || :
}
_access_log_rotate() {  # size-based, keep 3 generations (PLAN 16 caveat 9)
    local f="$AG_DIR/ag-access.log" sz i
    [[ -f $f ]] || return 0
    sz=${ _p_fsize "$f"; }
    [[ $sz =~ ^[0-9]+$ ]] && (( sz > AG_ACCESS_LOG_MAX )) || return 0
    for i in 2 1; do
        [[ -f $f.$i ]] && mv -f "$f.$i" "$f.$(( i + 1 ))" 2>/dev/null
    done
    mv -f "$f" "$f.1" 2>/dev/null || :
    (( AG_ACCESS_FD >= 0 )) && { exec {AG_ACCESS_FD}>&- 2>/dev/null; AG_ACCESS_FD=-1; }
    _note 'rotated ag-access.log'
}

# Cross-connection brute-force guard (PLAN 12/A07). socat gives each connection
# its own process, so a per-connection counter alone lets a client reconnect.
#
# Appending one short line is atomic; no lock needed.
_auth_locked() {  # 0 = locked out
    local f="$AG_DIR/.auth-fails" now cutoff t
    local -i n=0
    [[ -f $f ]] || return 1
    now=${ printf '%(%s)T' -1; }
    cutoff=$(( now - AG_AUTH_WINDOW_S ))
    while read -r t; do
        [[ $t =~ ^[0-9]+$ ]] || continue
        (( t >= cutoff )) && (( n++ ))
    done < "$f"
    (( n >= AG_AUTH_MAX_FAILS ))
}

_auth_record_fail() {
    local f="$AG_DIR/.auth-fails" now t
    now=${ printf '%(%s)T' -1; }
    printf '%s\n' "$now" >> "$f" 2>/dev/null || return 0
    chmod 600 "$f" 2>/dev/null || :
        # keep the file bounded: prune outside the window, occasionally
    if (( RANDOM % 16 == 0 )); then
        local cutoff=$(( now - AG_AUTH_WINDOW_S )) tmp="$f.$$"
        : > "$tmp"
        while read -r t; do
            [[ $t =~ ^[0-9]+$ ]] && (( t >= cutoff )) && printf '%s\n' "$t" >> "$tmp"
        done < "$f"
        mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    fi
}

_wal_alarm() {  # PLAN 16 caveat 6: a pinned WAL grows without bound
    local w sz
    for w in "$AG_DIR"/*.db-wal; do
        [[ -f $w ]] || continue
        sz=${ _p_fsize "$w"; }
        [[ $sz =~ ^[0-9]+$ ]] || continue
        (( sz > 4 * 67108864 )) && \
            printf 'active-graph: WARNING: %s is %s bytes (>4x journal_size_limit) - a long-lived read txn may be pinning it\n' "$w" "$sz" >&2
    done
    _eng w 'PRAGMA wal_checkpoint(PASSIVE);' 2>/dev/null || :
}

_fs_type() {  # best-effort filesystem type of $1 (PLAN 8.6 guard)
    local d=$1 best='' bl=0 mp fs
    if [[ -r /proc/mounts ]]; then
        while read -r _ mp fs _; do
            if [[ $d == "$mp"* && ${#mp} -gt $bl ]]; then best=$fs; bl=${#mp}; fi
        done < /proc/mounts
    else  # macOS / FreeBSD: `mount` lines: /dev/x on /path (type, opts)
        local line
        while IFS= read -r line; do
            mp=${line#* on }; mp=${mp% (*}
            fs=${line##*(}; fs=${fs%%,*}; fs=${fs%)}
            if [[ $d == "$mp"* && ${#mp} -gt $bl ]]; then best=$fs; bl=${#mp}; fi
        done < <(mount 2>/dev/null)
    fi
    printf '%s' "${best:-unknown}"
}

_dir_guard() {  # PLAN 12/A01 + caveat 18: the 0700 store dir IS the access control
        # The 0700 store dir IS the access control, and nothing asserted it.
        #
        # Auto-heal if we own it, else fail closed. Owner and mode from ONE stat.
    local d=$1 mode uid both=$AG_DIRSTAT
    [[ -n $both ]] || both=${ _p_stat '%u %a' '%u %Lp' "$d"; }
    uid=${both%% *}; both=${both#* }; mode=${both%% *}
    if [[ $uid =~ ^[0-9]+$ && $uid != "$UID" ]]; then
        _fail "$AG_E_AUTH" "store dir $d is owned by uid $uid, not $UID - refusing"; return 1
    fi
    if [[ $mode != 700 ]]; then
        chmod 700 "$d" 2>/dev/null || :
        mode=${ _p_fmode "$d"; }
    fi
    [[ $mode == 700 ]] || {
        _fail "$AG_E_AUTH" "store dir $d must be mode 0700 (is ${mode:-unknown}); it is the only portable access control for the IPC socket and the db files"; return 1; }
    return 0
}

# ONE stat(1) for what ag_open needs: the store dir's owner and mode, plus the
# sqlite3 binary's size and mtime (the probe cache's stamp).
AG_DIRSTAT='' AG_BINSTAT=''
_open_stat() {  # $1 = store dir, $2 = candidate binary (may be absent)
    local out
    if [[ -n ${2:-} && -e $2 ]]; then
        out=${ _p_stat '%u %a %s %Y' '%u %Lp %z %m' "$1" "$2"; }
        AG_DIRSTAT=${out%%$'\n'*}
        if [[ $out == *$'\n'* ]]; then
            out=${out#*$'\n'}
                        # keep only the two fields the stamp is made of: size and mtime
            AG_BINSTAT=${out#* * }
        else
            AG_BINSTAT=''
        fi
    else
        AG_DIRSTAT=${ _p_stat '%u %a %s %Y' '%u %Lp %z %m' "$1"; }
        AG_BINSTAT=''
    fi
    return 0
}

# Deliberately NOT optimised. Free on Linux (/proc/mounts), forks `mount` on
# macOS/BSD.
#
# Skipping that rests on 9p/drvfs being Linux-only — an argument from
# likelihood, under a fail-closed guard. test_37 simulates it and expects refusal.
_fs_guard() {  # refuse corrupting filesystems, warn on network ones
    local fs; fs=${ _fs_type "$1"; }
    case $fs in
        9p|v9fs|drvfs)
            _fail "$AG_E_STORAGE" "refusing db dir on '$fs' (broken locking corrupts WAL; on WSL keep AG_DIR on the ext4 side)" ;;
        nfs*|smbfs|cifs)
            printf 'active-graph: warning: db dir on network fs (%s) - SQLite locking may be unreliable\n' "$fs" >&2 ;;
    esac
}

# =============================================================================
# sqlite discovery + capability probe (PLAN 1 / 8.6)
# =============================================================================
# The probe costs a whole sqlite3 process, ~7 ms of a ~50 ms open.
#
# Its answer changes only with the binary, so it is cached in the store and
# stamped with size and mtime.
#
# A downgrade at the same path misses the cache and is refused.
AG_PROBE_FILE=''
_sqlite_probe_cached() {  # -> 0 if the cache vouches for a usable binary
    local f="$AG_DIR/.sqlite-probe" cpath csize cmtime cver
    [[ -r $f ]] || return 1
    IFS=$'\t' read -r cpath csize cmtime cver < "$f" || return 1
    [[ -n $cpath && -x $cpath ]] || return 1
        # If the caller pinned a different binary, the cache is about the wrong file.
    [[ -z ${AG_SQLITE:-} || $AG_SQLITE == "$cpath" ]] || return 1
    [[ -n $AG_BINSTAT && $AG_BINSTAT == "$csize $cmtime" ]] || return 1
    (( ${ _ver_num "$cver"; } >= AG_SQLITE_MIN )) || return 1
    AG_SQLITE=$cpath AG_SQLITE_OK=1
    return 0
}
_sqlite_probe_remember() {  # $1 = binary, $2 = version
    [[ -d $AG_DIR && -w $AG_DIR ]] || return 0
    local st; st=${ _p_stat '%s %Y' '%z %m' "$1"; }
    [[ $st =~ ^[0-9]+\ [0-9]+$ ]] || return 0
    local f="$AG_DIR/.sqlite-probe"
    printf '%s\t%s\t%s\n' "$1" "${st// /$'\t'}" "$2" > "$f" 2>/dev/null || return 0
    chmod 600 "$f" 2>/dev/null || :
}

_sqlite_resolve() {
    [[ -n ${AG_SQLITE_OK:-} ]] && return 0
    _sqlite_probe_cached && return 0
    local cands=() c out ver p
    [[ -n ${AG_SQLITE:-} ]] && cands+=("$AG_SQLITE")
    cands+=(/opt/homebrew/opt/sqlite/bin/sqlite3 /usr/local/opt/sqlite/bin/sqlite3
            /home/linuxbrew/.linuxbrew/opt/sqlite/bin/sqlite3)
    p=${ command -v sqlite3 || :; }
    [[ -n $p ]] && cands+=("$p")
    cands+=(/usr/local/bin/sqlite3 /usr/bin/sqlite3)
    for c in "${cands[@]}"; do
        [[ -x $c ]] || continue
        out=$("$c" -batch :memory: \
            "SELECT sqlite_version() || '|' || typeof(sha3('x',256)) || '|' || json_valid(jsonb('{}'),6) || '|' || length(coalesce(readfile('/dev/null'), x''));" \
            2>/dev/null) || continue
        ver=${out%%|*}
        [[ $out == *'|blob|1|'* ]] || continue
        (( ${ _ver_num "$ver"; } >= AG_SQLITE_MIN )) || continue
        AG_SQLITE=$c
        AG_SQLITE_OK=1
        _sqlite_probe_remember "$c" "$ver"
        return 0
    done
    _fail "$AG_E_STORAGE" "no sqlite3 >= 3.53.3 with sha3/readfile/jsonb found (run: setup; or set AG_SQLITE)"
}

# =============================================================================
# THE ENGINE — one long-lived sqlite3 process, three pipes
#
#   bash --[SQL]--> AG_FIN | rows --> AG_FOUT | errors --> AG_FERR
#
# stdout never closes, so _eng appends `SELECT 'AG_DONE:<nonce>:<n>'` and reads
# to it. Engines: 'w' writer, 'p' projection, 'r0..rN' readers.
#
# Wire invariants, each a confirmed bug:
#
#  I1. Terminator carries a per-process nonce; a literal marker let caller data
#      end the read early and consume another request's output.
#
#  I2. Errors use a separate fd; an "Error:" prefix test swallowed real values.
#
#  I3. Hostile or multi-line values use _getv (hex); raw text was truncated.
# =============================================================================
AG_NONCE=''
_engine_nonce() {  # once per process; unguessable by any client
    [[ -n $AG_NONCE ]] && return 0
    printf -v AG_NONCE '%04x%04x%04x%04x%x' \
        "$((RANDOM))" "$((RANDOM))" "$((RANDOM))" "$((RANDOM))" "$$"
}

declare -A AG_FERR=()   # engine -> stderr fd
declare -A AG_BINDF=()  # engine -> private bind scratch file

_engine_spawn() {  # $1=name $2=db-arg(path or file: URI) $3=init-sql
    local name=$1 db=$2 init=$3 fin fout ferr rc
    _engine_nonce
        # Set AG_ERR here, or the caller reports failure with an empty message —
        # how the broken projection rebuild presented: exit 1, nothing said.
    mkfifo "$AG_TMP/$name.in" "$AG_TMP/$name.out" "$AG_TMP/$name.err" 2>/dev/null \
        || { AG_ERR="cannot create engine fifos for '$name' in $AG_TMP"; return 1; }
    "$AG_SQLITE" -batch "$db" \
        < "$AG_TMP/$name.in" > "$AG_TMP/$name.out" 2> "$AG_TMP/$name.err" &
    AG_EPID[$name]=$!
        # O_RDWR on the error fifo so the reader never sees EOF between writes
    exec {fin}>"$AG_TMP/$name.in" {fout}<"$AG_TMP/$name.out" {ferr}<>"$AG_TMP/$name.err"
    AG_FIN[$name]=$fin AG_FOUT[$name]=$fout AG_FERR[$name]=$ferr
        # Only the handshake is bounded. A file that is not a database fails every
        # statement at PREPARE, terminator included.
        #
        # sqlite3 does not exit either (we hold its stdin), so every command hung.
        # Ordinary queries stay unbounded.
    AG_ENG_DEADLINE_S=$AG_ENG_HANDSHAKE_S
    _eng "$name" "$init"; rc=$?
    AG_ENG_DEADLINE_S=''
    if (( rc )) && [[ -z $AG_ERR || $AG_ERR == 'engine died'* ]]; then
        AG_ERR="engine did not answer within ${AG_ENG_HANDSHAKE_S}s ($db)"
    fi
    return $rc
}

# Tear ONE engine down: fds, process AND fifos, so the name can be respawned.
#
# A surviving fifo makes the respawn's mkfifo fail, so the rebuild fails.
_engine_drop() {  # $1 = engine name
    local name=$1
    [[ -n ${AG_EPID[$name]:-} ]] || return 0
    printf '.quit\n' >&"${AG_FIN[$name]}" 2>/dev/null || :
    exec {AG_FIN[$name]}>&- 2>/dev/null || :
    exec {AG_FOUT[$name]}<&- 2>/dev/null || :
    [[ -n ${AG_FERR[$name]:-} ]] && { exec {AG_FERR[$name]}<&- 2>/dev/null || :; }
    kill "${AG_EPID[$name]}" 2>/dev/null || :
    unset "AG_FIN[$name]" "AG_FOUT[$name]" "AG_FERR[$name]" "AG_EPID[$name]" \
          "AG_BINDF[$name]" "AG_RESF[$name]" "AG_ENG_MODE[$name]"
    rm -f "$AG_TMP/$name.in" "$AG_TMP/$name.out" "$AG_TMP/$name.err" \
          "$AG_TMP/bind.$name" "$AG_TMP/res.$name"
}

_engine_stop() {
    local name
    for name in "${!AG_EPID[@]}"; do
        printf '.quit\n' >&"${AG_FIN[$name]}" 2>/dev/null || :
        exec {AG_FIN[$name]}>&- 2>/dev/null || :
        exec {AG_FOUT[$name]}<&- 2>/dev/null || :
        [[ -n ${AG_FERR[$name]:-} ]] && { exec {AG_FERR[$name]}<&- 2>/dev/null || :; }
        kill "${AG_EPID[$name]}" 2>/dev/null || :
    done
    AG_FIN=() AG_FOUT=() AG_FERR=() AG_EPID=() AG_BINDF=() AG_RESF=()
}

# Drain the engine's stderr for the request just done. sqlite3 writes the
# diagnostic before the terminator, so the bytes are already there.
#
# `read -t 0` makes the no-error case free.
_eng_drain_err() {
    local fd=${AG_FERR[$1]:-} line
    [[ -n $fd ]] || return 0
    read -r -t 0 -u "$fd" 2>/dev/null || return 0
    while IFS= read -r -t 0.05 -u "$fd" line; do
        [[ -n $line ]] && AG_ERR+=$line$'\n'
    done
    return 0
}

# _eng <engine> <sql> -> rows in AG_OUT (one per line), errors in AG_ERR.
# Every template SELECT yields one column (JSON or scalar): NDJSON out.
_eng() {
    local e=$1 sql=$2 line term="AG_DONE:$AG_NONCE:$((++AG_SEQREQ))"
    AG_OUT='' AG_ERR=''
        # Unbounded by default: a legitimate query can run for minutes and a clock
        # is not a correctness signal. _engine_spawn sets this for the handshake only.
    local -a rd=(-r -u "${AG_FOUT[$e]}")
    [[ -n ${AG_ENG_DEADLINE_S:-} ]] && rd=(-t "$AG_ENG_DEADLINE_S" "${rd[@]}")
    printf '%s\nSELECT %s;\n' "$sql" "'$term'" >&"${AG_FIN[$e]}" 2>/dev/null \
        || { AG_ERR='engine pipe closed'; return 70; }
        # AG_MAX_RESULT bounds the result BUFFER, not the response: capping the
        # finished string is too late.
        #
        # Over budget, keep reading to the terminator (dropping out desyncs the
        # engine) but stop accumulating.
    local -i got=0 over=0
    while IFS= read "${rd[@]}" line; do
        if [[ $line == "$term" ]]; then
            _eng_drain_err "$e"
            if (( over )); then
                AG_OUT=''
                AG_ERR="result exceeds AG_MAX_RESULT ($AG_MAX_RESULT bytes); narrow the query or paginate"$'\n'
                return 1
            fi
            if [[ -z $AG_ERR ]]; then return 0; else return 1; fi
        fi
        if [[ -n $line ]]; then
            if (( over )); then continue; fi
            got+=${#line}+1
            if (( got > AG_MAX_RESULT )); then over=1; AG_OUT=''; continue; fi
            AG_OUT+=$line$'\n'
        fi
    done
    _eng_drain_err "$e"
    AG_ERR=${AG_ERR:-'engine died'}
    return 70
}

# `${v%%$'\n'*}` is QUADRATIC: suffix removal searches position by position.
#
# 38 s on a 480 KB single-line value, 4 ms when the newline is early.
#
# That is the JSON-RPC envelope, and why one reply took ~3 s. `read` is linear.
_first_line_v() {  # $1 = value -> its first line in REPLY
    if (( ${#1} > 4096 )); then
        REPLY=''; IFS= read -r REPLY <<< "$1"
    else
        REPLY=${1%%$'\n'*}
    fi
}
_first_line() {  # $1 = value ; prints its first line
    _first_line_v "$1"; printf '%s' "$REPLY"
}

_scalar() {  # _scalar <engine> <sql> -> prints first output line
    _eng "$1" "$2" || return $?
    _first_line "$AG_OUT"
}

# _sc <engine> <sql> -> first output line in REPLY.
#
# Only the return path differs from _scalar, and it costs more than the query:
# stdout capture 364 us, `${| _sc ...; }` 178 us.
#
# REPLY is cleared FIRST, so an early return cannot hand this caller the
# previous one's answer.
_sc() {  # _sc <engine> <sql> -> REPLY
    REPLY=''
    _eng "$1" "$2" || return $?
    _first_line_v "$AG_OUT"
}

# _engf <engine> <sql> — _eng's contract, rows returned through a FILE.
#
# Bash reads a pipe ONE BYTE AT A TIME (a shared fd must not over-read).
#
# 800 events / 563 KB: 350 ms off the fifo, 2 ms from a file, <1 ms of SQL.
#
# The engine `.output`s rows to a private file; only the terminator uses the
# fifo, so framing is untouched. _eng stays right for single-value chatter.
#
# Safe because _engf only gets SQL we wrote: external text arrives as bound
# parameters, and operator SQL goes to `scan`, which refuses dot-commands.
declare -A AG_RESF=()   # engine -> private result file
_engf() {  # _engf <engine> <sql> -> rows in AG_OUT
    local e=$1
    local f=${AG_RESF[$e]:-}
    if [[ -z $f ]]; then f="$AG_TMP/res.$e"; AG_RESF[$e]=$f; fi
        # A failed `.output` is reported on stderr and leaves the engine writing to
        # stdout, so _eng returns non-zero rather than this reading a stale file.
    _eng "$e" ".output '${f//\'/\'\'}'
$2
.output" || return $?
        # Cap checked against the file, BEFORE the bytes enter the shell — stricter
        # than _eng's running total, which spent the RAM before rejecting the row.
    local n; n=${ _p_fsize "$f"; }
    if [[ $n =~ ^[0-9]+$ ]] && (( n > AG_MAX_RESULT )); then
        AG_OUT=''
        AG_ERR="result exceeds AG_MAX_RESULT ($AG_MAX_RESULT bytes); narrow the query or paginate"$'\n'
        return 1
    fi
        # `read -d ''` slurps the file in one builtin, forking nothing and keeping
        # the trailing newline AG_OUT's contract needs.
        #
        # It stops at NUL, which SQLite's text output cannot contain.
    AG_OUT=''
    IFS= read -r -d '' AG_OUT < "$f" || :
    return 0
}

# The one-BIG-row case: `diff` and `insights` return a single json_object of
# hundreds of kilobytes. One row, but 200,000 one-byte reads off the fifo.
_scalarf() {  # _scalarf <engine> <sql> -> prints first output line
    _engf "$1" "$2" || return $?
        # Straight off the result file: one line read, no copy of the other 480 KB.
    local first=''
    IFS= read -r first < "${AG_RESF[$1]}" || :
    printf '%s' "$first"
}

# _getv <engine> <expr> -> exact value in REPLY (invariant I3).
#
# The result rides the wire hex-encoded, so newlines and terminator lookalikes
# in DATA cannot influence framing.
_unhex() {
    local h=$1
    local out='' i n=${#h}       # split: ${#h} would expand before `local h` binds
    REPLY=''
    (( n )) || return 0
    for (( i=0; i<n; i+=2 )); do out+="\\x${h:i:2}"; done
    printf -v REPLY '%b' "$out"
}
_getv() {
    local h
    h=${| _sc "$1" "SELECT coalesce(lower(hex(CAST((${2}) AS BLOB))), '');"; } \
        || { REPLY=''; return 1; }
    [[ $h =~ ^[0-9a-f]*$ ]] || { REPLY=''; return 1; }
    _unhex "$h"
}

# ---- parameter binding: values NEVER appear in SQL text --------------------
#
# SQL is a fixed template; data is a named parameter.
#
# Concatenating has already gone wrong here: an object's own data was pasted
# back into a query and ran writefile().
#
#   _bindv   short, shape-validated. One round trip, '' doubled.
#
#   _bindval user/LLM-authored or large: written to a scratch file the engine
#            readfile()s, so bytes never touch SQL text. Use if unsure.
#
#   _getv    the read direction, hex-encoded (see I3).
_bindv() {  # _bindv <engine> <:name> <value>
    local v=${3//\'/\'\'}
    _eng "$1" "INSERT OR REPLACE INTO temp.sqlite_parameters(key,value) VALUES('$2','$v');"
}
# Tier 2: payloads, RPC bodies, anything large.
#
# Deliberately not a pipeline: `printf >file` is a builtin plus a redirection,
# zero forks.
#
# The old `printf | _bindf` forked subshell + cat + mktemp + rm per value.
_bindval() {  # _bindval <engine> <:name> <value>
        # NOTE: `local e=$1 f=${AG_BINDF[$e]:-}` would expand $e before `local e`
        # takes effect (bash expands all words first), yielding an empty subscript.
    local e=$1
    local f=${AG_BINDF[$e]:-}
    if [[ -z $f ]]; then f="$AG_TMP/bind.$e"; AG_BINDF[$e]=$f; fi
    printf '%s' "$3" > "$f" 2>/dev/null || { AG_ERR='bind write failed'; return 1; }
    _eng "$e" "INSERT OR REPLACE INTO temp.sqlite_parameters(key,value)
               VALUES('$2', CAST(readfile('${f//\'/\'\'}') AS TEXT));"
}

# ---- write transactions with bounded jittered retry (PLAN 8.3) --------------
_txn_begin() {
    local d
    for d in 0 47 103 251 509 997; do
        (( d )) && _nap "0.$(printf '%03d' "$d")"
        _eng w 'BEGIN IMMEDIATE;' && return 0
        [[ $AG_ERR == *'database is locked'* || $AG_ERR == *SQLITE_BUSY* ]] || return 1
    done
    _fail "$AG_E_BUSY" 'database busy'
}
_txn_commit()   { _eng w 'COMMIT;'; }
# F6: preserve AG_ERR/AG_OUT across the rollback — _eng clears them on entry, so
# `_txn_rollback; use $AG_ERR` read empty, misclassifying constraint errors.
_txn_rollback() { local _e=$AG_ERR _o=$AG_OUT; _eng w 'ROLLBACK;' 2>/dev/null || :; AG_ERR=$_e AG_OUT=$_o; }
_proj_rollback() { local _e=$AG_ERR _o=$AG_OUT; _eng p 'ROLLBACK;' 2>/dev/null || :; AG_ERR=$_e AG_OUT=$_o; }

# =============================================================================
# THE SCHEMA — three databases
#
#   ag-catalog.db  runs, segments, behaviours, interned names, config. `main`.
#   seg-NNNNNN.db  run_events + blobs. Where the data is.
#   ag-proj.db     ag_nodes + ag_edges. Derived, disposable.
#
#   tid/aid            type and actor interned to integers; the map lives in
#                      the catalog, so ids mean the same in every segment.
#
#   WITHOUT ROWID      run_events clustered by (rid,seq): in-order reads are
#                      sequential, with no second hidden index.
#
#   STRICT             a string in an INTEGER column is an error.
#
#   partial indexes    queries must repeat the WHERE or SQLite ignores them.
#
#   generated columns  cost_usd/tokens/dur_ms computed from ctx, no storage.
#                      tool_name/model are real: a large payload moves to
#                      blobs, and a generated column would read NULL.
#
# Executed verbatim by _store_create.
# =============================================================================
readonly AG_DDL_CATALOG="
PRAGMA user_version = $AG_SCHEMA_VERSION;
CREATE TABLE runs (
    rid        INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id     TEXT    NOT NULL UNIQUE,
    seg_id     INTEGER NOT NULL REFERENCES segments(seg_id),
    parent_rid INTEGER REFERENCES runs(rid) ON DELETE RESTRICT,
    fork_seq   INTEGER,
    goal       TEXT    NOT NULL DEFAULT '',
    status     TEXT    NOT NULL DEFAULT 'live'
               CHECK (status IN ('live','done','failed','forked','purged')),
    started_ms INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec')*1000 AS INTEGER)),
    ended_ms   INTEGER,
    env        ANY     NOT NULL DEFAULT '{}',
    tags       ANY     NOT NULL DEFAULT '[]',
    chain_seed BLOB,
    CHECK (chain_seed IS NULL OR length(chain_seed) = 32),
    CHECK ((parent_rid IS NULL) = (fork_seq IS NULL)),
    CHECK (fork_seq IS NULL OR fork_seq >= 0),
    CHECK (ended_ms IS NULL OR ended_ms >= started_ms),
    CHECK (json_valid(env, 6)), CHECK (json_valid(tags, 6))
) STRICT;
CREATE INDEX idx_runs_parent ON runs(parent_rid) WHERE parent_rid IS NOT NULL;
CREATE INDEX idx_runs_seg    ON runs(seg_id, status);
CREATE TABLE segments (
    seg_id      INTEGER PRIMARY KEY,
    path        TEXT    NOT NULL,
    state       TEXT    NOT NULL DEFAULT 'active' CHECK (state IN
                ('active','draining','sealing','sealed','archived','quarantined','dropped')),
    created_ms  INTEGER NOT NULL,
    sealed_ms   INTEGER,
    size_bytes  INTEGER,
    file_sha3   BLOB CHECK (file_sha3 IS NULL OR length(file_sha3) = 32),
    run_count   INTEGER,
    event_count INTEGER
) STRICT;
CREATE TABLE event_types (tid INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE) STRICT;
INSERT INTO event_types VALUES (1,'run.started'),(2,'run.ended'),(3,'pack.loaded'),
 (4,'goal.created'),(6,'llm.requested'),(7,'llm.responded'),(8,'tool.requested'),
 (9,'tool.responded'),(10,'object.created'),(11,'object.updated'),
 (12,'relation.created'),(13,'behavior.started'),(14,'behavior.completed'),
 (15,'frame.opened'),(16,'frame.closed'),(17,'finding.recorded');
CREATE TABLE actors (aid INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE) STRICT;
INSERT INTO actors VALUES (1,'runtime'),(2,'user'),(3,'llm');
CREATE TABLE seg_stats (
    seg_id INTEGER NOT NULL, dim TEXT NOT NULL, key TEXT NOT NULL,
    n INTEGER NOT NULL, cost_usd REAL, tokens INTEGER, dur_ms_sum INTEGER,
    PRIMARY KEY (seg_id, dim, key)
) STRICT, WITHOUT ROWID;
CREATE TABLE config (key TEXT PRIMARY KEY, value ANY) STRICT, WITHOUT ROWID;
-- Behaviour subscriptions (paper section 3): 'a behavior is a reaction. It
-- declares a subscription - an event type plus an optional predicate and a
-- graph-shape pattern expressed in a Cypher subset - and a body.' The registry
-- is global (catalog), because a subscription is not a property of one run.
CREATE TABLE behaviors (
    bid        INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    on_type    TEXT NOT NULL,            -- triggering event type ('' = any)
    pattern    TEXT NOT NULL DEFAULT '', -- graph shape, e.g. (c:claim)-[:addresses]->(q:question)
    where_expr TEXT NOT NULL DEFAULT '', -- predicate over the matched nodes' data
    absent     TEXT NOT NULL DEFAULT '', -- negative edge guard, e.g. q-[:answered_by]->
    argv       TEXT NOT NULL,            -- body: argv array, executed as an array (never eval)
    enabled    INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
    created_ms INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec')*1000 AS INTEGER)),
    CHECK (json_valid(argv) AND json_type(argv) = 'array')
) STRICT;
"

# Segment DDL parameterized by attach alias: the stored schema is
# alias-independent, so all segments share one fingerprint.
_ddl_segment() {  # $1 = attach alias (e.g. s1)
    local a=$1
    printf '%s' "
PRAGMA $a.user_version = $AG_SCHEMA_VERSION;
CREATE TABLE $a.run_events (
    rid       INTEGER NOT NULL,
    seq       INTEGER NOT NULL CHECK (seq >= 1),
    tid       INTEGER NOT NULL,
    aid       INTEGER NOT NULL,
    caused_by INTEGER CHECK (caused_by IS NULL OR (caused_by >= 1 AND caused_by < seq)),
    payload   ANY,
    body_ref  BLOB,
    ctx       ANY,
    hash      BLOB,
    chain     BLOB,
    idem      TEXT,
    tool_name TEXT,
    model     TEXT,
    req_hash  BLOB,        -- schema v2. On responded events (tid 7,9): the hash
                           -- of the REQUEST this response answers, so the cache
                           -- can be probed the way the paper describes.
    obj_kind  TEXT,        -- schema v2. tid 10: payload.kind / tid 15: frames.
    obj_n     INTEGER,     -- schema v2. The ordinal minted into the id, so the
                           -- next one is an index probe, not a lineage scan.
    ts_ms     INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec')*1000 AS INTEGER)),
    PRIMARY KEY (rid, seq),
    CHECK ((payload IS NULL) <> (body_ref IS NULL)),
    CHECK (payload IS NULL OR json_valid(payload, 6)),
    CHECK (body_ref IS NULL OR length(body_ref) = 32),
    CHECK (ctx IS NULL OR json_valid(ctx, 6)),
    CHECK (hash IS NULL OR length(hash) = 32),
    CHECK (req_hash IS NULL OR length(req_hash) = 32),
    CHECK (chain IS NULL OR length(chain) = 32),
    CHECK (obj_n IS NULL OR obj_n >= 1)
) STRICT, WITHOUT ROWID;
CREATE TABLE $a.blobs (
    hash BLOB PRIMARY KEY CHECK (length(hash) = 32),
    sz   INTEGER NOT NULL,
    body BLOB NOT NULL
) STRICT, WITHOUT ROWID;
ALTER TABLE $a.run_events ADD COLUMN cost_usd REAL
    GENERATED ALWAYS AS (ctx ->> '\$.estimated_cost_usd') VIRTUAL;
ALTER TABLE $a.run_events ADD COLUMN tokens_total INTEGER
    GENERATED ALWAYS AS (ctx ->> '\$.usage.total_tokens') VIRTUAL;
ALTER TABLE $a.run_events ADD COLUMN dur_ms INTEGER
    GENERATED ALWAYS AS (ctx ->> '\$.dur_ms') VIRTUAL;
CREATE INDEX $a.idx_re_type   ON run_events(rid, tid);
CREATE INDEX $a.idx_re_hash   ON run_events(hash, tid)      WHERE tid IN (7,9);
CREATE INDEX $a.idx_re_tool   ON run_events(tool_name, tid) WHERE tid IN (8,9);
CREATE INDEX $a.idx_re_model  ON run_events(model, tid)     WHERE tid IN (6,7);
CREATE INDEX $a.idx_re_caused ON run_events(rid, caused_by) WHERE caused_by IS NOT NULL;
CREATE UNIQUE INDEX $a.idx_re_idem ON run_events(rid, idem) WHERE idem IS NOT NULL;
CREATE INDEX $a.idx_re_reqhash ON run_events(req_hash, tid) WHERE tid IN (7,9);
CREATE INDEX $a.idx_re_objn ON run_events(rid, obj_kind, obj_n) WHERE obj_n IS NOT NULL;
"
}

# Schema fingerprint (PLAN 8.5b). Excludes sqlite_% tables: ANALYZE creates
# sqlite_stat1 at runtime, and including it made a store fail to reopen.
_schema_sha3() {  # $1 = engine, $2 = schema name (main|seg)
    _scalar "$1" "SELECT lower(hex(sha3(coalesce((SELECT group_concat(sql, char(10) ORDER BY name) FROM $2.sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'), ''), 256)));"
}

# =============================================================================
# OPENING A STORE — never trusted blindly
#
# ag_open is idempotent. On an existing store `user_version` and a fingerprint
# of the CREATE statements must both match what creation recorded.
#
# A mismatch means drift or tampering, and we refuse to run.
# =============================================================================
_engine_init_sql() {  # $1 = ro|rw
        # ORDER MATTERS: changing temp_store DROPS existing temp tables, so it runs
        # BEFORE `.parameter init` creates temp.sqlite_parameters (test_01).
        #
        # cache_size is a TIER: the writer gets AG_CACHE_KB, rpc-children drop to
        # 32 MiB so max-children x cache is not a RAM bomb (caveat 5).
    local common="PRAGMA busy_timeout=5000;
PRAGMA temp_store=MEMORY;
PRAGMA cache_size=-$AG_CACHE_KB;
PRAGMA mmap_size=1073741824;
PRAGMA trusted_schema=OFF;
${AG_HEAP_ON:+PRAGMA hard_heap_limit=$AG_HEAP_LIMIT;}"
    if [[ $1 == rw ]]; then
        printf '%s\nPRAGMA foreign_keys=ON;\nPRAGMA synchronous=NORMAL;\nPRAGMA wal_autocheckpoint=4000;\nPRAGMA journal_size_limit=67108864;\n.mode list\n.parameter init\n.dbconfig defensive on\n' "$common"
    else
                # Readers are read-only at the FILE level, so data writes already fail.
                #
                # Do NOT add `PRAGMA query_only=ON`: it also blocks temp writes, breaking
                # _bindv's temp.sqlite_parameters and silently unbinding :run.
        printf '%s\n.mode list\n.parameter init\n.dbconfig defensive on\n' "$common"
    fi
}

# =============================================================================
# THE SEGMENT ROUTER — which .db files does this query need?
#
# A run's query needs its segment plus every ancestor it forked from, and ATTACH
# is limited to ~10. This is an LRU of segment->engine attachments.
#
# _route_run attaches the lineage's segments and rebuilds the TEMP views
# v_run_events and v_blobs to UNION whatever is attached now.
#
# Reads say "FROM v_run_events" and never name a file. Writes cannot INSERT
# into a UNION view, so they name their segment (s42.run_events).
# =============================================================================
declare -A AG_ATT=()          # "engine\tsegid" -> last-use tick
declare -A AG_ENG_MODE=()     # engine -> rw|ro (whether it may attach RW)
declare -i AG_TICK=0
: "${AG_ATTACH_BUDGET:=8}"    # sealed/LRU-evictable slots per engine
AG_ACTIVE_SEG=''             # current active segment id (new runs pin here)

_seg_pad() { printf 'seg-%06d.db' "$1"; }        # seg_id -> filename

_rebuild_views() {  # $1 = engine ; rebuild v_run_events / v_blobs over its attaches
    local e=$1 key re='' bl=''
    for key in "${!AG_ATT[@]}"; do
        [[ $key == "$e"$'\t'* ]] || continue
        local sid=${key#*$'\t'}
        re+="${re:+ UNION ALL }SELECT * FROM s${sid}.run_events"
        bl+="${bl:+ UNION ALL }SELECT * FROM s${sid}.blobs"
    done
    [[ -n $re ]] || return 0
    _eng "$e" "DROP VIEW IF EXISTS v_run_events; DROP VIEW IF EXISTS v_blobs;
CREATE TEMP VIEW v_run_events AS $re;
CREATE TEMP VIEW v_blobs AS $bl;"
}

_seg_evict_lru() {  # $1 = engine, $2 = set of segids to keep (space-delimited)
    local e=$1 keep=" $2 " key oldest='' otick=0 sid
    for key in "${!AG_ATT[@]}"; do
        [[ $key == "$e"$'\t'* ]] || continue
        sid=${key#*$'\t'}
        [[ $keep == *" $sid "* ]] && continue          # never evict a required seg
        [[ $sid == "$AG_ACTIVE_SEG" ]] && continue      # never evict the active seg
        if [[ -z $oldest ]] || (( AG_ATT[$key] < otick )); then oldest=$sid; otick=${AG_ATT[$key]}; fi
    done
    [[ -n $oldest ]] || return 1
        # DETACH fails inside a txn (verified) — that is the safety guard; caller
        # only evicts between operations.
    _eng "$e" "DETACH s${oldest};" || return 1
    unset "AG_ATT[$e"$'\t'"$oldest]"
    return 0
}

_seg_require() {  # $1 = engine ; rest = segids the next query needs attached
    local e=$1; shift
    local changed=0 sid meta path state alias want
    local attached_count=0 key
    for key in "${!AG_ATT[@]}"; do [[ $key == "$e"$'\t'* ]] && (( attached_count++ )); done
    for sid in "$@"; do
        (( AG_TICK++ ))
        if [[ -n ${AG_ATT[$e$'\t'$sid]:-} ]]; then AG_ATT[$e$'\t'$sid]=$AG_TICK; continue; fi
                # evict beyond budget (never the active seg or one we still need)
        while (( attached_count >= AG_ATTACH_BUDGET )); do
            _seg_evict_lru "$e" "$*" || break
            (( attached_count-- ))
        done
        meta=${| _sc "$e" "SELECT path || '|' || state FROM segments WHERE seg_id = $sid;"; }
        [[ -n $meta ]] || { _fail "$AG_E_STORAGE" "unknown segment $sid"; return 1; }
        path=${meta%%|*}; state=${meta##*|}
        [[ -f $path ]] || { _fail "$AG_E_STORAGE" "segment file missing: $path"; return 1; }
        local pq=${path//\'/\'\'} a="s${sid}"
        case $state in
            active|draining)
                if [[ ${AG_ENG_MODE[$e]} == rw ]]; then _eng "$e" "ATTACH '${pq}' AS $a;"
                else _eng "$e" "ATTACH 'file:${pq}?mode=ro' AS $a;"; fi ;;
            sealed|archived) _eng "$e" "ATTACH 'file:${pq}?immutable=1' AS $a;" ;;
            sealing) _fail "$AG_E_BUSY" "segment $sid is being sealed; retry"; return 1 ;;
            quarantined|dropped) _fail "$AG_E_STORAGE" "segment $sid is $state"; return 1 ;;
            *) _fail "$AG_E_STORAGE" "segment $sid in unexpected state '$state'"; return 1 ;;
        esac || {
                        # MAX_ATTACHED=10 ceiling: a lineage spanning >10 segments cannot
                        # attach at once. v1 does not do multi-pass reads (PLAN 7.3 caveat).
            if [[ $AG_ERR == *'too many attached'* ]]; then
                _fail "$AG_E_STORAGE" "run lineage spans too many segments (>10) to attach at once; deep fork chains across many rollovers are a v1 limitation"
            else
                _fail "$AG_E_STORAGE" "attach segment $sid failed: ${AG_ERR%%$'\n'*}"
            fi
            return 1
        }
        AG_ATT[$e$'\t'$sid]=$AG_TICK; changed=1; (( attached_count++ ))
    done
    (( changed )) && { _rebuild_views "$e" || return 1; }
    return 0
}

# segids a run's lineage spans (own segment + all fork ancestors'). Runs on any
# engine that can see catalog.runs/segments.
_seg_for_run() {  # $1 = engine ; :run must be bound ; prints space-separated segids
    _scalar "$1" "WITH RECURSIVE lin(rid) AS (
        SELECT rid FROM runs WHERE run_id = :run
        UNION ALL SELECT r.parent_rid FROM runs r JOIN lin ON r.rid = lin.rid WHERE r.parent_rid IS NOT NULL)
    SELECT group_concat(DISTINCT seg_id) FROM runs WHERE rid IN (SELECT rid FROM lin);" \
        | tr ',' ' '
}

_seg_of_run() {  # $1 = engine ; :run bound ; the run's pinned segid in REPLY
    _sc "$1" "SELECT seg_id FROM runs WHERE run_id = :run;"
}

# ensure every lineage segment of :run (already bound on $1) is attached to $1
_route_run() {  # $1 = engine ; :run must be bound
    local segids; segids=${ _seg_for_run "$1"; }
    [[ -n ${segids// /} ]] || return 0
        # segment ids are interpolated into SQL as identifiers (s<id>) and as
        # integers; assert the shape rather than trusting the catalog read.
    [[ $segids =~ ^[0-9]+( [0-9]+)*$ ]] \
        || { _fail "$AG_E_INTERNAL" 'malformed segment id list from catalog'; return 1; }
    _seg_require "$1" $segids
}

_store_create() {
    local seg="$AG_DIR/$(_seg_pad 1)" segq
    segq=${seg//\'/\'\'}
    _eng w 'PRAGMA page_size=8192; PRAGMA auto_vacuum=INCREMENTAL;' || return 1
    _eng w 'PRAGMA journal_mode=WAL;' || return 1
    _eng w "$AG_DDL_CATALOG" || { _fail "$AG_E_INTERNAL" "catalog DDL failed: $AG_ERR"; return 1; }
    _eng w "ATTACH '$segq' AS s1;
PRAGMA s1.page_size=8192; PRAGMA s1.auto_vacuum=INCREMENTAL;" || return 1
    _eng w 'PRAGMA s1.journal_mode=WAL;' || return 1
    _eng w "${ _ddl_segment s1; }" || { _fail "$AG_E_INTERNAL" "segment DDL failed: ${AG_ERR%%$'\n'*}"; return 1; }
    _bindv w :sp "$seg" || return 1
    _eng w "INSERT INTO segments(seg_id, path, state, created_ms)
            VALUES (1, :sp, 'active', CAST(unixepoch('subsec')*1000 AS INTEGER));" || return 1
    local ch sh
    ch=${ _schema_sha3 w main; } || return 1
    sh=${ _schema_sha3 w s1; }   || return 1
    _eng w "INSERT INTO config(key,value) VALUES
            ('catalog_schema_sha3','$ch'),
            ('segment_schema_sha3','$sh'),
            ('file_hash_algo','${AG_FILE_HASH_ALGO:-none}'),
            ('ag_version','$AG_VERSION'),
            ('created_ms', CAST(unixepoch('subsec')*1000 AS INTEGER));" || return 1
    _eng w '.dbconfig defensive on' || :
    AG_ATT[w$'\t'1]=$(( ++AG_TICK )); AG_ACTIVE_SEG=1
    _rebuild_views w || return 1
    return 0
}

_store_check() {  # existing store: fail-closed schema verification (PLAN 8.5b)
    local uv ch want
    uv=${| _sc w 'PRAGMA user_version;'; }
    if [[ $uv != "$AG_SCHEMA_VERSION" ]]; then
        _fail "$AG_E_SCHEMA" "catalog user_version=$uv, expected $AG_SCHEMA_VERSION (migrate needed)"; return 1
    fi
    want=${| _sc w "SELECT coalesce((SELECT value FROM config WHERE key='catalog_schema_sha3'),'');"; }
    ch=${ _schema_sha3 w main; }
    if [[ -z $want || $ch != "$want" ]]; then
        _fail "$AG_E_SCHEMA" "catalog schema fingerprint mismatch (drift or tamper) in $AG_DIR/ag-catalog.db"; return 1
    fi
    local asid sp spq
    asid=${| _sc w "SELECT seg_id FROM segments WHERE state='active' ORDER BY seg_id DESC LIMIT 1;"; }
    [[ -n $asid ]] || { _fail "$AG_E_SCHEMA" 'no active segment in catalog'; return 1; }
    sp=${| _sc w "SELECT path FROM segments WHERE seg_id = $asid;"; }
    [[ -f $sp ]] || { _fail "$AG_E_STORAGE" "active segment file missing: $sp"; return 1; }
    spq=${sp//\'/\'\'}
    _eng w "ATTACH '$spq' AS s${asid};" || { _fail "$AG_E_STORAGE" "cannot attach segment: $AG_ERR"; return 1; }
    uv=${| _sc w "PRAGMA s${asid}.user_version;"; }
    [[ $uv == "$AG_SCHEMA_VERSION" ]] || { _fail "$AG_E_SCHEMA" "segment user_version=$uv, expected $AG_SCHEMA_VERSION"; return 1; }
    want=${| _sc w "SELECT value FROM config WHERE key='segment_schema_sha3';"; }
    ch=${ _schema_sha3 w "s${asid}"; }
    [[ $ch == "$want" ]] || { _fail "$AG_E_SCHEMA" "segment schema fingerprint mismatch in $sp"; return 1; }
        # sealed-segment digests are only comparable under the algorithm that wrote them
    want=${| _sc w "SELECT coalesce((SELECT value FROM config WHERE key='file_hash_algo'),'sha256');"; }
    [[ $want == "${AG_FILE_HASH_ALGO:-none}" ]] || {
        _fail "$AG_E_SCHEMA" "store was sealed with file hash '$want' but this host provides '${AG_FILE_HASH_ALGO:-none}' (install sha256sum/shasum/openssl)"; return 1; }
    _eng w '.dbconfig defensive on' || :
    AG_ATT[w$'\t'$asid]=$(( ++AG_TICK )); AG_ACTIVE_SEG=$asid
    _rebuild_views w || return 1
    return 0
}

# =============================================================================
# rollover (PLAN 7.2): the active segment fills, a new one takes NEW runs.
#
# The old drains until its live runs end, then seals. A run never spans segments.
# =============================================================================
_rollover() {  # cross-process serialized; re-validates under the lock
        # mkdir is an atomic POSIX mutex (flock unavailable, PLAN 1).
        #
        # Without it two racing processes each allocate max+1 and drain the other's
        # active, leaving TWO active segments (found by black-box attack).
    local lock="$AG_DIR/.rollover.lock" held=0 i
    for i in $(seq 1 200); do
        if mkdir "$lock" 2>/dev/null; then
                        # record the holder so a crash mid-rollover is reapable (below)
            printf '%s' "$$" > "$lock/pid" 2>/dev/null || :
            held=1; break
        fi
                # contended: the holder may be dead (kill -9'd between mkdir and rmdir),
                # which would otherwise wedge every future rollover forever. Reap it.
        _reap_rollover_lock "$lock"
        _nap 0.05
    done
    (( held )) || { _fail "$AG_E_BUSY" 'rollover lock contended'; return 1; }
    local rc=0
    _rollover_locked || rc=$?
    rm -f "$lock/pid" 2>/dev/null || :
    rmdir "$lock" 2>/dev/null || :
    return $rc
}

_reap_rollover_lock() {  # remove a rollover lock abandoned by a crashed holder
        # The mkdir(2) mutex is atomic but not self-healing: a holder kill -9'd
        # before its rmdir wedges every later rollover at BUSY.
        #
        # Reap only when the recorded pid is dead, or the dir predates the threshold.
    local lock=$1 pid mt now
    [[ -d $lock ]] || return 0
    pid=${ cat "$lock/pid" 2>/dev/null || :; }
        # Only a plausible pid (1..9999999) enters the liveness check.
        #
        # "0" signals our own process GROUP and always succeeds, so a truncated pid
        # file would read as a live holder and wedge forever.
    if [[ $pid =~ ^[1-9][0-9]{0,6}$ ]]; then
        kill -0 "$pid" 2>/dev/null && return 0        # holder alive: not stale
        rm -f "$lock/pid" 2>/dev/null || :
        rmdir "$lock" 2>/dev/null && _dbg "reaped stale rollover lock (dead holder $pid)"
        return 0
    fi
    mt=${ _p_mtime "$lock"; }
    now=${ printf '%(%s)T' -1; }
    [[ $mt =~ ^[0-9]+$ && $now =~ ^[0-9]+$ ]] || return 0
    (( now - mt >= AG_ROLLOVER_LOCK_STALE_S )) || return 0
    rm -f "$lock/pid" 2>/dev/null || :   # a garbage/truncated pid file would block rmdir
    rmdir "$lock" 2>/dev/null && _dbg "reaped stale rollover lock (aged, holder=${pid:-none})"
    return 0
}

_rollover_locked() {
        # A concurrent process may have already rolled — adopt its fresh active
        # instead of creating a redundant (and invariant-breaking) second one.
    local cur
    cur=${| _sc w "SELECT seg_id FROM segments WHERE state='active' ORDER BY seg_id DESC LIMIT 1;"; }
    [[ -n $cur ]] || { _fail "$AG_E_INTERNAL" 'no active segment during rollover'; return 1; }
    if [[ $cur != "$AG_ACTIVE_SEG" ]]; then
        AG_ACTIVE_SEG=$cur   # someone else rolled; adopt it, do not roll again
        return 0
    fi
        # still our active: re-check its size under the lock (the outer check in
        # _maybe_rollover is only an optimization to avoid taking the lock every run)
    local sz
    sz=${| _sc w "SELECT (SELECT * FROM pragma_page_count('s${AG_ACTIVE_SEG}')) * (SELECT * FROM pragma_page_size('s${AG_ACTIVE_SEG}'));"; }
    [[ $sz =~ ^[0-9]+$ ]] && (( sz > AG_SEG_MAX_BYTES )) || return 0
    local nid npath npq
    nid=${| _sc w 'SELECT coalesce(max(seg_id),0)+1 FROM segments;'; }
    npath="$AG_DIR/$(_seg_pad "$nid")"; npq=${npath//\'/\'\'}
    [[ -e $npath ]] && { _fail "$AG_E_STORAGE" "rollover target exists: $npath"; return 1; }
    _eng w "ATTACH '$npq' AS s${nid};
PRAGMA s${nid}.page_size=8192; PRAGMA s${nid}.auto_vacuum=INCREMENTAL;" \
        || { _fail "$AG_E_STORAGE" "rollover attach failed: ${AG_ERR%%$'\n'*}"; return 1; }
    _eng w "PRAGMA s${nid}.journal_mode=WAL;" || return 1
    _eng w "${ _ddl_segment "s${nid}"; }" || { _fail "$AG_E_INTERNAL" "rollover DDL: ${AG_ERR%%$'\n'*}"; return 1; }
        # atomic catalog flip: register new active, drain the old one
    _bindv w :np "$npath" || { _rollover_cleanup "$nid" "$npath"; return 1; }
    _txn_begin || { _rollover_cleanup "$nid" "$npath"; return 1; }
    _eng w "INSERT INTO segments(seg_id, path, state, created_ms)
            VALUES ($nid, :np, 'active', CAST(unixepoch('subsec')*1000 AS INTEGER));
            UPDATE segments SET state='draining' WHERE seg_id=$AG_ACTIVE_SEG AND state='active';" \
        || { local e=$AG_ERR; _txn_rollback; _rollover_cleanup "$nid" "$npath"; _fail "$AG_E_INTERNAL" "rollover catalog: ${e%%$'\n'*}"; return 1; }
    _txn_commit || { _txn_rollback; _rollover_cleanup "$nid" "$npath"; return 1; }
    AG_ATT[w$'\t'$nid]=$(( ++AG_TICK )); AG_ACTIVE_SEG=$nid
    _rebuild_views w || return 1
    _note "rolled over to segment $nid ($npath)"
    return 0
}

_rollover_cleanup() {  # $1=segid $2=path — detach + remove a partially-created segment
    _eng w "DETACH s${1};" 2>/dev/null || :
    unset "AG_ATT[w"$'\t'"${1}]"
    rm -f "$2" "$2-wal" "$2-shm" 2>/dev/null || :
}

_maybe_rollover() {  # cheap size check at run_start; propagates rollover failure
        # page_count*page_size is the LOGICAL size including uncheckpointed WAL
        # pages (stat of the .db misses those) and sidesteps the stat dialect split.
    local sz
    sz=${| _sc w "SELECT (SELECT * FROM pragma_page_count('s${AG_ACTIVE_SEG}')) * (SELECT * FROM pragma_page_size('s${AG_ACTIVE_SEG}'));"; }
    [[ $sz =~ ^[0-9]+$ ]] || return 0
    (( sz > AG_SEG_MAX_BYTES )) || return 0
    _rollover
}

# =============================================================================
# sealing (PLAN 7.2): a fully-drained segment becomes immutable forever, which
# makes TB maintenance tractable. Every step is idempotent, so a crash resumes.
# =============================================================================
_seal_segment() {  # $1 = segid ; writer engine. Returns 0 on seal (or already sealed).
    local sid=$1 path state live
    path=${| _sc w "SELECT path FROM segments WHERE seg_id=$sid;"; }
    [[ -n $path ]] || { _fail "$AG_E_NORUN" "unknown segment $sid"; return 1; }
    state=${| _sc w "SELECT state FROM segments WHERE seg_id=$sid;"; }
    [[ $state == sealed ]] && return 0
    [[ $state == draining || $state == sealing ]] || { _fail "$AG_E_PARAMS" "segment $sid is '$state', not sealable"; return 1; }
    live=${| _sc w "SELECT count(*) FROM runs WHERE seg_id=$sid AND status='live';"; }
    (( live == 0 )) || { _fail "$AG_E_PARAMS" "segment $sid has $live live run(s); cannot seal"; return 1; }

    _eng w "UPDATE segments SET state='sealing' WHERE seg_id=$sid;" || return 1
        # detach so no connection holds it, then compact via a fresh exclusive process
    if [[ -n ${AG_ATT[w$'\t'$sid]:-} ]]; then
        _eng w "DETACH s${sid};" 2>/dev/null || :
        unset "AG_ATT[w$'\t'$sid]"; _rebuild_views w
    fi
        # make writable in case a prior partial seal already chmod'd it
    chmod u+w "$path" 2>/dev/null || :
    "$AG_SQLITE" -batch "$path" \
        "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE; ANALYZE; PRAGMA optimize; VACUUM;" \
        >/dev/null 2>&1 || { _eng w "UPDATE segments SET state='draining' WHERE seg_id=$sid;"; _fail "$AG_E_STORAGE" "seal compaction failed for segment $sid"; return 1; }

        # rollups (read-only attach) — finalized now, correct forever (immutable)
    local aq=${path//\'/\'\'} ec rcnt
    _eng w "ATTACH 'file:${aq}?mode=ro' AS seal_src;" || return 1
    _eng w "DELETE FROM seg_stats WHERE seg_id=$sid;
INSERT INTO seg_stats(seg_id,dim,key,n,cost_usd,tokens,dur_ms_sum)
  SELECT $sid,'model',model,count(*),sum(cost_usd),sum(tokens_total),NULL
    FROM seal_src.run_events WHERE model IS NOT NULL AND tid IN(6,7) GROUP BY model
  UNION ALL
  SELECT $sid,'tool',tool_name,count(*),NULL,NULL,sum(dur_ms)
    FROM seal_src.run_events WHERE tool_name IS NOT NULL AND tid IN(8,9) GROUP BY tool_name
  UNION ALL
  SELECT $sid,'meta','events',(SELECT count(*) FROM seal_src.run_events),NULL,NULL,NULL
  UNION ALL
  SELECT $sid,'meta','blobs',(SELECT count(*) FROM seal_src.blobs),NULL,NULL,NULL;" \
        || { _eng w "DETACH seal_src;" 2>/dev/null; _fail "$AG_E_INTERNAL" "seal rollups: ${AG_ERR%%$'\n'*}"; return 1; }
    ec=${| _sc w "SELECT count(*) FROM seal_src.run_events;"; }
    _eng w "DETACH seal_src;" 2>/dev/null || :
    rcnt=${| _sc w "SELECT count(*) FROM runs WHERE seg_id=$sid;"; }

    local sh sz
    sh=${ _file_hash "$path"; }        # streaming; never loads the file into RAM
    [[ $sh =~ ^[0-9a-f]{64}$ ]] || { _fail "$AG_E_STORAGE" "seal hash failed for segment $sid"; return 1; }
    sz=${ _p_fsize "$path"; }
    chmod 400 "$path" 2>/dev/null || :
    _eng w "UPDATE segments SET state='sealed',
              sealed_ms=CAST(unixepoch('subsec')*1000 AS INTEGER),
              size_bytes=${sz:-NULL}, event_count=$ec, run_count=$rcnt,
              file_sha3=unhex('$sh')
            WHERE seg_id=$sid;" || return 1
    _note "sealed segment $sid ($path)"
    return 0
}

# segments fully drained (draining/sealing, no live runs) and thus sealable
_drainable_segments() {  # prints space-separated segids
    _scalar w "SELECT group_concat(seg_id,' ') FROM segments s
               WHERE s.state IN ('draining','sealing')
                 AND NOT EXISTS (SELECT 1 FROM runs r WHERE r.seg_id=s.seg_id AND r.status='live');"
}

ag_seal() {  # [--seg N | --all] : seal drained segment(s)
    local one=''
    while (( $# )); do case $1 in
        --seg) _optval "$@" || return 1; one=$REPLY; shift 2 ;;
        --all) shift ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    local -a sealed=() sids
    if [[ -n $one ]]; then
        _v_int "$one" || { _fail "$AG_E_PARAMS" 'invalid --seg'; return 1; }
        sids=("$one")
    else
        local list; list=${ _drainable_segments; }
        read -ra sids <<< "$list"
    fi
    local s
    for s in "${sids[@]}"; do
        [[ -n $s ]] || continue
        _seal_segment "$s" || return 1
        sealed+=("$s")
    done
    local out; printf -v out '%s,' "${sealed[@]}"
    printf '{"sealed":[%s]}\n' "${out%,}"
}

# =============================================================================
# integrity, drop, backup (PLAN 7.2, milestone 8d) — the payoff of immutability
# =============================================================================
ag_verify_files() {  # [--quarantine] : re-hash sealed segments vs catalog sha3
    local quarantine=0
    while (( $# )); do case $1 in
        --quarantine) quarantine=1; shift ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
        # One row per segment, read from AG_OUT: group_concat through _sc returns
        # only the FIRST LINE, so this loop silently ran for a single segment.
    _eng w "SELECT seg_id || '|' || path || '|' || lower(hex(file_sha3))
            FROM segments WHERE state IN ('sealed','archived') AND file_sha3 IS NOT NULL
            ORDER BY seg_id;" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    local rows=$AG_OUT
    local -a bad=() line sid path want got
    while IFS='|' read -r sid path want; do
        [[ -n $sid ]] || continue
        got=${ _file_hash "$path"; }
        if [[ $got != "$want" ]]; then
            bad+=("$sid")
            (( quarantine )) && _eng w "UPDATE segments SET state='quarantined' WHERE seg_id=$sid;"
        fi
    done <<< "$rows"
    local total; total=${| _sc w "SELECT count(*) FROM segments WHERE state IN ('sealed','archived') AND file_sha3 IS NOT NULL;"; }
    local blist; printf -v blist '%s,' "${bad[@]}"
    printf '{"checked":%s,"corrupt":[%s]%s}\n' "${total:-0}" "${blist%,}" \
           "$( (( quarantine && ${#bad[@]} )) && printf ',"quarantined":true' )"
    (( ${#bad[@]} == 0 ))
}

# drop sealed segments whose runs are ALL purged: reclaim TB in one unlink.
ag_drop_purged() {  # internal helper for maintain; prints dropped segids
        # One row per segment, read from AG_OUT: group_concat through _sc returns
        # only the FIRST LINE, so this loop silently ran for a single segment.
    _eng w "SELECT seg_id || '|' || path FROM segments s
            WHERE s.state='sealed'
              AND NOT EXISTS (SELECT 1 FROM runs r WHERE r.seg_id=s.seg_id AND r.status <> 'purged')
            ORDER BY seg_id;" || return 1
    local rows=$AG_OUT
    local -a dropped=() sid path
    while IFS='|' read -r sid path; do
        [[ -n $sid ]] || continue
                # only drop if the segment actually holds runs (never the active/empty ones)
        local nr; nr=${| _sc w "SELECT count(*) FROM runs WHERE seg_id=$sid;"; }
        (( nr > 0 )) || continue
        _eng w "UPDATE segments SET state='dropped' WHERE seg_id=$sid;" || continue
        chmod u+w "$path" 2>/dev/null || :
        rm -f "$path" "$path-wal" "$path-shm"
        dropped+=("$sid")
        _note "dropped segment $sid (all runs purged): $path"
    done <<< "$rows"
    printf '%s' "${dropped[*]}"
}

ag_backup() {  # <dest> : incremental — copy sealed files dest lacks + snapshot catalog/active
    local dest=${1:-}
    [[ -n $dest ]] || { _fail "$AG_E_PARAMS" 'usage: backup <dest-dir>'; return 1; }
    ag_open || return 1
    mkdir -p "$dest" || { _fail "$AG_E_STORAGE" "cannot create $dest"; return 1; }
        # One row per segment, read from AG_OUT: group_concat through _sc returns
        # only the FIRST LINE, so this loop silently ran for a single segment.
    _eng w "SELECT seg_id || '|' || path || '|' || lower(hex(file_sha3))
            FROM segments WHERE state IN ('sealed','archived') AND file_sha3 IS NOT NULL
            ORDER BY seg_id;" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    local rows=$AG_OUT
    local -a copied=() line sid path want dpath got
    while IFS='|' read -r sid path want; do
        [[ -n $sid ]] || continue
        dpath="$dest/$(_seg_pad "$sid")"
                # skip if the destination already has a byte-identical copy (incremental)
        if [[ -f $dpath ]]; then
            got=${ _file_hash "$dpath"; }
            [[ $got == "$want" ]] && continue
        fi
        cp "$path" "$dpath" || { _fail "$AG_E_STORAGE" "copy failed: $path"; return 1; }
        got=${ _file_hash "$dpath"; }
        [[ $got == "$want" ]] || { _fail "$AG_E_STORAGE" "copy verify FAILED for segment $sid (source may be corrupt)"; return 1; }
        chmod 400 "$dpath" 2>/dev/null || :
        copied+=("$sid")
    done <<< "$rows"
        # consistent hot snapshots of the small, mutable files (VACUUM INTO is atomic)
    local cq=${dest//\'/\'\'}
    rm -f "$dest/ag-catalog.db"
    _eng w "VACUUM main INTO '${cq}/ag-catalog.db';" || { _fail "$AG_E_STORAGE" "catalog snapshot failed: ${AG_ERR%%$'\n'*}"; return 1; }
    local aseg="$dest/$(_seg_pad "$AG_ACTIVE_SEG")"
    rm -f "$aseg"
    _eng w "VACUUM s${AG_ACTIVE_SEG} INTO '${cq}/$(_seg_pad "$AG_ACTIVE_SEG")';" || { _fail "$AG_E_STORAGE" "active snapshot failed: ${AG_ERR%%$'\n'*}"; return 1; }
    local clist; printf -v clist '%s,' "${copied[@]}"
    printf '{"dest":"%s","sealed_copied":[%s],"catalog_snapshot":true,"active_snapshot":%s}\n' \
           "$dest" "${clist%,}" "$AG_ACTIVE_SEG"
}

_reader_spawn() {  # $1 = index
    local i=$1 cat="$AG_DIR/ag-catalog.db"
    _engine_spawn "r$i" "file:${cat}?mode=ro" "${ _engine_init_sql ro; }" || return 1
    AG_ENG_MODE[r$i]=ro
    return 0
}

_engine_for_read() {  # engine name for read ops -> REPLY
    if (( AG_READERS > 0 )); then
        local i=$(( AG_RR % AG_READERS )); AG_RR+=1
        if [[ -z ${AG_EPID[r$i]:-} ]]; then
            _reader_spawn "$i" || { REPLY=w; return 0; }
        fi
        REPLY=r$i
    else
        REPLY=w
    fi
    return 0
}

# F5: numeric env config is interpolated into SQL; validate before any use so a
# malformed value fails closed instead of corrupting a query.
_v_config() {
    local k v
    for k in AG_BLOB_MIN AG_MAX_PAYLOAD AG_MAX_FRAME AG_LIMIT_MAX AG_LIMIT_DEFAULT \
             AG_MAX_CHILDREN AG_READERS AG_REQ_DEADLINE_S AG_SEG_MAX_BYTES \
             AG_MAX_RESP AG_MAX_BATCH AG_CACHE_KB AG_HEAP_LIMIT AG_ACCESS_LOG_MAX \
             AG_RUN_GRACE_S AG_AUTH_COOLDOWN_S AG_MAX_RESULT AG_BEHAVIOR_TIMEOUT_S \
             AG_REACT_MAX_ROUNDS AG_AUTH_WINDOW_S AG_AUTH_MAX_FAILS \
             AG_ENG_HANDSHAKE_S; do
        v=${!k}
        [[ $v =~ ^[0-9]+$ ]] || { _fail "$AG_E_PARAMS" "config $k must be a non-negative integer (got '$v')"; return 1; }
    done
    [[ $AG_CHAIN == 0 || $AG_CHAIN == 1 ]] || { _fail "$AG_E_PARAMS" "AG_CHAIN must be 0 or 1 (got '$AG_CHAIN')"; return 1; }
    [[ $AG_ALLOW_EXPLICIT_ID == 0 || $AG_ALLOW_EXPLICIT_ID == 1 ]] \
        || { _fail "$AG_E_PARAMS" "AG_ALLOW_EXPLICIT_ID must be 0 or 1 (got '$AG_ALLOW_EXPLICIT_ID')"; return 1; }
    (( AG_MAX_BATCH >= 1 )) || { _fail "$AG_E_PARAMS" 'AG_MAX_BATCH must be >= 1'; return 1; }
    (( AG_REQ_DEADLINE_S >= 1 )) || { _fail "$AG_E_PARAMS" 'AG_REQ_DEADLINE_S must be >= 1'; return 1; }
    (( AG_ENG_HANDSHAKE_S >= 1 )) || { _fail "$AG_E_PARAMS" 'AG_ENG_HANDSHAKE_S must be >= 1'; return 1; }
    (( AG_LIMIT_DEFAULT >= 1 && AG_LIMIT_DEFAULT <= AG_LIMIT_MAX )) || { _fail "$AG_E_PARAMS" 'AG_LIMIT_DEFAULT out of range'; return 1; }
        # A fresh segment is already ~80KB (2 tables + 6 indexes). A threshold below
        # that would roll over on every run_start, spawning segments forever.
    (( AG_SEG_MAX_BYTES >= 262144 )) || { _fail "$AG_E_PARAMS" "AG_SEG_MAX_BYTES must be >= 262144 (256KiB); a fresh segment is ~80KB"; return 1; }
    return 0
}

ag_open() {  # idempotent: resolve deps, open/create store, verify schema
    (( AG_OPENED )) && return 0
    _self_path
    _v_config || return 1
        # Order matters: _sqlite_resolve ran first, so it could use neither _p_stat
        # nor its cache in the store dir. Only _engine_spawn needs the binary.
    _platform_init
        # Three external commands became one. fork+exec is 2.8 ms here, and ag_open
        # spent three: `mktemp -d`, its `chmod 700`, and `mkdir -p`.
        #
        # umask, not chmod: `mkdir -m` chmods AFTER creating, leaving the dir
        # group-readable for an instant.
        #
        # mkdir also fails if the name exists, which is the exclusivity mktemp gave.
    local umask_was=${ umask; }
    umask 077
    local tomake=()
    [[ -d $AG_DIR ]] || tomake+=("$AG_DIR")
    if [[ -z $AG_TMP ]]; then
        local tmpcand tries=0
        while :; do
            printf -v tmpcand '%s/ag.%04x%04x%04x%04x.%d' "${TMPDIR:-/tmp}" \
                "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$$"
            [[ -e $tmpcand ]] || break
            (( ++tries > 8 )) && { umask "$umask_was"; _fail "$AG_E_STORAGE" 'cannot pick a private temp dir'; return 1; }
        done
        AG_TMP=$tmpcand; tomake+=("$tmpcand")
    fi
    if (( ${#tomake[@]} )) && ! mkdir -p "${tomake[@]}"; then
        umask "$umask_was"; _fail "$AG_E_STORAGE" "cannot create ${tomake[*]}"; return 1
    fi
    umask "$umask_was"
    local cat="$AG_DIR/ag-catalog.db" creating=0
    _fs_guard "$AG_DIR" || return 1
        # One stat answers _dir_guard AND stamps the sqlite binary for the probe
        # cache. The candidate comes from the cache file, read by a builtin.
    local cand=${AG_SQLITE:-}
    if [[ -z $cand && -r $AG_DIR/.sqlite-probe ]]; then
        IFS=$'\t' read -r cand _ < "$AG_DIR/.sqlite-probe" 2>/dev/null || cand=''
    fi
    _open_stat "$AG_DIR" "$cand"
    _dir_guard "$AG_DIR" || return 1
    _sqlite_resolve || return 1
    if [[ ! -f $cat ]]; then
        if mkdir "$AG_DIR/.init.lock" 2>/dev/null; then
            creating=1
        else  # another process is creating; wait for it
            local -i n=0
            while [[ ! -f $cat || -d $AG_DIR/.init.lock ]]; do
                _nap 0.05
                if (( ++n > 200 )); then _fail "$AG_E_BUSY" 'timed out waiting for store creation'; return 1; fi
            done
        fi
    fi
    _engine_spawn w "$cat" "${ _engine_init_sql rw; }" \
        || { _fail "$AG_E_STORAGE" "cannot open $cat: ${AG_ERR%%$'\n'*}"; return 1; }
    AG_ENG_MODE[w]=rw
    if (( creating )); then
        if ! _store_create; then rmdir "$AG_DIR/.init.lock" 2>/dev/null; return 1; fi
        rmdir "$AG_DIR/.init.lock" 2>/dev/null
    else
        _store_check || return 1
    fi
    AG_OPENED=1
    return 0
}

ag_close() {
    _engine_stop
    (( AG_ACCESS_FD >= 0 )) && { exec {AG_ACCESS_FD}>&- 2>/dev/null; AG_ACCESS_FD=-1; }
    if [[ -n ${AG_PIDFILE:-} && -f ${AG_PIDFILE:-} ]]; then
        [[ ${ cat "$AG_PIDFILE" 2>/dev/null || :; } == "$$" ]] && rm -f "$AG_PIDFILE"
        AG_PIDFILE=''
    fi
    if [[ -n $AG_TMP && -d $AG_TMP ]]; then rm -rf "$AG_TMP"; fi
    AG_TMP='' AG_OPENED=0 AG_PROJ_OPEN=0 AG_ACTIVE_SEG=''
    AG_ATT=() AG_ENG_MODE=()
}

# =============================================================================
# VALIDATION — one surface, two front doors
#
# CLI and JSON-RPC share these, so a rule cannot be enforced in one and
# forgotten in the other. FAIL-CLOSED: input is rejected, never cleaned up.
#
#   L1 transport  frame size / deadline           (rpc-child)
#   L2 envelope   valid JSON-RPC request?         (_rpc_dispatch)
#
#   L3 shape      _v_run_id, _v_actor, _v_idem    (here)
#   L4 semantic   does the run exist? is it live? (in the transaction)
#
# Schema CHECKs are the last line of defence: an error surfacing only there has
# a poor message, and the work is already done.
# =============================================================================

# _optval <flag> [args...] — a value-taking flag's value, into REPLY.
#
# `shift 2` did not drain a one-element list in bash 5.3, so a trailing flag
# looped forever.
#
# `shift; shift` fixed the hang and left the flag accepted with an EMPTY value.
#
# For a filter that reads as success: `events --type` printed everything,
# `run-start --goal` made a goal-less run at rc 0.
#
# `--` is not a value (behaviour bodies use it). A value that merely looks like
# a flag still is one: `--payload -` is documented.
_optval() {
    if (( $# < 2 )) || [[ $2 == -- ]]; then
        _fail "$AG_E_PARAMS" "missing value for $1"; return 1
    fi
    REPLY=$2
}

_v_run_id() { [[ $1 =~ ^r[0-9]{9,13}-[0-9a-f]{4}$ ]]; }
_v_actor()  { [[ $1 =~ ^[a-z][a-z0-9_:.-]{0,63}$ ]]; }
_v_custom_type() { [[ $1 =~ ^x\.[a-z][a-z0-9_.]{0,62}$ ]]; }
_v_idem()   { [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
_v_int()    { [[ $1 =~ ^[0-9]+$ ]]; }
_v_hash()   { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

_v_payload() {  # binds :payload on writer; validates size + JSON object
    local p=$1
    (( ${#p} <= AG_MAX_PAYLOAD )) || { _fail "$AG_E_PARAMS" "payload exceeds $AG_MAX_PAYLOAD bytes"; return 1; }
    _bindval w :payload "$p" || { _fail "$AG_E_INTERNAL" 'bind failed'; return 1; }
    local t; t=${| _sc w "SELECT CASE WHEN json_valid(:payload) THEN json_type(:payload) ELSE '' END;"; }
    [[ $t == object ]] || { _fail "$AG_E_PARAMS" 'payload must be a JSON object'; return 1; }
}

_resolve_tid() {  # $1 = type name -> prints tid; interns x.* customs
    local t=$1 tid
    _bindv w :type "$t" || return 1
    tid=${| _sc w "SELECT coalesce((SELECT tid FROM event_types WHERE name = :type), 0);"; }
    if [[ $tid == 0 ]]; then
        _v_custom_type "$t" || { _fail "$AG_E_PARAMS" "unknown event type '$t' (custom types must match x.<name>)"; return 1; }
        _eng w "INSERT OR IGNORE INTO event_types(tid, name)
                SELECT coalesce((SELECT max(tid) FROM event_types WHERE tid >= 100), 99) + 1, :type;" || :
        tid=${| _sc w "SELECT coalesce((SELECT tid FROM event_types WHERE name = :type), 0);"; }
        if [[ $tid == 0 ]]; then _fail "$AG_E_INTERNAL" 'type intern failed'; return 1; fi
    fi
    printf '%s' "$tid"
}

_resolve_aid() {  # $1 = actor name -> prints aid
    _bindv w :actor "$1" || return 1
    _eng w 'INSERT OR IGNORE INTO actors(name) VALUES (:actor);' || return 1
    _scalar w 'SELECT aid FROM actors WHERE name = :actor;'
}

_run_status() {  # $1 = run_id -> status in REPLY ('' if unknown); binds :run
    REPLY=''
    _bindv w :run "$1" || return 1
    _sc w "SELECT coalesce((SELECT status FROM runs WHERE run_id = :run), '');"
}

# semantic (L4) validation per event type; expects :payload bound on writer
_v_semantic() {  # $1 = tid
    case $1 in
        10) local k i
            k=${| _sc w "SELECT coalesce(:payload ->> '\$.kind', '');"; }
            i=${| _sc w "SELECT coalesce(:payload ->> '\$.id', '');"; }
            [[ $k =~ ^[a-z][a-z0-9_]{0,31}$ ]] || { _fail "$AG_E_PARAMS" 'object.created requires payload.kind (lowercase, id-safe)'; return 1; }
                        # The determinism contract requires runtime-minted ids.
                        #
                        # A supplied id can collide with a later one, and the projection
                        # resolves that last-write-wins — identical logs could differ.
            if [[ -n $i ]]; then
                [[ $AG_ALLOW_EXPLICIT_ID == 1 ]] \
                    || { _fail "$AG_E_PARAMS" 'caller-supplied object id rejected (set AG_ALLOW_EXPLICIT_ID=1 to override)'; return 1; }
                [[ $i == "$k#"* ]] || { _fail "$AG_E_PARAMS" "object id must be '<kind>#<n>'"; return 1; }
            fi ;;
        11) local i pt
            i=${| _sc w "SELECT coalesce(:payload ->> '\$.id', '');"; }
            pt=${| _sc w "SELECT coalesce(json_type(:payload, '\$.patch'), '');"; }
            [[ -n $i && $pt == object ]] || { _fail "$AG_E_PARAMS" 'object.updated requires payload.id and an object payload.patch'; return 1; } ;;
        12) local ok
            ok=${| _sc w "SELECT (coalesce(:payload ->> '\$.src','') <> '') AND (coalesce(:payload ->> '\$.dst','') <> '') AND (coalesce(:payload ->> '\$.kind','') <> '');"; }
            [[ $ok == 1 ]] || { _fail "$AG_E_PARAMS" 'relation.created requires payload.src/.kind/.dst'; return 1; } ;;
        16) local f
            f=${| _sc w "SELECT coalesce(:payload ->> '\$.frame', '');"; }
            [[ $f =~ ^f[0-9]+$ ]] || { _fail "$AG_E_PARAMS" "frame.closed requires payload.frame 'f<n>'"; return 1; } ;;
    esac
    return 0
}

# ---- emit SQL builders ------------------------------------------------------
# Deterministic ids (paper §3): object.created and frame.opened get their id
# injected INSIDE the insert.
#
# The ordinal is read under BEGIN IMMEDIATE, so concurrent emitters cannot mint
# the same one.
#
# The counter reads ACROSS the lineage, so a fork continues the parent's
# numbering and the id stays a pure function of the log.
#
# v1 derived it from count(*) over every prior event of that kind: 6.4 ms at
# 1k priors, 136.8 ms at 200k — O(N) per emit.
#
# Schema v2 persists obj_n, so this is one index probe.
_pf_cte() {  # $1 = tid -> CTE tail defining pf(p, n, k); appended to AG_SQL_LINEAGE
    local tid=$1 kind path pre
    case $tid in
        10) kind=":payload ->> '\$.kind'"; path='$.id';    pre="(:payload ->> '\$.kind') || '#'" ;;
        15) kind="''";                     path='$.frame'; pre="'f'" ;;
        *)  printf '%s' ", pf(p, n, k) AS (SELECT json(:payload), NULL, NULL)"; return 0 ;;
    esac
    printf '%s' ", base(n, k) AS (
    SELECT 1 + coalesce((SELECT max(e2.obj_n) FROM lineage l2
                         JOIN v_run_events e2 ON e2.rid = l2.rid
                              AND (l2.upto IS NULL OR e2.seq <= l2.upto)
                         WHERE e2.tid = $tid AND e2.obj_kind = ($kind)), 0),
           ($kind))
, pf(p, n, k) AS (
    SELECT CASE WHEN :payload ->> '$path' IS NOT NULL THEN json(:payload)
                ELSE json_set(:payload, '$path', $pre || base.n) END,
           base.n, base.k
    FROM base)"
}

# _sql_emit builds one append's two statements: INSERT OR IGNORE into blobs
# (only for a large payload), then the run_events INSERT.
#
# A payload over AG_BLOB_MIN is stored once, content-addressed, the row keeping
# only its hash — so retries, forks and cache hits cost one copy.
#
# A CHECK enforces exactly one of payload/body_ref.
#
# $4 is the run's pinned segment: the INSERT target. Reads use the union views.
#
# Both statements ship as ONE block; they were two round trips per event.
_sql_emit() {  # $1=tid $2=aid $3=caused $4=seg; expects :run :payload :ctx :idem
    local tid=$1 aid=$2 caused=$3 seg=$4 cause_n
    cause_n="nullif(CAST('$caused' AS INTEGER), 0)"
    printf '%s' "$AG_SQL_LINEAGE${ _pf_cte "$tid"; }
INSERT OR IGNORE INTO s${seg}.blobs(hash, sz, body)
SELECT sha3(pf.p, 256), length(jsonb(pf.p)), jsonb(pf.p)
FROM pf WHERE length(jsonb(pf.p)) > $AG_BLOB_MIN;

$AG_SQL_LINEAGE${ _pf_cte "$tid"; }
INSERT INTO s${seg}.run_events(rid, seq, tid, aid, caused_by,
                           payload, body_ref, ctx, hash, chain, idem, tool_name, model,
                           req_hash, obj_kind, obj_n)
SELECT r.rid,
       1 + coalesce((SELECT max(seq) FROM v_run_events WHERE rid = r.rid), coalesce(r.fork_seq, 0)),
       $tid, $aid,
       $cause_n,
       CASE WHEN length(jsonb(pf.p)) <= $AG_BLOB_MIN THEN jsonb(pf.p) END,
       CASE WHEN length(jsonb(pf.p)) >  $AG_BLOB_MIN THEN sha3(pf.p, 256) END,
       CASE WHEN :ctx = '' THEN NULL ELSE jsonb(:ctx) END,
       CASE WHEN $tid IN (6,7,8,9) THEN sha3(pf.p, 256) END,
       CASE WHEN CAST('$AG_CHAIN' AS INTEGER) = 1 THEN
            sha3(coalesce((SELECT chain FROM v_run_events WHERE rid = r.rid ORDER BY seq DESC LIMIT 1),
                          r.chain_seed, zeroblob(32)) || sha3(pf.p, 256), 256) END,
       nullif(:idem, ''),
       CASE WHEN $tid IN (8,9) THEN pf.p ->> '\$.name'  END,
       CASE WHEN $tid IN (6,7) THEN pf.p ->> '\$.model' END,
       -- req_hash: the paper keys a cached response on the hash of its REQUEST.
       -- Prefer an explicit ctx.request_hash (execution metadata, outside the
       -- determinism contract), else resolve the caused_by event's payload hash.
       CASE WHEN $tid IN (7,9) THEN coalesce(
            CASE WHEN :ctx <> ''
                  AND length(coalesce(:ctx ->> '\$.request_hash','')) = 64
                  AND (:ctx ->> '\$.request_hash') GLOB '[0-9a-f]*'
                 THEN unhex(:ctx ->> '\$.request_hash') END,
            (SELECT e3.hash FROM lineage l3
               JOIN v_run_events e3 ON e3.rid = l3.rid
                    AND (l3.upto IS NULL OR e3.seq <= l3.upto)
              WHERE e3.seq = $cause_n AND e3.hash IS NOT NULL)) END,
       pf.k, pf.n
FROM runs r, pf WHERE r.run_id = :run
ON CONFLICT(rid, idem) WHERE idem IS NOT NULL DO NOTHING
RETURNING json_object('run', :run, 'seq', seq, 'hash', nullif(lower(hex(hash)), ''),
                      'req_hash', nullif(lower(hex(req_hash)), ''))"
}

# =============================================================================
# core operations (PLAN 9)
# =============================================================================
_gen_run_id() { printf 'r%s-%04x' "$EPOCHSECONDS" $(( (RANDOM<<4 ^ RANDOM) & 0xffff )); }

ag_run_start() {  # [--goal G] [--tags JSON] [--parent RUN --at-seq K] [--close-parent]
    local goal='' tags='[]' parent='' at_seq='' close_parent=0
    while (( $# )); do case $1 in
        --goal)   _optval "$@" || return 1; goal=$REPLY; shift 2 ;;
        --tags)   _optval "$@" || return 1; tags=$REPLY; shift 2 ;;
        --parent) _optval "$@" || return 1; parent=$REPLY; shift 2 ;;
        --at-seq) _optval "$@" || return 1; at_seq=$REPLY; shift 2 ;;
        --close-parent) close_parent=1; shift ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    _maybe_rollover || return 1   # new runs pin to the (possibly just-rolled) active segment
    (( ${#goal} <= 4096 )) || { _fail "$AG_E_PARAMS" 'goal exceeds 4KiB'; return 1; }
    if [[ -n $parent || -n $at_seq ]]; then
        [[ -n $parent && -n $at_seq ]] || { _fail "$AG_E_PARAMS" '--parent and --at-seq required together'; return 1; }
        _v_run_id "$parent" || { _fail "$AG_E_PARAMS" 'invalid parent run id'; return 1; }
        _v_int "$at_seq"    || { _fail "$AG_E_PARAMS" 'invalid --at-seq'; return 1; }
    fi
    _bindv w :goal "$goal" || return 1
    _bindval w :tags "$tags" || return 1
    local tt; tt=${| _sc w "SELECT CASE WHEN json_valid(:tags) THEN json_type(:tags) ELSE '' END;"; }
    [[ $tt == array ]] || { _fail "$AG_E_PARAMS" 'tags must be a JSON array'; return 1; }
    local os; os=${ uname -sm 2>/dev/null || echo unknown; }
    _bindv w :os "$os" || return 1
    _bindv w :hv "$AG_VERSION" || return 1
    _bindv w :bd "${ _build_id; }" || return 1
    _bindv w :bv "$BASH_VERSION" || return 1

    local prid='NULL' fseq='NULL'
    if [[ -n $parent ]]; then
        local pst; pst=${| _run_status "$parent"; }   # binds :run = parent
        [[ -n $pst ]] || { _fail "$AG_E_NORUN" "unknown parent run: $parent"; return 1; }
        [[ $pst != purged ]] || { _fail "$AG_E_PARAMS" 'cannot fork a purged run'; return 1; }
        _route_run w || return 1                      # attach parent's lineage segments
        _bindv w :prun "$parent" || return 1
        local pmax
        pmax=${| _sc w "SELECT coalesce((SELECT max(e.seq) FROM v_run_events e JOIN runs r ON r.rid = e.rid WHERE r.run_id = :prun),
                                           (SELECT coalesce(fork_seq, 0) FROM runs WHERE run_id = :prun));"; }
        (( at_seq <= pmax )) || { _fail "$AG_E_PARAMS" "fork seq $at_seq beyond parent max seq $pmax"; return 1; }
        prid="(SELECT rid FROM runs WHERE run_id = :prun)"
        fseq="CAST('$at_seq' AS INTEGER)"
    fi

    local rid='' run_id try
    for try in 1 2 3 4 5; do
        run_id=${ _gen_run_id; }
        _bindv w :rn "$run_id" || return 1
        _txn_begin || return 1
        _eng w "INSERT INTO runs(run_id, seg_id, parent_rid, fork_seq, goal, tags, env, chain_seed)
                SELECT :rn, $AG_ACTIVE_SEG, $prid, $fseq, :goal, jsonb(:tags),
                       jsonb(json_object('harness', :hv, 'build', :bd, 'os', :os, 'bash', :bv, 'sqlite', sqlite_version())),
                       CASE WHEN $fseq IS NOT NULL AND CAST('$AG_CHAIN' AS INTEGER) = 1 THEN
                           (SELECT e.chain FROM v_run_events e JOIN runs r ON r.rid = e.rid
                             WHERE r.run_id = :prun AND e.seq <= $fseq AND e.chain IS NOT NULL
                             ORDER BY e.seq DESC LIMIT 1)
                       END
                RETURNING rid;"
        if (( $? == 0 )); then
            rid=${AG_OUT%%$'\n'*}
                        # Forking used to close the parent unconditionally, so branching a
                        # live run terminated it.
                        #
                        # Nothing in the paper implies that, and it made fork destructive
                        # rather than cheap.
            if [[ -n $parent ]] && (( close_parent )); then
                _eng w "UPDATE runs SET status = 'forked' WHERE run_id = :prun AND status = 'live';" \
                    || { _txn_rollback; _fail "$AG_E_INTERNAL" "fork update failed: $AG_ERR"; return 1; }
            fi
            _txn_commit || { _txn_rollback; _fail "$AG_E_INTERNAL" "commit failed: $AG_ERR"; return 1; }
            break
        fi
        _txn_rollback
        [[ $AG_ERR == *'UNIQUE constraint failed: runs.run_id'* ]] \
            || { _fail "$AG_E_INTERNAL" "run insert failed: ${AG_ERR%%$'\n'*}"; return 1; }
        rid=''
    done
    [[ -n $rid ]] || { _fail "$AG_E_INTERNAL" 'run id collision retries exhausted'; return 1; }

    if [[ -z $parent ]]; then  # forks share the parent's prefix; no new run.started
        local gq; gq=${| _sc w 'SELECT json_quote(:goal);'; }
        AG_INTERNAL_EMIT=1 ag_emit --run "$run_id" --type run.started --actor runtime \
                --payload "{\"goal\":$gq}" >/dev/null || return 1
    fi
    if [[ -n $parent ]]; then
        printf '{"run":"%s","rid":%s,"forked_from":"%s","at_seq":%s}\n' "$run_id" "$rid" "$parent" "$at_seq"
    else
        printf '{"run":"%s","rid":%s}\n' "$run_id" "$rid"
    fi
}

# --payload@FILE and `--payload -` exist because Linux caps one argument at
# MAX_ARG_STRLEN (128 KiB): a bigger emit fails E2BIG before this script runs.
#
# AG_MAX_PAYLOAD is 1 MiB, so file/stdin are the only portable route to it.

# ag_emit — append ONE event. Read this first; the rest supports it.
#
#   validate flags        cheap regex, fail before touching the db
#   resolve type/actor    names -> interned integers
#   validate payload      JSON object, under the size cap
#
#   route                 ATTACH the run's segments (cannot run inside a txn)
#   BEGIN IMMEDIATE       write lock, jittered retry on BUSY
#
#   one INSERT            seq = max(seq)+1 in the same statement, so concurrent
#                         writers cannot mint the same seq
#   COMMIT
ag_emit() {  # --run R --type T (--payload JSON|- | --payload@FILE) [--actor A] ...
    local run='' type='' payload='' actor='runtime' caused=0 ctx='' idem='' pfile=''
    while (( $# )); do case $1 in
        --run)       _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --type)      _optval "$@" || return 1; type=$REPLY; shift 2 ;;
        --payload)   _optval "$@" || return 1; payload=$REPLY; shift 2 ;;
        --payload@*) pfile=${1#--payload@}; shift ;;
        --actor)     _optval "$@" || return 1; actor=$REPLY; shift 2 ;;
        --caused-by) _optval "$@" || return 1; caused=$REPLY; shift 2 ;;
        --ctx)       _optval "$@" || return 1; ctx=$REPLY; shift 2 ;;
        --idem)      _optval "$@" || return 1; idem=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" "invalid run id: '$run'"; return 1; }
    [[ -n $type ]]   || { _fail "$AG_E_PARAMS" '--type required'; return 1; }
    _v_actor "$actor" || { _fail "$AG_E_PARAMS" "invalid actor: '$actor'"; return 1; }
    if [[ -n $pfile ]]; then
        [[ -r $pfile ]] || { _fail "$AG_E_PARAMS" "cannot read payload file: $pfile"; return 1; }
        IFS= read -r -d '' payload < "$pfile" || :   # whole file, no fork
    fi
    [[ $payload == - ]] && payload=${ cat; }
    [[ -n $payload ]] || { _fail "$AG_E_PARAMS" '--payload required (JSON object, -, or --payload@FILE)'; return 1; }
    _v_int "$caused" || { _fail "$AG_E_PARAMS" 'invalid --caused-by'; return 1; }
    if [[ -n $idem ]]; then
        _v_idem "$idem" || { _fail "$AG_E_PARAMS" 'invalid --idem key'; return 1; }
    fi
    if [[ -n $ctx ]]; then
        (( ${#ctx} <= 4096 )) || { _fail "$AG_E_PARAMS" 'ctx exceeds 4KiB'; return 1; }
    fi

    local st; st=${| _run_status "$run"; }
    [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    [[ $st == live ]] || { _fail "$AG_E_PARAMS" "run is '$st', not live"; return 1; }

    local tid aid
    tid=${ _resolve_tid "$type"; } || return 1
        # F3: lifecycle types are runtime-minted, keeping runs.status and frame ids
        # consistent with the log. The public path refuses them; internal callers
        # set AG_INTERNAL_EMIT.
    if [[ ${AG_INTERNAL_EMIT:-0} != 1 ]] && [[ " 1 2 13 14 15 16 " == *" $tid "* ]]; then
        _fail "$AG_E_PARAMS" "event type '$type' is runtime-reserved (use run-start/run-end/frame-open/frame-close)"; return 1
    fi
    aid=${ _resolve_aid "$actor"; } || return 1
    _v_payload "$payload" || return 1
    _v_semantic "$tid" || return 1
    _bindval w :ctx "$ctx" || return 1
    if [[ -n $ctx ]]; then
        local ct; ct=${| _sc w "SELECT CASE WHEN json_valid(:ctx) THEN json_type(:ctx) ELSE '' END;"; }
        [[ $ct == object ]] || { _fail "$AG_E_PARAMS" 'ctx must be a JSON object'; return 1; }
    fi
    _bindv w :idem "$idem" || return 1

        # route: attach the run's lineage (pinned segment RW, sealed ancestors
        # immutable) and rebuild the views BEFORE the txn — ATTACH cannot run inside one.
    _bindv w :run "$run" || return 1
    _route_run w || return 1
    local seg; seg=${| _seg_of_run w; }
    [[ -n $seg ]] || { _fail "$AG_E_INTERNAL" "cannot resolve segment for $run"; return 1; }

    _txn_begin || return 1
    _eng w "${ _sql_emit "$tid" "$aid" "$caused" "$seg"; };"
    local rc=$? out=$AG_OUT
    if (( rc != 0 )); then
        _txn_rollback
        case $AG_ERR in
            *'CHECK constraint failed'*) _fail "$AG_E_PARAMS" "constraint rejected event: ${AG_ERR%%$'\n'*}" ;;
            *'database is locked'*)      _fail "$AG_E_BUSY" 'database busy' ;;
            *'disk is full'*)            _fail "$AG_E_STORAGE" 'storage full' ;;
            *)                           _fail "$AG_E_INTERNAL" "emit failed: ${AG_ERR%%$'\n'*}" ;;
        esac
        return 1
    fi
        # Lifecycle transitions must land in the SAME transaction as their event.
        #
        # A crash between the two leaves a run with a run.ended event still marked
        # 'live' forever.
    if [[ -n ${AG_EMIT_EXTRA_SQL:-} ]]; then
        _eng w "$AG_EMIT_EXTRA_SQL" \
            || { _txn_rollback; _fail "$AG_E_INTERNAL" "lifecycle update failed: ${AG_ERR%%$'\n'*}"; return 1; }
    fi
    _txn_commit || { _txn_rollback; _fail "$AG_E_INTERNAL" "commit failed: $AG_ERR"; return 1; }
    local trimmed=${out//[$'\n\t ']/}
    if [[ -z $trimmed && -n $idem ]]; then  # idem replay: return the existing seq
        _scalar w "SELECT json_object('run', :run, 'seq', e.seq, 'hash', nullif(lower(hex(e.hash)),''),
                          'req_hash', nullif(lower(hex(e.req_hash)),''), 'idem_replayed', json('true'))
                   FROM v_run_events e JOIN runs r ON r.rid = e.rid
                   WHERE r.run_id = :run AND e.idem = :idem;"
        printf '\n'
        return 0
    fi
    printf '%s' "$out"
}

# L3 validation for a whole batch in ONE statement (PLAN 11). Returns '' when
# every element passes, else "element <i>: <reason>" for the FIRST failure.
_sql_batch_validate() {
    printf '%s' "SELECT coalesce((SELECT 'element ' || k || ': ' || e FROM (
  SELECT je.key AS k, CASE
    WHEN json_type(je.value) <> 'object' THEN 'not a JSON object'
    WHEN coalesce(je.value ->> '\$.type','') = '' THEN 'type required'
    WHEN je.value ->> '\$.type' IN ('run.started','run.ended','frame.opened','frame.closed',
                                    'behavior.started','behavior.completed')
         THEN 'event type is runtime-reserved'
    WHEN (je.value ->> '\$.type') NOT IN (SELECT name FROM event_types)
         AND NOT ((je.value ->> '\$.type') GLOB 'x.[a-z]*'
                  AND length(je.value ->> '\$.type') <= 64
                  AND NOT (substr(je.value ->> '\$.type', 3) GLOB '*[^a-z0-9_.]*'))
         THEN 'unknown event type (custom types must match x.<name>)'
    WHEN length(coalesce(je.value ->> '\$.actor','runtime')) > 64
         OR NOT (coalesce(je.value ->> '\$.actor','runtime') GLOB '[a-z]*')
         OR (coalesce(je.value ->> '\$.actor','runtime') GLOB '*[^a-z0-9_:.-]*')
         THEN 'invalid actor'
    WHEN json_type(je.value, '\$.payload') IS NULL THEN 'payload required'
    WHEN json_type(je.value, '\$.payload') <> 'object' THEN 'payload must be a JSON object'
    WHEN length(json_extract(je.value, '\$.payload')) > $AG_MAX_PAYLOAD
         THEN 'payload exceeds $AG_MAX_PAYLOAD bytes'
    WHEN json_type(je.value, '\$.ctx') IS NOT NULL
         AND json_type(je.value, '\$.ctx') <> 'object' THEN 'ctx must be a JSON object'
    WHEN length(coalesce(json_extract(je.value, '\$.ctx'), '')) > 4096 THEN 'ctx exceeds 4KiB'
    WHEN json_type(je.value, '\$.caused_by') IS NOT NULL
         AND (json_type(je.value, '\$.caused_by') <> 'integer'
              OR CAST(je.value ->> '\$.caused_by' AS INTEGER) < 1) THEN 'invalid caused_by'
    WHEN json_type(je.value, '\$.idem') IS NOT NULL
         AND (json_type(je.value, '\$.idem') <> 'text'
              OR length(je.value ->> '\$.idem') NOT BETWEEN 1 AND 64
              OR (je.value ->> '\$.idem') GLOB '*[^A-Za-z0-9._-]*') THEN 'invalid idem key'
    WHEN je.value ->> '\$.type' = 'object.created' AND (
           coalesce(json_extract(je.value,'\$.payload') ->> '\$.kind','') = ''
           OR NOT (json_extract(je.value,'\$.payload') ->> '\$.kind' GLOB '[a-z]*')
           OR (json_extract(je.value,'\$.payload') ->> '\$.kind') GLOB '*[^a-z0-9_]*'
           OR length(json_extract(je.value,'\$.payload') ->> '\$.kind') > 32)
         THEN 'object.created requires payload.kind (lowercase, id-safe)'
    WHEN je.value ->> '\$.type' = 'object.created'
         AND json_extract(je.value,'\$.payload') ->> '\$.id' IS NOT NULL
         AND CAST('$AG_ALLOW_EXPLICIT_ID' AS INTEGER) <> 1
         THEN 'caller-supplied object id rejected (set AG_ALLOW_EXPLICIT_ID=1 to override)'
    WHEN je.value ->> '\$.type' = 'object.updated' AND (
           coalesce(json_extract(je.value,'\$.payload') ->> '\$.id','') = ''
           OR coalesce(json_type(json_extract(je.value,'\$.payload'), '\$.patch'),'') <> 'object')
         THEN 'object.updated requires payload.id and an object payload.patch'
    WHEN je.value ->> '\$.type' = 'relation.created' AND (
           coalesce(json_extract(je.value,'\$.payload') ->> '\$.src','') = ''
           OR coalesce(json_extract(je.value,'\$.payload') ->> '\$.kind','') = ''
           OR coalesce(json_extract(je.value,'\$.payload') ->> '\$.dst','') = '')
         THEN 'relation.created requires payload.src/.kind/.dst'
    END AS e
  FROM json_each(:batch) je
) WHERE e IS NOT NULL ORDER BY k LIMIT 1), '');"
}

ag_emit_batch() {  # --run R ; NDJSON events on stdin
    local run=''
    while (( $# )); do case $1 in
        --run) _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    local st; st=${| _run_status "$run"; }
    [[ -n $st ]]      || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    [[ $st == live ]] || { _fail "$AG_E_PARAMS" "run is '$st', not live"; return 1; }

    local -a lines=()
    local line
        # `|| [[ -n $line ]]` is not a nicety: a final line with no trailing newline
        # arrives WITH read's non-zero return.
        #
        # A plain `while read` sets the variable then discards it, so
        # `printf '%s\n%s' a b | emit-batch` silently lost b at rc 0.
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n ${line//[$' \t\r']/} ]] || { line=''; continue; }
        lines+=("$line")
        (( ${#lines[@]} > AG_MAX_BATCH )) && {
            _fail "$AG_E_PARAMS" "batch exceeds $AG_MAX_BATCH elements"; return 1; }
        line=''
    done
    (( ${#lines[@]} )) || { _fail "$AG_E_PARAMS" 'empty batch'; return 1; }

        # NDJSON -> one JSON array, bound once. Everything below is set-based: the
        # old loop cost 3 bind pipelines + 2 statements PER ELEMENT (~28 ms/event).
    local arr; printf -v arr '%s,' "${lines[@]}"
    _bindval w :batch "[${arr%,}]" || return 1
    local ok; ok=${| _sc w "SELECT CASE WHEN json_valid(:batch) THEN json_type(:batch) ELSE '' END;"; }
    if [[ $ok != array ]]; then
                # slow path, only on failure: name the offending line
        local i
        for i in "${!lines[@]}"; do
            _bindval w :el "${lines[$i]}" || return 1
            [[ ${| _sc w 'SELECT coalesce(json_valid(:el),0);'; } == 1 ]] && continue
            _fail "$AG_E_PARAMS" "batch element $i: not valid JSON"; return 1
        done
        _fail "$AG_E_PARAMS" 'batch is not valid NDJSON (one JSON object per line)'; return 1
    fi
    local verr; verr=${| _sc w "${ _sql_batch_validate; }"; } || {
        _fail "$AG_E_INTERNAL" "batch validation failed: ${AG_ERR%%$'\n'*}"; return 1; }
    [[ -z $verr ]] || { _fail "$AG_E_PARAMS" "batch $verr"; return 1; }

        # route once (all elements target the same run/segment) before the txn
    _bindv w :run "$run" || return 1
    _route_run w || return 1
    local seg; seg=${| _seg_of_run w; }
    [[ -n $seg ]] || { _fail "$AG_E_INTERNAL" "cannot resolve segment for $run"; return 1; }

        # One BEGIN IMMEDIATE around the whole batch: one WAL sync for N events,
        # full rollback on any failure (PLAN 9.1).
    _txn_begin || return 1
    local rid base
    rid=${| _sc w 'SELECT rid FROM runs WHERE run_id = :run;'; }
    [[ $rid =~ ^[0-9]+$ ]] || { _txn_rollback; _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
        # base seq is read ONCE under the write lock; row_number() supplies the rest,
        # so the INSERT never has to read rows it is itself inserting.
    base=${| _sc w "SELECT 1 * coalesce((SELECT max(seq) FROM v_run_events WHERE rid = $rid),
                              (SELECT coalesce(fork_seq,0) FROM runs WHERE rid = $rid));"; }
    [[ $base =~ ^[0-9]+$ ]] || base=0

        # intern every new type/actor in the batch (two statements, not 2N)
    _eng w "INSERT OR IGNORE INTO event_types(tid, name)
            SELECT (SELECT coalesce(max(tid),99) FROM event_types WHERE tid >= 100)
                   + row_number() OVER (ORDER BY name), name
            FROM (SELECT DISTINCT je.value ->> '\$.type' AS name FROM json_each(:batch) je
                  WHERE (je.value ->> '\$.type') NOT IN (SELECT name FROM event_types));
INSERT OR IGNORE INTO actors(name)
            SELECT DISTINCT coalesce(je.value ->> '\$.actor','runtime') FROM json_each(:batch) je;" \
        || { _txn_rollback; _fail "$AG_E_INTERNAL" "batch intern: ${AG_ERR%%$'\n'*}"; return 1; }

        # per-kind ordinal bases, materialised BEFORE the insert so the INSERT never
        # reads a table it is writing (SQLite gives no snapshot guarantee there)
    _eng w "DROP TABLE IF EXISTS temp._bkind;
CREATE TEMP TABLE _bkind(kind TEXT PRIMARY KEY, base INTEGER);
$AG_SQL_LINEAGE
INSERT INTO _bkind(kind, base)
SELECT k, coalesce((SELECT max(e2.obj_n) FROM lineage l2
                    JOIN v_run_events e2 ON e2.rid = l2.rid
                         AND (l2.upto IS NULL OR e2.seq <= l2.upto)
                    WHERE e2.tid = 10 AND e2.obj_kind = k), 0)
FROM (SELECT DISTINCT json_extract(je.value,'\$.payload') ->> '\$.kind' AS k
      FROM json_each(:batch) je WHERE je.value ->> '\$.type' = 'object.created');" \
        || { _txn_rollback; _fail "$AG_E_INTERNAL" "batch ordinals: ${AG_ERR%%$'\n'*}"; return 1; }

    local cte="$AG_SQL_LINEAGE, el AS (
    SELECT je.key AS k, je.value AS v, json_extract(je.value,'\$.payload') AS pay
    FROM json_each(:batch) je
), t AS (
    SELECT el.k, el.v, el.pay, et.tid AS tid, ac.aid AS aid,
           CASE WHEN et.tid = 10 THEN el.pay ->> '\$.kind' END AS okind
    FROM el JOIN event_types et ON et.name = el.v ->> '\$.type'
            JOIN actors ac ON ac.name = coalesce(el.v ->> '\$.actor','runtime')
), n AS (
    SELECT t.*, row_number() OVER (ORDER BY t.k) AS rn,
           CASE WHEN t.tid = 10 THEN row_number() OVER (PARTITION BY t.okind ORDER BY t.k) END AS krn
    FROM t
), pf AS (
    SELECT n.*, coalesce(bk.base,0) + n.krn AS objn,
           CASE WHEN n.tid = 10 AND n.pay ->> '\$.id' IS NULL
                THEN json_set(n.pay, '\$.id', n.okind || '#' || (coalesce(bk.base,0) + n.krn))
                ELSE json(n.pay) END AS p
    FROM n LEFT JOIN _bkind bk ON bk.kind = n.okind
)"
    _eng w "$cte
INSERT OR IGNORE INTO s${seg}.blobs(hash, sz, body)
SELECT sha3(pf.p,256), length(jsonb(pf.p)), jsonb(pf.p) FROM pf
WHERE length(jsonb(pf.p)) > $AG_BLOB_MIN;" \
        || { _txn_rollback; _fail "$AG_E_INTERNAL" "batch blobs: ${AG_ERR%%$'\n'*}"; return 1; }

    _eng w "$cte
INSERT INTO s${seg}.run_events(rid, seq, tid, aid, caused_by, payload, body_ref, ctx,
                               hash, chain, idem, tool_name, model, req_hash, obj_kind, obj_n)
SELECT $rid, $base + pf.rn, pf.tid, pf.aid,
       CAST(pf.v ->> '\$.caused_by' AS INTEGER),
       CASE WHEN length(jsonb(pf.p)) <= $AG_BLOB_MIN THEN jsonb(pf.p) END,
       CASE WHEN length(jsonb(pf.p)) >  $AG_BLOB_MIN THEN sha3(pf.p,256) END,
       jsonb(json_extract(pf.v,'\$.ctx')),
       CASE WHEN pf.tid IN (6,7,8,9) THEN sha3(pf.p,256) END,
       NULL,
       pf.v ->> '\$.idem',
       CASE WHEN pf.tid IN (8,9) THEN pf.p ->> '\$.name'  END,
       CASE WHEN pf.tid IN (6,7) THEN pf.p ->> '\$.model' END,
       CASE WHEN pf.tid IN (7,9) THEN coalesce(
            CASE WHEN length(coalesce(json_extract(pf.v,'\$.ctx') ->> '\$.request_hash','')) = 64
                  AND (json_extract(pf.v,'\$.ctx') ->> '\$.request_hash') GLOB '[0-9a-f]*'
                 THEN unhex(json_extract(pf.v,'\$.ctx') ->> '\$.request_hash') END,
            (SELECT e3.hash FROM lineage l3
               JOIN v_run_events e3 ON e3.rid = l3.rid
                    AND (l3.upto IS NULL OR e3.seq <= l3.upto)
              WHERE e3.seq = CAST(pf.v ->> '\$.caused_by' AS INTEGER)
                AND e3.hash IS NOT NULL)) END,
       pf.okind, pf.objn
FROM pf WHERE true
ON CONFLICT(rid, idem) WHERE idem IS NOT NULL DO NOTHING
RETURNING seq;" || {
        local e=$AG_ERR; _txn_rollback
        case $e in
            *'CHECK constraint failed'*) _fail "$AG_E_PARAMS" "batch rejected: ${e%%$'\n'*}" ;;
            *'database is locked'*)      _fail "$AG_E_BUSY" 'database busy' ;;
            *'disk is full'*)            _fail "$AG_E_STORAGE" 'storage full' ;;
            *)                           _fail "$AG_E_INTERNAL" "batch insert: ${e%%$'\n'*}" ;;
        esac
        return 1; }
    local seqout=$AG_OUT
        # AG_CHAIN batches: event k's chain seals k-1, a dependency a single set
        # INSERT cannot express. Fill it in one ordered UPDATE pass.
    if (( AG_CHAIN )); then
        _eng w "UPDATE s${seg}.run_events AS x SET chain = (
            WITH RECURSIVE c(seq, ch) AS (
              SELECT $base, coalesce((SELECT chain FROM s${seg}.run_events
                                       WHERE rid = $rid AND seq <= $base AND chain IS NOT NULL
                                       ORDER BY seq DESC LIMIT 1),
                                     (SELECT chain_seed FROM runs WHERE rid = $rid),
                                     zeroblob(32))
              UNION ALL
              SELECT e.seq, sha3(c.ch || sha3(json(coalesce(e.payload, b.body)),256), 256)
              FROM c JOIN s${seg}.run_events e ON e.rid = $rid AND e.seq = c.seq + 1
              LEFT JOIN s${seg}.blobs b ON b.hash = e.body_ref)
            SELECT ch FROM c WHERE c.seq = x.seq)
          WHERE x.rid = $rid AND x.seq > $base;" \
            || { _txn_rollback; _fail "$AG_E_INTERNAL" "batch chain: ${AG_ERR%%$'\n'*}"; return 1; }
    fi
    _eng w 'DROP TABLE IF EXISTS temp._bkind;' || :
    _txn_commit || { _txn_rollback; _fail "$AG_E_INTERNAL" "batch commit failed: $AG_ERR"; return 1; }

    local first='' last='' s
    while IFS= read -r s; do
        [[ $s =~ ^[0-9]+$ ]] || continue
        [[ -z $first ]] && first=$s
        [[ -z $last || $s -gt $last ]] && last=$s
        [[ $s -lt $first ]] && first=$s
    done <<< "$seqout"
    printf '{"run":"%s","count":%d,"first_seq":%s,"last_seq":%s}\n' \
           "$run" "${#lines[@]}" "${first:-null}" "${last:-null}"
}

# lineage CTE fragment (PLAN 9.3); expects :run bound; yields (rid, upto).
#
# A fork copies nothing: it records parent P and branch seq k, so reading it
# means reading P's events 1..k plus its own, recursively.
#
# This CTE walks that chain and yields how much of each ancestor is visible.
# `min(l.upto, r.fork_seq)` is load-bearing: cutoffs COMPOSE.
#
# Seq spaces never overlap, so a UNION of the slices is already ordered by seq.
readonly AG_SQL_LINEAGE="
WITH RECURSIVE lineage(rid, upto) AS (
    SELECT rid, NULL FROM runs WHERE run_id = :run
    UNION ALL
    SELECT r.parent_rid,
           CASE WHEN l.upto IS NULL THEN r.fork_seq ELSE min(l.upto, r.fork_seq) END
    FROM runs r JOIN lineage l ON r.rid = l.rid
    WHERE r.parent_rid IS NOT NULL
)"

ag_events() {  # --run R [--type T] [--since N] [--limit N] -> NDJSON
    local run='' type='' since=0 limit=$AG_LIMIT_DEFAULT
    while (( $# )); do case $1 in
        --run)   _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --type)  _optval "$@" || return 1; type=$REPLY; shift 2 ;;
        --since) _optval "$@" || return 1; since=$REPLY; shift 2 ;;
        --limit) _optval "$@" || return 1; limit=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    _v_int "$since"  || { _fail "$AG_E_PARAMS" 'invalid --since'; return 1; }
    if ! _v_int "$limit" || (( limit < 1 || limit > AG_LIMIT_MAX )); then
        _fail "$AG_E_PARAMS" "limit must be 1..$AG_LIMIT_MAX"; return 1
    fi
    local st; st=${| _run_status "$run"; }
    [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
        # F7: a purged run's events are physically gone; return a clear signal
        # rather than a silent empty result that reads as "run had no events".
    [[ $st != purged ]] || { _fail "$AG_E_NORUN" "run is purged (events deleted): $run"; return 1; }
    local e; e=${| _engine_for_read; }
    _bindv "$e" :run "$run" || return 1
    _route_run "$e" || return 1
    _bindv "$e" :tname "$type" || return 1
    _engf "$e" "$AG_SQL_LINEAGE
SELECT json_object('seq', e.seq, 'type', t.name, 'actor', a.name,
                   'caused_by', e.caused_by,
                   'payload', json(coalesce(e.payload, b.body)),
                   'ctx', json(e.ctx),
                   'hash', nullif(lower(hex(e.hash)), ''),
                   'ts_ms', e.ts_ms)
FROM lineage l
JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
LEFT JOIN v_blobs b ON b.hash = e.body_ref
JOIN event_types t ON t.tid = e.tid
JOIN actors a ON a.aid = e.aid
WHERE (:tname = '' OR t.name = :tname) AND e.seq > $since
ORDER BY e.seq LIMIT $limit;" || { _fail "$AG_E_INTERNAL" "events query failed: ${AG_ERR%%$'\n'*}"; return 1; }
    printf '%s' "$AG_OUT"
}

ag_fork() {  # <run> <seq> [--close-parent]
    local run=${1:-} seq=${2:-}; shift 2>/dev/null; shift 2>/dev/null
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    _v_int "$seq"    || { _fail "$AG_E_PARAMS" 'invalid seq'; return 1; }
    local -a extra=()
    while (( $# )); do case $1 in
        --close-parent) extra+=(--close-parent); shift ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_run_start --parent "$run" --at-seq "$seq" "${extra[@]}"
}

ag_run_end() {  # --run R [--status done|failed]
    local run='' status=done
    while (( $# )); do case $1 in
        --run)    _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --status) _optval "$@" || return 1; status=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    [[ $status == done || $status == failed ]] || { _fail "$AG_E_PARAMS" 'status must be done|failed'; return 1; }
    local st; st=${| _run_status "$run"; }
    [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    [[ $st == live ]] || { _fail "$AG_E_PARAMS" "run is '$st', not live"; return 1; }
    AG_INTERNAL_EMIT=1 \
    AG_EMIT_EXTRA_SQL="UPDATE runs SET status = '$status',
                              ended_ms = CAST(unixepoch('subsec')*1000 AS INTEGER)
                       WHERE run_id = :run;" \
        ag_emit --run "$run" --type run.ended --actor runtime \
                --payload "{\"status\":\"$status\"}" >/dev/null || return 1
    printf '{"run":"%s","status":"%s"}\n' "$run" "$status"
}

ag_cache_lookup() {  # <hash-hex> [--by request|response|any] (PLAN 9.4 / paper 4)
        # The paper keys a cached response on a hash of the whole REQUEST.
        #
        # v1 indexed only each event's own payload hash, so a probe hit only if
        # the caller already had it: a dedup index, not a cache.
    local h='' by=any
    while (( $# )); do case $1 in
        --by) _optval "$@" || return 1; by=$REPLY; shift 2 ;;
        -*)   _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
        *)    h=$1; shift ;;
    esac; done
    case $by in request|response|any) ;; *) _fail "$AG_E_PARAMS" '--by must be request|response|any'; return 1 ;; esac
    _v_hash "$h" || { _fail "$AG_E_PARAMS" 'expected 64-char lowercase hex sha3'; return 1; }
    ag_open || return 1
    local e; e=${| _engine_for_read; }
        # Content-addressed: same sha3 means byte-identical payload, so search the
        # newest segment first and return the first hit.
        #
        # A miss scans every segment one at a time; there is no global hash index.
    local segids sid trimmed
    segids=${| _sc "$e" "SELECT coalesce(group_concat(seg_id, ' ' ORDER BY seg_id DESC), '')
                            FROM segments WHERE state IN ('active','draining','sealed','archived');"; }
    local pred
    case $by in
        request)  pred="e.req_hash = unhex('$h')" ;;
        response) pred="e.hash = unhex('$h')" ;;
        any)      pred="(e.req_hash = unhex('$h') OR e.hash = unhex('$h'))" ;;
    esac
    for sid in $segids; do
        _seg_require "$e" "$sid" || return 1
        _eng "$e" "SELECT json_object('hit', json('true'), 'type', t.name, 'seq', e.seq,
                        'keyed', CASE WHEN e.req_hash = unhex('$h') THEN 'request' ELSE 'response' END,
                        'payload', json(coalesce(e.payload, b.body)))
                   FROM s${sid}.run_events e
                   LEFT JOIN s${sid}.blobs b ON b.hash = e.body_ref
                   JOIN event_types t ON t.tid = e.tid
                   WHERE $pred AND e.tid IN (7,9)
                   ORDER BY e.rid, e.seq LIMIT 1;" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
        trimmed=${AG_OUT//$'\n'/}
        [[ -n $trimmed ]] && { printf '%s' "$AG_OUT"; return 0; }
    done
    printf '{"hit":false}\n'
}

ag_verify() {  # --run R [--chain]
    local run='' chain=0
    while (( $# )); do case $1 in
        --run)   _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --chain) chain=1; shift ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    local st; st=${| _run_status "$run"; }
    [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    [[ $st != purged ]] || { _fail "$AG_E_NORUN" "run is purged (events deleted): $run"; return 1; }  # F7
    local e; e=${| _engine_for_read; }
    _bindv "$e" :run "$run" || return 1
    _route_run "$e" || return 1
    local bad
    bad=${| _sc "$e" "$AG_SQL_LINEAGE
SELECT coalesce((SELECT json_object('seq', e.seq, 'kind', 'hash')
FROM lineage l JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
LEFT JOIN v_blobs b ON b.hash = e.body_ref
WHERE e.hash IS NOT NULL
  AND e.hash <> sha3(json(coalesce(e.payload, b.body)), 256)
ORDER BY e.seq LIMIT 1), '');"; } || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    if [[ -n $bad ]]; then printf '{"ok":false,"first_bad":%s}\n' "$bad"; return 1; fi
    if (( chain )); then
        bad=${| _sc "$e" "$AG_SQL_LINEAGE
SELECT coalesce((SELECT json_object('seq', seq, 'kind', 'chain') FROM (
    SELECT e.seq AS seq, e.chain AS chain,
           sha3(coalesce(lag(e.chain) OVER (ORDER BY e.seq), zeroblob(32))
                || sha3(json(coalesce(e.payload, b.body)), 256), 256) AS want
    FROM lineage l JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
    LEFT JOIN v_blobs b ON b.hash = e.body_ref
    WHERE e.chain IS NOT NULL
) WHERE chain <> want ORDER BY seq LIMIT 1), '');"; } || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
        if [[ -n $bad ]]; then printf '{"ok":false,"first_bad":%s}\n' "$bad"; return 1; fi
    fi
    printf '{"ok":true}\n'
}

ag_purge() {  # --run R (v1: active segment, batched)
    local run=''
    while (( $# )); do case $1 in
        --run) _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    local st; st=${| _run_status "$run"; }
    [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    local kids
    kids=${| _sc w "SELECT count(*) FROM runs WHERE parent_rid = (SELECT rid FROM runs WHERE run_id = :run) AND status <> 'purged';"; }
    (( kids == 0 )) || { _fail "$AG_E_PARAMS" "run has $kids unpurged fork(s); purge children first"; return 1; }
        # purge deletes the run's OWN rows, all in its pinned segment; never the
        # shared prefix (parent rows in ancestor segments).
    _bindv w :run "$run" || return 1
    _route_run w || return 1
    local seg; seg=${| _seg_of_run w; }
    [[ -n $seg ]] || { _fail "$AG_E_INTERNAL" "cannot resolve segment for $run"; return 1; }
    local segstate; segstate=${| _sc w "SELECT state FROM segments WHERE seg_id=$seg;"; }
    local n total=0 mode=physical blobs_gone=0
    if [[ $segstate == sealed || $segstate == archived ]]; then
                # a sealed segment is immutable — purge is a catalog TOMBSTONE now; bytes
                # are reclaimed when the segment is dropped. Use ag_segment_rewrite for
                # GDPR-grade hard-delete-now.
        mode=tombstone
    else
                # Deleting a row only unlinks it: the bytes stay in freed pages.
                #
                # In WAL mode the main file also holds the pre-delete image until a
                # checkpoint. secure_delete zeroes freed content as part of the delete.
        _eng w "PRAGMA s${seg}.secure_delete=ON;" || :
        while :; do
            _txn_begin || return 1
            _eng w "DELETE FROM s${seg}.run_events
                    WHERE rid = (SELECT rid FROM runs WHERE run_id = :run)
                      AND seq IN (SELECT seq FROM s${seg}.run_events
                                  WHERE rid = (SELECT rid FROM runs WHERE run_id = :run)
                                  ORDER BY seq LIMIT 10000);
SELECT changes();" || { _txn_rollback; _fail "$AG_E_INTERNAL" "purge failed: ${AG_ERR%%$'\n'*}"; return 1; }
            n=${AG_OUT%%$'\n'*}
            _txn_commit || { _txn_rollback; return 1; }
            total=$(( total + n ))
            (( n == 0 )) && break
        done
                # Offloaded payloads live in blobs, not run_events. Deleting only event
                # rows left every payload > AG_BLOB_MIN readable, while purge said
                # "physical".
                #
                # Blobs are shared, so drop only the ones nothing references.
        _txn_begin || return 1
        _eng w "DELETE FROM s${seg}.blobs
                WHERE hash NOT IN (SELECT body_ref FROM s${seg}.run_events WHERE body_ref IS NOT NULL);
SELECT changes();" || { _txn_rollback; _fail "$AG_E_INTERNAL" "blob purge failed: ${AG_ERR%%$'\n'*}"; return 1; }
        blobs_gone=${AG_OUT%%$'\n'*}
        _txn_commit || { _txn_rollback; return 1; }
                # push the zeroed pages from the -wal into the main file, then hand the
                # freed pages back to the OS
        _eng w "PRAGMA s${seg}.wal_checkpoint(TRUNCATE);" || :
        _eng w "PRAGMA s${seg}.incremental_vacuum(2000);" || :
        _eng w "PRAGMA s${seg}.wal_checkpoint(TRUNCATE);" || :
        _eng w "PRAGMA s${seg}.secure_delete=FAST;" || :
    fi
    _eng w "UPDATE runs SET status = 'purged', ended_ms = coalesce(ended_ms, CAST(unixepoch('subsec')*1000 AS INTEGER)) WHERE run_id = :run;" || return 1
    printf '{"run":"%s","purged_events":%d,"purged_blobs":%d,"mode":"%s"}\n' \
           "$run" "$total" "${blobs_gone:-0}" "$mode"
}

ag_segment_rewrite() {  # <run> : GDPR hard-delete a run's data out of its SEALED segment
        # Regular purge only TOMBSTONES a run in a sealed segment.
        #
        # Erasure needs the bytes gone now even though live runs share the file:
        # rebuild without them, swap atomically, re-hash, scrub the catalog.
    local run=''
    while (( $# )); do case $1 in
        --run) _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        -*)    _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
        *)     run=$1; shift ;;
    esac; done
    [[ -n $run ]] || { _fail "$AG_E_PARAMS" 'usage: segment-rewrite <run>'; return 1; }
    ag_open || return 1
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    local st; st=${| _run_status "$run"; }
    [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    _bindv w :run "$run" || return 1
    local rid seg segstate path
    rid=${| _sc w "SELECT rid FROM runs WHERE run_id=:run;"; }
    seg=${| _sc w "SELECT seg_id FROM runs WHERE run_id=:run;"; }
    segstate=${| _sc w "SELECT state FROM segments WHERE seg_id=$seg;"; }
    path=${| _sc w "SELECT path FROM segments WHERE seg_id=$seg;"; }
    [[ $segstate == sealed || $segstate == archived ]] \
        || { _fail "$AG_E_PARAMS" "segment $seg is '$segstate'; segment-rewrite applies only to sealed segments (use purge otherwise)"; return 1; }
    [[ -f $path ]] || { _fail "$AG_E_STORAGE" "segment file missing: $path"; return 1; }
    local kids
    kids=${| _sc w "SELECT count(*) FROM runs WHERE parent_rid=$rid AND status<>'purged';"; }
    (( kids == 0 )) || { _fail "$AG_E_PARAMS" "run has $kids unpurged fork(s); erase children first"; return 1; }

        # 1. build a rewritten copy WITHOUT the target run's rows + any blob it alone held
    local tmp="$path.rewrite.$$" oldq=${path//\'/\'\'}
    local cols='rid,seq,tid,aid,caused_by,payload,body_ref,ctx,hash,chain,idem,tool_name,model,ts_ms'
    rm -f "$tmp" "$tmp-wal" "$tmp-shm" 2>/dev/null || :
    "$AG_SQLITE" -batch "$tmp" "
${ _ddl_segment main; }
ATTACH 'file:${oldq}?immutable=1' AS src;
INSERT INTO main.run_events($cols) SELECT $cols FROM src.run_events WHERE rid<>$rid;
INSERT INTO main.blobs SELECT * FROM src.blobs
    WHERE hash IN (SELECT DISTINCT body_ref FROM main.run_events WHERE body_ref IS NOT NULL);
DETACH src;
PRAGMA journal_mode=DELETE; ANALYZE; PRAGMA optimize; VACUUM;" >/dev/null 2>&1 \
        || { rm -f "$tmp"; _fail "$AG_E_STORAGE" "segment rewrite build failed for segment $seg"; return 1; }
    local ig gone
    ig=${ "$AG_SQLITE" -batch "$tmp" 'PRAGMA integrity_check;' 2>/dev/null; }
    [[ $ig == ok ]] || { rm -f "$tmp"; _fail "$AG_E_STORAGE" "rewritten segment failed integrity_check"; return 1; }
    gone=${ "$AG_SQLITE" -batch "$tmp" "SELECT count(*) FROM run_events WHERE rid=$rid;" 2>/dev/null; }
    [[ $gone == 0 ]] || { rm -f "$tmp"; _fail "$AG_E_INTERNAL" "target run rows survived the rewrite"; return 1; }

        # 2. detach the old file, then swap in the new one (rename is atomic).
        #
        # Bytes leave disk HERE, before the catalog update, so a crash after the
        # swap still satisfies erasure; verify-files flags the stale hash.
    if [[ -n ${AG_ATT[w$'\t'$seg]:-} ]]; then
        _eng w "DETACH s${seg};" 2>/dev/null || :; unset "AG_ATT[w$'\t'$seg]"; _rebuild_views w
    fi
    chmod u+w "$path" 2>/dev/null || :
    mv -f "$tmp" "$path" || { rm -f "$tmp"; _fail "$AG_E_STORAGE" "failed to swap rewritten segment into place"; return 1; }
    rm -f "$path-wal" "$path-shm" 2>/dev/null || :
    chmod 400 "$path" 2>/dev/null || :

        # 3. reconcile the catalog: scrub the run's PII + tombstone it, refresh the
        # segment's hash/size/counts and rollups from the rewritten file.
    local sh sz aq=${path//\'/\'\'}
    sh=${ _file_hash "$path"; }
    [[ $sh =~ ^[0-9a-f]{64}$ ]] || { _fail "$AG_E_STORAGE" "post-rewrite hash failed for segment $seg"; return 1; }
    sz=${ _p_fsize "$path"; }
    _eng w "ATTACH 'file:${aq}?immutable=1' AS rw_src;" || return 1
    _txn_begin || { _eng w "DETACH rw_src;" 2>/dev/null; return 1; }
    _eng w "UPDATE runs SET status='purged', goal='', tags='[]', env='{}',
              ended_ms=coalesce(ended_ms, CAST(unixepoch('subsec')*1000 AS INTEGER))
            WHERE run_id=:run;
DELETE FROM seg_stats WHERE seg_id=$seg;
INSERT INTO seg_stats(seg_id,dim,key,n,cost_usd,tokens,dur_ms_sum)
  SELECT $seg,'model',model,count(*),sum(cost_usd),sum(tokens_total),NULL
    FROM rw_src.run_events WHERE model IS NOT NULL AND tid IN(6,7) GROUP BY model
  UNION ALL
  SELECT $seg,'tool',tool_name,count(*),NULL,NULL,sum(dur_ms)
    FROM rw_src.run_events WHERE tool_name IS NOT NULL AND tid IN(8,9) GROUP BY tool_name
  UNION ALL SELECT $seg,'meta','events',(SELECT count(*) FROM rw_src.run_events),NULL,NULL,NULL
  UNION ALL SELECT $seg,'meta','blobs',(SELECT count(*) FROM rw_src.blobs),NULL,NULL,NULL;
UPDATE segments SET size_bytes=${sz:-NULL},
    event_count=(SELECT count(*) FROM rw_src.run_events),
    run_count=(SELECT count(*) FROM runs WHERE seg_id=$seg),
    file_sha3=unhex('$sh')
  WHERE seg_id=$seg;" \
        || { local e2=$AG_ERR; _txn_rollback; _eng w "DETACH rw_src;" 2>/dev/null; _fail "$AG_E_INTERNAL" "rewrite catalog update: ${e2%%$'\n'*}"; return 1; }
    _txn_commit || { _txn_rollback; _eng w "DETACH rw_src;" 2>/dev/null; return 1; }
    _eng w "DETACH rw_src;" 2>/dev/null || :
        # Scrubbing in place clears the ROW; the old bytes linger in the catalog's
        # freelist until VACUUM.
        #
        # In WAL mode the clean pages then sit in the -wal, so follow with
        # wal_checkpoint(TRUNCATE): both are on-disk PII.
    if _eng w "VACUUM;" 2>/dev/null; then
        _eng w "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || :
    else
        _dbg "segment-rewrite: catalog VACUUM deferred (busy); PII row cleared, freelist compaction pending"
    fi
    _note "segment-rewrite: hard-deleted run $run from sealed segment $seg"
    printf '{"run":"%s","segment":%s,"mode":"segment-rewrite"}\n' "$run" "$seg"
}

ag_stats() {  # whole-store aggregation across every segment (PLAN 8d)
        # Sealed segments are immutable and their rollups were finalized into
        # seg_stats at seal time — read those, never re-scan a 64GB file.
        #
        # Non-sealed ones aggregate live, ONE at a time to stay inside MAX_ATTACHED.
    ag_open || return 1
    local e; e=${| _engine_for_read; }
    _eng "$e" "DROP TABLE IF EXISTS temp._sacc;
CREATE TEMP TABLE _sacc(dim TEXT, key TEXT, n INTEGER, cost REAL, tokens INTEGER, dur INTEGER);" \
        || { _fail "$AG_E_INTERNAL" "stats acc: ${AG_ERR%%$'\n'*}"; return 1; }
        # sealed/archived: finalized rollups (model, tool, and meta events/blobs)
    _eng "$e" "INSERT INTO _sacc(dim,key,n,cost,tokens,dur)
        SELECT dim,key,n,cost_usd,tokens,dur_ms_sum FROM seg_stats
        WHERE seg_id IN (SELECT seg_id FROM segments WHERE state IN ('sealed','archived'));" \
        || { _fail "$AG_E_INTERNAL" "stats sealed: ${AG_ERR%%$'\n'*}"; return 1; }
        # non-sealed: live aggregate, bounded to one extra attach at a time
    local nonsealed sid
    nonsealed=${| _sc "$e" "SELECT coalesce(group_concat(seg_id,' '),'') FROM segments WHERE state IN ('active','draining');"; }
    for sid in $nonsealed; do
        _seg_require "$e" "$sid" || return 1
        _eng "$e" "INSERT INTO _sacc(dim,key,n,cost,tokens,dur)
            SELECT 'model',model,count(*),sum(cost_usd),sum(tokens_total),NULL
              FROM s${sid}.run_events WHERE model IS NOT NULL AND tid IN(6,7) GROUP BY model
            UNION ALL
            SELECT 'tool',tool_name,count(*),NULL,NULL,sum(dur_ms)
              FROM s${sid}.run_events WHERE tool_name IS NOT NULL AND tid IN(8,9) GROUP BY tool_name
            UNION ALL SELECT 'meta','events',(SELECT count(*) FROM s${sid}.run_events),NULL,NULL,NULL
            UNION ALL SELECT 'meta','blobs',(SELECT count(*) FROM s${sid}.blobs),NULL,NULL,NULL;" \
            || { _fail "$AG_E_INTERNAL" "stats seg $sid: ${AG_ERR%%$'\n'*}"; return 1; }
    done
    _scalar "$e" "SELECT json_object(
        'events', (SELECT coalesce(sum(n),0) FROM _sacc WHERE dim='meta' AND key='events'),
        'runs',   (SELECT count(*) FROM runs),
        'blobs',  (SELECT coalesce(sum(n),0) FROM _sacc WHERE dim='meta' AND key='blobs'),
        'models', (SELECT coalesce(json_group_array(json_object('model', key, 'n', n, 'cost_usd', c, 'tokens', tk)), '[]')
                   FROM (SELECT key, sum(n) n, sum(cost) c, sum(tokens) tk
                         FROM _sacc WHERE dim='model' GROUP BY key ORDER BY key)),
        'tools',  (SELECT coalesce(json_group_array(json_object('tool', key, 'n', n, 'dur_ms', d)), '[]')
                   FROM (SELECT key, sum(n) n, sum(dur) d
                         FROM _sacc WHERE dim='tool' GROUP BY key ORDER BY key)));" \
        || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    printf '\n'
}

# Insights (PLAN 4.2/7.5, our extension). Cost, tokens and latency come from
# the VIRTUAL columns over ctx, so this is a pure scan.
#
# ag_stats: what the store costs. ag_insights: where THIS run went.
ag_insights() {  # [--run R] [--limit N]
    local run='' limit=50
    while (( $# )); do case $1 in
        --run)   _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --limit) _optval "$@" || return 1; limit=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    if ! _v_int "$limit" || (( limit < 1 || limit > AG_LIMIT_MAX )); then
        _fail "$AG_E_PARAMS" "limit must be 1..$AG_LIMIT_MAX"; return 1
    fi
    local e; e=${| _engine_for_read; }
    local scope
    if [[ -n $run ]]; then
        _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
        local st; st=${| _run_status "$run"; }
        [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
        [[ $st != purged ]] || { _fail "$AG_E_NORUN" "run is purged (events deleted): $run"; return 1; }
        _bindv "$e" :run "$run" || return 1
        _route_run "$e" || return 1
        scope="$AG_SQL_LINEAGE, ev AS (
            SELECT e.* FROM lineage l
            JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto))"
    else
                # whole store: every non-sealed segment, and nothing from sealed ones
                # (their per-event ctx is finalized in seg_stats — see ag_stats).
        local sids; sids=${| _sc "$e" "SELECT coalesce(group_concat(seg_id,' '),'') FROM segments WHERE state IN ('active','draining');"; }
        local numlist='^[0-9]+( [0-9]+)*$'
        [[ -z $sids || $sids =~ $numlist ]] \
            || { _fail "$AG_E_INTERNAL" 'malformed segment list'; return 1; }
        local sid
        for sid in $sids; do _seg_require "$e" "$sid" || return 1; done
        scope="WITH ev AS (SELECT * FROM v_run_events)"
        _bindv "$e" :run '' || return 1
    fi
    _scalarf "$e" "$scope
SELECT json_object(
  'scope', CASE WHEN :run = '' THEN 'store' ELSE :run END,
  'events', (SELECT count(*) FROM ev),
  'cost_usd', (SELECT round(coalesce(sum(cost_usd),0), 6) FROM ev),
  'tokens',   (SELECT coalesce(sum(tokens_total),0) FROM ev),
  'dur_ms',   (SELECT coalesce(sum(dur_ms),0) FROM ev),
  'by_type', (SELECT coalesce(json_group_array(json_object(
                 'type', name, 'n', n, 'cost_usd', c, 'tokens', tk, 'dur_ms', d)), '[]')
              FROM (SELECT t.name AS name, count(*) AS n,
                           round(coalesce(sum(ev.cost_usd),0),6) AS c,
                           coalesce(sum(ev.tokens_total),0) AS tk,
                           coalesce(sum(ev.dur_ms),0) AS d
                    FROM ev JOIN event_types t ON t.tid = ev.tid
                    GROUP BY t.name ORDER BY n DESC, t.name LIMIT $limit)),
  'by_model', (SELECT coalesce(json_group_array(json_object(
                 'model', model, 'n', n, 'cost_usd', c, 'tokens', tk,
                 'dur_ms_min', dmin, 'dur_ms_avg', davg, 'dur_ms_max', dmax)), '[]')
              FROM (SELECT model, count(*) AS n,
                           round(coalesce(sum(cost_usd),0),6) AS c,
                           coalesce(sum(tokens_total),0) AS tk,
                           min(dur_ms) AS dmin,
                           CAST(round(coalesce(avg(dur_ms),0)) AS INTEGER) AS davg,
                           max(dur_ms) AS dmax
                    FROM ev WHERE model IS NOT NULL AND tid IN (6,7)
                    GROUP BY model ORDER BY c DESC, model LIMIT $limit)),
  'by_tool', (SELECT coalesce(json_group_array(json_object(
                 'tool', tool_name, 'n', n,
                 'dur_ms_min', dmin, 'dur_ms_avg', davg, 'dur_ms_max', dmax,
                 'dur_ms_total', dtot)), '[]')
              FROM (SELECT tool_name, count(*) AS n, min(dur_ms) AS dmin,
                           CAST(round(coalesce(avg(dur_ms),0)) AS INTEGER) AS davg,
                           max(dur_ms) AS dmax, coalesce(sum(dur_ms),0) AS dtot
                    FROM ev WHERE tool_name IS NOT NULL AND tid IN (8,9)
                    GROUP BY tool_name ORDER BY dtot DESC, tool_name LIMIT $limit)),
  'cache', json_object(
      'requests', (SELECT count(*) FROM ev WHERE tid IN (6,8)),
      'answered', (SELECT count(*) FROM ev WHERE tid IN (7,9) AND req_hash IS NOT NULL)));" \
        || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    printf '\n'
}

# =============================================================================
# ag_scan (PLAN 7.5 / 9): raw aggregate SQL streamed over every segment.
#
# CLI-ONLY, never RPC-exposed. Each segment opens in its OWN short-lived
# process as `main`, -readonly + immutable + query_only.
#
# Damage is bounded by construction, which is also why --parallel is safe.
# =============================================================================

# That bound held for the SQL and not the text around it.
#
# The sqlite3 CLI treats a line whose FIRST character is '.' as a dot-command,
# so `.shell` ran commands and `.output` wrote files.
#
# This check is the exact complement of that rule (column 0), so nothing gets
# past it; a leading `.5` literal is still expressible, indented.
#
# `-safe` mode is not the answer: it also refuses ATTACH, which the catalog needs.
_v_scan_sql() {  # reject sqlite3 CLI dot-commands hiding in operator SQL
    local first=${1%%$'\n'*} rest=$1
    [[ $first == .* ]] && { _fail "$AG_E_PARAMS" \
        'scan SQL may not contain a line starting with "." (sqlite3 dot-commands such as .shell/.output/.import are not SQL); indent the line if you meant a float literal'; return 1; }
    [[ $rest == *$'\n.'* ]] && { _fail "$AG_E_PARAMS" \
        'scan SQL may not contain a line starting with "." (sqlite3 dot-commands such as .shell/.output/.import are not SQL); indent the line if you meant a float literal'; return 1; }
    return 0
}

ag_scan() {  # <sql> [--parallel N] [--sealed-only]
    local sql='' par=1 states="'active','draining','sealed','archived'"
    while (( $# )); do case $1 in
        --parallel) _optval "$@" || return 1; par=$REPLY; shift 2 ;;
        --sealed-only) states="'sealed','archived'"; shift ;;
        --)         shift; sql=${1:-}; shift 2>/dev/null ;;
        -*)         _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
        *)          sql=$1; shift ;;
    esac; done
    [[ -n $sql ]] || { _fail "$AG_E_PARAMS" 'usage: scan [--parallel N] <sql>  (tables: run_events, blobs, cat.runs, cat.event_types; :seg is bound)'; return 1; }
    _v_scan_sql "$sql" || return 1
    _v_int "$par" && (( par >= 1 && par <= 64 )) \
        || { _fail "$AG_E_PARAMS" '--parallel must be 1..64'; return 1; }
    ag_open || return 1
        # One row per segment, read from AG_OUT: group_concat through _sc returns
        # only the FIRST LINE, so this loop silently ran for a single segment.
    _eng w "SELECT seg_id || '|' || state || '|' || path
            FROM segments WHERE state IN ($states) ORDER BY seg_id;" \
        || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    local rows=$AG_OUT
    [[ -n ${rows//[$'\n ']/} ]] || { printf ''; return 0; }

    local cat="$AG_DIR/ag-catalog.db"
    local -a outs=() pids=()
    local sid state path outf
    while IFS='|' read -r sid state path; do
        [[ $sid =~ ^[0-9]+$ ]] || continue
        [[ -f $path ]] || continue
        outf="$AG_TMP/scan.$sid"
        outs+=("$outf")
        _scan_one "$sid" "$state" "$path" "$cat" "$sql" >"$outf" 2>"$outf.err" &
        pids+=($!)
                # NEVER a bare `wait` here: the engine coprocesses are also background
                # jobs of this shell and never exit, so `wait` would block forever.
        if (( ${#pids[@]} >= par )); then wait -n "${pids[@]}" 2>/dev/null || :; fi
    done <<< "$rows"
    local p
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || :; done
    local rc=0 f
    for f in "${outs[@]}"; do
        [[ -s $f ]] && cat "$f"
        if [[ -s $f.err ]]; then
            printf 'active-graph: scan error on %s: %s\n' "${f##*/}" "${ head -1 "$f.err"; }" >&2
            rc=1
        fi
        rm -f "$f" "$f.err"
    done
    (( rc == 0 )) || { _fail "$AG_E_PARAMS" 'scan SQL failed on at least one segment'; return 1; }
    return 0
}

_scan_one() {  # $1=segid $2=state $3=path $4=catalog-path $5=sql
        # A sealed file is immutable, so immutable=1 is safe and lock-free.
        #
        # A live segment is not: it reads past a hot WAL and returns torn data.
    local uri
    case $2 in
        sealed|archived) uri="file:${3//\'/\'\'}?immutable=1" ;;
        *)               uri="file:${3//\'/\'\'}?mode=ro" ;;
    esac
    printf '.parameter init\n.parameter set :seg %s\nATTACH %s AS cat;\nPRAGMA query_only=ON;\n%s\n' \
        "$1" "'file:${4//\'/\'\'}?mode=ro'" "$5" \
        | "$AG_SQLITE" -batch -readonly "$uri"
}

# =============================================================================
# ag_migrate (PLAN 9 / 8.5b): version-gated, idempotent, resumable steps.
# Every step is safe to re-run, so a crash mid-migrate recovers by re-running.
# =============================================================================
_migrate_segment_v1_v2() {  # $1 = path ; adds the v2 columns and backfills them
    local p=$1 sealed=$2
    local pq=${p//\'/\'\'}       # split: ${p//...} would expand before `local p` binds
    [[ -f $p ]] || return 0
        # mode=ro, NOT immutable=1: an active segment still has a hot -wal, and
        # opening it immutable either fails or reads past the WAL.
    local uv; uv=${ "$AG_SQLITE" -batch -readonly "file:${pq}?mode=ro" 'PRAGMA user_version;' 2>/dev/null; }
    [[ $uv == 1 ]] || return 0                 # already migrated (or not v1)
    (( sealed )) && chmod u+w "$p" 2>/dev/null
    AG_MIGRATE_ERR=${ "$AG_SQLITE" -batch "$p" "
BEGIN IMMEDIATE;
ALTER TABLE run_events ADD COLUMN req_hash BLOB;
ALTER TABLE run_events ADD COLUMN obj_kind TEXT;
ALTER TABLE run_events ADD COLUMN obj_n    INTEGER;
-- backfill the deterministic-id ordinal from the ids already in the payloads
UPDATE run_events SET
  obj_kind = json(coalesce(payload,(SELECT body FROM blobs WHERE hash = body_ref))) ->> '\$.kind',
  obj_n = CAST(substr(json(coalesce(payload,(SELECT body FROM blobs WHERE hash = body_ref))) ->> '\$.id',
               instr(json(coalesce(payload,(SELECT body FROM blobs WHERE hash = body_ref))) ->> '\$.id', '#') + 1)
          AS INTEGER)
WHERE tid = 10;
UPDATE run_events SET
  obj_kind = '',
  obj_n = CAST(substr(json(coalesce(payload,(SELECT body FROM blobs WHERE hash = body_ref))) ->> '\$.frame', 2)
          AS INTEGER)
WHERE tid = 15;
-- backfill the request hash from the causality already recorded
UPDATE run_events AS r SET req_hash = (
    SELECT q.hash FROM run_events q
    WHERE q.rid = r.rid AND q.seq = r.caused_by AND q.hash IS NOT NULL)
WHERE r.tid IN (7,9) AND r.caused_by IS NOT NULL;
COMMIT;
CREATE INDEX IF NOT EXISTS idx_re_reqhash ON run_events(req_hash, tid) WHERE tid IN (7,9);
CREATE INDEX IF NOT EXISTS idx_re_objn ON run_events(rid, obj_kind, obj_n) WHERE obj_n IS NOT NULL;
PRAGMA user_version = 2;
ANALYZE;" 2>&1 >/dev/null; }
    (( sealed )) && chmod 400 "$p" 2>/dev/null
    uv=${ "$AG_SQLITE" -batch -readonly "file:${pq}?mode=ro" 'PRAGMA user_version;' 2>/dev/null; }
    [[ $uv == 2 ]] || return 1
    return 0
}

# v2 -> v3 changed only the catalog, so a v2 segment needs its version stamped
# forward, nothing rewritten. v1 segments migrate columns first.
_migrate_segment_stamp() {  # $1 = path, $2 = sealed
    local p=$1 sealed=$2
    local pq=${p//\'/\'\'}
    [[ -f $p ]] || return 0
    _migrate_segment_v1_v2 "$p" "$sealed" || return 1
    local uv; uv=${ "$AG_SQLITE" -batch -readonly "file:${pq}?mode=ro" 'PRAGMA user_version;' 2>/dev/null; }
    [[ $uv =~ ^[0-9]+$ ]] || return 1
    (( uv == AG_SCHEMA_VERSION )) && return 0
    (( sealed )) && chmod u+w "$p" 2>/dev/null
    AG_MIGRATE_ERR=${ "$AG_SQLITE" -batch "$p" "PRAGMA user_version = $AG_SCHEMA_VERSION;" 2>&1 >/dev/null; }
    (( sealed )) && chmod 400 "$p" 2>/dev/null
    uv=${ "$AG_SQLITE" -batch -readonly "file:${pq}?mode=ro" 'PRAGMA user_version;' 2>/dev/null; }
    [[ $uv == "$AG_SCHEMA_VERSION" ]] || return 1
    return 0
}

ag_migrate() {  # [--dry-run] : bring an older store up to AG_SCHEMA_VERSION
    local dry=0
    while (( $# )); do case $1 in
        --dry-run) dry=1; shift ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    _v_config || return 1
    _sqlite_resolve || return 1
    if [[ -z $AG_TMP ]]; then
        AG_TMP=${ mktemp -d "${TMPDIR:-/tmp}/ag.XXXXXXXX"; } || { _fail "$AG_E_STORAGE" 'mktemp failed'; return 1; }
        chmod 700 "$AG_TMP"
    fi
    _platform_init
    local cat="$AG_DIR/ag-catalog.db"
    [[ -f $cat ]] || { _fail "$AG_E_STORAGE" "no store at $AG_DIR"; return 1; }
    local from; from=${ "$AG_SQLITE" -batch -readonly "$cat" 'PRAGMA user_version;' 2>/dev/null; }
    [[ $from =~ ^[0-9]+$ ]] || { _fail "$AG_E_SCHEMA" 'cannot read catalog user_version'; return 1; }
    if (( from == AG_SCHEMA_VERSION )); then
        printf '{"from":%s,"to":%s,"migrated":false,"reason":"already current"}\n' "$from" "$AG_SCHEMA_VERSION"
        return 0
    fi
    if (( from > AG_SCHEMA_VERSION )); then
        _fail "$AG_E_SCHEMA" "store schema v$from is NEWER than this build (v$AG_SCHEMA_VERSION); upgrade active-graph.sh"; return 1
    fi
    if (( from < 1 )); then
        _fail "$AG_E_SCHEMA" "no migration path from schema v$from to v$AG_SCHEMA_VERSION"; return 1
    fi
    if (( dry )); then
        local steps=''
        (( from <= 1 )) && steps+='"v1->v2: segment columns req_hash/obj_kind/obj_n + backfill",'
        (( from <= 2 )) && steps+='"v2->v3: catalog behaviors table",'
        steps+='"catalog fingerprint refresh","sealed segments re-hashed"'
        printf '{"from":%s,"to":%s,"migrated":false,"dry_run":true,"steps":[%s]}\n' \
               "$from" "$AG_SCHEMA_VERSION" "$steps"
        return 0
    fi

        # 1a. catalog-only steps (idempotent DDL, so a crashed migrate re-runs safely)
    if (( from <= 2 )); then
        "$AG_SQLITE" -batch "$cat" "
CREATE TABLE IF NOT EXISTS behaviors (
    bid        INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    on_type    TEXT NOT NULL,
    pattern    TEXT NOT NULL DEFAULT '',
    where_expr TEXT NOT NULL DEFAULT '',
    absent     TEXT NOT NULL DEFAULT '',
    argv       TEXT NOT NULL,
    enabled    INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
    created_ms INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec')*1000 AS INTEGER)),
    CHECK (json_valid(argv) AND json_type(argv) = 'array')
) STRICT;" >/dev/null 2>&1 \
            || { _fail "$AG_E_SCHEMA" 'v2->v3 catalog step failed'; return 1; }
    fi

        # 1b. every segment file
    local rows; rows=${ "$AG_SQLITE" -batch -readonly "$cat" \
        "SELECT seg_id || '|' || state || '|' || path FROM segments WHERE state <> 'dropped' ORDER BY seg_id;" 2>/dev/null; }
    local -a done_segs=() reseal=()
    local sid state path sealed
    while IFS='|' read -r sid state path; do
        [[ $sid =~ ^[0-9]+$ ]] || continue
        sealed=0; [[ $state == sealed || $state == archived ]] && sealed=1
        _migrate_segment_stamp "$path" "$sealed" \
            || { _fail "$AG_E_SCHEMA" "segment $sid migration failed ($path): ${AG_MIGRATE_ERR%%$'\n'*}"; return 1; }
        done_segs+=("$sid")
        (( sealed )) && reseal+=("$sid|$path")
    done <<< "$rows"

        # 2. sealed files changed on disk -> their recorded digest must be refreshed,
        #    or ag_verify_files would report every one of them as corrupt.
    local entry sh sz
    for entry in "${reseal[@]}"; do
        sid=${entry%%|*}; path=${entry#*|}
        sh=${ _file_hash "$path"; }
        [[ $sh =~ ^[0-9a-f]{64}$ ]] || { _fail "$AG_E_STORAGE" "re-hash failed for segment $sid"; return 1; }
        sz=${ _p_fsize "$path"; }
        "$AG_SQLITE" -batch "$cat" \
            "UPDATE segments SET file_sha3=unhex('$sh'), size_bytes=${sz:-NULL} WHERE seg_id=$sid;" \
            >/dev/null 2>&1 || { _fail "$AG_E_STORAGE" "catalog re-hash update failed for segment $sid"; return 1; }
        chmod 400 "$path" 2>/dev/null || :
    done

        # 3. catalog: bump the version and re-stamp the fingerprints the open path checks
    "$AG_SQLITE" -batch "$cat" "PRAGMA user_version = $AG_SCHEMA_VERSION;" >/dev/null 2>&1 \
        || { _fail "$AG_E_SCHEMA" 'catalog version bump failed'; return 1; }
    _engine_spawn w "$cat" "${ _engine_init_sql rw; }" || { _fail "$AG_E_INTERNAL" 'engine spawn failed'; return 1; }
    AG_ENG_MODE[w]=rw
    local asid sp spq ch sh2
    asid=${| _sc w "SELECT seg_id FROM segments WHERE state='active' ORDER BY seg_id DESC LIMIT 1;"; }
    sp=${| _sc w "SELECT path FROM segments WHERE seg_id = $asid;"; }
    spq=${sp//\'/\'\'}
    _eng w "ATTACH '$spq' AS s${asid};" || { _fail "$AG_E_STORAGE" 'cannot attach active segment'; return 1; }
    ch=${ _schema_sha3 w main; }
    sh2=${ _schema_sha3 w "s${asid}"; }
    _eng w "INSERT INTO config(key,value) VALUES ('catalog_schema_sha3','$ch')
              ON CONFLICT(key) DO UPDATE SET value=excluded.value;
            INSERT INTO config(key,value) VALUES ('segment_schema_sha3','$sh2')
              ON CONFLICT(key) DO UPDATE SET value=excluded.value;
            INSERT INTO config(key,value) VALUES ('ag_version','$AG_VERSION')
              ON CONFLICT(key) DO UPDATE SET value=excluded.value;
            INSERT INTO config(key,value) VALUES ('file_hash_algo','${AG_FILE_HASH_ALGO:-none}')
              ON CONFLICT(key) DO UPDATE SET value=excluded.value;" \
        || { _fail "$AG_E_SCHEMA" "fingerprint re-stamp failed: ${AG_ERR%%$'\n'*}"; return 1; }
    _engine_stop
    local sl; printf -v sl '%s,' "${done_segs[@]}"
    printf '{"from":%s,"to":%s,"migrated":true,"segments":[%s],"resealed":%d}\n' \
           "$from" "$AG_SCHEMA_VERSION" "${sl%,}" "${#reseal[@]}"
}

# =============================================================================
# Behaviours (paper §3) — the reactive core. Behaviours react to graph changes
# and emit events; no component instructs another.
#
# The runtime owns subscription, matching, dispatch, provenance and fire-once.
#
# The BODY is an external program run as an argv ARRAY, never eval: match JSON
# on stdin, NDJSON events on stdout.
#
# Those are emitted with caused_by pointing at its behavior.started, so every
# effect stays in the log and replays.
#
# Subscriptions match a GRAPH SHAPE, not just an event type:
#
#   --on object.created
#   --match '(c:claim)-[:addresses]->(q:question)'   compiles to SQL joins
#   --absent 'q-[:answered_by]->'                    adds NOT EXISTS
#   --                                               body argv from here on
# =============================================================================
_v_ident() { [[ $1 =~ ^[a-z][a-z0-9_]{0,31}$ ]]; }

# Compile the Cypher subset to SQL over the projection. Grammar:
#
#   pattern := node (rel node)*        (max 3 nodes / 2 hops)
#   node    := '(' var [':' kind] ')'
#
#   rel     := '-[:' type ']->' | '<-[:' type ']-'
#
# Sets AG_PAT_VARS and AG_PAT_SQL.
AG_PAT_VARS='' AG_PAT_SQL='' AG_PAT_SEL=''
_pattern_compile() {  # $1 = pattern, $2 = rid, $3 = where, $4 = absent
    local pat=$1 rid=$2 wex=$3 abs=$4
    AG_PAT_VARS='' AG_PAT_SQL='' AG_PAT_SEL=''
    local -a vars=() kinds=() rtypes=() rdirs=()
    local rest=$pat n=0
    while [[ -n ${rest//[[:space:]]/} ]]; do
        [[ $rest =~ ^[[:space:]]*\(([a-z][a-z0-9_]*)(:([a-z][a-z0-9_]*))?\)(.*)$ ]] \
            || { _fail "$AG_E_PARAMS" "cannot parse pattern near: ${rest:0:40}"; return 1; }
        vars+=("${BASH_REMATCH[1]}"); kinds+=("${BASH_REMATCH[3]}")
        rest=${BASH_REMATCH[4]}
        (( ++n > 3 )) && { _fail "$AG_E_PARAMS" 'pattern supports at most 3 nodes (2 hops)'; return 1; }
        [[ -n ${rest//[[:space:]]/} ]] || break
        if [[ $rest =~ ^[[:space:]]*-\[:([a-z][a-z0-9_]*)\]-\>(.*)$ ]]; then
            rtypes+=("${BASH_REMATCH[1]}"); rdirs+=(out); rest=${BASH_REMATCH[2]}
        elif [[ $rest =~ ^[[:space:]]*\<-\[:([a-z][a-z0-9_]*)\]-(.*)$ ]]; then
            rtypes+=("${BASH_REMATCH[1]}"); rdirs+=(in); rest=${BASH_REMATCH[2]}
        else
            _fail "$AG_E_PARAMS" "cannot parse relation near: ${rest:0:40}"; return 1
        fi
    done
    (( ${#vars[@]} )) || { _fail "$AG_E_PARAMS" 'empty pattern'; return 1; }

    local from="ag_nodes n0" where="n0.rid = $rid" sel='' i
    [[ -n ${kinds[0]} ]] && where+=" AND n0.kind = '${kinds[0]}'"
    for (( i=0; i<${#rtypes[@]}; i++ )); do
        local j=$(( i + 1 ))
        if [[ ${rdirs[$i]} == out ]]; then
            from+=" JOIN ag_edges e$i ON e$i.rid = $rid AND e$i.kind = '${rtypes[$i]}' AND e$i.src_obj = n$i.obj_id"
            from+=" JOIN ag_nodes n$j ON n$j.rid = $rid AND n$j.obj_id = e$i.dst_obj"
        else
            from+=" JOIN ag_edges e$i ON e$i.rid = $rid AND e$i.kind = '${rtypes[$i]}' AND e$i.dst_obj = n$i.obj_id"
            from+=" JOIN ag_nodes n$j ON n$j.rid = $rid AND n$j.obj_id = e$i.src_obj"
        fi
        [[ -n ${kinds[$j]} ]] && where+=" AND n$j.kind = '${kinds[$j]}'"
    done
        # negative edge guard: "<var>-[:type]->"  or  "<var><-[:type]-"
    if [[ -n $abs ]]; then
        local av at adir
        if [[ $abs =~ ^[[:space:]]*([a-z][a-z0-9_]*)-\[:([a-z][a-z0-9_]*)\]-\>[[:space:]]*$ ]]; then
            av=${BASH_REMATCH[1]}; at=${BASH_REMATCH[2]}; adir=out
        elif [[ $abs =~ ^[[:space:]]*([a-z][a-z0-9_]*)\<-\[:([a-z][a-z0-9_]*)\]-[[:space:]]*$ ]]; then
            av=${BASH_REMATCH[1]}; at=${BASH_REMATCH[2]}; adir=in
        else
            _fail "$AG_E_PARAMS" "cannot parse --absent (expected 'var-[:type]->' or 'var<-[:type]-')"; return 1
        fi
        local ai=-1
        for (( i=0; i<${#vars[@]}; i++ )); do [[ ${vars[$i]} == "$av" ]] && ai=$i; done
        (( ai >= 0 )) || { _fail "$AG_E_PARAMS" "--absent names unknown variable '$av'"; return 1; }
        if [[ $adir == out ]]; then
            where+=" AND NOT EXISTS (SELECT 1 FROM ag_edges x WHERE x.rid = $rid AND x.kind = '$at' AND x.src_obj = n$ai.obj_id)"
        else
            where+=" AND NOT EXISTS (SELECT 1 FROM ag_edges x WHERE x.rid = $rid AND x.kind = '$at' AND x.dst_obj = n$ai.obj_id)"
        fi
    fi
        # predicate: variable names are rewritten to their node aliases
    if [[ -n $wex ]]; then
        local w=$wex
        for (( i=0; i<${#vars[@]}; i++ )); do w=${w//"${vars[$i]}"./n$i.}; done
        where+=" AND ($w)"
    fi
    local keyexpr='' bindexpr='' order=''
    for (( i=0; i<${#vars[@]}; i++ )); do
        keyexpr+="${keyexpr:+ || '|' || }n$i.obj_id"
        bindexpr+="${bindexpr:+, }'${vars[$i]}', json_object('id', n$i.obj_id, 'kind', n$i.kind, 'data', json(n$i.data), 'caused_seq', n$i.caused_seq)"
        order+="${order:+, }n$i.obj_id"
        AG_PAT_VARS+="${AG_PAT_VARS:+ }${vars[$i]}"
    done
    local maxseq=''
    for (( i=0; i<${#vars[@]}; i++ )); do maxseq+="${maxseq:+, }n$i.caused_seq"; done
    AG_PAT_SEL="SELECT json_object('key', $keyexpr, 'seq', max($maxseq), 'bind', json_object($bindexpr))"
    AG_PAT_SQL=" FROM $from WHERE $where ORDER BY $order"
    return 0
}

ag_behavior_add() {  # --name N --on TYPE [--match P] [--where E] [--absent A] -- argv...
    local name='' on='' pat='' wex='' abs=''
    local -a argv=()
    while (( $# )); do case $1 in
        --name)   _optval "$@" || return 1; name=$REPLY; shift 2 ;;
        --on)     _optval "$@" || return 1; on=$REPLY; shift 2 ;;
        --match)  _optval "$@" || return 1; pat=$REPLY; shift 2 ;;
        --where)  _optval "$@" || return 1; wex=$REPLY; shift 2 ;;
        --absent) _optval "$@" || return 1; abs=$REPLY; shift 2 ;;
        --)       shift; argv=("$@"); break ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    _v_ident "$name" || { _fail "$AG_E_PARAMS" '--name must be lowercase [a-z][a-z0-9_]*'; return 1; }
    [[ -n $on ]] || { _fail "$AG_E_PARAMS" '--on <event-type> required'; return 1; }
    (( ${#argv[@]} )) || { _fail "$AG_E_PARAMS" 'a body is required: ... -- <program> [args]'; return 1; }
    [[ -n $pat ]] || { _fail "$AG_E_PARAMS" '--match <graph pattern> required'; return 1; }
        # --where is operator-supplied SQL (same trust class as `scan`): reject the
        # constructs that would let it break out of the predicate into a statement.
    if [[ -n $wex ]]; then
        [[ $wex != *";"* && $wex != *"--"* && $wex != *"/*"* ]] \
            || { _fail "$AG_E_PARAMS" '--where may not contain ";", "--" or "/*"'; return 1; }
    fi
    ag_open || return 1
    _proj_open || return 1
    _pattern_compile "$pat" 0 "$wex" "$abs" || return 1   # parse-check only
    _bindv w :bn "$name" || return 1
    _bindv w :bo "$on" || return 1
    _bindval w :bp "$pat" || return 1
    _bindval w :bw "$wex" || return 1
    _bindval w :ba "$abs" || return 1
    local aj; printf -v aj '%s' "$( _json_array "${argv[@]}" )"
    _bindval w :bv "$aj" || return 1
    _eng w "INSERT INTO behaviors(name, on_type, pattern, where_expr, absent, argv)
            VALUES(:bn, :bo, :bp, :bw, :ba, :bv)
            ON CONFLICT(name) DO UPDATE SET
              on_type=excluded.on_type, pattern=excluded.pattern,
              where_expr=excluded.where_expr, absent=excluded.absent, argv=excluded.argv;" \
        || { _fail "$AG_E_PARAMS" "behavior insert failed: ${AG_ERR%%$'\n'*}"; return 1; }
    _scalar w "SELECT json_object('behavior', name, 'on', on_type, 'match', pattern,
                      'where', nullif(where_expr,''), 'absent', nullif(absent,''),
                      'argv', json(argv), 'enabled', json(CASE WHEN enabled THEN 'true' ELSE 'false' END))
               FROM behaviors WHERE name = :bn;"
    printf '\n'
}

_json_array() {  # argv -> JSON array literal, correctly escaped
    local out='' a
    for a in "$@"; do _json_esc "$a"; out+="${out:+,}$REPLY"; done
    printf '[%s]' "$out"
}

ag_behaviors() {  # list
    ag_open || return 1
    _eng w "SELECT json_object('behavior', name, 'on', on_type, 'match', pattern,
                   'where', nullif(where_expr,''), 'absent', nullif(absent,''),
                   'argv', json(argv),
                   'enabled', json(CASE WHEN enabled THEN 'true' ELSE 'false' END))
            FROM behaviors ORDER BY name;" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    printf '%s' "$AG_OUT"
}

ag_behavior_remove() {  # --name N | --all
    local name='' all=0
    while (( $# )); do case $1 in
        --name) _optval "$@" || return 1; name=$REPLY; shift 2 ;;
        --all)  all=1; shift ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    if (( all )); then
        _eng w 'DELETE FROM behaviors;' || return 1
        printf '{"removed":"all"}\n'; return 0
    fi
    _v_ident "$name" || { _fail "$AG_E_PARAMS" '--name required'; return 1; }
    _bindv w :bn "$name" || return 1
    local n; n=${| _sc w 'SELECT count(*) FROM behaviors WHERE name = :bn;'; }
    (( n )) || { _fail "$AG_E_PARAMS" "no such behavior: $name"; return 1; }
    _eng w 'DELETE FROM behaviors WHERE name = :bn;' || return 1
    printf '{"removed":"%s"}\n' "$name"
}

# One reactor pass: project, match every enabled behaviour, fire the matches
# that have not fired before. Returns the number of fires via AG_REACT_FIRED.
AG_REACT_FIRED=0
_react_round() {  # $1 = run
    local run=$1
    AG_REACT_FIRED=0
    ag_project --run "$run" >/dev/null || return 1
    local rid; rid=${| _sc p "SELECT rid FROM runs WHERE run_id = :run;"; }
    [[ $rid =~ ^[0-9]+$ ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }

        # names only (shape-validated, newline-free); free-text fields are fetched
        # individually through _getv, since a pattern may contain a newline and
        # corrupt a delimiter-joined record.
    _eng w "SELECT name FROM behaviors WHERE enabled = 1 ORDER BY name;" \
        || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    local blist=$AG_OUT
    [[ -n ${blist//[$'\n']/} ]] || return 0

    local bname bpat bwex babs bargv
    while IFS= read -r bname; do
        [[ -n $bname ]] || continue
        _bindv w :bn "$bname" || return 1
        _getv w "(SELECT pattern    FROM behaviors WHERE name = :bn)" && bpat=$REPLY  || return 1
        _getv w "(SELECT where_expr FROM behaviors WHERE name = :bn)" && bwex=$REPLY  || return 1
        _getv w "(SELECT absent     FROM behaviors WHERE name = :bn)" && babs=$REPLY  || return 1
        _getv w "(SELECT argv       FROM behaviors WHERE name = :bn)" && bargv=$REPLY || return 1
        _pattern_compile "$bpat" "$rid" "$bwex" "$babs" || return 1
        _eng p "$AG_PAT_SEL$AG_PAT_SQL;" \
            || { _fail "$AG_E_INTERNAL" "behavior '$bname' match failed: ${AG_ERR%%$'\n'*}"; return 1; }
        local matches=$AG_OUT m
        [[ -n ${matches//[$'\n']/} ]] || continue
        while IFS= read -r m; do
            [[ -n $m ]] || continue
            _react_fire "$run" "$bname" "$bargv" "$m" || return 1
        done <<< "$matches"
    done <<< "$blist"
    return 0
}

# Fire once per (behaviour, match), with the dedupe key IN THE LOG (the
# behavior.started payload), not in side state.
#
# Replay and fork therefore see the same firing decisions.
_react_fire() {  # $1=run $2=name $3=argv-json $4=match-json
    local run=$1 bname=$2 bargv=$3 mj=$4
    _bindval w :mj "$mj" || return 1
    local key seq
    key=${ _getv w "coalesce(:mj ->> '\$.key','')" ; } && key=$REPLY
    seq=${| _sc w "SELECT coalesce(:mj ->> '\$.seq', 0);"; }
    [[ -n $key ]] || return 0
    _bindv w :bk "$bname|$key" || return 1
    _bindv w :run "$run" || return 1
    _route_run w || return 1
    local fired
    fired=${| _sc w "$AG_SQL_LINEAGE
        SELECT count(*) FROM lineage l
        JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
        LEFT JOIN v_blobs b ON b.hash = e.body_ref
        WHERE e.tid = 13
          AND json(coalesce(e.payload, b.body)) ->> '\$.fire_key' = :bk;"; }
    (( fired == 0 )) || return 0     # already fired for this match

    local startpay
    startpay=${| _sc w "SELECT json_object('behavior', '$bname',
                    'fire_key', :bk, 'match', json_extract(:mj, '\$.bind'));"; }
    local sout
    sout=${ AG_INTERNAL_EMIT=1 ag_emit --run "$run" --type behavior.started \
              --actor runtime --caused-by "$seq" --payload "$startpay"; } || return 1
    local sseq=''; [[ $sout =~ \"seq\":([0-9]+) ]] && sseq=${BASH_REMATCH[1]}

        # body: argv is executed as an ARRAY (no eval, no string-built shell).
        # Elements ride back hex-encoded so an argument may contain any byte.
    _bindval w :av "$bargv" || return 1
    _eng w "SELECT lower(hex(CAST(value AS BLOB))) FROM json_each(:av);" || return 1
    local -a argv=()
    local h
    while IFS= read -r h; do
        [[ $h =~ ^[0-9a-f]*$ && -n $h ]] || continue
        _unhex "$h"; argv+=("$REPLY")
    done <<< "$AG_OUT"

    local body_ok=true emitted=0 berr=''
    if (( ${#argv[@]} )); then
        local outf="$AG_TMP/behav.out" errf="$AG_TMP/behav.err"
        : > "$outf"; : > "$errf"
        if printf '%s' "$mj" | _run_bounded "$AG_BEHAVIOR_TIMEOUT_S" "${argv[@]}" >"$outf" 2>"$errf"; then
                        # The body speaks the emit-batch dialect: NDJSON {type, payload}.
                        # Provenance is stamped by the RUNTIME, so a behaviour cannot lie
                        # about what caused its output.
            local -a lines=()
            local ev
                        # A body is somebody else's program, and many end output without a
                        # newline.
                        #
                        # A plain `while read` threw that last event away: the reaction ran,
                        # behavior.completed said ok, and the event never existed.
            while IFS= read -r ev || [[ -n $ev ]]; do
                [[ -n ${ev//[[:space:]]/} ]] || { ev=''; continue; }
                lines+=("$ev")
                ev=''
            done < "$outf"
            if (( ${#lines[@]} )); then
                local arr; printf -v arr '%s,' "${lines[@]}"
                _bindval w :bev "[${arr%,}]" || return 1
                local ok
                ok=${| _sc w "SELECT CASE WHEN json_valid(:bev) THEN 1 ELSE 0 END;"; }
                if [[ $ok != 1 ]]; then
                    body_ok=false; berr='body emitted invalid JSON'
                else
                    _bindv w :bact "$bname" || return 1
                    _eng w "SELECT json_set(json_set(je.value, '\$.caused_by', ${sseq:-0}),
                                            '\$.actor', :bact)
                            FROM json_each(:bev) je;" \
                        || { body_ok=false; berr=${AG_ERR%%$'\n'*}; }
                    if [[ $body_ok == true ]]; then
                        local nd=$AG_OUT
                        if printf '%s' "$nd" | ag_emit_batch --run "$run" >/dev/null; then
                            emitted=${#lines[@]}
                        else
                            body_ok=false; berr=${AG_MSG:-emit failed}
                        fi
                    fi
                fi
            fi
        else
            body_ok=false; berr=${ head -c 200 "$errf" 2>/dev/null || :; }
        fi
        rm -f "$outf" "$errf"
    fi
    _bindval w :be "$berr" || return 1
    local donepay
    donepay=${| _sc w "SELECT json_object('behavior', '$bname', 'fire_key', :bk,
                   'ok', json('$body_ok'), 'emitted', $emitted,
                   'error', nullif(:be,''));"; }
    AG_INTERNAL_EMIT=1 ag_emit --run "$run" --type behavior.completed --actor runtime \
        --caused-by "${sseq:-0}" --payload "$donepay" >/dev/null || return 1
    (( AG_REACT_FIRED++ ))
    return 0
}

_run_bounded() {  # $1 = seconds, rest = argv (array, never eval)
    local secs=$1; shift
    "$@" &
    local pid=$!
    ( _nap "$secs"; kill -TERM "$pid" 2>/dev/null ) &
    local wd=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$wd" 2>/dev/null || :
    wait "$wd" 2>/dev/null || :
    return $rc
}

ag_react() {  # --run R [--once] [--max-rounds N]
    local run='' once=0 rounds=$AG_REACT_MAX_ROUNDS
    while (( $# )); do case $1 in
        --run)        _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --once)       once=1; shift ;;
        --max-rounds) _optval "$@" || return 1; rounds=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    _v_int "$rounds" && (( rounds >= 1 )) || { _fail "$AG_E_PARAMS" '--max-rounds must be >= 1'; return 1; }
    ag_open || return 1
    local st; st=${| _run_status "$run"; }
    [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    [[ $st == live ]] || { _fail "$AG_E_PARAMS" "run is '$st', not live"; return 1; }
    (( once )) && rounds=1
        # Cascade: each round's events change the graph, which can satisfy another
        # behaviour. Bounded so a mutually-triggering pair cannot spin forever.
    local -i r=0 total=0
    while (( r < rounds )); do
        _react_round "$run" || return 1
        (( total += AG_REACT_FIRED ))
        (( AG_REACT_FIRED == 0 )) && break
        (( r++ ))
    done
    local quiesced=true
    (( r >= rounds && AG_REACT_FIRED > 0 )) && quiesced=false
    printf '{"run":"%s","rounds":%d,"fired":%d,"quiesced":%s}\n' "$run" "$r" "$total" "$quiesced"
}

# =============================================================================
# THE PROJECTION — the graph, rebuilt from the log
#
# ag_nodes/ag_edges are not a second source of truth: ag_project deletes this
# run's rows and rebuilds from events every time. If it is wrong, delete it.
#
# Three explicit event types build it, nothing inferred from llm/tool traffic:
# object.created (node), object.updated (merge-patch), relation.created (edge).
#
# It gets its OWN connection ('p'): BEGIN IMMEDIATE reserves every writable
# attached db, so a long rebuild sharing the writer would block all ingest.
# =============================================================================
readonly AG_DDL_PROJ="
PRAGMA user_version = $AG_SCHEMA_VERSION;
CREATE TABLE ag_nodes (
    rid        INTEGER NOT NULL,
    obj_id     TEXT    NOT NULL,
    kind       TEXT    NOT NULL,
    data       ANY     NOT NULL DEFAULT '{}' CHECK (json_valid(data, 6)),
    created_by TEXT    NOT NULL,
    caused_seq INTEGER NOT NULL,
    PRIMARY KEY (rid, obj_id)
) STRICT, WITHOUT ROWID;
CREATE INDEX idx_nodes_kind ON ag_nodes(rid, kind);
CREATE TABLE ag_edges (
    rid        INTEGER NOT NULL,
    src_obj    TEXT    NOT NULL,
    kind       TEXT    NOT NULL,
    dst_obj    TEXT    NOT NULL,
    caused_seq INTEGER NOT NULL,
    PRIMARY KEY (rid, src_obj, kind, dst_obj)
) STRICT, WITHOUT ROWID;
CREATE INDEX idx_edges_rev ON ag_edges(rid, dst_obj, kind);
"

AG_PROJ_OPEN=0
AG_PROJ_REBUILT=0    # guard: the disposable proj db is thrown away at most once
_proj_open() {  # dedicated engine 'p': proj rw as main, catalog+segment ro.
        # A projection rebuild must NEVER share the emit writer: BEGIN IMMEDIATE
        # reserves every writable attached db (PLAN 16 caveat 4).
    (( AG_PROJ_OPEN )) && return 0
    ag_open || return 1
    local proj="$AG_DIR/ag-proj.db" fresh=0
    [[ -f $proj ]] || fresh=1
    local catq=${AG_DIR//\'/\'\'}/ag-catalog.db
    if ! _engine_spawn p "$proj" "${ _engine_init_sql rw; }"; then
                # The projection is derived, so a file that cannot even be OPENED is not
                # an error to report but a file to throw away.
                #
                # A corrupt ag-proj.db used to hard-fail every graph/explain/diff call.
        if (( fresh )) || (( AG_PROJ_REBUILT )); then
            _fail "$AG_E_INTERNAL" "proj engine spawn: ${AG_ERR%%$'\n'*}"; return 1
        fi
        _note "ag-proj.db cannot be opened (${AG_ERR%%$'\n'*}); rebuilding"
        _engine_drop p
        rm -f "$proj" "$proj-wal" "$proj-shm"
        AG_PROJ_REBUILT=1
        _proj_open
        return $?
    fi
    AG_ENG_MODE[p]=ro   # 'p' writes only its own main (proj); segments are read-only
    _eng p "ATTACH 'file:${catq}?mode=ro' AS cat;
CREATE TEMP VIEW runs AS SELECT * FROM cat.runs;
CREATE TEMP VIEW segments AS SELECT * FROM cat.segments;
CREATE TEMP VIEW event_types AS SELECT * FROM cat.event_types;
CREATE TEMP VIEW actors AS SELECT * FROM cat.actors;" \
        || { _fail "$AG_E_INTERNAL" "proj attach failed: ${AG_ERR%%$'\n'*}"; return 1; }
    if (( fresh )); then
        _eng p 'PRAGMA page_size=8192; PRAGMA journal_mode=WAL;' || return 1
        _eng p "$AG_DDL_PROJ" || { _fail "$AG_E_INTERNAL" "proj DDL: ${AG_ERR%%$'\n'*}"; return 1; }
    else
        local uv; uv=${| _sc p 'PRAGMA main.user_version;'; }
        if [[ $uv != "$AG_SCHEMA_VERSION" ]]; then
                        # proj is DERIVED: stale schema -> rebuild, not fail.
                        #
                        # This teardown was inline and left p.err behind, so the respawn
                        # tripped over the surviving fifo and EVERY rebuild failed rc 1.
            _note "proj schema v$uv stale; rebuilding ag-proj.db"
            _engine_drop p
            rm -f "$proj" "$proj-wal" "$proj-shm"
            AG_PROJ_REBUILT=1
            _proj_open
            return $?
        fi
    fi
    AG_PROJ_OPEN=1
    AG_PROJ_REBUILT=0
}

ag_project() {  # --run R : wholesale rebuild of the run's graph projection
    local run=''
    while (( $# )); do case $1 in
        --run) _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    _proj_open || return 1
    _bindv p :run "$run" || return 1
    local rid st
    rid=${| _sc p "SELECT coalesce((SELECT rid FROM runs WHERE run_id = :run), '');"; }
    [[ -n $rid ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    st=${| _sc p "SELECT status FROM runs WHERE run_id = :run;"; }
    [[ $st != purged ]] || { _fail "$AG_E_NORUN" "run is purged (events deleted): $run"; return 1; }  # F7
        # attach the run's lineage segments to 'p' and rebuild its views BEFORE the
        # write txn (ATTACH cannot run inside a transaction).
    _route_run p || return 1

    _eng p 'BEGIN IMMEDIATE;' || { _fail "$AG_E_BUSY" 'proj busy'; return 1; }
    _eng p "DELETE FROM ag_nodes WHERE rid = $rid; DELETE FROM ag_edges WHERE rid = $rid;" \
        || { _proj_rollback; _fail "$AG_E_INTERNAL" "proj clear: ${AG_ERR%%$'\n'*}"; return 1; }
        # nodes from explicit object.created events.
        #
        # F2: OR REPLACE so a duplicate explicit id resolves last-write-wins by seq
        # instead of crashing the whole projection with a PK violation.
    _eng p "$AG_SQL_LINEAGE
INSERT OR REPLACE INTO ag_nodes(rid, obj_id, kind, data, created_by, caused_seq)
SELECT $rid,
       json(coalesce(e.payload, b.body)) ->> '\$.id',
       json(coalesce(e.payload, b.body)) ->> '\$.kind',
       jsonb(coalesce(json_extract(json(coalesce(e.payload, b.body)), '\$.data'), '{}')),
       a.name, e.seq
FROM lineage l
JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
LEFT JOIN v_blobs b ON b.hash = e.body_ref
JOIN actors a ON a.aid = e.aid
WHERE e.tid = 10 ORDER BY e.seq;" \
        || { _proj_rollback; _fail "$AG_E_INTERNAL" "proj nodes: ${AG_ERR%%$'\n'*}"; return 1; }
        # object.updated: fold JSON MergePatch per object in seq order.
        #
        # This was a bash loop doing a bind + UPDATE round trip PER PATCH under
        # BEGIN IMMEDIATE.
        #
        # The CTE materialises to temp, so UPDATE never reads what it writes.
    _eng p "DROP TABLE IF EXISTS temp._patched;
CREATE TEMP TABLE _patched(obj_id TEXT PRIMARY KEY, doc TEXT);
$AG_SQL_LINEAGE, up AS (
    SELECT oid, pt, row_number() OVER (PARTITION BY oid ORDER BY seq) AS i FROM (
        SELECT e.seq AS seq,
               json(coalesce(e.payload, b.body)) ->> '\$.id' AS oid,
               json_extract(json(coalesce(e.payload, b.body)), '\$.patch') AS pt
        FROM lineage l
        JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
        LEFT JOIN v_blobs b ON b.hash = e.body_ref
        WHERE e.tid = 11)
), fold(oid, i, doc) AS (
    SELECT n.obj_id, 0, json(n.data) FROM ag_nodes n
    WHERE n.rid = $rid AND n.obj_id IN (SELECT oid FROM up)
    UNION ALL
    SELECT f.oid, f.i + 1, json_patch(f.doc, up.pt)
    FROM fold f JOIN up ON up.oid = f.oid AND up.i = f.i + 1
)
INSERT INTO _patched(obj_id, doc)
SELECT oid, doc FROM (
    SELECT oid, doc, row_number() OVER (PARTITION BY oid ORDER BY i DESC) AS rn FROM fold
) WHERE rn = 1;
UPDATE ag_nodes SET data = jsonb((SELECT doc FROM _patched p2 WHERE p2.obj_id = ag_nodes.obj_id))
WHERE rid = $rid AND obj_id IN (SELECT obj_id FROM _patched);
DROP TABLE IF EXISTS temp._patched;" \
        || { _proj_rollback; _fail "$AG_E_INTERNAL" "proj patches: ${AG_ERR%%$'\n'*}"; return 1; }
        # edges from relation.created
    _eng p "$AG_SQL_LINEAGE
INSERT OR REPLACE INTO ag_edges(rid, src_obj, kind, dst_obj, caused_seq)
SELECT $rid,
       json(coalesce(e.payload, b.body)) ->> '\$.src',
       json(coalesce(e.payload, b.body)) ->> '\$.kind',
       json(coalesce(e.payload, b.body)) ->> '\$.dst',
       e.seq
FROM lineage l
JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
LEFT JOIN v_blobs b ON b.hash = e.body_ref
WHERE e.tid = 12 ORDER BY e.seq;" \
        || { _proj_rollback; _fail "$AG_E_INTERNAL" "proj edges: ${AG_ERR%%$'\n'*}"; return 1; }
    _eng p 'COMMIT;' || { _proj_rollback; _fail "$AG_E_INTERNAL" 'proj commit failed'; return 1; }
    _scalar p "SELECT json_object('run', :run,
        'nodes', (SELECT count(*) FROM ag_nodes WHERE rid = $rid),
        'edges', (SELECT count(*) FROM ag_edges WHERE rid = $rid));"
    printf '\n'
}

ag_graph() {  # --run R [--edges] [--kind K] [--from OBJ] [--to OBJ] -> NDJSON
    local run='' what=nodes kind='' from='' to=''
    while (( $# )); do case $1 in
        --run)   _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --edges) what=edges; shift ;;
        --nodes) what=nodes; shift ;;
        --kind)  _optval "$@" || return 1; kind=$REPLY; shift 2 ;;
        --from)  _optval "$@" || return 1; from=$REPLY; shift 2 ;;
        --to)    _optval "$@" || return 1; to=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_project --run "$run" >/dev/null || return 1
    local rid; rid=${| _sc p "SELECT rid FROM runs WHERE run_id = :run;"; }
    _bindv p :kind "$kind"; _bindv p :from "$from"; _bindv p :to "$to"
    if [[ $what == nodes ]]; then
        _engf p "SELECT json_object('id', obj_id, 'kind', kind, 'data', json(data),
                                   'created_by', created_by, 'caused_seq', caused_seq)
                FROM ag_nodes WHERE rid = $rid AND (:kind = '' OR kind = :kind)
                ORDER BY caused_seq;" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    else
        _engf p "SELECT json_object('src', src_obj, 'kind', kind, 'dst', dst_obj, 'caused_seq', caused_seq)
                FROM ag_edges WHERE rid = $rid
                  AND (:kind = '' OR kind = :kind)
                  AND (:from = '' OR src_obj = :from)
                  AND (:to   = '' OR dst_obj = :to)
                ORDER BY caused_seq;" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    fi
    printf '%s' "$AG_OUT"
}

ag_explain() {  # --run R --obj ID : provenance + causal chain of one object
    local run='' obj=''
    while (( $# )); do case $1 in
        --run) _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --obj) _optval "$@" || return 1; obj=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    [[ -n $obj ]] || { _fail "$AG_E_PARAMS" '--obj required'; return 1; }
    ag_project --run "$run" >/dev/null || return 1
    local rid; rid=${| _sc p "SELECT rid FROM runs WHERE run_id = :run;"; }
    _bindv p :obj "$obj" || return 1
        # The node document NEVER round-trips through the shell.
        #
        # It used to: a json_object() was pasted back as json('<text>'), so data
        # containing a quote was second-order SQL injection.
        #
        # That was reachable over JSON-RPC and able to run writefile(), and an
        # unbalanced quote instead hung the engine forever.
    local cs
    cs=${| _sc p "SELECT coalesce((SELECT caused_seq FROM ag_nodes WHERE rid = $rid AND obj_id = :obj), '');"; }
    [[ $cs =~ ^[0-9]+$ ]] || { _fail "$AG_E_PARAMS" "unknown object: $obj"; return 1; }
    _engf p "$AG_SQL_LINEAGE, ev AS (
    SELECT e.seq, e.tid, e.aid, e.caused_by
    FROM lineage l JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
), walk(seq) AS (
    SELECT $cs
    UNION
    SELECT ev.caused_by FROM ev JOIN walk ON ev.seq = walk.seq
    WHERE ev.caused_by IS NOT NULL
)
SELECT json_object('seq', ev.seq, 'type', t.name, 'actor', a.name, 'caused_by', ev.caused_by)
FROM walk JOIN ev ON ev.seq = walk.seq
JOIN event_types t ON t.tid = ev.tid
JOIN actors a ON a.aid = ev.aid
ORDER BY ev.seq;" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    local chain_nd=$AG_OUT
    _bindval p :cnd "$chain_nd" || return 1
    _scalar p "SELECT json_object(
        'object', (SELECT json_object('id', obj_id, 'kind', kind, 'data', json(data),
                                      'created_by', created_by, 'caused_seq', caused_seq)
                   FROM ag_nodes WHERE rid = $rid AND obj_id = :obj),
        'chain', CASE WHEN :cnd = '' THEN json('[]')
                      ELSE json('[' || replace(rtrim(:cnd, char(10)), char(10), ',') || ']') END);"
    printf '\n'
}

ag_diff() {  # <runA> <runB> : structural diff of the two projections
    local A=${1:-} B=${2:-}
    _v_run_id "$A" && _v_run_id "$B" || { _fail "$AG_E_PARAMS" 'usage: diff <runA> <runB>'; return 1; }
    ag_project --run "$A" >/dev/null || return 1
    ag_project --run "$B" >/dev/null || return 1
    _bindv p :a "$A"; _bindv p :b "$B"
    local RA RB
    RA=${| _sc p "SELECT rid FROM runs WHERE run_id = :a;"; }
    RB=${| _sc p "SELECT rid FROM runs WHERE run_id = :b;"; }
        # shared-prefix cutoff if B descends from A (else -1 -> no patch report)
    _bindv p :run "$B"
    local cut
    cut=${| _sc p "$AG_SQL_LINEAGE SELECT coalesce((SELECT coalesce(upto, -2) FROM lineage WHERE rid = $RA), -1);"; }
    local patches_sql="json('[]')"
    if [[ $cut != -1 && $cut != -2 ]]; then
        patches_sql="(SELECT coalesce(json_group_array(json_object('seq', s, 'id', oid, 'patch', json(pt))), '[]') FROM (
            $AG_SQL_LINEAGE
            SELECT e.seq AS s,
                   json(coalesce(e.payload, b.body)) ->> '\$.id' AS oid,
                   json_extract(json(coalesce(e.payload, b.body)), '\$.patch') AS pt
            FROM lineage l JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
            LEFT JOIN v_blobs b ON b.hash = e.body_ref
            WHERE e.tid = 11 AND e.seq > $cut ORDER BY e.seq))"
    fi
    _scalarf p "SELECT json_object(
'a', :a, 'b', :b,
'objects', json_object(
  'added', (SELECT coalesce(json_group_array(json_object('id', obj_id, 'kind', kind, 'data', json(data))), '[]')
            FROM ag_nodes nb WHERE nb.rid = $RB
              AND NOT EXISTS (SELECT 1 FROM ag_nodes na WHERE na.rid = $RA AND na.obj_id = nb.obj_id)),
  'removed', (SELECT coalesce(json_group_array(json_object('id', obj_id, 'kind', kind)), '[]')
            FROM ag_nodes na WHERE na.rid = $RA
              AND NOT EXISTS (SELECT 1 FROM ag_nodes nb WHERE nb.rid = $RB AND nb.obj_id = na.obj_id)),
  'changed', (SELECT coalesce(json_group_array(json_object('id', na.obj_id,
                'from', json(na.data), 'to', json(nb.data))), '[]')
            FROM ag_nodes na JOIN ag_nodes nb ON nb.rid = $RB AND nb.obj_id = na.obj_id
            WHERE na.rid = $RA AND sha3(json(na.data), 256) <> sha3(json(nb.data), 256))),
'relations', json_object(
  'added', (SELECT coalesce(json_group_array(json_object('src', src_obj, 'kind', kind, 'dst', dst_obj)), '[]')
            FROM ag_edges eb WHERE eb.rid = $RB
              AND NOT EXISTS (SELECT 1 FROM ag_edges ea WHERE ea.rid = $RA
                              AND ea.src_obj = eb.src_obj AND ea.kind = eb.kind AND ea.dst_obj = eb.dst_obj)),
  'removed', (SELECT coalesce(json_group_array(json_object('src', src_obj, 'kind', kind, 'dst', dst_obj)), '[]')
            FROM ag_edges ea WHERE ea.rid = $RA
              AND NOT EXISTS (SELECT 1 FROM ag_edges eb WHERE eb.rid = $RB
                              AND eb.src_obj = ea.src_obj AND eb.kind = ea.kind AND eb.dst_obj = ea.dst_obj))),
'patches', $patches_sql);" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    printf '\n'
}

# =============================================================================
# wait, replay verification, frames (PLAN 9.4/9.5/9.7)
# =============================================================================
ag_wait() {  # --run R [--types a,b] [--since N] [--timeout MS] -> NDJSON (may be empty)
    local run='' types='' since=0 timeout=30000
    while (( $# )); do case $1 in
        --run)     _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --types)   _optval "$@" || return 1; types=$REPLY; shift 2 ;;
        --since)   _optval "$@" || return 1; since=$REPLY; shift 2 ;;
        --timeout) _optval "$@" || return 1; timeout=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    _v_int "$since"  || { _fail "$AG_E_PARAMS" 'invalid --since'; return 1; }
    if ! _v_int "$timeout" || (( timeout > 60000 )); then
        _fail "$AG_E_PARAMS" 'timeout must be 0..60000 ms'; return 1
    fi
    local st; st=${| _run_status "$run"; }
    [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    [[ $st != purged ]] || { _fail "$AG_E_NORUN" "run is purged (events deleted): $run"; return 1; }  # F7
    local tfilter='' tk
    if [[ -n $types ]]; then
        local IFS=,
        for tk in $types; do
            [[ $tk =~ ^[a-z][a-z0-9_.]{0,63}$ ]] || { _fail "$AG_E_PARAMS" "invalid type in --types: $tk"; return 1; }
            tfilter+="${tfilter:+,}'$tk'"
        done
    fi
    local e; e=${| _engine_for_read; }
    _bindv "$e" :run "$run" || return 1
    _route_run "$e" || return 1
        # new events append to the run's pinned segment; watch that file's
        # data_version.
        #
        # A live run's segment is attached mode=ro, so external commits are visible
        # — unlike immutable ancestors.
    local wseg; wseg=${| _seg_of_run "$e"; }
    local q="$AG_SQL_LINEAGE
SELECT json_object('seq', e.seq, 'type', t.name, 'actor', a.name,
                   'payload', json(coalesce(e.payload, b.body)), 'ts_ms', e.ts_ms)
FROM lineage l
JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
LEFT JOIN v_blobs b ON b.hash = e.body_ref
JOIN event_types t ON t.tid = e.tid
JOIN actors a ON a.aid = e.aid
WHERE e.seq > $since ${tfilter:+AND t.name IN ($tfilter)}
ORDER BY e.seq LIMIT 100;"
    local t0=$EPOCHREALTIME deadline_ms elapsed_ms dv dv0 nap=0.05
    deadline_ms=$timeout
    dv0=${| _sc "$e" "PRAGMA s${wseg}.data_version;"; }
    while :; do
        _engf "$e" "$q" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
        if [[ -n ${AG_OUT//$'\n'/} ]]; then printf '%s' "$AG_OUT"; return 0; fi
        local t=$EPOCHREALTIME
        elapsed_ms=$(( (${t%.*} - ${t0%.*}) * 1000 + (10#${t#*.} - 10#${t0#*.}) / 1000 ))
        (( elapsed_ms >= deadline_ms )) && return 0   # timeout: empty, rc 0
                # data_version is a cheap cross-connection change probe (one pager read)
        while :; do
            _nap "$nap"
            [[ $nap == 0.05 ]] && nap=0.25
            dv=${| _sc "$e" "PRAGMA s${wseg}.data_version;"; }
            [[ $dv != "$dv0" ]] && { dv0=$dv; nap=0.05; break; }
            t=$EPOCHREALTIME
            elapsed_ms=$(( (${t%.*} - ${t0%.*}) * 1000 + (10#${t#*.} - 10#${t0#*.}) / 1000 ))
            (( elapsed_ms >= deadline_ms )) && return 0
        done
    done
}

# Permissive replay (paper §4): per recorded *.requested event, does the lineage
# already hold the matching *.responded?
#
# That report IS the replay plan — hits are served from the log, misses go live.
_replay_permissive() {  # $1 = run
    local e; e=${| _engine_for_read; }
    _bindv "$e" :run "$1" || return 1
    _route_run "$e" || return 1
        # `resp` carries the response BODY, not just its seq.
        #
        # Carrying the seq made the outer SELECT use a correlated subquery,
        # re-running the lineage CTE once PER REQUEST EVENT: 21/46/128/433 ms at
        # 100/200/400/800 events.
    _engf "$e" "$AG_SQL_LINEAGE, resp AS (
    SELECT rh, rtid, rseq, body FROM (
        SELECT e.req_hash AS rh, e.tid AS rtid, e.seq AS rseq,
               json(coalesce(e.payload, b.body)) AS body,
               row_number() OVER (PARTITION BY e.req_hash, e.tid ORDER BY e.seq) AS rn
        FROM lineage l JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
        LEFT JOIN v_blobs b ON b.hash = e.body_ref
        WHERE e.tid IN (7,9) AND e.req_hash IS NOT NULL
    ) WHERE rn = 1
)
SELECT json_object('seq', q.seq, 'type', t.name,
    'request_hash', lower(hex(q.hash)),
    'cache', CASE WHEN r.rseq IS NOT NULL THEN 'hit' ELSE 'miss' END,
    'response_seq', r.rseq,
    -- json() again on the way out: a value loses its JSON subtype when it
    -- passes through a CTE column, and without this the response came back as
    -- a quoted STRING of JSON rather than the object it was before.
    'response', json(r.body))
FROM lineage l
JOIN v_run_events q ON q.rid = l.rid AND (l.upto IS NULL OR q.seq <= l.upto)
JOIN event_types t ON t.tid = q.tid
LEFT JOIN resp r ON r.rh = q.hash AND r.rtid = q.tid + 1
WHERE q.tid IN (6,8)
ORDER BY q.seq;" || { _fail "$AG_E_INTERNAL" "permissive replay failed: ${AG_ERR%%$'\n'*}"; return 1; }
    printf '%s' "$AG_OUT"
}

ag_replay() {  # --run R [--strict] : strict = compare a candidate stream (NDJSON
        # against the recorded log, event by event. First divergence -> -32002.
    local run='' strict=0
    while (( $# )); do case $1 in
        --run)    _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --strict) strict=1; shift ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    ag_open || return 1
    _v_run_id "$run" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    local st; st=${| _run_status "$run"; }
    [[ -n $st ]] || { _fail "$AG_E_NORUN" "unknown run: $run"; return 1; }
    [[ $st != purged ]] || { _fail "$AG_E_NORUN" "run is purged (events deleted): $run"; return 1; }
    (( strict )) || { _replay_permissive "$run"; return $?; }
    _bindv w :run "$run" || return 1
    _route_run w || return 1
        # recorded stream: seq|type|payload-hash, in order
    _engf w "$AG_SQL_LINEAGE
SELECT e.seq || '|' || t.name || '|' || lower(hex(sha3(json(coalesce(e.payload, b.body)), 256)))
FROM lineage l
JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
LEFT JOIN v_blobs b ON b.hash = e.body_ref
JOIN event_types t ON t.tid = e.tid
ORDER BY e.seq;" || { _fail "$AG_E_INTERNAL" "${AG_ERR%%$'\n'*}"; return 1; }
    local -a rec_type=() rec_ph=()
    local line f1 f2 f3
    while IFS='|' read -r f1 f2 f3; do
        [[ -n $f1 ]] && { rec_type+=("$f2"); rec_ph+=("$f3"); }
    done <<< "$AG_OUT"
    local -i i=0
        # Same unterminated-last-line trap as emit-batch, nastier here: dropping the
        # candidate's final line made a byte-identical replay report a divergence
        # that was not there.
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        _bindval w :sl "$line" || return 1
        local ok gtype gph rest
                # One round trip, not three: shape, type and payload hash return as one
                # \x1f-delimited value.
                #
                # _getv hex-encodes it, so newlines in CANDIDATE data cannot be mistaken
                # for protocol (I3).
        _getv w "CASE WHEN json_valid(:sl) AND json_type(:sl) = 'object'
                       AND json_type(:sl, '\$.payload') = 'object'
                  THEN '1' || char(31) || coalesce(:sl ->> '\$.type', '') || char(31)
                       || lower(hex(sha3(json(json_extract(:sl, '\$.payload')), 256)))
                  ELSE '0' END" || { _fail "$AG_E_INTERNAL" 'stream hash failed'; return 1; }
        ok=${REPLY%%$'\x1f'*}
        [[ $ok == 1 ]] || { _fail "$AG_E_PARAMS" "stream line $((i+1)): expected {type, payload} object"; return 1; }
        rest=${REPLY#*$'\x1f'}
        gtype=${rest%$'\x1f'*}
        gph=${rest##*$'\x1f'}
        line=''
        if (( i >= ${#rec_ph[@]} )); then
            printf '{"ok":false,"divergence":{"seq":%d,"reason":"stream longer than recorded log"}}\n' $((i+1))
            _fail "$AG_E_DIVERGE" 'replay divergence'; return 1
        fi
        if [[ $gtype != "${rec_type[$i]}" || $gph != "${rec_ph[$i]}" ]]; then
            printf '{"ok":false,"divergence":{"seq":%d,"expected_type":"%s","got_type":"%s","expected_hash":"%s","got_hash":"%s"}}\n' \
                   $((i+1)) "${rec_type[$i]}" "$gtype" "${rec_ph[$i]}" "$gph"
            _fail "$AG_E_DIVERGE" 'replay divergence'; return 1
        fi
        i+=1
    done
    if (( i < ${#rec_ph[@]} )); then
        printf '{"ok":false,"divergence":{"seq":%d,"reason":"stream shorter than recorded log (%d < %d)"}}\n' \
               $((i+1)) "$i" "${#rec_ph[@]}"
        _fail "$AG_E_DIVERGE" 'replay divergence'; return 1
    fi
    printf '{"ok":true,"events":%d}\n' "$i"
}

# _frame_state <run> <frame> -> 'open' | 'closed' | '' (never opened).
#
# Read from the LINEAGE, so a frame opened before a fork is visible to the child.
#
# Only the id SHAPE was checked, so `--frame f99` appended a valid frame.closed
# for a frame that never existed.
#
# A close with no open makes the log lie.
_frame_state() {  # $1 = run, $2 = frame id ; assumes :run is bound + routed
    _bindv w :frame_ "$2" || return 1
    _scalar w "$AG_SQL_LINEAGE
SELECT CASE WHEN sum(e.tid = 16) > 0 THEN 'closed'
            WHEN sum(e.tid = 15) > 0 THEN 'open'
            ELSE '' END
FROM lineage l
JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
LEFT JOIN v_blobs b ON b.hash = e.body_ref
WHERE e.tid IN (15, 16)
  AND json(coalesce(e.payload, b.body)) ->> '\$.frame' = :frame_;"
}

# Shared preamble: the run must exist and be live before a frame question means
# anything.
#
# The lineage CTE also needs :run bound and the segment routed.
_frame_prepare() {  # $1 = run
    ag_open || return 1
    _v_run_id "$1" || { _fail "$AG_E_PARAMS" 'invalid run id'; return 1; }
    local st; st=${| _run_status "$1"; }
    [[ -n $st ]]      || { _fail "$AG_E_NORUN" "unknown run: $1"; return 1; }
    [[ $st == live ]] || { _fail "$AG_E_PARAMS" "run is '$st', not live"; return 1; }
    _bindv w :run "$1" || return 1
    _route_run w
}

ag_frame_open() {  # --run R [--parent fN] : open an in-run parallel frame
    local run='' parent=''
    while (( $# )); do case $1 in
        --run)    _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --parent) _optval "$@" || return 1; parent=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    local payload='{}'
    if [[ -n $parent ]]; then
        [[ $parent =~ ^f[0-9]+$ ]] || { _fail "$AG_E_PARAMS" 'invalid --parent frame id'; return 1; }
        _frame_prepare "$run" || return 1
        case ${ _frame_state "$run" "$parent"; } in
            open)   : ;;
            closed) _fail "$AG_E_PARAMS" "--parent frame $parent is already closed"; return 1 ;;
            *)      _fail "$AG_E_NORUN" "no such frame in run $run: $parent"; return 1 ;;
        esac
        payload="{\"parent_frame\":\"$parent\"}"
    fi
    local out; out=${ AG_INTERNAL_EMIT=1 ag_emit --run "$run" --type frame.opened --actor runtime --payload "$payload"; } || return 1
    local seq=''; [[ $out =~ \"seq\":([0-9]+) ]] && seq=${BASH_REMATCH[1]}
        # read back the injected deterministic frame id
    local fid
    fid=${| _sc w "$AG_SQL_LINEAGE
SELECT json(coalesce(e.payload, b.body)) ->> '\$.frame'
FROM lineage l JOIN v_run_events e ON e.rid = l.rid AND (l.upto IS NULL OR e.seq <= l.upto)
LEFT JOIN v_blobs b ON b.hash = e.body_ref
WHERE e.seq = $seq;"; }
    printf '{"run":"%s","frame":"%s","seq":%s}\n' "$run" "$fid" "$seq"
}

ag_frame_close() {  # --run R --frame fN [--result JSON]
    local run='' frame='' result='{}'
    while (( $# )); do case $1 in
        --run)    _optval "$@" || return 1; run=$REPLY; shift 2 ;;
        --frame)  _optval "$@" || return 1; frame=$REPLY; shift 2 ;;
        --result) _optval "$@" || return 1; result=$REPLY; shift 2 ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    [[ $frame =~ ^f[0-9]+$ ]] || { _fail "$AG_E_PARAMS" 'invalid --frame id'; return 1; }
    _frame_prepare "$run" || return 1
    case ${ _frame_state "$run" "$frame"; } in
        open)   : ;;
        closed) _fail "$AG_E_PARAMS" "frame $frame is already closed"; return 1 ;;
        *)      _fail "$AG_E_NORUN" "no such frame in run $run: $frame"; return 1 ;;
    esac
    _bindval w :res_ "$result" || return 1
    local ok; ok=${| _sc w "SELECT json_valid(:res_) AND json_type(:res_) = 'object';"; }
    [[ $ok == 1 ]] || { _fail "$AG_E_PARAMS" 'result must be a JSON object'; return 1; }
    local payload
    payload=${| _sc w "SELECT json_object('frame', '$frame', 'result', json(:res_));"; }
    AG_INTERNAL_EMIT=1 ag_emit --run "$run" --type frame.closed --actor runtime --payload "$payload"
}

ag_maintain() {  # seal drained segments, drop fully-purged ones, optimize (PLAN 6)
    ag_open || return 1
    _reap_rollover_lock "$AG_DIR/.rollover.lock"   # clear locks from crashed rollovers
        # PLAN 7.1 puts the rollover check at run_start AND ag_maintain. Only
        # run_start had it, so one long-lived run grew its segment without bound.
    _maybe_rollover || _note "rollover deferred: ${AG_MSG:-busy}"
        # PLAN 7.4 sweep: a crash between the catalog row and the run.started event
        # leaves a 'live' run with zero events, pinning its segment forever.
    local swept
    swept=${| _sc w "SELECT count(*) FROM runs r WHERE r.status='live'
             AND r.started_ms < (unixepoch('subsec')*1000 - ${AG_RUN_GRACE_S}*1000)
             AND NOT EXISTS (SELECT 1 FROM v_run_events e WHERE e.rid = r.rid);"; }
    if [[ $swept =~ ^[1-9] ]]; then
        _eng w "UPDATE runs SET status='failed',
                  ended_ms=CAST(unixepoch('subsec')*1000 AS INTEGER)
                WHERE status='live'
                  AND started_ms < (unixepoch('subsec')*1000 - ${AG_RUN_GRACE_S}*1000)
                  AND NOT EXISTS (SELECT 1 FROM v_run_events e WHERE e.rid = runs.rid);" \
            && _note "swept $swept abandoned run(s) to 'failed'"
    fi
    _wal_alarm
    _access_log_rotate
    local list; list=${ _drainable_segments; }
    local -a sids; read -ra sids <<< "$list"
    local -a sealed=() s
    for s in "${sids[@]}"; do
        [[ -n $s ]] || continue
        if _seal_segment "$s"; then sealed+=("$s"); else _note "seal of segment $s deferred: ${AG_MSG}"; fi
    done
    local dropped; dropped=${ ag_drop_purged; }
    _eng w 'PRAGMA optimize;' 2>/dev/null || :
    local so do_; printf -v so '%s,' "${sealed[@]}"
    do_=${dropped// /,}
    printf '{"sealed":[%s],"dropped":[%s]}\n' "${so%,}" "$do_"
}

ag_doctor() {
    _self_path
    _platform_init
    local sq_ok=0 sq_path='' sq_ver=''
    if _sqlite_resolve 2>/dev/null; then
        sq_ok=1; sq_path=$AG_SQLITE
        sq_ver=$("$AG_SQLITE" -batch :memory: 'SELECT sqlite_version();' 2>/dev/null)
    fi
    local socat_p nc_p fs
    socat_p=${ command -v socat || :; }
    nc_p=${ command -v nc || :; }
    fs=${ _fs_type "$AG_DIR"; }
    local fs_ok=true
    case $fs in 9p|v9fs|drvfs) fs_ok=false ;; esac
        # dir mode is a SECURITY check, not decoration: it is the only portable
        # access control for the IPC socket and the db files (PLAN 12/A01).
    local dir_mode dir_ok=true
    if [[ -d $AG_DIR ]]; then
        dir_mode=${ _p_fmode "$AG_DIR"; }
        [[ $dir_mode == 700 ]] || dir_ok=false
    else
        dir_mode=absent
    fi
    local hash_ok=true
    [[ -n ${AG_FILE_HASH_ALGO:-} ]] || hash_ok=false
        # socat is the only serving backend, so its presence IS serving readiness.
        #
        # `ok` stays a statement about the STORE, so CLI and library use are not
        # blocked by a missing server dependency.
    local serve_ok=false serve_backend=none
    if [[ -n $socat_p ]]; then serve_ok=true; serve_backend=socat; fi
    local all_ok=false
    if (( sq_ok )) && [[ $fs_ok == true && $dir_ok == true && $hash_ok == true ]]; then all_ok=true; fi
    local j_sqp j_sqv j_bash j_socat j_nc j_dir j_fs j_mode
    _json_esc "$sq_path";     j_sqp=$REPLY
    _json_esc "$sq_ver";      j_sqv=$REPLY
    _json_esc "$BASH_VERSION"; j_bash=$REPLY
    _json_esc "$socat_p";     j_socat=$REPLY
    _json_esc "$nc_p";        j_nc=$REPLY
    _json_esc "$AG_DIR";      j_dir=$REPLY
    _json_esc "$fs";          j_fs=$REPLY
    _json_esc "$dir_mode";    j_mode=$REPLY
    local j_backend; _json_esc "$serve_backend"; j_backend=$REPLY
    printf '{"ok":%s,"sqlite":{"found":%s,"path":%s,"version":%s},"bash":%s,"socat":%s,"nc":%s,"serve_ok":%s,"serve_backend":%s,"dir":%s,"dir_mode":%s,"dir_ok":%s,"fs":%s,"fs_ok":%s,"file_hash":"%s","hash_ok":%s,"chain":%s,"readers":%s}\n' \
        "$all_ok" "$( (( sq_ok )) && echo true || echo false )" "$j_sqp" "$j_sqv" \
        "$j_bash" "$j_socat" "$j_nc" "$serve_ok" "$j_backend" "$j_dir" "$j_mode" "$dir_ok" "$j_fs" "$fs_ok" \
        "${AG_FILE_HASH_ALGO:-none}" "$hash_ok" "$AG_CHAIN" "$AG_READERS"
    [[ $all_ok == true ]]
}

ag_setup() {  # explicit, consent-gated networked mode (PLAN 15)
    local yes=0
    [[ ${1:-} == --yes ]] && yes=1
    local os; os=${ uname -s; }
    if [[ $os == FreeBSD ]]; then
        echo 'FreeBSD: run as root:  pkg install sqlite3 bash socat' >&2
        echo '  (socat is REQUIRED to serve; sqlite3 and bash are required always)' >&2
        return 0
    fi
    local mgr; mgr=${ command -v brew || :; }
    if [[ -z $mgr ]]; then
        local c
        for c in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
            [[ -x $c ]] && { mgr=$c; break; }
        done
    fi
    if [[ -z $mgr ]]; then
        echo 'Homebrew not found. Installing it runs a script fetched from GitHub (a trust decision):' >&2
        echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
        if (( ! yes )); then
            if [[ -t 0 ]]; then
                local a; read -r -p 'Install Homebrew now? [y/N] ' a
                [[ $a == y || $a == Y ]] || { echo 'Aborted. Install manually, then re-run setup.' >&2; return 1; }
            else
                echo 'Non-interactive: re-run with --yes to consent.' >&2; return 1
            fi
        fi
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
        mgr=${ command -v brew || echo /opt/homebrew/bin/brew; }
    fi
    "$mgr" install sqlite bash socat || return 1
    echo 'setup: done (socat is required for "serve"). Re-run "doctor" to verify.' >&2
}

# =============================================================================
# JSON-RPC 2.0 — the wire protocol
#
# One request per LINE. A connection may carry many; reconnecting costs a
# process and a fresh sqlite engine.
#
#   -> {"jsonrpc":"2.0","id":7,"method":"ag.emit","params":{...}}
#   <- {"jsonrpc":"2.0","id":7,"result":{"seq":42,"hash":"9f86..."}}
#
# Methods match a WHITELIST (AG_RPC_ALLOWED) that also lists each method's
# parameters; an unknown one is an error naming it, never ignored.
#
# Responses are built by json_object() inside SQLite, so escaping is correct by
# construction. NOT exposed: `scan` and `behavior-add` (both take trusted SQL).
#
# Codes: -32700 parse, -32600 invalid request, -32601 unknown method,
# -32602 bad params, -32603 internal.
#
# Then -32000 busy, -32001 unknown run, -32002 divergence, -32003 unauthorized,
# -32005 storage full, -32006 segment unavailable.
# =============================================================================
declare -A AG_RPC_ALLOWED=(
    [ag.ping]="'auth'"
    [ag.run_start]="'auth','goal','tags','parent','at_seq'"
    [ag.emit]="'auth','run','type','payload','actor','caused_by','ctx','idem'"
    [ag.events]="'auth','run','type','since_seq','limit'"
    [ag.fork]="'auth','run','seq'"
    [ag.run_end]="'auth','run','status'"
    [ag.emit_batch]="'auth','run','events'"
    [ag.replay]="'auth','run'"
    [ag.cache_lookup]="'auth','hash','by'"
    [ag.stats]="'auth'"
    [ag.insights]="'auth','run','limit'"
    [ag.behaviors]="'auth'"
    [ag.react]="'auth','run','once','max_rounds'"
    [ag.project]="'auth','run'"
    [ag.graph]="'auth','run','what','kind','from','to'"
    [ag.explain]="'auth','run','obj'"
    [ag.diff]="'auth','a','b'"
    [ag.wait]="'auth','run','types','since_seq','timeout_ms'"
    [ag.frame_open]="'auth','run','parent'"
    [ag.frame_close]="'auth','run','frame','result'"
)

# The reply envelope carries the ENTIRE result, so it takes the file path, not
# the fifo: ag.events over IPC returned 336 KB in ~3 s.
#
# socat EXECs one rpc-child per connection, so a request does pay ag_open
# (~105 ms) — a fixed cost, unlike 3 s.
_rpc_respond() {  # $1=id-json $2=result-json
    _bindval w :res "$2" || return 1
    _bindv w :rid_ "$1" || return 1
    _scalarf w "SELECT json_object('jsonrpc', '2.0', 'id', json(:rid_), 'result', json(:res));"
    printf '\n'
}
_rpc_error() {  # $1=id-json $2=code $3=message
    _bindv w :rid_ "$1" || return 1
    _bindv w :msg_ "$3" || return 1
    _scalar w "SELECT json_object('jsonrpc', '2.0', 'id', json(:rid_), 'error', json_object('code', $2, 'message', :msg_));"
    printf '\n'
}

# Client-controlled values ride the wire hex-encoded (I3). As raw text they were
# corrupted: a goal of "Error: something" stored as empty, "line1\nline2"
# truncated to "line1".
_rpc_param() {  # $1 = params key -> text value in REPLY ('' if absent). :req bound.
        # _getv already answers in REPLY, so the old `printf` existed purely to feed
        # a `${ ...; }` capture that read it back. Both are gone.
    _getv w "coalesce(:req ->> '\$.params.$1', '')" || REPLY=''
    return 0
}
_rpc_param_json() {  # $1 = params key; prints raw JSON value ('' if absent)
    _getv w "coalesce(json_extract(:req, '\$.params.$1'), '')" && printf '%s' "$REPLY"
}

_rpc_dispatch() {  # $1 = raw frame [, $2 = 1 when called from a batch]
    local line=$1 nested=${2:-0} t0=${EPOCHREALTIME/./}
    (( ${#line} <= AG_MAX_FRAME )) || { _rpc_error null -32600 'frame too large'; return 0; }
    [[ $line == *'\u0000'* ]] && { _rpc_error null -32600 'NUL escape rejected'; return 0; }
    _bindval w :req "$line" || { _rpc_error null -32603 'bind failed'; return 0; }
    local valid; valid=${| _sc w 'SELECT json_valid(:req);'; }
    [[ $valid == 1 ]] || { _rpc_error null -32700 'Parse error'; return 0; }
    local jt; jt=${| _sc w 'SELECT json_type(:req);'; }
    if [[ $jt == array ]]; then
                # JSON-RPC 2.0 batch elements must be request OBJECTS. Recursing into a
                # nested array let a single frame fan out without bound.
        (( nested )) && { _rpc_error null -32600 'nested batch rejected'; return 0; }
        _rpc_batch "$line"; return 0
    fi
    [[ $jt == object ]] || { _rpc_error null -32600 'Invalid Request'; return 0; }

    local rpcv idt id method pt
    rpcv=${| _sc w "SELECT coalesce(:req ->> '\$.jsonrpc', '');"; }
    idt=${| _sc w "SELECT coalesce(json_type(:req, '\$.id'), 'absent');"; }
    id=${| _sc w "SELECT coalesce(json_extract(:req, '\$.id'), 'null');"; }
    [[ $idt == text ]] && id=${| _sc w "SELECT json_quote(:req ->> '\$.id');"; }
    method=${| _sc w "SELECT coalesce(:req ->> '\$.method', '');"; }
    pt=${| _sc w "SELECT coalesce(json_type(:req, '\$.params'), 'absent');"; }

    local notify=0
    [[ $idt == absent ]] && notify=1
    case $idt in
        absent|null|integer|real|text) ;;
        *) _rpc_error null -32600 'invalid id type'; return 0 ;;
    esac
    if [[ $rpcv != 2.0 ]]; then
        (( notify )) || _rpc_error "$id" -32600 'jsonrpc must be "2.0"'; return 0
    fi
    if [[ $pt != absent && $pt != object ]]; then
        (( notify )) || _rpc_error "$id" -32602 'params must be an object'; return 0
    fi
    if [[ -z ${AG_RPC_ALLOWED[$method]:-} ]]; then
        (( notify )) || _rpc_error "$id" -32601 "method not found: ${method:-<empty>}"; return 0
    fi

        # auth gate (before anything touches state)
    if [[ -n $AG_TOKEN_SHA ]]; then
                # sustained failures across connections lock the endpoint for a cooldown;
                # checked BEFORE the compare so a locked-out peer costs nothing.
        if _auth_locked; then
            _access_log auth_lockout "$id" -32003 0 "${#line}" 0
            _dbg "auth lockout active (>= $AG_AUTH_MAX_FAILS failures in ${AG_AUTH_WINDOW_S}s)"
            (( notify )) || _rpc_error "$id" -32003 'unauthorized (rate limited)'
            _nap "$AG_AUTH_COOLDOWN_S"
            return 0
        fi
        local okt
        okt=${| _sc w "SELECT CASE WHEN lower(hex(sha3(coalesce(:req ->> '\$.params.auth', ''), 256))) = '$AG_TOKEN_SHA' THEN 1 ELSE 0 END;"; }
        if [[ $okt != 1 ]]; then
            AG_AUTH_FAILS+=1
            _auth_record_fail
            _access_log auth_fail "$id" -32003 0 "${#line}" 0
            (( notify )) || _rpc_error "$id" -32003 'unauthorized'
            return 0
        fi
    fi
        # unknown-parameter rejection (fail closed, names the offenders)
    if [[ $pt == object ]]; then
        local unk
        unk=${| _sc w "SELECT coalesce((SELECT json_group_array(key) FROM json_each(:req, '\$.params')
                                           WHERE key NOT IN (${AG_RPC_ALLOWED[$method]})), '[]');"; }
        if [[ $unk != '[]' ]]; then
            (( notify )) || _rpc_error "$id" -32602 "unknown params: $unk"; return 0
        fi
    fi

    local out rc=0
    AG_CODE=0 AG_MSG=''
    case $method in
        ag.ping)
            out='{"ok":true,"version":"'$AG_VERSION'"}' ;;
        ag.run_start)
            local g tg pr as args=()
            g=${| _rpc_param goal; }; tg=${ _rpc_param_json tags; }
            pr=${| _rpc_param parent; }; as=${| _rpc_param at_seq; }
            [[ -n $g ]]  && args+=(--goal "$g")
            [[ -n $tg ]] && args+=(--tags "$tg")
            [[ -n $pr ]] && args+=(--parent "$pr" --at-seq "$as")
            out=${ ag_run_start "${args[@]}"; } || rc=1 ;;
        ag.emit)
            local r t p a c x k args=()
            r=${| _rpc_param run; }; t=${| _rpc_param type; }
            p=${ _rpc_param_json payload; }
            a=${| _rpc_param actor; }; c=${| _rpc_param caused_by; }
            x=${ _rpc_param_json ctx; }; k=${| _rpc_param idem; }
            args=(--run "$r" --type "$t" --payload "$p")
            [[ -n $a ]] && args+=(--actor "$a")
            [[ -n $c ]] && args+=(--caused-by "$c")
            [[ -n $x ]] && args+=(--ctx "$x")
            [[ -n $k ]] && args+=(--idem "$k")
            out=${ ag_emit "${args[@]}"; } || rc=1 ;;
        ag.events)
            local r t s l args=()
            r=${| _rpc_param run; }; t=${| _rpc_param type; }
            s=${| _rpc_param since_seq; }; l=${| _rpc_param limit; }
            args=(--run "$r"); [[ -n $t ]] && args+=(--type "$t")
            [[ -n $s ]] && args+=(--since "$s"); [[ -n $l ]] && args+=(--limit "$l")
            local nd; nd=${ ag_events "${args[@]}"; } || rc=1
            if (( ! rc )); then
                _bindval w :nd "$nd"
                out=${ _scalarf w "SELECT json_object('events',
                    CASE WHEN :nd = '' THEN json('[]')
                         ELSE json('[' || replace(rtrim(:nd, char(10)), char(10), ',') || ']') END);"; }
            fi ;;
        ag.fork)
            out=${ ag_fork "${| _rpc_param run; }" "${| _rpc_param seq; }"; } || rc=1 ;;
        ag.run_end)
            local r s args=()
            r=${| _rpc_param run; }; s=${| _rpc_param status; }
            args=(--run "$r"); [[ -n $s ]] && args+=(--status "$s")
            out=${ ag_run_end "${args[@]}"; } || rc=1 ;;
        ag.emit_batch)
                        # events: a JSON ARRAY of event objects (the wire form of the CLI's NDJSON)
            local ebr eba
            ebr=${| _rpc_param run; }; eba=${ _rpc_param_json events; }
            if [[ -z $eba ]]; then
                (( notify )) || _rpc_error "$id" -32602 'events (array) required'; return 0
            fi
            _bindval w :eb "$eba" || { _rpc_error "$id" -32603 'bind failed'; return 0; }
            local ebnd; ebnd=${| _sc w "SELECT CASE WHEN json_valid(:eb) AND json_type(:eb)='array'
                                    THEN coalesce((SELECT group_concat(value, char(10)) FROM json_each(:eb)), '')
                                    ELSE char(1) END;"; }
            if [[ $ebnd == $'\001' ]]; then
                (( notify )) || _rpc_error "$id" -32602 'events must be a JSON array'; return 0
            fi
            out=${ printf '%s\n' "$ebnd" | ag_emit_batch --run "$ebr"; } || rc=1 ;;
        ag.replay)
                        # RPC exposes PERMISSIVE replay only: strict replay consumes a
                        # candidate event stream, which is a CLI/stdin shape.
            local rpnd; rpnd=${ ag_replay --run "${| _rpc_param run; }"; } || rc=1
            if (( ! rc )); then
                _bindval w :nd "$rpnd"
                out=${| _sc w "SELECT json_object('plan',
                    CASE WHEN :nd = '' THEN json('[]')
                         ELSE json('[' || replace(rtrim(:nd, char(10)), char(10), ',') || ']') END);"; }
            fi ;;
        ag.cache_lookup)
            local clh clb args=()
            clh=${| _rpc_param hash; }; clb=${| _rpc_param by; }
            args=("$clh"); [[ -n $clb ]] && args+=(--by "$clb")
            out=${ ag_cache_lookup "${args[@]}"; } || rc=1 ;;
        ag.stats)
            out=${ ag_stats; } || rc=1 ;;
        ag.behaviors)
            local bnd; bnd=${ ag_behaviors; } || rc=1
            if (( ! rc )); then
                _bindval w :nd "$bnd"
                out=${| _sc w "SELECT json_object('behaviors',
                    CASE WHEN :nd = '' THEN json('[]')
                         ELSE json('[' || replace(rtrim(:nd, char(10)), char(10), ',') || ']') END);"; }
            fi ;;
        ag.react)
            local rr ro rm args=()
            rr=${| _rpc_param run; }; ro=${| _rpc_param once; }; rm=${| _rpc_param max_rounds; }
            args=(--run "$rr")
            [[ $ro == true || $ro == 1 ]] && args+=(--once)
            [[ -n $rm ]] && args+=(--max-rounds "$rm")
            out=${ ag_react "${args[@]}"; } || rc=1 ;;
        ag.insights)
            local inr inl args=()
            inr=${| _rpc_param run; }; inl=${| _rpc_param limit; }
            [[ -n $inr ]] && args+=(--run "$inr")
            [[ -n $inl ]] && args+=(--limit "$inl")
            out=${ ag_insights "${args[@]}"; } || rc=1 ;;
        ag.project)
            out=${ ag_project --run "${| _rpc_param run; }"; } || rc=1 ;;
        ag.graph)
            local gr gw gk gf gt args=()
            gr=${| _rpc_param run; }; gw=${| _rpc_param what; }
            gk=${| _rpc_param kind; }; gf=${| _rpc_param from; }; gt=${| _rpc_param to; }
            args=(--run "$gr")
            [[ $gw == edges ]] && args+=(--edges)
            [[ -n $gk ]] && args+=(--kind "$gk")
            [[ -n $gf ]] && args+=(--from "$gf")
            [[ -n $gt ]] && args+=(--to "$gt")
            local gnd; gnd=${ ag_graph "${args[@]}"; } || rc=1
            if (( ! rc )); then
                _bindval w :nd "$gnd"
                out=${| _sc w "SELECT json_object('items',
                    CASE WHEN :nd = '' THEN json('[]')
                         ELSE json('[' || replace(rtrim(:nd, char(10)), char(10), ',') || ']') END);"; }
            fi ;;
        ag.explain)
            out=${ ag_explain --run "${| _rpc_param run; }" --obj "${| _rpc_param obj; }"; } || rc=1 ;;
        ag.diff)
            out=${ ag_diff "${| _rpc_param a; }" "${| _rpc_param b; }"; } || rc=1 ;;
        ag.frame_open)
            local fr fp args=(--run "${| _rpc_param run; }")
            fp=${| _rpc_param parent; }; [[ -n $fp ]] && args+=(--parent "$fp")
            out=${ ag_frame_open "${args[@]}"; } || rc=1 ;;
        ag.frame_close)
            local fc args=(--run "${| _rpc_param run; }" --frame "${| _rpc_param frame; }")
            fc=${ _rpc_param_json result; }; [[ -n $fc ]] && args+=(--result "$fc")
            out=${ ag_frame_close "${args[@]}"; } || rc=1 ;;
        ag.wait)
            local wr wt ws wtm args=()
            wr=${| _rpc_param run; }
            wt=${| _sc w "SELECT coalesce((SELECT group_concat(value, ',') FROM json_each(:req, '\$.params.types')), '');"; }
            ws=${| _rpc_param since_seq; }; wtm=${| _rpc_param timeout_ms; }
                        # A long wait pins a connection slot, so clamp it to the request
                        # deadline.
                        #
                        # Only already-VALID values are clamped: an out-of-range timeout is
                        # still rejected, not silently shrunk.
            if [[ $wtm =~ ^[0-9]+$ ]] \
               && (( wtm <= 60000 && wtm > AG_REQ_DEADLINE_S * 1000 )); then
                wtm=$(( AG_REQ_DEADLINE_S * 1000 ))
            fi
            args=(--run "$wr")
            [[ -n $wt ]]  && args+=(--types "$wt")
            [[ -n $ws ]]  && args+=(--since "$ws")
            [[ -n $wtm ]] && args+=(--timeout "$wtm")
            local wnd; wnd=${ ag_wait "${args[@]}"; } || rc=1
            if (( ! rc )); then
                _bindval w :nd "$wnd"
                out=${ _scalarf w "SELECT json_object('events',
                    CASE WHEN :nd = '' THEN json('[]')
                         ELSE json('[' || replace(rtrim(:nd, char(10)), char(10), ',') || ']') END);"; }
            fi ;;
    esac
    local dur=$(( ${EPOCHREALTIME/./} - t0 ))
    (( dur < 0 )) && dur=0
    if (( rc )); then
        _access_log "$method" "$id" "${AG_CODE:--32603}" $(( dur / 1000 )) "${#line}" 0
        (( notify )) || _rpc_error "$id" "${AG_CODE:--32603}" "${AG_MSG:-internal error}"
        return 0
    fi
        # multi-line results (NDJSON) are wrapped by handlers; single-line JSON here
    out=${out//$'\n'/}
        # PLAN 10.6: cap the response instead of emitting a multi-GB single line.
        # ag.events with limit=10000 over 1 MiB payloads had no bound at all.
    if (( ${#out} > AG_MAX_RESP )); then
        _access_log "$method" "$id" -32603 $(( dur / 1000 )) "${#line}" "${#out}"
        (( notify )) || _rpc_error "$id" -32603 \
            "response exceeds $AG_MAX_RESP bytes; paginate with limit/since_seq"
        return 0
    fi
    _access_log "$method" "$id" 0 $(( dur / 1000 )) "${#line}" "${#out}"
    (( notify )) || _rpc_respond "$id" "$out"
    return 0
}

_rpc_batch() {  # $1 = raw array frame
    local raw=$1 n i el resp out=''
    _bindval w :req "$raw" || return 0
    n=${| _sc w 'SELECT json_array_length(:req);'; }
    if (( n == 0 )); then _rpc_error null -32600 'empty batch'; return 0; fi
        # A 1 MiB frame of [0,0,0,...] is ~500k elements, each costing several engine
        # round trips: an uncapped batch is a one-frame amplification DoS.
    if (( n > AG_MAX_BATCH )); then
        _rpc_error null -32600 "batch exceeds $AG_MAX_BATCH elements"; return 0
    fi
    local -a els=()
    for (( i=0; i<n; i++ )); do
        els+=("${| _sc w "SELECT json_extract(:req, '\$[$i]');"; }")
    done
    for el in "${els[@]}"; do
        resp=${ _rpc_dispatch "$el" 1; }
        [[ -n $resp ]] && out+=${out:+,}$resp
    done
    [[ -n $out ]] && printf '[%s]\n' "$out"
    return 0
}

ag_rpc_child() {  # dispatcher on stdio (socat EXEC target; test harness entry)
    AG_CACHE_KB=32768 AG_HEAP_ON=1     # PLAN 6/10.3: children never take the writer tier
        # a connection handler must not be able to materialise more than it may send
    (( AG_MAX_RESULT > AG_MAX_RESP )) && AG_MAX_RESULT=$AG_MAX_RESP
    AG_PEER=${SOCAT_PEERADDR:+${SOCAT_PEERADDR}:${SOCAT_PEERPORT:-0}}
    : "${AG_PEER:=-}"
        # socat reaps children with SIGTERM, which skips the EXIT trap: every closed
        # connection used to leak its $TMPDIR/ag.* directory and FIFOs.
    trap 'ag_close; exit 0' TERM INT HUP
    trap 'ag_close' EXIT
    if ! ag_open; then
        _emit_error_json "${AG_CODE:--32603}" "${AG_MSG:-open failed}"
        return 1
    fi
        # derive token hash in-child (env AG_TOKEN survives the socat EXEC)
    if [[ -n ${AG_TOKEN:-} && -z $AG_TOKEN_SHA ]]; then
        _bindv w :tok_ "$AG_TOKEN"
        AG_TOKEN_SHA=${| _sc w 'SELECT lower(hex(sha3(:tok_, 256)));'; }
    fi
        # F4: bound the read at AG_MAX_FRAME so a huge newline-free line cannot make
        # bash buffer unbounded memory; an over-cap frame fails JSON validation.
        #
        # AG_REQ_DEADLINE_S was validated but unused and this loop had no timeout,
        # so an idle connection held a slot forever. `read -t` also bounds slowloris.
    local line rc
    while :; do
        IFS= read -r -t "$AG_REQ_DEADLINE_S" -n "$AG_MAX_FRAME" line; rc=$?
        if (( rc > 128 )); then
            _dbg "idle > ${AG_REQ_DEADLINE_S}s; closing connection"
            _access_log '-' null -32600 0 0 0
            return 0
        fi
        if (( rc != 0 )); then
            [[ -n $line ]] && _rpc_dispatch "$line"   # last frame without a newline
            return 0
        fi
        [[ -z $line ]] && continue
        _rpc_dispatch "$line"
        if (( AG_AUTH_FAILS >= 3 )); then _dbg 'auth failure limit; dropping connection'; return 1; fi
    done
}

# =============================================================================
# SERVE — accept connections and hand each one to a child
#
# No accept loop here: socat forks `active-graph.sh rpc-child` per connection
# with the socket on its stdin/stdout.
#
# Concurrency is one OS process per connection, arbitrated by SQLite's locking.
#
#   ipc (default)  unix socket in $AG_DIR; the 0700 dir is the access control.
#   tcp            binds 127.0.0.1 unless given BOTH a token and --allow-remote.
# =============================================================================
_port_free() { ! _p_port_busy "$1"; }   # _p_port_busy is chosen by the probe (8.6)

_pick_port() {
    if [[ -n ${AG_PORT:-} ]]; then
        _port_free "$AG_PORT" || { _fail "$AG_E_STORAGE" "port $AG_PORT in use"; return 1; }
        _note "listening on tcp:${AG_BIND}:${AG_PORT}"
        return 0
    fi
    local p
    for p in $(seq 4900 4999) $(seq 49152 49252); do
        if _port_free "$p"; then
            _note "selected free port $p"
            AG_PORT=$p
            return 0
        fi
        _note "port $p busy, trying next"
    done
    _fail "$AG_E_STORAGE" 'no free port in scan ranges'
}

_sock_alive() {  # is anything listening on unix socket $1?
    socat -u /dev/null "UNIX-CONNECT:$1" 2>/dev/null
}

# Single-instance guard (PLAN 8.4 / caveat 19). `set -C` makes the create
# atomic, so the pidfile is acquired BEFORE the socket path is touched.
_serve_pidfile() {
    local pf="$AG_DIR/ag-serve.pid" old
    if ! ( set -C; : > "$pf" ) 2>/dev/null; then
        old=${ cat "$pf" 2>/dev/null || :; }
        if [[ $old =~ ^[1-9][0-9]{0,6}$ ]] && kill -0 "$old" 2>/dev/null; then
            _fail "$AG_E_STORAGE" "another server is running (pid $old); pidfile $pf"; return 1
        fi
        _note "removing stale pidfile $pf (holder ${old:-none} is gone)"
        rm -f "$pf"
        ( set -C; : > "$pf" ) 2>/dev/null \
            || { _fail "$AG_E_STORAGE" "cannot acquire pidfile $pf"; return 1; }
    fi
    printf '%s' "$$" > "$pf"
    chmod 600 "$pf" 2>/dev/null || :
    AG_PIDFILE=$pf
    return 0
}

_ipc_bind() {
    : "${AG_SOCK:=$AG_DIR/ag.sock}"
    (( ${#AG_SOCK} <= 100 )) || { _fail "$AG_E_PARAMS" "socket path >100 bytes (sun_path limit): $AG_SOCK"; return 1; }
    if [[ -S $AG_SOCK ]]; then
        if _sock_alive "$AG_SOCK"; then
            _fail "$AG_E_STORAGE" "server already listening on $AG_SOCK"; return 1
        fi
        _note "removing stale socket $AG_SOCK"
        rm -f "$AG_SOCK"
    fi
    _note "listening on unix:$AG_SOCK"
}

ag_serve() {
    local transport=ipc allow_remote=0 token_file=''
    AG_BIND=${AG_BIND:-127.0.0.1}
    while (( $# )); do case $1 in
        --transport)  _optval "$@" || return 1; transport=$REPLY; shift 2 ;;
        --socket)     _optval "$@" || return 1; AG_SOCK=$REPLY; shift 2 ;;
        --port)       _optval "$@" || return 1; AG_PORT=$REPLY; shift 2 ;;
        --bind)       _optval "$@" || return 1; AG_BIND=$REPLY; shift 2 ;;
        --readers)    _optval "$@" || return 1; AG_READERS=$REPLY; shift 2 ;;
        --token-file) _optval "$@" || return 1; token_file=$REPLY; shift 2 ;;
        --token)      _fail "$AG_E_PARAMS" '--token on argv is refused (visible in ps); use AG_TOKEN env or --token-file'; return 1 ;;
        --allow-remote) allow_remote=1; shift ;;
        *) _fail "$AG_E_PARAMS" "unknown option: $1"; return 1 ;;
    esac; done
    case $transport in
        ipc) if [[ -n ${AG_PORT:-} ]]; then _fail "$AG_E_PARAMS" '--port is a TCP option; use --transport tcp'; return 1; fi ;;
        tcp) if [[ -n ${AG_SOCK:-} ]]; then _fail "$AG_E_PARAMS" '--socket is an IPC option'; return 1; fi ;;
        *)   _fail "$AG_E_PARAMS" 'transport must be ipc or tcp'; return 1 ;;
    esac
        # Endpoint values are interpolated into socat's COMMA-SEPARATED addresses,
        # where an unvalidated value is option injection (--port '4900,su=nobody').
    if [[ -n ${AG_PORT:-} ]]; then
        [[ $AG_PORT =~ ^[0-9]{1,5}$ ]] && (( AG_PORT >= 1 && AG_PORT <= 65535 )) \
            || { _fail "$AG_E_PARAMS" "--port must be 1..65535 (got '$AG_PORT')"; return 1; }
    fi
    [[ $AG_BIND =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9a-fA-F:]+|localhost)$ ]] \
        || { _fail "$AG_E_PARAMS" "--bind must be an IP literal or localhost (got '$AG_BIND')"; return 1; }
    if [[ -n ${AG_SOCK:-} ]]; then
        [[ $AG_SOCK != *[,$'\n\r']* ]] \
            || { _fail "$AG_E_PARAMS" '--socket must not contain a comma or newline'; return 1; }
    fi
        # socat is the ONLY backend, and that is a CORRECTNESS decision.
        #
        # nc exposes one stdio stream for the whole listener, so connections cannot
        # be told apart and an abandoned frame sits in the next peer's buffer.
        #
        # Checked BEFORE anything binds, so a refused start leaves nothing behind.
    local socat_bin; socat_bin=${ command -v socat || :; }
    if [[ -z $socat_bin ]]; then
        _fail "$AG_E_STORAGE" \
            "socat is required to serve and was not found. Install it: 'brew install socat' (macOS/Linux), 'apk add socat' (Alpine), 'apt install socat' (Debian/Ubuntu), 'pkg install socat' (FreeBSD), or run '$0 setup'."
        return 1
    fi
    AG_HEAP_ON=1              # PLAN 6: server engines carry a hard heap bound
    ag_open || return 1
    _serve_pidfile || return 1

        # token: env or 0600 file; mandatory off-loopback (PLAN 12/A07)
    local tok=${AG_TOKEN:-}
    if [[ -n $token_file ]]; then
        local perms; perms=${ _p_fmode "$token_file"; }
        [[ $perms == 600 ]] || { _fail "$AG_E_AUTH" "token file must be mode 0600 (is ${perms:-missing})"; return 1; }
        tok=$(<"$token_file")
    fi
    if [[ $transport == tcp && $AG_BIND != 127.0.0.1 && $AG_BIND != ::1 && $AG_BIND != localhost ]]; then
        if (( ! allow_remote )) || [[ -z $tok ]]; then
            _fail "$AG_E_AUTH" 'non-loopback bind requires a token AND --allow-remote'; return 1
        fi
        printf 'active-graph: WARNING: plaintext TCP on %s - prefer an SSH tunnel\n' "$AG_BIND" >&2
    fi
    if [[ -n $tok ]]; then
        (( ${#tok} >= 16 )) || { _fail "$AG_E_AUTH" 'token must be >= 16 chars'; return 1; }
        _bindv w :tok_ "$tok" || return 1
        AG_TOKEN_SHA=${| _sc w 'SELECT lower(hex(sha3(:tok_, 256)));'; }
        export AG_TOKEN=$tok   # socat children re-derive from env
    fi

    case $transport in
        ipc) _ipc_bind || return 1 ;;
        tcp) _pick_port || return 1 ;;
    esac

    if [[ -n $socat_bin ]]; then
        _note "backend: socat (concurrent, max-children=$AG_MAX_CHILDREN)"
        local addr
        case $transport in
            ipc) addr="UNIX-LISTEN:$AG_SOCK,backlog=64,max-children=$AG_MAX_CHILDREN,fork,unlink-early,mode=600" ;;
            tcp) addr="TCP-LISTEN:$AG_PORT,bind=$AG_BIND,reuseaddr,backlog=64,max-children=$AG_MAX_CHILDREN,fork" ;;
        esac
        export AG_DIR AG_CHAIN AG_SQLITE AG_READERS AG_MAX_FRAME AG_MAX_RESP \
               AG_MAX_BATCH AG_MAX_PAYLOAD AG_REQ_DEADLINE_S AG_LIMIT_MAX \
               AG_LIMIT_DEFAULT AG_ALLOW_EXPLICIT_ID AG_HEAP_LIMIT AG_BLOB_MIN
                # -t is NOT cosmetic. A request/response client half-closes after writing
                # and socat then holds the other direction for -t seconds.
                #
                # The DEFAULT IS 0.5s, so every slower reply was discarded and the client
                # saw a clean EOF with no error.
                #
                # The transport must outlive the request deadline.
        exec "$socat_bin" -t "$(( AG_REQ_DEADLINE_S + 5 ))" "$addr" EXEC:"$AG_SELF rpc-child"
    fi

        # Unreachable: the exec above replaces this process whenever socat is
        # present, and the pre-flight check refuses to start when it is not.
    _fail "$AG_E_INTERNAL" 'socat exec failed'
    return 1
}

# =============================================================================
# CLI dispatcher
# =============================================================================
# Help has two depths: the summary is the map, one line per command.
#
# `help <command>` is the manual page you want once you have the name.
_usage_text() {
    cat <<'EOF'
usage: active-graph.sh <command> [--dir DIR] [options]
  init                                   create or verify the store
  run-start [--goal G] [--tags J] [--parent RUN --at-seq K] [--close-parent]
  emit --run R --type T (--payload J|- | --payload@FILE)
       [--actor A] [--caused-by N] [--ctx J] [--idem K]
       NOTE: Linux caps one argv string at 128 KiB, so payloads larger than
       that must use --payload@FILE or --payload - (stdin), not --payload J.
  emit-batch --run R                     (NDJSON events on stdin)
  events --run R [--type T] [--since N] [--limit N]
  fork <run> <seq> [--close-parent]      parent stays live unless --close-parent
  run-end --run R [--status done|failed]
  cache-lookup <sha3-hex> [--by request|response|any]
  verify --run R [--chain]
  purge --run R
  segment-rewrite <run>                    GDPR hard-delete a run from its sealed segment
  project --run R
  graph --run R [--edges] [--kind K] [--from OBJ] [--to OBJ]
  explain --run R --obj ID
  diff <runA> <runB>
  wait --run R [--types a,b] [--since N] [--timeout MS]
  replay --run R                         permissive: per-request cache hit/miss plan
  replay --run R --strict                (candidate NDJSON stream on stdin)
  frame-open --run R [--parent fN]
  frame-close --run R --frame fN [--result J]
  seal [--seg N | --all]                 seal drained segment(s) -> immutable
  maintain                               seal drained + drop purged + optimize
  verify-files [--quarantine]            re-hash sealed segments (bitrot/tamper)
  backup <dest>                          incremental backup to a directory
  behavior-add --name N --on TYPE --match PATTERN [--where E] [--absent A] -- CMD...
                                         register a reaction. PATTERN is a Cypher
                                         subset, e.g. (c:claim)-[:addresses]->(q:question)
                                         --absent 'q-[:answered_by]->' means "unanswered".
                                         CMD is run as an array: match JSON in,
                                         NDJSON events out. CLI-only (--where is SQL).
  behaviors                              list registered behaviors
  behavior-remove --name N | --all
  react --run R [--once] [--max-rounds N]
                                         run the reactor until the graph quiesces
  insights [--run R] [--limit N]         cost/token/latency breakdown
  scan [--parallel N] [--sealed-only] <sql>
                                         CLI-ONLY raw SQL, one read-only process
                                         per segment (tables: run_events, blobs,
                                         cat.*; the segment id is bound as :seg)
  migrate [--dry-run]                    bring an older store to the current schema
  stats | doctor | setup [--yes]
  serve [--transport ipc|tcp] [--socket P] [--port N] [--bind A]
        [--readers N] [--token-file F] [--allow-remote]
        REQUIRES socat: one process per connection, concurrent.
  rpc-child                              JSON-RPC dispatcher on stdio
  help [command|topic] | --help | -h      this map, or one command in full
  version | --version                     print the version and exit
environment:
  AG_DIR AG_SQLITE AG_READERS AG_CHAIN AG_TOKEN AG_DEBUG
  AG_MAX_FRAME AG_MAX_RESP AG_MAX_BATCH AG_MAX_PAYLOAD AG_REQ_DEADLINE_S
  AG_ALLOW_EXPLICIT_ID (default 0: object ids come from the runtime generator)
  AG_RUN_GRACE_S AG_ACCESS_LOG_MAX AG_AUTH_COOLDOWN_S AG_CACHE_KB AG_HEAP_LIMIT
EOF
}

# The error path. A wrong command line is a failure, so the map goes to stderr
# with a bad-arguments exit code.
#
# A caller that pipes us must not get usage text in its data stream.
_usage() { _usage_text >&2; exit 2; }

# Everything `help <topic>` knows. Topics that are not commands come last.
_help_topic() {  # $1 = topic; returns 1 if there is nothing to say about it
    case $1 in
    init) cat <<'EOF'
usage: init

Create the store under --dir (default $PWD/.activegraph, or $AG_DIR) — or, if
one is already there, verify it. Idempotent: every other command opens the store
exactly the same way, so `init` mostly exists to see the result of that check on
its own. The store directory is created 0700 and stays that way; a loosened mode
is refused, because on the IPC transport the directory IS the access control.

Exits 65 if the schema fingerprint or user_version does not match this build.
That is deliberately fail-closed — run `migrate`.

  active-graph.sh --dir /srv/agents/store init
EOF
;;
    run-start) cat <<'EOF'
usage: run-start [--goal TEXT] [--tags JSON-ARRAY]
                 [--parent RUN --at-seq N] [--close-parent]

Start a run and emit its run.started event. Prints the new run id, which looks
like r1785148979-e9cb (epoch seconds plus random hex, never a counter).

  --goal TEXT     free text, <= 4 KiB, recorded on the run and in run.started
  --tags JSON     a JSON array, e.g. '["nightly","exp-3"]'
  --parent RUN --at-seq N
                  start this run as a fork of RUN at sequence N. Identical to
                  `fork RUN N`. Both flags are required together.
  --close-parent  with --parent, also end the parent run

Each run stores an environment fingerprint — this script's own build hash, the
harness version, os, bash and sqlite versions — so replaying somewhere else,
or after an edit to this file, is detectable rather than silently different.

  active-graph.sh run-start --goal 'summarise Q3' --tags '["batch","q3"]'
EOF
;;
    emit) cat <<'EOF'
usage: emit --run RUN --type TYPE (--payload JSON | --payload - | --payload@FILE)
            [--actor NAME] [--caused-by SEQ] [--ctx JSON] [--idem KEY]

Append one event. This is the only write in the system: the graph, the cache and
every projection are derived from these rows. Prints {"run":..,"seq":N,..}.

  --run RUN       the run to append to; must still be live
  --type TYPE     a built-in type (see `help event-types`) or a custom 'x.*'
                  one.
                  Custom types are interned on first use.
  --payload JSON  a JSON OBJECT, <= AG_MAX_PAYLOAD (1 MiB default). Payloads
                  over 512 B are content-addressed into the blob table and
                  deduplicated; reads reconstitute them transparently.
  --payload -     read the payload from stdin
  --payload@FILE  read the payload from FILE. Use this over ~128 KiB: Linux caps
                  a single argv string at 128 KiB, so a large --payload JSON
                  fails with E2BIG there while working on macOS.
  --actor NAME    who did it (default 'runtime'); lowercase, interned
  --caused-by SEQ the sequence this event answers. This is what makes a response
                  cacheable: the runtime copies the request's hash onto the
                  response as req_hash, which is the key `cache-lookup` and
                  permissive replay probe.
  --ctx JSON      execution metadata, <= 4 KiB, OUTSIDE the determinism
                  contract and never hashed: cost, tokens, latency, model.
                  `insights` reads estimated_cost_usd, usage.total_tokens and
                  dur_ms from here.
  --idem KEY      at-most-once. Re-emitting with the same key returns the
                  ORIGINAL seq instead of writing a second row, so a client
                  whose reply was lost can safely retry.

Lifecycle types (run.started, run.ended, frame.opened, frame.closed,
behavior.started, behavior.completed) are refused here — they are minted by
run-start/run-end/frame-open/frame-close/react, which keeps run status and
frame ids consistent with the log.

  active-graph.sh emit --run "$R" --type llm.requested \
    --payload '{"model":"claude","prompt":"write a haiku"}'
  active-graph.sh emit --run "$R" --type llm.responded --caused-by 2 \
    --payload '{"text":"..."}' \
    --ctx '{"estimated_cost_usd":0.004,"usage":{"total_tokens":180},"dur_ms":920}'
EOF
;;
    emit-batch) cat <<'EOF'
usage: emit-batch --run RUN            (NDJSON on stdin)

Append many events in ONE transaction. Each stdin line is a JSON object with the
same fields `emit` takes: {"type":..,"payload":{..},"actor":..,"caused_by":N,
"ctx":{..},"idem":".."}. At most AG_MAX_BATCH (1000) lines per call.

It is set-based, not a loop: one validation pass, one intern pass, two
INSERT...SELECTs. That is the difference between ~36 and ~7,900 events/sec.
Either every line lands or none does — a violation anywhere rolls the batch
back, and the sequences that do land are contiguous.

  jq -c '.[]' events.json | active-graph.sh emit-batch --run "$R"
EOF
;;
    events) cat <<'EOF'
usage: events --run RUN [--type TYPE] [--since SEQ] [--limit N]

Read the log back as NDJSON — one JSON object per line, not an array, so it
streams and pipes into jq without buffering the whole run.

  --type TYPE   only this event type
  --since SEQ   only sequences greater than SEQ (this is how you paginate)
  --limit N     cap the rows (default AG_LIMIT_DEFAULT=1000, max AG_LIMIT_MAX)

For a forked run this reads the whole lineage: the parent's prefix up to the
fork sequence, then this run's own events. The prefix is never copied.

  active-graph.sh events --run "$R" --type llm.responded --since 40 | jq .payload
EOF
;;
    fork) cat <<'EOF'
usage: fork RUN SEQ [--close-parent]

Branch a run at sequence SEQ. O(1) whatever the run's size: the child stores
(parent_rid, fork_seq) and a recursive CTE reads the shared prefix at query
time. Nothing is copied, so a hundred forks of a hundred-thousand-event run
cost a hundred rows.

The parent stays live — forking is not destructive. Pass --close-parent when
you do want the "abandon this line, continue over there" semantics.

Object ids stay deterministic across the boundary: the ordinal is counted over
the lineage, so the same log always projects the same graph.

  active-graph.sh fork "$R" 12
EOF
;;
    run-end) cat <<'EOF'
usage: run-end --run RUN [--status done|failed]

Emit run.ended and move the run out of 'live'. After this, `emit` on the run is
refused; reads, projection, diff and replay all still work. Default status is
'done'.

  active-graph.sh run-end --run "$R" --status failed
EOF
;;
    cache-lookup) cat <<'EOF'
usage: cache-lookup <sha3-hex-64> [--by request|response|any]

Probe the content-addressed cache: given the hash of a REQUEST payload, find the
recorded response, which is what lets a replay serve from the log instead of
calling out again.

  --by any       (default) try both of the below
  --by request   match responses whose req_hash is this hash — i.e. "what did
                 we answer when this exact request was made?"
  --by response  match an event whose own payload hash is this hash

The search covers every segment, newest first, and stops at the first hit — all
matches for a hash are byte-identical by construction, so segment order cannot
change the answer. A miss scans them all.

  H=$(active-graph.sh events --run "$R" --type llm.requested | jq -r .hash)
  active-graph.sh cache-lookup "$H"
EOF
;;
    verify) cat <<'EOF'
usage: verify --run RUN [--chain]

Structural check of a run: sequences contiguous from 1, no caused-by pointing
forward, payload/body_ref discriminator intact, blobs present for every offload.

  --chain   also recompute the tamper-evident hash chain end to end and name
            the FIRST sequence that disagrees. Requires the run to have been
            written with AG_CHAIN=1; a fork seeds its chain from the parent's
            state at the fork point, so verification crosses lineage.

  AG_CHAIN=1 active-graph.sh verify --run "$R" --chain
EOF
;;
    purge) cat <<'EOF'
usage: purge --run RUN

Erasure for a run in a LIVE segment: delete its events and any blob left with no
other referrer, under secure_delete plus a WAL checkpoint, so the bytes leave
both the database and its write-ahead log rather than lingering in the freelist.
Runs in batches, and is resumable if interrupted. The run row survives as a
tombstone so lineage stays honest about what used to be there.

Refused if a fork child still depends on the prefix — purge the children first.
For a run whose segment has already been SEALED (immutable, mode 400), this
records the tombstone only; use `segment-rewrite` to actually remove the bytes.

  active-graph.sh purge --run "$R"
EOF
;;
    segment-rewrite) cat <<'EOF'
usage: segment-rewrite RUN

Hard-delete a run out of a SEALED segment — the GDPR path. A sealed segment is
immutable by design, so this rebuilds the file without that run's rows and its
orphaned blobs, then swaps it in atomically. The bytes leave the disk BEFORE the
catalog is updated, so a crash mid-rewrite still satisfies erasure.

Afterwards it re-hashes the segment, refreshes its rollups, scrubs goal/tags/env
off the run row, and VACUUMs plus truncates the CATALOG's WAL — scrubbing the
row alone would leave the old text in the freelist and in the -wal, both of
which are still on-disk personal data.

Guards: sealed segments only (use `purge` otherwise), and no unpurged fork
children. CLI-only: never reachable over RPC.

  active-graph.sh segment-rewrite "$R"
EOF
;;
    project) cat <<'EOF'
usage: project --run RUN

Rebuild the run's graph projection from its log. The projection database is
derived and disposable — delete it and this recreates it exactly, which is the
whole point of the log being the source of truth. object.created/updated become
nodes, relation.created becomes edges, and updates are folded in patch order.

`graph`, `explain`, `diff` and behaviour matching all read the projection, and
project it themselves when it is stale, so you rarely need to call this.

  active-graph.sh project --run "$R"
EOF
;;
    graph) cat <<'EOF'
usage: graph --run RUN [--nodes | --edges] [--kind KIND] [--from OBJ] [--to OBJ]

Query the projected graph as NDJSON.

  --nodes        nodes only (the default is nodes)
  --edges        edges instead of nodes
  --kind KIND    filter nodes by kind, or edges by relation type
  --from OBJ     edges leaving this object id
  --to OBJ       edges arriving at this object id

Node ids are deterministic: the n-th object of kind k in a lineage is always
k#n, so the same log always yields the same ids.

  active-graph.sh graph --run "$R" --kind claim
  active-graph.sh graph --run "$R" --edges --from claim#1
EOF
;;
    explain) cat <<'EOF'
usage: explain --run RUN --obj OBJECT-ID

Why does this node look like this? Prints the object's provenance: the event
that created it, every event that patched it, and the causal chain behind each
one — request, response, the behaviour that fired, back to the root.

This is the query the projection exists to make cheap. It is also why the log is
append-only: an UPDATE would have destroyed the answer.

  active-graph.sh explain --run "$R" --obj claim#3
EOF
;;
    diff) cat <<'EOF'
usage: diff RUN-A RUN-B

Structural difference between two runs' projections: objects and relations added,
removed, or changed, plus the patches that landed past a shared fork point. It is
an anti-join on (obj_id, hash), not a text diff, so reordered-but-equivalent
histories compare equal. Two identical runs produce an empty diff.

The intended use is "I forked here and tried something else — what actually
changed?".

  B=$(active-graph.sh fork "$R" 12 | jq -r .run)
  active-graph.sh diff "$R" "$B"
EOF
;;
    wait) cat <<'EOF'
usage: wait --run RUN [--types a,b,c] [--since SEQ] [--timeout MS]

Long-poll for new events: block until something past --since appears, then print
it as NDJSON. Returns empty with exit 0 on timeout — a timeout is an answer, not
an error.

  --types a,b   only wake for these event types
  --since SEQ   watch for sequences greater than SEQ
  --timeout MS  0..60000, default 30000

It watches the segment's data_version — one page read per probe, no polling of
the event table — and backs off between probes, so an idle waiter is nearly
free. Over RPC the timeout is clamped to AG_REQ_DEADLINE_S, because a parked
wait holds one of the server's connection slots.

  active-graph.sh wait --run "$R" --types llm.responded --timeout 10000
EOF
;;
    replay) cat <<'EOF'
usage: replay --run RUN              (permissive: print the plan)
       replay --run RUN --strict     (candidate NDJSON on stdin)

Permissive replay reports, for every recorded *.requested event, whether the
lineage already holds the matching *.responded: 'hit' means a re-run can serve
that step from the log, 'miss' means it has to go out and call. That report IS
the replay plan.

Strict replay compares a candidate stream against what was recorded, sequence by
sequence, by hash. The first divergence is named with its sequence and both
hashes, and the command exits 7. Nothing is written either way.

  active-graph.sh replay --run "$R" | jq -r '[.seq,.cache] | @tsv'
  cat candidate.ndjson | active-graph.sh replay --run "$R" --strict
EOF
;;
    frame-open|frame-close) cat <<'EOF'
usage: frame-open  --run RUN [--parent fN]
       frame-close --run RUN --frame fN [--result JSON]

Frames are parallel branches INSIDE one run — several lines of work interleaved
in a single log rather than split across forks. Frame ids are deterministic
(f1, f2, ...), assigned by the runtime in the same transaction as the event, so
interleaving cannot change them and membership survives replay byte for byte.

  --parent fN   nest this frame inside another
  --result J    a JSON object recorded with frame.closed

Use a frame when the branches belong to the same run and you want one log; use
`fork` when they are alternative histories.

  F=$(active-graph.sh frame-open --run "$R" | jq -r .frame)
  active-graph.sh frame-close --run "$R" --frame "$F" --result '{"ok":true}'
EOF
;;
    seal) cat <<'EOF'
usage: seal [--seg N | --all]

Turn a drained segment (one with no live runs left) into an immutable file:
journal mode DELETE so there are no sidecars, mode 400, a sha256 of the file
recorded in the catalog, and per-dimension rollups precomputed into seg_stats so
later `stats` and `insights` never have to rescan it.

Sealed segments are attached immutable=1, which takes no locks at all — that is
what makes `scan --parallel` and cross-segment reads cheap. Interrupted seals
resume; `maintain` seals everything eligible for you.

  active-graph.sh seal --all
EOF
;;
    maintain) cat <<'EOF'
usage: maintain

The periodic housekeeping pass, safe to run from cron:
  * seal every drained segment
  * drop segment files whose runs have all been purged
  * check whether the active segment is due for rollover
  * sweep 'live' runs that never got an event and are older than AG_RUN_GRACE_S
  * reap an abandoned rollover lock whose holder is gone
  * PRAGMA optimize

  active-graph.sh maintain
EOF
;;
    verify-files) cat <<'EOF'
usage: verify-files [--quarantine]

Re-hash every sealed segment and compare against the sha256 recorded at seal
time — bitrot and tampering both show up here. The hash is streamed, so a 64 GiB
segment is checked without reading it into memory.

  --quarantine  move a failing segment aside instead of only reporting it, so
                the store keeps serving the segments that are still good

  active-graph.sh verify-files --quarantine
EOF
;;
    backup) cat <<'EOF'
usage: backup DEST-DIR

Incremental backup. Sealed segments are immutable, so only the ones DEST does
not already have are copied, and each copy is hash-verified after landing. The
catalog and the active segment are snapshotted with VACUUM INTO, which is
consistent without stopping writers.

The projection database is deliberately NOT backed up: it is derived, and
`project` rebuilds it exactly.

  active-graph.sh backup /srv/backups/agents
EOF
;;
    behavior-add) cat <<'EOF'
usage: behavior-add --name NAME --on EVENT-TYPE --match PATTERN
                    [--where SQL-PREDICATE] [--absent EDGE] -- PROGRAM [ARGS...]

Register a reaction — the paper's reactive core. A behaviour is a subscription
(an event type, a graph-shape pattern, an optional predicate) plus a body.

  --name NAME     lowercase [a-z][a-z0-9_]*, up to 32 chars; re-adding the
                  same name replaces that behaviour rather than duplicating it
  --on TYPE       the event type that makes this behaviour worth evaluating
  --match PATTERN a Cypher subset: up to 3 nodes and 2 hops, e.g.
                    (c:claim)-[:addresses]->(q:question)
                    (a:answer)<-[:answered_by]-(q:question)
                  A bare (x) matches any kind. Variables become the keys of the
                  match object handed to the body.
  --absent EDGE   a negative guard: 'q-[:answered_by]->' means "only where q has
                  no answered_by edge" — which is how you say "unanswered".
  --where SQL     a predicate over matched node columns, e.g.
                  "c.data ->> '$.confidence' < 0.5". Operator-supplied SQL, so
                  it is CLI-only and ';', '--' and '/*' are refused.

The body after -- is an argv ARRAY, never a shell string and never eval'd. It
receives the match as JSON on stdin and returns NDJSON events on stdout, which
are appended to the run bracketed by behavior.started / behavior.completed, so
everything a behaviour did is in the log with its provenance.

  active-graph.sh behavior-add --name answer_open_questions \
    --on object.created \
    --match '(q:question)' --absent 'q-[:answered_by]->' \
    -- /usr/local/bin/answer-question.sh
EOF
;;
    behaviors) cat <<'EOF'
usage: behaviors

List every registered behaviour as NDJSON: name, trigger type, pattern, guard,
predicate, body argv and enabled flag. The registry lives in the catalog, not in
a run, because a subscription is not a property of one run.

  active-graph.sh behaviors | jq -r '[.behavior,.on,.match] | @tsv'
EOF
;;
    behavior-remove) cat <<'EOF'
usage: behavior-remove --name NAME
       behavior-remove --all

Unregister a behaviour (or all of them). Events already emitted by it stay in
the log — removing the subscription does not rewrite history.

  active-graph.sh behavior-remove --name answer_open_questions
EOF
;;
    react) cat <<'EOF'
usage: react --run RUN [--once] [--max-rounds N]

Run the reactor over a live run until the graph quiesces. Each round projects
the run, evaluates every behaviour's pattern against it, and dispatches the
bodies whose matches are new. Emitted events change the graph, which can satisfy
another behaviour — so rounds repeat until nothing new fires.

  --once          a single round
  --max-rounds N  cascade bound (default AG_REACT_MAX_ROUNDS=100)

Fire-once is enforced by a key stored IN THE LOG, not in memory, so a restarted
reactor does not re-fire what already ran. A body that overruns
AG_BEHAVIOR_TIMEOUT_S is killed, and its behavior.completed carries "ok":false
with the reason — a failed reaction is recorded, never silent.

  active-graph.sh react --run "$R"
EOF
;;
    insights) cat <<'EOF'
usage: insights [--run RUN] [--limit N]

Cost, token and latency breakdown — by model, by tool, by run. The numbers come
from --ctx (estimated_cost_usd, usage.total_tokens, dur_ms), which is execution
metadata and never part of the determinism contract, so measuring does not
change a hash.

Sealed segments answer from the rollups computed at seal time rather than a
rescan, so this stays fast as the store grows. Without --run it covers the whole
store.

  active-graph.sh insights --run "$R" | jq .by_model
EOF
;;
    scan) cat <<'EOF'
usage: scan [--parallel N] [--sealed-only] <SQL>

Raw SQL across every segment — the escape hatch for questions the built-in
commands do not answer. Each segment is opened in its OWN short-lived process
with that segment as `main`, read-only, immutable where sealed, and
PRAGMA query_only=ON: damage is bounded by construction, not by blacklisting
SQL text. Results are concatenated in segment order.

Visible: run_events and blobs (the segment's own tables), plus the catalog
attached as cat — cat.runs, cat.segments, cat.event_types, cat.actors. The
segment id is bound as :seg.

  --parallel N     1..64 segments at once. Safe because a sealed file takes no
                   locks at all.
  --sealed-only    skip the active/draining segments

CLI-only: never reachable over RPC, since it is operator-supplied SQL.

  active-graph.sh scan --parallel 4 \
    "SELECT :seg, count(*) FROM run_events WHERE tid = 10;"
EOF
;;
    migrate) cat <<'EOF'
usage: migrate [--dry-run]

Bring an older store up to this build's schema. Version-gated, idempotent and
resumable — every step is safe to re-run, so a crash mid-migrate is repaired by
running it again. Sealed segments it has to rewrite are unsealed, migrated,
re-hashed and re-sealed.

  --dry-run   report what would change and touch nothing

Opening a store whose user_version or schema fingerprint does not match fails
closed with exit 65 and points here, rather than half-working.

  active-graph.sh migrate --dry-run
EOF
;;
    stats) cat <<'EOF'
usage: stats

Store-wide counters: runs by status, events, blobs and bytes saved by dedup,
segments by state, database sizes. Sealed segments contribute their seal-time
rollups; live ones are aggregated on the spot, one segment at a time so the
10-attachment budget is never exceeded.

  active-graph.sh stats | jq .
EOF
;;
    doctor) cat <<'EOF'
usage: doctor

Read-only health report, and the thing to run first when something is off:
sqlite and bash versions at the resolved paths (a build without sha3, readfile
or JSONB does not resolve at all, so `sqlite.found:false` covers that), socat
presence as `serve_ok`, the store directory's mode — 0700 is a security check,
not decoration, since it is the only portable access control for the IPC socket
and the db files — the file-hash algorithm, and the filesystem type: a store on
a 9p/drvfs mount is refused outright, because SQLite locking is not reliable
there.

Deliberately does NOT open the store, so it still answers when the store is the
thing that is broken. Exits non-zero when any of those checks fail. Never
touches the network. `serve` runs it at startup.

  active-graph.sh doctor
EOF
;;
    setup) cat <<'EOF'
usage: setup [--yes]

The single, explicit, consent-gated networked mode; every other code path stays
offline. Installs or upgrades sqlite (>= 3.53.3), bash (>= 5.3) and socat via
Homebrew on macOS and Linux. On FreeBSD it prints the pkg command instead of
running it, because that needs root and this never uses sudo on your behalf.

If Homebrew itself is missing it prints the official installer command and the
plain fact that it is curl-piped-to-bash — a trust decision, not a detail to
bury — and runs it only after you confirm.

  --yes   consent non-interactively (required when stdin is not a terminal)

  active-graph.sh setup --yes
EOF
;;
    serve) cat <<'EOF'
usage: serve [--transport ipc|tcp] [--socket PATH] [--port N] [--bind ADDR]
             [--readers N] [--token-file FILE] [--allow-remote]

Serve JSON-RPC 2.0. REQUIRES socat, which forks one process per connection, so
connections are genuinely concurrent and SQLite's own locking arbitrates between
them. There is no fallback listener: nc exposes a single stdio stream for the
whole listener, so it cannot tell two clients apart.

  --transport ipc   (default) a unix socket at $AG_DIR/ag.sock. The access
                    control is the filesystem: the directory is 0700. No network
                    surface at all.
  --transport tcp   binds 127.0.0.1 unless you pass BOTH a token and
                    --allow-remote. Omit --port and it scans for a free one;
                    give one that is busy and it fails rather than drifting.
  --socket PATH     IPC only; <= 100 bytes (the sun_path limit)
  --port N / --bind ADDR
                    TCP only; mixing them with ipc is a usage error, on purpose
  --readers N       N extra read-only engines. Reads round-robin across them;
                    writes stay on the writer.
  --token-file FILE a token, >= 16 chars, from a file that must be mode 0600.
                    --token on argv is REFUSED — argv is visible in ps.
                    AG_TOKEN in the environment works too.

Single-instance guarded by a pidfile, stale sockets are detected and unlinked,
and every request is logged to ag-access.log (0600, rotated, tokens never in it).

  AG_TOKEN=$(openssl rand -hex 16) active-graph.sh serve --readers 4
EOF
;;
    rpc-child) cat <<'EOF'
usage: rpc-child            (JSON-RPC on stdin/stdout)

One connection's worth of dispatcher, reading newline-delimited JSON-RPC 2.0
frames from stdin and writing responses to stdout. This is what `serve` execs
per connection — which also means it works unmodified under systemd socket
activation, launchd, inetd or `ncat --exec`, and it is the entry point the test
suite drives directly.

Frames are bounded at AG_MAX_FRAME, responses at AG_MAX_RESP, batches at
AG_MAX_BATCH, and an idle connection is dropped after AG_REQ_DEADLINE_S.

  echo '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}' | active-graph.sh rpc-child
EOF
;;
    events-types|event-types) cat <<'EOF'
Built-in event types

  run.started        run.ended            lifecycle; use run-start / run-end
  frame.opened       frame.closed         lifecycle; use frame-open / frame-close
  behavior.started   behavior.completed   lifecycle; stamped by react
  llm.requested      llm.responded        hashed, cacheable pair
  tool.requested     tool.responded       hashed, cacheable pair
  object.created     object.updated       projected into graph nodes
  relation.created                        projected into graph edges
  goal.created       pack.loaded          finding.recorded

The six lifecycle types are runtime-minted and refused by `emit`. The four
request/response types are the ones whose payloads get hashed and indexed for
the cache.

Anything else you need is a custom type matching x.[a-z][a-z0-9_.]*, interned on
first use:  --type x.review.approved

Payload requirements the runtime enforces:
  object.created    payload.kind, lowercase and id-safe. The id is minted by the
                    runtime as kind#n (set AG_ALLOW_EXPLICIT_ID=1 to supply one).
  object.updated    payload.id and an object payload.patch
  relation.created  payload.src, payload.kind, payload.dst
EOF
;;
    patterns) cat <<'EOF'
Graph patterns (the --match language)

A deliberately small Cypher subset — up to 3 nodes and 2 hops:

  (c)                          any node, bound to variable c
  (c:claim)                    a node of kind 'claim'
  (c:claim)-[:addresses]->(q)  an outgoing edge of type 'addresses'
  (a)<-[:answered_by]-(q)      an incoming edge

Variables become the keys of the match object handed to a behaviour body:
  {"key":"claim#1|question#2","seq":41,
   "bind":{"c":{"id":"claim#1","kind":"claim","data":{...},"caused_seq":40},
           "q":{...}}}

  --absent 'q-[:answered_by]->'    only matches where q has NO such outgoing
                                   edge. This is how "unanswered" is expressed.
  --where "c.data ->> '$.score' < 0.5"
                                   a predicate over the bound nodes' columns
                                   (id, kind, data, caused_seq). SQL, so it is
                                   CLI-only and ';', '--', '/*' are refused.

See also: `help behavior-add`, `help react`.
EOF
;;
    rpc) cat <<'EOF'
JSON-RPC 2.0 over IPC or TCP

One request per LINE (newline-delimited JSON). A connection may carry many
requests; that is cheaper than reconnecting, since each connection costs a
process and an engine.

Methods:
  ag.ping        ag.run_start   ag.emit        ag.emit_batch  ag.events
  ag.fork        ag.run_end     ag.replay      ag.cache_lookup ag.stats
  ag.project     ag.graph       ag.explain     ag.diff        ag.wait
  ag.frame_open  ag.frame_close ag.insights    ag.behaviors   ag.react

Not exposed on purpose: scan, migrate, purge, segment-rewrite, seal, backup,
setup — operator commands that take raw SQL or destroy data. They are CLI-only.

Params are a named object; a positional array is rejected with -32602, since
argument order is not a contract worth having. Unknown parameters are named in
the error rather than ignored. When a token is configured, every request carries
it as params.auth. Notifications (no id) are answered with silence, per spec.
Batches are arrays, capped at AG_MAX_BATCH.

  printf '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}\n' \
    | socat - UNIX-CONNECT:.activegraph/ag.sock

See also: `help serve`, `help exit-codes`.
EOF
;;
    exit-codes) cat <<'EOF'
Exit codes

  0   success
  1   anything else
  2   bad arguments (JSON-RPC -32602 / -32600)
  3   no such run (-32001) — also a purged run
  4   busy, retry (-32000)
  5   storage (-32005) — out of space, or a store that cannot be opened
  6   unauthorized (-32003)
  7   replay divergence (-32002)
  65  schema mismatch (-32010) — run `migrate`
  70  bash older than 5.3 and no newer one found

Errors print one JSON object on STDERR, so stdout stays parseable:
  {"error":{"code":-32001,"message":"unknown run: r1785148979-e9cb"}}
EOF
;;
    env|environment) cat <<'EOF'
Environment

Store and engines
  AG_DIR            store directory (default $PWD/.activegraph)
  AG_SQLITE         path to sqlite3 (>= 3.53.3); auto-detected
  AG_READERS        extra read-only engines (default 2)
  AG_CHAIN          1 = maintain the tamper-evident hash chain (default 0)
  AG_BLOB_MIN       payloads over this many bytes are offloaded (default 512)
  AG_CACHE_KB       writer page cache in KiB; rpc children drop to 32 MiB
  AG_HEAP_LIMIT     hard_heap_limit for server engines
  AG_ALLOW_EXPLICIT_ID  1 = accept caller-supplied object ids (default 0)

Limits
  AG_MAX_PAYLOAD    1 MiB      AG_MAX_FRAME      1 MiB
  AG_MAX_RESP       8 MiB      AG_MAX_RESULT     64 MiB
  AG_MAX_BATCH      1000       AG_MAX_CHILDREN   32
  AG_LIMIT_DEFAULT  1000       AG_LIMIT_MAX      10000
  AG_REQ_DEADLINE_S 30         AG_BEHAVIOR_TIMEOUT_S 60
  AG_ENG_HANDSHAKE_S 30        (bounds an engine's FIRST reply only, so a
                               corrupt store errors instead of hanging; real
                               queries are never on a clock)
  AG_REACT_MAX_ROUNDS 100

Server and auth
  AG_TOKEN          auth token (>= 16 chars). Never pass one on argv.
  AG_AUTH_COOLDOWN_S / AG_AUTH_WINDOW_S / AG_AUTH_MAX_FAILS
  AG_ACCESS_LOG_MAX rotate ag-access.log past this many bytes

Segments and housekeeping
  AG_SEG_MAX_BYTES  active segment rolls over past this (default 64 GiB)
  AG_ROLLOVER_LOCK_STALE_S   reap an abandoned rollover lock after this (30 s)
  AG_RUN_GRACE_S    sweep event-less live runs older than this (3600 s)
  AG_ATTACH_BUDGET  segments the read router keeps attached (default 8; SQLite
                    allows 10, and the router needs headroom under that)

  AG_DEBUG=1        verbose diagnostics on stderr
EOF
;;
    files|layout) cat <<'EOF'
Store layout ($AG_DIR, mode 0700)

  ag-catalog.db     the catalog, opened as `main`: runs, segments, interned
                    event types and actors, behaviours, config
  seg-NNNNNN.db     one segment per rollover window; holds run_events and blobs.
                    Active and draining segments are read-write WAL; sealed ones
                    are single-file, mode 400, hashed, and attached immutable=1.
  ag-proj.db        the graph projection. DERIVED and disposable — delete it and
                    `project` rebuilds it exactly. Never backed up.
  ag.sock           the IPC endpoint (mode 600)
  ag-serve.pid      single-instance guard for `serve`
  ag-access.log     one line per request (mode 600, rotated, no tokens)
  .rollover.lock/   mkdir-based mutex held across a segment rollover

Reads go through v_run_events / v_blobs, union views the router rebuilds for the
segments a given run's lineage actually needs — SQLite allows 10 attachments, so
a lineage spanning more than that is reported as an error rather than silently
truncated.
EOF
;;
    *) return 1 ;;
    esac
    return 0
}

_help() {  # $1 = optional command or topic
    local topic=${1:-}
    if [[ -z $topic ]]; then
        _usage_text
        cat <<'EOF'

Run "active-graph.sh help <command>" for one command in full, or one of these
topics: event-types, patterns, rpc, exit-codes, env, files.
Every command also answers --help.
EOF
        exit 0
    fi
    _help_topic "$topic" && exit 0
    printf 'active-graph: no help for "%s"; try "active-graph.sh help"\n' "$topic" >&2
    exit 2
}

# Everything uses JSON-RPC error numbers internally so CLI and server agree;
# the shell needs small integers:
#
#   2  bad arguments        3  no such run        4  busy (retry)
#   5  out of storage       6  unauthorized       7  replay divergence
#
#   65 schema mismatch (run `migrate`)            1  anything else
_exit_code() {  # map AG_CODE -> shell exit code
    case $1 in
        -32602|-32600) echo 2 ;;
        -32001)        echo 3 ;;
        -32000)        echo 4 ;;
        -32005)        echo 5 ;;
        -32003)        echo 6 ;;
        -32002)        echo 7 ;;
        -32010)        echo 65 ;;
        *)             echo 1 ;;
    esac
}

_main() {
    local cmd=${1:-}
    (( $# )) && shift
    if [[ ${1:-} == --dir ]]; then
        [[ $# -ge 2 && $2 != -- ]] \
            || { printf 'active-graph: missing value for --dir\n' >&2; exit 2; }
        AG_DIR=$2; shift 2
    fi
        # `<command> --help` is how anyone asks, so it is answered before the store
        # is opened.
        #
        # Help must work on a store that is missing or unreadable. The scan stops at
        # `--`, since everything after belongs to a behaviour's argv.
    local a
    for a in "$@"; do
        [[ $a == -- ]] && break
        [[ $a == --help || $a == -h ]] && _help "$cmd"
    done
    trap 'ag_close' EXIT
    local rc=0
    case $cmd in
        init)         if ag_open; then printf '{"ok":true,"dir":"%s"}\n' "$AG_DIR"; else rc=1; fi ;;
        run-start)    ag_run_start "$@" || rc=1 ;;
        emit)         ag_emit "$@" || rc=1 ;;
        emit-batch)   ag_emit_batch "$@" || rc=1 ;;
        events)       ag_events "$@" || rc=1 ;;
        fork)         ag_fork "$@" || rc=1 ;;
        run-end)      ag_run_end "$@" || rc=1 ;;
        cache-lookup) ag_cache_lookup "$@" || rc=1 ;;
        verify)       ag_verify "$@" || rc=1 ;;
        purge)        ag_purge "$@" || rc=1 ;;
        segment-rewrite) ag_segment_rewrite "$@" || rc=1 ;;
        project)      ag_project "$@" || rc=1 ;;
        graph)        ag_graph "$@" || rc=1 ;;
        explain)      ag_explain "$@" || rc=1 ;;
        diff)         ag_diff "$@" || rc=1 ;;
        wait)         ag_wait "$@" || rc=1 ;;
        replay)       ag_replay "$@" || rc=1 ;;
        frame-open)   ag_frame_open "$@" || rc=1 ;;
        frame-close)  ag_frame_close "$@" || rc=1 ;;
        seal)         ag_seal "$@" || rc=1 ;;
        maintain)     ag_maintain "$@" || rc=1 ;;
        verify-files) ag_verify_files "$@" || rc=1 ;;
        backup)       ag_backup "$@" || rc=1 ;;
        stats)        ag_stats "$@" || rc=1 ;;
        insights)     ag_insights "$@" || rc=1 ;;
        behavior-add)    ag_behavior_add "$@" || rc=1 ;;
        behaviors)       ag_behaviors "$@" || rc=1 ;;
        behavior-remove) ag_behavior_remove "$@" || rc=1 ;;
        react)           ag_react "$@" || rc=1 ;;
        scan)         ag_scan "$@" || rc=1 ;;
        migrate)      ag_migrate "$@" || rc=1 ;;
        doctor)       ag_doctor "$@" || rc=1 ;;
        setup)        ag_setup "$@" || rc=1 ;;
        serve)        ag_serve "$@" || rc=1 ;;
        rpc-child)    ag_rpc_child "$@" || rc=1 ;;
        help|-h|--help)    _help "${1:-}" ;;
        version|--version) printf '%s\n' "$AG_VERSION" ;;
        '')                _usage ;;
        *) printf 'active-graph: unknown command: %s\n' "$cmd" >&2; _usage ;;
    esac
    if (( rc )) && [[ -n ${AG_MSG:-} ]]; then
        _cli_error_json "${AG_CODE:-1}" "$AG_MSG" >&2
        exit "${ _exit_code "${AG_CODE:-1}"; }"
    fi
    exit "$rc"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    _main "$@"
fi
