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
  require_root "writes /etc/npmrc"
  # cp -p: mktemp creates the backup 0600, and a plain cp into it keeps 0600, so
  # the mv below used to leave /etc/npmrc unreadable by every non-root user.
  backup=""
  if [ -f /etc/npmrc ]; then
    backup=$(mktemp)
    cp -p /etc/npmrc "$backup"
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
  require_root "writes /etc/npmrc"
  # cp -p: mktemp creates the backup 0600, and a plain cp into it keeps 0600, so
  # the mv below used to leave /etc/npmrc unreadable by every non-root user.
  backup=""
  if [ -f /etc/npmrc ]; then
    backup=$(mktemp)
    cp -p /etc/npmrc "$backup"
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

# ---- JDK-only hosts: ./gradlew and ./mvnw (CMP 4.5) ----
#
# Most JVM builds run the project's wrapper, not a gradle/mvn on PATH. The
# wrapper's distribution reads the same gradle user home and ~/.m2, so the role
# must deploy there when a JDK is present. MEASURED on 8281a6b (JDK 21 on PATH,
# no gradle or mvn): nothing was deployed, and a 1.+ plugin resolved and ran
# under gradle 8.14.3.
#
# Isolated: HOME and GRADLE_USER_HOME point into a temp dir (the role resolves
# both from the target's environment), so the files this run writes cannot
# leak into the suite's own hardened home. `java` is a stub: the gate only asks
# whether a wrapper could start, it never runs java.

# PATH with every directory that holds gradle, mvn or java removed, then $1
# (if given) in front. Prints nothing when a needed system dir holds one of
# them, so the caller can skip instead of testing the wrong thing.
jvm_free_path() {
  local d out="" IFS=:
  for d in $PATH; do
    if [ -x "$d/gradle" ] || [ -x "$d/mvn" ] || [ -x "$d/java" ]; then
      case "$d" in /usr/bin|/bin|/usr/sbin|/sbin) return 1 ;; esac
      continue
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "${1:+$1:}$out"
}

jvm_only_apply() { # $1 = PATH to use
  local t=$2
  cd "$ROLE_DIR"
  env -u JAVA_HOME HOME="$t/home" GRADLE_USER_HOME="$t/home/.gradle" PATH="$1" \
    ansible-playbook site.yml --connection=local --limit localhost \
      -e podman_enabled=false --tags maven,gradle 2>&1
}

@test "JDK-only host: a java with no gradle/mvn still gets the init script and settings.xml (CMP 4.5)" {
  local t p
  t=$(mktemp -d); mkdir -p "$t/bin" "$t/home"
  printf '#!/bin/sh\necho "openjdk version \"21\""\n' > "$t/bin/java"
  chmod +x "$t/bin/java"
  p=$(jvm_free_path "$t/bin") || { rm -rf "$t"; skip "gradle, mvn or java lives in a system bin dir here"; }
  run jvm_only_apply "$p" "$t"
  echo "$output" | grep -E 'fatal|neither|PLAY RECAP' -A1 | head -8
  [ "$status" -eq 0 ]
  assert_file_exists "$t/home/.gradle/init.d/supply-chain-security.gradle"
  assert_file_exists "$t/home/.m2/settings.xml"
  ! echo "$output" | grep -q 'neither gradle nor a JDK'
  ! echo "$output" | grep -q 'neither mvn nor a JDK'
  rm -rf "$t"
}

@test "JDK-only host: FIXTURE CONTROL — with no java either, nothing is deployed and both skips are recorded" {
  local t p
  t=$(mktemp -d); mkdir -p "$t/home"
  p=$(jvm_free_path) || { rm -rf "$t"; skip "gradle, mvn or java lives in a system bin dir here"; }
  run jvm_only_apply "$p" "$t"
  [ "$status" -eq 0 ]
  [ ! -e "$t/home/.gradle/init.d/supply-chain-security.gradle" ]
  [ ! -e "$t/home/.m2/settings.xml" ]
  echo "$output" | grep -q 'neither gradle nor a JDK'
  echo "$output" | grep -q 'neither mvn nor a JDK'
  rm -rf "$t"
}

# ---- composer_path_wrapper=false: the documented way back ----
#
# defaults/main.yml: "Set this var to false to restore the real binary at the
# wrap location on next apply (env-var layer remains)". MEASURED on 6c77f4e
# (composer 2.11.2): that apply failed the play at "Restore original composer
# binary when wrapper is disabled" with "'dict object' has no attribute 'rc'",
# because the probes it reads were skipped whenever the wrapper was off, and the
# wrapper stayed where it was.

COMPOSER_UNWRAPPED=""
composer_apply() { # extra ansible args
  cd "$ROLE_DIR"
  ansible-playbook site.yml --connection=local --limit localhost \
    --tags composer -e podman_enabled=false -e verify_protections=false "$@" 2>&1
}
restore_composer_wrapper() {
  [ -n "$COMPOSER_UNWRAPPED" ] || return 0
  grep -q 'supply-chain-hardening' "$COMPOSER_UNWRAPPED" 2>/dev/null && return 0
  echo "# teardown: wrapping composer again" >&3
  composer_apply >/dev/null || true
}

