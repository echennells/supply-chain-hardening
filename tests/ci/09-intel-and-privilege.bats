#!/usr/bin/env bats
# The `intel` input, and the privilege model underneath the wrapper layer.
#
# Both halves exist because of measured defects:
#
#   intel      `install_sfw` was vendor-named and boolean. `intel` is
#              capability-named, and the deprecated spelling has to keep
#              working without inventing a silent precedence rule.
#
#   privilege  harden.sh called `sudo` 24 times with no check that it exists.
#              In a `container:` job the runner is usually ALREADY ROOT and
#              slim images ship no sudo package, so the first wrapper
#              deployment died at exit 127 and took every downstream
#              ecosystem with it. The privilege was never missing; the
#              program we asked for it with was.

load helpers

setup() {
  common_setup
  NOSUDO="${BATS_TEST_TMPDIR}/nosudo"
  mkdir -p "$NOSUDO"
  cat > "$NOSUDO/sudo" <<'EOF'
#!/bin/sh
echo "sudo: command not found" >&2
exit 127
EOF
  chmod +x "$NOSUDO/sudo"
}

# harden with a sudo that always fails, the way a slim container image behaves.
harden_nosudo() {
  local -a envs=() args=()
  local sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then sep=1; continue; fi
    if [[ $sep -eq 1 ]]; then args+=("$a"); else envs+=("$a"); fi
  done
  shield_host_tools "${envs[@]}"
  env -i PATH="${NOSUDO}:${TEST_BIN}:${PASSWD_BIN}:${PATH}" HOME="$TEST_HOME" \
    GRADLE_USER_HOME="${TEST_HOME}/.gradle" TMPDIR="$TEST_TMP" WRITE_ETC=false \
    "${envs[@]}" bash "$HARDEN_SH" "${args[@]}"
}

# ---------------------------------------------------------------- intel ----

@test "intel defaults to none — no sfw install is attempted" {
  # Assert on behaviour, not on the word: the summary table carries a
  # "Socket Firewall | false" row either way, so matching the vendor name
  # would pass whatever the code did.
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" != *"sfw installed"* ]]
  [[ "$output" != *"install -g sfw"* ]]
  [[ "$output" == *"| \`false\` |"* ]]      # the sfw-installed row reports false
}

@test "an unrecognised intel value is refused, not ignored" {
  # Silently ignoring it would mean a workflow that reads as protected is not.
  run harden ECOSYSTEMS=npm INTEL=aikido -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"not recognised"* ]]
}

@test "intel=none is accepted explicitly" {
  run harden ECOSYSTEMS=npm INTEL=none -- --emit=plain
  [ "$status" -eq 0 ]
}

@test "the deprecated install_sfw spelling still works and says so" {
  run harden ECOSYSTEMS=npm INSTALL_SFW=false -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"deprecated"* ]]
}

@test "install_sfw with a non-boolean is refused" {
  run harden ECOSYSTEMS=npm INSTALL_SFW=yes -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be true or false"* ]]
}

@test "setting both intel and install_sfw is an error, not a precedence rule" {
  # There is no defensible winner, and picking one silently means a workflow
  # that reads as "intel off" can be running intel, or the reverse.
  run harden ECOSYSTEMS=npm INTEL=sfw INSTALL_SFW=true -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"not both"* ]]
}

@test "explicit intel=none + install_sfw is a conflict, not a silent intel-ON" {
  # Regression: intel: none + install_sfw: true slipped past the conflict guard
  # (its `!= none` clause) and silently turned intel ON against an explicit
  # `intel: none` — a workflow that reads as "intel off" was running intel.
  run harden ECOSYSTEMS=npm INTEL=none INSTALL_SFW=true -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"not both"* ]]
}

# --- intel off converges what an earlier intel run left ---------------------
#
# MEASURED (round-2 VM test, a persistent Debian 12 host; reproduced at
# 6c77f4e in debian:trixie-slim with the real sfw 2.0.6): a run with INTEL=sfw
# at 8281a6b wrapped npm and npx with wrappers that run sfw without
# SFW_SKIP_UPDATE_CHECK. A later run with intel unset left both in place, and
# once sfw's hourly update check came due every npm and npx call failed with
# "[sfw] Failed to prepare firewall binary: EACCES ... next-check", rc=1.

