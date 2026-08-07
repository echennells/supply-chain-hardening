#!/usr/bin/env bats
# Yarn yarnrc.yml.j2 tier-rendering tests.
#
# enableHardenedMode is the one Yarn setting in the role that's
# version-gated — Yarn 4.0+ honors it; older versions warn on the
# unknown key. The role omits it on detected <4.0 to keep logs clean.
# This file synthesizes each tier by rendering the template at fixed
# yarn_detected_version inputs and asserts presence/absence.
#
# Mirrors the composer tier-rendering test (28-composer-tier-rendering.bats)
# — same setup_file pattern, same /tmp scratch dir, same per-tier
# assertions per the role's tier-rendering convention.

load setup

TIER_DIR=/tmp/yarn-tier-renders

setup_file() {
  mkdir -p "$TIER_DIR"
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    yarn_minimal_age_gate: "2d"
    yarn_enable_scripts: false
    yarn_enable_immutable_installs: true
    yarn_enable_immutable_cache: true
    yarn_checksum_behavior: "throw"
    yarn_approved_git_repositories: []
    yarn_unsafe_http_whitelist: []
    yarn_enable_hardened_mode: true
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/yarnrc.yml.j2
        dest: "$TIER_DIR/{{ item.label }}.yml"
        mode: "0644"
      vars:
        yarn_detected_version: "{{ item.version }}"
      loop:
        - { label: undetected, version: "" }
        - { label: yarn-3.6.4, version: "3.6.4" }
        - { label: yarn-3.8.x-edge, version: "3.8.9" }
        - { label: yarn-4.0.0, version: "4.0.0" }
        - { label: yarn-4.5.3, version: "4.5.3" }
        - { label: yarn-5.0.0-future, version: "5.0.0" }
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
}

teardown_file() {
  rm -rf "$TIER_DIR"
}

assert_valid_yaml() {
  python3 -c "import yaml,sys; yaml.safe_load(open('$1'))" \
    || { echo "FAIL: $1 is not valid YAML" >&2; cat "$1" >&2; return 1; }
}

assert_has_baseline() {
  local f="$1"
  for key in npmMinimalAgeGate enableScripts enableImmutableInstalls enableImmutableCache checksumBehavior approvedGitRepositories unsafeHttpWhitelist; do
    grep -q "^${key}:" "$f" || { echo "missing $key in $f" >&2; return 1; }
  done
}

@test "tier-render: undetected → enableHardenedMode emitted (assume modern Yarn)" {
  local f="$TIER_DIR/undetected.yml"
  assert_valid_yaml "$f"
  assert_has_baseline "$f"
  grep -q "^enableHardenedMode: true$" "$f"
}

@test "tier-render: 3.6.4 → enableHardenedMode OMITTED (Yarn <4.0 warns on unknown key)" {
  local f="$TIER_DIR/yarn-3.6.4.yml"
  assert_valid_yaml "$f"
  assert_has_baseline "$f"
  ! grep -q "^enableHardenedMode:" "$f"
}

@test "tier-render: 3.8.9 (last 3.x) → enableHardenedMode OMITTED" {
  local f="$TIER_DIR/yarn-3.8.x-edge.yml"
  assert_valid_yaml "$f"
  ! grep -q "^enableHardenedMode:" "$f"
}

@test "tier-render: 4.0.0 (boundary) → enableHardenedMode emitted" {
  local f="$TIER_DIR/yarn-4.0.0.yml"
  assert_valid_yaml "$f"
  grep -q "^enableHardenedMode: true$" "$f"
}

@test "tier-render: 4.5.3 (current) → enableHardenedMode emitted" {
  local f="$TIER_DIR/yarn-4.5.3.yml"
  assert_valid_yaml "$f"
  grep -q "^enableHardenedMode: true$" "$f"
}

@test "tier-render: 5.0.0 (future) → enableHardenedMode still emitted (numeric compare)" {
  # Guards against the classic "5.0" < "4.5" string-compare bug.
  local f="$TIER_DIR/yarn-5.0.0-future.yml"
  assert_valid_yaml "$f"
  grep -q "^enableHardenedMode: true$" "$f"
}
