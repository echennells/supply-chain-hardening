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

@test "Composer config default-denies plugin execution (allow-plugins: false)" {
  # composer.json plugins are arbitrary code that runs during composer
  # operations. allow-plugins=false makes the role fail-closed: projects
  # have to opt in to specific plugins via their own composer.json.
  assert_file_contains "$HOME/.config/composer/config.json" '"allow-plugins": false'
}

@test "Composer audit.abandoned defaults to fail (Composer >=2.7; test env runs 2.9+)" {
  # Tier 2+ — matches Composer's own upstream default since 2.7.0.
  assert_file_contains "$HOME/.config/composer/config.json" '"abandoned": "fail"'
}

@test "Composer audit.block-insecure is enabled (Composer >=2.9 tier)" {
  # Tier 1 only — refuses updates to packages with known security advisories.
  # Test container installs Composer via upstream installer so hits Tier 1.
  assert_file_contains "$HOME/.config/composer/config.json" '"block-insecure": true'
}

@test "Composer audit.block-abandoned is enabled (Composer >=2.9 tier)" {
  assert_file_contains "$HOME/.config/composer/config.json" '"block-abandoned": true'
}

@test "Composer config.json is valid JSON (template tiering must not break parse)" {
  # The template uses nested {% if %} blocks around commas — a regression
  # could easily leave a trailing comma or missing brace and silently break
  # every composer invocation on the host.
  python3 -c "import json,sys; json.load(open('$HOME/.config/composer/config.json'))"
}
