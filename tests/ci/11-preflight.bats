#!/usr/bin/env bats
# harden.sh --preflight: what applying would meet, before anything is written.
#
# Two things matter here. It must change nothing, because the agent running it
# has not asked the host's owner yet, and a preview that changes things is the
# change. And its judgement of "would stop" must be the apply's: the same files,
# the same markers, the same classification as tasks/preflight.yml, so a host it
# clears is not one the play then refuses.

load helpers

setup() { common_setup; }

ROOT="${BATS_TEST_DIRNAME}/../.."

# Run the preflight with a tidy PATH: only the test bin and the directories the
# basic utilities live in, so nothing here reaches the host's package managers.
BASE_PATH=""
base_path() {
  local d="$BATS_TEST_TMPDIR/base" t p
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    for t in bash sh awk basename cat cksum cmp cp cut date diff dirname env find grep head hostname id ls mkdir od printf readlink rm sed sha256sum shasum sort stat tail tr uname wc xargs; do
      p=$(type -P "$t" 2>/dev/null) || continue
      case "$p" in /*) ln -s "$p" "$d/$t" ;; esac
    done
  fi
  BASE_PATH="$d"
}

# preflight [args...]: run harden.sh --preflight with a clean environment.
preflight() {
  base_path
  env -i PATH="${TEST_BIN}:${PASSWD_BIN}:${BASE_PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    ${PF_ENV[@]+"${PF_ENV[@]}"} bash "$HARDEN_SH" --preflight "$@"
}

# ansible_at <version>: an ansible-playbook whose own package says <version>.
# The preflight reads the package, so a launcher that runs would be a write: its
# interpreter here records a run instead.
ansible_at() {
  local v="$BATS_TEST_TMPDIR/ansible-venv"
  mkdir -p "$v/bin" "$v/lib/python3.12/site-packages/ansible"
  printf "# release\n__version__ = '%s'\n" "$1" > "$v/lib/python3.12/site-packages/ansible/release.py"
  printf '#!/bin/sh\ntouch "%s"\n' "$BATS_TEST_TMPDIR/ansible-ran" > "$v/bin/python3"
  chmod +x "$v/bin/python3"
  printf '#!%s\nnot python\n' "$v/bin/python3" > "${TEST_BIN}/ansible-playbook"
  chmod +x "${TEST_BIN}/ansible-playbook"
}

# Snapshot: every path under the home and the scratch directory, with size and
# checksum. Compared before and after a run.
snapshot() {
  local d
  for d in "$TEST_HOME" "$TEST_TMP" "$TEST_BIN"; do
    ( cd "$d" && find . -print0 | xargs -0 ls -ldn 2>/dev/null | awk '{print $1, $3, $4, $5, $NF}'
      find . -type f -print0 | xargs -0 cksum 2>/dev/null )
  done | sort
}

@test "preflight writes nothing: home, scratch and state directory are the same before and after" {
  printf '%s\n' "ignore-scripts=false" > "$TEST_HOME/.npmrc"
  mkdir -p "$TEST_HOME/.cargo" "$TEST_HOME/.m2"
  echo '<settings/>' > "$TEST_HOME/.m2/settings.xml"
  # Every tool the preflight asks for a version, stubbed so a write would show:
  # a version command that touched the home would be a write it claims not to make.
  local t
  for t in node npm uv bun deno go rustc cargo python3 gradle mvn dotnet composer bundle gem yarn pnpm; do
    stub_bin "$t" 'case "${1:-}" in --version|-V|version) echo 9.9.9 ;; esac; exit 0'
  done
  local before after marker="$BATS_TEST_TMPDIR/before"
  before=$(snapshot)
  # Modification times too, not only names and contents: a marker a second
  # older than the run, so a file rewritten with the same bytes still shows.
  touch "$marker"; sleep 1
  run preflight
  [[ "$output" == *"gradle (version not read) "* ]]     # the stubs were there to be asked
  after=$(snapshot)
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after")
  [ -z "$(find "$TEST_HOME" "$TEST_TMP" -newer "$marker" -print)" ] || { find "$TEST_HOME" "$TEST_TMP" -newer "$marker" -print; return 1; }
  [ ! -e "$STATE_DIR" ]
  [ ! -e "$TEST_HOME/.cache" ]
}

@test "preflight: a tool whose version command writes is not asked; those asked write nothing" {
  # The allowlist (_pf_version) is the ones measured to write nothing. This
  # checks the SHAPE: stubs that create a file when run for any command, so only
  # the ones the preflight actually runs leave a marker.
  local t marker="$BATS_TEST_TMPDIR/asked"
  for t in node uv bun deno go rustc cargo python3 gradle mvn dotnet composer bundle gem poetry npq-hero sfw; do
    stub_bin "$t" "echo '$t' >> '$marker'
case \"\${1:-}\" in --version|-V|version) echo 9.9.9 ;; esac"
  done
  run preflight
  [ "$status" -ne 2 ]
  # go writes telemetry for any command, `go version` included (MEASURED, 1.24.2).
  for t in go gradle mvn dotnet composer bundle gem poetry npq-hero sfw; do
    ! grep -qx "$t" "$marker" || { echo "preflight ran $t"; return 1; }
  done
  # The ones it does ask: a version in the output.
  [[ "$output" == *"node 9.9.9 "* ]]
  [[ "$output" == *"uv 9.9.9 "* ]]
  [[ "$output" == *"gradle (version not read) "* ]]
}

@test "preflight: a rustup proxy is not run in a home with no rustup state, where running it writes one" {
  # MEASURED on GitHub's macos-15-intel (Homebrew's rustup): `rustc --version` wrote
  # ~/.rustup/settings.toml, so the preflight changed the home it was describing.
  stub_bin rustup 'mkdir -p "${RUSTUP_HOME:-$HOME/.rustup}"; : > "${RUSTUP_HOME:-$HOME/.rustup}/settings.toml"
echo "${0##*/} 1.95.0 (stub)"'
  local t
  for t in rustc cargo; do ln -sf rustup "$TEST_BIN/$t"; done
  run preflight
  [ ! -e "$TEST_HOME/.rustup" ]
  [[ "$output" == *"rustc (version not read) ($TEST_BIN/rustc)"* ]]
  # A hard link is the same proxy.
  for t in rustc cargo; do rm -f "$TEST_BIN/$t"; ln "$TEST_BIN/rustup" "$TEST_BIN/$t"; done
  run preflight
  [ ! -e "$TEST_HOME/.rustup" ]
  # FIXTURE CONTROL: with rustup's state there it is asked, so the version is shown.
  mkdir -p "$TEST_HOME/.rustup"; : > "$TEST_HOME/.rustup/settings.toml"
  run preflight
  [[ "$output" == *"rustc 1.95.0 ($TEST_BIN/rustc)"* ]]
}