# stage_old_intel_wrapper <tool>: the shape 8281a6b wrote, cut to what matters
# here: the header, REAL_<TOOL>, the recursion guard, and `exec sfw` with no
# SFW_SKIP_UPDATE_CHECK.
stage_old_intel_wrapper() {
  local t="$1" var
  var="REAL_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  mv "$TEST_BIN/$t" "$TEST_BIN/$t-real"
  cat > "$TEST_BIN/$t" <<EOF
#!/bin/bash
# Managed by supply-chain-harden action
$var='$TEST_BIN/$t-real'
if [ -z "\$$var" ] || [ ! -x "\$$var" ] || [ "\$$var" = "$TEST_BIN/$t" ]; then
  echo "[supply-chain-harden] error: real $t not found at '\$$var'; refusing to recurse" >&2
  exit 127
fi
case "\${1:-}" in
  install|i|ci|exec|view|"") if command -v sfw >/dev/null 2>&1; then exec sfw "\$$var" "\$@"; fi ;;
esac
exec "\$$var" "\$@"
EOF
  chmod 755 "$TEST_BIN/$t"
}

# An sfw that fails the way the real one does for a non-root caller an hour
# after hardening, unless it is told to skip its update check.
stub_expired_sfw() {
  stub_bin sfw 'if [ -z "${SFW_SKIP_UPDATE_CHECK:-}" ]; then
  echo "[sfw] Failed to prepare firewall binary: EACCES: permission denied, open '"'"'/usr/local/lib/node_modules/sfw/.sfw-cache/next-check'"'"'" >&2
  exit 1
fi
exec "$@"'
}

@test "intel off: a run without intel takes back an earlier intel run's npm and npx wrappers, and npm runs" {
  stub_bin npm 'case "${1:-}" in --version) echo "10.9.8" ;; *) echo "STUB:npm ARGS=[$*]" ;; esac'
  stub_bin npx 'echo "STUB:npx ARGS=[$*]"'
  stub_expired_sfw
  stage_old_intel_wrapper npm
  stage_old_intel_wrapper npx
  # FIXTURE CONTROL: the staged wrappers fail as measured, so a pass below is
  # the run's doing.
  run env PATH="$TEST_BIN:$PATH" npm install foo
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to prepare firewall binary: EACCES"* ]]

  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"npm: intel is off, so the npm wrapper an earlier intel: sfw run left at $TEST_BIN/npm was removed and the real npm moved back"* ]]
  [[ "$output" == *"npx: intel is off"*"moved back"* ]]
  # The real binaries are back where they were, and nothing routes through sfw.
  [ ! -e "$TEST_BIN/npm-real" ]
  [ ! -e "$TEST_BIN/npx-real" ]
  assert_file_lacks "$TEST_BIN/npm" "supply-chain-harden"
  assert_file_lacks "$TEST_BIN/npx" "supply-chain-harden"
  run env PATH="$TEST_BIN:$PATH" npm install foo
  [ "$status" -eq 0 ]
  [ "$output" = "STUB:npm ARGS=[install foo]" ]
  run env PATH="$TEST_BIN:$PATH" npx cowsay
  [ "$status" -eq 0 ]
  [ "$output" = "STUB:npx ARGS=[cowsay]" ]
  # And the record says what is on disk.
  assert_file_contains "$OUT_FILE" "^sfw_installed=false"
  assert_file_lacks "$OUT_FILE" "^wrappers_deployed=.*npm"
}

@test "intel off: the wrappers this version's intel run deploys are taken back too" {
  stub_bin npm 'case "$*" in
  "install -g --ignore-scripts sfw@2.0.6") exit 0 ;;
  "--version") echo "10.9.8" ;;
  *) echo "STUB:npm ARGS=[$*]" ;;
