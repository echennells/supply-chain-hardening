#!/usr/bin/env bats
# Behavioral tests for Composer.
#
# The previous "ATTACK: post-install-cmd is blocked" test was a tautology:
# the fixture had `"require": {}` and composer skips post-install-cmd
# dispatch entirely on empty-require installs. The marker never appeared
# regardless of hardening (verified empirically with `env -i HOME=/tmp/clean
# composer install` against the same fixture — still no marker). The fixture
# was rewritten to require a path-local package so post-install-cmd actually
# fires when nothing blocks it; the FIXTURE CONTROL test below verifies that
# property.
#
# The blocking assertion is skipped until the /usr/local/bin/composer
# wrapper is implemented (composer has no config-file or env-var way to
# block scripts host-wide — the only real primitives are --no-scripts CLI
# flag and COMPOSER_SKIP_SCRIPTS=<event,list> env var on composer 2.9+,
# neither suitable as an always-on host-wide protection without a wrapper).

load setup

setup() {
  rm -f /tmp/marker-composer-script
  load_profile
}

@test "FIXTURE CONTROL: composer-postinstall fixture fires a script hook on a wide-open install" {
  # Sanity-check the fixture itself. If composer would NOT fire any script
  # against this fixture even with no hardening, then any "is blocked"
  # test using this fixture is a tautology. The fixture declares
  # post-install-cmd, post-update-cmd, AND post-autoload-dump because
  # `composer install` with no lock transparently routes through update
  # (firing the latter two, not the former). Run with env -i + a clean
  # HOME so neither role env vars nor the role's per-user config affects
  # the result. /usr/local/bin/composer-real bypasses the wrapper too.
  # The marker SHOULD appear.
  [ -x /usr/local/bin/composer-real ] || skip "composer-real not present"
  cd /tmp && rm -rf composer-control-test && mkdir composer-control-test && cd composer-control-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  env -i HOME=/tmp/composer-control-test PATH=/usr/local/bin:/usr/bin:/bin \
    /usr/local/bin/composer-real install --no-interaction 2>/dev/null || true
  marker_present=$([ -f /tmp/marker-composer-script ] && echo "yes" || echo "no")
  rm -rf /tmp/composer-control-test
  rm -f /tmp/marker-composer-script
  [ "$marker_present" = "yes" ]
}

@test "ATTACK: composer post-install-cmd script is blocked" {
  # The /usr/local/bin/composer wrapper injects --no-scripts on every
  # invocation. The fixture above (FIXTURE CONTROL) proves the script
  # would fire absent hardening; this test proves the wrapper actually
  # blocks it. If the wrapper is ever bypassed, removed, or fails to
  # inject the flag, this test catches it.
  cd /tmp && rm -rf composer-attack-test && mkdir composer-attack-test && cd composer-attack-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  composer install --no-interaction 2>/dev/null || true
  marker_present=$([ -f /tmp/marker-composer-script ] && echo "yes" || echo "no")
  rm -rf /tmp/composer-attack-test
  rm -f /tmp/marker-composer-script
  [ "$marker_present" = "no" ]
}

@test "BYPASS VERIFICATION: composer-real + cleared COMPOSER_SKIP_SCRIPTS runs scripts (documented bypass works)" {
  # The role ships TWO layers of script blocking:
  #   1. /usr/local/bin/composer wrapper injects --no-scripts --no-plugins
  #   2. COMPOSER_SKIP_SCRIPTS=<events> in /etc/environment (catches
  #      `php composer.phar` callers and composer-real callers in
  #      PAM-loaded shells)
  # The documented bypass requires going around BOTH: invoke composer-real
  # AND clear the env var. Just `composer-real install` alone is still
  # blocked by layer 2 — which is intentional belt-and-suspenders, not a
  # bug. This test verifies the documented bypass actually works.
  [ -x /usr/local/bin/composer-real ] || skip "composer-real not present (composer_path_wrapper may be false)"
  cd /tmp && rm -rf composer-bypass-test && mkdir composer-bypass-test && cd composer-bypass-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  env -i HOME=/tmp/composer-bypass-test PATH=/usr/local/bin:/usr/bin:/bin \
    /usr/local/bin/composer-real install --no-interaction 2>/dev/null || true
  marker_present=$([ -f /tmp/marker-composer-script ] && echo "yes" || echo "no")
  rm -rf /tmp/composer-bypass-test
  rm -f /tmp/marker-composer-script
  [ "$marker_present" = "yes" ]
}