@test "preflight: ansible-core's version comes from its package, and nothing is started to read it" {
  # `ansible-playbook --version` creates ~/.ansible (MEASURED, 2.16.3).
  ansible_at 2.21.6
  run preflight
  [[ "$output" == *"ansible-core 2.21.6 ($TEST_BIN/ansible-playbook)"* ]] || { echo "$output"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/ansible-ran" ]
  [ ! -e "$TEST_HOME/.ansible" ]
  # A layout it does not know: said, not guessed, and still not started.
  printf '#!/bin/sh\ntouch "%s"\n' "$BATS_TEST_TMPDIR/ansible-ran" > "${TEST_BIN}/ansible-playbook"
  run preflight
  [[ "$output" == *"ansible-core (version not read)"* ]]
  [[ "$output" == *"its version could not be read without starting it"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/ansible-ran" ]
}

@test "preflight: Ansible missing is a STOP, and the exit code says so" {
  run preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"STOP  ansible-playbook not found"* ]]
  [[ "$output" == *"harden.sh --emit=plain"* ]]
  [[ "$output" == *"wait for their answer"* ]]
}

@test "preflight: an Ansible new enough, and nothing in the way, says so and exits 0" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: a different report"
  # This machine's own /etc is read too, and GitHub's Ubuntu image ships an
  # /etc/pip.conf. With a file there that is not this project's, that STOP and no
  # other is the right answer.
  local f foreign=0
  for f in /etc/npmrc /etc/pip.conf /etc/uv/uv.toml; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    grep -qE 'Managed by (ansible-supply-chain-security|supply-chain-harden)' "$f" || foreign=$((foreign + 1))
  done
  stub_bin sudo 'case "$1" in --version) echo "Sudo version 1.9.15" ;; -n) shift; [ "$1" = true ] ;; *) exit 1 ;; esac'
  ansible_at 2.21.6
  # The play refuses a Mac, whatever else is right; this is about the rest.
  stub_bin uname 'echo Linux'
  stub_bin date 'case "$*" in --version) echo "date (GNU coreutils) 9.4" ;; "-u -d @0 "*) echo 1970-01-01T00:00:00Z ;; *) exec /bin/date "$@" ;; esac'
  run preflight
  [[ "$output" == *"ansible-core 2.21.6"* ]]
  if [ "$foreign" -gt 0 ]; then
    [ "$(grep -cE '^ +STOP  ' <<<"$output")" -eq "$foreign" ] || { echo "$output"; return 1; }
    [ "$(grep -cE '^ +STOP  /etc/[^:]*: not written by this project' <<<"$output")" -eq "$foreign" ]
    [ "$status" -eq 1 ]
    return 0
  fi
  [[ "$output" == *"Nothing above would stop the play"* ]]
  [[ "$output" == *"wait for their OK"* ]]
  [ "$status" -eq 0 ]
}