esac'
  stub_bin npx 'echo "STUB:npx ARGS=[$*]"'
  stub_bin node 'echo 22'
  stub_bin sfw 'exec "$@"'
  harden ECOSYSTEMS=npm INTEL=sfw -- --emit=plain >/dev/null
  assert_file_contains "$TEST_BIN/npm" "Managed by supply-chain-harden action"
  assert_file_contains "$TEST_BIN/npx" "Managed by supply-chain-harden action"
  run harden ECOSYSTEMS=npm INTEL=none -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_lacks "$TEST_BIN/npm" "supply-chain-harden"
  assert_file_lacks "$TEST_BIN/npx" "supply-chain-harden"
  [ ! -e "$TEST_BIN/npm-real" ]
  [ ! -e "$TEST_BIN/npx-real" ]
  run env PATH="$TEST_BIN:$PATH" npm install foo
  [ "$output" = "STUB:npm ARGS=[install foo]" ]
}

@test "intel off: a wrapper it cannot safely take back is left in place, with a warning that says what to do" {
  # The role's npm wrapper is not this script's to remove: its header differs,
  # though "supply-chain-harden" is a substring of it.
  cat > "$TEST_BIN/npm" <<'EOF'
#!/bin/sh
# /usr/local/bin/npm — supply-chain-hardening wrapper
# Managed by ansible-supply-chain-security.
case "${1:-}" in --version) echo "10.9.8" ;; *) echo "ROLE-WRAPPER ARGS=[$*]" ;; esac
EOF
  chmod +x "$TEST_BIN/npm"
  printf '#!/bin/sh\necho REAL\n' > "$TEST_BIN/npm-real"; chmod +x "$TEST_BIN/npm-real"
  # An npx wrapper of ours whose real binary is gone.
  stub_bin npx 'echo "STUB:npx"'
  stage_old_intel_wrapper npx
  rm -f "$TEST_BIN/npx-real"
  local npm_before npx_before
  npm_before=$(cksum < "$TEST_BIN/npm"); npx_before=$(cksum < "$TEST_BIN/npx")
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cksum < "$TEST_BIN/npm")" = "$npm_before" ]
  [ -e "$TEST_BIN/npm-real" ]
  [[ "$output" != *"npm: intel is off"* ]]
  [ "$(cksum < "$TEST_BIN/npx")" = "$npx_before" ]
  [[ "$output" == *"npx: $TEST_BIN/npx is the npx wrapper an earlier intel: sfw run deployed"*"not an executable $TEST_BIN/npx-real"*"Re-run with INTEL=sfw"* ]]
}

@test "intel off without sudo: another account's wrapper is left alone and named" {
  [ "$(id -u)" != 0 ] || skip "root may replace any account's file"
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null \
    || skip "needs passwordless sudo to plant a wrapper root owns"
  stub_bin npm 'case "${1:-}" in --version) echo "10.9.8" ;; *) echo "STUB:npm ARGS=[$*]" ;; esac'
  stub_bin npx 'echo "STUB:npx ARGS=[$*]"'
  stage_old_intel_wrapper npm
  stage_old_intel_wrapper npx
  # Root's, as a root run's would be, in a directory this account can write.
  sudo chown 0 "$TEST_BIN/npm" "$TEST_BIN/npm-real"
  local before
  before=$(cksum < "$TEST_BIN/npm")
  run harden_nosudo ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cksum < "$TEST_BIN/npm")" = "$before" ]
  [ -e "$TEST_BIN/npm-real" ]
  [[ "$output" == *"npm: $TEST_BIN/npm is the npm wrapper an earlier intel: sfw run deployed as root"*"Re-run harden.sh as root or with sudo"* ]]
  # This account's own npx wrapper is still taken back.
  assert_file_lacks "$TEST_BIN/npx" "supply-chain-harden"
  sudo rm -f "$TEST_BIN/npm" "$TEST_BIN/npm-real"
}

