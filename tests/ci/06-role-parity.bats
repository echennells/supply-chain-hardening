#!/usr/bin/env bats
# Drift between the role and the CI script.
#
# These are two implementations of one policy: the role renders Jinja
# templates, the action writes the same files from bash. Every divergence so
# far has been silent — a plausible key the tool ignores, or a protection the
# role added months earlier that the action simply never grew. Nothing failed;
# the gaps were found by reading.
#
# This is the standing check that replaces the reading. See parity.py for the
# exclusion list, which is where a deliberate difference gets argued for.

load helpers

setup() { common_setup; }

@test "the action carries every role config key that is not excluded" {
  harden -- --emit=plain >/dev/null
  run python3 "${BATS_TEST_DIRNAME}/parity.py" "$TEST_HOME"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the parity check actually detects a dropped protection" {
  # A checker that cannot fail is worse than none — it reads as coverage.
  harden -- --emit=plain >/dev/null
  # Drop a key the role sets and the action currently carries.
  grep -v '^ignoreScripts:' "$TEST_HOME/.config/pnpm/config.yaml" > "$TEST_HOME/.tmp" \
    && mv "$TEST_HOME/.tmp" "$TEST_HOME/.config/pnpm/config.yaml"
  run python3 "${BATS_TEST_DIRNAME}/parity.py" "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ignoreScripts"* ]]
}

@test "the env layer matches the role's exactly" {
  # 18 variables on both sides today. This is the layer most likely to drift
  # unnoticed, because an env var that is never set looks identical to one
  # that is set correctly unless you go looking.
  harden -- --emit=plain >/dev/null
  run python3 "${BATS_TEST_DIRNAME}/env-parity.py"
  echo "$output"
  [ "$status" -eq 0 ]
}