@test "preflight: a Mac is a STOP that names harden.sh, with no way past it; Linux is not" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: a different report"
  # MEASURED on hosted macos-15: the preflight cleared the host ("Nothing above
  # would stop the play") and the play then died half way, after /etc/npmrc.
  stub_bin sudo 'case "$1" in --version) echo "Sudo version 1.9.15" ;; -n) shift; [ "$1" = true ] ;; *) exit 1 ;; esac'
  ansible_at 2.21.6
  stub_bin date 'case "$*" in --version) echo "date (GNU coreutils) 9.4" ;; *) exec /bin/date "$@" ;; esac'
  stub_bin uname 'case "${1:-}" in -s|"") echo Darwin ;; *) echo Darwin ;; esac'
  run preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"STOP  it is macOS, and the Ansible role supports Linux only"*"action/harden.sh --emit=plain"* ]] || { echo "$output"; false; }
  [[ "$output" != *"Nothing above would stop the play"* ]]
  # Nor does a date that is not GNU date send anyone off to install one there.
  stub_bin date 'case "$*" in --version) echo "date: illegal option -- -" >&2; exit 1 ;; *) exec /bin/date "$@" ;; esac'
  run preflight
  [ "$status" -eq 1 ]
  [[ "$output" != *"GNU date"* && "$output" != *"coreutils"* && "$output" != *"brew"* ]] || { echo "$output"; false; }
  # On Linux the same date is a STOP of its own, and macOS is not mentioned.
  stub_bin uname 'echo Linux'
  stub_bin date 'case "$*" in --version) exit 1 ;; "-u -d "*) exit 1 ;; *) exec /bin/date "$@" ;; esac'
  run preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"STOP  this machine's date is not GNU date"* ]] || { echo "$output"; false; }
  [[ "$output" != *"macOS"* && "$output" != *"brew"* ]] || { echo "$output"; false; }
}

@test "preflight: the role's macOS refusal is its first task, and no text sends a Mac past it" {
  python3 -c 'import yaml' 2>/dev/null || skip "needs python3-yaml"
  python3 - "$ROOT" <<'PY'
import sys, yaml
root = sys.argv[1]
tasks = yaml.safe_load(open(root + "/tasks/preflight.yml", encoding="utf-8"))
first = tasks[0]
assert "ansible.builtin.fail" in first, first
assert "ansible_system" in str(first["when"]) and "Darwin" in str(first["when"]), first["when"]
assert "harden.sh" in first["ansible.builtin.fail"]["msg"]
assert "become" not in first
main = yaml.safe_load(open(root + "/tasks/main.yml", encoding="utf-8"))
assert main[0]["ansible.builtin.include_tasks"]["file"] == "preflight.yml"
for f in ("tasks/preflight.yml", "action/harden.sh", "defaults/main.yml"):
    t = open(root + "/" + f, encoding="utf-8").read()
    assert "brew install coreutils" not in t and "gnubin" not in t, f
PY
}

