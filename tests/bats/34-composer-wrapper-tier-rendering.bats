#!/usr/bin/env bats
# composer-wrapper.sh.j2 authority test for composer_allow_plugins.
#
# Before this test, the wrapper hardcoded --no-plugins regardless of
# composer_allow_plugins, making the role var decorative whenever
# composer_path_wrapper was on (the default). This test renders the
# wrapper template with both values of composer_allow_plugins and
# asserts the var is authoritative on the wrapper layer.
#
# Companion to 28-composer-tier-rendering.bats which covers the JSON
# config-layer authority. Both layers MUST agree — if the wrapper omits
# --no-plugins while the JSON still says "allow-plugins": false, the
# JSON config kicks in and prompts in interactive mode / denies in
# non-interactive contexts, which is surprising for a user who flipped
# composer_allow_plugins=true expecting plugins to run.

load setup

WRAPPER_DIR=/tmp/composer-wrapper-renders

setup_file() {
  mkdir -p "$WRAPPER_DIR"
  # A stand-in for the real composer that prints what the wrapper handed it,
  # so the routing tests below observe the argv instead of grepping the text.
  printf '#!/bin/sh\necho "ARGV: $*"\n' > "$WRAPPER_DIR/stub-real"
  chmod 0755 "$WRAPPER_DIR/stub-real"
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    composer_cooldown_seconds: "172800"
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/composer-wrapper.sh.j2
        dest: "$WRAPPER_DIR/{{ item.label }}.sh"
        mode: "0755"
      vars:
        composer_allow_plugins: "{{ item.allow }}"
        composer_real_path: "{{ item.real }}"
        composer_detected_version: "{{ item.version }}"
      loop:
        - { label: deny-plugins, allow: false, real: /usr/local/bin/composer-real, version: "" }
        - { label: allow-plugins, allow: true, real: /usr/local/bin/composer-real, version: "" }
        - { label: route-2.11, allow: false, real: "$WRAPPER_DIR/stub-real", version: "2.11.2" }
        - { label: route-2.1, allow: false, real: "$WRAPPER_DIR/stub-real", version: "2.1.14" }
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
}

teardown_file() {
  rm -rf "$WRAPPER_DIR"
}

@test "wrapper-render: the publish-age window is pinned for callers with no env layer" {
  grep -q '^export COMPOSER_POLICY_COOLDOWN_PERIOD=172800$' "$WRAPPER_DIR/deny-plugins.sh"
  grep -q '^export COMPOSER_POLICY_COOLDOWN_BLOCK=1$' "$WRAPPER_DIR/deny-plugins.sh"
}

@test "wrapper-render: composer_allow_plugins=false → wrapper injects --no-plugins" {
  local f="$WRAPPER_DIR/deny-plugins.sh"
  [ -f "$f" ]
  # The flags are assembled into FLAGS[] rather than written literally on the
  # exec line: --no-scripts is version-gated (it is not an application-level
  # option on composer <= 2.1), --no-plugins is not (it is global that far
  # back), so --no-plugins is an unconditional append.
  grep -qE '^FLAGS\+=\(--no-plugins\)$' "$f"
  grep -qE '^exec ".*REAL_COMPOSER.*" .*FLAGS.* "\$@"$' "$f"
}

@test "wrapper-render: composer_allow_plugins=true → wrapper omits --no-plugins" {
  local f="$WRAPPER_DIR/allow-plugins.sh"
  [ -f "$f" ]
  # --no-scripts MUST still be present (script execution has no opt-in).
  grep -qE '^ *FLAGS\+=\(--no-scripts\)$' "$f"
  grep -qE '^exec ".*REAL_COMPOSER.*" .*FLAGS.* "\$@"$' "$f"
  # --no-plugins MUST be absent from the injected flags.
  # Anchor to the append, not a bare grep: the wrapper's header comments
  # legitimately discuss --no-plugins when explaining the flag, and a bare
  # grep matches those comments (false positive) even though the injection
  # is correctly omitted.
  ! grep -qE '^FLAGS\+=\(--no-plugins\)$' "$f"
  ! grep -qE '^exec .*--no-plugins' "$f"
}

