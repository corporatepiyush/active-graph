#!/usr/bin/env bash
# environment + capability probe (PLAN test_00)
. "$(dirname "$0")/harness.bash"

d=$("$AG" doctor)
t_is "$(printf '%s' "$d" | jq -r .ok)" true "doctor reports ok"
t_is "$(printf '%s' "$d" | jq -r .sqlite.found)" true "sqlite3 resolved"

ver=$(printf '%s' "$d" | jq -r .sqlite.version)
IFS=. read -r a b c <<EOF
$ver
EOF
vn=$(( ${a:-0}*1000000 + ${b:-0}*1000 + ${c:-0} ))
t_ok "$([ "$vn" -ge 3053003 ]; echo $?)" "sqlite version $ver >= 3.53.3"

sqpath=$(printf '%s' "$d" | jq -r .sqlite.path)
caps=$("$sqpath" -batch :memory: "SELECT typeof(sha3('x',256)) || '|' || json_valid(jsonb('{}'),6) || '|' || length(coalesce(readfile('/dev/null'),x''));")
t_is "$caps" "blob|1|0" "sha3 + jsonb + readfile capabilities present"

# MAX_ATTACHED probe (design assumes a hard cap; assert it is discoverable)
att=$("$sqpath" -batch :memory: "SELECT compile_options FROM pragma_compile_options WHERE compile_options LIKE 'MAX_ATTACHED=%';")
t_like "$att" "MAX_ATTACHED=*" "MAX_ATTACHED discoverable ($att)"

t_is "$(printf '%s' "$d" | jq -r .fs_ok)" true "filesystem guard passes here"

# bash >= 5.3 at the resolved path (funsubs require 5.3+)
bash_ver=$(printf '%s' "$d" | jq -r .bash)
t_like "$bash_ver" "5.*" "probe reports bash >= 5 (got $bash_ver)"
IFS=. read -r ba bb _ <<EOF
$bash_ver
EOF
bn=$(( ${ba:-0}*100 + ${bb:-0} ))
t_ok "$([ "$bn" -ge 503 ]; echo $?)" "bash version $bash_ver >= 5.3"

# probe results are stable across invocations (cached, not re-derived differently)
d2=$("$AG" doctor)
t_is "$(printf '%s' "$d" | jq -c '{s:.sqlite.version,b:.bash,f:.fs}')" \
     "$(printf '%s' "$d2" | jq -c '{s:.sqlite.version,b:.bash,f:.fs}')" \
     "doctor results stable across two runs (cached)"

# ---------------------------------------------------------------------------
# STRUCTURAL SELF-CHECK. `bash -n` only proves the file parses; it does not
# notice that a function was deleted, and a deleted function fails at RUNTIME on
# whichever path happens to call it. An edit that sliced out the access-log and
# WAL-alarm block once passed both `bash -n` and several spot-checked tests
# before test_43 caught it, so the invariant is asserted directly.
# ---------------------------------------------------------------------------
undef=$(awk '
    # collect definitions and call sites, then report calls with no definition
    /^[_a-zA-Z][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { n=$0; sub(/\(\).*/,"",n); def[n]=1 }
    { line=$0
      while (match(line, /(^|[^A-Za-z0-9_.$"-])_[a-z][A-Za-z0-9_]*/)) {
          tok=substr(line, RSTART, RLENGTH)
          sub(/^[^_]*/, "", tok)
          use[tok]=1
          line=substr(line, RSTART+RLENGTH)
      }
    }
    END { for (u in use) if (!(u in def)) print u }
' "$AG" | grep -vE '^_(p_|nap$|file_hash$|ag_b$|agp$|e$|o$|bindf$|bkind$|patched$|sacc$)' | sort)
t_is "$undef" "" "every internal function referenced by the script is defined"

# and the ones the security model depends on are present by name
missing=''
for fn in _dir_guard _fs_guard _access_log _access_log_rotate _wal_alarm \
          _auth_locked _auth_record_fail _json_esc _bindval _getv _unhex \
          _serve_pidfile _pattern_compile _react_fire _scan_one; do
    grep -q "^$fn() {" "$AG" || missing="$missing $fn"
done
t_is "$missing" "" "security- and behaviour-critical helpers are all defined"
t_done