@test "preflight: an Ansible below 2.14 is a STOP" {
  ansible_at 2.12.10
  run preflight
  [[ "$output" == *"STOP  ansible-core 2.12.10 is below 2.14"* ]]
  [ "$status" -eq 1 ]
}

# The sudo-rs prompt ansible-core cannot answer (tasks/preflight.yml). Needs a
# `sudo` that reports sudo-rs and asks for a password.
sudo_rs_stub() {
  stub_bin sudo 'case "$*" in "--version") echo "sudo-rs 0.2.13" ;; "-n true") exit 1 ;; *) exit 1 ;; esac'
}

@test "preflight: sudo-rs with a password prompt and an affected ansible-core is a STOP, and a fixed one is not" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: sudo is not consulted"
  sudo_rs_stub
  local v
  for v in 2.16.14 2.20.10 2.21.5; do
    ansible_at "$v"
    run preflight
    [[ "$output" == *"STOP  this host's sudo is sudo-rs and asks for a password, which ansible-core $v cannot answer"* ]] || { echo "$v: $output"; return 1; }
    [ "$status" -eq 1 ]
  done
  for v in 2.20.11 2.21.6 2.22.0; do
    ansible_at "$v"
    run preflight
    [[ "$output" != *"sudo-rs"* ]] || { echo "$v: $output"; return 1; }
  done
}

@test "preflight: a per-user config this project did not write is a STOP; its own and dotnet's first-run are not" {
  ansible_at 2.21.6
  stub_bin cargo 'echo cargo 1.100.0'
  mkdir -p "$TEST_HOME/.cargo"
  printf '[registries.corp]\nindex = "sparse+https://corp.invalid/"\n' > "$TEST_HOME/.cargo/config.toml"
  run preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"STOP  $TEST_HOME/.cargo/config.toml: not exactly what this project last wrote"*"accept_user_config_overwrite=true"* ]]
  # Ours, by the marker the role writes first.
  printf '# Cargo supply-chain hardening — system defaults.\n[net]\nretry = 3\n' > "$TEST_HOME/.cargo/config.toml"
  run preflight
  [[ "$output" == *"$TEST_HOME/.cargo/config.toml: exactly what this project last wrote"* ]]
  # CARGO_HOME moves it, as the role resolves it.
  PF_ENV=(CARGO_HOME="$BATS_TEST_TMPDIR/ch")
  mkdir -p "$BATS_TEST_TMPDIR/ch"; echo 'x' > "$BATS_TEST_TMPDIR/ch/config.toml"
  run preflight
  PF_ENV=()
  [[ "$output" == *"STOP  $BATS_TEST_TMPDIR/ch/config.toml"* ]]
  # dotnet's first-run NuGet.Config (nuget.org only) does not stop it.
  stub_bin dotnet 'echo 8.0.134'
  mkdir -p "$TEST_HOME/.nuget/NuGet"
  printf '\357\273\277<?xml version="1.0" encoding="utf-8"?>\n<configuration>\n  <packageSources>\n    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />\n  </packageSources>\n</configuration>\n' > "$TEST_HOME/.nuget/NuGet/NuGet.Config"
  run preflight
  [[ "$output" == *"$TEST_HOME/.nuget/NuGet/NuGet.Config: dotnet's own first-run file"* ]]
  # A settings.xml is checked only where Maven (or a JDK) would read it.
  mkdir -p "$TEST_HOME/.m2"; echo '<settings/>' > "$TEST_HOME/.m2/settings.xml"
  run preflight
  [[ "$output" != *"settings.xml"* ]]
  stub_bin mvn 'echo "Apache Maven 3.9.9"'
  run preflight
  [[ "$output" == *"STOP  $TEST_HOME/.m2/settings.xml: not exactly what this project last wrote"* ]]
}

