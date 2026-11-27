#!/usr/bin/env bash
# tests/ci/agent-shell/run.sh <cell> [setup|contents|checks|cleanup|all]
#
# The shells two agent runners started, imitated for real in containers, with
# action/harden.sh and action/verify.sh run inside them (ci-script.yml, job
# agent-shells). MEASURED on two agent VMs on 2026-11-26
# (docs/design-principles.md, "Agent runners"):
#
#   VM A  every command as `/bin/bash --norc --noprofile -c "umask 0007; ..."`,
#         as root with HOME=/home/hatch (root's passwd home is /root), PATH
#         /opt/hatch/bin:/opt/hatch-image/bin:/usr/local/sbin:..., no home
#         directory on it, npm 10.9.4 and bun in a read-only /opt/hatch-image/bin,
#         pip 24.0 in /usr/bin.
#   VM B  a shell state saved once per session from `bash -ilc` with no
#         terminal, replayed into `bash -O extglob -c` commands under
#         `shopt -s expand_aliases`.
#
# Cells: vm-a, uid-without-passwd, replayed-state, image-recipe.
# Phases: setup (pull, build, start), contents (what the cell really holds),
# checks (the assertions), cleanup; `all`, the default, runs them in order. The
# workflow runs them as separate steps; the container and the work directory
# carry over between them by name.
#
# Environment:
#   DOCKER              docker (default) or podman
#   AGENT_SHELL_PREFIX  names images (localhost/<prefix>-<cell>) and containers
#                       (<prefix>-<cell>); default sch-agent-shell
#   AGENT_SHELL_TMP     where the work directories go; default $RUNNER_TEMP, else
#                       ~/.cache/sch-agent-shell
#   AGENT_SHELL_KEEP    set: `all` leaves the container and the work directory
#
# Every check prints PASS or FAIL with what it looked at. A phase exits 1 when a
# check failed, and also when fewer or more checks ran than it declares: a check
# that silently did not run is a failure too.

set -euo pipefail

DOCKER=${DOCKER:-docker}
PREFIX=${AGENT_SHELL_PREFIX:-sch-agent-shell}
CELL=${1:?usage: run.sh <vm-a|uid-without-passwd|replayed-state|image-recipe> [setup|contents|checks|cleanup|all]}
PHASE=${2:-all}
REPO=$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
BASE=${AGENT_SHELL_TMP:-${RUNNER_TEMP:-${XDG_CACHE_HOME:-$HOME/.cache}/sch-agent-shell}}
W="$BASE/$CELL"
CTR="$PREFIX-$CELL"
IMG="localhost/$PREFIX-$CELL"

# Tags, as the repo's other workflows use them (verify-matrix.yml: ubuntu:24.04).
# node:22-bookworm is what action/examples/Dockerfile builds FROM.
UBUNTU_IMAGE=docker.io/library/ubuntu:24.04
NODE_IMAGE=docker.io/library/node:22-bookworm
# uv in VM A's ~/.local/bin, off PATH. 0.13.8 (released 2026-11-12), checked
# against the digest its release publishes.
UV_VERSION=0.13.8
UV_SHA256=5acfd9177cfecf0bf87578f059728215ccc884388988f55f7a65041b57387d91
NPM_VERSION=10.9.4
BUN_VERSION=1.4.4

case "$CELL" in vm-a|uid-without-passwd|replayed-state|image-recipe) ;; *) echo "unknown cell: $CELL" >&2; exit 2 ;; esac
case "$PHASE" in setup|contents|checks|cleanup|all) ;; *) echo "unknown phase: $PHASE" >&2; exit 2 ;; esac

PODMAN=false
if "$DOCKER" --version 2>/dev/null | grep -qi podman; then PODMAN=true; fi

CHECKS=0
FAILS=0
pass() { CHECKS=$((CHECKS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$*"; [ -z "${GITHUB_ACTIONS:-}" ] || printf '::error::%s: %s\n' "$CELL" "$*"; }
# check <what was checked> <command...>: PASS or FAIL by the command's status.
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
# done_phase <expected number of checks>
done_phase() {
  if [ "$CHECKS" -ne "$1" ]; then
    fail "$CELL $CUR ran $CHECKS checks, not the $1 it declares"
  fi
  echo "== $CELL $CUR: $CHECKS checks, $FAILS failed"
  [ "$FAILS" -eq 0 ]
}
say() { printf '\n== %s\n' "$*"; }
# show <label> <text>: the text, indented, so a log reader sees what a check saw.
show() { printf -- '-- %s:\n' "$1"; printf '%s\n' "$2" | sed 's/^/   | /'; }

# capture <command...>: OUT (stdout and stderr) and RC, whatever the status.
capture() { set +e; OUT=$("$@" 2>&1); RC=$?; set -e; }

# in_ctr <command...>: a plain exec in the cell's container, for setup and for
# reading state. Not how the agent runs commands; see agent().
in_ctr() { "$DOCKER" exec -i "$CTR" "$@"; }

# json_get <file> <expression over d>: one value from the verifier's --json output.
json_get() {
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2], {"d": d})
print(",".join(v) if isinstance(v, list) else v)' "$1" "$2"
}
# json_row <file> <protection>: "STATUS|EVIDENCE|DETAIL" of the row with that name, or nothing.
json_row() {
  python3 -I -c 'import json, sys
for r in json.load(open(sys.argv[1]))["rows"]:
    if r["protection"] == sys.argv[2]:
        print("%s|%s|%s" % (r["status"], r["evidence"], r["detail"]))
        break' "$1" "$2"
}
# json_flagged <file>: every GAP and WEAK row, one per line, for the log.
json_flagged() {
  python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
print("result: %s" % json.dumps(d["result"]))
for r in d["rows"]:
    if r["status"] in ("GAP", "WEAK"):
        print("%-4s %-10s %s: %s" % (r["status"], r["evidence"], r["protection"], r["detail"]))' "$1"
}
# exit_agrees <file> <rc>: the exit status is what --json says it must be (1 on any GAP).
exit_agrees() {
  local gaps n
  gaps=$(json_get "$1" 'd["result"]["gaps"]')
  n=$(json_get "$1" 'len([r for r in d["rows"] if r["status"] == "GAP"])')
  [ "$gaps" = "$n" ] || { echo "   result.gaps=$gaps but $n GAP rows"; return 1; }
  if [ "$gaps" -gt 0 ]; then [ "$2" -eq 1 ]; else [ "$2" -eq 0 ]; fi
}
has() { case "$1" in *"$2"*) return 0 ;; esac; echo "   expected to find: $2"; return 1; }
lacks() { case "$1" in *"$2"*) echo "   expected NOT to find: $2"; return 1 ;; esac; return 0; }

