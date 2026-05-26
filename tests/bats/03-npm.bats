#!/usr/bin/env bats

load setup

@test "npm: ignore-scripts blocks postinstall" {
  rm -f /tmp/postinstall-marker
  cd /tmp && mkdir -p npm-script-test && cd npm-script-test
  npm init -y >/dev/null 2>&1
  npm install /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/postinstall-marker ]
  rm -rf /tmp/npm-script-test
}

@test "npm: .npmrc contains allow-git=none (file-content check)" {
  # File-content layer only. `npm config get allow-git` returns the literal
  # value from .npmrc regardless of whether npm honors the key — so a test
  # asserting "config get returns 'none'" passes whether the key is real
  # (npm >= 11) or made up. allow-git IS documented and enforced in
  # npm >= 11 per https://docs.npmjs.com/cli/v11/using-npm/config, but the
  # config-get-roundtrip pattern is the same shape the role hit with the
  # made-up COMPOSER_NO_SCRIPTS env var (test passed; no protection). The
  # behavioral check below tests enforcement; this one only tests the
  # file got written.
  result=$(npm config get allow-git)
  [ "$result" = "none" ]
}

@test "npm: allow-git=none blocks git deps behaviorally (npm >=11 only)" {
  # Behavioral verification of allow-git enforcement. Documented in
  # npm v11 config reference: allow-git=none refuses git-URL dependencies.
  # On npm <11, this test skips because the key is silently inert there.
  npm_major=$(npm --version 2>/dev/null | sed -nE 's/^([0-9]+)\..*/\1/p' | head -1)
  [[ "$npm_major" =~ ^[0-9]+$ ]] || skip "couldn't parse npm major version"
  [[ "$npm_major" -ge 11 ]] || skip "allow-git enforcement requires npm >=11 (got: $(npm --version 2>/dev/null))"

  # Try installing from a git URL that won't resolve — if npm honors
  # allow-git=none it refuses BEFORE attempting any network fetch.
  # If npm doesn't honor (silently ignored), we'd see DNS-resolution
  # errors (ENOTFOUND / getaddrinfo) because npm would attempt the fetch.
  # Distinguishing these two failure modes is what makes this a real
  # behavioral test rather than a config-get-roundtrip.
  cd /tmp && rm -rf allow-git-test && mkdir allow-git-test && cd allow-git-test
  npm init -y >/dev/null 2>&1
  result=$(npm install "git+https://does-not-resolve.invalid/x.git" 2>&1 || true)
  rm -rf /tmp/allow-git-test

  if echo "$result" | grep -qiE "ENOTFOUND|ENETUNREACH|getaddrinfo|could not resolve"; then
    echo "FAIL: npm attempted DNS for the bogus git URL — allow-git=none NOT enforced" >&2
    echo "--- npm output ---" >&2
    echo "$result" >&2
    return 1
  fi
}

@test "npm: config get ignore-scripts returns true" {
  result=$(npm config get ignore-scripts)
  [ "$result" = "true" ]
}
