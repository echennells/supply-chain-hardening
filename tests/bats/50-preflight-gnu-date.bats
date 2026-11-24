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

# --- a macOS target ----------------------------------------------------------
#
# MEASURED on hosted macos-15: with GNU date on the controller's PATH, or the
# cutoff pinned as the message above said, the role replaced ~/.npmrc, wrote
# /etc/npmrc and died on its group ("failed to look up group root"), with nothing
# after it applied. An extra var outranks a gathered fact, so it stands in for a
# Mac here; the real one is in .github/workflows/macos.yml.

@test "macOS preflight: a macOS target is refused first, with nothing escalated and the script to use instead" {
  local extra
  for extra in "" "-e uv_exclude_newer=2026-05-24T12:00:00Z" "-e skip_gnu_date_check=true"; do
    # shellcheck disable=SC2086  # an empty $extra is no argument
    run run_pf gnu gnu -e ansible_system=Darwin $extra
    [ "$status" -ne 0 ] || { echo "$extra: not refused"; return 1; }
    echo "$output" | grep -q 'this role supports Linux'
    echo "$output" | grep -q 'action/harden.sh --emit=plain'
    # It is the first task: none of the checks below it ran, the sudo ones included.
    [ "$(echo "$output" | grep -c '^TASK \[')" -le 2 ] || { echo "$output" | grep '^TASK \['; return 1; }
    [[ "$output" != *"Detect non-managed existing system config files"* ]]
  done
}

@test "macOS preflight: the whole role changes nothing on a macOS target" {
  require_root "applies the role"
  local before after f
  snap() { for f in "$HOME/.npmrc" /etc/npmrc /etc/profile.d/supply-chain-hardening.sh /etc/environment; do stat -c '%n %Y %s' "$f" 2>/dev/null; done; }
  before=$(snap)
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost -e ansible_system=Darwin -e accept_etc_overwrite=true
  [ "$status" -ne 0 ]
  [[ "$output" == *"this role supports Linux"* ]]
  [[ "$output" == *"changed=0"* ]] || { echo "$output" | tail -5; return 1; }
  after=$(snap)
  [ "$before" = "$after" ]
}

@test "macOS preflight: a Linux target is not refused, whatever the controller's date is" {
  run run_pf bsd gnu -e uv_exclude_newer=2026-05-24T12:00:00Z
  [ "$status" -eq 0 ]
  [[ "$output" != *"this role supports Linux"* ]]
}
