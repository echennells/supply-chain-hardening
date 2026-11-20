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

@test "the config layer survives a step boundary with no env at all" {
  # The per-step-container shape (Drone, Woodpecker): nothing in a process
  # environment crosses a step, so this is what the portability claim rests
  # on. Config files land in a shared HOME and are read by the tool directly.
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null

  # A completely fresh environment — no sourcing, no inherited variables.
  run env -i PATH="$PATH" HOME="$TEST_HOME" npm config get ignore-scripts
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "the env layer is genuinely absent until sourced, and present after" {
  # The other half of the same claim: if the env layer appeared to work
  # without the source line, the file would be pointless and the docs wrong.
  harden ECOSYSTEMS=go -- --emit=plain >/dev/null

  run env -i PATH="$PATH" HOME="$TEST_HOME" bash -c 'echo "${GOFLAGS:-ABSENT}"'
  [ "$output" = "ABSENT" ]

  run env -i PATH="$PATH" HOME="$TEST_HOME" bash -c "source '$ENV_FILE'; echo \"\$GOFLAGS\""
  [ "$output" = "-mod=readonly" ]
}

# ---- The shipped GitLab example, run as written ----
#
# GitLab's Docker and Kubernetes executors run jobs under `umask 0000` unless
# FF_DISABLE_UMASK_FOR_DOCKER_EXECUTOR / ..._KUBERNETES_EXECUTOR is on (runner
# feature-flag docs), so the checkout is drwxrwxrwx. The example used to pin
# HARDENING_ENV_FILE into $CI_PROJECT_DIR. MEASURED in a container (review of
# the VM#3 fix): harden.sh refused that directory, rc=2, and the anchor's
# source line then failed with "No such file or directory". These tests read
# the example file itself, so editing the example is what they test.

# gitlab_job <file> <job>: the example's top-level `variables:` as exports,
# then that job's lines (`.harden` = the anchor), comments stripped.
gitlab_job() {
  awk -v job="$2" '
    /^variables:/ { v = 1; next }
    v && /^  [A-Za-z_][A-Za-z0-9_]*:/ { k = $1; sub(/:$/, "", k); $1 = ""; sub(/^ /, ""); print "export " k "=" $0; next }
    v && /^[^ #]/ { v = 0 }
    job == ".harden" && /^\.harden: &harden/ { h = 1; next }
    h && /^  - / { l = $0; sub(/^  - /, "", l); print l; next }
    h { h = 0 }
    job != ".harden" && $0 == job ":" { j = 1; next }
    j && /^[^ ]/ { j = 0 }
    j && /^  script:/ { s = 1; next }
    j && s && /^    - / { l = $0; sub(/^    - /, "", l); sub(/ +#.*$/, "", l); print l; next }
    j && s && /^  [^ ]/ { s = 0 }
  ' "$1"
}

# run_gitlab_job <job>: in a 0777 checkout, as GitLab runs a script.
run_gitlab_job() {
  local ex="${BATS_TEST_DIRNAME}/../../action/examples/gitlab-ci.yml"
  PROJ="$TEST_TMP/builds/grp/proj"
  (umask 0000 && mkdir -p "$PROJ" && cp -R "${BATS_TEST_DIRNAME}/../../action" "$PROJ/action")
  [ "$(ls -ld "$PROJ" | cut -c1-10)" = drwxrwxrwx ]
  JOB_LINES=$(gitlab_job "$ex" "$1")
  [[ "$JOB_LINES" == *"./action/harden.sh --emit=gitlab"* ]]
  # Each failing line stops the job, as GitLab does ("further commands do not execute").
  { echo 'set -eo pipefail'; echo 'umask 0000'; echo 'cd "$CI_PROJECT_DIR"'
    printf '%s\n' "$JOB_LINES"
    echo 'echo "JOB-END NPM_CONFIG_IGNORE_SCRIPTS=${NPM_CONFIG_IGNORE_SCRIPTS:-<unset>}"'
  } > "$TEST_TMP/job.sh"
  run env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" \
    GRADLE_USER_HOME="${TEST_HOME}/.gradle" TMPDIR="$TEST_TMP" WRITE_ETC=false \
    ECOSYSTEMS=npm GITLAB_CI=true CI_PROJECT_DIR="$PROJ" CI_JOB_ID=4242 \
    bash "$TEST_TMP/job.sh"
}

@test "gitlab example: the .harden anchor works in a world-writable checkout under umask 0000" {
  [ ! -e "$TEST_HOME/.cache" ]
  run_gitlab_job .harden
  [ "$status" -eq 0 ]
  [[ "$output" != *"refusing to write"* ]]
  [[ "$output" == *"JOB-END NPM_CONFIG_IGNORE_SCRIPTS=true"* ]]
  [ -f "$ENV_FILE" ]
  # The umask did not leak into the directories harden.sh made.
  [ "$(ls -ld "$TEST_HOME/.cache" | cut -c1-10)" = drwx------ ]
  [ "$(ls -ld "$STATE_DIR" | cut -c1-10)" = drwx------ ]
}

@test "gitlab example: the dotenv job copies the env file it just wrote" {
  sed --version >/dev/null 2>&1 || skip "the example's sed -i is GNU sed"
  run_gitlab_job build-with-dotenv
  [ "$status" -eq 0 ]
  assert_file_contains "$PROJ/hardening.env" "NPM_CONFIG_IGNORE_SCRIPTS=true"
  # Not `! grep`: bats does not fail a test on a negated command.
  [ -z "$(grep '^export ' "$PROJ/hardening.env")" ]
}