@test "composer_path_wrapper=false: a re-apply puts the real composer back at the wrapped path, and true wraps it again" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  require_root "moves the root-owned composer wrapper"
  w=$(command -v composer) || skip "composer not installed"
  grep -q 'supply-chain-hardening' "$w" || skip "composer is not wrapped here"
  [ -x "$w-real" ] || skip "no $w-real next to the wrapper"
  real_sum=$(sha256sum < "$w-real")
  COMPOSER_UNWRAPPED=$w

  run composer_apply -e composer_path_wrapper=false
  echo "$output" | grep -E 'fatal|FAILED|Restore original composer|PLAY RECAP' -A2 | head -20
  [ "$status" -eq 0 ]
  # The binary composer-real held is back at the path, and no wrapper is left.
  [ ! -e "$w-real" ]
  if grep -q 'supply-chain-hardening' "$w"; then echo "$w is still the wrapper"; return 1; fi
  [ "$(sha256sum < "$w")" = "$real_sum" ]
  run "$w" --version --no-ansi --no-plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"Composer"* ]]
  # The env-var layer stays, as documented.
  grep -q '^COMPOSER_SKIP_SCRIPTS=' /etc/environment
  grep -q 'COMPOSER_SKIP_SCRIPTS=' /etc/profile.d/supply-chain-hardening.sh

  # Again with the wrapper off: nothing left to restore, and the play passes.
  run composer_apply -e composer_path_wrapper=false
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -A1 'TASK \[.*Restore original composer binary' | tail -n 1 | grep -q '^skipping:'

  # Back on: wrapped again, around the same binary.
  run composer_apply
  [ "$status" -eq 0 ]
  grep -q 'supply-chain-hardening' "$w"
  [ "$(sha256sum < "$w-real")" = "$real_sum" ]
}

# ---- Per-user config files the role replaces whole (CMP 4.7) ----
#
# $CARGO_HOME/config.toml, ~/.m2/settings.xml and NuGet.Config are replaced,
# not merged. MEASURED on 8281a6b: an apply replaced a corporate copy of all
# three (registry mirror, private feed, credentials) with no copy and no
# message. Preflight now refuses unless accept_user_config_overwrite=true.
#
# Isolated like the JDK-only tests: HOME and CARGO_HOME point into a temp dir,
# and stub `java` / `dotnet` satisfy the maven and nuget gates. cargo.yml is
# only let past preflight when no cargo is installed: with one, it would build
# the gate backend into the temp CARGO_HOME and point the suite's real cargo
# wrapper at it. A refusal stops in preflight, so that test always covers it.

ucfg_setup() { # creates $T with stubs; plants corporate files unless $1=none
  T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/home/.cargo" "$T/home/.m2" "$T/home/.nuget/NuGet" "$T/orig"
  printf '#!/bin/sh\necho "openjdk version 21"\n' > "$T/bin/java"
  printf '#!/bin/sh\necho 8.0.100\n' > "$T/bin/dotnet"
  chmod +x "$T/bin/java" "$T/bin/dotnet"
  [ "${1:-}" = none ] && return 0
  printf '[source.crates-io]\nreplace-with = "corp"\n[source.corp]\nregistry = "sparse+https://cargo.corp.example/index/"\n' \
    > "$T/home/.cargo/config.toml"
  printf '<settings><servers><server><id>corp</id><password>s3cr3t</password></server></servers><mirrors><mirror><id>corp</id><mirrorOf>*</mirrorOf><url>https://maven.corp.example/</url></mirror></mirrors></settings>\n' \
    > "$T/home/.m2/settings.xml"
  printf '<?xml version="1.0" encoding="utf-8"?>\n<configuration><packageSources><add key="corp" value="https://nuget.corp.example/v3/index.json" /></packageSources></configuration>\n' \
    > "$T/home/.nuget/NuGet/NuGet.Config"
  cp "$T/home/.cargo/config.toml" "$T/orig/cargo"
  cp "$T/home/.m2/settings.xml" "$T/orig/maven"
  cp "$T/home/.nuget/NuGet/NuGet.Config" "$T/orig/nuget"
}

# 0 when cargo.yml would find no cargo (its own probe list), so it is safe to
# run it against a temp CARGO_HOME
ucfg_no_cargo() {
  local p
  for p in /usr/local/bin/cargo /usr/bin/cargo; do [ -x "$p" ] && return 1; done
  ! PATH="/usr/local/bin:/usr/bin:/bin:$PATH" command -v cargo >/dev/null 2>&1
}

ucfg_apply() { # extra ansible args
  cd "$ROLE_DIR"
  env -u DOTNET_CLI_HOME HOME="$T/home" CARGO_HOME="$T/home/.cargo" PATH="$T/bin:$PATH" \
    ansible-playbook site.yml --connection=local --limit localhost \
      -e podman_enabled=false "$@" 2>&1
}

# a backup of $1 (path) that is byte-identical to $2 (the original)
ucfg_backup_of() {
  local b
  for b in "$1".*~; do
    [ -f "$b" ] && cmp -s "$b" "$2" && return 0
  done
  echo "no byte-identical backup of $1 among: $(ls -a "$(dirname "$1")" | tr '\n' ' ')" >&2
  return 1
}

@test "preflight: refuses to replace per-user cargo/maven/nuget config it did not write, and changes nothing (CMP 4.7)" {
  ucfg_setup
  run ucfg_apply --tags cargo,maven,nuget
  echo "$output" | grep -A12 'Refusing to overwrite existing per-user' | head -16
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[supply-chain-hardening\] Refusing to overwrite existing per-user config'
  echo "$output" | grep -q "$T/home/.cargo/config.toml"
  echo "$output" | grep -q "$T/home/.m2/settings.xml"
  echo "$output" | grep -q "$T/home/.nuget/NuGet/NuGet.Config"
  echo "$output" | grep -q 'accept_user_config_overwrite=true'
  cmp "$T/home/.cargo/config.toml" "$T/orig/cargo"
  cmp "$T/home/.m2/settings.xml" "$T/orig/maven"
  cmp "$T/home/.nuget/NuGet/NuGet.Config" "$T/orig/nuget"
  rm -rf "$T"
}

