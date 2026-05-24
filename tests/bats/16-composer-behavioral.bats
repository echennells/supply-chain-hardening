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

@test "FIXTURE CONTROL: composer-postinstall fixture fires post-install-cmd on a wide-open install" {
  # Sanity-check the fixture itself. If composer would NOT fire
  # post-install-cmd against this fixture even with no hardening, then any
  # "is blocked" test using this fixture is a tautology. Run with env -i +
  # a clean HOME so neither role env vars nor the role's per-user config
  # affects the result. The marker SHOULD appear.
  cd /tmp && rm -rf composer-control-test && mkdir composer-control-test && cd composer-control-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  env -i HOME=/tmp/composer-control-test PATH=/usr/local/bin:/usr/bin:/bin \
    composer install --no-interaction 2>/dev/null || true
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

@test "BYPASS VERIFICATION: composer-real (unwrapped) does run scripts (escape hatch works)" {
  # The wrapper's documented escape hatch: users who genuinely need
  # scripts invoke /usr/local/bin/composer-real directly. This test
  # verifies the escape hatch (a) exists and (b) actually bypasses the
  # script-blocking. If composer-real is missing OR was somehow also
  # script-blocked, this test catches it.
  [ -x /usr/local/bin/composer-real ] || skip "composer-real not present (composer_path_wrapper may be false)"
  cd /tmp && rm -rf composer-bypass-test && mkdir composer-bypass-test && cd composer-bypass-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  /usr/local/bin/composer-real install --no-interaction 2>/dev/null || true
  marker_present=$([ -f /tmp/marker-composer-script ] && echo "yes" || echo "no")
  rm -rf /tmp/composer-bypass-test
  rm -f /tmp/marker-composer-script
  [ "$marker_present" = "yes" ]
}
