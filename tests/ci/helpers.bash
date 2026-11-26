#!/usr/bin/env bash
# Shared setup for the harden.sh suite.
#
# These tests exercise action/harden.sh DIRECTLY, on the host, with no docker
# and no Ansible. That is deliberate: the role's bats suite needs a built
# container, so before this file there was no test of the CI script that
# could run anywhere but a GitHub runner. Everything here runs on a bare
# checkout in under a second.
#
# Isolation: every test gets a throwaway $HOME and $TMPDIR and runs the
# script under `env -i`, so nothing touches the developer's real config and
# no ambient CI variable leaks in to skew platform auto-detection. harden()
# also gives every tool harden.sh wraps in place a stub in TEST_BIN first
# (shield_host_tools), so a real composer, bun, cargo or deno on the host is
# never the binary it replaces.
#
# WHAT THIS SUITE CANNOT REACH — read before trusting a green run:
#   - action.yml. Nothing here exercises the composite action's inputs,
#     outputs or ${{ github.action_path }}. The packaging every consumer
#     actually touches has ZERO coverage; only the smoke workflows test it.
#   - the /etc layer. WRITE_ETC is forced false throughout so the suite never
#     needs to write outside a temp dir, which means the sudo/system path is
#     never exercised here either.
#   - real tools for 10 of the 14 ecosystems. Only npm, node, uv and python3
#     are genuinely present; bun, deno, composer, cargo, go, pnpm, yarn,
#     maven, gradle and dotnet are STUBS. So these tests prove what the
#     wrappers EMIT, never that the real tool accepts it.
# A green run means the script behaves; it does not mean the action works.

HARDEN_SH="${BATS_TEST_DIRNAME}/../../action/harden.sh"
VERIFY_SH="${BATS_TEST_DIRNAME}/../../action/verify.sh"

# Named rather than being bats' own setup(): a .bats file that needs extra
# setup (a skip guard, say) defines its own setup(), which SHADOWS a setup()
# defined here and silently leaves every path variable empty.
common_setup() {
  TEST_HOME="${BATS_TEST_TMPDIR}/home"
  TEST_TMP="${BATS_TEST_TMPDIR}/tmp"
  TEST_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$TEST_HOME" "$TEST_TMP" "$TEST_BIN"
  # harden.sh's DEFAULT location with no RUNNER_TEMP: a per-user directory,
  # deliberately not $TMPDIR (VM#3: a fixed name in /tmp let another local user
  # plant the file the recipe sources). Every test uses the default, so the
  # default is what gets exercised.
  # shellcheck disable=SC2034  # consumed by the .bats files that load this
  STATE_DIR="${TEST_HOME}/.cache/supply-chain-hardening"
  # shellcheck disable=SC2034
  ENV_FILE="${STATE_DIR}/supply-chain-hardening.env"
  # shellcheck disable=SC2034
  OUT_FILE="${STATE_DIR}/supply-chain-hardening.outputs"
  # Not there. The real npm reads the host's global npmrc whatever HOME is, so on a
  # host the role has hardened (or any with a company one) a test of what harden.sh
  # wrote to HOME, or of npm with nothing written, was a test of that file as well.
  # MEASURED: 5 of 436 failed under the role's /etc/npmrc (npm 11.19.1).
  # shellcheck disable=SC2034
  NO_GLOBAL_NPMRC="${TEST_TMP}/no-global-npmrc"
  # Where pnpm reads its config, and so where harden.sh writes it: harden() runs
  # with no XDG_CONFIG_HOME. See pnpm_config_dir in action/harden.sh.
  # shellcheck disable=SC2034
  PNPM_DIR="${TEST_HOME}/.config/pnpm"
  [ "$(uname -s)" != Darwin ] || PNPM_DIR="${TEST_HOME}/Library/Preferences/pnpm"
}