rm_work() {
  [ -e "$W" ] || return 0
  # A container's root (docker's, not rootless podman's) owns what it wrote in a
  # bind mount; it removes that itself.
  rm -rf -- "$W" 2>/dev/null || {
    "$DOCKER" run --rm -v "$W:/w" "$UBUNTU_IMAGE" sh -c 'rm -rf /w/* /w/.[!.]* 2>/dev/null; true'
    rm -rf -- "$W"
  }
}
cleanup() {
  local t
  "$DOCKER" rm -f "$CTR" >/dev/null 2>&1 || true
  if [ "$CELL" = image-recipe ]; then
    for t in latest $IR_TAGS; do "$DOCKER" image rm -f "$IMG:$t" >/dev/null 2>&1 || true; done
  fi
  rm_work
}

# The tree an agent would have checked out: harden.sh, verify.sh and the probes,
# in their action/ and files/ layout (verify.sh reads ../files/verify-probes.sh).
copy_tree() { # <dir in the container>
  in_ctr mkdir -p "$1"
  tar -C "$REPO" -cf - action files | in_ctr tar -C "$1" --no-same-owner -xf -
}

# The contents of /etc/profile.d/npq-aliases.sh, as the role deploys it: the
# `content: |` block of the task whose dest is that file, in tasks/npq.yml. Read
# from the role, so this cell follows any change to it.
npq_aliases_from_role() {
  awk '
    /dest: \/etc\/profile\.d\/npq-aliases\.sh/ { want = 1; next }
    want && /^    content: \|$/ { body = 1; next }
    body && /^      / { sub(/^      /, ""); print; next }
    body && /^$/ { print; next }
    body { exit }
  ' "$REPO/tasks/npq.yml"
}

# ============================================================== vm-a ======

VM_A_HOME=/home/hatch
VM_A_PATH=/opt/hatch/bin:/opt/hatch-image/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# agent <command>: as VM A's runner starts it. Nothing else in the environment:
# env -i drops what the container's own config would add.
agent() {
  "$DOCKER" exec -i "$CTR" env -i HOME="$VM_A_HOME" PATH="$VM_A_PATH" \
    /bin/bash --norc --noprofile -c "umask 0007; $1"
}

# outside_home <marker name> <home> <prune...>: what changed (mtime or ctime) after the
# marker, outside HOME, on the container's root filesystem. /tmp and /run are
# searched like every other directory: both are on the root overlay (MEASURED,
# podman 5.7.0: the same device as /; vm-a's contents check it on any engine), so
# a write there counts. -xdev keeps out /proc, /sys and /dev, which are
# other filesystems; they are pruned by name as well, with the markers' directory
# and the cell's own bind mounts (the <prune...> arguments).
outside_home() {
  local m=$1 h=$2 p prune=""
  shift 2
  for p in /proc /sys /dev "$MARKS" "$h" "$@"; do prune="$prune -path $p -o"; done
  in_ctr sh -c "find / /tmp -xdev \\( ${prune% -o} \\) -prune -o \\( -newer $MARKS/$m -o -cnewer $MARKS/$m \\) -print 2>/dev/null | sort -u"
}
# mark <name>: a marker strictly newer than whatever made it. The markers live in
# a directory of their own, made at setup and pruned from every search, so making
# one changes no directory the searches look at.
MARKS=/var/tmp/sch-marks
mark() { in_ctr sh -c "touch '$MARKS/$1' && sleep 1 && touch '$MARKS/$1'"; }

