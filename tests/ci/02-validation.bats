#!/usr/bin/env bats
# Input validation and the fail-loud guards.
#
# Every case here is one where failing SILENTLY would be worse than failing:
# a disabled age gate or a half-applied run that still reports success is
# indistinguishable from a protected one at the terminal.

load helpers

setup() { common_setup; }

@test "release_age_hours=0 is rejected, not silently applied" {
  run harden RELEASE_AGE_HOURS=0 ECOSYSTEMS=npm
  [ "$status" -eq 2 ]
  [[ "$output" == *"silently disables the age gate"* ]]
}

@test "non-integer release_age_hours is rejected" {
  run harden RELEASE_AGE_HOURS="48 hours" ECOSYSTEMS=npm
  [ "$status" -eq 2 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "a leading-zero release_age_hours is read as decimal, not octal" {
  # Bash arithmetic reads 072 as octal 58. It passed validation and then gave
  # every derived window 58 hours while the summary said 72.
  run harden RELEASE_AGE_HOURS=072 ECOSYSTEMS=pnpm -- --emit=plain
  [ "$status" -eq 0 ]
  grep -rqs 'minimum-release-age=4320\|minimumReleaseAge: 4320' "$PNPM_DIR" "$TEST_HOME/.npmrc"
  run harden RELEASE_AGE_HOURS=09 ECOSYSTEMS=pnpm -- --emit=plain
  [ "$status" -eq 0 ]
}

@test "negative release_age_hours is rejected" {
  run harden RELEASE_AGE_HOURS=-5 ECOSYSTEMS=npm
  [ "$status" -eq 2 ]
}

@test "a sub-day age gate rounds npm UP to one day rather than to zero" {
  # 12/24 == 0 in integer division, and npm reads whole days. Rounding down
  # would silently disable the npm gate for anyone asking for a short window.
  stub_npm 11.19.1
  run harden RELEASE_AGE_HOURS=12 ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.npmrc" "min-release-age=1"
}

@test "missing HOME is refused" {
  run env -i PATH="$PATH" TMPDIR="$TEST_TMP" WRITE_ETC=false ECOSYSTEMS=npm \
    bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOME is unset"* ]]
}

@test "a HOME pointing at a non-directory is refused" {
  run env -i PATH="$PATH" HOME="$TEST_TMP/not-a-dir" TMPDIR="$TEST_TMP" \
    WRITE_ETC=false ECOSYSTEMS=npm bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 2 ]
}

@test "SUPPLY_CHAIN_HARDEN_SKIP exits early without hardening anything" {
  run harden SUPPLY_CHAIN_HARDEN_SKIP=true ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"intentionally skipped"* ]]
  [ ! -f "$TEST_HOME/.npmrc" ]
}

@test "the skip path still emits the full output set" {
  # A consumer reading steps.harden.outputs.* must not get undefined values
  # just because hardening was skipped.
  run harden SUPPLY_CHAIN_HARDEN_SKIP=true ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "ecosystems_hardened="
  assert_file_contains "$OUT_FILE" "release_age_hours=48"
  assert_file_contains "$OUT_FILE" "sfw_installed=false"
  assert_file_contains "$OUT_FILE" "tool_versions={}"
  assert_file_contains "$OUT_FILE" "env_file="
}

@test "an unknown ecosystem warns and is skipped, the rest still apply" {
  run harden ECOSYSTEMS=npm,nosuchtool,pip -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unknown ecosystem: 'nosuchtool'"* ]]
  assert_file_contains "$OUT_FILE" "ecosystems_hardened=npm,pip"
}

@test "trailing and doubled commas in the ecosystem list are tolerated" {
  run harden ECOSYSTEMS="npm,,pip," -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown ecosystem"* ]]
  assert_file_contains "$OUT_FILE" "ecosystems_hardened=npm,pip"
}

