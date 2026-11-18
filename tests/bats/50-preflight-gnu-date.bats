#!/usr/bin/env bats
# Pre-flight GNU date probe: it must test the machine that computes the cutoff.
#
# The rolling uv/pip cutoff is rendered by lookup('pipe', 'date -u -d @...'),
# which runs on the CONTROLLER. The probe used to be a command task, which runs
# on the TARGET, so for any remote apply it tested the wrong machine:
#   - a non-GNU target was refused although nothing ran date on it;
#   - a non-GNU controller passed, then the play died at render with a bare
#     "lookup_plugin.pipe(...) returned 1" instead of the fix instructions;
#   - pinning uv_exclude_newer, the fix the message itself recommends, did not
#     get past the check.
#
# Controller and target are the same box here, so they are told apart by PATH:
# the play's `environment:` reaches the target's commands but never a lookup,
# and the PATH ansible-playbook is started with is the controller's. A stub
# `date` that refuses `-d` stands in for BSD date.

load setup

PB=/tmp/pf-gnu-date.yml

setup_file() {
  local stub=/tmp/pf-bsd-date
  mkdir -p "$stub"
  cat > "$stub/date" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -d*) echo "date: illegal option -- d" >&2; exit 1;; esac; done
exec /bin/date "$@"
EOF
  chmod 755 "$stub/date"
  cat > "$PB" <<EOF
- hosts: localhost
  connection: local
  environment:
    PATH: "{{ target_path | default(lookup('env', 'PATH')) }}"
  vars:
    release_age_hours: 48
  tasks:
    - ansible.builtin.include_vars: $ROLE_DIR/defaults/main.yml
    - ansible.builtin.import_tasks: $ROLE_DIR/tasks/preflight.yml
    - ansible.builtin.debug:
        msg: "CUTOFF={{ sch_uv_cutoff }} PIP={{ sch_pip_cutoff }}"
EOF
}

teardown_file() {
  rm -rf "$PB" /tmp/pf-bsd-date
}

# run_pf <controller: gnu|bsd> <target: gnu|bsd> [ansible-playbook args...]
run_pf() {
  local ctl="$1" tgt="$2"; shift 2
  local ctl_path="$PATH" tgt_path="/usr/local/bin:/usr/bin:/bin"
  [ "$ctl" = bsd ] && ctl_path="/tmp/pf-bsd-date:$PATH"
  [ "$tgt" = bsd ] && tgt_path="/tmp/pf-bsd-date:$tgt_path"
  (cd /tmp && PATH="$ctl_path" ansible-playbook -i localhost, "$PB" \
     -e "target_path=$tgt_path" "$@" 2>&1)
}

@test "gnu-date preflight: a non-GNU TARGET is not refused (the lookup never runs there)" {
  run run_pf gnu bsd
  [ "$status" -eq 0 ]
  [[ "$output" != *"refused the probe"* ]]
  echo "$output" | grep -qE 'CUTOFF=[0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00Z'
}

@test "gnu-date preflight: a non-GNU CONTROLLER fails at preflight with the fix, not at render" {
  run run_pf bsd gnu
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "refused the probe"
  echo "$output" | grep -q "illegal option"
  [[ "$output" != *"lookup_plugin.pipe"* ]]
}

@test "gnu-date preflight: pinning uv_exclude_newer (the message's advice) gets past it" {
  run run_pf bsd bsd -e uv_exclude_newer=2026-05-24T12:00:00Z
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CUTOFF=2026-05-24T12:00:00Z PIP=2026-05-24T12:00:00Z"
}

@test "gnu-date preflight: a rolling pip cutoff still needs it when only uv is pinned" {
  run run_pf bsd gnu -e uv_exclude_newer=2026-05-24T12:00:00Z -e pip_uploaded_prior_to=rolling
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "refused the probe"
}
