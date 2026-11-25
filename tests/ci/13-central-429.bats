#!/usr/bin/env bats
# Maven Central's rate limit (HTTP 429) is told apart from a control that does not
# work, in the smoke jobs and in the macOS job.
#
# The fixtures are the real output of the two jobs, from runs on GitHub:
#   maven-429       job 138217056780, reported as "maven did NOT block the HTTP repo"
#   gradle-429      job 138043538056, "errored but not with the expected shape"
#   maven-blocked   job 138643215336      gradle-blocked  job 138643215256

load helpers

VERDICT="${BATS_TEST_DIRNAME}/../smoke/verdict.sh"
FIX="${BATS_TEST_DIRNAME}/fixtures/central-429"

setup() { common_setup; unset GITHUB_OUTPUT; LOG="$BATS_TEST_TMPDIR/log"; }

@test "429: the two runs Maven Central refused are not-tested, neither a pass nor a fail" {
  run "$VERDICT" maven 1 "$FIX/maven-429.log"
  [ "$status" -eq 0 ]
  [[ "$output" == "not-tested Maven Central answered 429"* ]]
  run "$VERDICT" gradle 1 "$FIX/gradle-429.log"
  [[ "$output" == "not-tested Maven Central answered 429"* ]]
}

@test "429: the runs that were blocked are blocked, with the tool's own words" {
  run "$VERDICT" maven 1 "$FIX/maven-blocked.log"
  [[ "$output" == "blocked "*"central-https-only"*"Blocked mirror for repositories: [http-repo (ht"* ]] || { echo "$output"; false; }
  run "$VERDICT" gradle 1 "$FIX/gradle-blocked.log"
  [[ "$output" == "blocked "*"Resolution strategy disallows usage of dynamic versions"* ]]
}

@test "429: blocked wins over a 429 elsewhere in the same log" {
  cat "$FIX/maven-429.log" "$FIX/maven-blocked.log" > "$LOG"
  run "$VERDICT" maven 1 "$LOG"
  [[ "$output" == "blocked "* ]]
  cat "$FIX/gradle-429.log" "$FIX/gradle-blocked.log" > "$LOG"
  run "$VERDICT" gradle 1 "$LOG"
  [[ "$output" == "blocked "* ]]
}

@test "429: a refused run whose log names the fixture's group is not read as a block" {
  # The old test grepped for http.*blocked, and its group id was com.example.blocked:
  # any download line for it matched, 429 or not, mirror or not.
  { cat "$FIX/maven-429.log"
    echo '[INFO] Downloading from central: https://repo.maven.apache.org/maven2/com/example/blocked/only-on-http/1.0/only-on-http-1.0.pom'; } > "$LOG"
  grep -qiE "blocked.*mirror|http.*blocked|mirror.*blocked|external:http:.*blocked" "$LOG"
  run "$VERDICT" maven 1 "$LOG"
  [[ "$output" == "not-tested "* ]]
}

@test "429: the attack going through is not-blocked, and no 429 excuses it" {
  printf '[INFO] BUILD SUCCESS\n' > "$LOG"
  run "$VERDICT" maven 0 "$LOG"
  [[ "$output" == "not-blocked "* ]]
  run "$VERDICT" gradle 0 "$LOG"
  [[ "$output" == "not-blocked "* ]]
  # A 429 on the way, and the build succeeded anyway.
  run "$VERDICT" maven 0 "$FIX/maven-429.log"
  [[ "$output" == "not-blocked "* ]]
  run "$VERDICT" gradle 0 "$FIX/gradle-429.log"
  [[ "$output" == "not-blocked "* ]]
  # Maven went to the http repository, which the mirror exists to prevent.
  { cat "$FIX/maven-429.log"
    echo '[ERROR] Could not transfer artifact com.example.nowhere:only-on-http:pom:1.0 from/to http-repo (http://repo.example.com/maven2): repo.example.com: Name or service not known'; } > "$LOG"
  run "$VERDICT" maven 1 "$LOG"
  [[ "$output" == "not-blocked "*"went to the http repository"* ]]
}

@test "429: another failure, and a 429 from somewhere else, are not-blocked" {
  printf '[ERROR] Unknown lifecycle phase\n' > "$LOG"
  run "$VERDICT" maven 1 "$LOG"
  [[ "$output" == "not-blocked "* ]]
  # maven's own default blocker, not the mirror the Action wrote.
  sed 's/central-https-only/maven-default-http-blocker/' "$FIX/maven-blocked.log" > "$LOG"
  run "$VERDICT" maven 1 "$LOG"
  [[ "$output" == "not-blocked "* ]]
  printf "[ERROR] https://corp.example/maven2: HTTP Status: 429\n" > "$LOG"
  run "$VERDICT" maven 1 "$LOG"
  [[ "$output" == "not-blocked "* ]]
  printf "   > Could not GET 'https://corp.example/maven2/x'.\n      > Received status code 429 from server: Too Many Requests\n" > "$LOG"
  run "$VERDICT" gradle 1 "$LOG"
  [[ "$output" == "not-blocked "* ]]
}

@test "429: the verdict reaches the workflow, and the verdict jobs are skipped on not-tested" {
  local out="$BATS_TEST_TMPDIR/ghout" wf="${BATS_TEST_DIRNAME}/../../.github/workflows/action-smoke.yml"
  GITHUB_OUTPUT="$out" "$VERDICT" maven 1 "$FIX/maven-429.log" >/dev/null
  grep -qx 'verdict=not-tested' "$out"
  python3 -c 'import yaml' 2>/dev/null || skip "needs python3-yaml"
  python3 - "$wf" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["jobs"]
for attempt, verdict in (("action-maven-https-only-attempt", "action-maven-behavioral-https-only"),
                         ("action-gradle-dynamic-version-attempt", "action-gradle-behavioral-dynamic-version")):
    j = jobs[verdict]
    assert j["needs"] == attempt, verdict
    assert j["if"] == "needs.%s.outputs.verdict != 'not-tested'" % attempt, j["if"]
    assert jobs[attempt]["outputs"]["verdict"] == "${{ steps.attempt.outputs.verdict }}", attempt
    assert any("= blocked" in s.get("run", "") for s in j["steps"]), verdict
    assert any("tests/smoke/verdict.sh" in s.get("run", "") for s in jobs[attempt]["steps"]), attempt
PY
}
