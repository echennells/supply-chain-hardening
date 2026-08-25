#!/usr/bin/env bash
# Shared setup for the harden.sh suite.
#
# These tests exercise action/harden.sh DIRECTLY, on the host, with no docker
# and no Ansible. That is deliberate: the role's bats suite needs a built
# container, so before this file there was no test of the CI script that
# could run anywhere but a GitHub runner. Everything here runs on a bare
# checkout in under a second.
#
# Isolation: every test gets a throwaway $HOME and $TMPDIR and runs the
# script under `env -i`, so nothing touches the developer's real config and
# no ambient CI variable leaks in to skew platform auto-detection.

HARDEN_SH="${BATS_TEST_DIRNAME}/../../action/harden.sh"
VERIFY_SH="${BATS_TEST_DIRNAME}/../../action/verify.sh"

# Named rather than being bats' own setup(): a .bats file that needs extra
# setup (a skip guard, say) defines its own setup(), which SHADOWS a setup()
# defined here and silently leaves every path variable empty.
common_setup() {
  TEST_HOME="${BATS_TEST_TMPDIR}/home"
  TEST_TMP="${BATS_TEST_TMPDIR}/tmp"
  TEST_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$TEST_HOME" "$TEST_TMP" "$TEST_BIN"
  # shellcheck disable=SC2034  # consumed by the .bats files that load this
  ENV_FILE="${TEST_TMP}/supply-chain-hardening.env"
  # shellcheck disable=SC2034
  OUT_FILE="${TEST_TMP}/supply-chain-hardening.outputs"
}

# harden [VAR=value ...] [-- script args ...]
#
# Runs harden.sh in a pristine environment. WRITE_ETC defaults to false so the
# suite never needs sudo; tests that want the /etc layer pass WRITE_ETC=true
# explicitly and are skipped when sudo is unavailable.
harden() {
  local -a envs=() args=()
  local sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then sep=1; continue; fi
    if [[ $sep -eq 1 ]]; then args+=("$a"); else envs+=("$a"); fi
  done
  env -i \
    PATH="${TEST_BIN}:${PATH}" \
    HOME="$TEST_HOME" \
    TMPDIR="$TEST_TMP" \
    WRITE_ETC=false \
    "${envs[@]}" \
    bash "$HARDEN_SH" "${args[@]}"
}

# verify [VAR=value ...] [-- script args ...]
#
# Runs verify.sh the way a LATER CI step would: same HOME and PATH, but a
# fresh environment, so whether the env layer propagated is a real question
# rather than an artifact of the test inheriting it.
verify() {
  local -a envs=() args=()
  local sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then sep=1; continue; fi
    if [[ $sep -eq 1 ]]; then
      args+=("$a")
    else
      # Catch the mistake this helper otherwise hides: `env` accepts ANY token
      # containing = as a variable assignment, so a flag passed before `--`
      # becomes a bogus variable and never reaches the script — the test then
      # passes while testing the default path.
      [[ "$a" == -* ]] && { echo "helper misuse: pass script flags after --, got '$a'" >&2; return 64; }
      envs+=("$a")
    fi
  done
  env -i \
    PATH="${TEST_BIN}:${PATH}" \
    HOME="$TEST_HOME" \
    TMPDIR="$TEST_TMP" \
    HARDENING_ENV_FILE="$ENV_FILE" \
    "${envs[@]}" \
    bash "$VERIFY_SH" "${args[@]}"
}

# verify_sourced — as above, but with the env layer picked up first, which is
# what a correctly-configured job looks like.
verify_sourced() {
  env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    bash -c "set -a; source '$ENV_FILE'; set +a
             HARDENING_ENV_FILE='$ENV_FILE' bash '$VERIFY_SH' $*"
}

# stub_bin <name> [body]
#
# Drops a fake executable early on PATH so harden.sh discovers it, wraps it in
# place, and we can then assert on what the wrapper passes through. Default
# body echoes argv so a test can inspect the forwarded arguments; it also
# answers --version so detect_version finds something.
stub_bin() {
  local name="$1"; shift
  local body="${1:-}"
  if [[ -z "$body" ]]; then
    body='case "${1:-}" in
  --version|-v|version) echo "'"$name"' 9.9.9" ;;
  *) echo "STUB:'"$name"' ARGV0=$0 ARGS=[$*]" ;;
esac'
  fi
  # A previous wrap in the same test leaves a root-owned wrapper at this
  # path (harden.sh writes it with sudo), so plain truncation fails.
  [[ -e "${TEST_BIN}/${name}" ]] && sudo rm -f "${TEST_BIN}/${name}"
  printf '#!/bin/bash\n%s\n' "$body" > "${TEST_BIN}/${name}"
  chmod +x "${TEST_BIN}/${name}"
}

# stub_symlink <name> <target>
#
# The layout a real bun install actually has: bunx is a SYMLINK to bun, not a
# separate binary. Wrapping code that writes with `tee` follows that link and
# clobbers whatever it points at, so any wrapper test that stubs both as plain
# files is testing a shape that does not occur in the wild.
stub_symlink() {
  local name="$1" target="$2"
  [[ -e "${TEST_BIN}/${name}" || -L "${TEST_BIN}/${name}" ]] && sudo rm -f "${TEST_BIN}/${name}"
  ln -s "$target" "${TEST_BIN}/${name}"
}

# The real binary harden.sh moved aside when it wrapped our stub.
stub_real() { echo "${TEST_BIN}/${1}-real"; }

assert_file_contains() {
  local file="$1" pattern="$2"
  [[ -f "$file" ]] || { echo "expected file missing: $file"; return 1; }
  grep -q -- "$pattern" "$file" || {
    echo "pattern not found in $file: $pattern"
    echo "--- actual ---"; cat "$file"
    return 1
  }
}

assert_file_lacks() {
  local file="$1" pattern="$2"
  [[ -f "$file" ]] || return 0
  if grep -q -- "$pattern" "$file"; then
    echo "pattern SHOULD NOT be in $file: $pattern"
    echo "--- actual ---"; cat "$file"
    return 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }
