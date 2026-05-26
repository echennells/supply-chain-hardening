#!/usr/bin/env bats
# Bun bunfig.toml.j2 tier-rendering tests.
#
# saveTextLockfile is bun 1.2+ only. The role omits the key on detected
# <1.2 (older bun silently ignores it, but the omission keeps the
# rendered config clean). Mirrors the composer + yarn tier-rendering
# tests in 28-composer-tier-rendering.bats and 32-yarn-tier-rendering.bats.

load setup

TIER_DIR=/tmp/bun-tier-renders

setup_file() {
  mkdir -p "$TIER_DIR"
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    bun_minimum_release_age_seconds: 172800
    bun_exact: true
    bun_lifecycle_scripts: false
    bun_frozen_lockfile: true
    bun_auto: "disable"
    bun_save_text_lockfile: true
    bun_security_scanner: ""
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/bunfig.toml.j2
        dest: "$TIER_DIR/{{ item.label }}.toml"
        mode: "0644"
      vars:
        bun_detected_version: "{{ item.version }}"
      loop:
        - { label: undetected, version: "" }
        - { label: "bun-1.0.30", version: "1.0.30" }
        - { label: "bun-1.1.20", version: "1.1.20" }
        - { label: "bun-1.1.99-edge", version: "1.1.99" }
        - { label: "bun-1.2.0", version: "1.2.0" }
        - { label: "bun-1.2.5", version: "1.2.5" }
        - { label: "bun-2.0.0-future", version: "2.0.0" }
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
}

teardown_file() {
  rm -rf "$TIER_DIR"
}

assert_valid_toml() {
  python3 -c "import tomllib; tomllib.loads(open('$1').read())" \
    || { echo "FAIL: $1 is not valid TOML" >&2; cat "$1" >&2; return 1; }
}

assert_has_baseline() {
  local f="$1"
  for key in minimumReleaseAge exact lifecycleScripts frozenLockfile auto; do
    grep -q "^${key} = \|^${key}=" "$f" || { echo "missing $key in $f" >&2; return 1; }
  done
}

@test "tier-render: undetected → saveTextLockfile emitted (assume modern bun)" {
  local f="$TIER_DIR/undetected.toml"
  assert_valid_toml "$f"
  assert_has_baseline "$f"
  grep -q "^saveTextLockfile = true$" "$f"
}

@test "tier-render: 1.0.30 → saveTextLockfile OMITTED (pre-1.2)" {
  local f="$TIER_DIR/bun-1.0.30.toml"
  assert_valid_toml "$f"
  assert_has_baseline "$f"
  ! grep -q "^saveTextLockfile" "$f"
}

@test "tier-render: 1.1.20 → saveTextLockfile OMITTED (pre-1.2)" {
  local f="$TIER_DIR/bun-1.1.20.toml"
  assert_valid_toml "$f"
  ! grep -q "^saveTextLockfile" "$f"
}

@test "tier-render: 1.1.99 (last pre-1.2 patch) → saveTextLockfile OMITTED" {
  local f="$TIER_DIR/bun-1.1.99-edge.toml"
  assert_valid_toml "$f"
  ! grep -q "^saveTextLockfile" "$f"
}

@test "tier-render: 1.2.0 (boundary) → saveTextLockfile emitted" {
  local f="$TIER_DIR/bun-1.2.0.toml"
  assert_valid_toml "$f"
  grep -q "^saveTextLockfile = true$" "$f"
}

@test "tier-render: 1.2.5 (current) → saveTextLockfile emitted" {
  local f="$TIER_DIR/bun-1.2.5.toml"
  assert_valid_toml "$f"
  grep -q "^saveTextLockfile = true$" "$f"
}

@test "tier-render: 2.0.0 (future) → saveTextLockfile still emitted (numeric compare)" {
  # Guards against the "2.0" < "1.2" string-compare bug.
  local f="$TIER_DIR/bun-2.0.0-future.toml"
  assert_valid_toml "$f"
  grep -q "^saveTextLockfile = true$" "$f"
}

# --- bun_security_scanner role var conditional rendering ---
# Separate rendering pass because it's role-var-conditional, not
# version-tiered. Two cells: var set, var empty.

@test "render: bun_security_scanner='' → no [install.security] section (default)" {
  local out=/tmp/bun-render-no-scanner.toml
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    bun_minimum_release_age_seconds: 172800
    bun_exact: true
    bun_lifecycle_scripts: false
    bun_frozen_lockfile: true
    bun_auto: "disable"
    bun_save_text_lockfile: true
    bun_security_scanner: ""
    bun_detected_version: "1.2.5"
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/bunfig.toml.j2
        dest: $out
        mode: "0644"
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
  assert_valid_toml "$out"
  ! grep -q '^\[install\.security\]' "$out"
  rm -f "$out"
}

@test "render: bun_security_scanner='@socketsecurity/bun-security-scanner' → section emitted" {
  local out=/tmp/bun-render-scanner.toml
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    bun_minimum_release_age_seconds: 172800
    bun_exact: true
    bun_lifecycle_scripts: false
    bun_frozen_lockfile: true
    bun_auto: "disable"
    bun_save_text_lockfile: true
    bun_security_scanner: "@socketsecurity/bun-security-scanner"
    bun_detected_version: "1.2.5"
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/bunfig.toml.j2
        dest: $out
        mode: "0644"
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
  assert_valid_toml "$out"
  grep -q '^\[install\.security\]$' "$out"
  grep -q 'scanner = "@socketsecurity/bun-security-scanner"' "$out"
  rm -f "$out"
}
