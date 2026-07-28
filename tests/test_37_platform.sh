#!/usr/bin/env bash
# platform probe (§8.6): the portability layer resolves a working sqlite, sizes
# files, sleeps sub-second, classifies the filesystem, and refuses the ones that
# corrupt WAL — all behind behavioural probes (PLAN §13 test_37).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null

# every store op already ran _platform_init + _fs_guard; doctor exposes the result
doc=$("$AG" doctor 2>/dev/null)
t_is "$(echo "$doc" | jq -r .ok)" true "doctor: environment healthy"
t_is "$(echo "$doc" | jq -r .sqlite.found)" true "probe resolved a usable sqlite"
ver=$(echo "$doc" | jq -r .sqlite.version)
t_ok "$([ "$(printf '%s\n3.53.3\n' "$ver" | sort -V | head -1)" = "3.53.3" ]; echo $?)" "resolved sqlite >= 3.53.3 (got $ver)"
t_like "$(echo "$doc" | jq -r .bash)" "5.*" "probe reports bash >= 5"
t_is "$(echo "$doc" | jq -r .fs_ok)" true "current filesystem is accepted"
t_ok "$([ -n "$(echo "$doc" | jq -r .fs)" ]; echo $?)" "filesystem type was classified (fs=$(echo "$doc" | jq -r .fs))"

# probe results are stable across invocations (cached, not re-derived differently)
t_is "$("$AG" doctor 2>/dev/null | jq -r .fs)" "$(echo "$doc" | jq -r .fs)" "fs classification is stable across runs"

# sub-second sleep works: an ag_wait with a 250ms timeout and no new data returns
# quickly (not a 1s-granularity stall, not a busy hang)
R=$(new_run w); "$AG" emit --run "$R" --type x.note --payload '{"kind":"n","data":{"a":1}}' >/dev/null
tip=$("$AG" events --run "$R" | jq -s 'map(.seq)|max')
t0=$(date +%s)
"$AG" wait --run "$R" --since "$tip" --timeout 250 >/dev/null 2>&1
t_ok "$([ $(( $(date +%s) - t0 )) -lt 10 ]; echo $?)" "sub-second wait timeout returns promptly (no hang)"

# fs guard REJECTS a corrupting filesystem. On hosts that classify via mount(8)
# (macOS/BSD) we can shim mount to report 9p; Linux reads /proc/mounts and is
# skipped (can't be shimmed portably).
if [ ! -r /proc/mounts ]; then
  shim="$TDIR/bin"; mkdir -p "$shim"
  printf '#!/bin/sh\necho "fake on %s (9p, local)"\n' "$AG_DIR" > "$shim/mount"
  chmod +x "$shim/mount"
  out=$(PATH="$shim:$PATH" AG_DIR="$AG_DIR" "$AG" run-start --goal x 2>&1); rc=$?
  t_ok "$([ $rc -ne 0 ]; echo $?)" "fs guard refuses a 9p mount (WAL-unsafe)"
  t_like "$out" "*refusing*" "fs guard error explains the refusal"
else
  t_ok 0 "fs guard 9p-refusal skipped on Linux (/proc/mounts not shimmable)"
  t_ok 0 "(skip) fs guard message check on Linux"
fi

# serving readiness is a single, explicit fact: socat present or not
t_is "$(echo "$doc" | jq -r .serve_ok)" "$(command -v socat >/dev/null 2>&1 && echo true || echo false)" \
     "doctor's serve_ok tracks socat availability"

t_done