@test "a run without cargo names an older cargo wrapper that routes through sfw unprotected; a run with cargo replaces it" {
  # The cargo wrapper also carries --locked, so it is not removed; a run that
  # includes cargo re-renders it, and one that does not has to say so.
  stub_bin npm 'case "${1:-}" in --version) echo "10.9.8" ;; *) echo "STUB:npm ARGS=[$*]" ;; esac'
  stub_bin cargo 'case "${1:-}" in --version|-V) echo "cargo 1.100.0 (abc 2026-11-05)";; *) echo "STUB:cargo ARGS=[$*]";; esac'
  mv "$TEST_BIN/cargo" "$TEST_BIN/cargo-real"
  # 8281a6b's rendering, cut down: header, the route with intel on, no skip.
  cat > "$TEST_BIN/cargo" <<EOF
#!/bin/bash
# cargo — supply-chain-harden wrapper
REAL_CARGO='$TEST_BIN/cargo-real'
run_real() {
  local pfx=""
  if [ "true" = "true" ] && [ "\${SCH_NET:-0}" = "1" ] \\
     && command -v sfw >/dev/null 2>&1; then
    pfx="sfw"
  fi
  exec \$pfx "\$REAL_CARGO" "\$@"
}
run_real "\$@"
EOF
  chmod 755 "$TEST_BIN/cargo"
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"cargo: $TEST_BIN/cargo is a cargo wrapper from an earlier hardening run that routes cargo through sfw without SFW_SKIP_UPDATE_CHECK"*"Re-run with cargo in ECOSYSTEMS to replace it"* ]]
  run harden ECOSYSTEMS=npm,cargo -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" != *"routes cargo through sfw without SFW_SKIP_UPDATE_CHECK"* ]]
  assert_file_contains "$TEST_BIN/cargo" "SFW_SKIP_UPDATE_CHECK"
  # A current wrapper is not reported by a later run without cargo.
  run harden ECOSYSTEMS=npm -- --emit=plain
  [[ "$output" != *"routes cargo through sfw"* ]]
}

# ------------------------------------------------------------ privilege ----

@test "no sudo, writable target: still wraps — this is the container-as-root case" {
  # REGRESSION. Before the guard this exited 127 at the first `sudo mv`,
  # even though the target was writable and no escalation was needed.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  run harden_nosudo ECOSYSTEMS=bun -- --emit=plain
  [ "$status" -eq 0 ]
  grep -q "supply-chain-harden" "${TEST_BIN}/bun"
}

@test "no sudo does not eat the ecosystems listed after it" {
  # MEASURED: with ECOSYSTEMS=bun,npm,pip only .bunfig.toml was written —
  # npm, pip and everything after never ran. Same "one failure eats the rest"
  # shape the role fixed in tasks/go.yml.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  run harden_nosudo ECOSYSTEMS=bun,npm,pip -- --emit=plain
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.npmrc" ]
  [ -f "$TEST_HOME/.config/pip/pip.conf" ]
}

@test "an unwritable target degrades with a reason instead of dying" {
  # Root writes into a 0555 directory, so as root there is no unwritable target.
  [ "$(id -u)" -ne 0 ] || skip "running as root: a 0555 directory does not stop root"
  local ro="${BATS_TEST_TMPDIR}/ro"
  mkdir -p "$ro"
  cat > "$ro/bun" <<'EOF'
#!/bin/bash
case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac
EOF
  chmod +x "$ro/bun"
  chmod 555 "$ro"          # cannot replace a file in a non-writable directory

  run env -i PATH="${NOSUDO}:${ro}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    WRITE_ETC=false ECOSYSTEMS=bun bash "$HARDEN_SH" --emit=plain
  chmod 755 "$ro"

  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot deploy the PATH wrapper"* ]]
  [[ "$output" == *"no root and no usable sudo"* ]]
}

@test "no sudo: a bunx this account cannot replace degrades bun and does not eat the ecosystems after it" {
  # MEASURED (v2.1.0, main 8cfc1c4): bun in the home directory and bunx in a
  # root-owned one. `rm -f bunx` died on "Permission denied" under set -e: rc 1,
  # no summary, and every ecosystem after bun skipped.
  [ "$(id -u)" -ne 0 ] || skip "running as root: a 0555 directory does not stop root"
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  rm -f "${TEST_BIN}/bunx"
  local ro="${BATS_TEST_TMPDIR}/ro-bunx"
  mkdir -p "$ro"
  printf '#!/bin/bash\necho THEIRS\n' > "$ro/bunx"
  chmod 755 "$ro/bunx"
  chmod 555 "$ro"

  run env -i PATH="${NOSUDO}:${TEST_BIN}:${ro}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    WRITE_ETC=false ECOSYSTEMS=bun,npm,pip bash "$HARDEN_SH" --emit=plain
  local theirs; theirs=$("$ro/bunx")
  chmod 755 "$ro"

  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.npmrc" ]                         # the ecosystems after bun
  [ -f "$TEST_HOME/.config/pip/pip.conf" ]
  grep -q "supply-chain-harden" "${TEST_BIN}/bun"    # bun itself is still wrapped
  [ "$theirs" = THEIRS ]                             # bunx is left as it was
  [[ "$output" == *"cannot deploy the PATH wrapper at $ro/bunx"* ]]
  [[ "$output" == *"degraded: "*bun* ]]              # and the verdict line says so
}