@test "preflight: Maven's settings.xml is judged in the passwd home, where the run writes it, by both surfaces" {
  # Maven reads <user.home>/.m2/settings.xml, and the JVM takes user.home from the
  # passwd entry, not $HOME (ucf_jvm_home). A stub getent names a directory of this
  # test's as the passwd home.
  local pw="$BATS_TEST_TMPDIR/pwhome"
  mkdir -p "$pw/.m2" "$TEST_HOME/.m2"
  echo '<settings/>' > "$pw/.m2/settings.xml"
  echo '<settings/>' > "$TEST_HOME/.m2/settings.xml"
  stub_bin getent "echo 'u:x:$(id -u):$(id -g)::$pw:/bin/sh'"
  stub_bin mvn 'echo "Apache Maven 3.9.9"'
  run preflight
  [[ "$output" == *"STOP  $pw/.m2/settings.xml: not exactly what this project last wrote"* ]] || { echo "$output"; false; }
  [[ "$output" != *"$TEST_HOME/.m2/settings.xml"* ]]
  # The role's preflight runs the same block, from files/user-config.sh.
  base_path
  run env -i PATH="${TEST_BIN}:${BASE_PATH}" HOME="$TEST_HOME" bash "$ROOT/files/user-config.sh" classify maven
  [ "$status" -eq 42 ]
  [ "$output" = "foreign $pw/.m2/settings.xml" ]
  # The control: with the passwd home at HOME, HOME's file is the one judged.
  stub_bin getent "echo 'u:x:$(id -u):$(id -g)::$TEST_HOME:/bin/sh'"
  run preflight
  [[ "$output" == *"STOP  $TEST_HOME/.m2/settings.xml: not exactly what this project last wrote"* ]]
  [[ "$output" != *"$pw/.m2/settings.xml"* ]]
}

@test "preflight: sudo is only asked whether it needs a password, never to read or run anything else" {
  # Nobody has agreed to anything yet. An earlier version read /root/.yarnrc.yml
  # through passwordless sudo.
  [ "$(id -u)" -ne 0 ] || skip "running as root: sudo is not consulted"
  stub_bin sudo "printf '%s\\n' \"\$*\" >> '$BATS_TEST_TMPDIR/sudo-calls'
case \"\$1\" in --version) echo 'Sudo version 1.9.15' ;; esac
exit 0"
  ansible_at 2.21.6
  run preflight
  [ -s "$BATS_TEST_TMPDIR/sudo-calls" ]
  [ -z "$(grep -vxE -e '-n true|--version' "$BATS_TEST_TMPDIR/sudo-calls")" ] || { cat "$BATS_TEST_TMPDIR/sudo-calls"; return 1; }
  [[ "$output" == *"/root/.yarnrc.yml: not looked at"* ]]
}

@test "preflight: run as root under sudo, with root's HOME, is a STOP" {
  # The role refuses it because per-user config would land in root's home. This
  # host's own uid decides which branch runs, so a stub id that says 0.
  [ "$(id -u)" -ne 0 ] || skip "running as root already"
  stub_bin id 'case "$*" in -u) echo 0 ;; -un) echo root ;; *) exec /usr/bin/id "$@" ;; esac'
  ansible_at 2.21.6
  PF_ENV=(SUDO_USER=alice HOME=/root)
  run preflight
  [[ "$output" == *"STOP  running as root under sudo from 'alice'"* ]]
  [ "$status" -eq 1 ]
  # The role's guard is about HOME: with the user's own HOME kept (sudo -E) it
  # is not refused, and neither is a root login.
  PF_ENV=(SUDO_USER=alice)
  run preflight
  [[ "$output" != *"STOP  running as root"* ]]
  PF_ENV=(HOME=/root)
  run preflight
  PF_ENV=()
  [[ "$output" == *"running as root: the role hardens root's own home"* ]]
}

