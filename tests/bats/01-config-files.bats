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

@test "uv.toml: index-strategy first-index (anti-dep-confusion)" {
  assert_file_contains "$HOME/.config/uv/uv.toml" 'index-strategy = "first-index"'
}

@test "uv.toml: allow-insecure-host explicit (default empty = no TLS bypass)" {
  assert_file_contains "$HOME/.config/uv/uv.toml" "allow-insecure-host"
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

@test "pnpm-rc.j2 template: allowlist branch emits ignore-scripts=false (regression: don't let /etc/npmrc win silently)" {
  # When pnpm_built_dependencies is non-empty, the user rc switches to
  # only-built-dependencies semantics and MUST explicitly set
  # ignore-scripts=false. Otherwise /etc/npmrc's ignore-scripts=true
  # wins via pnpm's per-key config merge and silently blocks all build
  # scripts — including allowlisted ones. We can't easily test the
  # non-default vars path end-to-end, so assert against the template
  # source: the override line must be present in the allowlist branch.
  local template="$ROLE_DIR/templates/pnpm-rc.j2"
  assert_file_contains "$template" "ignore-scripts=false"
}

# pnpm 11+ YAML config — required because pnpm 11 stopped reading ini-format
# rc files, ~/.npmrc, /etc/npmrc, and NPM_CONFIG_* env vars for non-auth
# settings. Without this file, pnpm 11 has zero protection from the role.
@test "pnpm config.yaml: ignoreScripts true (pnpm 11+ blocks project scripts)" {
  assert_file_contains "$HOME/.config/pnpm/config.yaml" "ignoreScripts: true"
}

@test "pnpm config.yaml: minimumReleaseAge set (pnpm 11+ age gate)" {
  assert_file_contains "$HOME/.config/pnpm/config.yaml" "minimumReleaseAge:"
}

@test "pnpm config.yaml: minimumReleaseAgeStrict true (fail loud not silent fallback)" {
  assert_file_contains "$HOME/.config/pnpm/config.yaml" "minimumReleaseAgeStrict: true"
}

@test "pnpm config.yaml: blockExoticSubdeps true (pnpm 11+ blocks tarball/git/http subdeps)" {
  assert_file_contains "$HOME/.config/pnpm/config.yaml" "blockExoticSubdeps: true"
}

# yarn
@test "yarnrc: enableScripts false" {
  assert_file_contains "$HOME/.yarnrc.yml" "enableScripts: false"
}

@test "yarnrc: enableImmutableInstalls true (lockfile-change refusal)" {
  assert_file_contains "$HOME/.yarnrc.yml" "enableImmutableInstalls: true"
}

@test "yarnrc: enableImmutableCache true (prevent cache mutation during install)" {
  assert_file_contains "$HOME/.yarnrc.yml" "enableImmutableCache: true"
}

@test "yarnrc: checksumBehavior throw (error on hash mismatch)" {
  assert_file_contains "$HOME/.yarnrc.yml" "checksumBehavior: throw"
}

@test "yarnrc: approvedGitRepositories present (allowlist for git deps; empty = block all)" {
  assert_file_contains "$HOME/.yarnrc.yml" "approvedGitRepositories"
}

@test "yarnrc: unsafeHttpWhitelist present (empty = HTTPS-only enforcement)" {
  assert_file_contains "$HOME/.yarnrc.yml" "unsafeHttpWhitelist"
}

# bun
@test "bunfig: lifecycleScripts = false" {
  assert_file_contains "$HOME/.bunfig.toml" "lifecycleScripts = false"
}

@test "bunfig: exact = true" {
  assert_file_contains "$HOME/.bunfig.toml" "exact = true"
}

@test "bunfig: frozenLockfile = true (refuse install on lockfile divergence)" {
  assert_file_contains "$HOME/.bunfig.toml" "frozenLockfile = true"
}

@test "bunfig: auto = disable (block runtime auto-install foot-gun)" {
  assert_file_contains "$HOME/.bunfig.toml" 'auto = "disable"'
}

# cargo
@test "cargo config exists" {
  assert_file_exists "$HOME/.cargo/config.toml"
}

@test "cargo config: check-revoke = true" {
  assert_file_contains "$HOME/.cargo/config.toml" "check-revoke = true"
}

# bundler
@test "bundler: BUNDLE_FROZEN true" {
  assert_file_contains "$HOME/.bundle/config" 'BUNDLE_FROZEN: "true"'
}

@test "bundler: BUNDLE_DEPLOYMENT true" {
  assert_file_contains "$HOME/.bundle/config" 'BUNDLE_DEPLOYMENT: "true"'
}

# system-wide /etc fallbacks (close the sudo / other-user gap where $HOME
# flips and the per-user config above isn't found)

@test "/etc/npmrc: ignore-scripts=true (sudo-safe npm hardening)" {
  assert_file_contains "/etc/npmrc" "ignore-scripts=true"
}

@test "/etc/npmrc: min-release-age set (sudo-safe npm age gate)" {
  assert_file_contains "/etc/npmrc" "min-release-age="
}

@test "/etc/npmrc: pnpm keys present (sudo-safe pnpm via shared file)" {
  # pnpm's resolution chain includes /etc/npmrc. Verifying pnpm-specific
  # keys here confirms both tools are covered by one file.
  assert_file_contains "/etc/npmrc" "minimum-release-age-strict="
  assert_file_contains "/etc/npmrc" "block-exotic-subdeps=true"
}

@test "/etc/yarnrc.yml: enableScripts false (sudo-safe yarn hardening)" {
  assert_file_contains "/etc/yarnrc.yml" "enableScripts: false"
}

@test "/etc/pip.conf: only-binary=:all: (sudo-safe pip wheels-only)" {
  assert_file_contains "/etc/pip.conf" "only-binary = :all:"
}

@test "/etc/uv/uv.toml: exclude-newer set (sudo-safe uv age gate)" {
  assert_file_contains "/etc/uv/uv.toml" "exclude-newer"
}

@test "/etc/uv/uv.toml: no-build = true (sudo-safe uv wheels-only)" {
  assert_file_contains "/etc/uv/uv.toml" "no-build = true"
}
