#!/usr/bin/env bats
# pnpm allowlist-hardening tests.
#
# Covers the changes motivated by the Shai-Hulud / ChainDrop npm worm review
# (keyv maintainer-account takeover, 2026-08):
#   - store-integrity + lockfile-determinism keys render on the default path
#     AND survive alongside a build-script allowlist (not lost in that branch)
#   - the doubly-exempt guard (pnpm_allowlist_conflict_action) fails or warns
#     when a package is on BOTH the script allowlist and the age-gate exclude
#   - the exemption report surfaces only when something is actually exempted
#
# Render tests use the direct-template pattern from 33-bun-tier-rendering.bats.
# Behavior tests run tasks/pnpm.yml via ansible-playbook with XDG_CONFIG_HOME
# redirected to a throwaway dir, so the file-deployment tasks never touch the
# host's real ~/.config/pnpm. The guard runs before any write, so its fail
# cases abort before the filesystem is touched at all.

load setup

RENDER_DIR=/tmp/pnpm-allowlist-renders

setup_file() {
  mkdir -p "$RENDER_DIR"
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    pnpm_minimum_release_age_minutes: 2880
    pnpm_minimum_release_age_strict: true
    pnpm_verify_store_integrity: true
    pnpm_prefer_frozen_lockfile: true
  tasks:
    # Default posture: both allowlists empty.
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/pnpm-rc.j2
        dest: "$RENDER_DIR/default-rc"
        mode: "0644"
      vars:
        pnpm_minimum_release_age_exclude: []
        pnpm_built_dependencies: []
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/pnpm-config.yaml.j2
        dest: "$RENDER_DIR/default-config.yaml"
        mode: "0644"
      vars:
        pnpm_minimum_release_age_exclude: []
    # Build-script allowlist set (the pnpm <= 10 path: ignore-scripts flips false).
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/pnpm-rc.j2
        dest: "$RENDER_DIR/allow-rc"
        mode: "0644"
      vars:
        pnpm_minimum_release_age_exclude: []
        pnpm_built_dependencies: ["esbuild"]
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/pnpm-config.yaml.j2
        dest: "$RENDER_DIR/allow-config.yaml"
        mode: "0644"
      vars:
        pnpm_minimum_release_age_exclude: ["@myorg/internal"]
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
}

teardown_file() {
  rm -rf "$RENDER_DIR"
}

assert_valid_yaml() {
  # Prefer python's yaml (present in the test image via ansible's PyYAML dep);
  # fall back to ruby's YAML so the check still runs anywhere PyYAML is absent.
  if python3 -c "import yaml" 2>/dev/null; then
    python3 -c "import yaml; yaml.safe_load(open('$1'))" \
      || { echo "FAIL: $1 is not valid YAML (python)" >&2; cat "$1" >&2; return 1; }
  else
    ruby -ryaml -e "YAML.load_file(ARGV[0])" "$1" \
      || { echo "FAIL: $1 is not valid YAML (ruby)" >&2; cat "$1" >&2; return 1; }
  fi
}

# Run the role's pnpm.yml with the given JSON extra-vars, capturing combined
# output and the ansible exit code. Loaded via include_role (not import_tasks)
# so the role context is set up and pnpm.yml's relative template `src`
# (pnpm-rc.j2, pnpm-config.yaml.j2) resolves. XDG_CONFIG_HOME points at a
# throwaway dir so config files written on the success path never touch the
# host's real ~/.config/pnpm.
run_pnpm_task() {
  local xdg role_parent role_name playbook rc
  xdg=$(mktemp -d)
  role_parent="$(dirname "$ROLE_DIR")"
  role_name="$(basename "$ROLE_DIR")"
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: true
  vars:
    pnpm_minimum_release_age_minutes: 2880
    pnpm_minimum_release_age_strict: true
    pnpm_minimum_release_age_exclude: []
    pnpm_built_dependencies: []
    pnpm_verify_store_integrity: true
    pnpm_prefer_frozen_lockfile: true
    pnpm_allowlist_conflict_action: "fail"
  tasks:
    - include_role:
        name: $role_name
        tasks_from: pnpm
EOF
  XDG_CONFIG_HOME="$xdg" ANSIBLE_ROLES_PATH="$role_parent" ansible-playbook "$playbook" -e "$1" 2>&1
  rc=$?
  rm -rf "$xdg"
  rm -f "$playbook"
  return $rc
}

