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
  skip "composer has no host-wide config/env mechanism to block scripts; pending /usr/local/bin/composer wrapper (see README Limitations)"
}