@test "preflight: accept_user_config_overwrite=true replaces them and keeps a byte-identical backup of each" {
  local tags=maven,nuget
  ucfg_setup
  ucfg_no_cargo && tags=cargo,$tags
  run ucfg_apply --tags "$tags" -e accept_user_config_overwrite=true
  echo "$output" | grep -E 'fatal|PLAY RECAP' -A1 | head -6
  [ "$status" -eq 0 ]
  grep -q 'Managed by ansible-supply-chain-security' "$T/home/.m2/settings.xml"
  grep -q 'Managed by ansible-supply-chain-security' "$T/home/.nuget/NuGet/NuGet.Config"
  ucfg_backup_of "$T/home/.m2/settings.xml" "$T/orig/maven"
  ucfg_backup_of "$T/home/.nuget/NuGet/NuGet.Config" "$T/orig/nuget"
  if [[ "$tags" == cargo,* ]]; then
    grep -q 'Managed by ansible-supply-chain-security' "$T/home/.cargo/config.toml"
    ucfg_backup_of "$T/home/.cargo/config.toml" "$T/orig/cargo"
  fi
  rm -rf "$T"
}

@test "preflight: files this project wrote (marker, or the role's pre-marker versions) and dotnet's first-run NuGet.Config do not stop the play" {
  local tags=maven,nuget
  ucfg_setup none
  ucfg_no_cargo && tags=cargo,$tags
  # the role's own files as 8281a6b wrote them, before they carried a marker
  printf '# Cargo supply-chain hardening — system defaults.\n[net]\nretry = 3\n' > "$T/home/.cargo/config.toml"
  printf '<settings><mirrors><mirror><id>central-https</id></mirror></mirrors><activeProfiles><activeProfile>strict-checksums</activeProfile></activeProfiles></settings>\n' \
    > "$T/home/.m2/settings.xml"
  # dotnet's first-run file as SDK 8.0.134 writes it (UTF-8 BOM, no final
  # newline), which nobody chose
  printf '\357\273\277<?xml version="1.0" encoding="utf-8"?>\n<configuration>\n  <packageSources>\n    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />\n  </packageSources>\n</configuration>' \
    > "$T/home/.nuget/NuGet/NuGet.Config"
  cp "$T/home/.nuget/NuGet/NuGet.Config" "$T/orig/nuget"
  # (check mode writes nothing, so cargo.yml is safe here even with cargo)
  run ucfg_apply --tags "cargo,maven,nuget" --check
  echo "$output" | grep -E 'Refusing|fatal|PLAY RECAP' -A1 | head -6
  echo "$output" | grep -q 'Detect per-user config files this run would replace'
  ! echo "$output" | grep -q 'Refusing to overwrite existing per-user'
  run ucfg_apply --tags "$tags"
  echo "$output" | grep -E 'Refusing|fatal|PLAY RECAP' -A1 | head -6
  [ "$status" -eq 0 ]
  grep -q 'Managed by ansible-supply-chain-security' "$T/home/.m2/settings.xml"
  grep -q 'Managed by ansible-supply-chain-security' "$T/home/.nuget/NuGet/NuGet.Config"
  # the stock file is still kept, like any file this project did not write
  ucfg_backup_of "$T/home/.nuget/NuGet/NuGet.Config" "$T/orig/nuget"
  # our own files are replaced without a backup, and a re-apply over them
  # neither stops nor backs anything up
  run ucfg_apply --tags "$tags"
  [ "$status" -eq 0 ]
  [ "$(ls -a "$T/home/.m2" "$T/home/.cargo" | grep -c '~$')" -eq 0 ]
  [ "$(ls -a "$T/home/.nuget/NuGet" | grep -c '~$')" -eq 1 ]
  rm -rf "$T"
}

