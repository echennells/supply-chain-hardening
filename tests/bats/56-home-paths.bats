#!/usr/bin/env bats
# Which home each write lands in, when the HOME the role runs with is not the
# passwd home of its uid (an agent VM running as root with HOME=/home/hatch, a
# container run with -u, sudo -E):
#
#   - gradle's init script and Maven's settings.xml go to the passwd home,
#     looked up by uid (tasks/passwd_home.yml), because the JVM takes user.home
#     from there. MEASURED (maven 3.10.2, gradle 8.14.8, temurin 21.0.13.1, as
#     root with HOME=/tmp/h): both read /root. Not ansible_user_dir, which
#     follows $LOGNAME/$USER; the run summary names both homes.
#
# The JVM tests run the real task files through include_role, with a stub java
# for the tool gate (no JDK in the test image). They run as throwaway accounts
# whose passwd home is a temp dir, except the one that is about root itself.

load setup

ACCT=schjvm
NOHOME_ACCT=schnohome

setup() {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible-playbook not installed"
  D=$(mktemp -d /tmp/sch-home-paths.XXXXXX)
  chmod 755 "$D"
  mkdir -p "$D/bin" "$D/o"
  chmod 1777 "$D/o"   # the throwaway accounts write their results here
  printf '#!/bin/sh\necho "openjdk version 21" >&2\n' > "$D/bin/java"
  chmod 755 "$D/bin" "$D/bin/java"
  # The summary task, lifted from tasks/main.yml by name.
  python3 - "$ROLE_DIR/tasks/main.yml" "$D/summary.json" <<'PY'
import json, sys, yaml
t = [t for t in yaml.safe_load(open(sys.argv[1])) if t.get("name") == "Report files written outside $HOME"]
assert len(t) == 1, "expected the summary task in tasks/main.yml"
json.dump(t, open(sys.argv[2], "w"))
PY
  cat > "$D/pb.yml" <<'YML'
- hosts: localhost
  connection: local
  gather_facts: true
  tasks:
    - ansible.builtin.include_role:
        name: "{{ role_dir }}"
        tasks_from: gradle.yml
    - ansible.builtin.include_role:
        name: "{{ role_dir }}"
        tasks_from: maven.yml
      when: with_maven | default(true) | bool
    - ansible.builtin.include_tasks: "{{ summary_task }}"
    - ansible.builtin.copy:
        dest: "{{ out }}"
        mode: "0644"
        content: |
          user_dir={{ ansible_user_dir }}
          {% for n in sch_home_notes | default([]) %}
          note={{ n }}
          {% endfor %}
          {% for n in skipped_protections | default([]) %}
          skip={{ n }}
          {% endfor %}
YML
  chmod 644 "$D/pb.yml" "$D/summary.json"
  ROOT_HOME=$(getent passwd 0 | cut -d: -f6)
}

teardown() {
  [ -n "${D:-}" ] || return 0
  local a
  for a in "$ACCT" "$NOHOME_ACCT"; do
    if [ "$(id -u)" = 0 ] && id "$a" >/dev/null 2>&1; then userdel "$a" 2>/dev/null || true; fi
  done
  # What the root test wrote into root's passwd home, when it was not there before.
  if [ -f "$D/root-had-none" ]; then
    rm -f "$ROOT_HOME/.gradle/init.d/supply-chain-security.gradle"
    rmdir "$ROOT_HOME/.gradle/init.d" "$ROOT_HOME/.gradle" 2>/dev/null || true
  fi
  rm -rf "$D"
}

# make_account <name> <passwd home>: an account whose passwd home is that path
make_account() {
  if id "$1" >/dev/null 2>&1; then userdel "$1" 2>/dev/null || true; fi
  useradd -M -d "$2" -s /bin/bash "$1"
}

# jvm_play_as <account> <HOME> [VAR=value...]: the playbook above as that account,
# with nothing in its environment but what is given here. Output in $output.
# Ansible's own temp dirs are pinned under $D. Without that, the test image's
# ansible put its remote tmp in the home of the account $USER names (with
# USER=root, /root/.ansible/tmp, which this account cannot write), and otherwise
# in the passwd home, which the second account does not have.
jvm_play_as() {
  local who="$1" home="$2"; shift 2
  run su "$who" -s /bin/bash -c "cd '$D' && env -i HOME='$home' PATH='$D/bin:/usr/local/bin:/usr/bin:/bin' LC_ALL=C.UTF-8 \
    ANSIBLE_REMOTE_TMP='$D/o/rtmp.$who' ANSIBLE_LOCAL_TEMP='$D/o/ltmp.$who' $* \
    ansible-playbook -i localhost, '$D/pb.yml' -e role_dir='$ROLE_DIR' -e summary_task='$D/summary.json' -e out='$D/o/out' 2>&1"
}

