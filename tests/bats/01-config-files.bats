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

@test "pip.conf: template wiring intact (pip_only_binary variable controls behavior)" {
  # Regression catcher: pip.conf must be template-driven, not hardcoded.
  # The trade-off comment is only present in the template-rendered version.
  # If this disappears, someone has reverted to a hardcoded copy: task and
  # the pip_only_binary default variable is no longer actually controlling
  # anything (silent contract violation with defaults/main.yml).
  assert_file_contains "$HOME/.config/pip/pip.conf" "Set pip_only_binary: false to disable"
}

# pnpm
@test "pnpm rc: ignore-scripts=true" {
  assert_file_contains "$HOME/.config/pnpm/rc" "ignore-scripts=true"
}

@test "pnpm rc: block-exotic-subdeps=true" {
  assert_file_contains "$HOME/.config/pnpm/rc" "block-exotic-subdeps=true"
}

@test "pnpm rc: minimum-release-age-strict=true" {
  # Without strict mode, pnpm can silently fall back to whatever version is
  # available when no candidate satisfies the age gate — defeating the gate.
  # Regression catcher: if anyone reverts the strict flag, the install would
  # appear to honor the age but actually permit fresh versions.
  assert_file_contains "$HOME/.config/pnpm/rc" "minimum-release-age-strict=true"
}

@test "pnpm rc: template wiring (catches revert to hardcoded copy)" {
  # The rc is template-driven so the new variables (built_dependencies,
  # release_age_exclude) actually take effect. If someone reverts to the old
  # hardcoded copy:-based deployment, neither variable would apply.
  # The template emits an explanatory comment that the hardcoded version
  # didn't have — its presence proves the template is in use.
  assert_file_contains "$HOME/.config/pnpm/rc" "Explicit build-script allowlist\|equivalent default-deny via the"
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