# home_state <home> <record dir>: every entry under HOME but the run record's
# directory, with inode, mode and size, and the checksum of each file.
home_state() {
  in_ctr sh -c "cd '$1' && find . -path './${2#"$1"/}' -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
      printf '%s ' \"\$p\"; ls -ldin \"\$p\" | awk '{print \$1, \$2, \$6}'
      if [ -f \"\$p\" ] && [ ! -L \"\$p\" ]; then cksum < \"\$p\"; fi
    done"
}
ro_manifest() {
  in_ctr sh -c 'cd /opt/hatch-image && find . | LC_ALL=C sort | while IFS= read -r p; do
      printf "%s " "$p"; ls -ldin "$p" | awk "{print \$1, \$2, \$6}"
      if [ -f "$p" ] && [ ! -L "$p" ]; then cksum < "$p"; fi
    done'
}

NPM_FIX=$VM_A_HOME/fixture
npm_fixture() { # (re)write a local dependency whose postinstall leaves a marker
  in_ctr sh -c "rm -rf '$NPM_FIX' && mkdir -p '$NPM_FIX/evil' '$NPM_FIX/proj' &&
    printf '{ \"name\": \"evil-dep\", \"version\": \"1.0.0\", \"scripts\": { \"postinstall\": \"touch $NPM_FIX/postinstall-ran\" } }\n' > '$NPM_FIX/evil/package.json' &&
    printf '{ \"name\": \"victim\", \"version\": \"1.0.0\", \"private\": true }\n' > '$NPM_FIX/proj/package.json'"
}
npm_install_fixture() { agent "cd '$NPM_FIX' && npm install --prefix ./proj --no-audit --no-fund ./evil"; }

vm_a_setup() {
  say "vm-a setup: Node $NPM_VERSION npm and bun $BUN_VERSION in a directory for /opt/hatch-image"
  mkdir -p "$W/hatch-image" "$W/uv"
  # Node's binary from the node image and npm and bun installed beside it, so the
  # directory holds what VM A's image directory held. Install scripts run here
  # (bun's puts its binary in place): this is the image being made, not the agent.
  "$DOCKER" run --rm -v "$W/hatch-image:/out" "$NODE_IMAGE" sh -c "set -e
    mkdir -p /out/bin && cp /usr/local/bin/node /out/bin/node
    npm install -g --prefix /out --no-audit --no-fund --loglevel=error npm@$NPM_VERSION bun@$BUN_VERSION"
  say "vm-a setup: uv $UV_VERSION"
  curl -fsSL -o "$W/uv.tgz" "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz"
  echo "$UV_SHA256  $W/uv.tgz" | sha256sum -c -
  tar -C "$W/uv" --strip-components=1 -xzf "$W/uv.tgz"
  say "vm-a setup: the container (ubuntu:24.04, /opt/hatch-image mounted read-only)"
  "$DOCKER" rm -f "$CTR" >/dev/null 2>&1 || true
  "$DOCKER" run -d --name "$CTR" -v "$W/hatch-image:/opt/hatch-image:ro" "$UBUNTU_IMAGE" sleep infinity >/dev/null
  in_ctr sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends python3-pip >/dev/null'
  in_ctr mkdir -p "$VM_A_HOME/.local/bin" "$MARKS"
  "$DOCKER" cp "$W/uv/uv" "$CTR:$VM_A_HOME/.local/bin/uv"
  copy_tree "$VM_A_HOME/sch"
}

vm_a_contents() {
  say "vm-a: what the cell contains, as the agent's shell sees it"
  capture agent 'echo "uid=$(id -u) HOME=$HOME umask=$(umask) bash=$BASH_VERSION"; echo "PATH=$PATH"
    for t in node npm bun pip pip3 python3 uv; do printf "%-8s %s\n" "$t" "$(command -v $t || echo "(not on PATH)")"; done
    echo "npm $(npm --version)"; echo "bun $(bun --version)"; python3 -m pip --version; ~/.local/bin/uv --version
    getent passwd 0'
  show "agent shell" "$OUT"
  check "the agent shell ran (rc $RC)" [ "$RC" -eq 0 ]
  check "root, with HOME=$VM_A_HOME and umask 0007" has "$OUT" "uid=0 HOME=$VM_A_HOME umask=0007"
  check "root's passwd home is /root, not HOME" has "$OUT" "root:x:0:0:root:/root:"
  check "npm $NPM_VERSION from /opt/hatch-image/bin" \
    eval 'has "$OUT" "npm      /opt/hatch-image/bin/npm" && has "$OUT" "npm $NPM_VERSION"'
  check "bun $BUN_VERSION from /opt/hatch-image/bin" \
    eval 'has "$OUT" "bun      /opt/hatch-image/bin/bun" && has "$OUT" "bun $BUN_VERSION"'
  check "pip 24.0 (apt python3-pip) in /usr/bin" \
    eval 'has "$OUT" "pip      /usr/bin/pip" && has "$OUT" "pip 24.0 from /usr/lib/python3/dist-packages/pip"'
  check "uv $UV_VERSION in ~/.local/bin, off PATH" \
    eval 'has "$OUT" "uv       (not on PATH)" && has "$OUT" "uv $UV_VERSION"'
  # A real read-only mount: root cannot write it (EROFS), whatever the modes say.
  capture in_ctr sh -c 'grep " /opt/hatch-image " /proc/mounts; touch /opt/hatch-image/bin/.probe'
  show "mount, and root writing into it" "$OUT"
  check "/opt/hatch-image is mounted ro and root's write fails with EROFS" \
    eval '[ "$RC" -ne 0 ] && has "$OUT" " ro," && has "$OUT" "Read-only file system"'
  capture in_ctr sh -c 'stat -c "%d %m %n" / /tmp /run /home/hatch'
  show "devices of /, /tmp, /run and HOME" "$OUT"
  check "/tmp, /run and HOME are on the root filesystem, so the find below covers them" \
    eval '[ "$(printf "%s\n" "$OUT" | awk "{print \$1}" | sort -u | wc -l)" -eq 1 ]'
  done_phase 9
}

vm_a_checks() {
  local rec_dir="$VM_A_HOME/.cache/supply-chain-hardening" out1 out2 before after found day1 day2
  say "vm-a: fixture control, before any hardening"
  npm_fixture
  capture npm_install_fixture
  show "npm install of a local dependency with a postinstall, unhardened" "$OUT"
  check "FIXTURE CONTROL: unhardened, the postinstall DOES run from the agent's shell" in_ctr test -f "$NPM_FIX/postinstall-ran"
  npm_fixture

  say "vm-a: the outside-HOME search sees a write to the passwd home (control)"
  mark mark0
  in_ctr touch /root/sch-probe
  found=$(outside_home mark0 "$VM_A_HOME" /opt/hatch-image)
  check "CONTROL: a file written to /root after the marker is found" has "$found" /root/sch-probe
  in_ctr rm -f /root/sch-probe

  say "vm-a: harden.sh --home-only, twice, from the agent's shell"
  before=$(ro_manifest)
  mark mark1
  capture agent "cd $VM_A_HOME/sch && ./action/harden.sh --home-only"
  out1=$OUT
  show "first run (rc $RC)" "$out1"
  check "first run exits 0" [ "$RC" -eq 0 ]
  check "bun in the read-only image directory gets no wrapper, and the run says so" \
    has "$out1" "bun: no wrapper, because /opt/hatch-image/bin/bun is outside HOME"
  day1=$(date -u +%F)
  home_state "$VM_A_HOME" "$rec_dir" > "$W/home-1"
  mark mark2
  capture agent "cd $VM_A_HOME/sch && ./action/harden.sh --home-only"
  out2=$OUT
  show "second run (rc $RC)" "$out2"
  check "second run exits 0" [ "$RC" -eq 0 ]
  home_state "$VM_A_HOME" "$rec_dir" > "$W/home-2"
  day2=$(date -u +%F)
  if [ "$day1" != "$day2" ]; then
    echo "-- the UTC day changed between the runs, and with it the cutoffs; once more"
    home_state "$VM_A_HOME" "$rec_dir" > "$W/home-1"
    mark mark2
    capture agent "cd $VM_A_HOME/sch && ./action/harden.sh --home-only"
    home_state "$VM_A_HOME" "$rec_dir" > "$W/home-2"
  fi
  found=$(outside_home mark1 "$VM_A_HOME" /opt/hatch-image)
  show "changed outside $VM_A_HOME during both runs (/tmp and /root included)" "${found:-(nothing)}"
  check "find / -xdev -newer: nothing outside $VM_A_HOME changed, /tmp and /root included" [ -z "$found" ]
  after=$(ro_manifest)
  check "nothing in /opt/hatch-image changed (inode, mode, size, checksum of $(printf '%s\n' "$before" | wc -l) entries)" \
    [ "$before" = "$after" ]
  check "the second run changed no entry under HOME but its run record" diff "$W/home-1" "$W/home-2"
  found=$(in_ctr find "$VM_A_HOME" \( -newer "$MARKS/mark2" -o -cnewer "$MARKS/mark2" \) ! -path "$rec_dir" ! -path "$rec_dir/*")
  show "newer than the second run's marker under HOME, the record's directory left out" "${found:-(nothing)}"
  check "and touched nothing there either (mtime and ctime)" [ -z "$found" ]

  say "vm-a: npm from the agent's shell, hardened"
  capture agent 'cd "$(mktemp -d)" && npm config get ignore-scripts 2>/dev/null'
  check "npm $NPM_VERSION reads ignore-scripts=true from HOME's config (got: $OUT)" [ "$OUT" = true ]
  capture npm_install_fixture
  show "npm install of the same dependency, hardened" "$OUT"
  check "the dependency's postinstall does NOT run" eval '[ "$RC" -eq 0 ] && ! in_ctr test -e "$NPM_FIX/postinstall-ran"'

  say "vm-a: the verifier, from the agent's shell"
  set +e
  agent "cd $VM_A_HOME/sch && ./action/verify.sh --emit=plain --json" > "$W/verify.json" 2> "$W/verify.err"
  RC=$?
  set -e
  show "verifier stderr (rc $RC)" "$(cat "$W/verify.err")"
  show "GAP and WEAK rows" "$(json_flagged "$W/verify.json" 2>&1)"
  local row
  row=$(json_row "$W/verify.json" "npm age gate")
  check "npm age gate: GAP naming the read-only location ($row)" \
    eval 'has "$row" "GAP|" && has "$row" ". npm is at /opt/hatch-image/bin/npm: read-only (image-owned?)"'
  row=$(json_row "$W/verify.json" "pip native age gate")
  check "pip native age gate: GAP, pip 24.0 ($row)" eval 'has "$row" "GAP|" && has "$row" "pip 24.0 does NOT implement"'
  row=$(json_row "$W/verify.json" "env layer propagation")
  check "env layer propagation: N/A BYDESIGN ($row)" has "$row" "N/A|BYDESIGN|"
  row=$(json_row "$W/verify.json" "uv on this shell's PATH")
  check "uv in ~/.local/bin is graded but off this shell's PATH: WEAK ($row)" has "$row" "WEAK|"
  check "the exit status ($RC) agrees with --json's result" exit_agrees "$W/verify.json" "$RC"
  # What --home-only cannot write: /etc, and a wrapper outside HOME. Neither is a
  # gap a re-run closes, so neither fails --fail-on=config. Before they were
  # classed so, this run exited 1 with "3 fixable by re-running the hardening".
  row=$(json_row "$W/verify.json" "uv system config (sudo/other users)")
  check "uv system config: N/A BYDESIGN, --home-only writes no /etc file ($row)" \
    eval 'has "$row" "N/A|BYDESIGN|" && has "$row" "which by design writes no /etc file"'
  local brow bxrow
  brow=$(json_row "$W/verify.json" "bun runtime auto-install blocked")
  bxrow=$(json_row "$W/verify.json" "bunx fetch-and-execute blocked")
  check "bun runtime auto-install and bunx: still GAPs at /opt/hatch-image/bin, which a re-run does not close ($brow / $bxrow)" \
    eval 'has "$brow" "GAP|PRESENT|bun resolves to an unwrapped binary at /opt/hatch-image/bin/bun;" && has "$brow" "re-running it does not close this" &&
          has "$bxrow" "GAP|PRESENT|bunx resolves to an unwrapped binary at /opt/hatch-image/bin/bunx;" && has "$bxrow" "re-running it does not close this"'
  set +e
  agent "cd $VM_A_HOME/sch && ./action/verify.sh --emit=plain --fail-on=config" > "$W/verify-config.out" 2>&1
  RC=$?
  set -e
  show "--fail-on=config: the summary (rc $RC)" "$(grep -A1 '^RESULT' "$W/verify-config.out")"
  check "--fail-on=config exits 0: no GAP left that a re-run of --home-only closes (rc $RC)" \
    eval '[ "$RC" -eq 0 ] && grep -q "^        0 fixable by re-running the hardening" "$W/verify-config.out"'
  done_phase 19
}

# ================================================= uid-without-passwd ======

UID_HOME=/tmp/h
uid_setup() {
  say "uid-without-passwd setup: node:22-bookworm as uid 4242, HOME=$UID_HOME"
  local -a nopw=()
  # podman adds a passwd entry for --user by default (its home is /); --passwd=false
  # leaves /etc/passwd as the image has it, as docker does.
  [ "$PODMAN" = false ] || nopw=(--passwd=false)
  "$DOCKER" rm -f "$CTR" >/dev/null 2>&1 || true
  "$DOCKER" run -d --name "$CTR" ${nopw[@]+"${nopw[@]}"} -u 4242 -e HOME="$UID_HOME" \
    -v "$REPO:/src:ro" "$NODE_IMAGE" sleep infinity >/dev/null
  in_ctr mkdir -p "$UID_HOME" "$MARKS"
}
uid_contents() {
  say "uid-without-passwd: what the cell contains"
  capture in_ctr bash -c 'echo "uid=$(id -u) HOME=$HOME"; id -un 2>&1 || echo "id -un: no name"
    echo "getent=[$(getent passwd 4242)] passwd=[$(grep -c ":4242:" /etc/passwd)]"
    echo "node $(node --version) npm $(npm --version) yarn $(yarn --version)"; [ -w "$HOME" ] && echo "HOME writable"'
  show "container" "$OUT"
  check "uid 4242 with HOME=$UID_HOME" has "$OUT" "uid=4242 HOME=$UID_HOME"
  check "no passwd entry for it (getent and /etc/passwd)" has "$OUT" "getent=[] passwd=[0]"
  check "HOME exists and is writable" has "$OUT" "HOME writable"
  done_phase 3
}
uid_checks() {
  local found
  say "uid-without-passwd: the outside-HOME search sees a write to /var/tmp (control)"
  mark mark0
  in_ctr touch /var/tmp/sch-probe
  found=$(outside_home mark0 "$UID_HOME" /src)
  check "CONTROL: a file written to /var/tmp after the marker is found" has "$found" /var/tmp/sch-probe
  in_ctr rm -f /var/tmp/sch-probe
  say "uid-without-passwd: harden.sh --home-only"
  mark mark1
  capture in_ctr bash -c 'cd /src && ./action/harden.sh --home-only'
  show "run (rc $RC)" "$OUT"
  check "exits 0" [ "$RC" -eq 0 ]
  check "maven: nothing written, no passwd entry to say where the JVM looks" \
    has "$OUT" "maven: uid 4242 has no passwd entry, so it is not known where the JVM looks"
  check "gradle: the same" has "$OUT" "gradle: uid 4242 has no passwd entry, so it is not known where the JVM looks"
  found=$(outside_home mark1 "$UID_HOME" /src)
  show "changed outside $UID_HOME" "${found:-(nothing)}"
  check "find / -xdev -newer: nothing outside $UID_HOME changed, the rest of /tmp included" [ -z "$found" ]
  # find exits 1 on the directories uid 4242 cannot read; the control above shows
  # the search itself works here.
  found=$(in_ctr sh -c "find / -xdev \\( -name .m2 -o -name .gradle -o -name settings.xml -o -name '*.gradle' \\) -newer $MARKS/mark1 -print 2>/dev/null; true")
  check "no .m2, .gradle, settings.xml or gradle script was written anywhere, HOME included" [ -z "$found" ]
  show "what it wrote under $UID_HOME" "$(in_ctr find "$UID_HOME" -maxdepth 3 | sort)"
  done_phase 6
}

# ===================================================== replayed-state ======

RS_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RS_ENV=/etc/supply-chain-hardening.env
RS_DUMP='declare -px; alias -p; shopt -p; declare -f'
rs_setup() {
  say "replayed-state setup: node:22-bookworm hardened as action/examples/Dockerfile does it"
  "$DOCKER" rm -f "$CTR" >/dev/null 2>&1 || true
  "$DOCKER" run -d --name "$CTR" "$NODE_IMAGE" sleep infinity >/dev/null
  copy_tree /opt/sch
  # The same variables and lines as the example's RUN and its option A.
  capture in_ctr env -i HOME=/root PATH="$RS_PATH" ECOSYSTEMS=npm,pnpm,yarn,pip,uv,bun RELEASE_AGE_HOURS=48 \
    WRITE_ETC=true HARDENING_ENV_FILE="$RS_ENV" /opt/sch/action/harden.sh --emit=plain
  printf '%s\n' "$OUT" | tail -25
  [ "$RC" -eq 0 ] || { echo "harden.sh failed (rc $RC)"; exit 1; }
  in_ctr sh -c "echo '. $RS_ENV' >> /etc/profile.d/00-hardening.sh"
  # And the role's npq aliases file, which a role-hardened host like VM B has.
  npq_aliases_from_role | in_ctr sh -c 'cat > /etc/profile.d/npq-aliases.sh'
}
rs_contents() {
  say "replayed-state: what the cell contains"
  capture in_ctr sh -c "ls /etc/profile.d; echo; cat /etc/profile.d/00-hardening.sh; echo; grep -c '^export ' $RS_ENV
    command -v script; command -v npq-hero || echo 'no npq-hero'; command -v yarn; yarn --version; bash --version | head -1"
  show "container" "$OUT"
  check "the env layer is sourced from /etc/profile.d, as the example's option A does it" has "$OUT" ". $RS_ENV"
  check "the role's npq-aliases.sh is in /etc/profile.d" \
    eval 'has "$OUT" "npq-aliases.sh" && in_ctr grep -q "alias yarn=" /etc/profile.d/npq-aliases.sh'
  check "yarn is on PATH and npq-hero is not, so an applied alias fails visibly" \
    eval 'has "$OUT" "/usr/local/bin/yarn" && has "$OUT" "no npq-hero"'
  check "script(1) is there to give the control capture a terminal" has "$OUT" "/usr/bin/script"
  done_phase 4
}
# capture_state <file> <how>: the state VM B's runner saves, from a login shell.
#   notty  `bash -ilc` with stdin from /dev/null and no terminal, as the runner does
#   tty    the same in a terminal (script(1)): the control, a shell that set the aliases
#   plain  `bash -c`, no startup file: the control for the env layer
capture_state() {
  case "$2" in
    notty) in_ctr sh -c "env -i HOME=/root PATH=$RS_PATH bash -ilc '$RS_DUMP' </dev/null >$1 2>$1.err" ;;
    tty)   in_ctr sh -c "script -qec \"env -i HOME=/root PATH=$RS_PATH TERM=dumb bash -ilc '{ $RS_DUMP; } >$1'\" /dev/null </dev/null >$1.err 2>&1" ;;
    plain) in_ctr sh -c "env -i HOME=/root PATH=$RS_PATH bash -c '$RS_DUMP' </dev/null >$1 2>$1.err" ;;
  esac
}
# replay <state> <command>: the command on a LATER line than the state, as the
# runner replays it. replay_same_line puts both on one line, to measure the difference.
replay() {
  in_ctr env -i HOME=/root PATH=/usr/bin:/bin bash -O extglob -c "shopt -s expand_aliases
. $1 2>/dev/null
$2"
}
replay_same_line() {
  in_ctr env -i HOME=/root PATH=/usr/bin:/bin bash -O extglob -c "shopt -s expand_aliases
. $1 2>/dev/null; $2"
}
RS_PRESENT='n=0; have=0; miss=""
for v in $(sed -n "s/^export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p" '"$RS_ENV"'); do
  n=$((n + 1)); if [ -n "${!v+set}" ]; then have=$((have + 1)); else miss="$miss $v"; fi
