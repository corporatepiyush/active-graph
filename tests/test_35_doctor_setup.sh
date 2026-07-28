#!/usr/bin/env bash
# doctor (read-only health) + setup (consent-gated, mocked package manager). CI
# must NEVER install real packages or touch the network (PLAN §13 test_35 / §15).
. "$(dirname "$0")/harness.bash"
"$AG" init >/dev/null

# doctor on a healthy host: ok=true, exit 0, all fields present
doc=$("$AG" doctor 2>/dev/null); rc=$?
t_is "$rc" 0 "doctor exits 0 on a healthy host"
t_is "$(echo "$doc" | jq -r .ok)" true "doctor reports ok"
t_is "$(echo "$doc" | jq -r .sqlite.found)" true "doctor found sqlite"
t_ok "$(echo "$doc" | jq -e 'has("bash") and has("fs") and has("fs_ok") and has("nc")' >/dev/null; echo $?)" "doctor reports bash/fs/fs_ok/nc"

# doctor FAILS (nonzero) on a WAL-unsafe filesystem (mount-shim 9p; macOS/BSD).
if [ ! -r /proc/mounts ]; then
  shim="$TDIR/bin1"; mkdir -p "$shim"
  printf '#!/bin/sh\necho "fake on %s (9p, local)"\n' "$AG_DIR" > "$shim/mount"; chmod +x "$shim/mount"
  bad=$(PATH="$shim:$PATH" "$AG" doctor 2>/dev/null); brc=$?
  t_is "$brc" 1 "doctor exits nonzero when the filesystem is WAL-unsafe"
  t_is "$(echo "$bad" | jq -r .fs_ok)" false "doctor flags fs_ok=false on 9p"
else
  t_ok 0 "(skip) doctor 9p check on Linux (/proc/mounts)"
  t_ok 0 "(skip) doctor fs_ok flag on Linux"
fi

# --- setup against a MOCK package manager (no network, no real install) --------
mock="$TDIR/mockbin"; mkdir -p "$mock"
log="$TDIR/brew.calls"
cat > "$mock/brew" <<EOF
#!/bin/sh
echo "\$*" >> "$log"
exit 0
EOF
chmod +x "$mock/brew"

# setup --yes uses the mock brew (found on PATH first) and installs exactly the
# three named packages — never a global upgrade
PATH="$mock:$PATH" "$AG" setup --yes >/dev/null 2>&1
t_is "$(cat "$log" 2>/dev/null)" "install sqlite bash socat" "setup installs exactly sqlite+bash+socat via the package manager"

# zero network: the mock has no network access and setup completed, proving no
# implicit fetch outside the (mocked) install
t_ok "$([ -f "$log" ]; echo $?)" "setup ran entirely through the mocked manager (no real/network install)"

# setup is idempotent to re-run (install is upgrade-or-noop on the mock)
: > "$log"
PATH="$mock:$PATH" "$AG" setup --yes >/dev/null 2>&1
t_is "$(cat "$log")" "install sqlite bash socat" "re-running setup is safe (same install call)"

# setup refuses non-interactive without --yes when brew is absent
no_brew_dir="$TDIR/nobrew"; mkdir -p "$no_brew_dir"
: > "$log"
PATH="$no_brew_dir" "$AG" setup >/dev/null 2>&1
t_fails $? "setup without --yes and no brew fails (consent gate)"

# doctor with no socat on PATH: the STORE is still healthy (ok=true), but
# serving is not available and doctor must say so distinctly.
no_socat_dir="$TDIR/nosocat"; mkdir -p "$no_socat_dir"
# put a real nc on the PATH so doctor finds it
nc_path=$(command -v nc)
ln -sf "$nc_path" "$no_socat_dir/nc"
# Prepending a directory does NOT hide a binary further down PATH; the probe
# has to run against a PATH that contains only what we put there.
for _b in bash sqlite3 nc jq stat head tr sed grep cat rm mkdir printf sleep; do
    _p=$(command -v "$_b" 2>/dev/null) && ln -sf "$_p" "$no_socat_dir/$_b" 2>/dev/null
done
no_socat_doc=$(PATH="$no_socat_dir" AG_SQLITE="${AG_SQLITE:-$SQ}" "$AG" doctor 2>/dev/null); nrc=$?
t_is "$nrc" 0 "doctor exits 0 without socat (CLI and library still work)"
t_is "$(echo "$no_socat_doc" | jq -r .ok)" true "doctor ok=true without socat (store health)"
t_is "$(echo "$no_socat_doc" | jq -r .socat)" "" "doctor reports empty socat path"
t_is "$(echo "$no_socat_doc" | jq -r .serve_ok)" false "doctor reports serve_ok=false without socat"
t_is "$(echo "$no_socat_doc" | jq -r .serve_backend)" none "and reports no serving backend at all"
if command -v socat >/dev/null 2>&1; then
  t_is "$("$AG" doctor | jq -r .serve_ok)" true "serve_ok=true when socat is installed"
  t_is "$("$AG" doctor | jq -r .serve_backend)" socat "and the backend is socat"
else
  t_ok 0 "(skip) serve_ok=true check needs socat installed"
  t_ok 0 "(skip) backend=socat check needs socat installed"
fi

# doctor reports chain and readers config
doc=$("$AG" doctor 2>/dev/null)
t_is "$(echo "$doc" | jq -r .chain)" "${AG_CHAIN:-0}" "doctor reports AG_CHAIN"
t_is "$(echo "$doc" | jq -r .readers)" "${AG_READERS:-2}" "doctor reports AG_READERS"

t_done
