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
  env -i PATH="${NOSUDO}:${TEST_BIN}:${PATH}" HOME="$TEST_HOME" \
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

@test "a degraded wrapper is reported in the verdict line, not only the table" {
  # A status word outside the APPLIED/PARTIAL/INERT vocabulary lands in
  # neither summary list, so the ecosystem vanishes from the one line most
  # people read while still appearing in the table below it — reported and
  # unreported at once. Caught in review of this very change.
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

@test "write_etc without privilege warns instead of failing the run" {
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