done
echo "present=$have/$n missing:${miss:- none}"'
rs_checks() {
  local n
  n=$(in_ctr grep -c '^export ' "$RS_ENV")
  say "replayed-state: capture the states"
  capture_state /var/tmp/state-notty notty
  capture_state /var/tmp/state-tty tty
  capture_state /var/tmp/state-plain plain
  show "lines in each state (notty, tty, plain)" "$(in_ctr wc -l /var/tmp/state-notty /var/tmp/state-tty /var/tmp/state-plain)"

  say "replayed-state: the control state, from a shell that had a terminal"
  capture replay /var/tmp/state-tty 'alias -p'
  show "aliases in a command replaying the tty state" "$OUT"
  check "CONTROL: replayed from a terminal's state, the npq aliases are defined" \
    eval 'has "$OUT" "alias yarn='"'"'NPQ_PKG_MGR=yarn npq-hero'"'"'" && has "$OUT" "alias pnpm="'
  # MEASURED (bash 5.2.15, node:22-bookworm, 2026-11-27): an alias the state
  # defines applies to a command on a later line of the same `bash -c` string, and
  # not to one on the line that sources the state (bash reads a whole line before
  # it runs any of it): yarn ran as npq-hero, which is not there, on the later
  # line, and as yarn 1.22.22 on the same line.
  capture replay /var/tmp/state-tty 'yarn --version'
  show "yarn on a later line than the state" "$OUT (rc $RC)"
  check "MEASURED: on a later line the alias applies (yarn ran as npq-hero)" \
    eval '[ "$RC" -eq 127 ] && has "$OUT" "npq-hero: command not found"'
  capture replay_same_line /var/tmp/state-tty 'yarn --version'
  show "yarn on the line that sources the state" "$OUT (rc $RC)"
  check "MEASURED: on the same line it does not (yarn ran as itself)" \
    eval '[ "$RC" -eq 0 ] && lacks "$OUT" npq-hero'

  say "replayed-state: the state VM B's runner saves (bash -ilc, stdin /dev/null, no terminal)"
  capture replay /var/tmp/state-notty 'alias -p; echo "--"; yarn --version'
  show "aliases, then yarn on a later line" "$OUT (rc $RC)"
  check "no npq alias is defined, and yarn on a later line runs yarn" \
    eval '[ "$RC" -eq 0 ] && lacks "$OUT" npq-hero'
  capture replay /var/tmp/state-notty "$RS_PRESENT"
  check "all $n variables of the env layer are in the replayed command ($OUT)" has "$OUT" "present=$n/$n missing: none"
  capture replay /var/tmp/state-plain "$RS_PRESENT"
  check "CONTROL: a state saved from bash -c, which reads no startup file, has none of them ($OUT)" \
    has "$OUT" "present=0/$n"
  set +e
  # The env file is not where verify.sh looks by default, so it is named, as
  # action/README.md says to ("set the matching input on the verify step too").
  replay /var/tmp/state-notty "HARDENING_ENV_FILE=$RS_ENV /opt/sch/action/verify.sh --emit=plain --json" > "$W/verify.json" 2> "$W/verify.err"
  RC=$?
  set -e
  local row
  row=$(json_row "$W/verify.json" "env layer propagation")
  check "the verifier in the replayed command: env layer propagation OK ($row)" has "$row" "OK|FUNCTIONAL|all $n variables present"
  done_phase 7
}

