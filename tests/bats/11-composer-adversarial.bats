#!/usr/bin/env bats
# Adversarial tests: Composer config-file hardening assertions.
#
# NOTE: composer has no host-wide config-file or env-var mechanism to
# disable script execution. The previous "blocked by env var" and
# "scripts-are-disabled" tests asserted presence of strings that composer
# ignores entirely (COMPOSER_NO_SCRIPTS is not a real composer env var;
# "scripts-are-disabled" is not in composer's JSON schema). Those tests
# passed but proved nothing about runtime behavior. See README Limitations
# for the unmitigated composer-scripts attack class and the planned wrapper.

load setup

setup() {
  load_profile
  rm -f /tmp/marker-composer-script
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

@test "composer wrapper deployed at the discovered composer path" {
  composer_path=$(command -v composer)
  [ -n "$composer_path" ]
  grep -q "supply-chain-hardening" "$composer_path"
}

@test "composer-real backup exists next to the wrapper" {
  composer_path=$(command -v composer)
  [ -f "${composer_path}-real" ]
  [ -x "${composer_path}-real" ]
}

@test "composer wrapper injects --no-scripts on every invocation" {
  composer_path=$(command -v composer)
  grep -q -- "--no-scripts" "$composer_path"
}

@test "composer wrapper injects --no-plugins on every invocation (default composer_allow_plugins=false)" {
  # The wrapper is now authoritative on composer_allow_plugins (see
  # tests/bats/34-composer-wrapper-tier-rendering.bats for the
  # render-both-values test). This integration test only exercises the
  # deployed wrapper, which reflects the default false → flag present.
  # If a user flips composer_allow_plugins=true in their inventory, the
  # wrapper omits --no-plugins by design — this test would then fail and
  # the user should set BATS_SKIP_PLUGIN_TEST=1 or rely on the
  # tier-rendering test instead.
  composer_path=$(command -v composer)
  grep -q -- "--no-plugins" "$composer_path"
}

@test "composer wrapper has recursion safety guard" {
  composer_path=$(command -v composer)
  grep -q "refusing to recurse" "$composer_path"
}

@test "which composer resolves to the wrapper (not bypassed by PATH lookup)" {
  resolved=$(command -v composer)
  grep -q "supply-chain-hardening" "$resolved"
}

@test "composer --version still works through the wrapper (read-only commands not broken)" {
  # --no-scripts and --no-plugins are no-ops for --version. If the wrapper
  # somehow breaks this, every CI lookup of composer's version fails.
  run composer --version
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "composer"
}

@test "Composer config.json is valid JSON (template tiering must not break parse)" {
  # The template uses nested {% if %} blocks around commas — a regression
  # could easily leave a trailing comma or missing brace and silently break
  # every composer invocation on the host.
  python3 -c "import json,sys; json.load(open('$HOME/.config/composer/config.json'))"
}