@test "jvm home: with USER and LOGNAME naming another account, gradle and maven files land in the uid's passwd home" {
  require_root "creates the $ACCT account"
  make_account "$ACCT" "$D/pw"
  mkdir -p "$D/pw" "$D/fake"
  chown "$ACCT:" "$D/pw" "$D/fake"
  jvm_play_as "$ACCT" "$D/fake" USER=root LOGNAME=root
  echo "$output" | grep -E 'fatal|FAILED|PLAY RECAP' -A2 | head -12
  [ "$status" -eq 0 ]
  # FIXTURE CONTROL: in this environment the env-derived fact the gradle task used
  # to read names root's home, not this uid's.
  grep -qx "user_dir=$ROOT_HOME" "$D/o/out"
  [ "$ROOT_HOME" != "$D/pw" ]
  # the files are in the uid's passwd home, and nothing went under $HOME
  grep -q 'Managed by ansible-supply-chain-security' "$D/pw/.gradle/init.d/supply-chain-security.gradle"
  grep -q 'Managed by ansible-supply-chain-security' "$D/pw/.m2/settings.xml"
  [ ! -e "$D/fake/.gradle" ]
  [ ! -e "$D/fake/.m2" ]
  # each says where it went, naming both homes, in the facts and in the summary
  grep -qF "note=gradle: \$HOME is '$D/fake' but the passwd home is '$D/pw'" "$D/o/out"
  grep -qF "the init script goes to $D/pw/.gradle/init.d, where the JVM looks, not under \$HOME." "$D/o/out"
  grep -qF "note=maven: \$HOME is '$D/fake' but the passwd home is '$D/pw'" "$D/o/out"
  grep -qF "settings.xml goes to $D/pw/.m2, where maven looks, not under \$HOME." "$D/o/out"
  echo "$output" | grep -qF '2 file(s) go to the passwd home, not under $HOME'
  ! grep -q '^skip=' "$D/o/out" || false
}

@test "jvm home: root with a relocated HOME gets the init script in root's passwd home and a summary line naming both homes" {
  require_root "writes the init script into root's passwd home"
  [ -n "$ROOT_HOME" ] && [ -d "$ROOT_HOME" ] || skip "no passwd home for root here"
  [ -e "$ROOT_HOME/.gradle/init.d/supply-chain-security.gradle" ] || : > "$D/root-had-none"
  mkdir -p "$D/h"
  run env -i HOME="$D/h" PATH="$D/bin:/usr/local/bin:/usr/bin:/bin" LC_ALL=C.UTF-8 \
    ansible-playbook -i localhost, "$D/pb.yml" -e role_dir="$ROLE_DIR" -e summary_task="$D/summary.json" \
      -e out="$D/out" -e with_maven=false
  echo "$output" | grep -E 'fatal|FAILED|PLAY RECAP' -A2 | head -12
  [ "$status" -eq 0 ]
  grep -q 'Managed by ansible-supply-chain-security' "$ROOT_HOME/.gradle/init.d/supply-chain-security.gradle"
  [ ! -e "$D/h/.gradle" ]
  grep -qF "note=gradle: \$HOME is '$D/h' but the passwd home is '$ROOT_HOME'" "$D/out"
  echo "$output" | grep -qF '1 file(s) go to the passwd home, not under $HOME'
  echo "$output" | grep -qF "the init script goes to $ROOT_HOME/.gradle/init.d, where the JVM looks"
  # FIXTURE CONTROL: with HOME at the passwd home there is nothing to say.
  run env -i HOME="$ROOT_HOME" PATH="$D/bin:/usr/local/bin:/usr/bin:/bin" LC_ALL=C.UTF-8 \
    ansible-playbook -i localhost, "$D/pb.yml" -e role_dir="$ROLE_DIR" -e summary_task="$D/summary.json" \
      -e out="$D/out2" -e with_maven=false
  [ "$status" -eq 0 ]
  grep -qx "user_dir=$ROOT_HOME" "$D/out2"
  ! grep -q '^note=' "$D/out2" || false
  ! echo "$output" | grep -q 'go to the passwd home' || false
}