@test "no sudo: an npx wrapper this account cannot rewrite is left alone and does not end the run" {
  # npm's directory lets this account in and npx's does not; npx there is the
  # wrapper an earlier run as root left. Only the FIRST wrap asked about privilege,
  # so the re-wrap's `tee` died on "Permission denied" under set -e.
  [ "$(id -u)" -ne 0 ] || skip "running as root: a 0555 directory does not stop root"
  stub_bin npm 'case "${1:-}" in --version|-v) echo "11.12.0";; root|prefix) echo "$TMPDIR";; *) exit 0;; esac'
  stub_bin sfw 'exec "$@"'
  rm -f "${TEST_BIN}/npx"
  local ro="${BATS_TEST_TMPDIR}/ro-npx"
  mkdir -p "$ro"
  printf '#!/bin/bash\n# Managed by supply-chain-harden action\nREAL_NPX=x\n' > "$ro/npx"
  printf '#!/bin/bash\necho REAL\n' > "$ro/npx-real"
  chmod 755 "$ro/npx" "$ro/npx-real"
  cp "$ro/npx" "${BATS_TEST_TMPDIR}/npx.before"
  chmod 555 "$ro" "$ro/npx"

  run env -i PATH="${NOSUDO}:${TEST_BIN}:${ro}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    WRITE_ETC=false INSTALL_SFW=true ECOSYSTEMS=npm bash "$HARDEN_SH" --emit=plain
  chmod 755 "$ro"

  [ "$status" -eq 0 ]
  grep -q "supply-chain-harden" "${TEST_BIN}/npm"    # FIXTURE CONTROL: the run got as far as wrapping
  cmp "$ro/npx" "${BATS_TEST_TMPDIR}/npx.before"
  [[ "$output" == *"npx: cannot deploy the PATH wrapper"* ]]
  [[ "$output" == *"done (emit=plain)"* ]]
}

# A sudo that works and still cannot write: what root is on a read-only image or mount.
# MEASURED (v2.1.0 and ef4da26, root in a container, the tool on a read-only mount):
# `mv: cannot move '/opt/ro/bin/bun' ...: Read-only file system` ended the run, with
# every ecosystem after it not applied and no summary; deno, cargo and composer too.
weak_sudo() { stub_bin sudo '[ "${1:-}" != -n ] || shift; exec "$@"'; }

@test "root that cannot write to a tool's directory: degraded, the tool left alone, the rest applied" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: a 0555 directory does not stop root"
  local t ro what
  weak_sudo
  for t in bun deno cargo composer; do
    ro="${BATS_TEST_TMPDIR}/ro-$t"
    mkdir -p "$ro"
    printf '#!/bin/bash\ncase "${1:-}" in --version|-v) echo "9.9.9";; *) echo THEIRS;; esac\n' > "$ro/$t"
    chmod 755 "$ro/$t"
    cp "$ro/$t" "${BATS_TEST_TMPDIR}/$t.before"
    rm -f "${TEST_BIN}/$t"
    chmod 555 "$ro"
    run env -i PATH="${TEST_BIN}:${ro}:${PASSWD_BIN}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
      WRITE_ETC=false ECOSYSTEMS="$t,maven" bash "$HARDEN_SH" --emit=plain
    chmod 755 "$ro"
    [ "$status" -eq 0 ] || { echo "$t: $output"; false; }
    [[ "$output" == *"$t: cannot deploy the PATH wrapper at $ro/$t"*"not writable, even as root"* ]] || { echo "$t: $output"; false; }
    what=degraded; [ "$t" != deno ] || what=ineffective
    grep -qx "ecosystems_$what=$t" "$OUT_FILE" || { echo "$t"; cat "$OUT_FILE"; false; }
    grep -qx 'ecosystems_effective=maven' "$OUT_FILE"
    grep -qx 'wrappers_deployed=' "$OUT_FILE"
    cmp "$ro/$t" "${BATS_TEST_TMPDIR}/$t.before"
    [ ! -e "$ro/$t-real" ]
  done
}

