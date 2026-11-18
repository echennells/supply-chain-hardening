#!/usr/bin/env bats
# supply-chain-verify must not execute a checkout's code while reading its config.
#
# The verifier reads the EFFECTIVE composer config of the current directory
# (files/verify-probes.sh, the `composer config --list --source` probe) so it can
# report a repo that weakens the global hardening. `composer config` ACTIVATES any
# plugin the merged allow-plugins permits, and a plugin's activate() is arbitrary
# PHP. Without --no-plugins, running the verifier inside a hostile checkout — the
# exact "just check posture" use the tool invites — runs that checkout's code as
# the invoking user. MEASURED on composer 2.11.1 before the fix: the plugin ran.
#
# This test stages that checkout and asserts the plugin's activate() does NOT run,
# AND that the composer rows are still produced (the flag must not blind the probe).
# It drives the REAL composer, not the role wrapper — the wrapper injects
# --no-plugins itself, so testing through it would prove nothing about the probe.

load setup

VERIFY=/usr/local/bin/supply-chain-verify
MARKER=/tmp/sch-verifier-plugin-activated

setup() {
  command -v php >/dev/null 2>&1 || skip "php not installed"
  [ -x "$VERIFY" ] || skip "supply-chain-verify not deployed"
  # The probe's exposure is against the UNWRAPPED composer; the role moves the
  # real binary aside as composer-real when it wraps. No -real => not wrapped,
  # and plain `composer` is already the real binary.
  REAL_COMPOSER=/usr/local/bin/composer-real
  [ -x "$REAL_COMPOSER" ] || REAL_COMPOSER=$(command -v composer 2>/dev/null)
  [ -n "$REAL_COMPOSER" ] || skip "composer not installed"
  rm -f "$MARKER"
}

teardown() { rm -f "$MARKER"; }

@test "verify: composer effective-config probe does not activate a checkout plugin" {
  local root="$BATS_TEST_TMPDIR/vcheck"
  mkdir -p "$root/plugin/src" "$root/app"

  cat > "$root/plugin/composer.json" <<'J'
{ "name": "evil/probe", "type": "composer-plugin", "version": "1.0.0",
  "require": { "composer-plugin-api": "^2.0" },
  "autoload": { "psr-4": { "Evil\\": "src/" } },
  "extra": { "class": "Evil\\Plugin" } }
J
  # A benign stand-in for arbitrary PHP: activate() just drops a marker file.
  cat > "$root/plugin/src/Plugin.php" <<P
<?php
namespace Evil;
use Composer\\Composer; use Composer\\IO\\IOInterface; use Composer\\Plugin\\PluginInterface;
class Plugin implements PluginInterface {
  public function activate(Composer \$c, IOInterface \$io) { file_put_contents('$MARKER', 'ran'); }
  public function deactivate(Composer \$c, IOInterface \$io) {}
  public function uninstall(Composer \$c, IOInterface \$io) {}
}
P
  # The hostile checkout: pulls the plugin from a path repo and allows it, and its
  # config object overrides the global hardening (allow-plugins:false) per composer's
  # merge rules — the scenario the probe exists to detect.
  cat > "$root/app/composer.json" <<'J'
{ "name": "victim/app", "version": "0.0.0",
  "repositories": [ { "type": "path", "url": "../plugin" } ],
  "require": { "evil/probe": "*" },
  "config": { "allow-plugins": { "evil/probe": true } } }
J

  # Populate vendor/ with the real composer so a committed-plugin checkout exists.
  # (This install legitimately activates the plugin; we clear the marker after.)
  ( cd "$root/app" && COMPOSER_HOME="$root/ch" HOME="$root" \
      "$REAL_COMPOSER" install --no-interaction --no-audit ) >/dev/null 2>&1 || true
  [ -f "$root/app/vendor/composer/installed.json" ] || skip "could not stage vendor/ (offline?)"
  rm -f "$MARKER"

  # Run the verifier in the hostile checkout with composer = the REAL binary.
  local shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  ln -sf "$REAL_COMPOSER" "$shim/composer"
  run env PATH="$shim:$PATH" bash -c "cd '$root/app' && '$VERIFY'"

  # The load-bearing assertion: the checkout's plugin code never ran.
  [ ! -f "$MARKER" ]
  # And the fix did not blind the probe: a composer row is still emitted.
  [[ "$output" == *"composer"* ]]
}
