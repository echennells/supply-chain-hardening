#!/usr/bin/env bats
# Adversarial tests: Composer script execution blocking.
# Tests that COMPOSER_NO_SCRIPTS=1 and scripts-are-disabled prevent
# post-install-cmd from running.

load setup

setup() {
  load_profile
  rm -f /tmp/marker-composer-script
}

@test "ATTACK: Composer post-install-cmd is blocked by env var" {
  # COMPOSER_NO_SCRIPTS=1 should prevent all script execution
  [ "$COMPOSER_NO_SCRIPTS" = "1" ]
}

@test "ATTACK: Composer config has scripts-are-disabled" {
  assert_file_contains "$HOME/.config/composer/config.json" '"scripts-are-disabled": true'
}

@test "Composer config enforces HTTPS" {
  assert_file_contains "$HOME/.config/composer/config.json" '"secure-http": true'
}

@test "Composer config prefers dist (no VCS hooks)" {
  assert_file_contains "$HOME/.config/composer/config.json" '"preferred-install": "dist"'
}