@test "a tool that cannot be moved aside in a writable directory: degraded, left alone, the rest applied" {
  # A file mounted on its own. MEASURED (podman, root): mv says "Device or resource busy".
  local t what
  stub_bin sudo '[ "${1:-}" != -n ] || shift
if [ "${1:-}" = mv ]; then echo "mv: cannot move '"'x' to 'x-real'"': Device or resource busy" >&2; exit 1; fi
exec "$@"'
  for t in bun deno cargo composer; do
    stub_bin "$t" 'case "${1:-}" in --version|-v) echo "9.9.9";; *) echo THEIRS;; esac'
    cp "${TEST_BIN}/$t" "${BATS_TEST_TMPDIR}/$t.before"
    run harden ECOSYSTEMS="$t,maven" -- --emit=plain
    [ "$status" -eq 0 ] || { echo "$t: $output"; false; }
    [[ "$output" == *"Device or resource busy"*"the tool there cannot be moved aside"* ]] || { echo "$t: $output"; false; }
    what=degraded; [ "$t" != deno ] || what=ineffective
    grep -qx "ecosystems_$what=$t" "$OUT_FILE" || { echo "$t"; cat "$OUT_FILE"; false; }
    grep -qx 'ecosystems_effective=maven' "$OUT_FILE"
    cmp "${TEST_BIN}/$t" "${BATS_TEST_TMPDIR}/$t.before"
    rm -f "${TEST_BIN}/$t"
  done
}

@test "an /etc that root cannot write is a warning, and the per-user config is all there" {
  # The stub refuses every write to /etc, so nothing on this machine is touched.
  local f
  stub_bin sudo '[ "${1:-}" != -n ] || shift
case "$*" in *"/etc"*) echo "tee: /etc/x: Read-only file system" >&2; exit 1 ;; esac
exec "$@"'
  [ "$(id -u)" -ne 0 ] || skip "running as root: there is no sudo in between to refuse"
  stub_npm 11.19.1
  run env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    WRITE_ETC=true ECOSYSTEMS=npm,pip,uv bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for f in /etc/npmrc /etc/pip.conf /etc/uv/uv.toml; do
    [[ "$output" == *"cannot write $f (Read-only file system)"* ]] || { echo "$f: $output"; false; }
  done
  [ -f "$TEST_HOME/.npmrc" ]
  [ -f "$TEST_HOME/.config/pip/pip.conf" ]
  [ -f "$TEST_HOME/.config/uv/uv.toml" ]
  [[ "$output" == *"done (emit=plain)"* ]] || false
}

@test "a sudo that will not answer whether it can write is taken at its word, as before" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  sudo -n true 2>/dev/null || skip "needs passwordless sudo to wrap binaries"
  # allows everything but sh, the way a sudoers list of commands may
  local real; real=$(command -v sudo)
  stub_bin sudo "case \"\${1:-} \${2:-}\" in 'sh '*) exit 1 ;; esac
exec '$real' \"\$@\""
  local ro="${BATS_TEST_TMPDIR}/ro-ask"
  mkdir -p "$ro"
  printf '#!/bin/bash\ncase "${1:-}" in --version|-v) echo "9.9.9";; *) echo THEIRS;; esac\n' > "$ro/bun"
  chmod 755 "$ro/bun"; chmod 555 "$ro"
  rm -f "${TEST_BIN}/bun"
  run env -i PATH="${TEST_BIN}:${ro}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    WRITE_ETC=false ECOSYSTEMS=bun bash "$HARDEN_SH" --emit=plain
  chmod 755 "$ro"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q supply-chain-harden "$ro/bun"
  [ -x "$ro/bun-real" ]
  "$real" -n rm -f "$ro/bun" "$ro/bun-real"
}

