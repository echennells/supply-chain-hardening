#!/usr/bin/env bats

load setup

@test "composer: secure-http true" {
  assert_file_contains "$HOME/.config/composer/config.json" "secure-http"
}

@test "composer: preferred-install dist" {
  assert_file_contains "$HOME/.config/composer/config.json" "dist"
}

@test "bundler: BUNDLE_DISABLE_EXEC_LOAD true" {
  assert_file_contains "$HOME/.bundle/config" 'BUNDLE_DISABLE_EXEC_LOAD: "true"'
}

@test "cargo: git-fetch-with-cli = true" {
  assert_file_contains "$HOME/.cargo/config.toml" "git-fetch-with-cli = true"
}

@test "npq aliases exist in profile.d" {
  assert_file_exists /etc/profile.d/npq-aliases.sh
}

@test "npq: npm alias routes through npq-hero" {
  assert_file_contains /etc/profile.d/npq-aliases.sh "alias npm='npq-hero'"
}

@test "npq: NPQ_DISABLE_AUTO_CONTINUE=true" {
  assert_file_contains /etc/profile.d/npq-aliases.sh "NPQ_DISABLE_AUTO_CONTINUE=true"
}