@test "ecosystem names are case- and whitespace-insensitive" {
  run harden ECOSYSTEMS=" NPM , Pip " -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "ecosystems_hardened=npm,pip"
}

@test "an env file directory that does not exist yet is created, not fatal" {
  run harden HARDENING_ENV_FILE="$TEST_TMP/deep/nested/h.env" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/deep/nested/h.env" ]
}

# ---- VM#3: the env file and the run record are not attacker-placeable ----
#
# MEASURED on old main (Ubuntu 26.04, --emit=plain): another local user
# pre-created /tmp/supply-chain-hardening.env with a payload; harden.sh exited 2,
# the AGENTS.md recipe's next line sourced it anyway, and the payload ran as the
# person hardening. A planted .outputs beside it scoped verify.sh down to
# "this job hardened: npm".

@test "env file: with no RUNNER_TEMP the default is per-user and 0700, never TMPDIR" {
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [ -f "$ENV_FILE" ] && [ -f "$OUT_FILE" ]
  [ ! -e "$TEST_TMP/supply-chain-hardening.env" ]
  [ ! -e "$TEST_TMP/supply-chain-hardening.outputs" ]
  # `ls -ld`, not GNU stat: this suite also runs on macOS.
  [ "$(ls -ld "$STATE_DIR" | cut -c1-10)" = drwx------ ]
  # 0644, not mktemp's 0600: a profile.d line for every user may source it.
  [ "$(ls -ld "$ENV_FILE" | cut -c1-10)" = -rw-r--r-- ]
  assert_file_contains "$OUT_FILE" "env_file=$ENV_FILE"
}

@test "env file: RUNNER_TEMP, when set, is still where it goes" {
  mkdir -p "$TEST_TMP/runner"
  run harden RUNNER_TEMP="$TEST_TMP/runner" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/runner/supply-chain-hardening.env" ]
  [ -f "$TEST_TMP/runner/supply-chain-hardening.outputs" ]
}

@test "env file: an existing file writable by others is refused, and a chained source never runs" {
  mkdir -p "$STATE_DIR"
  printf 'touch %s/planted-ran\n' "$TEST_TMP" > "$ENV_FILE"
  chmod 666 "$ENV_FILE"
  # The recipe as AGENTS.md now writes it.
  run env -i PATH="$PATH" HOME="$TEST_HOME" WRITE_ETC=false ECOSYSTEMS=npm \
    bash -c "bash '$HARDEN_SH' --emit=plain && source '$ENV_FILE'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to write the env file"* ]]
  [[ "$output" == *"$ENV_FILE"* ]]
  [[ "$output" == *"writable by group or others"* ]]
  [ ! -e "$TEST_TMP/planted-ran" ]
}

@test "env file: one owned by another user is refused before anything is written" {
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || skip "needs passwordless sudo to create a file owned by someone else"
  local other=nobody
  id -u "$other" >/dev/null 2>&1 || skip "no 'nobody' user"
  mkdir -p "$TEST_TMP/shared"
  echo "touch $TEST_TMP/planted-ran" > "$TEST_TMP/shared/h.env"
  chmod 644 "$TEST_TMP/shared/h.env"
  sudo -n chown "$other" "$TEST_TMP/shared/h.env"
  run harden HARDENING_ENV_FILE="$TEST_TMP/shared/h.env" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"belongs to another user"* ]]
  [ ! -f "$TEST_HOME/.npmrc" ]          # refused at admission: nothing hardened, nothing half-written
  [ "$(ls -ld "$TEST_TMP/shared/h.env" | awk '{print $3}')" = "$other" ]   # and not replaced either
}

@test "env file: a world-writable directory without the sticky bit is refused" {
  mkdir -p "$TEST_TMP/open" && chmod 777 "$TEST_TMP/open"
  run harden HARDENING_ENV_FILE="$TEST_TMP/open/h.env" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"no sticky bit"* ]]
}