# harden [VAR=value ...] [-- script args ...]
#
# Runs harden.sh in a pristine environment. WRITE_ETC is false so the suite
# never writes outside a temp dir. No test currently overrides it, so the
# /etc layer is untested here — the smoke workflows are the only coverage.
harden() {
  local -a envs=() args=()
  local sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then sep=1; continue; fi
    if [[ $sep -eq 1 ]]; then args+=("$a"); else envs+=("$a"); fi
  done
  refuse_root_cooldown_copy "${envs[@]}" || return 97
  shield_host_tools "${envs[@]}"
  # GRADLE_USER_HOME is part of the isolation, not part of the fixture.
  # Relocating HOME does NOT relocate gradle: gradle's default user home is
  # <user.home>/.gradle, and on Linux the JVM reads user.home from the PASSWD
  # ENTRY, so harden_gradle resolves the passwd home and would write the init
  # script into the developer's REAL ~/.gradle from inside a sandboxed test.
  # GRADLE_USER_HOME is the only lever that moves it, which is exactly why
  # harden_gradle exports it. Any sandbox that relocates HOME has to set this
  # too.
  env -i \
    PATH="${TEST_BIN}:${PATH}" \
    HOME="$TEST_HOME" \
    GRADLE_USER_HOME="${TEST_HOME}/.gradle" \
    TMPDIR="$TEST_TMP" \
    WRITE_ETC=false \
    "${envs[@]}" \
    bash "$HARDEN_SH" "${args[@]}"
}

# agent_sh [VAR=value ...] <command>
#
# The command as an agent runner with no startup files runs it. MEASURED on an agent VM
# on 2026-11-26 (docs/design-principles.md, "Agent runners"): every command went through
# `/bin/bash --norc --noprofile -c "umask 0007; ..."`, with no env layer. Here the
# environment holds HOME, PATH and TMPDIR and nothing else but what the caller names;
# PATH is AGENT_PATH, by default TEST_BIN and then this PATH.
agent_sh() {
  local cmd="${!#}"
  local -a envs=()
  [ "$#" -lt 2 ] || envs=("${@:1:$(($# - 1))}")
  env -i HOME="$TEST_HOME" PATH="${AGENT_PATH:-$TEST_BIN:$PATH}" TMPDIR="$TEST_TMP" \
    ${envs[@]+"${envs[@]}"} /bin/bash --norc --noprofile -c "umask 0007; $cmd"
}

# harden_agent [VAR=value ...] [-- script args ...]
#
# harden.sh --home-only, started the way agent_sh starts a command. No GRADLE_USER_HOME
# and no WRITE_ETC=false, unlike harden(): this mode has to keep out of the passwd home
# and /etc by itself. shield_host_tools all the same, so that if it ever wrapped a tool
# outside HOME it would be a stub of this test's.
harden_agent() {
  local -a envs=() args=()
  local sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then sep=1; continue; fi
    if [[ $sep -eq 1 ]]; then args+=("$a"); else envs+=("$a"); fi
  done
  shield_host_tools ${envs[@]+"${envs[@]}"}
  env -i HOME="$TEST_HOME" PATH="${AGENT_PATH:-$TEST_BIN:$PATH}" TMPDIR="$TEST_TMP" \
    ${envs[@]+"${envs[@]}"} \
    /bin/bash --norc --noprofile -c 'umask 0007; exec bash "$0" --home-only "$@"' \
    "$HARDEN_SH" ${args[@]+"${args[@]}"}
}

