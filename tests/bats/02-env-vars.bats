#!/usr/bin/env bats

load setup

setup() {
  load_profile
}

@test "env: NPM_CONFIG_IGNORE_SCRIPTS=true" {
  assert_env_equals NPM_CONFIG_IGNORE_SCRIPTS true
}

@test "env: NPM_CONFIG_AUDIT=true" {
  assert_env_equals NPM_CONFIG_AUDIT true
}

@test "env: NPM_CONFIG_SAVE_EXACT=true" {
  assert_env_equals NPM_CONFIG_SAVE_EXACT true
}

@test "env: NPM_CONFIG_FUND=false" {
  assert_env_equals NPM_CONFIG_FUND false
}

@test "env: UV_NO_SYSTEM_CONFIG is NOT set (would self-disable /etc/uv/uv.toml fallback)" {
  # Regression catcher. The role briefly set UV_NO_SYSTEM_CONFIG=1 as a
  # "block malicious /etc/uv/" defense, but the role itself deploys
  # /etc/uv/uv.toml as the sudo/non-deploying-user fallback. The env
  # var would make uv ignore that file in PAM-loaded shells — exactly
  # the contexts the fallback exists for.
  [ -z "$UV_NO_SYSTEM_CONFIG" ]
}

@test "env: NPM_CONFIG_MIN_RELEASE_AGE=2 (correct npm key; 48h gate expressed in days)" {
  # npm's config key is `min-release-age` (unit: days) → env NPM_CONFIG_MIN_RELEASE_AGE.
  if npm_warns_about 11.10.0; then skip "npm $(npm --version) warns about the key, so the role leaves it out"; fi
  # release_age_hours=48 → npm_minimum_release_age_days=2.
  assert_env_equals NPM_CONFIG_MIN_RELEASE_AGE 2
}

@test "env: NPM_CONFIG_MINIMUM_RELEASE_AGE is NOT emitted (npm rejects it as Unknown env config)" {
  # Regression catcher: the MINIMUM_ variant maps to npm's `minimum-release-age`,
  # which npm does not recognize — it warns "Unknown env config" and will hard-error
  # in a future npm major. The env-var age gate must use the real key.
  # NOTE: COMPOSER_NO_SCRIPTS test intentionally dropped here — that var is a
  # made-up name the role no longer emits; COMPOSER_SKIP_SCRIPTS is tested below.
  ! grep -q "NPM_CONFIG_MINIMUM_RELEASE_AGE" /etc/profile.d/supply-chain-hardening.sh
  ! grep -q "NPM_CONFIG_MINIMUM_RELEASE_AGE" /etc/environment
}

@test "env: GOSUMDB=sum.golang.org" {
  assert_env_equals GOSUMDB sum.golang.org
}

@test "env: GOPROXY set to official proxy" {
  assert_env_equals GOPROXY "https://proxy.golang.org,direct"
}

@test "env: GOFLAGS is not written by default (an explicit -mod=readonly makes go ignore vendor/)" {
  # goflags_mod defaults to "". MEASURED on go1.22.12 / go1.27.4: -mod=readonly
  # is go's own default without vendor/, and with vendor/ it makes go skip the
  # vendored copy. 05-go.bats builds a vendored module to prove the effect.
  # Counted, not `! grep`: bats does not fail a test on a negated command
  # unless it is the last line.
  [ "$(grep -c "^export GOFLAGS=" /etc/profile.d/supply-chain-hardening.sh)" = 0 ]
  [ "$(grep -c "^GOFLAGS=" /etc/environment)" = 0 ]
  [ -z "${GOFLAGS:-}" ]
}

@test "env: GOTOOLCHAIN=local" {
  assert_env_equals GOTOOLCHAIN local
}

@test "env: COMPOSER_SKIP_SCRIPTS enumerates post-install-cmd (belt-and-suspenders for php composer.phar callers)" {
  # The /usr/local/bin/composer wrapper is the primary protection; this
  # env var covers PAM-loaded shells that invoke composer via php
  # composer.phar (bypassing the wrapper). Composer 2.9+ honors it.
  # We assert against one representative event rather than the whole
  # 24-event list — the env var either contains the comma-separated list
  # or it doesn't, and asserting on the most-common event is a robust
  # sentinel that catches regression without locking in the exact text.
  [[ "$COMPOSER_SKIP_SCRIPTS" == *"post-install-cmd"* ]]
}