@test "wrapper-render: --no-scripts is present across both renderings" {
  # Regression catcher: if a future refactor accidentally couples
  # --no-scripts to composer_allow_plugins (or any var), this test
  # catches it. Scripts are higher-risk than plugins; they should
  # never become opt-out via the same knob.
  grep -q -- "--no-scripts" "$WRAPPER_DIR/deny-plugins.sh"
  grep -q -- "--no-scripts" "$WRAPPER_DIR/allow-plugins.sh"
}

# --- which invocations get --no-scripts -----------------------------------
# MEASURED on composer 2.2.6 -> 2.11.2 before this routing existed: injecting
# --no-scripts on `composer test` made it exit 0 having run nothing, and
# `composer run-script test` fail with 'Script "test" is not defined'. A script
# asked for by name now runs; every other invocation keeps --no-scripts.

# route <rendering> <args...>: run the rendered wrapper in $PROJ against the stub
route() {
  local r="$1"; shift
  run bash -c 'cd "$1" && shift && "$@"' _ "$PROJ" "$WRAPPER_DIR/$r.sh" "$@"
}

route_setup() {
  command -v php >/dev/null 2>&1 || skip "php not installed (the wrapper reads composer.json with php)"
  [ -x "$WRAPPER_DIR/route-2.11.sh" ] || skip "rendering failed"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/sub/deeper"
  # "install" is the hostile case: composer refuses to let a script shadow a
  # built-in, so `composer install` must still get --no-scripts. The key with a
  # newline must not smuggle "lint2" in as a script name.
  cat > "$PROJ/composer.json" <<'J'
{ "name": "t/t",
  "scripts": { "test": "echo t", "lint": ["@test"], "install": "echo x",
               "post-install-cmd": "echo p", "evil\nlint2": "echo e" },
  "scripts-aliases": { "lint": ["cs"] } }
J
}

@test "wrapper-route: a root script run by name gets no --no-scripts" {
  route_setup
  local args
  for args in "test" "lint" "cs" "run-script test" "run test" "-n test" "-vvv test --dev"; do
    # shellcheck disable=SC2086
    route route-2.11 $args
    [ "$status" -eq 0 ]
    [[ "$output" == "ARGV: "* ]] || { echo "no stub call for '$args': $output"; return 1; }
    [[ "$output" != *"--no-scripts"* ]] || { echo "'$args' got --no-scripts: $output"; return 1; }
    [[ "$output" == *"--no-plugins"* ]] || { echo "'$args' lost --no-plugins: $output"; return 1; }
  done
}

@test "wrapper-route: built-ins, unknown names and smuggled names keep --no-scripts" {
  route_setup
  local args
  for args in "install" "i" "update" "require x/y" "dump-autoload" "create-project a/b" \
              "show" "exec phpunit" "" "--version" "inst" "lint2" "post-install-cmd" "nosuchscript"; do
    # shellcheck disable=SC2086
    route route-2.11 $args
    [[ "$output" == *"--no-scripts"* ]] || { echo "'$args' did not get --no-scripts: $output"; return 1; }
  done
}

@test "wrapper-route: the composer.json is found where composer looks for it" {
  route_setup
  # -d / --working-dir move it, from anywhere
  run bash -c 'cd / && "$1" -d "$2" test' _ "$WRAPPER_DIR/route-2.11.sh" "$PROJ"
  [[ "$output" == "ARGV: "* && "$output" != *"--no-scripts"* ]] || { echo "-d: $output"; return 1; }
  run bash -c 'cd / && "$1" --working-dir="$2" test' _ "$WRAPPER_DIR/route-2.11.sh" "$PROJ"
  [[ "$output" == "ARGV: "* && "$output" != *"--no-scripts"* ]] || { echo "--working-dir=: $output"; return 1; }
  run bash -c 'cd / && "$1" -d"$2" test' _ "$WRAPPER_DIR/route-2.11.sh" "$PROJ"
  [[ "$output" == "ARGV: "* && "$output" != *"--no-scripts"* ]] || { echo "-dDIR: $output"; return 1; }
  # a subdirectory with no composer.json of its own: composer walks up to it
  run bash -c 'cd "$2/sub/deeper" && "$1" test' _ "$WRAPPER_DIR/route-2.11.sh" "$PROJ"
  [[ "$output" == "ARGV: "* && "$output" != *"--no-scripts"* ]] || { echo "walk-up: $output"; return 1; }
  # $COMPOSER names another file: "test" is not a script there
  echo '{"name":"t/o","scripts":{"other":"echo o"}}' > "$PROJ/other.json"
  run env COMPOSER=other.json bash -c 'cd "$2" && "$1" test' _ "$WRAPPER_DIR/route-2.11.sh" "$PROJ"
  [[ "$output" == *"--no-scripts"* ]] || { echo "COMPOSER=other.json test: $output"; return 1; }
  run env COMPOSER=other.json bash -c 'cd "$2" && "$1" other' _ "$WRAPPER_DIR/route-2.11.sh" "$PROJ"
  [[ "$output" != *"--no-scripts"* ]] || { echo "COMPOSER=other.json other: $output"; return 1; }
}

