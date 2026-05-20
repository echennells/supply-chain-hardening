#!/usr/bin/env bats
# Tests for the npm PATH wrapper (npm_path_wrapper: true).
#
# Background: shell aliases for npq only fire in interactive shells, leaving
# scripts, agents, package.json scripts, sudo, and CI without reputation or
# threat-intel coverage. The PATH wrapper sits at /usr/local/bin/npm and
# routes registry-touching subcommands (install/ci/update/audit/…) through
# Socket Firewall (non-interactive) or npq + sfw (interactive). Read-only
# and local subcommands (config/version/ls/run/help/…) bypass both — sfw's
# "no fetch attempts" banner corrupts captured stdout for `npm config get`,
# and npq would error on non-install subcommands. The test container builds
# with this feature on.

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

@test "npm config get produces clean output (read-only subcommand bypasses wrapper chatter)" {
  # Regression catcher for the exact bug that drove the subcommand allowlist:
  # before the allowlist, sfw's "no fetch attempts" banner prepended to every
  # `npm config get` call, breaking direct string comparisons in 03-npm.bats
  # and elsewhere. If someone narrows the bypass list to exclude `config`,
  # `npm config get ignore-scripts` will return something like
  # "[supply-chain-hardening] ... true" instead of just "true" and this fails.
  result=$(npm config get ignore-scripts 2>/dev/null)
  [ "$result" = "true" ]
}

@test "npm --version output is only a version number" {
  # The bypass path must not prepend warnings/banners to stdout. Anything
  # other than a bare semver-shaped string breaks scripts and CI that parse
  # `npm --version`. Catches a regression where someone moves `--version`
  # routing through sfw or adds wrapper output before the exec.
  result=$(npm --version 2>/dev/null)
  echo "$result" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'
}

@test "npm wrapper allowlist contains registry-fetching subcommands" {
  # Regression catcher: if someone narrows the allowlist, install/ci/update
  # would silently bypass sfw and lose threat-intel coverage. These four
  # subcommands MUST stay routed.
  assert_file_contains /usr/local/bin/npm "install"
  assert_file_contains /usr/local/bin/npm "ci"
  assert_file_contains /usr/local/bin/npm "update"
  assert_file_contains /usr/local/bin/npm "audit"
}

@test "npm install subcommand actually attempts to route through sfw" {
  # Behavioral check that the allowlist works in the OTHER direction: install
  # MUST go through sfw, not bypass to real npm. We verify by hiding sfw and
  # running an install — the wrapper's fallback path emits a "sfw not found"
  # warning. If the warning is absent, the install bypassed sfw entirely
  # (allowlist regression in the wrong direction).
  sfw_path=$(command -v sfw 2>/dev/null) || skip "sfw not present"

  mv "$sfw_path" "${sfw_path}.bats-hidden"
  cd /tmp && rm -rf wrapper-route-test && mkdir wrapper-route-test && cd wrapper-route-test
  npm init -y >/dev/null 2>&1
  output=$(npm install /opt/test-fixtures/npm-postinstall-pkg 2>&1 || true)
  mv "${sfw_path}.bats-hidden" "$sfw_path"
  rm -rf /tmp/wrapper-route-test

  echo "$output" | grep -q "sfw not found"
}

@test "direct /usr/bin/npm call still blocks scripts (config-layer coverage)" {
  # When a caller bypasses the /usr/local/bin/npm wrapper by invoking
  # the underlying npm binary directly (via its absolute path, or via
  # PATH ordering that puts /usr/bin first), they skip sfw and the
  # npq alias — but ~/.npmrc, /etc/npmrc, and NPM_CONFIG_* env vars
  # still apply. The config-layer ignore-scripts protection MUST hold
  # even when the wrapper isn't in the path.
  #
  # This is what an AI agent's subprocess.run(['/usr/bin/npm', ...])
  # call looks like, or what a Dockerfile RUN that uses the npm path
  # baked into a base image looks like.
  real_npm=$(grep -E "^REAL_NPM=" /usr/local/bin/npm | head -1 | sed "s/REAL_NPM=//; s/'//g")
  [ -n "$real_npm" ] || skip "could not resolve REAL_NPM from wrapper"
  [ -x "$real_npm" ] || skip "REAL_NPM at $real_npm is not executable"
  [ "$real_npm" != "/usr/local/bin/npm" ]  # would be a recursion bug

  rm -f /tmp/postinstall-marker
  cd /tmp && rm -rf direct-npm-test && mkdir direct-npm-test && cd direct-npm-test
  "$real_npm" init -y >/dev/null 2>&1
  "$real_npm" install /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true

  # Wrapper layer is gone, but config layer still catches it.
  [ ! -f /tmp/postinstall-marker ]

  rm -rf /tmp/direct-npm-test
  rm -f /tmp/postinstall-marker
}