@test "preflight=REPO prints the repo's --suggest output too" {
  ansible_at 2.21.6
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  printf "lockfileVersion: '9.0'\npackages:\n  sharp@0.33.0:\n    requiresBuild: true\n" > "$repo/pnpm-lock.yaml"
  printf 'no-build = false\n' > "$repo/uv.toml"
  run preflight "--preflight=$repo"
  [[ "$output" == *"What --suggest says for $repo:"* ]]
  [[ "$output" == *'"pnpm_built_dependencies": ["sharp"]'* ]]
  [[ "$output" == *"uv.toml: no-build = false"* ]]
}

@test "preflight: no HOME is a STOP with an explanation, not a crash" {
  base_path
  run env -i PATH="${TEST_BIN}:${BASE_PATH}" TMPDIR="$TEST_TMP" bash "$HARDEN_SH" --preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"STOP  HOME is not set"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"unbound variable"* ]]
}

@test "preflight is advertised in --help" {
  run harden -- --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--preflight"* ]]
}

# ------------------------------------------------- the same judgement as the role

@test "preflight: the file list and markers are tasks/preflight.yml's" {
  # The preflight names these; a list that drifted would clear a host the play
  # then stops on.
  grep -q 'for f in /etc/npmrc /etc/pip.conf /etc/uv/uv.toml; do' "$ROOT/tasks/preflight.yml"
  grep -q 'for f in /etc/npmrc /etc/pip.conf /etc/uv/uv.toml; do' "$ROOT/action/harden.sh"
  grep -q 'Managed by (ansible-supply-chain-security|supply-chain-harden)' "$ROOT/tasks/preflight.yml"
  grep -q "local marker='Managed by (ansible-supply-chain-security|supply-chain-harden)'" "$ROOT/action/harden.sh"
}

@test "preflight: the per-user classification is the role's: the same code, and the same files" {
  # Both run the block in files/user-config.sh; the role's preflight runs that file.
  local role="$BATS_TEST_TMPDIR/role" act="$BATS_TEST_TMPDIR/act" k
  sed -n '/^# >>> user_config$/,/^# <<< user_config$/p' "$ROOT/files/user-config.sh" > "$role"
  sed -n '/^# >>> user_config$/,/^# <<< user_config$/p' "$ROOT/action/harden.sh" > "$act"
  grep -q '^user_cfg_class() {' "$role"
  diff "$role" "$act"
  grep -q 'ansible.builtin.script: "../files/user-config.sh classify {{ sch_user_cfg_kinds }}"' "$ROOT/tasks/preflight.yml"
  # no classifier of its own is left in either
  ! grep -nE 'classify\(\)|strict-checksums|serviceIndex' "$ROOT/tasks/preflight.yml" || false
  [ "$(grep -c 'user_cfg_class()' "$ROOT/action/harden.sh")" -eq 1 ]
  # and the role asks about every kind the block knows, once each
  # shellcheck disable=SC1090
  . "$role"
  for k in $UCF_KINDS; do
    [ "$(sed -n '/sch_user_cfg_tags:/,/sch_user_cfg_kinds:/p' "$ROOT/tasks/preflight.yml" | grep -cE "^ +$k: \[")" -eq 1 ] || { echo "$k"; return 1; }
    [ "$k" = composer-home ] || [ -n "$(HOME=/h ucf_path "$k")" ]
  done
  [ "$(sed -n '/sch_user_cfg_tags:/,/sch_user_cfg_kinds:/p' "$ROOT/tasks/preflight.yml" | grep -cE '^ +[a-z-]+: \[')" -eq 13 ]
}

@test "preflight: the ansible-core versions it calls affected are the role's" {
  # tasks/preflight.yml: version('2.20.11','<') or (>= 2.21.0 and < 2.21.6).
  grep -q "version('2.20.11', '<')" "$ROOT/tasks/preflight.yml"
  grep -q "version('2.21.0', '>=')" "$ROOT/tasks/preflight.yml"
  grep -q "version('2.21.6', '<')" "$ROOT/tasks/preflight.yml"
  grep -q 'version_ge "\$ver" 2.20.11' "$ROOT/action/harden.sh"
  grep -q 'version_ge "\$ver" 2.21.0 && ! version_ge "\$ver" 2.21.6' "$ROOT/action/harden.sh"
}
