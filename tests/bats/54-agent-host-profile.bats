#!/usr/bin/env bats
# agent_host: one switch for a host whose job is running agents in repositories
# nobody vetted. It is the DEFAULT of verify_fail_on_gap, python_safe_path and
# uv_exclude_newer_env (defaults/main.yml), so it turns all three on, and an
# explicit value of any one of them wins wherever it is set, because a role
# default is the lowest precedence Ansible has.
#
# Measured here with the role's real defaults loaded the way a run loads them
# (include_role, tasks_from the summary task file), not with vars_files, which
# sits at a different precedence level and would prove nothing about this.

load setup

RUN_DIR=/tmp/agent-host-profile

setup_file() {
  rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
  command -v ansible-playbook >/dev/null 2>&1 || return 0
  cat > "$RUN_DIR/pb.yml" <<'YML'
- hosts: all
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.setup: { gather_subset: [min] }
    - ansible.builtin.include_role:
        name: "{{ role_dir }}"
        tasks_from: agent_profile.yml
        public: true
    - ansible.builtin.template:
        src: "{{ role_dir }}/templates/supply-chain-env.sh.j2"
        dest: "{{ out }}/env.sh"
    - ansible.builtin.debug:
        msg: "RESOLVED verify_fail_on_gap={{ verify_fail_on_gap | bool }} python_safe_path={{ python_safe_path | bool }} uv_exclude_newer_env={{ uv_exclude_newer_env | bool }}"
YML
  # Play vars: a level above role defaults and below extra vars.
  sed 's/^  gather_facts: false$/  gather_facts: false\n  vars: { agent_host: true, verify_fail_on_gap: false }/' \
    "$RUN_DIR/pb.yml" > "$RUN_DIR/pb-playvars.yml"
  # Inventory host vars.
  printf 'all:\n  hosts:\n    localhost:\n      ansible_connection: local\n      agent_host: true\n      uv_exclude_newer_env: false\n' \
    > "$RUN_DIR/inv.yml"
}

# profile <name> <playbook> [ansible args...]: run it, keep the log and the
# rendered env file under $RUN_DIR/<name>.
profile() {
  local name="$1" pb="$2"; shift 2
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible-playbook not installed"
  mkdir -p "$RUN_DIR/$name"
  ansible-playbook "$RUN_DIR/$pb" -e "role_dir=$ROLE_DIR" -e "out=$RUN_DIR/$name" "$@" \
    </dev/null > "$RUN_DIR/$name/log" 2>&1 || { cat "$RUN_DIR/$name/log"; return 1; }
}
resolved() { grep -o 'RESOLVED [^"]*' "$RUN_DIR/$1/log"; }
summary() { grep -o 'agent host profile: [^"]*' "$RUN_DIR/$1/log"; }

@test "agent_host: off by default, and the summary says so" {
  profile off pb.yml -i localhost,
  [ "$(resolved off)" = "RESOLVED verify_fail_on_gap=False python_safe_path=False uv_exclude_newer_env=False" ]
  [[ "$(summary off)" == "agent host profile: off (agent_host=false): verify_fail_on_gap=false, python_safe_path=false, uv_exclude_newer_env=false."* ]]
  ! grep -q 'PYTHONSAFEPATH' "$RUN_DIR/off/env.sh" || false
  ! grep -q '^export UV_EXCLUDE_NEWER=' "$RUN_DIR/off/env.sh"
}

@test "agent_host=true turns on all three, the env layer carries both variables, and the summary names what breaks" {
  profile on pb.yml -i localhost, -e agent_host=true
  [ "$(resolved on)" = "RESOLVED verify_fail_on_gap=True python_safe_path=True uv_exclude_newer_env=True" ]
  local s; s=$(summary on)
  [[ "$s" == "agent host profile: on (agent_host=true): verify_fail_on_gap=true, python_safe_path=true, uv_exclude_newer_env=true."* ]]
  [[ "$s" == *'`python script.py` cannot import a file next to it'* ]]
  [[ "$s" == *'`python -m` of a local package fails'* ]]
  [[ "$s" == *'fails `uv sync --locked`'* ]]
  [[ "$s" != *"set explicitly"* ]]
  grep -qx 'export PYTHONSAFEPATH=1' "$RUN_DIR/on/env.sh"
  grep -qE '^export UV_EXCLUDE_NEWER=[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00Z$' "$RUN_DIR/on/env.sh"
}

@test "agent_host: an explicit value wins as an extra var, and the summary marks it" {
  profile ev pb.yml -i localhost, -e agent_host=true -e python_safe_path=false
  [ "$(resolved ev)" = "RESOLVED verify_fail_on_gap=True python_safe_path=False uv_exclude_newer_env=True" ]
  [[ "$(summary ev)" == *"python_safe_path=false (set explicitly)"* ]]
  ! grep -q 'PYTHONSAFEPATH' "$RUN_DIR/ev/env.sh" || false
  grep -q '^export UV_EXCLUDE_NEWER=' "$RUN_DIR/ev/env.sh"
}

@test "agent_host: an explicit value wins in play vars and in inventory host vars" {
  profile pv pb-playvars.yml -i localhost,
  [ "$(resolved pv)" = "RESOLVED verify_fail_on_gap=False python_safe_path=True uv_exclude_newer_env=True" ]
  [[ "$(summary pv)" == *"verify_fail_on_gap=false (set explicitly)"* ]]
  profile inv pb.yml -i "$RUN_DIR/inv.yml"
  [ "$(resolved inv)" = "RESOLVED verify_fail_on_gap=True python_safe_path=True uv_exclude_newer_env=False" ]
  [[ "$(summary inv)" == *"uv_exclude_newer_env=false (set explicitly)"* ]]
  ! grep -q '^export UV_EXCLUDE_NEWER=' "$RUN_DIR/inv/env.sh"
}

@test "agent_host: one setting turned on alone is reported, with the profile off" {
  profile one pb.yml -i localhost, -e python_safe_path=true
  [ "$(resolved one)" = "RESOLVED verify_fail_on_gap=False python_safe_path=True uv_exclude_newer_env=False" ]
  [[ "$(summary one)" == "agent host profile: off (agent_host=false): verify_fail_on_gap=false, python_safe_path=true (set explicitly), uv_exclude_newer_env=false."* ]]
}

@test "agent_host: the image's own apply printed the profile in its summary" {
  [ -f /var/log/ansible-run.log ] || skip "no apply log (not the test image)"
  grep -q 'agent host profile: off (agent_host=false)' /var/log/ansible-run.log
}
