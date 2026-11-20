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
# The blocking assertion is skipped until the composer PATH
# wrapper is implemented (composer has no config-file or env-var way to
# block scripts host-wide — the only real primitives are --no-scripts CLI
# flag and COMPOSER_SKIP_SCRIPTS=<event,list> env var on composer 2.8.6+,
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
  # the result. The real binary behind the wrapper bypasses the wrapper too.
  # The marker SHOULD appear.
  REAL=$(real_binary composer) || skip "composer is not wrapped (composer_path_wrapper may be false)"
  cd /tmp && rm -rf composer-control-test && mkdir composer-control-test && cd composer-control-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  env -i HOME=/tmp/composer-control-test PATH=/usr/local/bin:/usr/bin:/bin \
    "$REAL" install --no-interaction 2>/dev/null || true
  marker_present=$([ -f /tmp/marker-composer-script ] && echo "yes" || echo "no")
  rm -rf /tmp/composer-control-test
  rm -f /tmp/marker-composer-script
  [ "$marker_present" = "yes" ]
}

@test "ATTACK: composer post-install-cmd script is blocked" {
  # The composer wrapper injects --no-scripts on every lifecycle
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
  #   1. the composer wrapper injects --no-scripts --no-plugins
  #   2. COMPOSER_SKIP_SCRIPTS=<events> in /etc/environment (catches
  #      `php composer.phar` callers and composer-real callers in
  #      PAM-loaded shells)
  # The documented bypass requires going around BOTH: invoke composer-real
  # AND clear the env var. Just `composer-real install` alone is still
  # blocked by layer 2 — which is intentional belt-and-suspenders, not a
  # bug. This test verifies the documented bypass actually works.
  REAL=$(real_binary composer) || skip "composer is not wrapped (composer_path_wrapper may be false)"
  cd /tmp && rm -rf composer-bypass-test && mkdir composer-bypass-test && cd composer-bypass-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  env -i HOME=/tmp/composer-bypass-test PATH=/usr/local/bin:/usr/bin:/bin \
    "$REAL" install --no-interaction 2>/dev/null || true
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
  REAL=$(real_binary composer) || skip "composer is not wrapped (composer_path_wrapper may be false)"
  # The env-var layer only exists from composer 2.8.6: MEASURED, 2.2.6, 2.7.1,
  # 2.8.4 and 2.8.5 run every script with COMPOSER_SKIP_SCRIPTS set, and the
  # role records that host as a skipped protection rather than claiming it.
  local v; v=$("$REAL" --version --no-ansi 2>/dev/null | sed -nE 's/^Composer (version )?([0-9]+\.[0-9]+\.[0-9]+).*$/\2/p' | head -1)
  [ -n "$v" ] || skip "could not read the composer version"
  [ "$(printf '2.8.6\n%s\n' "$v" | sort -V | head -1)" = "2.8.6" ] \
    || skip "composer $v ignores COMPOSER_SKIP_SCRIPTS (honoured from 2.8.6); there is no env-var layer to test"
  cd /tmp && rm -rf composer-real-test && mkdir composer-real-test && cd composer-real-test
  cp /opt/test-fixtures/composer-postinstall/composer.json .
  "$REAL" install --no-interaction 2>/dev/null || true
  marker_present=$([ -f /tmp/marker-composer-script ] && echo "yes" || echo "no")
  rm -rf /tmp/composer-real-test
  rm -f /tmp/marker-composer-script
  [ "$marker_present" = "no" ]
}

# --- a script asked for by name runs; lifecycle scripts do not ---------------
# MEASURED before the wrapper learned the difference (composer 2.2.6 -> 2.11.2,
# role and action): `composer test` exited 0 with no output while the script
# says `exit 3`, and `composer run-script test` failed with 'Script "test" is
# not defined in this package'. A CI test step went green having run nothing.

