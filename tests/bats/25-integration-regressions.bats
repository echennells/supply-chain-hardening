#!/usr/bin/env bats
# Integration & regression tests for bugs the existing per-file tests
# wouldn't catch on their own:
#
#   - Tool-install tasks aborting the whole play because of PATH /
#     toolchain edge cases (H1, H2, H3 from the May 2026 review).
#   - Pre-flight validation behaviors that aren't exercised by normal
#     "run-once-then-assert-config-content" tests.
#   - Idempotency: the role re-applies cleanly with no spurious
#     changed=N. A failed task in the middle of the play silently
#     breaks idempotency for everything after it.
#
# These tests run inside the existing test container against the role
# that was already applied at build time. Tests that re-run the playbook
# do so as a fresh ansible-playbook invocation; the build-time apply
# captured in /var/log/ansible-run.log isn't disturbed.

load setup

# ROLE_DIR is autodetected by setup.bash and works in both the Docker test
# image and any local clone. Do not hardcode the Docker path here — it
# silently breaks every test below when bats is run outside Docker.

# ---- Structural regression catchers (H1, H2, H3) ----
#
# These grep the task YAML for the specific pattern that fixed each bug.
# They're cheap, fast, and catch the exact form of regression that would
# re-introduce the bug — someone "simplifying" the task back to bare
# `uv tool install` or dropping the `environment:` block on the go install.

# Helper note for the four tests below: we extract a window of lines
# starting at the task header and capture enough lines to span the
# task body (cmd:, environment:, creates:, comment block, etc.).
# An earlier version used awk '/start/,/^- name:/' but that pattern
# matches BOTH start AND end on the same `- name: ...` line and
# returns just one line. Using grep -A with a generous N is simpler
# and immune to the awk same-line-range trap.

@test "H1 regression catcher: tasks/uv.yml uses absolute uv path for tool install" {
  # Bug: bare `uv tool install` exits 127 when ~/.local/bin isn't on
  # ansible's PATH (uv installer's default install location). Fix uses
  # the absolute path we already discover via uv_binary_path.
  task_file="${ROLE_DIR}/tasks/uv.yml"
  grep -A 25 'name: Install uv-managed tools' "$task_file" \
    | grep -qE 'cmd:.*\{\{ *uv_binary_path\.stdout *\}\} tool install'
}

@test "H2 regression catcher: tasks/github.yml uses absolute uv path for zizmor install" {
  task_file="${ROLE_DIR}/tasks/github.yml"
  grep -A 15 'name: Install zizmor' "$task_file" \
    | grep -qE 'cmd:.*\{\{ *uv_for_github\.stdout *\}\} tool install zizmor'
}

# Extract one task block: from its `- name:` line to the next top-level
# `- name:`. Structural, so it cannot be broken by editing comments.
#
# Both catchers below used `grep -A <n>` instead. When 8edfcb8 added ~20 lines
# of comment documenting the Go 1.21 finding, the distance from the task name
# to `environment:` grew to 38 lines in go.yml and 16 in github.yml, past
# windows of 25 and 15 — so both tests failed while GOTOOLCHAIN: auto was still
# right there (go.yml:78, github.yml:89). The comment explaining a fix broke the
# test guarding that fix. A fixed offset asserts proximity; what these tests
# actually mean to assert is membership in the task.
task_block() { # file, task-name substring
  awk -v pat="$2" '
    /^- name: / { inblk = index($0, pat) > 0 }
    inblk { print }
  ' "$1"
}

@test "H3 regression catcher: tasks/go.yml scopes GOTOOLCHAIN=auto for govulncheck install" {
  # Bug: govulncheck requires go newer than Ubuntu 24.04's stock 1.22,
  # and the role's GOTOOLCHAIN=local hardening prevents auto-fetch. Fix
  # scopes GOTOOLCHAIN=auto to just this install task via the
  # environment: keyword, keeping global hardening intact.
  task_block "${ROLE_DIR}/tasks/go.yml" 'Install govulncheck' \
    | grep -qE '^\s*GOTOOLCHAIN: *auto'
}

@test "H3 regression catcher: tasks/github.yml scopes GOTOOLCHAIN=auto for pinact install" {
  task_block "${ROLE_DIR}/tasks/github.yml" 'Install pinact' \
    | grep -qE '^\s*GOTOOLCHAIN: *auto'
}

@test "H3: GOTOOLCHAIN=auto stays SCOPED to the install task, never global" {
  # The other half of the invariant, which neither catcher checked: the fix is
  # only correct because the auto-fetch is scoped to one task. If GOTOOLCHAIN
  # auto ever appears at play level or in the env-var layer it would undo the
  # GOTOOLCHAIN=local hardening for every user `go install` on the host — the
  # exact protection those tasks are carefully working around.
  ! grep -qE '^\s*GOTOOLCHAIN=auto' "$ROLE_DIR"/templates/*.j2 2>/dev/null
  ! grep -qE 'GOTOOLCHAIN.*auto' "$ROLE_DIR"/tasks/shell_env.yml 2>/dev/null
}

# ---- Runtime regression catcher: bare-uv fails on stripped PATH ----
#
# Independent of the structural grep above: validates the underlying
# claim that bare `uv` actually fails when ~/.local/bin is missing from
# PATH. If this stops being true (e.g., uv installs to a different
# default location, or the container changes), the structural fix
# becomes less important — but knowing that requires THIS test.

@test "H1/H2 substrate: bare uv command DOES fail when ~/.local/bin is missing from PATH" {
  # Confirms the bug premise. If this passes, the absolute-path fix is
  # load-bearing. If this FAILS (bare uv worked anyway), investigate
  # why before assuming the fix is no longer needed.
  command -v uv >/dev/null 2>&1 || skip "uv not installed"

  # Resolve where uv lives, then strip its directory from PATH.
  uv_path=$(command -v uv)
  uv_dir=$(dirname "$uv_path")

  # Build a PATH that EXCLUDES uv's directory.
  stripped_path=$(echo "$PATH" | tr ':' '\n' | grep -vFx "$uv_dir" | paste -sd:)

  # Bare `uv` from the stripped PATH should fail to resolve.
  run env -i HOME="$HOME" PATH="$stripped_path" bash -c "uv --version"
  [ "$status" -ne 0 ]
}

@test "H1/H2 fix verified: absolute uv path works when ~/.local/bin is missing from PATH" {
  # Pair with the test above: the absolute path (what the role now uses)
  # must work in the same stripped environment.
  command -v uv >/dev/null 2>&1 || skip "uv not installed"

  uv_path=$(command -v uv)
  uv_dir=$(dirname "$uv_path")
  stripped_path=$(echo "$PATH" | tr ':' '\n' | grep -vFx "$uv_dir" | paste -sd:)

  run env -i HOME="$HOME" PATH="$stripped_path" bash -c "'$uv_path' --version"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ---- Pre-flight tests (#9, #10) ----
#
# These actually run ansible-playbook with adversarial inputs and assert
# the play halts at the preflight task with the documented message.

@test "preflight: rejects release_age_hours=0 with the documented error" {
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    -e podman_enabled=false -e release_age_hours=0
  [ "$status" -ne 0 ]
  [[ "$output" =~ "release_age_hours must be >= 1" ]]
}

@test "preflight: rejects release_age_hours=-1 (negative)" {
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    -e podman_enabled=false -e release_age_hours=-1
  [ "$status" -ne 0 ]
  [[ "$output" =~ "release_age_hours must be >= 1" ]]
}

@test "preflight: refuses to overwrite unmarked /etc/npmrc" {
  # Simulate a host with a pre-existing corporate /etc/npmrc (registry
  # auth, internal mirror, etc.) and verify the role refuses to clobber
  # it without explicit operator opt-in.
  backup=""
  if [ -f /etc/npmrc ]; then
    backup=$(mktemp)
    cp /etc/npmrc "$backup"
  fi
  echo "registry=https://malicious-corporate-stand-in.example.invalid/" > /etc/npmrc

  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    -e podman_enabled=false

  # Restore (regardless of test outcome)
  if [ -n "$backup" ]; then
    mv "$backup" /etc/npmrc
  else
    rm -f /etc/npmrc
  fi

  [ "$status" -ne 0 ]
  [[ "$output" =~ "Refusing to overwrite existing system config" ]]
  [[ "$output" =~ "/etc/npmrc" ]]
}

@test "preflight: accept_etc_overwrite=true bypasses the refuse-to-clobber check" {
  # The opt-in escape hatch must work — operators who knowingly want to
  # overwrite their existing /etc files need a documented path forward.
  backup=""
  if [ -f /etc/npmrc ]; then
    backup=$(mktemp)
    cp /etc/npmrc "$backup"
  fi
  echo "registry=https://unmarked-corporate-stand-in.example.invalid/" > /etc/npmrc

  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    -e podman_enabled=false -e accept_etc_overwrite=true \
    --tags always

  # Restore
  if [ -n "$backup" ]; then
    mv "$backup" /etc/npmrc
  else
    rm -f /etc/npmrc
  fi

  # The preflight check itself must NOT fail. We use --tags always to keep
  # the run cheap; with accept_etc_overwrite=true the preflight should
  # pass silently.
  [ "$status" -eq 0 ]
}

# ---- Idempotency (#3) ----
#
# Apply twice, assert the second apply produces zero changed= count.
# Catches: tasks that always report changed (missing `creates:`, wrong
# state checks, race conditions with auto-generated files, failed tasks
# leaving state that re-triggers next run, etc.).
#
# This test is comparatively slow (two full plays). Skipped via SKIP_SLOW
# if the operator wants a fast run.

@test "idempotency: re-applying the playbook produces changed=0 on second run" {
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  cd "$ROLE_DIR"

  # First apply (post-build, may re-run no-ops; we just want a fresh
  # baseline before measuring the second run).
  ansible-playbook site.yml --connection=local --limit localhost \
    -e podman_enabled=false >/tmp/idempotency-apply1.log 2>&1 || true

  # Second apply: this is what we measure.
  ansible-playbook site.yml --connection=local --limit localhost \
    -e podman_enabled=false >/tmp/idempotency-apply2.log 2>&1

  # The PLAY RECAP line for localhost contains changed=N. Parse it.
  recap_line=$(grep -E "^localhost" /tmp/idempotency-apply2.log | tail -1)
  echo "Second apply recap: $recap_line"

  # Extract the changed= number.
  changed=$(echo "$recap_line" | grep -oE 'changed=[0-9]+' | grep -oE '[0-9]+')

  # Must be 0. If it isn't, dump the changed tasks for debugging.
  if [ "$changed" != "0" ]; then
    echo "Tasks that reported changed on second apply:"
    grep -B1 "^changed:" /tmp/idempotency-apply2.log || true
  fi
  [ "$changed" = "0" ]
}

# --- check-mode support ---------------------------------------------------
# QA found that `--check` was not merely imprecise but actively misleading:
# the pre-flight GNU-date probe skipped, came back empty, and hard-aborted the
# run claiming date was missing on a host where it works; and every tool-detection
# probe skipped, so deployed protections were reported as skipped and the
# coverage summary rendered empty values ("found Node ."). Root cause: Ansible
# does not execute command/shell under --check, and no task set check_mode.
#
# Every read-only probe declares `changed_when: false`, which is the author
# asserting it mutates nothing — so running it under check mode is safe by
# construction. These two tests keep that invariant paired.

@test "check-mode: every changed_when:false probe also sets check_mode:false" {
  local missing=0
  for f in "$ROLE_DIR"/tasks/*.yml; do
    # Report any `changed_when: false` whose immediately following line is
    # not `check_mode:`. Paired insertion is the convention in this role.
    while IFS= read -r lineno; do
      next=$(sed -n "$((lineno + 1))p" "$f")
      if ! echo "$next" | grep -qE '^\s*check_mode:'; then
        echo "MISSING check_mode: false -> $(basename "$f"):$lineno" >&2
        missing=$((missing + 1))
      fi
    done < <(grep -nE '^\s*changed_when:\s*false\s*$' "$f" | cut -d: -f1)
  done
  [ "$missing" -eq 0 ]
}

@test "check-mode: a dry run completes instead of aborting at preflight" {
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  cd "$ROLE_DIR"
  # The specific regression: --check aborted at the GNU date probe with
  # "Your controller's date refused the probe / rc=0", i.e. it reported a
  # success rc while claiming failure. A dry run must simply complete.
  run ansible-playbook site.yml --connection=local --limit localhost \
    --check -e podman_enabled=false
  echo "$output" | tail -30
  ! echo "$output" | grep -q "refused the probe"
  [ "$status" -eq 0 ]
}

@test "no optional tool install may abort the play" {
  # THE MOST EXPENSIVE BUG THIS SUITE HAS MISSED.
  #
  # tasks/go.yml installed govulncheck with GOTOOLCHAIN=auto to let go fetch a
  # newer toolchain — but GOTOOLCHAIN only exists in Go >= 1.21. Stock Ubuntu
  # 22.04 ships Go 1.18.1 and Debian 12 ships 1.19.8, so `go install` failed,
  # the task had no failed_when, and the play DIED — taking 11 downstream
  # includes with it: composer, bundler, maven, gradle, nuget, podman, npq,
  # socket (sfw + the npm PATH wrapper), github, shell_env (the entire env-var
  # layer) and verify. Two of three declared supported platforms, left half
  # hardened.
  #
  # The invariant: config deployment is the load-bearing protection. An
  # optional scanner that will not install is a coverage gap to report, never
  # a reason to abandon the remaining ecosystems.
  local fatal=0
  while IFS= read -r hit; do
    local f="${hit%%:*}"
    local ln="${hit#*:}"; ln="${ln%%:*}"
    # walk forward to the end of the task block, looking for failed_when
    local blk
    blk=$(awk -v s="$ln" 'NR>=s { if (NR>s && /^- name: /) exit; print }' "$f")
    if ! echo "$blk" | grep -qE '^\s*(failed_when|ignore_errors):'; then
      echo "FATAL install task: $f:$ln" >&2
      echo "$blk" | head -3 >&2
      fatal=$((fatal + 1))
    fi
  done < <(grep -nE '^- name: Install ' "$ROLE_DIR"/tasks/*.yml)
  [ "$fatal" -eq 0 ]
}
