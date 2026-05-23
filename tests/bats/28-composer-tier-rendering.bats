#!/usr/bin/env bats
# Composer config.json.j2 tier-rendering tests.
#
# The test container installs Composer via the upstream installer, which
# means the integration tests in 11-composer-adversarial.bats only ever
# exercise Tier 1 (Composer >= 2.9). The version tiering itself — the
# whole point of the templated config — has no coverage from those tests.
#
# This file closes that gap by rendering the role's actual template
# (templates/composer-config.json.j2) at synthetic composer_detected_version
# inputs and asserting each tier's expected shape:
#   - undetected   → no audit block (safe baseline)
#   - 2.2.6 jammy  → no audit block
#   - 2.5.5 bookwm → no audit block
#   - 2.7.1 noble  → audit.abandoned only (no block-*)
#   - 2.9.8 current → full audit (abandoned + block-insecure + block-abandoned)

load setup

TIER_DIR=/tmp/composer-tier-renders
# ROLE_DIR is autodetected by setup.bash for both in-Docker and local runs.

setup_file() {
  mkdir -p "$TIER_DIR"
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    composer_audit_abandoned: "fail"
    composer_audit_block_insecure: true
    composer_audit_block_abandoned: true
    composer_allow_plugins: false
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/composer-config.json.j2
        dest: "$TIER_DIR/{{ item.label }}.json"
        mode: "0644"
      vars:
        composer_detected_version: "{{ item.version }}"
      loop:
        - { label: undetected, version: "" }
        - { label: tier3-jammy, version: "2.2.6" }
        - { label: tier3-bookworm, version: "2.5.5" }
        - { label: tier2-noble, version: "2.7.1" }
        - { label: tier1-current, version: "2.9.8" }
        - { label: tier1-future, version: "2.10.0" }
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
}

teardown_file() {
  rm -rf "$TIER_DIR"
}

assert_valid_json() {
  python3 -c "import json,sys; json.load(open('$1'))" \
    || { echo "FAIL: $1 is not valid JSON" >&2; cat "$1" >&2; return 1; }
}

assert_has_baseline() {
  # Baseline keys that must appear on EVERY tier (including undetected).
  local f="$1"
  grep -q '"scripts-are-disabled": true' "$f" || { echo "missing scripts-are-disabled in $f" >&2; return 1; }
  grep -q '"secure-http": true' "$f" || { echo "missing secure-http in $f" >&2; return 1; }
  grep -q '"preferred-install": "dist"' "$f" || { echo "missing preferred-install in $f" >&2; return 1; }
  grep -q '"allow-plugins": false' "$f" || { echo "missing allow-plugins in $f" >&2; return 1; }
}

@test "tier-render: undetected (composer not installed) → Tier-3 baseline, no audit block" {
  local f="$TIER_DIR/undetected.json"
  assert_valid_json "$f"
  assert_has_baseline "$f"
  if grep -q '"audit"' "$f"; then
    echo "FAIL: undetected tier must NOT include audit block (Composer < 2.7 may reject it)" >&2
    return 1
  fi
}

@test "tier-render: 2.2.6 (Ubuntu 22.04 jammy) → Tier 3, no audit block" {
  local f="$TIER_DIR/tier3-jammy.json"
  assert_valid_json "$f"
  assert_has_baseline "$f"
  ! grep -q '"audit"' "$f"
}

@test "tier-render: 2.5.5 (Debian 12 bookworm) → Tier 3, no audit block" {
  local f="$TIER_DIR/tier3-bookworm.json"
  assert_valid_json "$f"
  assert_has_baseline "$f"
  ! grep -q '"audit"' "$f"
}

@test "tier-render: 2.7.1 (Ubuntu 24.04 noble) → Tier 2, audit.abandoned only" {
  local f="$TIER_DIR/tier2-noble.json"
  assert_valid_json "$f"
  assert_has_baseline "$f"
  grep -q '"abandoned": "fail"' "$f"
  ! grep -q '"block-insecure"' "$f"
  ! grep -q '"block-abandoned"' "$f"
}

@test "tier-render: 2.9.8 (upstream current) → Tier 1, full audit block" {
  local f="$TIER_DIR/tier1-current.json"
  assert_valid_json "$f"
  assert_has_baseline "$f"
  grep -q '"abandoned": "fail"' "$f"
  grep -q '"block-insecure": true' "$f"
  grep -q '"block-abandoned": true' "$f"
}

@test "tier-render: 2.10.0 (future) → Tier 1 (version comparison is numeric, not string)" {
  # Guards against the classic "2.10" < "2.9" string-compare bug.
  local f="$TIER_DIR/tier1-future.json"
  assert_valid_json "$f"
  grep -q '"block-insecure": true' "$f"
  grep -q '"block-abandoned": true' "$f"
}