# shield_host_tools [VAR=value ...]
#
# harden.sh REPLACES some tools at the path it finds them on: it moves composer,
# bun, cargo and deno to <path>-real and writes its wrapper in their place,
# rewrites bunx, and with sfw (INSTALL_SFW=true or INTEL=sfw) does the same to
# npm and npx. With TEST_BIN first on PATH a stub there is what it finds; a
# test that stubs none falls through to the host's own binary, and with a
# usable sudo (every CI runner) or as root, that binary was wrapped. MEASURED at
# 6c77f4e, tests/ci as a user with passwordless sudo in a container with apt
# composer 2.8.8: after 03-config-files.bats, /usr/bin/composer was the
# harden.sh wrapper and /usr/bin/composer-real the original.
# So each of those names that would resolve outside this test's directory gets
# a pass-through stub in TEST_BIN first. harden.sh wraps the stub, the host's
# tool still answers through it (version, behaviour), and the host's binary is
# left as it was. A test that stubs a tool itself is unaffected.
# As root, harden.sh copies the cargo-cooldown it finds in $CARGO_HOME/bin to
# /usr/local/libexec/supply-chain-hardening/cargo/cargo-cooldown (a wrapper
# root runs is shared, so it gets a root-owned backend). That is the HOST path
# where the role installs the real shared gate backend, and a test's stub
# there is a no-op gate for every system cargo wrapper. MEASURED (tests/ci as
# root, run-ci-x container): 04-wrappers.bats and 07-verify.bats each created
# that file. A fixture that stages a cargo-cooldown calls this first.
skip_if_root_stages_cooldown() {
  [ "$(id -u)" -ne 0 ] || skip "running as root: harden.sh would copy this test's stub cargo-cooldown to the host's /usr/local/libexec/supply-chain-hardening/cargo/cargo-cooldown; run tests/ci as a non-root user"
}

# The safety net under that skip, for a fixture that forgets it: harden()
# refuses to start harden.sh as root while a cargo-cooldown sits where it
# looks. A refusal, not a skip: under `run`, bats' skip only ends the subshell.
refuse_root_cooldown_copy() {
  [ "$(id -u)" -eq 0 ] || return 0
  local ch="${TEST_HOME}/.cargo" a
  for a in "$@"; do
    case "$a" in CARGO_HOME=*) ch=${a#CARGO_HOME=} ;; esac
  done
  [ -e "$ch/bin/cargo-cooldown" ] || return 0
  echo "tests/ci: refusing to run harden.sh as root with $ch/bin/cargo-cooldown in place: it would replace the host's /usr/local/libexec/supply-chain-hardening/cargo/cargo-cooldown. The fixture must call skip_if_root_stages_cooldown." >&2
  return 1
}