@test "preflight: only files this run would write are checked (--tags maven ignores a foreign cargo config and NuGet.Config)" {
  ucfg_setup
  rm -f "$T/home/.m2/settings.xml"
  run ucfg_apply --tags maven
  echo "$output" | grep -E 'Refusing|fatal|PLAY RECAP' -A1 | head -6
  [ "$status" -eq 0 ]
  cmp "$T/home/.cargo/config.toml" "$T/orig/cargo"
  cmp "$T/home/.nuget/NuGet/NuGet.Config" "$T/orig/nuget"
  rm -rf "$T"
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

# ---- Idempotency under --tags: the order of the tags ----
#
# Ansible hands the run's tags over as a set, so the same --tags list arrives in
# a different order from one run to the next (it follows the interpreter's string
# hash seed). The verifier context embedded that order, so a re-apply with the
# same tags re-rendered "Render this host's verification context" and
# "Assemble the verification command" and reported changed. MEASURED on 6c77f4e:
# 5 of 6 applies with --tags npm,cargo,verify (in either spelling) reported
# changed=2, and --check reported the context changed.

# The two runs below use hash seeds under which this interpreter orders the set
# differently, so the test does not depend on luck.
tag_order() { # seed tags -> the order Ansible's list(set(...)) gives them
  PYTHONHASHSEED=$1 $TAG_PY -c 'import sys; print(",".join(list(set(sys.argv[1].split(",")))))' "$2"
}

@test "idempotency: a re-apply with the same tags, in another order, changes neither the verifier context nor the verifier" {
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  local tags=yarn,nuget,verify s1=0 s2="" s o1 o2 st
  TAG_PY=$(sed -n '1s/^#! *//p' "$(command -v ansible-playbook)")
  [ -n "$TAG_PY" ] || skip "could not read ansible-playbook's interpreter"
  o1=$(tag_order "$s1" "$tags")
  for s in $(seq 1 40); do
    o2=$(tag_order "$s" "$tags")
    if [ "$o2" != "$o1" ]; then s2=$s; break; fi
  done
  [ -n "$s2" ] || skip "no two hash seeds order these tags differently here"
  echo "seed $s1 orders the tags $o1, seed $s2 orders them $o2"
  cd "$ROLE_DIR"
  run env PYTHONHASHSEED=$s1 ansible-playbook site.yml --connection=local --limit localhost \
    -e podman_enabled=false -e verify_protections=false --tags "$tags"
  [ "$status" -eq 0 ]
  grep -q "limited to tags nuget,verify,yarn" /usr/local/lib/supply-chain-verify/00-context.sh

  # Again, the tags spelled in another order, and with a seed that hands them
  # over in another order.
  run env PYTHONHASHSEED=$s2 ansible-playbook site.yml --connection=local --limit localhost \
    -e podman_enabled=false -e verify_protections=false --tags verify,yarn,nuget
  [ "$status" -eq 0 ]
  for st in "Render this host's verification context" "Assemble the verification command"; do
    # The task's own result line, not whatever follows the header: ansible-core
    # 2.20 on Ubuntu 26.04 prints a [DEPRECATION WARNING] there (round 3).
    r=$(printf '%s\n' "$output" | awk -v st="$st" 'index($0, st) { f = 1; next } f && /^(ok|changed|skipping|fatal|failed):/ { print; exit }')
    echo "$st: $r"
    [[ "$r" == ok:* ]] || { echo "'$st' reported '$r' on a re-apply with the same tags"; return 1; }
  done
  # A dry run of the same says the same.
  run env PYTHONHASHSEED=$s2 ansible-playbook site.yml --connection=local --limit localhost --check \
    -e podman_enabled=false -e verify_protections=false --tags "$tags"
  [ "$status" -eq 0 ]
  r=$(printf '%s\n' "$output" | grep -F -A1 "Render this host's verification context" | tail -n 1)
  echo "--check: $r"
  [[ "$r" == ok:* ]]
}

# ---- Optional tool installs: Go floor and version pins ----
#
# The idempotency test above cannot see either bug below, because this image's
# Go is new enough and its tools sit at their pins.

# Stand a fake Go 1.18 in for the real one: `version` reports 1.18.1, and every
# other subcommand logs its argv and fails, as `go install ...@v5` does there.
# The image's pinact is hidden too: a real Go 1.18 host never got one, and with
# it present the old `creates:` guard skipped the install and hid the bug.
GO_REAL=/usr/local/go/bin/go
PINACT_BIN="$HOME/go/bin/pinact"
hide_real_go() {
  [ -x "$GO_REAL" ] || return 1
  [ -w "$(dirname "$GO_REAL")" ] || return 1
  if [ -e "$PINACT_BIN" ]; then mv "$PINACT_BIN" "$PINACT_BIN.bats-hidden"; fi
  mv "$GO_REAL" "$GO_REAL.bats-hidden"
  cat > "$GO_REAL" <<'EOF'
#!/bin/sh
if [ "$1" = version ]; then echo "go version go1.18.1 linux/amd64"; exit 0; fi
echo "$*" >> /tmp/fake-go-calls.log
exit 1
EOF
  chmod 755 "$GO_REAL"
}
restore_real_go() {
  if [ -e "$GO_REAL.bats-hidden" ]; then mv -f "$GO_REAL.bats-hidden" "$GO_REAL"; fi
  if [ -e "$PINACT_BIN.bats-hidden" ]; then mv -f "$PINACT_BIN.bats-hidden" "$PINACT_BIN"; fi
}

# The age-gate refresher (and, on a systemd host, its service unit) is one
# root-owned file that applies in this file re-render, several of them with
# -e socket_firewall_install=false so they need no network, which drops its
# --sfw step. 49-age-gate-refresh.bats reads the deployed copy later in the
# same container, and its --sfw tests then skipped as though the image had been
# built without sfw. setup() keeps the content of each before every test, and
# teardown() writes back any that a test changed, through the existing file so
# it stays root-owned (cat, or sudo tee for a normal user on a real host).
REFRESH_FILES=(/usr/local/sbin/supply-chain-age-gate-refresh /etc/systemd/system/supply-chain-age-gate-refresh.service)
setup() {
  local i=0 f
  for f in "${REFRESH_FILES[@]}"; do
    if [ -f "$f" ]; then cat "$f" > "$BATS_TEST_TMPDIR/refresh-snap.$i" 2>/dev/null || rm -f "$BATS_TEST_TMPDIR/refresh-snap.$i"; fi
    i=$((i + 1))
  done
}
restore_refresher() {
  local i=0 f snap changed=""
  for f in "${REFRESH_FILES[@]}"; do
    snap="$BATS_TEST_TMPDIR/refresh-snap.$i"; i=$((i + 1))
    [ -f "$snap" ] && [ -f "$f" ] || continue
    cmp -s "$snap" "$f" && continue
    { cat "$snap" > "$f"; } 2>/dev/null || sudo -n tee "$f" < "$snap" >/dev/null 2>&1 || continue
    case "$f" in *.service) changed=1 ;; esac
  done
  if [ -n "$changed" ] && [ -d /run/systemd/system ]; then
    systemctl daemon-reload 2>/dev/null || sudo -n systemctl daemon-reload 2>/dev/null || true
  fi
  return 0
}

