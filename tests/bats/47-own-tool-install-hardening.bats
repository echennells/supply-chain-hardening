#!/usr/bin/env bats
# ECH-185 — the role must harden its OWN tool installs, not just the user's.
#
# The role installs its enforcement/audit tooling by calling the real package
# manager directly (stepping around its own /usr/local/bin wrappers, correctly —
# it can't route sfw/cargo-cooldown's install through the very gate they provide).
# But stepping around the wrapper must not mean stepping around the protection:
# the wrapper's job for npm is to block lifecycle scripts, so the role's own
# `npm install -g` calls must pass --ignore-scripts explicitly.
#
# --ignore-scripts is a universal npm CLI flag (all versions): load-bearing on
# npm <12, redundant-but-harmless on >=12 (native allowScripts). So the guard is
# unconditional — no version tiering needed.
#
# This is a STATIC guard over the role source (task files), not a runtime probe:
# "was --ignore-scripts used" is not observable on the applied host after the
# fact, so we assert it where it lives.

load setup

@test "own tools: every 'npm install -g' command in tasks/ passes --ignore-scripts" {
  local offenders
  offenders=$(grep -rnE 'command:.*npm install -g' "$ROLE_DIR"/tasks/*.yml 2>/dev/null \
                | grep -v -- '--ignore-scripts' || true)
  [ -z "$offenders" ] || {
    echo "npm install -g without --ignore-scripts (the role would run its own tool's" >&2
    echo "postinstall unblocked — the exact vector it blocks for users):" >&2
    echo "$offenders" >&2
    false
  }
}

# The installs run as root, whose PATH is sudo's secure_path. On a host whose only
# Node is per-user (fnm, nvm, volta, asdf) root cannot run the npm the role detected,
# so each install must wait on a become-time probe and the play records that reason,
# not a bare "install failed". Running the user's npm as root instead would let root
# execute files the user can edit. MEASURED on an fnm host before the gate: both
# installs "changed" and failed, and sfw's warm step blamed GitHub (exit 127).
@test "own tools: every 'npm install -g' task waits on a become-time check that root can run npm" {
  local f out offenders=""
  while IFS= read -r f; do
    out=$(awk '
      function check(  v, b) {
        if (blk !~ /command:[^\n]*npm install -g/) return
        if (match(blk, /npm_root_for_[a-z_]+\.rc \| default\(1\) == 0/) == 0) { print name " (no root check)"; return }
        v = substr(blk, RSTART, RLENGTH); sub(/\.rc.*/, "", v)
        b = probes[v]
        if (b == "" || b !~ /become: true/ || b !~ /command -v npm/) print name " (" v " is not a become-time command -v npm probe)"
      }
      /^- name:/ { if (reg != "") probes[reg] = blk; check(); blk = ""; reg = ""; name = $0 }
      { blk = blk $0 "\n" }
      /^  register: npm_root_for_/ { reg = $2 }
      END { if (reg != "") probes[reg] = blk; check() }
    ' "$f")
    [ -z "$out" ] || offenders="$offenders${f##*/}: $out"$'\n'
  done < <(grep -lE 'command:.*npm install -g' "$ROLE_DIR"/tasks/*.yml)
  [ -z "$offenders" ] || { echo "$offenders" >&2; false; }
}

# Ansible sets no umask, so a tool install inherits the caller's. MEASURED at
# 6c77f4e, the role applied as root under `umask 0000` (the default of GitLab's
# Docker executor): /usr/local/lib/node_modules and the lockfile-lint, npq and
# sfw trees in it were 0777, any account could replace code root runs, and the
# per-user uv tools, ~/.local/bin among them, were 0777 too. So each install
# runs under `sh -c 'umask ... && exec "$@"'`.
#
# This takes each install command as the command module does (the YAML value,
# shlex-split, $VARS expanded), runs its umask wrapper under umask 0000 with a
# stub in place of the tool, and reads the umask the stub was started with.
# A root install must be exactly 022, so every account can still read it; a
# per-user one must at least clear group and other write.
@test "own tools: every tool install runs under a umask that clears group and other write" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML not available"
  run python3 - "$BATS_TEST_TMPDIR" "$ROLE_DIR"/tasks/*.yml <<'PY'
import os, re, shlex, subprocess, sys, yaml
tmp, files = sys.argv[1], sys.argv[2:]
stub = os.path.join(tmp, "tool")
with open(stub, "w") as fh:
    fh.write('#!/bin/sh\nprintf "%s %s\\n" "$(umask)" "$#" > "$SCH_OUT"\n')
os.chmod(stub, 0o755)
install = re.compile(r"npm install -g |tool install |cargo install |\binstall (github\.com|golang\.org)/")
seen, bad = 0, []
def walk(tasks, f, become):
    global seen
    for t in tasks or []:
        if not isinstance(t, dict):
            continue
        b = t.get("become", become)
        for k in ("block", "rescue", "always"):
            walk(t.get(k), f, b)
        c = t.get("ansible.builtin.command")
        cmd = c if isinstance(c, str) else (c or {}).get("cmd") if isinstance(c, dict) else None
        if not cmd or not install.search(cmd):
            continue
        seen += 1
        name = "%s: %s" % (os.path.basename(f), t.get("name"))
        argv = [os.path.expanduser(os.path.expandvars(a)) for a in shlex.split(cmd)]
        if argv[:2] != ["sh", "-c"] or len(argv) < 5:
            bad.append("%s runs with the caller's umask: %s" % (name, cmd))
            continue
        out = os.path.join(tmp, "out")
        old = os.umask(0)
        try:
            subprocess.run(argv[:4] + [stub, "a", "b"], env={"PATH": os.environ["PATH"], "SCH_OUT": out}, check=True)
        finally:
            os.umask(old)
        mask, nargs = open(out).read().split()
        m = int(mask, 8)
        root = b is True or str(b).lower() == "true"
        if nargs != "2":
            bad.append("%s: the wrapper passed %s arguments on, not 2" % (name, nargs))
        elif root and m != 0o022:
            bad.append("%s (become): installed under umask %s, want 0022" % (name, mask))
        elif not root and m & 0o022 != 0o022:
            bad.append("%s: installed under umask %s, which lets group or others write" % (name, mask))
        else:
            print("ok  %s  umask %s" % (name, mask))
for f in files:
    walk(yaml.safe_load(open(f)), f, False)
for line in bad:
    print("BAD " + line)
print("checked %d install commands" % seen)
sys.exit(1 if bad or seen < 9 else 0)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "own tools: under umask 0000 the role's root npm install leaves nothing group- or world-writable" {
  # The same defect end to end, through the real play: remove lockfile-lint,
  # re-apply the npm tag under umask 0000, and look at what the install wrote.
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root: re-runs the role's root npm install"
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  local g
  g=$(npm root -g 2>/dev/null) && [ -d "$g" ] || skip "no npm global root"
  rm -rf "$g/lockfile-lint"
  cd "$ROLE_DIR"
  run bash -c 'umask 0000; exec ansible-playbook site.yml --connection=local --limit localhost \
    --tags npm -e podman_enabled=false -e verify_protections=false'
  printf '%s\n' "$output" | grep -A1 'TASK \[.*Install lockfile-lint globally' || true
  [ "$status" -eq 0 ]
  [ -f "$g/lockfile-lint/package.json" ] || skip "lockfile-lint did not install (offline?): nothing to inspect"
  local bad
  bad=$(find "$g/lockfile-lint" \( -perm -0002 -o -perm -0020 \) ! -type l)
  [ -z "$bad" ] || { echo "writable by group or others:"; echo "$bad" | head -20 | while read -r p; do ls -ld "$p"; done; false; }
  # Still readable by every account, which a caller's 077 would have broken.
  [ "$(ls -ld "$g/lockfile-lint" | cut -c1-10)" = drwxr-xr-x ]
}