@test "LAYERED DEFENSE: composer-real alone (env-var layer still active) is still blocked" {
  # Counterpart to BYPASS VERIFICATION above. Verifies the belt-and-
  # suspenders env-var layer actually does what it claims — catches
  # composer-real invocations that don't explicitly clear the env. If
  # someone removed COMPOSER_SKIP_SCRIPTS from /etc/environment or
  # /etc/profile.d/, this test would flip from blocked→not-blocked and
  # catch the regression.
  [ -x /usr/local/bin/composer-real ] || skip "composer-real not present"
  cd /tmp && rm -rf composer-real-test && mkdir composer-real-test && cd composer-real-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  /usr/local/bin/composer-real install --no-interaction 2>/dev/null || true
  marker_present=$([ -f /tmp/marker-composer-script ] && echo "yes" || echo "no")
  rm -rf /tmp/composer-real-test
  rm -f /tmp/marker-composer-script
  [ "$marker_present" = "no" ]
}

# --- publish-age gate ---------------------------------------------------------
# These call the real binary with a scratch COMPOSER_HOME: the deployed wrapper
# pins the 48h window, and "the newest release is older than 48h" is true of most
# packages most days, so only a window far wider than any release cadence can
# tell an enforcing composer from one that ignores the key.

cooldown_composer() {
  local real; real=$(command -v composer-real || command -v composer) || return 1
  local v; v=$("$real" --version --no-ansi 2>/dev/null | sed -nE 's/^Composer (version )?([0-9]+\.[0-9]+\.[0-9]+).*$/\2/p' | head -1)
  [ -n "$v" ] && [ "$(printf '2.11.0\n%s\n' "$v" | sort -V | head -1)" = "2.11.0" ] || return 1
  printf '%s' "$real"
}

# resolve <project-config-json-or-empty> [env assignments...] -> the constraint written
cooldown_resolve() {
  local cfg="$1"; shift
  local d; d=$(mktemp -d)
  mkdir -p "$d/home" "$d/p"
  echo '{}' > "$d/home/config.json"
  printf '{"name":"t/t","require":{}%s}\n' "${cfg:+,\"config\":$cfg}" > "$d/p/composer.json"
  ( cd "$d/p" && env -u COMPOSER_POLICY_COOLDOWN_PERIOD -u COMPOSER_POLICY_COOLDOWN_BLOCK \
      COMPOSER_HOME="$d/home" COMPOSER_NO_INTERACTION=1 "$@" \
      "$COOLDOWN_BIN" require monolog/monolog --no-install --no-plugins --no-scripts >/dev/null 2>&1 )
  grep -oE '"monolog/monolog": *"[^"]+"' "$d/p/composer.json" | cut -d'"' -f4
  rm -rf "$d"
}

@test "BEHAVIORAL: the composer env gate withholds the newest release (control takes it)" {
  COOLDOWN_BIN=$(cooldown_composer) || skip "composer < 2.11 has no cooldown"
  local control gated
  control=$(cooldown_resolve '')
  [ -n "$control" ] || skip "packagist unreachable: the control resolved nothing"
  gated=$(cooldown_resolve '' COMPOSER_POLICY_COOLDOWN_PERIOD=81648000)
  [ -n "$gated" ]
  [ "$gated" != "$control" ]
}

@test "BEHAVIORAL: the env var outranks a repo's period null and block false" {
  COOLDOWN_BIN=$(cooldown_composer) || skip "composer < 2.11 has no cooldown"
  local control a b
  control=$(cooldown_resolve '')
  [ -n "$control" ] || skip "packagist unreachable: the control resolved nothing"
  a=$(cooldown_resolve '{"policy":{"cooldown":{"period":null}}}' COMPOSER_POLICY_COOLDOWN_PERIOD=81648000)
  b=$(cooldown_resolve '{"policy":{"cooldown":{"period":81648000,"block":false}}}' COMPOSER_POLICY_COOLDOWN_BLOCK=1)
  [ "$a" != "$control" ]
  [ "$b" != "$control" ]
}

@test "KNOWN GAP: a repo's ignore list outranks COMPOSER_POLICY_COOLDOWN_PERIOD" {
  # This documents the bypass; supply-chain-verify reports it. If this test starts
  # failing, composer has closed the gap and docs/limitations.md should say so.
  COOLDOWN_BIN=$(cooldown_composer) || skip "composer < 2.11 has no cooldown"
  local control got
  control=$(cooldown_resolve '')
  [ -n "$control" ] || skip "packagist unreachable: the control resolved nothing"
  got=$(cooldown_resolve '{"policy":{"cooldown":{"ignore":["*"]}}}' COMPOSER_POLICY_COOLDOWN_PERIOD=81648000)
  [ "$got" = "$control" ]
}
