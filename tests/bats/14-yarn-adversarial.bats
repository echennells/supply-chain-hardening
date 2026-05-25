#!/usr/bin/env bats
# Adversarial tests for Yarn: verify lifecycle scripts are blocked.
#
# The packageManager field in package.json tells corepack which yarn
# version to download/use for the project. Previously these tests
# hardcoded "yarn@4.9.1", which made matrix-mode coverage fake (corepack
# would download 4.9.1 regardless of what the matrix switcher activated).
# Now each test queries the currently-active yarn version and writes
# that into packageManager — so matrix runs actually exercise the
# matrix's yarn version, and the single-version test harness still works
# (it falls back to a known stable version when yarn isn't yet active).

load setup

setup() {
  rm -f /tmp/marker-postinstall /tmp/marker-ssh-exfil /tmp/marker-preinstall
}

# Helper: write a package.json that pins corepack to whatever yarn is
# currently active on PATH. Falls back to 4.9.1 if yarn isn't queryable
# yet (corepack-enabled but no yarn activated — what the single-version
# test container looks like before first yarn invocation).
write_yarn_package_json() {
  local yarn_v
  yarn_v=$(yarn --version 2>/dev/null || echo "4.9.1")
  printf '{"name":"yarn-test","packageManager":"yarn@%s"}\n' "$yarn_v" > package.json
}

@test "ATTACK: yarn postinstall is blocked" {
  cd /tmp && rm -rf yarn-attack-test && mkdir yarn-attack-test && cd yarn-attack-test
  write_yarn_package_json
  yarn install >/dev/null 2>&1 || true
  yarn add /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/marker-postinstall ]
  rm -rf /tmp/yarn-attack-test
}

@test "ATTACK: yarn SSH key exfiltration is blocked" {
  cd /tmp && rm -rf yarn-attack-test && mkdir yarn-attack-test && cd yarn-attack-test
  write_yarn_package_json
  yarn install >/dev/null 2>&1 || true
  yarn add /opt/test-fixtures/npm-read-ssh-keys 2>/dev/null || true
  [ ! -f /tmp/marker-ssh-exfil ]
  rm -rf /tmp/yarn-attack-test
}

@test "ATTACK: yarn preinstall hook is blocked" {
  cd /tmp && rm -rf yarn-attack-test && mkdir yarn-attack-test && cd yarn-attack-test
  write_yarn_package_json
  yarn install >/dev/null 2>&1 || true
  yarn add /opt/test-fixtures/npm-preinstall-script 2>/dev/null || true
  [ ! -f /tmp/marker-preinstall ]
  rm -rf /tmp/yarn-attack-test
}