explicit_fixture() {
  EXP="$BATS_TEST_TMPDIR/explicit"
  mkdir -p "$EXP"
  cat > "$EXP/composer.json" <<'J'
{ "name": "test/explicit-scripts",
  "scripts": { "test": "echo SCH-RAN-TEST; exit 3", "lint": ["@test"] } }
J
}

@test "EXPLICIT SCRIPT: composer <name> runs the root script and returns its exit code" {
  explicit_fixture
  run bash -c 'cd "$1" && composer test --no-interaction' _ "$EXP"
  [ "$status" -eq 3 ]
  [[ "$output" == *"SCH-RAN-TEST"* ]]
  run bash -c 'cd "$1" && composer lint --no-interaction' _ "$EXP"
  [ "$status" -eq 3 ]
  [[ "$output" == *"SCH-RAN-TEST"* ]]
}

@test "EXPLICIT SCRIPT: composer run-script <name> and composer run <name> run it" {
  explicit_fixture
  run bash -c 'cd "$1" && composer run-script test --no-interaction' _ "$EXP"
  [ "$status" -eq 3 ]
  [[ "$output" == *"SCH-RAN-TEST"* ]]
  run bash -c 'cd "$1" && composer run test --no-interaction' _ "$EXP"
  [ "$status" -eq 3 ]
  [[ "$output" == *"SCH-RAN-TEST"* ]]
}