# A name that is a script AND a built-in spelling. MEASURED on 2.7.1 and 2.11.2:
# composer looks for an exact command name before it expands a unique prefix of a
# built-in, and a script is a command, so a checkout defining "req", "du", "dump",
# "up", "upd", "ins" or "rem" ran that script, with scripts enabled, on
# `composer req psr/log` and the rest. A "scripts-aliases" alias spelled like a
# built-in ("i", "upgrade") ran its script in place of the built-in. Adding
# --no-scripts there only empties the run, so the wrapper refuses it, by name.
hijack_setup() {
  route_setup
  HIJ="$BATS_TEST_TMPDIR/hijack"
  mkdir -p "$HIJ"
  cat > "$HIJ/composer.json" <<'J'
{ "name": "t/h",
  "scripts": { "req": "echo h", "du": "echo h", "dump": "echo h", "up": "echo h",
               "upd": "echo h", "ins": "echo h", "rem": "echo h", "check": "echo h",
               "Install": "echo h", "foo": "echo h", "lint": "echo l" },
  "scripts-aliases": { "foo": ["i", "upgrade", "inst"], "lint": ["cs"] } }
J
}

@test "wrapper-route: a script or alias that also names a built-in is refused, not run" {
  hijack_setup
  local args
  for args in "req psr/log" "du" "dump" "up" "upd" "ins" "rem psr/log" "check" "Install" \
              "i" "upgrade" "inst" "-n upd"; do
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && "$@"' _ "$HIJ" "$WRAPPER_DIR/route-2.11.sh" $args
    [ "$status" -eq 2 ] || { echo "'$args' exited $status: $output"; return 1; }
    [[ "$output" != *"ARGV:"* ]] || { echo "'$args' reached composer: $output"; return 1; }
    [[ "$output" == *"[supply-chain-hardening] refusing 'composer "* && "$output" == *"composer run-script "* ]] \
      || { echo "'$args' refusal does not name the control and the way out: $output"; return 1; }
  done
  run bash -c 'cd "$1" && "$2" req' _ "$HIJ" "$WRAPPER_DIR/route-2.11.sh"
  [[ "$output" == *"built-in 'require'"* && "$output" == *"'composer run-script req'"* ]]
  run bash -c 'cd "$1" && "$2" i' _ "$HIJ" "$WRAPPER_DIR/route-2.11.sh"
  [[ "$output" == *"'composer run-script foo'"* ]]
  # The unambiguous spellings: the script by run-script, a script and an alias
  # that name no built-in, and the built-in by its full name.
  for args in "run-script req" "run check" "lint" "cs"; do
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && "$@"' _ "$HIJ" "$WRAPPER_DIR/route-2.11.sh" $args
    [[ "$output" == "ARGV: "* && "$output" != *"--no-scripts"* ]] || { echo "'$args': $output"; return 1; }
  done
  for args in "require psr/log" "install" "update"; do
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && "$@"' _ "$HIJ" "$WRAPPER_DIR/route-2.11.sh" $args
    [[ "$output" == "ARGV: "* && "$output" == *"--no-scripts"* ]] || { echo "'$args': $output"; return 1; }
  done
}

