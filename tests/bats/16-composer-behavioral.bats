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