# ---- render: integrity + lockfile keys on the DEFAULT (fully-locked) path ----

@test "render(default): rc is fully locked (ignore-scripts=true)" {
  grep -q "^ignore-scripts=true$" "$RENDER_DIR/default-rc"
}

@test "render(default): rc has verify-store-integrity=true" {
  grep -q "^verify-store-integrity=true$" "$RENDER_DIR/default-rc"
}

@test "render(default): rc has prefer-frozen-lockfile=true (no hard-freeze)" {
  grep -q "^prefer-frozen-lockfile=true$" "$RENDER_DIR/default-rc"
}

@test "render(default): config.yaml is valid YAML with integrity + lockfile + strict keys" {
  assert_valid_yaml "$RENDER_DIR/default-config.yaml"
  grep -q "^ignoreScripts: true$" "$RENDER_DIR/default-config.yaml"
  grep -q "^verifyStoreIntegrity: true$" "$RENDER_DIR/default-config.yaml"
  grep -q "^preferFrozenLockfile: true$" "$RENDER_DIR/default-config.yaml"
}

# ---- render: allowlist set — ignore-scripts flips, integrity keys survive ----

@test "render(allowlist): rc flips ignore-scripts=false and names the allowlisted pkg" {
  grep -q "^ignore-scripts=false$" "$RENDER_DIR/allow-rc"
  grep -q "^only-built-dependencies\[\]=esbuild$" "$RENDER_DIR/allow-rc"
}

@test "render(allowlist): integrity + lockfile keys still present in the allowlist branch" {
  # Regression guard: the allowlist branch must not drop the always-on keys.
  grep -q "^verify-store-integrity=true$" "$RENDER_DIR/allow-rc"
  grep -q "^prefer-frozen-lockfile=true$" "$RENDER_DIR/allow-rc"
}

@test "render(allowlist): config.yaml stays strict (pnpm 11 allowlists per-project) and valid" {
  assert_valid_yaml "$RENDER_DIR/allow-config.yaml"
  grep -q "^ignoreScripts: true$" "$RENDER_DIR/allow-config.yaml"
  grep -q "^verifyStoreIntegrity: true$" "$RENDER_DIR/allow-config.yaml"
}

# ---- behavior: doubly-exempt guard (pnpm_allowlist_conflict_action) ----

@test "guard: same pkg on both lists + action=fail → apply fails, names the pkg" {
  run run_pnpm_task '{"pnpm_built_dependencies":["esbuild"],"pnpm_minimum_release_age_exclude":["esbuild"],"pnpm_allowlist_conflict_action":"fail"}'
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "esbuild"
  echo "$output" | grep -qi "both"
}

@test "guard: same pkg on both lists + action=warn → apply succeeds with a warning" {
  run run_pnpm_task '{"pnpm_built_dependencies":["esbuild"],"pnpm_minimum_release_age_exclude":["esbuild"],"pnpm_allowlist_conflict_action":"warn"}'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "WARNING"
  echo "$output" | grep -q "esbuild"
}

@test "guard: no overlap (scripts for one pkg, age-exclude another) → apply succeeds" {
  run run_pnpm_task '{"pnpm_built_dependencies":["esbuild"],"pnpm_minimum_release_age_exclude":["@myorg/internal"],"pnpm_allowlist_conflict_action":"fail"}'
  [ "$status" -eq 0 ]
}

@test "guard: invalid action value → apply fails fast" {
  run run_pnpm_task '{"pnpm_allowlist_conflict_action":"bogus"}'
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "must be 'fail' or 'warn'"
}

# ---- behavior: exemption report ----

@test "report: exemptions listed when an allowlist is non-empty" {
  run run_pnpm_task '{"pnpm_built_dependencies":["esbuild"]}'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "exemptions active"
  echo "$output" | grep -q "esbuild"
}

@test "report: silent on the default (fully-locked) path" {
  run run_pnpm_task '{}'
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "exemptions active"
}
