#!/usr/bin/env bats
# Input validation and the fail-loud guards.
#
# Every case here is one where failing SILENTLY would be worse than failing:
# a disabled age gate or a half-applied run that still reports success is
# indistinguishable from a protected one at the terminal.

load helpers

setup() { common_setup; }

@test "release_age_hours=0 is rejected, not silently applied" {
  run harden RELEASE_AGE_HOURS=0 ECOSYSTEMS=npm
  [ "$status" -eq 2 ]
  [[ "$output" == *"silently disables the age gate"* ]]
}

@test "non-integer release_age_hours is rejected" {
  run harden RELEASE_AGE_HOURS="48 hours" ECOSYSTEMS=npm
  [ "$status" -eq 2 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "negative release_age_hours is rejected" {
  run harden RELEASE_AGE_HOURS=-5 ECOSYSTEMS=npm
  [ "$status" -eq 2 ]
}

@test "a sub-day age gate rounds npm UP to one day rather than to zero" {
  # 12/24 == 0 in integer division, and npm reads whole days. Rounding down
  # would silently disable the npm gate for anyone asking for a short window.
  run harden RELEASE_AGE_HOURS=12 ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.npmrc" "min-release-age=1"
}

@test "missing HOME is refused" {
  run env -i PATH="$PATH" TMPDIR="$TEST_TMP" WRITE_ETC=false ECOSYSTEMS=npm \
    bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOME is unset"* ]]
}

@test "a HOME pointing at a non-directory is refused" {
  run env -i PATH="$PATH" HOME="$TEST_TMP/not-a-dir" TMPDIR="$TEST_TMP" \
    WRITE_ETC=false ECOSYSTEMS=npm bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 2 ]
}

@test "SUPPLY_CHAIN_HARDEN_SKIP exits early without hardening anything" {
  run harden SUPPLY_CHAIN_HARDEN_SKIP=true ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"intentionally skipped"* ]]
  [ ! -f "$TEST_HOME/.npmrc" ]
}

@test "the skip path still emits the full output set" {
  # A consumer reading steps.harden.outputs.* must not get undefined values
  # just because hardening was skipped.
  run harden SUPPLY_CHAIN_HARDEN_SKIP=true ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "ecosystems_hardened="
  assert_file_contains "$OUT_FILE" "release_age_hours=48"
  assert_file_contains "$OUT_FILE" "sfw_installed=false"
  assert_file_contains "$OUT_FILE" "tool_versions={}"
  assert_file_contains "$OUT_FILE" "env_file="
}

@test "an unknown ecosystem warns and is skipped, the rest still apply" {
  run harden ECOSYSTEMS=npm,nosuchtool,pip -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unknown ecosystem: 'nosuchtool'"* ]]
  assert_file_contains "$OUT_FILE" "ecosystems_hardened=npm,pip"
}

@test "trailing and doubled commas in the ecosystem list are tolerated" {
  run harden ECOSYSTEMS="npm,,pip," -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown ecosystem"* ]]
  assert_file_contains "$OUT_FILE" "ecosystems_hardened=npm,pip"
}

@test "ecosystem names are case- and whitespace-insensitive" {
  run harden ECOSYSTEMS=" NPM , Pip " -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "ecosystems_hardened=npm,pip"
}

@test "a TMPDIR that does not exist yet is created, not fatal" {
  run env -i PATH="$PATH" HOME="$TEST_HOME" TMPDIR="$TEST_TMP/deep/nested" \
    WRITE_ETC=false ECOSYSTEMS=npm bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/deep/nested/supply-chain-hardening.env" ]
}

@test "an unwritable env file path fails loudly with the path named" {
  run env -i PATH="$PATH" HOME="$TEST_HOME" \
    HARDENING_ENV_FILE=/proc/cannot/write.env \
    WRITE_ETC=false ECOSYSTEMS=npm bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot write the env file"* ]]
  [[ "$output" == *"/proc/cannot/write.env"* ]]
}

@test "tool_versions is valid JSON" {
  run harden ECOSYSTEMS=npm,pip,cargo -- --emit=plain
  [ "$status" -eq 0 ]
  local tv
  tv=$(grep '^tool_versions=' "$OUT_FILE" | cut -d= -f2-)
  run node -e "JSON.parse(process.argv[1])" "$tv"
  [ "$status" -eq 0 ]
}

@test "reporting: an ecosystem whose only mechanism could not be applied reads NOT applied" {
  # deno has NO config file — a PATH wrapper is its entire mechanism. With deno
  # absent, nothing whatsoever is applied, and this used to report
  # "deno hardened" in the summary, the final line and the output.
  run harden ECOSYSTEMS=deno -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT applied: deno"* ]]
  assert_file_contains "$OUT_FILE" "ecosystems_ineffective=deno"
  assert_file_contains "$OUT_FILE" "^ecosystems_effective=$"
}

@test "reporting: the summary explains WHY an ecosystem is not in force" {
  run harden ECOSYSTEMS=deno -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not fully in force"* ]]
  [[ "$output" == *"PATH wrapper is the entire mechanism"* ]]
}

@test "reporting: a config-backed ecosystem with no wrapper reads degraded, not applied" {
  # cargo writes config AND needs a wrapper for --locked, which has no config
  # or env route at all. Absent cargo means partial, not full.
  run harden ECOSYSTEMS=cargo -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "ecosystems_degraded=cargo"
}

@test "reporting: npm that cannot enforce the age gate is flagged at hardening time" {
  # min-release-age landed in npm 11.10.0. The version is already detected, so
  # the run can say so itself instead of leaving it to an opt-in verifier.
  have npm || skip "npm not installed"
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  local v; v=$(npm --version)
  case "$v" in
    1[1-9].*|[2-9][0-9].*)
      # A new enough npm should NOT be flagged.
      [[ "$output" != *"does NOT implement min-release-age"* ]] ;;
    *)
      [[ "$output" == *"does NOT implement min-release-age"* ]]
      [[ "$output" == *"Script blocking is unaffected"* ]]
      assert_file_contains "$OUT_FILE" "ecosystems_degraded=npm" ;;
  esac
}

@test "reporting: a fully applied ecosystem says so without noise" {
  run harden ECOSYSTEMS=pip -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "ecosystems_effective=pip"
  [[ "$output" != *"Not fully in force"* ]]
}