# Runs after every test in this file. A no-op unless a test left the real Go
# or uv hidden, which must never outlive the test that hid it, or changed the
# refresher (above).
teardown() {
  restore_real_go
  restore_uv
  restore_yarnrc
  restore_refresher
  restore_composer_wrapper
}

UV_HIDDEN=""
hide_uv() {
  local p
  p=$(command -v uv 2>/dev/null) || return 1
  [ -w "$(dirname "$p")" ] || return 1
  mv "$p" "$p.bats-hidden" && UV_HIDDEN="$p"
  hash -r
  # uv.yml also looks in these; the test only means something if none has one.
  if command -v uv >/dev/null 2>&1 || [ -x /usr/local/bin/uv ] || [ -x /usr/bin/uv ] || [ -x "$HOME/.local/bin/uv" ]; then
    restore_uv
    return 1
  fi
}
restore_uv() {
  if [ -n "$UV_HIDDEN" ] && [ -e "$UV_HIDDEN.bats-hidden" ]; then mv -f "$UV_HIDDEN.bats-hidden" "$UV_HIDDEN"; fi
}

@test "pinact: Go < 1.21 skips the install and records why, so a re-apply changes nothing" {
  # MEASURED on stock Ubuntu 22.04 (Go 1.18.1) and Debian 12 (Go 1.19.8): the
  # pinact install had no Go floor, failed on every apply, and with
  # failed_when: false and no changed_when it reported `changed` each time, so
  # a second apply was never changed=0. govulncheck in go.yml had the floor.
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  require_root "swaps $GO_REAL for a fake Go 1.18"
  rm -f /tmp/fake-go-calls.log
  hide_real_go || skip "no tarball Go at $GO_REAL to stand in for"
  cd "$ROLE_DIR"
  local rc1=0 rc2=0
  ansible-playbook site.yml --connection=local --limit localhost --tags github \
    -e podman_enabled=false -e verify_protections=false >/tmp/pinact-go118-1.log 2>&1 || rc1=$?
  ansible-playbook site.yml --connection=local --limit localhost --tags github \
    -e podman_enabled=false -e verify_protections=false >/tmp/pinact-go118-2.log 2>&1 || rc2=$?
  restore_real_go
  echo "rc1=$rc1 rc2=$rc2; fake go calls: $(cat /tmp/fake-go-calls.log 2>/dev/null)"
  grep -E '^localhost' /tmp/pinact-go118-2.log | tail -1
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]
  # The install never ran: the fake logged no `install` call.
  if grep -q '^install ' /tmp/fake-go-calls.log 2>/dev/null; then
    echo "the role ran go install on a Go older than 1.21" >&2
    false
  fi
  grep -E '^localhost' /tmp/pinact-go118-2.log | tail -1 | grep -q 'changed=0'
  grep -q 'pinact (optional audit tool; nothing in the role runs it, so no install is blocked either way) — Go 1.18.1 is older than 1.21' /tmp/pinact-go118-2.log
}

@test "tool pins: an installed version that differs from the pin is reinstalled, not left in place" {
  # `creates:` (and lockfile-lint's `which`) only checked that a binary existed,
  # so bumping a pin in defaults/main.yml never reinstalled anything. Offline
  # by design: each pin is pointed at a version that does not exist, so the
  # reinstall the role must now attempt fails, and the summary has to say so.
  # Before the fix the install tasks were skipped and the summary said nothing.
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  require_root "reinstalls the role's global tools"
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags github,go,uv,npm -e podman_enabled=false -e verify_protections=false \
    -e socket_firewall_install=false \
    -e zizmor_version=99.99.99 -e pinact_version=v99.99.99 \
    -e govulncheck_version=v99.99.99 -e pip_audit_version=99.99.99 \
    -e uv_secure_version=99.99.99 -e lockfile_lint_version=99.99.99
  echo "$output" | grep -E 'NOT applied|optional audit tool' | head -20
  [ "$status" -eq 0 ]
  local t checked=0
  for t in zizmor pinact govulncheck 'uv-secure / pip-audit' lockfile-lint; do
    command -v "${t%% *}" >/dev/null 2>&1 || [ -x "$HOME/go/bin/$t" ] || continue
    checked=$((checked + 1))
    echo "$output" | grep -q "$t (optional audit tool[^)]*) — install failed" \
      || { echo "no reinstall attempt recorded for $t" >&2; false; }
  done
  [ "$checked" -gt 0 ] || skip "none of the role's optional tools is installed here"
  # The audit tools are not protections, so the header counts them apart.
  echo "$output" | grep -qE 'protection\(s\) were NOT applied on this host, plus [0-9]+ optional audit tool entr(y|ies) \(not protections'
}

