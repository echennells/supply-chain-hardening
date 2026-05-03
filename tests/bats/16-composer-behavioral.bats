#!/usr/bin/env bats
# Behavioral tests for Composer: verify scripts are actually blocked at runtime.

load setup

setup() {
  rm -f /tmp/marker-composer-script
  load_profile
}

@test "ATTACK: composer post-install-cmd script is blocked" {
  cd /tmp && rm -rf composer-attack-test && mkdir composer-attack-test && cd composer-attack-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  composer install --no-interaction 2>/dev/null || true
  [ ! -f /tmp/marker-composer-script ]
  rm -rf /tmp/composer-attack-test
}
