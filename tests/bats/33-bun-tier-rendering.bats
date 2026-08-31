#!/usr/bin/env bats
# Bun bunfig.toml.j2 tier-rendering tests.
#
# THREE tiers, all MEASURED across bun 1.1.38 → 1.4.0:
#   ignoreScripts      inert below 1.2.0 (global AND local bunfig ignored;
#                      only the CLI --ignore-scripts works there)
#   minimumReleaseAge  does not exist below 1.3.0 (absent through 1.2.23)
#   saveTextLockfile   bun 1.2.0+
# Below its threshold each key is OMITTED; tasks/bun.yml records the gap in
# skipped_protections. Undetected version emits everything, because bun
# ignores unknown [install] keys silently — over-emitting is inert, while
# under-emitting would leave a modern bun unhardened.
#
# minimumReleaseAge is asserted UNQUOTED and numeric on purpose: bun rejects
# the ENTIRE bunfig on one bad value ("Invalid Bunfig: failed to load
# bunfig", exit 1 — measured with a quoted "2d"), so a quoted value here
# would disarm every other key in the file and break bun.
#
# Mirrors the composer + yarn tier-rendering tests in
# 28-composer-tier-rendering.bats and 32-yarn-tier-rendering.bats.

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
    bun_ignore_scripts: true
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
        - { label: "bun-1.2.23", version: "1.2.23" }
        - { label: "bun-1.3.0", version: "1.3.0" }
        - { label: "bun-1.4.0", version: "1.4.0" }
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

# The keys with NO version threshold: measured universal 1.1.38 → 1.4.0.
# ignoreScripts and minimumReleaseAge are deliberately NOT in this list —
# they are tiered, and asserting them here is what let the untiered bug hide.
assert_has_baseline() {
  local f="$1"
  for key in exact frozenLockfile auto; do
    grep -q "^${key} = \|^${key}=" "$f" || { echo "missing $key in $f" >&2; return 1; }
  done
}

# minimumReleaseAge must be a bare integer: quoted or non-numeric makes bun
# reject the whole file.
assert_age_is_bare_integer() {
  grep -qE '^minimumReleaseAge = [0-9]+$' "$1" \
    || { echo "FAIL: minimumReleaseAge is not a bare integer in $1" >&2; grep -n minimumReleaseAge "$1" >&2; return 1; }
}

@test "tier-render: undetected → every key emitted (assume modern bun)" {
  local f="$TIER_DIR/undetected.toml"
  assert_valid_toml "$f"
  assert_has_baseline "$f"
  grep -q "^saveTextLockfile = true$" "$f"
  grep -q "^ignoreScripts = true$" "$f"
  assert_age_is_bare_integer "$f"
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
    bun_ignore_scripts: true
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
    bun_ignore_scripts: true
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

# --- ignoreScripts: inert below bun 1.2.0 (MEASURED) ---

@test "tier-render: 1.0.30 → ignoreScripts OMITTED (inert below 1.2.0)" {
  local f="$TIER_DIR/bun-1.0.30.toml"
  assert_valid_toml "$f"
  ! grep -q "^ignoreScripts" "$f"
}

@test "tier-render: 1.1.99 (last pre-1.2 patch) → ignoreScripts OMITTED" {
  local f="$TIER_DIR/bun-1.1.99-edge.toml"
  assert_valid_toml "$f"
  ! grep -q "^ignoreScripts" "$f"
}

@test "tier-render: 1.2.0 (boundary) → ignoreScripts emitted" {
  local f="$TIER_DIR/bun-1.2.0.toml"
  assert_valid_toml "$f"
  grep -q "^ignoreScripts = true$" "$f"
}

@test "tier-render: 1.4.0 → ignoreScripts emitted" {
  local f="$TIER_DIR/bun-1.4.0.toml"
  assert_valid_toml "$f"
  grep -q "^ignoreScripts = true$" "$f"
}

# --- minimumReleaseAge: does not exist below bun 1.3.0 (MEASURED) ---

@test "tier-render: 1.2.0 → minimumReleaseAge OMITTED (key added in 1.3.0)" {
  local f="$TIER_DIR/bun-1.2.0.toml"
  assert_valid_toml "$f"
  ! grep -q "^minimumReleaseAge" "$f"
}

@test "tier-render: 1.2.23 (last version without the key) → minimumReleaseAge OMITTED" {
  local f="$TIER_DIR/bun-1.2.23.toml"
  assert_valid_toml "$f"
  ! grep -q "^minimumReleaseAge" "$f"
  # ignoreScripts is a SEPARATE tier and is honoured here.
  grep -q "^ignoreScripts = true$" "$f"
}

@test "tier-render: 1.3.0 (boundary) → minimumReleaseAge emitted, bare integer" {
  local f="$TIER_DIR/bun-1.3.0.toml"
  assert_valid_toml "$f"
  assert_age_is_bare_integer "$f"
}

@test "tier-render: 1.4.0 → minimumReleaseAge emitted, bare integer" {
  local f="$TIER_DIR/bun-1.4.0.toml"
  assert_valid_toml "$f"
  assert_age_is_bare_integer "$f"
}

@test "tier-render: no rendered tier ever quotes minimumReleaseAge" {
  # bun rejects the WHOLE bunfig on one bad value, so a quoted age would
  # disarm ignoreScripts, frozenLockfile and auto along with itself.
  # Anchor to real KEY lines (optional indent, then the key): the template's own
  # comment documents the failure mode with a literal `minimumReleaseAge = "2d"`
  # example, and bun ignores comment (#) lines — matching that would be a false
  # positive. Only a quoted ACTIVE key must fail this test.
  ! grep -rqE '^[[:space:]]*minimumReleaseAge[[:space:]]*=[[:space:]]*"' "$TIER_DIR"
}

@test "tier-render: every tier stays valid TOML with keys omitted" {
  for f in "$TIER_DIR"/*.toml; do
    assert_valid_toml "$f"
    grep -q '^\[install\]$' "$f" || { echo "no [install] table in $f" >&2; return 1; }
  done
}
