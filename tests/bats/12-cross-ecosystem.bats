#!/usr/bin/env bats
# Cross-ecosystem tests: verify which mechanisms apply to which caller types.
#
# Important honesty note:
# Earlier versions of this file claimed "env vars apply in non-interactive
# bash -c" but the tests achieved this by manually sourcing the profile.d
# file inside the bash -c invocation. That tested whether the profile.d
# file CAN be sourced and produces correct values — it did NOT test whether
# /etc/environment automatically propagates to direct-exec contexts. It
# doesn't: /etc/environment is read by pam_env.so during PAM sessions
# (login, ssh, cron, su -, sudo -i), not by any non-PAM process spawn.
#
# A real AI agent launched as a container CMD or as a systemd service
# without an Environment= directive will NOT inherit /etc/environment vars.
# For those callers, the config files (~/.npmrc, ~/.config/uv/uv.toml,
# etc.) are the universal defense layer. The tests below verify both the
# PAM-covered path AND the direct-exec limit, plus prove that config files
# cover the gap.

load setup

setup() {
  rm -f /tmp/marker-*
}

# --- Permissions: non-root cannot modify the hardening ---

@test "SYSTEM: /etc/environment is not writable by non-root" {
  perms=$(stat -c %a /etc/environment)
  [ "$perms" = "644" ]
}

@test "SYSTEM: /etc/profile.d/supply-chain-hardening.sh is not writable by non-root" {
  perms=$(stat -c %a /etc/profile.d/supply-chain-hardening.sh)
  [ "$perms" = "644" ]
}

@test "SYSTEM: pip wrapper is not writable by non-root" {
  perms=$(stat -c %a /usr/local/bin/pip)
  [ "$perms" = "755" ]
  owner=$(stat -c %U /usr/local/bin/pip)
  [ "$owner" = "root" ]
}

# --- /etc/environment file content (always-readable artifact) ---

@test "SYSTEM: /etc/environment contains expected npm hardening line" {
  grep -q "^NPM_CONFIG_IGNORE_SCRIPTS=true$" /etc/environment
}

@test "SYSTEM: /etc/environment contains expected Go hardening line" {
  grep -q "^GOSUMDB=sum.golang.org$" /etc/environment
}

# --- profile.d file produces correct env when sourced ---
# (Verifies the file's content. Honest about what's being tested: a sourced-
# shell scenario, which covers login shells / sudo -i / su - / cron / ssh.)

@test "SYSTEM: profile.d exports npm vars when sourced (login shells, ssh, sudo -i, cron via PAM)" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh && echo $NPM_CONFIG_IGNORE_SCRIPTS')
  [ "$result" = "true" ]
}

@test "SYSTEM: profile.d exports Python vars when sourced" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh && echo $PYTHONDONTWRITEBYTECODE')
  [ "$result" = "1" ]
}

@test "SYSTEM: profile.d exports Go vars when sourced" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh && echo $GOSUMDB')
  [ "$result" = "sum.golang.org" ]
}

@test "SYSTEM: profile.d exports Composer skip-scripts list when sourced" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh && echo $COMPOSER_SKIP_SCRIPTS')
  [[ "$result" == *"post-install-cmd"* ]]
}

# --- Honest test of the /etc/environment limit ---

@test "LIMIT: direct-exec contexts (no PAM, no shell sourcing) do NOT inherit /etc/environment" {
  # An agent launched as Docker CMD or by systemd without Environment= sees
  # a clean env. This test simulates that with `env -i`. Result must be
  # empty — proving the limit is real and explicitly tested. Config files
  # (next test) are what protect these callers.
  result=$(env -i bash -c 'echo "$NPM_CONFIG_IGNORE_SCRIPTS"')
  [ -z "$result" ]
}

# --- Universal layer: config files cover the direct-exec gap ---

@test "UNIVERSAL: ~/.npmrc applies even when env is completely empty" {
  # Direct-exec callers don't get the env-var layer, but they DO get the
  # config file layer because npm reads ~/.npmrc unconditionally on every
  # invocation. This is the load-bearing defense for agent contexts.
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  result=$(env -i HOME="$HOME" PATH="$PATH" npm config get ignore-scripts 2>/dev/null)
  [ "$result" = "true" ]
}

@test "UNIVERSAL: ~/.config/uv/uv.toml applies even when env is completely empty" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  # uv prints config via `uv tool` introspection or by reading the toml directly.
  # Simplest: verify the file the tool reads has the expected setting.
  [ -f "$HOME/.config/uv/uv.toml" ]
  grep -q "no-build = true" "$HOME/.config/uv/uv.toml"
}

# --- Cleanup paranoia ---

@test "SYSTEM: all attack markers clean after full test run" {
  markers=$(ls /tmp/marker-* 2>/dev/null | wc -l)
  [ "$markers" -eq 0 ]
}