# The directory checks walk every directory above the file, not only the one it
# is in. MEASURED on the first VM#3 fix: a world-writable ~/.cache (created by
# harden.sh itself under umask 0000) and another user's sticky directory were
# both let through, and in the second case that user replaced the file.

@test "env file: a world-writable directory ABOVE the file's directory is refused" {
  mkdir -p "$TEST_TMP/open/mine" && chmod 777 "$TEST_TMP/open" && chmod 755 "$TEST_TMP/open/mine"
  run harden HARDENING_ENV_FILE="$TEST_TMP/open/mine/h.env" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"is below $TEST_TMP/open, which every user can write to"* ]]
  [ ! -e "$TEST_TMP/open/mine/h.env" ]
  [ ! -f "$TEST_HOME/.npmrc" ]
}

@test "env file: a symlinked directory is judged by where it points" {
  # A symlink's own mode is lrwxrwxrwx on Linux. Judged by that, every
  # symlinked path would be refused; judged by nothing, an open target passes.
  mkdir -p "$TEST_TMP/safe" "$TEST_TMP/open"
  chmod 755 "$TEST_TMP/safe"; chmod 777 "$TEST_TMP/open"
  ln -s "$TEST_TMP/safe" "$TEST_TMP/to-safe"
  ln -s "$TEST_TMP/open" "$TEST_TMP/to-open"
  run harden HARDENING_ENV_FILE="$TEST_TMP/to-safe/h.env" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/safe/h.env" ]
  run harden HARDENING_ENV_FILE="$TEST_TMP/to-open/h.env" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"no sticky bit"* ]]
}

@test "env file: a sticky directory another user owns is refused" {
  # The sticky bit stops everyone EXCEPT the directory's owner, who can delete
  # the file and put their own in its place.
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || skip "needs passwordless sudo to create a directory owned by someone else"
  id -u nobody >/dev/null 2>&1 || skip "no 'nobody' user"
  sudo -n mkdir -m 1777 "$TEST_TMP/theirs"
  sudo -n chown nobody "$TEST_TMP/theirs"
  run harden HARDENING_ENV_FILE="$TEST_TMP/theirs/h.env" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"a sticky directory that another user (nobody) owns"* ]]
  [ ! -e "$TEST_TMP/theirs/h.env" ]
  [ ! -f "$TEST_HOME/.npmrc" ]
}

@test "env file: a sticky directory we own is accepted, with a warning that does not call it safe" {
  mkdir -m 1777 "$TEST_TMP/ours"
  chmod 1777 "$TEST_TMP/ours"      # mkdir -m is still filtered by some umasks
  run harden HARDENING_ENV_FILE="$TEST_TMP/ours/h.env" ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/ours/h.env" ]
  [[ "$output" == *"which every user can write to"*"once a reboot or a cleanup removes it"* ]]
  [[ "$output" != *"safe as written"* ]]
}

@test "env file: under umask 0000 every directory harden.sh creates is 0700, ~/.cache included" {
  # GitLab's Docker and Kubernetes executors run jobs under umask 0000. A plain
  # `mkdir -p` made ~/.cache drwxrwxrwx there, the parent of the 0700 leaf.
  [ ! -e "$TEST_HOME/.cache" ]
  run env -i PATH="$PATH" HOME="$TEST_HOME" GRADLE_USER_HOME="$TEST_HOME/.gradle" \
    TMPDIR="$TEST_TMP" WRITE_ETC=false ECOSYSTEMS=npm \
    bash -c "umask 0000; bash '$HARDEN_SH' --emit=plain"
  [ "$status" -eq 0 ]
  [ "$(ls -ld "$TEST_HOME/.cache" | cut -c1-10)" = drwx------ ]
  [ "$(ls -ld "$STATE_DIR" | cut -c1-10)" = drwx------ ]
  [ -f "$ENV_FILE" ]
}