# A checkout cannot turn `composer install` into an "explicit run" by naming a
# script "install": composer skips such a script ("would override a Composer
# command") and runs the built-in, which must still get --no-scripts.
hostile_install_fixture() {
  HOST="$BATS_TEST_TMPDIR/hostile"
  mkdir -p "$HOST"
  php -r '
    $j = json_decode(file_get_contents($argv[1]), true);
    $j["scripts"]["install"] = "echo named-install";
    file_put_contents($argv[2], json_encode($j, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
  ' /opt/test-fixtures/composer-postinstall/composer.json "$HOST/composer.json"
}

@test "FIXTURE CONTROL: the hostile-install fixture fires its lifecycle script without the wrapper" {
  command -v php >/dev/null 2>&1 || skip "php not installed"
  REAL=$(real_binary composer) || skip "composer is not wrapped (composer_path_wrapper may be false)"
  hostile_install_fixture
  run bash -c 'cd "$1" && env -u COMPOSER_SKIP_SCRIPTS "$2" install --no-interaction' _ "$HOST" "$REAL"
  [ -f /tmp/marker-composer-script ]
  rm -f /tmp/marker-composer-script
}

@test "ATTACK: a script named install does not lift --no-scripts from composer install" {
  command -v php >/dev/null 2>&1 || skip "php not installed"
  hostile_install_fixture
  # COMPOSER_SKIP_SCRIPTS is unset so the wrapper is the only thing that can
  # block the script. setup() loads the env layer, which on composer >= 2.8.6
  # blocks post-install-cmd by itself: MEASURED on 2.11.2, this test still
  # passed with "install" removed from the wrapper's built-in list.
  run bash -c 'cd "$1" && env -u COMPOSER_SKIP_SCRIPTS composer install --no-interaction' _ "$HOST"
  [ "$status" -eq 0 ]
  [ -f "$HOST/vendor/autoload.php" ]
  [ ! -f /tmp/marker-composer-script ]
}

# A checkout cannot take over a command the caller typed as package management
# by naming a script after an abbreviation of a built-in: composer resolves an
# exact command name before an abbreviation, and a script is a command. MEASURED
# on 2.7.1 and 2.11.2 before the wrapper refused it: `composer req psr/log` ran
# the checkout's "req" script with scripts enabled, and so did du, dump, up, upd,
# ins and rem. A "scripts-aliases" alias spelled like a built-in ("i") did too.
abbrev_fixture() {
  ABB="$BATS_TEST_TMPDIR/abbrev"
  mkdir -p "$ABB"
  cat > "$ABB/composer.json" <<J
{ "name": "test/abbrev-hijack",
  "scripts": { "req": "echo req >> $ABB/HIJACK", "upd": "echo upd >> $ABB/HIJACK",
               "check": "echo check >> $ABB/HIJACK", "foo": "echo foo >> $ABB/HIJACK" },
  "scripts-aliases": { "foo": ["i"] } }
J
}

@test "FIXTURE CONTROL: without the wrapper, composer runs an abbreviation-named script" {
  REAL=$(real_binary composer) || skip "composer is not wrapped (composer_path_wrapper may be false)"
  abbrev_fixture
  run bash -c 'cd "$1" && env -u COMPOSER_SKIP_SCRIPTS "$2" req psr/log --no-interaction' _ "$ABB" "$REAL"
  # composer appends the arguments to the script's command, hence "req psr/log"
  grep -q '^req' "$ABB/HIJACK" 2>/dev/null || { echo "composer-real req did not run the req script: $output"; return 1; }
}

@test "ATTACK: a script named after an abbreviation of a built-in is refused, not run" {
  command -v php >/dev/null 2>&1 || skip "php not installed (the wrapper reads composer.json with php)"
  abbrev_fixture
  local args
  for args in "req psr/log" "upd" "check" "i"; do
    rm -f "$ABB/HIJACK"
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && env -u COMPOSER_SKIP_SCRIPTS composer "$@" --no-interaction' _ "$ABB" $args
    [ ! -f "$ABB/HIJACK" ] || { echo "'composer $args' ran the checkout's script: $(cat "$ABB/HIJACK")"; return 1; }
    [ "$status" -eq 2 ] || { echo "'composer $args' exited $status: $output"; return 1; }
    [[ "$output" == *"[supply-chain-hardening] refusing"* && "$output" == *"composer run-script"* ]] \
      || { echo "'composer $args' was not refused by name: $output"; return 1; }
  done
  # The unambiguous spelling still runs the script.
  rm -f "$ABB/HIJACK"
  run bash -c 'cd "$1" && composer run-script check --no-interaction' _ "$ABB"
  [ "$status" -eq 0 ]
  grep -q '^check' "$ABB/HIJACK"
  # And in a project with no such script, an abbreviation is still the built-in.
  explicit_fixture
  run bash -c 'cd "$1" && composer req --help --no-interaction' _ "$EXP"
  [[ "$output" == *"require [options]"* ]] || { echo "req --help: $output"; return 1; }
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

# ---- composer <= 2.1: an abbreviation is the same command ----
#
# --no-scripts is a global option only from composer 2.2.0, so on 2.0/2.1 the
# wrapper injects it per command. It used to match only the full names, while
# composer runs any unique prefix of a built-in (`req` is require). MEASURED on
# 6c77f4e with composer 2.1.14 behind the wrapper: `composer req local/pkg`,
# `upd`, `up`, `ins`, `dump` and `rem local/pkg` each ran the root
# pre/post-update-cmd and pre/post-autoload-dump scripts. A real 2.1.14 phar is
# downloaded (checksum pinned) and wrapped by the role's own template, rendered
# for that version.
C21_SHA256=d44a904520f9aaa766e8b4b05d2d9a766ad9a6f03fa1a48518224aad703061a4
c21_setup() {
  command -v php >/dev/null 2>&1 || skip "php not installed"
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  C21="$BATS_TEST_TMPDIR/c21"
  mkdir -p "$C21/home" "$C21/pkg"
  curl -fsSL --max-time 120 -o "$C21/composer-2.1.14" https://getcomposer.org/download/2.1.14/composer.phar \
    || skip "could not download composer 2.1.14 (offline?)"
  [ "$(sha256sum < "$C21/composer-2.1.14" | cut -d' ' -f1)" = "$C21_SHA256" ] || { echo "composer 2.1.14 checksum mismatch"; return 1; }
  chmod 0755 "$C21/composer-2.1.14"
  cat > "$C21/render.yml" <<Y
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/composer-wrapper.sh.j2
        dest: $C21/composer
        mode: "0755"
      vars:
        composer_allow_plugins: false
        composer_cooldown_seconds: 172800
        composer_real_path: $C21/composer-2.1.14
        composer_detected_version: "2.1.14"
Y
  ansible-playbook "$C21/render.yml" >/dev/null 2>&1 || { echo "rendering the wrapper failed"; return 1; }
  grep -q '^NO_SCRIPTS_IS_GLOBAL="false"$' "$C21/composer"
  echo '{ "name": "local/pkg", "version": "1.0.0" }' > "$C21/pkg/composer.json"
}
# c21_run <composer> <args...>: in a fresh project whose root scripts touch
# markers; prints the events whose script ran
c21_run() {
  local bin=$1 p="$C21/proj"; shift
  rm -rf "$p" /tmp/marker-c21-*; mkdir -p "$p"
  cat > "$p/composer.json" <<J
{ "name": "t/p", "minimum-stability": "dev",
  "repositories": [ { "type": "path", "url": "$C21/pkg", "options": { "symlink": false } }, { "packagist.org": false } ],
  "scripts": { "pre-update-cmd": "touch /tmp/marker-c21-pre-update-cmd",
               "post-update-cmd": "touch /tmp/marker-c21-post-update-cmd",
               "post-install-cmd": "touch /tmp/marker-c21-post-install-cmd",
               "post-autoload-dump": "touch /tmp/marker-c21-post-autoload-dump" } }
J
  if [ "$1" = rem ]; then
    ( cd "$p" && env -u COMPOSER_SKIP_SCRIPTS COMPOSER_HOME="$C21/home" COMPOSER_ALLOW_SUPERUSER=1 \
        "$C21/composer-2.1.14" require local/pkg --no-scripts -n >/dev/null 2>&1 )
  fi
  ( cd "$p" && env -u COMPOSER_SKIP_SCRIPTS COMPOSER_HOME="$C21/home" COMPOSER_ALLOW_SUPERUSER=1 \
      "$bin" "$@" -n >/dev/null 2>&1 ) || true
  ls /tmp/marker-c21-* 2>/dev/null | sed 's#/tmp/marker-c21-##' | tr '\n' ' '
  rm -f /tmp/marker-c21-*
}

@test "FIXTURE CONTROL: on composer 2.1.14 an abbreviation of a lifecycle command runs the root scripts" {
  c21_setup
  local args ran
  for args in "upd" "req local/pkg" "dump" "rem local/pkg"; do
    # shellcheck disable=SC2086
    ran=$(c21_run "$C21/composer-2.1.14" $args)
    echo "unwrapped composer $args: ${ran:-none}"
    [ -n "$ran" ] || { echo "the fixture fires no script for '$args' even unwrapped"; return 1; }
  done
}

@test "ATTACK: composer <= 2.1 tier — an abbreviation of a lifecycle command runs no root script through the wrapper" {
  c21_setup
  local args ran
  for args in "upd" "up" "ins" "req local/pkg" "requ local/pkg" "dump" "du" "rem local/pkg" "UPD"; do
    # shellcheck disable=SC2086
    ran=$(c21_run "$C21/composer" $args)
    echo "wrapped composer $args: ${ran:-none}"
    [ -z "$ran" ] || { echo "'composer $args' ran root scripts through the wrapper: $ran"; return 1; }
  done
  # The commands that do not declare --no-scripts on 2.1 still work (no
  # "option does not exist"), abbreviated or not.
  for args in "show" "sh" "valid" "conf --list"; do
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && "$@"' _ "$C21/proj" \
      env COMPOSER_HOME="$C21/home" COMPOSER_ALLOW_SUPERUSER=1 "$C21/composer" $args
    [[ "$output" != *"option does not exist"* ]] || { echo "'composer $args': $output"; return 1; }
  done
}
