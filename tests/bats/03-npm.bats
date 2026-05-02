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

@test "npm: allow-git config is set to none" {
  # allow-git=none is set in .npmrc. Behavioral blocking requires npm 11+.
  # This test verifies the config is in place.
  result=$(npm config get allow-git)
  [ "$result" = "none" ]
}

@test "npm: config get ignore-scripts returns true" {
  result=$(npm config get ignore-scripts)
  [ "$result" = "true" ]
}
