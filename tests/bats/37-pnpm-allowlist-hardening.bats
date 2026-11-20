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

# This file renders role templates and includes the role, so it needs ROLE_DIR.
# The shared setup.bash exports it on some branches but not others (it isn't on
# main's base), so resolve it here to keep this file self-sufficient.
if [ -z "${ROLE_DIR:-}" ]; then
  if [ -d /opt/ansible-supply-chain-security ]; then
    ROLE_DIR=/opt/ansible-supply-chain-security
  else
    ROLE_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  fi
  export ROLE_DIR
fi

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
    pnpm_prefer_frozen_lockfile: null
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
        pnpm_built_dependencies: []
    # Build-script allowlist set: ignore-scripts flips false in BOTH files.
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
        pnpm_built_dependencies: ["esbuild"]
    # Explicit opt-in: an operator who sets the variable still gets the key.
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/pnpm-rc.j2
        dest: "$RENDER_DIR/optin-rc"
        mode: "0644"
      vars:
        pnpm_minimum_release_age_exclude: []
        pnpm_built_dependencies: []
        pnpm_prefer_frozen_lockfile: true
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/pnpm-config.yaml.j2
        dest: "$RENDER_DIR/optin-config.yaml"
        mode: "0644"
      vars:
        pnpm_minimum_release_age_exclude: []
        pnpm_prefer_frozen_lockfile: true
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
    pnpm_prefer_frozen_lockfile: null
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

@test "render(default): rc does NOT write prefer-frozen-lockfile (it would turn off pnpm's CI freeze)" {
  ! grep -q "prefer-frozen-lockfile" "$RENDER_DIR/default-rc"
}

@test "render(opt-in): an explicit pnpm_prefer_frozen_lockfile is still written, in both files" {
  grep -q "^prefer-frozen-lockfile=true$" "$RENDER_DIR/optin-rc"
  assert_valid_yaml "$RENDER_DIR/optin-config.yaml"
  grep -q "^preferFrozenLockfile: true$" "$RENDER_DIR/optin-config.yaml"
}

@test "render(default): config.yaml is valid YAML with integrity + lockfile + strict keys" {
  assert_valid_yaml "$RENDER_DIR/default-config.yaml"
  grep -q "^ignoreScripts: true$" "$RENDER_DIR/default-config.yaml"
  grep -q "^verifyStoreIntegrity: true$" "$RENDER_DIR/default-config.yaml"
  ! grep -q "preferFrozenLockfile" "$RENDER_DIR/default-config.yaml"
}

# ---- render: allowlist set — ignore-scripts flips, integrity keys survive ----

@test "render(allowlist): rc flips ignore-scripts=false and names the allowlisted pkg" {
  grep -q "^ignore-scripts=false$" "$RENDER_DIR/allow-rc"
  grep -q "^only-built-dependencies\[\]=esbuild$" "$RENDER_DIR/allow-rc"
}

@test "render(allowlist): integrity + lockfile keys still present in the allowlist branch" {
  # Regression guard: the allowlist branch must not drop the always-on keys.
  grep -q "^verify-store-integrity=true$" "$RENDER_DIR/allow-rc"
  ! grep -q "prefer-frozen-lockfile" "$RENDER_DIR/allow-rc"
}