@test "env file: under umask 0000 a directory created for an override is not world-writable" {
  # It would otherwise be created 0777 and then refused by the same run.
  run env -i PATH="$PATH" HOME="$TEST_HOME" GRADLE_USER_HOME="$TEST_HOME/.gradle" \
    TMPDIR="$TEST_TMP" WRITE_ETC=false ECOSYSTEMS=npm \
    HARDENING_ENV_FILE="$TEST_TMP/new/deeper/h.env" \
    bash -c "umask 0000; bash '$HARDEN_SH' --emit=plain"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/new/deeper/h.env" ]
  [ "$(ls -ld "$TEST_TMP/new" | cut -c9)" = - ]
  [ "$(ls -ld "$TEST_TMP/new/deeper" | cut -c9)" = - ]
}

@test "under umask 0000 nothing harden.sh writes is writable by group or others" {
  # MEASURED at 6c77f4e (root, umask 0000, the default of GitLab's Docker
  # executor): every per-user config and the directory it sat in was left
  # world-writable, 32 paths in all, plus /etc/uv. Any other account could
  # rewrite what the next build reads. Every ecosystem runs here, with stubs
  # for the tools CI lacks, so each writer and each tool harden.sh starts
  # (the go stub writes its env file the way `go env -w` does) is covered.
  # What this suite cannot reach is /etc (WRITE_ETC is false throughout); the
  # container measurements in the commit cover that half.
  umask 022
  local t
  for t in pnpm yarn bun composer cargo bundle deno mvn gradle dotnet poetry; do stub_bin "$t"; done
  stub_go_env
  umask 0000
  run harden -- --emit=plain
  umask 022
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.cargo/config.toml" ]
  [ -f "$TEST_HOME/.m2/settings.xml" ]
  [ -f "$TEST_HOME/.config/go/env" ]
  local bad
  bad=$(find "$TEST_HOME" "$TEST_BIN" "$TEST_TMP" -mindepth 1 \( -perm -0002 -o -perm -0020 \) ! -type l 2>/dev/null)
  [ -z "$bad" ] || { echo "writable by group or others:"; for t in $bad; do ls -ld "$t"; done; false; }
}

@test "env file: /dev/null is refused, not replaced" {
  run harden HARDENING_ENV_FILE=/dev/null ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"'/dev/null' exists and is not a regular file"* ]]
  [ -c /dev/null ]
}

@test "env file: an existing file is replaced, never written through" {
  # `: >` kept the inode, so whoever held it (a hard link, an open descriptor)
  # saw every line harden.sh wrote, and the other user appended to it after.
  mkdir -p "$STATE_DIR"
  echo OLD > "$ENV_FILE"
  chmod 644 "$ENV_FILE"     # under umask 002 it would be 0664, which is refused
  ln "$ENV_FILE" "$TEST_TMP/held-link"
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/held-link")" = OLD ]
  assert_file_contains "$ENV_FILE" "NPM_CONFIG_IGNORE_SCRIPTS"
}

@test "the run record gets the same protection as the env file" {
  mkdir -p "$STATE_DIR"
  : > "$OUT_FILE"; chmod 666 "$OUT_FILE"
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to write the run record"* ]]
  [[ "$output" == *"HARDENING_OUTPUT_FILE"* ]]
}

@test "plain mode says once that nothing refreshes the uv/pip cutoff" {
  run harden ECOSYSTEMS=npm,pip -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"age-gate cutoff is fixed at"*"re-run harden.sh"* ]]
  # A CI job re-hardens every run: the reminder is noise there.
  run harden GITHUB_ACTIONS=true GITHUB_ENV="$TEST_TMP/ghenv" GITHUB_OUTPUT="$TEST_TMP/ghout" \
             GITHUB_STEP_SUMMARY="$TEST_TMP/ghsum" ECOSYSTEMS=npm,pip
  [ "$status" -eq 0 ]
  [[ "$output" != *"age-gate cutoff is fixed at"* ]]
}

