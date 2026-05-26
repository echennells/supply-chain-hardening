#!/usr/bin/env bats
# cargo-config.toml.j2 authority test for cargo_install_root.
#
# The deployed config (~/.cargo/config.toml) is tested by
# 01-config-files.bats which asserts that with cargo_install_root=""
# (default) the [install] block is NOT emitted. This file is the
# companion test for the set-case: rendering the template with a
# non-empty value MUST emit the [install] block with the right path.
#
# Same pattern as 34-composer-wrapper-tier-rendering.bats: render the
# template via ansible-playbook with each value, assert behavior.

load setup

CARGO_DIR=/tmp/cargo-config-renders

setup_file() {
  mkdir -p "$CARGO_DIR"
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/cargo-config.toml.j2
        dest: "$CARGO_DIR/{{ item.label }}.toml"
        mode: "0644"
      vars:
        cargo_install_root: "{{ item.root }}"
      loop:
        - { label: empty, root: "" }
        - { label: set, root: "/usr/local/cargo" }
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
}

teardown_file() {
  rm -rf "$CARGO_DIR"
}

@test "cargo-render: cargo_install_root='' (default) → no [install] block emitted" {
  local f="$CARGO_DIR/empty.toml"
  [ -f "$f" ]
  ! grep -q '^\[install\]' "$f"
  ! grep -q '^root = ' "$f"
}

@test "cargo-render: cargo_install_root set → [install] block + correct root path" {
  local f="$CARGO_DIR/set.toml"
  [ -f "$f" ]
  grep -q '^\[install\]' "$f"
  grep -q '^root = "/usr/local/cargo"$' "$f"
}

@test "cargo-render: both renderings keep [net] git-fetch-with-cli (the always-on hardening)" {
  # Regression catcher: a future template refactor must not couple
  # git-fetch-with-cli to the install-root conditional. git-fetch-with-cli
  # is the load-bearing hardening that respects SSH config / corporate
  # proxies — must fire on every rendering.
  grep -q "git-fetch-with-cli = true" "$CARGO_DIR/empty.toml"
  grep -q "git-fetch-with-cli = true" "$CARGO_DIR/set.toml"
}

@test "cargo-render: both renderings keep [net] retry (regression catcher)" {
  grep -q "retry = 3" "$CARGO_DIR/empty.toml"
  grep -q "retry = 3" "$CARGO_DIR/set.toml"
}

@test "cargo-render: both renderings parse as valid TOML" {
  python3 -c "import tomllib; tomllib.loads(open('$CARGO_DIR/empty.toml').read())"
  python3 -c "import tomllib; tomllib.loads(open('$CARGO_DIR/set.toml').read())"
}