@test "env: COMPOSER_ALLOW_SUPERUSER is NOT exported host-wide (only the composer wrapper sets it)" {
  # Exported host-wide it switched off composer's root guard for every caller
  # that bypasses the wrapper. MEASURED (2.7.1, 2.11.2, outside a container): a
  # non-interactive root run without it disables plugins and runs `sudo -K`;
  # with it, a plugin the checkout's own allow-plugins enables ran as root.
  [ -z "${COMPOSER_ALLOW_SUPERUSER+x}" ] || { echo "COMPOSER_ALLOW_SUPERUSER=$COMPOSER_ALLOW_SUPERUSER is exported" >&2; return 1; }
  ! grep -qE '^[[:space:]]*(export[[:space:]]+)?COMPOSER_ALLOW_SUPERUSER=' /etc/profile.d/supply-chain-hardening.sh
  ! grep -qE '^[[:space:]]*COMPOSER_ALLOW_SUPERUSER=' /etc/environment
}

@test "the composer wrapper sets COMPOSER_ALLOW_SUPERUSER for its own run" {
  composer_path=$(command -v composer)
  grep -q 'supply-chain-harden' "$composer_path" || skip "composer is not wrapped"
  grep -qx 'export COMPOSER_ALLOW_SUPERUSER=1' "$composer_path"
}

@test "/etc/environment has NPM_CONFIG_IGNORE_SCRIPTS" {
  assert_file_contains /etc/environment "NPM_CONFIG_IGNORE_SCRIPTS=true"
}

@test "env: NPM_CONFIG_ALLOW_GIT=none in profile.d and /etc/environment unless the npm found warns about it (11.2.0 to 11.8.x)" {
  # allow-git=none is in the npmrc files too, but a redirected user config
  # (NPM_CONFIG_USERCONFIG, which actions/setup-node exports) skips ~/.npmrc.
  # npm 11.2.0 to 11.8.x warn `Unknown env config "allow-git"` on every command
  # when it is set (MEASURED), so the role leaves it out there. The npm on PATH
  # here is the one the role found at apply time.
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  if ! npm_warns_about 11.9.0; then
    assert_env_equals NPM_CONFIG_ALLOW_GIT none
    assert_file_contains /etc/environment '^NPM_CONFIG_ALLOW_GIT=none$'
  else
    [ -z "${NPM_CONFIG_ALLOW_GIT+set}" ]
    ! grep -q 'ALLOW_GIT' /etc/environment
    ! grep -q 'ALLOW_GIT' /etc/profile.d/supply-chain-hardening.sh
  fi
}

@test "/etc/environment has NPM_CONFIG_MIN_RELEASE_AGE (correct key, days unit)" {
  if npm_warns_about 11.10.0; then skip "npm $(npm --version) warns about the key, so the role leaves it out"; fi
  assert_file_contains /etc/environment "NPM_CONFIG_MIN_RELEASE_AGE=2"
}

@test "env: the composer publish-age gate is in seconds and blocks" {
  assert_env_equals COMPOSER_POLICY_COOLDOWN_PERIOD 172800
  assert_env_equals COMPOSER_POLICY_COOLDOWN_BLOCK 1
}

@test "env: the bundler publish-age gate is in days" {
  assert_env_equals BUNDLE_COOLDOWN 2
}

@test "env: the poetry publish-age gate is in days" {
  assert_env_equals POETRY_SOLVER_MIN_RELEASE_AGE 2
}

@test "/etc/environment has both publish-age gates" {
  assert_file_contains /etc/environment "COMPOSER_POLICY_COOLDOWN_PERIOD=172800"
  assert_file_contains /etc/environment "BUNDLE_COOLDOWN=2"
}

@test "/etc/environment has GOSUMDB" {
  assert_file_contains /etc/environment "GOSUMDB=sum.golang.org"
}

@test "/etc/profile.d script exists" {
  assert_file_exists /etc/profile.d/supply-chain-hardening.sh
}
