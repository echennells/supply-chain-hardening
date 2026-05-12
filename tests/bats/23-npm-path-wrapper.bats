#!/usr/bin/env bats
# Tests for the npm PATH wrapper (npm_path_wrapper: true).
#
# Background: shell aliases for npq only fire in interactive shells, leaving
# scripts, agents, package.json scripts, sudo, and CI without reputation or
# threat-intel coverage. The PATH wrapper sits at /usr/local/bin/npm and
# routes every npm invocation through Socket Firewall (non-interactive) or
# npq + sfw (interactive). The test container builds with this feature on.

load setup

@test "npm wrapper deployed at /usr/local/bin/npm" {
  assert_file_exists /usr/local/bin/npm
}

@test "npm wrapper is executable" {
  [ -x /usr/local/bin/npm ]
}

@test "npm wrapper has recursion safety guard" {
  # Same pattern as the pip→uv wrapper: refuse to run if the embedded real
  # npm path is empty, non-executable, or points back at ourselves. Without
  # this guard, a missing-real-npm scenario would loop until killed.
  assert_file_contains /usr/local/bin/npm "refusing to recurse"
}

@test "npm wrapper has TTY detection logic" {
  # Routes interactive callers to npq's prompt-driven review, non-interactive
  # callers (scripts, agents, CI) to sfw alone.
  assert_file_contains /usr/local/bin/npm "[ -t 0 ]"
}

@test "npm wrapper embeds a real npm path that resolves to an executable" {
  embedded=$(grep -E "^REAL_NPM=" /usr/local/bin/npm | head -1 | sed "s/REAL_NPM=//; s/'//g")
  [ -n "$embedded" ]
  [ -x "$embedded" ]
  [ "$embedded" != "/usr/local/bin/npm" ]
}

@test "which npm resolves to the wrapper, not the underlying binary" {
  # PATH order must put /usr/local/bin before /usr/bin for the wrapper to
  # intercept. If this fails, npm calls bypass the wrapper entirely.
  result=$(command -v npm)
  [ "$result" = "/usr/local/bin/npm" ]
}

@test "npm wrapper routes calls end-to-end (npm --version works)" {
  # Behavioral check: if the wrapper, sfw, and real npm are all wired up
  # correctly, a simple `npm --version` produces a version string. If any
  # link in the chain is broken, this fails.
  run /usr/local/bin/npm --version
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "npm wrapper does not strip .npmrc protections" {
  # End-to-end: with the wrapper interposing, malicious lifecycle scripts
  # are still blocked by .npmrc ignore-scripts=true. If the wrapper were
  # accidentally bypassing the user's config, this would fail.
  rm -f /tmp/marker-wrapper-postinstall
  cd /tmp && rm -rf wrapper-attack-test && mkdir wrapper-attack-test && cd wrapper-attack-test
  npm init -y >/dev/null 2>&1
  npm install /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/marker-postinstall ]
  rm -rf /tmp/wrapper-attack-test
}

@test "npm wrapper falls back gracefully when sfw is hidden" {
  # If sfw is somehow unavailable at runtime, the wrapper must warn and
  # pass through to real npm rather than break npm entirely. Locate sfw,
  # rename it temporarily, run wrapper, restore.
  sfw_path=$(command -v sfw 2>/dev/null) || skip "sfw not present"
  [ -x "$sfw_path" ] || skip "sfw at $sfw_path not executable"

  mv "$sfw_path" "${sfw_path}.bats-hidden"
  run timeout 10 /usr/local/bin/npm --version
  mv "${sfw_path}.bats-hidden" "$sfw_path"

  # Must NOT hang/loop (timeout = 124) and must NOT exit 127 from the
  # recursion guard. Should exit 0 (pass-through to real npm).
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