@test "jvm home: a uid with no passwd home it can write gets both files under HOME, listed as not applied" {
  require_root "creates the $NOHOME_ACCT account"
  local none=/nonexistent-sch-home-paths uid
  [ ! -e "$none" ] || skip "$none exists here"
  make_account "$NOHOME_ACCT" "$none"
  uid=$(id -u "$NOHOME_ACCT")
  mkdir -p "$D/fake"
  chown "$NOHOME_ACCT:" "$D/fake"
  jvm_play_as "$NOHOME_ACCT" "$D/fake"
  echo "$output" | grep -E 'fatal|FAILED|PLAY RECAP' -A2 | head -12
  [ "$status" -eq 0 ]
  grep -q 'Managed by ansible-supply-chain-security' "$D/fake/.gradle/init.d/supply-chain-security.gradle"
  grep -q 'Managed by ansible-supply-chain-security' "$D/fake/.m2/settings.xml"
  [ ! -e "$none" ]
  grep -qF "skip=gradle init script — uid $uid has no passwd home it can write (passwd says: $none), so the script was written to $D/fake/.gradle, under \$HOME." "$D/o/out"
  grep -qF "skip=maven settings.xml — uid $uid has no passwd home it can write (passwd says: $none), so settings.xml was written to $D/fake/.m2, under \$HOME." "$D/o/out"
  ! grep -q '^note=' "$D/o/out" || false
}

# The preflight judges maven's settings.xml where tasks/maven.yml writes it. The
# passwd home is stood in for with -e sch_passwd_home (tasks/passwd_home.yml), so
# that root's own home is not touched; the tests above use the real lookup.
preflight_maven() { # extra ansible args
  cd "$ROLE_DIR"
  env -u DOTNET_CLI_HOME -u GRADLE_USER_HOME HOME="$D/home" PATH="$D/bin:$PATH" \
    ansible-playbook site.yml --connection=local --limit localhost --tags maven \
      -e podman_enabled=false -e verify_protections=false -e sch_passwd_home="$D/pw" "$@" 2>&1
}

@test "jvm home: the preflight refuses a maven settings.xml it did not write in the passwd home, and leaves HOME's alone" {
  require_root "applies the role, which writes /etc"
  mkdir -p "$D/pw/.m2" "$D/home/.m2"
  printf '<settings><servers><server><id>corp</id><password>s3cr3t</password></server></servers></settings>\n' > "$D/pw/.m2/settings.xml"
  printf '<settings><mirrors><mirror><id>home</id><mirrorOf>*</mirrorOf><url>https://home.example/</url></mirror></mirrors></settings>\n' > "$D/home/.m2/settings.xml"
  cp "$D/pw/.m2/settings.xml" "$D/pw.orig"
  cp "$D/home/.m2/settings.xml" "$D/home.orig"
  run preflight_maven
  echo "$output" | grep -A6 'Refusing to overwrite existing per-user' | head -8
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[supply-chain-hardening\] Refusing to overwrite existing per-user config'
  echo "$output" | grep -qF "$D/pw/.m2/settings.xml"
  ! echo "$output" | grep -qF "$D/home/.m2/settings.xml" || false
  ! echo "$output" | grep -q s3cr3t || false
  cmp "$D/pw/.m2/settings.xml" "$D/pw.orig"
  cmp "$D/home/.m2/settings.xml" "$D/home.orig"
  # FIXTURE CONTROL: with no file of anyone's in the passwd home, the same run
  # applies, writes there, and still leaves HOME's file as it was.
  rm -f "$D/pw/.m2/settings.xml"
  run preflight_maven
  echo "$output" | grep -E 'Refusing|fatal|PLAY RECAP' -A1 | head -6
  [ "$status" -eq 0 ]
  grep -q 'Managed by ansible-supply-chain-security' "$D/pw/.m2/settings.xml"
  cmp "$D/home/.m2/settings.xml" "$D/home.orig"
  echo "$output" | grep -qF "maven: \$HOME is '$D/home' but the passwd home is '$D/pw'"
}
