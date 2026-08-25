#!/usr/bin/env bats
# The portability claim, made falsifiable.
#
# harden.sh routes env vars, outputs and log annotations through one adapter.
# These tests assert each target writes to ITS OWN sink and to no other — the
# failure mode that matters is a new platform quietly inheriting GitHub's
# mechanism and appearing to work while propagating nothing.

load helpers

setup() { common_setup; }

@test "auto-detects github from GITHUB_ACTIONS" {
  run harden GITHUB_ACTIONS=true GITHUB_ENV="$TEST_TMP/ghenv" \
             GITHUB_OUTPUT="$TEST_TMP/ghout" GITHUB_STEP_SUMMARY="$TEST_TMP/ghsum" \
             ECOSYSTEMS=npm
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_TMP/ghenv" "NPM_CONFIG_IGNORE_SCRIPTS=true"
  assert_file_contains "$TEST_TMP/ghout" "ecosystems_hardened=npm"
  assert_file_contains "$TEST_TMP/ghsum" "Supply Chain Hardening Applied"
}

@test "auto-detects gitlab from GITLAB_CI" {
  run harden GITLAB_CI=true ECOSYSTEMS=npm
  [ "$status" -eq 0 ]
  [[ "$output" == *"emit=gitlab"* ]]
}

@test "auto-detects circleci and writes BASH_ENV" {
  : > "$TEST_TMP/bashenv"
  run harden CIRCLECI=true BASH_ENV="$TEST_TMP/bashenv" ECOSYSTEMS=npm
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_TMP/bashenv" "export NPM_CONFIG_IGNORE_SCRIPTS=true"
}

@test "auto-detects azure and emits vso commands" {
  run harden TF_BUILD=true ECOSYSTEMS=npm
  [ "$status" -eq 0 ]
  [[ "$output" == *"##vso[task.setvariable variable=NPM_CONFIG_IGNORE_SCRIPTS]true"* ]]
}

@test "falls back to plain with no CI markers at all" {
  run harden ECOSYSTEMS=npm
  [ "$status" -eq 0 ]
  [[ "$output" == *"emit=plain"* ]]
}

@test "explicit --emit overrides auto-detection" {
  : > "$TEST_TMP/ghenv"
  run harden GITHUB_ACTIONS=true GITHUB_ENV="$TEST_TMP/ghenv" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"emit=plain"* ]]
  # The github sink must be untouched when another target is selected.
  [ ! -s "$TEST_TMP/ghenv" ]
}

@test "plain mode emits no GitHub workflow commands" {
  run harden ECOSYSTEMS=npm,pip -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" != *"::group::"* ]]
  [[ "$output" != *"::error::"* ]]
  [[ "$output" != *"::warning::"* ]]
}

@test "non-github targets do not write BASH_ENV either" {
  : > "$TEST_TMP/bashenv"
  run harden BASH_ENV="$TEST_TMP/bashenv" ECOSYSTEMS=npm -- --emit=gitlab
  [ "$status" -eq 0 ]
  [ ! -s "$TEST_TMP/bashenv" ]
}

@test "gitlab section markers open and close with matching names" {
  run harden ECOSYSTEMS=npm,pip -- --emit=gitlab
  [ "$status" -eq 0 ]
  local starts ends
  starts=$(printf '%s' "$output" | grep -o 'section_start:0:[a-z]*' | sed 's/.*://' | sort)
  ends=$(printf '%s' "$output" | grep -o 'section_end:0:[a-z]*' | sed 's/.*://' | sort)
  [ -n "$starts" ]
  [ "$starts" = "$ends" ]
}

@test "unknown emit target is rejected with a usable message" {
  run harden ECOSYSTEMS=npm -- --emit=jenkins
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown --emit target 'jenkins'"* ]]
  [[ "$output" == *"supported:"* ]]
}

@test "every target writes the canonical env file" {
  local t
  for t in github gitlab circleci azure buildkite plain; do
    rm -f "$ENV_FILE"
    run harden GITHUB_ENV=/dev/null GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null \
               BASH_ENV=/dev/null ECOSYSTEMS=npm -- --emit=$t
    [ "$status" -eq 0 ]
    assert_file_contains "$ENV_FILE" "export NPM_CONFIG_IGNORE_SCRIPTS=true"
  done
}

@test "env file round-trips through source with values intact" {
  run harden ECOSYSTEMS=npm,go -- --emit=plain
  [ "$status" -eq 0 ]
  # A comma inside GOPROXY is the value most likely to be mangled by quoting.
  run env -i bash -c "source '$ENV_FILE'; printf '%s|%s' \"\$GOPROXY\" \"\$NPM_CONFIG_MIN_RELEASE_AGE\""
  [ "$status" -eq 0 ]
  [ "$output" = "https://proxy.golang.org,direct|2" ]
}

@test "env file leaves the bypass knobs set-but-empty, not unset" {
  run harden ECOSYSTEMS=go -- --emit=plain
  [ "$status" -eq 0 ]
  # An UNSET GOPRIVATE means "no policy"; an EMPTY one means "no bypasses".
  run env -i bash -c "source '$ENV_FILE'; printf '%s' \"\${GOPRIVATE+set}\""
  [ "$output" = "set" ]
}

@test "--help lists the targets and exits clean" {
  run harden -- --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--emit="* ]]
  [[ "$output" == *"plain"* ]]
}

@test "an unrecognised argument warns but does not abort" {
  run harden ECOSYSTEMS=npm -- --frobnicate
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrecognised argument"* ]]
}
