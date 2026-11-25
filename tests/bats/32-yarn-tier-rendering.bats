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

teardown() {
  local d
  [ -f "$BATS_TEST_TMPDIR/roothome" ] || return 0
  d=$(cat "$BATS_TEST_TMPDIR/roothome")
  case "$d" in /etc/sch-roothome.??????) rm -rf -- "$d" ;; esac
}

assert_valid_yaml() {
  python3 -c "import yaml,sys; yaml.safe_load(open('$1'))" \
    || { echo "FAIL: $1 is not valid YAML" >&2; cat "$1" >&2; return 1; }
}

assert_has_baseline() {
  local f="$1"
  # approvedGitRepositories is deliberately NOT in this list: yarn 4.10.3
  # rejects the key outright ("Usage Error: Unrecognized or legacy
  # configuration settings found"), which hard-fails EVERY yarn command.
  # See the inverted assertion in 01-config-files.bats.
  for key in npmMinimalAgeGate enableScripts enableImmutableInstalls enableImmutableCache checksumBehavior unsafeHttpWhitelist; do
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

# The role's "NOT applied" summary used to say nothing about yarn on a host
# whose yarn cannot enforce the age gate (VM#10: apt yarnpkg 4.1.0 on Debian 13
# and Ubuntu 26.04). This runs the REAL task from tasks/yarn.yml, lifted out by
# name so nothing else in that file (the ~/.yarnrc.yml writes for this user and
# root) touches this container, at fixed yarn_detected_version inputs.
yarn_skip_entries() { # <yarn_detected_version> -> skipped_protections, one per line
  local dir task play out
  dir=$(mktemp -d)
  task="$dir/task.json"; play="$dir/play.yml"; out="$dir/out.txt"
  python3 - "$ROLE_DIR/tasks/yarn.yml" "$task" <<'PY'
import json, sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
t = [t for t in tasks if t.get("name", "").startswith("Record skipped protection")]
assert len(t) == 1, "expected exactly one skip-recording task in tasks/yarn.yml"
json.dump(t, open(sys.argv[2], "w"))
PY
  cat > "$play" <<PLAY
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    yarn_detected_version: "$1"
  tasks:
    - ansible.builtin.include_tasks: $task
    - ansible.builtin.copy:
        content: "{{ (skipped_protections | default([])) | join('\n') }}\n"
        dest: $out
        mode: "0644"
PLAY
  ansible-playbook "$play" >/dev/null 2>&1 || { echo "playbook failed for '$1'" >&2; rm -rf "$dir"; return 1; }
  cat "$out"; rm -rf "$dir"
}

@test "skip report: yarn below 4.10 is listed as an inert age gate" {
  run yarn_skip_entries 4.1.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"Yarn publish-age gate"*"yarn 4.1.0"*"4.10.0"* ]]
  run yarn_skip_entries 4.9.4
  [[ "$output" == *"Yarn publish-age gate"*"yarn 4.9.4"* ]]
}

@test "skip report: yarn classic is listed as not reading .yarnrc.yml at all" {
  run yarn_skip_entries 1.22.22
  [ "$status" -eq 0 ]
  [[ "$output" == *"Yarn hardening"*"1.22.22"*"never"*"reads .yarnrc.yml"* ]]
}

@test "skip report: yarn 4.10+ and an undetected yarn add nothing" {
  local v
  for v in 4.10.0 4.11.0 5.0.0 ""; do
    run yarn_skip_entries "$v"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Yarn"* ]] || { echo "unexpected entry for '$v': $output"; return 1; }
  done
}

# Root's ~/.yarnrc.yml is what `sudo yarn` reads (HOME=/root), so the role
# writes it now that it no longer writes /etc/yarnrc.yml, which Yarn never
# reads. Unlike that file, root's is in use, and may hold root's registry and
# npmAuthToken. The REAL two tasks from tasks/yarn.yml, lifted by name, run
# with root's home pointed at a temp dir and the deploying user's home
# elsewhere (the container runs the role as root, where the two are one file
# and these tasks stand aside). `become` is dropped: the suite runs as root.
yarn_root_rc_play() { # <fake root home> <deploying user's HOME> -> summary entries
  local dir task play out
  dir=$(mktemp -d)
  task="$dir/task.json"; play="$dir/play.yml"; out="$dir/out.txt"
  python3 - "$ROLE_DIR/tasks/yarn.yml" "$task" "$ROLE_DIR" <<'PY'
import json, sys, yaml
want = ["Deploy hardened .yarnrc.yml to root's home (sudo coverage)",
        "Add root's own ~/.yarnrc.yml to the not-applied summary (sudo coverage)"]
tasks = {t.get("name"): t for t in yaml.safe_load(open(sys.argv[1]))}
lifted = []
for n in want:
    assert n in tasks, "task not found in tasks/yarn.yml: " + n
    t = dict(tasks[n]); t.pop("become", None)
    if "environment" in t:
        c = dict(t["ansible.builtin.command"])
        c["stdin"] = c["stdin"].replace("'user-config.sh'", "'" + sys.argv[3] + "/files/user-config.sh'")
        t["ansible.builtin.command"] = c
        t["environment"] = {k: v.replace("'yarnrc.yml.j2'", "'" + sys.argv[3] + "/templates/yarnrc.yml.j2'")
                            for k, v in t["environment"].items()}
    lifted.append(t)
json.dump(lifted, open(sys.argv[2], "w"))
PY
  cat > "$play" <<PLAY
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    yarn_root_home: { stdout: "$1" }
    ansible_env: { HOME: "$2" }
    yarn_detected_version: "4.11.0"
    yarn_minimal_age_gate: 2880
    yarn_enable_scripts: false
    yarn_enable_immutable_installs: true
    yarn_enable_immutable_cache: false
    yarn_checksum_behavior: "throw"
    yarn_unsafe_http_whitelist: []
    yarn_approved_git_repositories: []
    yarn_enable_hardened_mode: true
  tasks:
    - ansible.builtin.include_tasks: $task
    - ansible.builtin.copy:
        content: "{{ (skipped_protections | default([])) | join('\n') }}\n"
        dest: $out
        mode: "0644"
PLAY
  ansible-playbook "$play" >"$dir/log" 2>&1 || { echo "playbook failed:" >&2; tail -20 "$dir/log" >&2; rm -rf "$dir"; return 1; }
  cat "$out"; rm -rf "$dir"
}