@test "tool pins: tools already at their pins are not reinstalled" {
  # The other half: the version probes must recognise a tool that IS at its pin
  # (`uv tool list`, `go version -m`, lockfile-lint's package.json). A probe
  # that misreads its tool would reinstall on every apply.
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  cd "$ROLE_DIR"
  # A first apply brings the tools to their pins; only the second is measured.
  # In the image root's tools already are, but a user who has not applied the
  # role (a normal user on a real host) gets a legitimate first install of the
  # per-user ones (pinact and govulncheck in its own GOPATH), which is not what
  # this test is about.
  ansible-playbook site.yml --connection=local --limit localhost \
    --tags github,go,uv,npm -e podman_enabled=false -e verify_protections=false \
    -e socket_firewall_install=false >/tmp/tool-pins-apply1.log 2>&1 || true
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags github,go,uv,npm -e podman_enabled=false -e verify_protections=false \
    -e socket_firewall_install=false
  echo "$output" | grep -E '^(changed|TASK \[.*Install)' | head -20
  [ "$status" -eq 0 ]
  local task
  for task in 'Install zizmor' 'Install pinact' 'Install govulncheck' 'Install uv-managed tools' 'Install lockfile-lint globally'; do
    # Look only at the result lines between this task's header and the next.
    if echo "$output" | awk -v pat="$task" '
         /^TASK \[/ { inblk = index($0, pat) > 0; next }
         inblk && /^changed:/ { found = 1 }
         END { exit !found }'; then
      echo "$task reinstalled a tool that is already at its pin" >&2
      false
    fi
  done
}

# Did this task report `changed` on any of its result lines? (Same parse as above.)
task_changed() { # task_changed <output> <task name substring>
  echo "$1" | awk -v pat="$2" '
    /^TASK \[/ { inblk = index($0, pat) > 0; next }
    inblk && /^changed:/ { found = 1 }
    END { exit !found }'
}

@test "tool pins: a zizmor / uv-secure / pip-audit that uv did not install is left alone, not reported as a failed install" {
  # MEASURED (review of the version probes): with a zizmor from pipx or
  # `pip install --user` in ~/.local/bin, `uv tool list` does not show it, so
  # the probe said "not at the pin" on every apply, and `uv tool install`
  # failed with "Executable already exists: zizmor (use --force to overwrite)".
  # Every summary then said zizmor's install failed, although zizmor runs.
  # `creates:` had skipped quietly. UV_TOOL_DIR (empty, so `uv tool list` shows
  # nothing) and UV_TOOL_BIN_DIR (holding the copies) stage that host without
  # touching the image's own uv tools, and offline: the fixed role never runs
  # the install here.
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  local d t
  d=$(mktemp -d /tmp/sch-foreign-uv.XXXXXX)
  mkdir -p "$d/tools" "$d/bin"
  for t in zizmor uv-secure pip-audit; do
    printf '#!/bin/sh\necho "%s from pip --user"\n' "$t" > "$d/bin/$t"
    chmod 755 "$d/bin/$t"
  done
  cd "$ROLE_DIR"
  run env UV_TOOL_DIR="$d/tools" UV_TOOL_BIN_DIR="$d/bin" \
    ansible-playbook site.yml --connection=local --limit localhost \
    --tags github,uv -e podman_enabled=false -e verify_protections=false
  local out="$output" rc="$status"
  local intact=yes
  for t in zizmor uv-secure pip-audit; do
    [ "$("$d/bin/$t")" = "$t from pip --user" ] || intact=no
  done
  rm -rf "$d"
  echo "$out" | grep -E 'optional audit tool|not installed by `uv tool`|Executable already exists' | head -10
  [ "$rc" -eq 0 ]
  [ "$intact" = yes ]
  if echo "$out" | grep -qE '(zizmor|uv-secure / pip-audit) \(optional audit tools?[^)]*\) — install failed'; then
    echo "the summary reports a failed install of a tool that is installed and runs" >&2
    false
  fi
  # Not `! task_changed`: bash's errexit ignores a negated command, so it could not fail the test.
  local task
  for task in 'Install zizmor' 'Install uv-managed tools'; do
    if task_changed "$out" "$task"; then
      echo "$task installed over a copy uv does not manage" >&2
      false
    fi
  done
  # Leaving it alone is said, not silent.
  echo "$out" | grep -q "$d/bin/zizmor was not installed by \`uv tool\`"
  echo "$out" | grep -q "$d/bin/pip-audit was not installed by \`uv tool\`"
}

@test "tool pins: lockfile-lint's probe reads root's global prefix, not another copy earlier on the caller's PATH" {
  # MEASURED (review of the version probes): the probe read whichever
  # lockfile-lint `command -v` found, but the install writes root's global
  # prefix. With another lockfile-lint at another version earlier on PATH (an
  # nvm/fnm global; a local connection inherits the caller's PATH), the probe
  # never matched the pin and every apply reinstalled the system copy:
  # changed=1 on every re-apply.
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  local pin sysroot
  pin=$(sed -nE 's/^lockfile_lint_version: *"([^"]+)".*/\1/p' "$ROLE_DIR/defaults/main.yml")
  if [ "$(id -u)" -eq 0 ]; then sysroot=$(npm root -g 2>/dev/null); else sysroot=$(sudo -n npm root -g 2>/dev/null); fi
  grep -qE "\"version\": *\"$pin\"" "$sysroot/lockfile-lint/package.json" 2>/dev/null \
    || skip "root's global lockfile-lint is not at the pin $pin, so a reinstall would be correct"
  local d
  d=$(mktemp -d /tmp/sch-userpfx.XXXXXX)
  mkdir -p "$d/lib/node_modules/lockfile-lint/bin" "$d/bin"
  printf '{\n  "name": "lockfile-lint",\n  "version": "4.14.1"\n}\n' > "$d/lib/node_modules/lockfile-lint/package.json"
  printf '#!/bin/sh\necho 4.14.1\n' > "$d/lib/node_modules/lockfile-lint/bin/lockfile-lint.js"
  chmod 755 "$d/lib/node_modules/lockfile-lint/bin/lockfile-lint.js"
  ln -s ../lib/node_modules/lockfile-lint/bin/lockfile-lint.js "$d/bin/lockfile-lint"
  cd "$ROLE_DIR"
  run env PATH="$d/bin:$PATH" ansible-playbook site.yml --connection=local --limit localhost \
    --tags npm -e podman_enabled=false -e verify_protections=false -e socket_firewall_install=false
  local out="$output" rc="$status"
  rm -rf "$d"
  echo "$out" | grep -A2 'lockfile-lint' | grep -E '^(TASK|ok|changed|skipping)' | head -12
  [ "$rc" -eq 0 ]
  if task_changed "$out" 'Install lockfile-lint globally'; then
    echo "reinstalled root's lockfile-lint $pin because another copy came first on PATH" >&2
    false
  fi
}

# ---- The end-of-run summary ----
#
# MEASURED on every stock VM: the "NOT applied" summary left out npm < 11.10
# (no age gate), Yarn classic / Yarn < 4.10, and the pip wrapper when uv is
# absent; told the operator the pip wrapper "already does" route through uv
# when there was none; and closed with "Everything else in the role applied
# normally". A stub yarn first on PATH stands in for each Yarn version.

# The yarn tasks render ~/.yarnrc.yml and root's ~/.yarnrc.yml for the version
# they detect, so a stub's rendering must not outlive its test: left rendered for
# a stub 4.10.3, a real Yarn 1.x host keeps a 4.x file, and the other way round a
# Yarn 4 host loses enableHardenedMode. MEASURED in review: both files' hashes
# changed across a run of these tests (the second was /etc/yarnrc.yml then).
# Restored by teardown, whatever the outcome.
YARNRC_FILES=("$HOME/.yarnrc.yml" ~root/.yarnrc.yml)
YARNRC_BACKUP=""
backup_yarnrc() {
  local f i=0
  YARNRC_BACKUP=$(mktemp -d /tmp/sch-yarnrc.XXXXXX)
  for f in "${YARNRC_FILES[@]}"; do
    # cp -p keeps the 0644 mode and owner (see the /etc/npmrc tests above).
    if [ -e "$f" ]; then cp -p "$f" "$YARNRC_BACKUP/$i"; fi
    i=$((i + 1))
  done
}
restore_yarnrc() {
  [ -n "$YARNRC_BACKUP" ] && [ -d "$YARNRC_BACKUP" ] || return 0
  local f i=0
  for f in "${YARNRC_FILES[@]}"; do
    if [ -e "$YARNRC_BACKUP/$i" ]; then cp -p "$YARNRC_BACKUP/$i" "$f"; else rm -f "$f"; fi
    i=$((i + 1))
  done
  rm -rf "$YARNRC_BACKUP"
  YARNRC_BACKUP=""
}

make_yarn_stub() { # make_yarn_stub <version>
  YARN_STUB=$(mktemp -d /tmp/sch-yarn-stub.XXXXXX)
  printf '#!/bin/sh\necho %s\n' "$1" > "$YARN_STUB/yarn"
  chmod 755 "$YARN_STUB" "$YARN_STUB/yarn"
}

summary_of() { # the summary task's msg, one line per entry
  echo "$1" | grep -A2 'Report protections that were NOT applied' | grep '"msg"' | sed 's/\\n/\n/g'
}

@test "summary: npm < 11.10, Yarn classic and a missing pip wrapper are listed, and nothing claims the rest applied" {
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  require_root "moves the image's uv aside"
  hide_uv || skip "no uv this test can hide"
  backup_yarnrc
  make_yarn_stub 1.22.22
  cd "$ROLE_DIR"
  run env PATH="$YARN_STUB:$PATH" ansible-playbook site.yml --connection=local --limit localhost \
    --tags npm,yarn,pip -e podman_enabled=false -e verify_protections=false -e socket_firewall_install=false
  restore_uv; rm -rf "$YARN_STUB"
  local sum; sum=$(summary_of "$output")
  echo "$sum"
  [ "$status" -eq 0 ]
  echo "$sum" | grep -q 'Yarn hardening — yarn 1.22.22 is Yarn classic, which never reads .yarnrc.yml'
  echo "$sum" | grep -q 'pip / pip3 wrapper — this run found no uv, so it did not deploy /usr/local/bin/pip or /usr/local/bin/pip3'
  # The wrappers are system-wide and outlive the apply that wrote them. Where an
  # earlier apply left one (this image's build did), "pip runs the real pip"
  # would be false: the entry has to say the old wrapper is still there.
  if grep -qx '# Managed by ansible-supply-chain-security' /usr/local/bin/pip 2>/dev/null; then
    echo "$sum" | grep -q 'The wrappers an earlier apply left there are still in place'
    if echo "$sum" | grep -q 'runs the real pip'; then echo "claims the real pip runs past a wrapper that is there" >&2; false; fi
  else
    echo "$sum" | grep -q '`pip install` runs the real pip'
  fi
  if echo "$sum" | grep -qE 'deployed /usr/local/bin/pip already does|Everything else in the role applied normally'; then
    echo "the summary still claims coverage it does not have" >&2
    false
  fi
  echo "$sum" | grep -q 'supply-chain-verify'
  local nv; nv=$(npm --version 2>/dev/null)
  if [ -n "$nv" ] && [ "$(printf '%s\n11.10.0\n' "$nv" | sort -V | head -1)" != 11.10.0 ]; then
    echo "$sum" | grep -q "npm publish-age gate — npm $nv does not implement min-release-age"
  else
    if echo "$sum" | grep -q 'npm publish-age gate'; then echo "npm $nv listed as lacking the gate" >&2; false; fi
  fi
}

# The no-uv entry has to describe the pip wrapper that is on disk. It used to
# describe only an earlier version's (runs any uv it can execute), so after a
# second account with no uv applied, it said `pip` runs the first account's uv
# while this version's wrapper refused that uv with exit 126 (MEASURED, Ubuntu
# 26.04). Runs the REAL detect and record tasks from tasks/uv.yml, lifted out
# by name as 32-* does for yarn, with uv_binary_path saying "no uv".
pip_no_uv_entry() {
  local dir task play out
  dir=$(mktemp -d)
  task="$dir/task.json"; play="$dir/play.yml"; out="$dir/out.txt"
  python3 - "$ROLE_DIR/tasks/uv.yml" "$task" <<'PY'
import json, sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
names = ("Look for pip wrappers an earlier apply left in place",
         "Record skipped protection — pip / pip3 wrapper")
t = [t for t in tasks if t.get("name", "").startswith(names)]
assert len(t) == 2, [x.get("name") for x in t]
json.dump(t, open(sys.argv[2], "w"))
PY
  cat > "$play" <<PLAY
- hosts: localhost
  connection: local
  gather_facts: false
  vars:
    uv_binary_path: {rc: 1, stdout: ""}
    pip_only_binary: true
  tasks:
    - ansible.builtin.include_tasks: $task
    - ansible.builtin.copy:
        content: "{{ (skipped_protections | default([])) | join('\n') }}\n"
        dest: $out
        mode: "0644"
PLAY
  ansible-playbook "$play" >/dev/null 2>&1 || { echo "playbook failed" >&2; rm -rf "$dir"; return 1; }
  cat "$out"; rm -rf "$dir"
}

@test "summary: with no uv, the pip entry describes the wrapper on disk, this version's or an earlier one's" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  grep -q '^sch_trusted()' /usr/local/bin/pip 2>/dev/null || skip "no pip wrapper from this version at /usr/local/bin/pip"
  require_root "swaps /usr/local/bin/pip for an earlier version's wrapper"
  run pip_no_uv_entry
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"runs the first uv that the caller owns, or that root owns"*"exit 126"*"exit 127"* ]]
  [[ "$output" != *"whoever owns it"* ]]

  # An earlier version's wrapper: the opening of main's (8281a6b), whose loop
  # takes the first uv it can execute.
  cp -p /usr/local/bin/pip "$BATS_TEST_TMPDIR/pip.saved"
  cat > /usr/local/bin/pip <<'EOF'
