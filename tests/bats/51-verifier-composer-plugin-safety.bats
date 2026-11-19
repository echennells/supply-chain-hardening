#!/usr/bin/env bats
# supply-chain-verify must not execute a checkout's code while reading its config.
#
# The verifier reads the EFFECTIVE composer config of the current directory
# (files/verify-probes.sh, the `composer config --list --source` probe) so it can
# report a repo that weakens the global hardening. A composer command run inside a
# checkout boots that checkout: it ACTIVATES any plugin the merged allow-plugins
# permits (a plugin's activate() is arbitrary PHP) and dispatches pre-command-run
# to the root composer.json's scripts. Without --no-plugins, running the verifier
# inside a hostile checkout — the exact "just check posture" use the tool invites —
# runs that checkout's code as the invoking user.
#
# MEASURED on composer 2.11.2 at 8281a6b, with an unwrapped composer first on
# PATH: composer_implements() (`composer config --global <key>`, once per key)
# activated the plugin AND ran the root pre-command-run script, and the run-probe
# (`composer --version`) activated the plugin, in both the role's verifier and
# action/verify.sh. This test stages that checkout and asserts neither runs, and
# that the composer rows are still produced (the flags must not blind the probe).
#
# It drives the REAL composer, not the role wrapper: the wrapper injects
# --no-plugins and --no-scripts itself, so testing through it would prove nothing
# about the probes. The real binary is read from the wrapper (real_binary), not
# assumed at /usr/local/bin: on an apt host that path does not exist and the old
# fallback resolved to the wrapper, which passes falsely.

load setup

VERIFY=/usr/local/bin/supply-chain-verify
MARKER=/tmp/sch-verifier-plugin-activated
SCRIPT_MARKER=/tmp/sch-verifier-checkout-script-ran

setup() {
  command -v php >/dev/null 2>&1 || skip "php not installed"
  [ -x "$VERIFY" ] || skip "supply-chain-verify not deployed"
  REAL_COMPOSER=$(real_binary composer) || REAL_COMPOSER=$(command -v composer 2>/dev/null)
  [ -n "$REAL_COMPOSER" ] || skip "composer not installed"
  if grep -q 'supply-chain-harden' "$REAL_COMPOSER" 2>/dev/null; then
    skip "composer resolves to a wrapper whose real binary could not be read"
  fi
  rm -f "$MARKER" "$SCRIPT_MARKER"
}

teardown() { rm -f "$MARKER" "$SCRIPT_MARKER"; }

stage_hostile_checkout() {
  root="$BATS_TEST_TMPDIR/vcheck"
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
  # The hostile checkout: pulls the plugin from a path repo and allows it (its
  # config object overrides the global allow-plugins {} per composer's merge
  # rules — the scenario the probe exists to detect), and hooks pre-command-run.
  cat > "$root/app/composer.json" <<J
{ "name": "victim/app", "version": "0.0.0",
  "repositories": [ { "type": "path", "url": "../plugin", "options": { "symlink": false } } ],
  "require": { "evil/probe": "*" },
  "scripts": { "pre-command-run": "echo ran > $SCRIPT_MARKER" },
  "config": { "allow-plugins": { "evil/probe": true } } }
J

  # Populate vendor/ with the real composer so a committed-plugin checkout exists.
  # (This install legitimately activates the plugin; the markers are cleared after.)
  ( cd "$root/app" && env -u COMPOSER_SKIP_SCRIPTS COMPOSER_HOME="$root/ch" HOME="$root" \
      COMPOSER_ALLOW_SUPERUSER=1 "$REAL_COMPOSER" install --no-interaction ) >/dev/null 2>&1 || true
  [ -f "$root/app/vendor/composer/installed.json" ] || skip "could not stage vendor/ from the path repository"
  rm -f "$MARKER" "$SCRIPT_MARKER"
  # The shim makes the bare `composer` the REAL binary for the verifier.
  shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  ln -sf "$REAL_COMPOSER" "$shim/composer"
}

@test "FIXTURE CONTROL: the probe's command without the protections runs the checkout's plugin" {
  stage_hostile_checkout
  # What composer_implements() ran before the fix: no --no-plugins, checkout as cwd.
  # COMPOSER_ALLOW_SUPERUSER=1 so a root run outside a container cannot mask it
  # (composer 2.7+ disables plugins for a non-interactive root run without it).
  ( cd "$root/app" && env -u COMPOSER_SKIP_SCRIPTS COMPOSER_ALLOW_SUPERUSER=1 \
      "$shim/composer" config --global --no-ansi secure-http ) >/dev/null 2>&1 || true
  if [ ! -f "$MARKER" ]; then
    # MEASURED: composer 2.2.6 and 2.7.1 did not activate the plugin on this
    # command; 2.5.5, 2.8.8 and 2.11.2 did (the VM run and this repo's own runs).
    skip "this composer ($("$REAL_COMPOSER" --version --no-ansi 2>/dev/null | head -1)) does not activate a checkout plugin on 'config --global'; nothing for the test below to prove"
  fi
}

@test "verify: composer probes do not run a checkout's plugin or scripts" {
  stage_hostile_checkout
  run env PATH="$shim:$PATH" COMPOSER_ALLOW_SUPERUSER=1 bash -c "cd '$root/app' && '$VERIFY' --verbose"

  # The load-bearing assertions: neither the plugin nor the root script ran.
  [ ! -f "$MARKER" ] || { echo "the checkout's plugin ran during verify" >&2; return 1; }
  [ ! -f "$SCRIPT_MARKER" ] || { echo "the checkout's pre-command-run script ran during verify" >&2; return 1; }
  # And the fix did not blind the probes: the plugin and override rows still
  # see the checkout's allow-plugins.
  [[ "$output" == *"composer plugin execution blocked"* ]]
  [[ "$output" == *"evil/probe"* ]]
}