@test "render(allowlist): config.yaml flips ignoreScripts: false like the rc and the action, and stays valid" {
  # pnpm 11+ has no global allowlist; a project names its builds in allowBuilds.
  # MEASURED on 11.28.12 / 12.21.0: under a global ignoreScripts: true that
  # allowBuilds is silently inert (rc=0, the approved postinstall never runs).
  # The role kept true here while its rc and the action flipped to false, so an
  # operator who set pnpm_built_dependencies got no approved build on pnpm 11+.
  assert_valid_yaml "$RENDER_DIR/allow-config.yaml"
  grep -q "^ignoreScripts: false$" "$RENDER_DIR/allow-config.yaml"
  [ "$(grep -c "^ignoreScripts" "$RENDER_DIR/allow-config.yaml")" = 1 ]
  # The names are NOT written: pnpm 11 rejects onlyBuiltDependencies here.
  [ "$(grep -v '^#' "$RENDER_DIR/allow-config.yaml" | grep -ci "esbuild")" = 0 ]
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

# ---- behavior: pnpm 11+ build approval under the role's rendered config.yaml ----
#
# pnpm 11+ has no global allowlist; a project approves builds with allowBuilds
# in its pnpm-workspace.yaml. MEASURED on 11.28.12 and 12.21.0:
#   global ignoreScripts: true  -> allowBuilds is silently inert (rc=0, nothing runs)
#   global ignoreScripts: false -> the named dependency builds; any other is
#                                  refused with ERR_PNPM_IGNORED_BUILDS (rc=1)
# These run real pnpm against the config.yaml renders from setup_file, with
# XDG_CONFIG_HOME pointing at a throwaway dir so the host's own config is not
# read. The fixture is a local directory dependency, so no network is needed;
# pnpm keys a `file:` dependency's approval as <name>@file:<path> (MEASURED).

pnpm11_or_skip() {
  local major
  major=$(pnpm --version 2>/dev/null | sed -nE 's/^([0-9]+)\..*/\1/p' | head -1)
  [[ "$major" =~ ^[0-9]+$ ]] || skip "couldn't parse pnpm major version"
  [ "$major" -ge 11 ] || skip "allowBuilds is the pnpm >= 11 mechanism (got: $(pnpm --version 2>/dev/null))"
}

# make_build_project <dir> [pnpm-workspace.yaml content]
make_build_project() {
  mkdir -p "$1/dep"
  cat > "$1/dep/package.json" <<'JSON'
{"name":"sch-build-fixture","version":"1.0.0","scripts":{"postinstall":"node -e \"require('fs').writeFileSync(process.env.SCH_MARK,'x')\""}}
JSON
  echo '{"name":"victim","version":"1.0.0","dependencies":{"sch-build-fixture":"file:./dep"}}' > "$1/package.json"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$1/pnpm-workspace.yaml"; fi
}

# pnpm_install_with <rendered config.yaml> <project dir>  (sets $status / $output)
pnpm_install_with() {
  local xdg="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$xdg/pnpm"
  cp "$1" "$xdg/pnpm/config.yaml"
  cd "$2"
  run env XDG_CONFIG_HOME="$xdg" SCH_MARK="$2/marker" \
    pnpm install --store-dir "$BATS_TEST_TMPDIR/store"
}

ALLOW_FIXTURE=$'allowBuilds:\n  \'sch-build-fixture@file:dep\': true'

@test "pnpm 11+: with pnpm_built_dependencies set, a project's allowBuilds runs its approved build" {
  # The bug: the role wrote ignoreScripts: true here regardless of the list,
  # while its rc and the action wrote false, so this build silently never ran.
  pnpm11_or_skip
  p="$BATS_TEST_TMPDIR/proj"; make_build_project "$p" "$ALLOW_FIXTURE"
  pnpm_install_with "$RENDER_DIR/allow-config.yaml" "$p"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$p/marker" ]
}

@test "pnpm 11+: with pnpm_built_dependencies set, a build the project did not approve is refused loudly" {
  pnpm11_or_skip
  p="$BATS_TEST_TMPDIR/proj"; make_build_project "$p"
  pnpm_install_with "$RENDER_DIR/allow-config.yaml" "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERR_PNPM_IGNORED_BUILDS"* ]]
  [ ! -f "$p/marker" ]
}

@test "pnpm 11+: default config, the documented per-project route (ignoreScripts: false + allowBuilds) runs the build" {
  # defaults/main.yml tells pnpm 11+ users to put BOTH lines in the project.
  pnpm11_or_skip
  p="$BATS_TEST_TMPDIR/proj"; make_build_project "$p" "ignoreScripts: false
$ALLOW_FIXTURE"
  pnpm_install_with "$RENDER_DIR/default-config.yaml" "$p"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$p/marker" ]
}

@test "pnpm 11+: default config, allowBuilds alone runs nothing (why the docs ask for both lines)" {
  # Pins the measured behaviour the docs rest on. If a pnpm release starts
  # honouring allowBuilds under a global ignoreScripts: true, this fails and the
  # advice in defaults/main.yml and docs/limitations.md needs revisiting.
  pnpm11_or_skip
  p="$BATS_TEST_TMPDIR/proj"; make_build_project "$p" "$ALLOW_FIXTURE"
  pnpm_install_with "$RENDER_DIR/default-config.yaml" "$p"
  [ "$status" -eq 0 ]
  [ ! -f "$p/marker" ]
}