@test "a degraded wrapper is reported in the verdict line, not only the table" {
  # A status word outside the APPLIED/PARTIAL/INERT vocabulary lands in
  # neither summary list, so the ecosystem vanishes from the one line most
  # people read while still appearing in the table below it — reported and
  # unreported at once. Caught in review of this very change.
  [ "$(id -u)" -ne 0 ] || skip "running as root: a 0555 directory does not stop root"
  local ro="${BATS_TEST_TMPDIR}/ro2"
  mkdir -p "$ro"
  cat > "$ro/bun" <<'EOF'
#!/bin/bash
case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac
EOF
  chmod +x "$ro/bun"
  chmod 555 "$ro"

  run env -i PATH="${NOSUDO}:${ro}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    WRITE_ETC=false ECOSYSTEMS=bun bash "$HARDEN_SH" --emit=plain
  chmod 755 "$ro"

  [[ "$output" == *"degraded: bun"* ]]
}

@test "a second account without sudo leaves root's wrapper alone, names it, and applies the rest" {
  # MEASURED at 6c77f4e: root hardened first, so the cargo wrapper was root's,
  # in a directory every account could write (the official rust images'
  # /usr/local/cargo/bin is 0777). A second account with no sudo then ran
  # harden.sh: the directory check passed, `cp` hit root's file, and set -e
  # ended the run on a bare "cp: cannot create regular file ... Permission
  # denied", rc=1, with nothing after cargo applied. The wrapper must not be
  # replaced (root runs it), and the refusal must say whose it is and what to do.
  [ "$(id -u)" != 0 ] || skip "root may replace any account's file"
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null \
    || skip "needs passwordless sudo to plant a wrapper root owns"
  stub_bin cargo 'case "${1:-}" in --version|-V) echo "cargo 1.100.0 (abc 2026-11-05)";; *) echo "STUB:cargo ARGS=[$*]";; esac'
  # The first run wraps through sudo, as root's run would: a root-owned wrapper
  # in a directory this account can write.
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  [ "$(ls -ln "$TEST_BIN/cargo" | awk '{print $3}')" = 0 ]
  grep -q 'supply-chain-harden' "$TEST_BIN/cargo"
  local before home2="${BATS_TEST_TMPDIR}/home2"
  before=$(cksum < "$TEST_BIN/cargo")
  mkdir -p "$home2"
  run env -i PATH="${NOSUDO}:${TEST_BIN}:${PATH}" HOME="$home2" \
    GRADLE_USER_HOME="$home2/.gradle" TMPDIR="$TEST_TMP" WRITE_ETC=false \
    ECOSYSTEMS=cargo,bundler bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"Permission denied"* ]]
  [[ "$output" == *"the PATH wrapper at $TEST_BIN/cargo belongs to root"* ]]
  [[ "$output" == *"re-run harden.sh as root or with sudo"* ]]
  [[ "$output" == *"degraded: "*cargo* ]]
  # Root's wrapper is untouched; this account's own layer, and the ecosystem
  # after cargo, still landed.
  [ "$(cksum < "$TEST_BIN/cargo")" = "$before" ]
  [ "$(ls -ln "$TEST_BIN/cargo" | awk '{print $3}')" = 0 ]
  [ -f "$home2/.cargo/config.toml" ]
  [ -f "$home2/.bundle/config" ]
}

@test "write_etc without privilege warns instead of failing the run" {
  # As root there is no missing privilege to test: harden.sh runs its writes
  # directly, so this would write the real /etc/npmrc.
  [ "$(id -u)" -ne 0 ] || skip "running as root: this would write the host's /etc/npmrc"
  stub_bin npm 'case "${1:-}" in --version|-v) echo "11.10.0";; *) echo STUB;; esac'
  run env -i PATH="${NOSUDO}:${TEST_BIN}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    WRITE_ETC=true ECOSYSTEMS=npm bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.npmrc" ]      # the per-user layer still landed
}

# --------------------------------------------------------- npm subcommands --

# Removed: "the npm wrapper covers exec and x" grep'd HARDEN_SH's own source
# text, not the deployed wrapper's behavior — the "assert the tool's own echo,
# not observed enforcement" anti-pattern this suite otherwise avoids. The npm
# exec/x allowlist is covered by the deployed wrapper (reconciled to match the
# role) and the action-smoke integration suite; a real behavioral check here
# would need a live sfw install, out of scope for this unit file.