shield_host_tools() {
  local tools="composer bun bunx cargo deno" t p a
  for a in "$@"; do
    case "$a" in INSTALL_SFW=true|INTEL=sfw) tools="$tools npm npx" ;; esac
  done
  for t in $tools; do
    p=$(PATH="${TEST_BIN}:${PATH}"; command -v "$t" 2>/dev/null) || continue
    case "$p" in
      /*) ;;
      *) continue ;;
    esac
    case "$p" in "${BATS_TEST_TMPDIR}"/*) continue ;; esac
    {
      printf '#!/bin/bash\n# tests/ci: pass-through to the host %s, so harden.sh wraps this file and not that one\n' "$t"
      # harden.sh installs sfw with `npm install -g`, which no pass-through may
      # carry to the host's own npm prefix.
      if [ "$t" = npm ]; then
        printf 'case " $* " in *" -g "*|*" --global "*) echo "tests/ci: refusing a global npm install from a test (it would change the host npm prefix); stub npm" >&2; exit 97 ;; esac\n'
      fi
      printf 'exec %q "$@"\n' "$p"
    } > "${TEST_BIN}/${t}"
    chmod +x "${TEST_BIN}/${t}"
  done
}

# verify [VAR=value ...] [-- script args ...]
#
# Runs verify.sh the way a LATER CI step would: same HOME and PATH, but a
# fresh environment, so whether the env layer propagated is a real question
# rather than an artifact of the test inheriting it.
verify() {
  local -a envs=() args=()
  local sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then sep=1; continue; fi
    if [[ $sep -eq 1 ]]; then
      args+=("$a")
    else
      # Catch the mistake this helper otherwise hides: `env` accepts ANY token
      # containing = as a variable assignment, so a flag passed before `--`
      # becomes a bogus variable and never reaches the script — the test then
      # passes while testing the default path.
      [[ "$a" == -* ]] && { echo "helper misuse: pass script flags after --, got '$a'" >&2; return 64; }
      envs+=("$a")
    fi
  done
  # GRADLE_USER_HOME for the same reason as in harden(): the verifier runs a
  # real gradle where one is installed, and without it gradle used the PASSWD
  # home. MEASURED at 6c77f4e in the same container as shield_host_tools: after
  # 07-verify.bats the tester's real ~/.gradle held caches/, daemon/ and native/.
  env -i \
    PATH="${TEST_BIN}:${PATH}" \
    HOME="$TEST_HOME" \
    GRADLE_USER_HOME="${TEST_HOME}/.gradle" \
    TMPDIR="$TEST_TMP" \
    HARDENING_ENV_FILE="$ENV_FILE" \
    "${envs[@]}" \
    bash "$VERIFY_SH" "${args[@]}"
}

# verify_sourced — as above, but with the env layer picked up first, which is
# what a correctly-configured job looks like.
verify_sourced() {
  env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    GRADLE_USER_HOME="${TEST_HOME}/.gradle" \
    bash -c "set -a; source '$ENV_FILE'; set +a
             HARDENING_ENV_FILE='$ENV_FILE' bash '$VERIFY_SH' $*"
}

# stub_bin <name> [body]
#
# Drops a fake executable early on PATH so harden.sh discovers it, wraps it in
# place, and we can then assert on what the wrapper passes through. Default
# body echoes argv so a test can inspect the forwarded arguments; it also
# answers --version so detect_version finds something.
stub_bin() {
  local name="$1"; shift
  local body="${1:-}"
  if [[ -z "$body" ]]; then
    body='case "${1:-}" in
  --version|-v|version) echo "'"$name"' 9.9.9" ;;
  *) echo "STUB:'"$name"' ARGV0=$0 ARGS=[$*]" ;;
esac'
  fi
  # A previous wrap in the same test leaves a root-owned wrapper at this path
  # (harden.sh writes it with sudo), so plain truncation fails. Removing it does
  # not need root: TEST_BIN is ours, and a directory decides about its entries.
  # A bare `sudo rm` here asked a person for their password.
  rm -f "${TEST_BIN}/${name}"
  printf '#!/bin/bash\n%s\n' "$body" > "${TEST_BIN}/${name}"
  chmod +x "${TEST_BIN}/${name}"
}

# stub_symlink <name> <target>
#
# The layout a real bun install actually has: bunx is a SYMLINK to bun, not a
# separate binary. Wrapping code that writes with `tee` follows that link and
# clobbers whatever it points at, so any wrapper test that stubs both as plain
# files is testing a shape that does not occur in the wild.
stub_symlink() {
  local name="$1" target="$2"
  rm -f "${TEST_BIN}/${name}"
  ln -s "$target" "${TEST_BIN}/${name}"
}

# stub_go_env [version]
#
# A go that implements just `version` and `go env` (read, -w, -u, GOENV)
# against a GOENV file under $HOME, with go's precedence: the environment wins
# over the file. Enough to observe what harden.sh persists with `go env -w`
# and what verify.sh reads back with the environment stripped.
#
# version defaults to go1.27.4. Below go1.21 the stub has no GOTOOLCHAIN, as
# MEASURED on go1.18.10, go1.19.13 and go1.20.14: `go env -w GOTOOLCHAIN=...`
# fails with "unknown go command variable GOTOOLCHAIN", and `go env GOTOOLCHAIN`
# prints an empty line even with GOTOOLCHAIN=local exported.
stub_go_env() {
  local ver="${1:-go1.27.4}" minor notc=0
  minor=${ver#go1.}; minor=${minor%%.*}
  [[ "$minor" -lt 21 ]] && notc=1
  # Created when missing, never touched: a test of what a second run changes reads mtimes.
  stub_bin go 'f="$HOME/.config/go/env"; mkdir -p "${f%/*}"; [ -e "$f" ] || : > "$f"
notc='"$notc"'
case "${1:-}" in
  version) echo "go version '"$ver"' linux/amd64" ;;
  env) shift
    case "${1:-}" in
      -w) shift; for kv in "$@"; do k=${kv%%=*}
            if [ "$notc" = 1 ] && [ "$k" = GOTOOLCHAIN ]; then echo "go: unknown go command variable GOTOOLCHAIN" >&2; exit 1; fi
            grep -v "^$k=" "$f" > "$f.t" || true; mv "$f.t" "$f"; echo "$kv" >> "$f"; done ;;
      -u) shift; for k in "$@"; do grep -v "^$k=" "$f" > "$f.t" || true; mv "$f.t" "$f"; done ;;
      GOENV) echo "$f" ;;
      *) if [ "$notc" = 1 ] && [ "$1" = GOTOOLCHAIN ]; then echo
         elif v=$(printenv "$1"); then echo "$v"; else grep "^$1=" "$f" | cut -d= -f2-; fi ;;
    esac ;;
esac'
}

# The real binary harden.sh moved aside when it wrapped our stub.
stub_real() { echo "${TEST_BIN}/${1}-real"; }

assert_file_contains() {
  local file="$1" pattern="$2"
  [[ -f "$file" ]] || { echo "expected file missing: $file"; return 1; }
  grep -q -- "$pattern" "$file" || {
    echo "pattern not found in $file: $pattern"
    echo "--- actual ---"; cat "$file"
    return 1
  }
}

assert_file_lacks() {
  local file="$1" pattern="$2"
  [[ -f "$file" ]] || return 0
  if grep -q -- "$pattern" "$file"; then
    echo "pattern SHOULD NOT be in $file: $pattern"
    echo "--- actual ---"; cat "$file"
    return 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# stub_npm <version>: an npm that says it is that version and does nothing else.
# harden.sh writes min-release-age and allow-git by the npm it finds (npm 11.2.0 to
# 11.9.0 warns about them on every command), so a test about what those keys say
# must not depend on the npm of the machine it runs on.
stub_npm() { stub_bin npm "case \"\$*\" in --version) echo $1 ;; *) echo STUB ;; esac"; }

# bare_path: a directory with the basic utilities and nothing else, in BARE_PATH.
# harden.sh looks at every npm on PATH, so a test about which npm it found must
# not have this machine's own further down.
BARE_PATH=""
bare_path() {
  local d="$BATS_TEST_TMPDIR/bare" t p
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    for t in bash sh awk basename cat chmod chown cksum cmp cp cut date diff dirname echo env find getconf grep head hostname id install ln ls mkdir mktemp mv od perl pgrep printf ps python3 readlink rm sed sha256sum shasum sleep sort stat sudo tail tee touch tr true uname wc xargs; do
      p=$(type -P "$t" 2>/dev/null) || continue
      case "$p" in /*) ln -s "$p" "$d/$t" ;; esac
    done
  fi
  BARE_PATH="$TEST_BIN:$d"
}

# npm_ge <version>: the npm on PATH is at least <version>. awk, not sort -V,
# which the macOS runners' sort may lack.
npm_ge() {
  awk -v a="$(npm --version 2>/dev/null)" -v b="$1" 'BEGIN { split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 0 }'
}

# Rewrite a file in place, keeping its mode and owner: `filter_file FILE CMD...`
# runs CMD with FILE on stdin and writes its stdout back over FILE. Use it
# instead of `sed -i`: BSD sed on the macOS runners has no plain -i (it takes
# the script as a backup suffix) and no \n in a replacement.
filter_file() {
  local f="$1" tmp
  shift
  tmp="$BATS_TEST_TMPDIR/filter_file.$$.$RANDOM"
  "$@" < "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -w "$f" ]; then cat "$tmp" > "$f"; else sudo -n cp "$tmp" "$f"; fi
  rm -f "$tmp"
}