@test "root's ~/.yarnrc.yml: one this project did not write is left alone and listed; absent or ours, it is written" {
  require_root "renders a root-owned file"
  # Root's home is a directory no other account controls; in /tmp it would not be.
  local r u="$BATS_TEST_TMPDIR/deployer"
  r=$(mktemp -d /etc/sch-roothome.XXXXXX)
  echo "$r" > "$BATS_TEST_TMPDIR/roothome"
  mkdir -p "$u"
  # Root's own file: a registry and its token.
  printf 'npmRegistryServer: "https://npm.corp.invalid"\nnpmAuthToken: "tok"\n' > "$r/.yarnrc.yml"
  cp "$r/.yarnrc.yml" "$BATS_TEST_TMPDIR/before"
  run yarn_root_rc_play "$r" "$u"
  [ "$status" -eq 0 ]
  cmp "$r/.yarnrc.yml" "$BATS_TEST_TMPDIR/before"
  [[ "$output" == *"Yarn sudo coverage — $r/.yarnrc.yml exists and is not exactly what this project last wrote"* ]]
  # A file with this project's marker (an older rendering) is rewritten.
  printf '# Managed by supply-chain-harden action\nenableScripts: true\n' > "$r/.yarnrc.yml"
  run yarn_root_rc_play "$r" "$u"
  [ "$status" -eq 0 ]
  grep -qx 'enableScripts: false' "$r/.yarnrc.yml"
  grep -qx 'npmMinimalAgeGate: 2880' "$r/.yarnrc.yml"
  [[ "$output" != *"Yarn sudo coverage"* ]]
  # A token added to it since is root's, marker or no marker: left alone, listed.
  echo 'npmAuthToken: "tok"' >> "$r/.yarnrc.yml"
  cp "$r/.yarnrc.yml" "$BATS_TEST_TMPDIR/before"
  run yarn_root_rc_play "$r" "$u"
  [ "$status" -eq 0 ]
  cmp "$r/.yarnrc.yml" "$BATS_TEST_TMPDIR/before"
  [[ "$output" == *"Yarn sudo coverage — $r/.yarnrc.yml exists and is not exactly"* ]]
  # One that cannot be written is listed too, and does not stop the play.
  rm -f "$r/.yarnrc.yml"; mkdir "$r/.yarnrc.yml"
  run yarn_root_rc_play "$r" "$u"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Yarn sudo coverage — $r/.yarnrc.yml could not be written: "*"is not a regular file"* ]] || { echo "$output"; return 1; }
  # So is one that leads to what other accounts can write.
  rmdir "$r/.yarnrc.yml"; ln -s /dev/null "$r/.yarnrc.yml"
  run yarn_root_rc_play "$r" "$u"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Yarn sudo coverage — $r/.yarnrc.yml could not be written: "*"root writes only to paths no other account controls"* ]] || { echo "$output"; return 1; }
  [ -c /dev/null ]
  # None at all: written.
  rm -f "$r/.yarnrc.yml"
  run yarn_root_rc_play "$r" "$u"
  [ "$status" -eq 0 ]
  grep -qx 'enableScripts: false' "$r/.yarnrc.yml"
  [[ "$output" != *"Yarn sudo coverage"* ]]
  # The role run as root: root's home is the deploying user's, whose
  # ~/.yarnrc.yml the role writes as it always has, so these tasks stand
  # aside and report nothing.
  printf 'npmRegistryServer: "https://npm.corp.invalid"\n' > "$r/.yarnrc.yml"
  cp "$r/.yarnrc.yml" "$BATS_TEST_TMPDIR/before"
  run yarn_root_rc_play "$r" "$r"
  [ "$status" -eq 0 ]
  cmp "$r/.yarnrc.yml" "$BATS_TEST_TMPDIR/before"
  [[ "$output" != *"Yarn sudo coverage"* ]]
}
