#!/usr/bin/env bats

load setup

# npm
@test "npmrc: ignore-scripts=true" {
  assert_file_contains "$HOME/.npmrc" "ignore-scripts=true"
}

@test "npmrc: allow-git=none" {
  assert_file_contains "$HOME/.npmrc" "allow-git=none"
}

@test "npmrc: min-release-age set" {
  assert_file_contains "$HOME/.npmrc" "min-release-age="
}

@test "npmrc: save-exact=true" {
  assert_file_contains "$HOME/.npmrc" "save-exact=true"
}

# uv
@test "uv.toml: exclude-newer set" {
  assert_file_contains "$HOME/.config/uv/uv.toml" "exclude-newer"
}

@test "uv.toml: no-build = true" {
  assert_file_contains "$HOME/.config/uv/uv.toml" "no-build = true"
}

@test "uv.toml: verify-hashes = true" {
  assert_file_contains "$HOME/.config/uv/uv.toml" "verify-hashes = true"
}

# pip fallback
@test "pip.conf: only-binary = :all:" {
  assert_file_contains "$HOME/.config/pip/pip.conf" "only-binary = :all:"
}

# pnpm
@test "pnpm rc: ignore-scripts=true" {
  assert_file_contains "$HOME/.config/pnpm/rc" "ignore-scripts=true"
}

@test "pnpm rc: block-exotic-subdeps=true" {
  assert_file_contains "$HOME/.config/pnpm/rc" "block-exotic-subdeps=true"
}

# yarn
@test "yarnrc: enableScripts false" {
  assert_file_contains "$HOME/.yarnrc.yml" "enableScripts: false"
}

# bun
@test "bunfig: lifecycleScripts = false" {
  assert_file_contains "$HOME/.bunfig.toml" "lifecycleScripts = false"
}

@test "bunfig: exact = true" {
  assert_file_contains "$HOME/.bunfig.toml" "exact = true"
}

# cargo
@test "cargo config exists" {
  assert_file_exists "$HOME/.cargo/config.toml"
}

@test "cargo config: check-revoke = true" {
  assert_file_contains "$HOME/.cargo/config.toml" "check-revoke = true"
}

# composer
@test "composer: scripts-are-disabled" {
  assert_file_contains "$HOME/.config/composer/config.json" "scripts-are-disabled"
}

# bundler
@test "bundler: BUNDLE_FROZEN true" {
  assert_file_contains "$HOME/.bundle/config" 'BUNDLE_FROZEN: "true"'
}

@test "bundler: BUNDLE_DEPLOYMENT true" {
  assert_file_contains "$HOME/.bundle/config" 'BUNDLE_DEPLOYMENT: "true"'
}