#!/bin/sh
# Managed by ansible-supply-chain-security
UV='/home/someone/.local/bin/uv'
for _c in /usr/local/bin/uv /usr/bin/uv "$UV" "$(command -v uv 2>/dev/null)"; do
  if [ -n "$_c" ] && [ -x "$_c" ]; then UV="$_c"; break; fi
done
exec "$UV" pip "$@"
EOF
  run pip_no_uv_entry
  cp -p "$BATS_TEST_TMPDIR/pip.saved" /usr/local/bin/pip
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"earlier version of this role"*"the /home/someone/.local/bin/uv recorded at that apply"*"whoever owns it"* ]]
  [[ "$output" != *"exit 126"* ]]
  grep -q '^sch_trusted()' /usr/local/bin/pip
}

@test "summary: Yarn 2.x-4.9 is listed without its age gate; Yarn 4.10+ is not listed" {
  [ -z "${SKIP_SLOW:-}" ] || skip "SKIP_SLOW set"
  require_root "re-renders root's ~/.yarnrc.yml for a stub Yarn and restores it afterwards"
  backup_yarnrc
  cd "$ROLE_DIR"
  make_yarn_stub 4.1.0
  run env PATH="$YARN_STUB:$PATH" ansible-playbook site.yml --connection=local --limit localhost \
    --tags yarn -e podman_enabled=false -e verify_protections=false -e socket_firewall_install=false
  rm -rf "$YARN_STUB"
  [ "$status" -eq 0 ]
  summary_of "$output" | grep -q 'Yarn publish-age gate — yarn 4.1.0 does not implement npmMinimalAgeGate (added in Yarn 4.10.0)'
  make_yarn_stub 4.10.3
  run env PATH="$YARN_STUB:$PATH" ansible-playbook site.yml --connection=local --limit localhost \
    --tags yarn -e podman_enabled=false -e verify_protections=false -e socket_firewall_install=false
  rm -rf "$YARN_STUB"
  [ "$status" -eq 0 ]
  if echo "$output" | grep -qE 'Yarn (hardening|publish-age gate) — yarn 4.10.3'; then
    echo "yarn 4.10.3 listed as missing a protection" >&2
    false
  fi
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

@test "check-mode: every changed_when:false probe is check-mode-safe (check_mode:false OR a not-ansible_check_mode guard)" {
  local missing=0
  for f in "$ROLE_DIR"/tasks/*.yml; do
    # A changed_when:false probe must not falsely run/report during a dry run.
    # Two valid ways: `check_mode: false` (run for real, report no change), or a
    # `when: ... not ansible_check_mode` guard that skips the task in check mode
    # entirely (the pattern tasks/verify.yml uses for the read-only verify probe
    # under ECH-152). Accept either, scanning the task block forward from the
    # changed_when line to the next task.
    while IFS= read -r lineno; do
      blk=$(awk -v s="$lineno" 'NR>=s { if (NR>s && /^- name: /) exit; print }' "$f")
      if ! echo "$blk" | grep -qE '^\s*check_mode:|not ansible_check_mode'; then
        echo "NOT check-mode-safe (needs check_mode:false or a not-ansible_check_mode guard) -> $(basename "$f"):$lineno" >&2
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
  # verify.yml does not run under --check, so the summary must not point at a
  # report "that follows" (it said so whenever verify_protections was true).
  if echo "$output" | grep -q 'supply-chain-verify report that follows'; then
    echo "the --check summary promises a verifier report that never runs" >&2
    false
  fi
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