@test "an unwritable env file path fails loudly with the path named" {
  run env -i PATH="$PATH" HOME="$TEST_HOME" \
    HARDENING_ENV_FILE=/proc/cannot/write.env \
    WRITE_ETC=false ECOSYSTEMS=npm bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot write the env file"* ]]
  [[ "$output" == *"/proc/cannot/write.env"* ]]
}

@test "tool_versions is valid JSON" {
  run harden ECOSYSTEMS=npm,pip,cargo -- --emit=plain
  [ "$status" -eq 0 ]
  local tv
  tv=$(grep '^tool_versions=' "$OUT_FILE" | cut -d= -f2-)
  run node -e "JSON.parse(process.argv[1])" "$tv"
  [ "$status" -eq 0 ]
}

@test "reporting: an ecosystem whose only mechanism could not be applied reads NOT applied" {
  # deno has NO config file — a PATH wrapper is its entire mechanism. With deno
  # absent, nothing whatsoever is applied, and this used to report
  # "deno hardened" in the summary, the final line and the output.
  run harden ECOSYSTEMS=deno -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT applied: deno"* ]]
  assert_file_contains "$OUT_FILE" "ecosystems_ineffective=deno"
  assert_file_contains "$OUT_FILE" "^ecosystems_effective=$"
}

@test "reporting: the summary explains WHY an ecosystem is not in force" {
  run harden ECOSYSTEMS=deno -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not fully in force"* ]]
  [[ "$output" == *"PATH wrapper is the entire mechanism"* ]]
}

@test "reporting: a config-backed ecosystem with no wrapper reads degraded, not applied" {
  # cargo writes config AND needs a wrapper for --locked, which has no config
  # or env route at all. Absent cargo means partial, not full.
  run harden ECOSYSTEMS=cargo -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "ecosystems_degraded=cargo"
}

@test "reporting: yarn below 4.10 is degraded, not 'Fully applied' (VM#10)" {
  # MEASURED on old main with apt yarnpkg 4.1.0: "Fully applied | yarn" while a
  # release 13 hours old installed. npmMinimalAgeGate arrived in Yarn 4.10.0.
  stub_bin yarn 'case "${1:-}" in --version) echo "4.1.0" ;; *) echo STUB ;; esac'
  run harden ECOSYSTEMS=yarn -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"yarn 4.1.0 does NOT implement npmMinimalAgeGate"* ]]
  [[ "$output" != *"Fully applied | \`yarn\`"* ]]
  assert_file_contains "$OUT_FILE" "ecosystems_degraded=yarn"
  # Script blocking is still written: this is INERT, not a refusal.
  assert_file_contains "$TEST_HOME/.yarnrc.yml" "enableScripts: false"
}

@test "reporting: yarn classic is NOT applied, and yarn 4.10+ is" {
  stub_bin yarn 'case "${1:-}" in --version) echo "1.22.22" ;; *) echo STUB ;; esac'
  run harden ECOSYSTEMS=yarn -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"never reads .yarnrc.yml"* ]]
  assert_file_contains "$OUT_FILE" "ecosystems_ineffective=yarn"
  stub_bin yarn 'case "${1:-}" in --version) echo "4.10.3" ;; *) echo STUB ;; esac'
  run harden ECOSYSTEMS=yarn -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "ecosystems_effective=yarn"
  [[ "$output" != *"does NOT implement npmMinimalAgeGate"* ]]
}

@test "reporting: the cargo-cooldown hint names the switch this caller has (VM#14)" {
  # Old main told a plain-mode caller to set the ACTION INPUT
  # install_cargo_cooldown, which only action.yml reads.
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || skip "needs passwordless sudo to wrap cargo"
  stub_bin cargo
  run harden ECOSYSTEMS=cargo -- --emit=plain
  [[ "$output" == *"INSTALL_CARGO_COOLDOWN=true"* ]]
  [[ "$output" != *"install_cargo_cooldown: true"* ]]
  sudo -n rm -f "$(stub_real cargo)"; stub_bin cargo
  run harden GITHUB_ACTIONS=true GITHUB_ENV="$TEST_TMP/ghenv" GITHUB_OUTPUT="$TEST_TMP/ghout" \
             GITHUB_STEP_SUMMARY="$TEST_TMP/ghsum" ECOSYSTEMS=cargo
  [[ "$output" == *"install_cargo_cooldown: true"* ]]
}

