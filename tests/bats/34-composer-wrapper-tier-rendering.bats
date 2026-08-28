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
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    composer_real_path: /usr/local/bin/composer-real
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/composer-wrapper.sh.j2
        dest: "$WRAPPER_DIR/{{ item.label }}.sh"
        mode: "0755"
      vars:
        composer_allow_plugins: "{{ item.allow }}"
      loop:
        - { label: deny-plugins, allow: false }
        - { label: allow-plugins, allow: true }
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
}

teardown_file() {
  rm -rf "$WRAPPER_DIR"
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

@test "wrapper-render: --no-scripts is unconditional across both renderings" {
  # Regression catcher: if a future refactor accidentally couples
  # --no-scripts to composer_allow_plugins (or any var), this test
  # catches it. Scripts are higher-risk than plugins; they should
  # never become opt-out via the same knob.
  grep -q -- "--no-scripts" "$WRAPPER_DIR/deny-plugins.sh"
  grep -q -- "--no-scripts" "$WRAPPER_DIR/allow-plugins.sh"
}

@test "wrapper-render: recursion guard present in both renderings" {
  # If a refactor of the Jinja conditional breaks the guard pattern, this
  # surfaces it before the wrapper gets shipped to production hosts.
  grep -q "refusing to recurse" "$WRAPPER_DIR/deny-plugins.sh"
  grep -q "refusing to recurse" "$WRAPPER_DIR/allow-plugins.sh"
}