@test "wrapper-route: an abbreviation that is not a script is the built-in, with --no-scripts" {
  route_setup
  local args
  for args in "req psr/log" "upd" "dump" "check"; do
    # shellcheck disable=SC2086
    route route-2.11 $args
    [[ "$output" == "ARGV: "* && "$output" == *"--no-scripts"* ]] || { echo "'$args': $output"; return 1; }
  done
}

@test "wrapper-route: in -nd DIR the DIR is a value, and composer does not change to it" {
  route_setup
  # MEASURED on 2.5.5, 2.7.1 and 2.11.2: `composer -nd DIR test` runs the test
  # script of the CURRENT directory. The wrapper parsed DIR as the subcommand,
  # injected --no-scripts, and the test step exited 0 having run nothing.
  run bash -c 'cd "$2" && "$1" -nd /tmp test' _ "$WRAPPER_DIR/route-2.11.sh" "$PROJ"
  [[ "$output" == "ARGV: "* && "$output" != *"--no-scripts"* ]] || { echo "-nd in the project: $output"; return 1; }
  run bash -c 'cd / && "$1" -nd "$2" test' _ "$WRAPPER_DIR/route-2.11.sh" "$PROJ"
  [[ "$output" == *"--no-scripts"* ]] || { echo "-nd from /: $output"; return 1; }
}

@test "wrapper-route: composer <= 2.1 injects only on the subcommands that declare --no-scripts" {
  route_setup
  [ -x "$WRAPPER_DIR/route-2.1.sh" ] || skip "rendering failed"
  route route-2.1 install
  [[ "$output" == *"--no-scripts"* ]]
  route route-2.1 show
  [[ "$output" == "ARGV: "* && "$output" != *"--no-scripts"* ]]
  route route-2.1 test
  [[ "$output" == "ARGV: "* && "$output" != *"--no-scripts"* ]]
}

# composer resolves an alias or a unique prefix of a built-in to the command
# itself, so on <= 2.1 those must get --no-scripts too. MEASURED on 6c77f4e with
# composer 2.1.14: `req`, `upd`, `up`, `ins`, `dump` and `rem` got none and ran
# the root update and autoload-dump scripts (the real-composer test is in
# 16-composer-behavioral.bats). The commands that do not declare the option on
# 2.1.14 (`composer list --format=json`) must still not get it, or they die with
# 'The "--no-scripts" option does not exist.'; neither must a name composer
# calls ambiguous (`in`: init, install, info).
@test "wrapper-route: composer <= 2.1 resolves aliases and unique prefixes before deciding" {
  route_setup
  [ -x "$WRAPPER_DIR/route-2.1.sh" ] || skip "rendering failed"
  local args
  for args in "i" "ins" "inst" "u" "up" "upd" "upgrade" "upg" "req x/y" "requ x/y" "rem x/y" "remo x/y" \
              "rm x/y" "uninstall x/y" "dump" "du" "dumpa" "dumpautoload" "cr a/b" "create-project a/b" \
              "rei x/y" "reinstall x/y" "UPD" "-n upd" "-d /tmp req x/y"; do
    # shellcheck disable=SC2086
    route route-2.1 $args
    [[ "$output" == "ARGV: "* && "$output" == *"--no-scripts"* ]] || { echo "'$args' did not get --no-scripts: $output"; return 1; }
  done
  for args in "show" "sh" "info" "in" "re" "d" "conf" "config" "exec phpunit" "valid" "status" "outdated" "--version" ""; do
    # shellcheck disable=SC2086
    route route-2.1 $args
    [[ "$output" == "ARGV: "* && "$output" != *"--no-scripts"* ]] || { echo "'$args' got --no-scripts: $output"; return 1; }
  done
}

@test "wrapper-render: recursion guard present in both renderings" {
  # If a refactor of the Jinja conditional breaks the guard pattern, this
  # surfaces it before the wrapper gets shipped to production hosts.
  grep -q "refusing to recurse" "$WRAPPER_DIR/deny-plugins.sh"
  grep -q "refusing to recurse" "$WRAPPER_DIR/allow-plugins.sh"
}