@test "reporting: npm that cannot enforce the age gate is flagged at hardening time" {
  # min-release-age landed in npm 11.10.0. The version is already detected, so
  # the run can say so itself instead of leaving it to an opt-in verifier.
  have npm || skip "npm not installed"
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  # 11.10.0, not 11: this matched 1[1-9].* and took 11.5.1 for new enough.
  if npm_ge 11.10.0; then
    [[ "$output" != *"does NOT implement min-release-age"* ]]
  else
    [[ "$output" == *"does NOT implement min-release-age"* ]]
    [[ "$output" == *"Script blocking is unaffected"* ]]
    assert_file_contains "$OUT_FILE" "ecosystems_degraded=npm"
  fi
}

@test "reporting: the npm versions around the age gate's first release are told apart" {
  local v
  bare_path
  for v in 10.9.8 11.5.1 11.9.0; do
    stub_npm "$v"
    run harden PATH="$BARE_PATH" ECOSYSTEMS=npm -- --emit=plain
    [ "$status" -eq 0 ]
    [[ "$output" == *"npm $v does NOT implement min-release-age"* ]] || { echo "$v: $output"; false; }
    grep -qx 'ecosystems_degraded=npm' "$OUT_FILE"
  done
  for v in 11.10.0 11.21.3 12.2.3; do
    stub_npm "$v"
    run harden PATH="$BARE_PATH" ECOSYSTEMS=npm -- --emit=plain
    [ "$status" -eq 0 ]
    [[ "$output" != *"does NOT implement min-release-age"* ]] || { echo "$v: $output"; false; }
    grep -qx 'ecosystems_effective=npm' "$OUT_FILE"
  done
}

@test "reporting: a fully applied ecosystem says so without noise" {
  run harden ECOSYSTEMS=pip -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "ecosystems_effective=pip"
  [[ "$output" != *"Not fully in force"* ]]
}

@test "packaging: both scripts run by path, the way the action.yml files call them" {
  # action/action.yml runs `${{ github.action_path }}/harden.sh` and
  # action/verify/action.yml runs `"${{ github.action_path }}/../verify.sh"`:
  # by path, with no interpreter in front. Everything else in this suite calls
  # them through `bash`, which never needs the execute bit, so commit 7f51aac
  # could drop it from verify.sh (100755 -> 100644) with every test still
  # passing, while every consumer of the verify action got rc=126 "Permission
  # denied" and no rows (MEASURED from a `git archive` of that tree).
  local root="$BATS_TEST_DIRNAME/../.." f mode
  # The premise: the action files still call the scripts by path.
  grep -qF 'run: ${{ github.action_path }}/harden.sh' "$root/action/action.yml"
  grep -qF '"${{ github.action_path }}/../verify.sh" "${args[@]}"' "$root/action/verify/action.yml"
  run env -i PATH="$PATH" HOME="$TEST_HOME" "$root/action/harden.sh" --help
  [ "$status" -eq 0 ]
  run env -i PATH="$PATH" HOME="$TEST_HOME" "$root/action/verify/../verify.sh" --help
  [ "$status" -eq 0 ]
  # A checkout's file mode follows git's, but a tree copied without modes would
  # pass the lines above for the wrong reason, so check what git records too.
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for f in action/harden.sh action/verify.sh; do
      mode=$(git -C "$root" ls-files -s -- "$f" | cut -d' ' -f1)
      [ "$mode" = 100755 ] || { echo "$f is mode $mode in git, not 100755"; return 1; }
    done
  fi
}