@test "LIMIT: PATH-prepended user shim CAN bypass the npm wrapper (documented)" {
  # A non-root user who prepends a directory to PATH containing their
  # own `npm` script can shadow /usr/local/bin/npm. This is a real
  # limitation, not a bug — the role can't prevent users from
  # modifying their own PATH. Documented in README; this test pins
  # the behavior so a future "fix" attempt doesn't break the OTHER
  # use case (legitimate per-user npm wrappers).
  #
  # Setup: create a fake npm in a temp dir; prepend it to PATH;
  # verify `which npm` resolves to it (i.e., the bypass succeeds).
  shim_dir=$(mktemp -d)
  cat > "$shim_dir/npm" <<'EOF'
#!/bin/sh
echo "SHIMMED_NPM_RAN"
exit 42
EOF
  chmod +x "$shim_dir/npm"

  # PATH-prepend the shim dir; `which npm` should find OUR fake first.
  resolved=$(PATH="$shim_dir:$PATH" command -v npm)
  rm -rf "$shim_dir"

  [ "$resolved" = "$shim_dir/npm" ]
}

@test "npm wrapper survives self-upgrade (npm install -g npm)" {
  # The role-deployed wrapper at /usr/local/bin/npm is a shell script
  # owned by root. `npm install -g npm` updates the npm package in
  # node's global prefix (usually /usr/lib/node_modules/npm via the
  # nodesource installer) and refreshes symlinks under that prefix's
  # bin directory — typically /usr/bin, NOT /usr/local/bin. The
  # wrapper's location at /usr/local/bin/npm is upstream of npm's
  # symlink scope, so it should survive. But the protection depends
  # on PATH order AND on /usr/local not being npm's prefix. This test
  # locks that invariant: if a future Node distribution changes the
  # global prefix to /usr/local (or someone reconfigures npm), the
  # wrapper would be silently clobbered on the next `npm i -g npm`.
  #
  # Captures the wrapper's content hash before and after a self-upgrade
  # attempt. Hash MUST match — otherwise the wrapper has been replaced
  # by the upgraded npm's own bin entry, and our hardening surface is
  # silently gone.
  before=$(md5sum /usr/local/bin/npm | awk '{print $1}')

  # Use a non-destructive form: ask npm to recompute the dependency
  # tree but don't actually upgrade itself globally. Two reasons:
  #   1. Actually upgrading npm in the test container risks contaminating
  #      every test that runs after this one.
  #   2. We can prove the invariant (npm's self-modify path doesn't
  #      touch /usr/local/bin) without actually moving npm. If `npm i
  #      -g npm --dry-run` reports that /usr/local/bin/npm is in its
  #      modification scope, that's the bug we want to catch.
  output=$(npm install -g npm --dry-run 2>&1 || true)

  after=$(md5sum /usr/local/bin/npm | awk '{print $1}')

  [ "$before" = "$after" ]

  # Belt-and-suspenders: if npm's dry-run output mentions /usr/local/bin/npm
  # as a target, that's a future risk even if the file wasn't actually
  # touched on this run.
  if echo "$output" | grep -q "/usr/local/bin/npm"; then
    echo "WARNING: npm's self-upgrade scope includes /usr/local/bin/npm — wrapper may not survive a real upgrade" >&2
    echo "$output" | grep "/usr/local/bin/npm" >&2
    return 1
  fi
}
