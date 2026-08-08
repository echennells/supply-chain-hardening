#!/usr/bin/env bats
# supply-chain-verify: does the verifier actually catch a silently-broken
# protection, or does it just print a reassuring table?
#
# This suite deliberately does NOT assert "everything is OK on this host" —
# that would be a tautology test of the same kind that let six silent no-ops
# ship. It stages the real failure shapes with stand-in binaries on PATH and
# asserts the verifier reports a GAP for each one.

load setup

VERIFY=/usr/local/bin/supply-chain-verify

setup() {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
}

@test "verify: the command is deployed and executable" {
  [ -x "$VERIFY" ]
}

@test "verify: runs and emits the evidence-strength legend" {
  run "$VERIFY"
  # rc is 0 or 1 depending on the host; both are valid outcomes.
  echo "$output" | grep -q "STATUS"
  echo "$output" | grep -q "EVIDENCE"
  # The legend is load-bearing: a row's meaning depends on how it was proven.
  echo "$output" | grep -q "FUNCTIONAL = observed behavior"
  echo "$output" | grep -q "PARSED = the tool reported the"
}

@test "verify: --help works without running any probe" {
  run "$VERIFY" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "evidence strength"
}

@test "verify: BEHAVIORAL — catches yarn's npmMinimalAgeGate parsing to NaN" {
  # The c9a250f bug. The config file said exactly what we intended; yarn
  # parsed "2d" to NaN and applied no gate at all, with no warning. Grepping
  # our own file could never catch this. Asking yarn could.
  cat > "$FAKEBIN/yarn" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "4.10.3"; exit 0; }
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  case "$3" in
    npmMinimalAgeGate) echo "NaN" ;;
    enableScripts)     echo "false" ;;
  esac
fi
EOF
  chmod +x "$FAKEBIN/yarn"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep -q "yarn age gate"
  echo "$output" | grep "yarn age gate" | grep -q "GAP"
  [ "$status" -eq 1 ]
}

@test "verify: BEHAVIORAL — catches an npq that is installed but suppressed" {
  # The bug QA found. npq fails OPEN below Node 20.13.0: one line to stderr,
  # passthrough to the real package manager, exit 0. Presence checks report
  # full coverage in exactly this state.
  cat > "$FAKEBIN/npq-hero" <<'EOF'
#!/bin/bash
echo "error: npq suppressed due to old node version" >&2
echo "9.2.0"
exit 0
EOF
  chmod +x "$FAKEBIN/npq-hero"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "npq reputation checks" | grep -q "GAP"
  echo "$output" | grep "npq reputation checks" | grep -q "SUPPRESSED"
  [ "$status" -eq 1 ]
}

@test "verify: BEHAVIORAL — catches yarn 1.x ignoring .yarnrc.yml entirely" {
  cat > "$FAKEBIN/yarn" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "1.22.22"; exit 0; }
EOF
  chmod +x "$FAKEBIN/yarn"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "yarn hardening" | grep -q "GAP"
  [ "$status" -eq 1 ]
}

@test "verify: a working yarn is reported OK, so GAP is not the default answer" {
  # Counterweight to the tests above. A verifier that reports GAP for
  # everything would pass all of them and be useless.
  cat > "$FAKEBIN/yarn" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "4.10.3"; exit 0; }
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  case "$3" in
    npmMinimalAgeGate) echo "2880" ;;
    enableScripts)     echo "false" ;;
  esac
fi
EOF
  chmod +x "$FAKEBIN/yarn"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "yarn age gate" | grep -q "OK"
  echo "$output" | grep "yarn age gate" | grep -q "2880"
}

@test "verify: wrapper rows are labeled PRESENT, never counted as enforcement" {
  # PATH wrappers are the weakest evidence in the role: existence says nothing
  # about whether callers resolve through them. If a wrapper row ever claims
  # FUNCTIONAL, the evidence taxonomy has been undermined.
  run "$VERIFY"
  wrapper_rows=$(echo "$output" | grep "PATH wrapper" || true)
  if [ -n "$wrapper_rows" ]; then
    ! echo "$wrapper_rows" | grep -q "FUNCTIONAL"
  fi
}
