#!/usr/bin/env bats
# Adversarial tests for Yarn: verify lifecycle scripts are blocked.

load setup

setup() {
  rm -f /tmp/marker-postinstall /tmp/marker-ssh-exfil /tmp/marker-preinstall
}

@test "ATTACK: yarn postinstall is blocked" {
  cd /tmp && rm -rf yarn-attack-test && mkdir yarn-attack-test && cd yarn-attack-test
  echo '{"name":"yarn-test","packageManager":"yarn@4.9.1"}' > package.json
  yarn install >/dev/null 2>&1 || true
  yarn add /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/marker-postinstall ]
  rm -rf /tmp/yarn-attack-test
}

@test "ATTACK: yarn SSH key exfiltration is blocked" {
  cd /tmp && rm -rf yarn-attack-test && mkdir yarn-attack-test && cd yarn-attack-test
  echo '{"name":"yarn-test","packageManager":"yarn@4.9.1"}' > package.json
  yarn install >/dev/null 2>&1 || true
  yarn add /opt/test-fixtures/npm-read-ssh-keys 2>/dev/null || true
  [ ! -f /tmp/marker-ssh-exfil ]
  rm -rf /tmp/yarn-attack-test
}

@test "ATTACK: yarn preinstall hook is blocked" {
  cd /tmp && rm -rf yarn-attack-test && mkdir yarn-attack-test && cd yarn-attack-test
  echo '{"name":"yarn-test","packageManager":"yarn@4.9.1"}' > package.json
  yarn install >/dev/null 2>&1 || true
  yarn add /opt/test-fixtures/npm-preinstall-script 2>/dev/null || true
  [ ! -f /tmp/marker-preinstall ]
  rm -rf /tmp/yarn-attack-test
}