# ======================================================= image-recipe ======

IR_LIB=/usr/local/lib/supply-chain-hardening
# The rebuilds the checks make, as tags of $IMG; cleanup removes them.
IR_TAGS="nostamp stamp1 stamp1-again"
# ir_build <tag> [build args...]: the example built again, as setup builds it.
ir_build() {
  local tag=$1; shift
  local -a prog=()
  [ "$PODMAN" = true ] || prog=(--progress=plain)
  "$DOCKER" build ${prog[@]+"${prog[@]}"} "$@" -t "$IMG:$tag" -f "$REPO/action/examples/Dockerfile" "$REPO" > "$W/build-$tag.log" 2>&1
}
# ir_cutoffs <image>: the pip and uv cutoffs harden.sh wrote, instants taken when it ran.
ir_cutoffs() { "$DOCKER" run --rm --entrypoint "" "$1" grep -h -e '^uploaded-prior-to' -e '^exclude-newer' /etc/pip.conf /etc/uv/uv.toml; }
ir_setup() {
  say "image-recipe setup: docker build action/examples/Dockerfile, as shipped"
  local -a prog=()
  [ "$PODMAN" = true ] || prog=(--progress=plain)
  local rc
  set +e
  "$DOCKER" build ${prog[@]+"${prog[@]}"} -t "$IMG" -f "$REPO/action/examples/Dockerfile" "$REPO" 2>&1 | tee "$W/build.log"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || { echo "the build failed (rc $rc); its verify step fails it on a GAP the image could have closed"; exit 1; }
}
ir_contents() {
  say "image-recipe: what the image contains"
  local user
  user=$("$DOCKER" image inspect --format '{{.Config.User}}' "$IMG")
  capture "$DOCKER" run --rm --entrypoint "" "$IMG" sh -c "id; node --version; npm --version; yarn --version
    ls -l $IR_LIB/action/harden.sh $IR_LIB/action/verify.sh $IR_LIB/files/verify-probes.sh /etc/supply-chain-hardening.env
    stat -c '%A %U %n' /etc/supply-chain-hardening.outputs"
  show "image (runtime user '${user:-root}')" "$OUT"
  check "it runs as root (no USER), as it was built" eval '[ -z "$user" ] && has "$OUT" "uid=0(root)"'
  check "verify.sh and the probes are there in the action/ and files/ layout" \
    eval 'has "$OUT" "$IR_LIB/action/verify.sh" && has "$OUT" "$IR_LIB/files/verify-probes.sh"'
  check "the run record is root's and readable by everyone" has "$OUT" "-rw-r--r-- root /etc/supply-chain-hardening.outputs"
  done_phase 3
}
ir_checks() {
  local row seen
  say "image-recipe: the verifier as the image runs commands (its entrypoint)"
  set +e
  "$DOCKER" run --rm "$IMG" "$IR_LIB/action/verify.sh" --emit=plain --json --fail-on=config > "$W/verify.json" 2> "$W/verify.err"
  RC=$?
  set -e
  show "verifier stderr (rc $RC)" "$(cat "$W/verify.err")"
  show "GAP and WEAK rows" "$(json_flagged "$W/verify.json" 2>&1)"
  check "no GAP the image could have closed: --fail-on=config exits 0 (rc $RC)" [ "$RC" -eq 0 ]
  row=$(json_row "$W/verify.json" "env layer propagation")
  check "env layer propagation: OK through the entrypoint ($row)" has "$row" "OK|FUNCTIONAL|"
  seen=$(json_get "$W/verify.json" 'd["result"]["tools_seen"]')
  check "it checked package managers: tools_seen includes npm ($seen)" has ",$seen," ",npm,"
  set +e
  "$DOCKER" run --rm "$IMG" "$IR_LIB/action/verify.sh" --emit=plain --json > "$W/verify-any.json" 2>/dev/null
  RC=$?
  set -e
  check "with --fail-on=any the exit status ($RC) agrees with --json's result" exit_agrees "$W/verify-any.json" "$RC"
  say "image-recipe: the same command without the entrypoint (control)"
  set +e
  "$DOCKER" run --rm --entrypoint "" "$IMG" "$IR_LIB/action/verify.sh" --emit=plain --json > "$W/verify-noep.json" 2>/dev/null
  set -e
  row=$(json_row "$W/verify-noep.json" "env layer propagation")
  check "CONTROL: a command started without it gets none of the env layer ($row)" has "$row" "GAP|FUNCTIONAL|NONE of"

  say "image-recipe: arguments that are not a command run node, as on the base image"
  local own base
  capture "$DOCKER" run --rm "$NODE_IMAGE" --version
  base=$OUT
  check "CONTROL: the base image's entrypoint runs node for \`--version\` (got: $base, rc $RC)" \
    eval '[ "$RC" -eq 0 ] && printf "%s\n" "$base" | grep -qxE "v[0-9]+\.[0-9]+\.[0-9]+"'
  own=$("$DOCKER" run --rm --entrypoint "" "$IMG" node --version) || own="(node --version failed)"
  capture "$DOCKER" run --rm "$IMG" --version
  check "the image's entrypoint does too: \`IMG --version\` prints its node's version $own (got: $OUT, rc $RC)" \
    eval '[ "$RC" -eq 0 ] && [ "$OUT" = "$own" ]'
  capture "$DOCKER" run --rm "$IMG" -e 'console.log(6 * 7, process.env.NPM_CONFIG_IGNORE_SCRIPTS)'
  check "and \`IMG -e '...'\` runs node, with the env layer loaded (got: $OUT, rc $RC)" \
    eval '[ "$RC" -eq 0 ] && [ "$OUT" = "42 true" ]'

  say "image-recipe: a rebuild and the uv and pip cutoffs"
  local cut0 cut1 cut2 stamp
  cut0=$(ir_cutoffs "$IMG") || true
  show "cutoffs in the image setup built" "$cut0"
  # The control, and the reason for HARDEN_STAMP: rebuilt as it was, the cache
  # keeps the harden layer, and with it the cutoffs.
  ir_build nostamp || { show "build log" "$(tail -20 "$W/build-nostamp.log")"; }
  check "CONTROL: rebuilt with nothing changed, the cutoffs stay ($(ir_cutoffs "$IMG:nostamp" 2>&1 | head -1 || true))" \
    eval '[ -n "$cut0" ] && [ "$(ir_cutoffs "$IMG:nostamp")" = "$cut0" ]'
  stamp=$(date -u +%Y%m%dT%H%M%S)
  ir_build stamp1 --build-arg HARDEN_STAMP="$stamp" || { show "build log" "$(tail -20 "$W/build-stamp1.log")"; }
  cut1=$(ir_cutoffs "$IMG:stamp1" 2>&1) || true
  show "cutoffs with HARDEN_STAMP=$stamp" "$cut1"
  check "a new HARDEN_STAMP runs the hardening again: new cutoffs" \
    eval '[ -n "$cut1" ] && [ "$cut1" != "$cut0" ] && has "$cut1" "uploaded-prior-to = "'
  ir_build stamp1-again --build-arg HARDEN_STAMP="$stamp" || { show "build log" "$(tail -20 "$W/build-stamp1-again.log")"; }
  cut2=$(ir_cutoffs "$IMG:stamp1-again" 2>&1) || true
  check "the same HARDEN_STAMP again hits the cache: the same cutoffs ($cut2)" eval '[ -n "$cut2" ] && [ "$cut2" = "$cut1" ]'
  done_phase 11
}

# ============================================================== main ======

run_phase() {
  CHECKS=0; FAILS=0; CUR=$1
  case "$CELL:$1" in
    *:setup)   rm_work; mkdir -p "$W" ;;
  esac
  case "$CELL:$1" in
    vm-a:setup) vm_a_setup ;;            vm-a:contents) vm_a_contents ;;    vm-a:checks) vm_a_checks ;;
    uid-without-passwd:setup) uid_setup ;; uid-without-passwd:contents) uid_contents ;; uid-without-passwd:checks) uid_checks ;;
    replayed-state:setup) rs_setup ;;    replayed-state:contents) rs_contents ;; replayed-state:checks) rs_checks ;;
    image-recipe:setup) ir_setup ;;      image-recipe:contents) ir_contents ;; image-recipe:checks) ir_checks ;;
    *:cleanup) cleanup ;;
  esac
}

if [ "$PHASE" = all ]; then
  [ -n "${AGENT_SHELL_KEEP:-}" ] || trap cleanup EXIT
  for p in setup contents checks; do run_phase "$p"; done
else
  run_phase "$PHASE"
fi
