#!/usr/bin/env bats
# The verifier.
#
# harden.sh writing a file proves nothing about enforcement. These check that
# verify.sh reaches the right verdict in each way hardening can be present on
# disk and absent in effect — which is every way it has actually failed.

load helpers

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  # The pnpm repo config override fixture's project (pn_project). Resolved
  # physically: the row names the directory it found, and on macOS the temp
  # dir under /var is a symlink to /private/var.
  PNT=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  PNP="$PNT/proj"
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null \
    || skip "needs passwordless sudo to wrap binaries"
}

@test "reports the env layer as propagated when it was sourced" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"env layer propagation"* ]]
  [[ "$output" == *"variables present in this step's environment"* ]]
}

@test "flags the env layer as a GAP when nothing sourced it" {
  # The silent half-application: config files landed, no variable arrived.
  # On gitlab/buildkite/plain this is the single most likely misconfiguration.
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=plain
  [[ "$output" == *"GAP"* ]]
  [[ "$output" == *"NONE of"* ]]
  [[ "$output" == *"variables reached this step"* ]]
}

@test "the env-layer record names a variable that did not arrive" {
  # One variable missing out of several is named, not reported as "NONE of".
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  grep -q '^export NPM_CONFIG_MIN_RELEASE_AGE=' "$ENV_FILE"
  run verify_sourced --emit=plain
  [[ "$output" == *"OK"*"env layer propagation"*"all "*" variables present in this step's environment"* ]]
  run env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    GRADLE_USER_HOME="${TEST_HOME}/.gradle" \
    bash -c "set -a; source '$ENV_FILE'; set +a; unset NPM_CONFIG_MIN_RELEASE_AGE
             HARDENING_ENV_FILE='$ENV_FILE' bash '$VERIFY_SH' --emit=plain"
  [[ "$output" == *"GAP"*"env layer propagation"*"missing: NPM_CONFIG_MIN_RELEASE_AGE"* ]]
}

@test "names the env file in the diagnosis so the fix is obvious" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=plain
  [[ "$output" == *"$ENV_FILE"* ]]
}

# GROUND TRUTH FIRST, THEN THE VERDICT.
#
# The bug these three tests exist to prevent was invisible to the tests that
# came before them, because those asserted the STRING the verifier prints
# rather than the FACT it is a claim about. They put one shape of front-runner
# on PATH — a plain copy of the real binary, which does not delegate — and
# checked for "shadowed and never runs". Under that fixture the claim happens
# to be true, so the test passed, and it would have passed no matter how wrong
# the verifier was about every other front-runner.
#
# `wrapper_actually_ran` answers the question by its own route: invoke the
# tool, ask the wrapper whether it executed. The verifier's verdict is then
# required to agree with an answer derived independently of it.
wrapper_actually_ran() {
  local probe="${BATS_TEST_TMPDIR}/ran.$$"
  rm -f "$probe"
  env PATH="$1" HOME="$TEST_HOME" SCH_WRAPPER_PROBE="$probe" \
      bun --version >/dev/null 2>&1 || true
  [ -s "$probe" ] && grep -q "supply-chain-harden" "$(head -1 "$probe")" 2>/dev/null
}

@test "a non-delegating binary in front really does bypass the wrapper" {
  # A setup step that reinstalls a tool AFTER hardening. The wrapper exists;
  # nothing reaches it. Ground truth and verdict must both say so.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/later"
  cp "$(stub_real bun)" "$BATS_TEST_TMPDIR/later/bun"
  local p="$BATS_TEST_TMPDIR/later:${TEST_BIN}:${PATH}"

  run wrapper_actually_ran "$p"
  [ "$status" -ne 0 ]              # fact: it did NOT run

  run env -i PATH="$p" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    HARDENING_ENV_FILE="$ENV_FILE" bash "$VERIFY_SH" --emit=plain
  [[ "$output" == *"did NOT run"* ]]
  [[ "$output" == *"bun PATH wrapper"* ]]
}

@test "a DELEGATING front-runner is not reported as bypassed" {
  # REGRESSION. MEASURED against a real Aikido safe-chain shim: it strips its
  # own directory from PATH and execs the next match, which is our wrapper, so
  # the wrapper ran on every call — while the verifier reported "shadowed and
  # never runs" at FUNCTIONAL strength. Every version manager (asdf, mise,
  # volta, nodenv, pyenv) is shim-first and delegates identically, so this
  # fired for those users with no second security tool anywhere.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null

  mkdir -p "$BATS_TEST_TMPDIR/shims"
  cat > "$BATS_TEST_TMPDIR/shims/bun" <<EOF
#!/bin/sh
# a delegating shim: drop our own dir, hand off to whatever is next
_p=\$(echo "\$PATH" | sed "s|$BATS_TEST_TMPDIR/shims:||g")
exec env PATH="\$_p" bun "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/shims/bun"
  local p="$BATS_TEST_TMPDIR/shims:${TEST_BIN}:${PATH}"

  run wrapper_actually_ran "$p"
  [ "$status" -eq 0 ]              # fact: it DID run

  run env -i PATH="$p" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    HARDENING_ENV_FILE="$ENV_FILE" bash "$VERIFY_SH" --emit=plain
  [[ "$output" == *"observed running"* ]]
  [[ "$output" == *"chained behind"* ]]
  [[ "$output" != *"did NOT run"* ]]
}

@test "the verdict agrees with ground truth in both directions" {
  # The property the other two are instances of, asserted directly: whatever
  # the wrapper actually did, the verifier says the same thing. A future check
  # that re-introduces position-inference fails here even if someone updates
  # the message strings to match.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/blocker" "$BATS_TEST_TMPDIR/passthru"
  cp "$(stub_real bun)" "$BATS_TEST_TMPDIR/blocker/bun"
  cat > "$BATS_TEST_TMPDIR/passthru/bun" <<EOF
#!/bin/sh
_p=\$(echo "\$PATH" | sed "s|$BATS_TEST_TMPDIR/passthru:||g")
exec env PATH="\$_p" bun "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/passthru/bun"

  local dir
  for dir in blocker passthru; do
    local p="$BATS_TEST_TMPDIR/$dir:${TEST_BIN}:${PATH}"
    local truth=ran
    wrapper_actually_ran "$p" || truth=bypassed

    run env -i PATH="$p" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
      HARDENING_ENV_FILE="$ENV_FILE" bash "$VERIFY_SH" --emit=plain
    local verdict=bypassed
    # Scope to the bun row: composer/cargo wrappers also print "observed
    # running", so an unscoped match reads THEIR success as bun's (the 'blocker'
    # case bun row correctly says "did NOT run", but the whole-output grep hit
    # composer's line -> false 'ran').
    echo "$output" | grep 'bun PATH wrapper' | grep -q "observed running" && verdict=ran

    [ "$truth" = "$verdict" ] || {
      echo "front-runner '$dir': wrapper $truth, verifier said $verdict"
      echo "$output" | grep 'bun PATH wrapper'
      return 1
    }
  done
}

@test "the shadow diagnosis names both the wrapper and what won" {
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/later"
  cp "$(stub_real bun)" "$BATS_TEST_TMPDIR/later/bun"
  run env -i PATH="$BATS_TEST_TMPDIR/later:${TEST_BIN}:${PATH}" HOME="$TEST_HOME" \
    TMPDIR="$TEST_TMP" HARDENING_ENV_FILE="$ENV_FILE" bash "$VERIFY_SH" --emit=plain
  [[ "$output" == *"${TEST_BIN}/bun"* ]]
  [[ "$output" == *"$BATS_TEST_TMPDIR/later/bun"* ]]
}

@test "detects an orphaned wrapper whose real target is gone" {
  # The wrapper IS what PATH resolves to, but its recursion guard makes it
  # exit 127 on every call. Looks deployed, refuses to run.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  sudo rm -f "$(stub_real bun)"
  run verify -- --emit=plain
  [[ "$output" == *"refuse to run"* ]]
}

@test "the bunx row catches a wrapper that lets a leading metadata flag skip --no-install" {
  # `bunx some-cli` alone cannot see this: the plain shape is hardened while
  # `bunx --version some-cli` reaches real bun without --no-install, which
  # fetch-and-executes. The stub answers --help in bunx mode so the row gets
  # past its entry-point check to the dispatch it is testing.
  local body='case "${1:-}" in --version|-v) echo "1.4.4";; --help) echo "Usage: bunx [flags] <package>";; *) echo STUB;; esac'
  stub_bin bun "$body"
  stub_bin bunx "$body"
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     FUNCTIONAL  bunx fetch-and-execute blocked"* ]]
  # Put the bypass back: pass ANY leading metadata flag through, as the
  # wrapper did before the `$# -eq 1` guard. Assert the mutation landed, or a
  # wrapper rewrite would turn this into a test of nothing.
  # Not `sed -i`: BSD sed (the macOS job) needs `-i ''`. cp keeps the mode.
  sed 's/if \[ "\$#" -eq 1 \]; then/if true; then/' "$TEST_BIN/bunx" > "$BATS_TEST_TMPDIR/bunx"
  sudo cp "$BATS_TEST_TMPDIR/bunx" "$TEST_BIN/bunx"
  grep -q 'if true; then' "$TEST_BIN/bunx"
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    FUNCTIONAL  bunx fetch-and-execute blocked"* ]]
  [[ "$output" == *'`bunx --version some-cli`'* ]]
}

@test "the bunx row catches a BUN wrapper that lets a leading metadata flag skip --no-install" {
  # Same bypass one token later: `bun --version x <pkg>` fetch-and-executes on
  # bun 1.4.4, and the Action's bun wrapper passed any leading metadata flag
  # through. No bunx here, so the row's bun-only branch is the one under test.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.4.4";; --help) echo "Usage: bun <command> [...flags]";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     FUNCTIONAL  bunx fetch-and-execute blocked"* ]]
  # Put the bypass back, portably (BSD sed has no bare -i), and prove it landed.
  sed 's/if \[ "\$#" -eq 1 \]; then/if true; then/' "$TEST_BIN/bun" > "$BATS_TEST_TMPDIR/bun"
  sudo cp "$BATS_TEST_TMPDIR/bun" "$TEST_BIN/bun"
  grep -q 'if true; then' "$TEST_BIN/bun"
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    FUNCTIONAL  bunx fetch-and-execute blocked"* ]]
  [[ "$output" == *'`bun --version x some-cli`'* ]]
}

@test "pip age gate: a cutoff in the future is a GAP, not OK" {
  # A future uploaded-prior-to admits everything published before it. The row
  # used to compute a negative age, miss the > 7 day test and print OK.
  local realpy; realpy=$(command -v python3)
  stub_bin python3 'if [ "${1:-}" = -m ] && [ "${2:-}" = pip ]; then
  case "${3:-}" in
    --version) echo "pip 26.1 from /x/pip (python 3.13)" ;;
    install) echo "  --uploaded-prior-to <datetime>" ;;
    config) echo "global.uploaded-prior-to='"'"'2099-01-01T00:00:00Z'"'"'" ;;
  esac
  exit 0
fi
exec '"$realpy"' "$@"'
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      pip native age gate"*"FUTURE"* ]]
}

@test "pip age gate: a pip without the flag fails only the jobs that hardened pip" {
  # Stock ubuntu-24.04 runners have pip 24.0. That is a real GAP for a job that
  # asked for pip -- and none of the business of a job that did not.
  local realpy; realpy=$(command -v python3)
  stub_bin python3 'if [ "${1:-}" = -m ] && [ "${2:-}" = pip ]; then
  case "${3:-}" in
    --version) echo "pip 24.0 from /usr/lib/python3/dist-packages/pip (python 3.12)" ;;
    install) echo "  --only-binary <format_control>" ;;
  esac
  exit 0
fi
exec '"$realpy"' "$@"'
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      pip native age gate"*"pip 24.0 does NOT implement"* ]]
  # Counted as toolchain: no re-run teaches pip 24 the flag. It was counted as
  # config, so the summary told the reader re-running the hardening would fix it.
  [[ "$output" =~ [1-9][0-9]*\ no\ configuration\ can\ close ]]

  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"N/A    BYDESIGN    pip native age gate"*"not in the requested ecosystems"* ]]
  [[ "$output" != *"GAP    PARSED      pip native age gate"* ]]
}

@test "cargo publish-age gate: a repo cooldown.toml is a GAP even with the environment pinned" {
  # The pin beats a repo file only for settings that have an environment form.
  # MEASURED on cargo-cooldown 0.3.5: `[allow.global] minutes = 0` in a repo
  # cooldown.toml still built a crate published hours earlier through a pinned
  # wrapper. The row used to downgrade this to WEAK.
  skip_if_root_stages_cooldown
  stub_bin cargo 'case "${1:-}" in --version|-v) echo "cargo 1.99.0";; *) echo "STUB:cargo ARGS=[$*]";; esac'
  mkdir -p "$TEST_HOME/.cargo/bin"
  printf '#!/bin/sh\necho "cargo-cooldown 0.3.5"\n' > "$TEST_HOME/.cargo/bin/cargo-cooldown"
  chmod +x "$TEST_HOME/.cargo/bin/cargo-cooldown"
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  printf '[allow.global]\nminutes = 0\n' > "$BATS_TEST_TMPDIR/repo/cooldown.toml"
  cd "$BATS_TEST_TMPDIR/repo"
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    FUNCTIONAL  cargo publish-age gate"*"[allow.global]"* ]]
}

@test "cargo threat-intel: a cold sfw cache says cargo runs unfiltered, not that every build fails" {
  # With nothing cached, sfw cannot run for a non-root caller (it cannot
  # create its root-owned cache), and the cargo wrapper then runs cargo
  # WITHOUT sfw and warns. MEASURED in the role and the action: the crate
  # downloaded, exit 0, while this row said "EVERY cargo build in this job is
  # failing" and sent the operator after the wrong problem.
  [ "$(id -u)" != 0 ] || skip "root can fill the cache itself, so the wrapper does not skip sfw"
  stub_bin cargo 'case "${1:-}" in --version|-v) echo "cargo 1.80.0";; *) echo "STUB:cargo ARGS=[$*]";; esac'
  mkdir -p "$BATS_TEST_TMPDIR/proj"; touch "$BATS_TEST_TMPDIR/proj/Cargo.lock"
  # sfw laid out like a global npm install. It fails the way the real one
  # does when it cannot create its cache.
  local pkg="$BATS_TEST_TMPDIR/prefix/lib/node_modules/sfw"
  mkdir -p "$pkg/dist" "$pkg/.sfw-cache"
  printf '{"name":"sfw","version":"2.0.6"}\n' > "$pkg/package.json"
  printf '#!/bin/bash\n[ -e "%s/.sfw-cache/latest" ] && exec "$@"\necho "[sfw] Failed to prepare firewall binary: EACCES: permission denied, mkdir" >&2; exit 1\n' "$pkg" > "$pkg/dist/sfw.mjs"
  chmod +x "$pkg/dist/sfw.mjs"
  stub_symlink sfw "$pkg/dist/sfw.mjs"
  ln -s "$pkg/dist/sfw.mjs" "$pkg/.sfw-cache/latest"
  harden ECOSYSTEMS=cargo CARGO_SOCKET_FIREWALL=true -- --emit=plain >/dev/null
  rm -f "$pkg/.sfw-cache/latest"
  chmod a-w "$pkg/.sfw-cache"

  # Ground truth first: the build runs, unfiltered, with the warning.
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' fetch 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw has no firewall binary cached"* ]]
  [[ "$output" == *"sudo sh -c 'umask 022; sfw true && chmod -R go+rX "*"/.sfw-cache'"* ]]

  run verify_sourced --emit=plain
  row=$(printf '%s\n' "$output" | grep 'cargo threat-intel filtering')
  echo "$row"
  [[ "$row" == "GAP    FUNCTIONAL  cargo threat-intel filtering"* ]]
  [[ "$row" == *"runs cargo WITHOUT sfw"* ]]
  # The command must leave a binary other accounts can run: under a umask of
  # 077 (a caller's own on Debian 13, or sudoers `Defaults umask=0077`), a bare
  # `sudo sfw true` downloaded it into a 0700 cache and every other account
  # still failed (MEASURED, sfw 2.0.6 on Ubuntu 24.04 and Debian 13). The path
  # is matched loosely: readlink -f resolves macOS's /var to /private/var.
  [[ "$row" == *"sudo sh -c 'umask 022; sfw true && chmod -R go+rX "*"/.sfw-cache'"* ]]
  [[ "$row" == *"re-run action/harden.sh"* ]]
  [[ "$row" != *"EVERY cargo build"* ]]

  # An sfw that cannot execute with a binary cached is still the failing case.
  chmod u+w "$pkg/.sfw-cache"
  ln -s "$pkg/dist/sfw.mjs" "$pkg/.sfw-cache/latest"
  printf '#!/bin/bash\nexit 1\n' > "$pkg/dist/sfw.mjs"
  run verify_sourced --emit=plain
  row=$(printf '%s\n' "$output" | grep 'cargo threat-intel filtering')
  echo "$row"
  [[ "$row" == *"CANNOT EXECUTE"* ]]
}

@test "cargo publish-age gate: a backend the wrapper refuses for this account is its own GAP" {
  # The wrapper runs cargo-cooldown only when no other account can choose what
  # runs there (VM#2). A refusal exits 126 before cargo is reached; the row
  # must say so, not "no dispatch". The backend is given to ANOTHER account:
  # a root-owned file in this user's own directory is this user's to run.
  [ "$(id -u)" != 0 ] || skip "the fixture needs a non-root caller"
  sudo -n true 2>/dev/null || skip "needs passwordless sudo to hand the backend to another account"
  stub_bin cargo 'case "${1:-}" in --version|-v) echo "cargo 1.99.0";; *) echo "STUB:cargo ARGS=[$*]";; esac'
  mkdir -p "$TEST_HOME/.cargo/bin"
  printf '#!/bin/sh\necho "cargo-cooldown 0.3.5"\n' > "$TEST_HOME/.cargo/bin/cargo-cooldown"
  chmod 755 "$TEST_HOME/.cargo/bin/cargo-cooldown"
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  sudo chown 65534 "$TEST_HOME/.cargo/bin/cargo-cooldown"
  run verify_sourced --emit=plain
  sudo rm -f "$TEST_HOME/.cargo/bin/cargo-cooldown"
  [[ "$output" == *"GAP    FUNCTIONAL  cargo publish-age gate"*"REFUSES its gate backend"* ]]
}

@test "cargo publish-age gate: a wrapper that still prepends another account's directory is GAP" {
  # Wrappers rendered before the backend had a fixed path PREPENDED a directory
  # to PATH. MEASURED (VM#2): at /usr/bin/cargo that made root and a second
  # account run the deploying user's cargo-cooldown and ~/.cargo/bin/cargo,
  # while the dispatch probe still saw `cooldown build`. Owned by the caller,
  # the same line is the caller's own business and not this GAP.
  [ "$(id -u)" != 0 ] || skip "the fixture needs a non-root caller"
  sudo -n true 2>/dev/null || skip "needs passwordless sudo to stage another account's directory"
  stub_bin cargo 'case "${1:-}" in --version|-v) echo "cargo 1.99.0";; *) echo "STUB:cargo ARGS=[$*]";; esac'
  mkdir -p "$TEST_HOME/.cargo/bin"
  printf '#!/bin/sh\necho "cargo-cooldown 0.3.5"\n' > "$TEST_HOME/.cargo/bin/cargo-cooldown"
  chmod 755 "$TEST_HOME/.cargo/bin/cargo-cooldown"
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  other="$BATS_TEST_TMPDIR/theirs"
  mkdir -p "$other"; chmod 755 "$other"; sudo chown 65534 "$other"
  filter_file "$TEST_BIN/cargo" awk -v l="COOLDOWN_BIN='$other'" '{ print } /^COOLDOWN_EXE=/ { print l }'
  grep -q "^COOLDOWN_BIN='$other'\$" "$TEST_BIN/cargo"
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    FUNCTIONAL  cargo publish-age gate"*"PREPENDS $other to PATH"* ]]
  filter_file "$TEST_BIN/cargo" sed "s|^COOLDOWN_BIN=.*|COOLDOWN_BIN='$TEST_HOME/.cargo/bin'|"
  run verify_sourced --emit=plain
  sudo rm -rf "$other"
  [[ "$output" == *"cargo publish-age gate"* ]]
  [[ "$output" != *"PREPENDS"* ]]
}

# uv_reporting <cutoff>: a uv that reports an absolute exclude-newer instant in
# the Debug shape `uv pip list --show-settings` prints, so the age-gate row
# can be driven without a real uv or a frozen clock.
uv_reporting() {
  stub_bin uv 'case "$*" in
  --version*|-V*) echo "uv 0.13.5" ;;
  "pip list --show-settings") printf "%s\n" "PipSettings {" "    no_build: true," "    exclude_newer: ExcludeNewer {" "        global: Some(" "            Absolute(" "                '"$1"'," "            )," "        )," "    }," "}" ;;
  *) echo /tmp ;;
esac'
}

# A BSD date stand-in, macOS shape: no -d at all, -j -f to parse.
bsd_date() {
  cat > "${TEST_BIN}/date" <<'SHIM'
#!/usr/bin/env python3
import sys, calendar, time
a = sys.argv[1:]
if "-d" in a:
    sys.stderr.write("date: illegal option -- d\n"); sys.exit(1)
if "-j" in a and "-f" in a:
    i = a.index("-f")
    try:
        print(calendar.timegm(time.strptime(a[i + 2], a[i + 1]))); sys.exit(0)
    except ValueError:
        sys.exit(1)
if a and a[-1].startswith("+"):
    print(int(time.time()) if a[-1] == "+%s" else time.strftime(a[-1][1:], time.gmtime())); sys.exit(0)
sys.exit(1)
SHIM
  chmod +x "${TEST_BIN}/date"
}

@test "uv age gate: a cutoff weeks old reads as a freeze, not as OK" {
  uv_reporting 2026-01-01T00:00:00Z
  harden ECOSYSTEMS=uv -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      uv age gate"*"FREEZE"* ]]
}

@test "uv age gate: a cutoff two days old reads as OK with its age" {
  # GNU `-d` or BSD `-v`: this suite also runs on macOS.
  uv_reporting "$(date -u -d '2 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-2d '+%Y-%m-%dT%H:%M:%SZ')"
  harden ECOSYSTEMS=uv -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      uv age gate"*"(2 day(s) old)"* ]]
}

@test "uv age gate: BSD date still sees the freeze (it used to read 0 days old)" {
  # macOS date has no -d. The age used to fall back to 0, so a months-old
  # freeze read OK "(0 day(s) old)" on exactly the hosts least likely to
  # have GNU date.
  uv_reporting 2026-01-01T00:00:00Z
  harden ECOSYSTEMS=uv -- --emit=plain >/dev/null
  bsd_date
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      uv age gate"*"FREEZE"* ]]
  [[ "$output" != *"0 day(s) old"* ]]
}

@test "an active wrapper reads as OK at FUNCTIONAL strength" {
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     FUNCTIONAL  bun PATH wrapper"* ]]
}

@test "distinguishes a key npm implements from one it merely echoes back" {
  # npm returns a value for ANY key present in config, implemented or not.
  # On npm < 11.10.0 min-release-age is echoed and enforced by nothing, which
  # is precisely the failure this whole script exists to surface.
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"npm lifecycle scripts blocked"* ]]
  [[ "$output" == *"npm age gate"* ]]
  # Whichever way this npm goes, the verdict must be argued from
  # implementation, not from the value being echoed back.
  if [[ "$output" == *"does NOT implement min-release-age"* ]]; then
    [[ "$output" == *"GAP"* ]]
  else
    [[ "$output" == *"implements min-release-age and reports"* ]]
  fi
}

@test "exits non-zero when there is a gap and zero when there is not" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  # Unsourced env layer guarantees at least one gap.
  run verify -- --emit=plain
  [ "$status" -eq 1 ]
}

@test "--quiet suppresses the table but keeps the exit code" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=plain --quiet
  [ "$status" -eq 1 ]
  [[ "$output" != *"STATUS"* ]]
}

@test "--strict turns PRESENT-only rows into a failure" {
  # A hardened, sourced job with no gaps can still be carrying rows whose only
  # evidence is that a file exists. --strict is for pipelines that want
  # unverified to count as unprotected.
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced -- --emit=plain --strict
  # Either it found a gap (1) or strict escalated a WEAK row (1); both fail.
  # What must NOT happen is passing while reporting WEAK rows.
  if [[ "$output" == *"WEAK"* ]]; then [ "$status" -eq 1 ]; fi
}

@test "absent tools are N/A, not gaps" {
  # A runner without cargo is not an unprotected runner.
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"N/A"* ]]
}

@test "emits a GitHub error annotation on the github target" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=github
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"NOT in effect"* ]]
}

@test "plain mode emits no GitHub workflow commands" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=plain
  [[ "$output" != *"::error::"* ]]
}

@test "--help explains itself without running any probe" {
  run verify -- --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"EVIDENCE STRENGTH"* ]]
  # The help text documents the STATUS legend, so its presence proves nothing.
  # No RESULT line means no probe ran.
  [[ "$output" != *"RESULT:"* ]]
}

# --- publish-age gates: composer and bundler --------------------------------

# Both tools echo a key they ignore (MEASURED: composer 2.7.1, bundler 2.4.20), so
# these stubs report a healthy value at every version on purpose. A verdict that
# came from the readback would call the old versions OK.
composer_age_stub() { # version [extra line for the config dump]
  stub_bin composer "case \"\$*\" in
  *--version*) echo 'Composer version $1 2026-01-01 00:00:00' ;;
  *--list*) echo '[policy.cooldown.period] 172800 (/x/config.json)'
            echo '[policy.cooldown.block] true (/x/config.json)'
            echo '${2:-}' ;;
  *) echo STUB ;;
esac"
}

# The third argument is the top layer bundler's `config get cooldown` names
# (default: the environment); "none" makes that command print no account, the
# way a bundler that crashed on its config does.
bundler_age_stub() { # version cooldown [layer line | none]
  stub_bin bundle "case \"\$*\" in
  *--version*) echo '$1' ;;
  *'config get cooldown --parseable'*) echo 'cooldown=$2' ;;
  *'config get cooldown'*) [ '${3:-}' = none ] && exit 1
                           echo 'Settings for \`cooldown\` in order of priority. The top value will be used'
                           echo '${3:-Set via BUNDLE_COOLDOWN: $2}' ;;
  *) echo STUB ;;
esac"
}

@test "composer below 2.11 is a toolchain GAP even though it echoes the key" {
  composer_age_stub 2.10.3
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      composer publish-age gate"* ]]
  [[ "$output" == *"does NOT implement config.policy.cooldown"* ]]
  # Counted as toolchain, or --fail-on=config fails a job for what it was handed.
  [[ "$output" =~ [1-9][0-9]*\ no\ configuration\ can\ close ]]
}

@test "composer: every version-limited gap is toolchain, so fail-on=config can pass on a stock LTS" {
  # noble's 2.7.1 lacks both block-insecure and the cooldown. Neither is closed by
  # re-running the hardening, so neither may count as fixable.
  composer_age_stub 2.7.1
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      composer audit blocking"* ]]
  [[ "$output" == *"GAP    PARSED      composer publish-age gate"* ]]
  [[ "$output" =~ [2-9]\ no\ configuration\ can\ close ]]
}

@test "composer 2.11 with the gate in effect reads OK" {
  composer_age_stub 2.11.1
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      composer publish-age gate"* ]]
}

@test "composer: a window shorter than the declared one is WEAK, not OK" {
  composer_age_stub 2.11.1
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  echo 'export COMPOSER_POLICY_COOLDOWN_PERIOD=3600' >> "$ENV_FILE"
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      composer publish-age gate"* ]]
  [[ "$output" == *"below the 48h"* ]]
}

@test "composer: a repo ignoring every package is a GAP, since no env var outranks it" {
  composer_age_stub 2.11.1 '[policy.cooldown.ignore] [*] (./composer.json)'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      composer publish-age gate"* ]]
  [[ "$output" == *"every package skips the gate"* ]]
}

@test "composer: a narrow repo ignore list is WEAK and named" {
  composer_age_stub 2.11.1 '[policy.cooldown.ignore] [acme/*, foo/bar] (./composer.json)'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      composer publish-age gate"* ]]
  [[ "$output" == *"acme/*"* ]]
}

# MEASURED on 2.11.2 (VM run): ["*/*"] exempts every package (`composer require`
# resolved a release inside the window) but read WEAK, because only a literal
# "*" was recognised. Composer's only wildcard is *, so any pattern made of *
# and the one slash matches every vendor/name.
@test "composer: an ignore pattern that matches every vendor/name is a GAP, not just *" {
  local pat
  for pat in '*/*' '**' '*/**'; do
    composer_age_stub 2.11.1 "[policy.cooldown.ignore] [acme/*, $pat] (./composer.json)"
    harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
    run verify_sourced --emit=plain
    [[ "$output" == *"GAP    PARSED      composer publish-age gate"* ]] || { echo "'$pat' was not a GAP" >&2; return 1; }
    [[ "$output" == *"every package skips the gate"* ]]
  done
}

@test "composer: a map-form ignore entry is read, and a constrained match-all is WEAK" {
  composer_age_stub 2.11.1 '[policy.cooldown.ignore.*.constraint] <1.0 (./composer.json)
[policy.cooldown.ignore.*.reason] legacy (./composer.json)'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      composer publish-age gate"* ]]
  [[ "$output" == *"for the versions its constraint names"* ]]
  composer_age_stub 2.11.1 '[policy.cooldown.ignore.*] legacy (./composer.json)'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      composer publish-age gate"* ]]
}

# The writers put "allow-plugins": {} there, never false (false is a hard fatal
# below 2.2.15). Composer lists no [allow-plugins] line for {} (MEASURED 2.2.6,
# 2.7.1, 2.11.2), so the row was WEAK on every host, blaming a `false` nothing
# writes.
@test "composer: the empty allowlist the writers write reads OK, an allowed plugin a GAP" {
  composer_age_stub 2.11.1 '[secure-http] true (/x/config.json)'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      composer plugin execution blocked"* ]]
  [[ "$output" == *"empty allowlist"* ]]
  [[ "$output" != *"allow-plugins=false is NOT"* ]]
  composer_age_stub 2.11.1 '[allow-plugins.evil/probe] true (/x/config.json)'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      composer plugin execution blocked"* ]]
  [[ "$output" == *"evil/probe"* ]]
}

# composer_override_stub <effective-only lines>: the --global dump is the
# hardened one; the dump without --global (run inside the checkout) adds lines.
composer_override_stub() {
  stub_bin composer "case \"\$*\" in
  *--version*) echo 'Composer version 2.11.1 2026-01-01 00:00:00' ;;
  *--global*--list*) echo '[secure-http] true (/x/config.json)'
                     echo '[policy.cooldown.period] 172800 (/x/config.json)'
                     echo '[policy.cooldown.block] true (/x/config.json)' ;;
  *--list*) echo '[secure-http] true (/x/config.json)'
            echo '[policy.cooldown.period] 172800 (/x/config.json)'
            echo '[policy.cooldown.block] true (/x/config.json)'
            echo '$1' ;;
  *) echo STUB ;;
esac"
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"; mkdir -p "$CHECKOUT"
  echo '{"name":"t/t"}' > "$CHECKOUT/composer.json"
}

# MEASURED on 2.11.2 (VM run): a checkout's "policy": false with COMPOSER_POLICY=1
# exported is listed as `[policy] true (./composer.json)`; the gate rows were
# right (OK) but this row said GAP "policy: <unset> -> true ... composer uses
# the repo's value", crediting the env's value to the repo.
@test "composer: a repo key the exported env outranks is not reported as an override" {
  composer_override_stub '[policy] true (./composer.json)'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  echo 'export COMPOSER_POLICY=1' >> "$ENV_FILE"
  cd "$CHECKOUT"
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      composer repo config override"* ]]
  [[ "$output" == *"outranked by the exported COMPOSER_POLICY=1"* ]]
}

# MEASURED on 2.11.2 (VM run): with {"*": "x"} the gate row was GAP while this
# row said OK, "matches the global config on every key we harden".
@test "composer: a map-form ignore entry in the checkout is an override" {
  composer_override_stub '[policy.cooldown.ignore.*] x (./composer.json)'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  cd "$CHECKOUT"
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      composer repo config override"* ]]
  [[ "$output" == *"policy.cooldown.ignore entries"* ]]
}

# composer_ignore_stub <ignore JSON, empty = not set> [--list line]: answers the
# single-key read `composer config policy.cooldown.ignore` inside the checkout
# with the JSON composer prints; the global config sets no ignore list.
composer_ignore_stub() {
  stub_bin composer "case \"\$*\" in
  *--version*) echo 'Composer version 2.11.1 2026-01-01 00:00:00' ;;
  *'--global policy.cooldown.ignore'*) exit 1 ;;
  *'policy.cooldown.ignore'*) [ -n '$1' ] || exit 1; echo '$1' ;;
  *--global*--list*) echo '[secure-http] true (/x/config.json)'
                     echo '[policy.cooldown.period] 172800 (/x/config.json)'
                     echo '[policy.cooldown.block] true (/x/config.json)' ;;
  *--list*) echo '[secure-http] true (/x/config.json)'
            echo '[policy.cooldown.period] 172800 (/x/config.json)'
            echo '[policy.cooldown.block] true (/x/config.json)'
            echo '${2:-}' ;;
  *) echo STUB ;;
esac"
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"; mkdir -p "$CHECKOUT"
  echo '{"name":"t/t"}' > "$CHECKOUT/composer.json"
}

# MEASURED on 2.11.2 with the role applied: a checkout's {"*": {}}, {"*/*": {}}
# or {"*": []} let `composer require aws/aws-sdk-php --dry-run` take a release the
# baseline withholds as "still in the cooldown period", while `config --list`
# printed no line for the rule and both rows read OK. Composer prints the
# single-key read of all three as {"*":[]} / {"*/*":[]}.
@test "composer: an ignore rule with no fields that matches every package is a GAP on both rows" {
  have php || skip "php not installed (the verifier decodes the ignore list with php)"
  local shape
  for shape in '{"*":[]}' '{"*/*":[]}' '{"*":{}}' '{"*":null}' '{"*":[{"reason":"x"}]}'; do
    composer_ignore_stub "$shape"
    harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
    cd "$CHECKOUT"
    run verify_sourced --emit=plain
    cd - >/dev/null
    [[ "$output" == *"GAP    PARSED      composer publish-age gate"* && "$output" == *"every package skips the gate"* ]] \
      || { echo "gate row for $shape: $(printf '%s\n' "$output" | grep 'publish-age gate')" >&2; return 1; }
    [[ "$output" == *"GAP    PARSED      composer repo config override"* && "$output" == *"policy.cooldown.ignore entries: <none> -> "* ]] \
      || { echo "override row for $shape: $(printf '%s\n' "$output" | grep 'repo config override')" >&2; return 1; }
  done
  # The control: no ignore list reads OK on both rows.
  composer_ignore_stub ''
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  cd "$CHECKOUT"
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      composer publish-age gate"* ]]
  [[ "$output" == *"OK     PARSED      composer repo config override"* ]]
}

# MEASURED on 2.11.2: {"*": {"on-block": false}} still withheld the release; the
# rule only affects the audit report. It read GAP "every package skips the gate",
# and the override row named its field as a pattern ("<none> -> *.on-block").
@test "composer: a rule with on-block false exempts nothing from the gate" {
  have php || skip "php not installed (the verifier decodes the ignore list with php)"
  composer_ignore_stub '{"*":{"on-block":false}}' '[policy.cooldown.ignore.*.on-block] false (./composer.json)'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  cd "$CHECKOUT"
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      composer publish-age gate"* ]]
  [[ "$output" == *"OK     PARSED      composer repo config override"* ]]
  [[ "$output" != *"on-block"* ]]
}

# What every composer call in harden.sh and verify.sh hands composer, recorded by
# an UNWRAPPED stub (the wrapper sets COMPOSER_ALLOW_SUPERUSER itself, which would
# hide the probe's own environment). MEASURED before: run as root on a terminal,
# a composer that is not the wrapper waits at a hidden "Continue as root/super
# user [yes]?" prompt unless COMPOSER_ALLOW_SUPERUSER is set (with the wrapper
# reverted on 2.2.6 the verifier never finished), and the version probes ran
# with the checkout's composer.json as the project. Reading a version needs no
# project, and a probe must never boot the checkout it runs in.
@test "composer: every composer probe is non-interactive, root-safe, and reads a version with no project" {
  local log="$BATS_TEST_TMPDIR/composer-calls" body
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"; mkdir -p "$CHECKOUT"
  echo '{"name":"t/t","require":{}}' > "$CHECKOUT/composer.json"
  body="printf '%s|%s|%s|%s\\n' \"\$PWD\" \"\${COMPOSER-<unset>}\" \"\${COMPOSER_ALLOW_SUPERUSER-<unset>}\${COMPOSER_NO_INTERACTION:+ NI}\" \"\$*\" >> '$log'
case \"\$*\" in
  *--version*) echo 'Composer version 2.11.1 2026-01-01 00:00:00' ;;
  *--list*) echo '[secure-http] true (/x/config.json)' ;;
esac"
  stub_bin composer "$body"
  cd "$CHECKOUT"
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  stub_bin composer "$body"
  run verify_sourced --emit=plain
  [ -s "$log" ]
  local pwd comp su args nver=0
  while IFS='|' read -r pwd comp su args; do
    [[ "$su" == 1* ]] || { echo "no COMPOSER_ALLOW_SUPERUSER=1: composer $args (in $pwd)" >&2; return 1; }
    [[ " $args " == *" --no-interaction "* || " $args " == *" -n "* || "$su" == *" NI" ]] \
      || { echo "interactive: composer $args (in $pwd)" >&2; return 1; }
    if [[ " $args " == *" --version "* ]]; then
      nver=$((nver + 1))
      [ "$comp" = /dev/null/composer.json ] || { echo "version probe with COMPOSER=$comp: composer $args (in $pwd)" >&2; return 1; }
    fi
  done < "$log"
  # harden's probe, the verifier's version read and its run-probe(s)
  [ "$nver" -ge 3 ] || { echo "only $nver version probes recorded" >&2; cat "$log" >&2; return 1; }
}

@test "bundler below 4.0.13 is a toolchain GAP even though it echoes the key" {
  bundler_age_stub 2.4.20 2
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      bundler publish-age gate"* ]]
  [[ "$output" == *"does NOT implement cooldown"* ]]
  [[ "$output" =~ [1-9][0-9]*\ no\ configuration\ can\ close ]]
}

@test "bundler 4.0.13 is the first version the row accepts" {
  bundler_age_stub 4.0.12 2
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      bundler publish-age gate"* ]]
  bundler_age_stub 4.0.13 2
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  # What the row says about `gem install` depends on RubyGems, so pin it: the
  # host's own gem made this test pass or fail by what happened to be installed.
  stub_bin gem 'echo 3.4.20'
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      bundler publish-age gate"* ]]
  [[ "$output" == *"is not age-gated"* ]]
}

@test "bundler: on RubyGems 4.1+ the row says gem install shares the window" {
  # RubyGems 4.1.0 reads BUNDLE_COOLDOWN for `gem install` too (MEASURED: it
  # installs an older version inside the window, and refuses an exact pin to a
  # too-new one), so "gem install is not age-gated" is wrong there.
  bundler_age_stub 4.0.24 2
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  stub_bin gem 'echo 4.1.0'
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      bundler publish-age gate"* ]]
  [[ "$output" == *"RubyGems 4.1.0 applies the same window"* ]]
  [[ "$output" != *"is not age-gated"* ]]
}

@test "bundler: cooldown=0 is a GAP, because a repo's .bundle/config outranks the env var" {
  bundler_age_stub 4.0.24 0
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      bundler publish-age gate"* ]]
  [[ "$output" == *"disables the gate"* ]]
}

@test "bundler: a window shorter than the declared one is WEAK, not OK" {
  bundler_age_stub 4.0.24 1
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      bundler publish-age gate"* ]]
  [[ "$output" == *"below the 2d"* ]]
}

# A checkout whose own .bundle/config sets BUNDLE_COOLDOWN. Bundler's local
# config outranks the BUNDLE_COOLDOWN the env layer exports (MEASURED on 4.0.13,
# 4.0.24 and 4.1.0: a repo "0" let `bundle lock` take a release 22 hours old
# with BUNDLE_COOLDOWN=2 exported). The "bundler local config override" row
# used to read only BUNDLE_FROZEN and BUNDLE_DEPLOYMENT from that file, so it
# said N/A ("cannot switch lockfile pinning off") while the file switched the
# age gate off. The stub answers the window bundler reports from inside the
# checkout; the real-bundler test after these measures that answer.
bundler_cooldown_checkout() { # value [line prefix, e.g. one space]
  CHECKOUT="$BATS_TEST_TMPDIR/rbcheckout"; mkdir -p "$CHECKOUT/.bundle" "$CHECKOUT/sub"
  # The verifier sees the physical path (macOS: /var is /private/var).
  CHECKOUT=$(cd "$CHECKOUT" && pwd -P)
  printf 'source "https://rubygems.org"\n' > "$CHECKOUT/Gemfile"
  printf -- '---\n%sBUNDLE_COOLDOWN: "%s"\n' "${2:-}" "$1" > "$CHECKOUT/.bundle/config"
}
# What bundler's `config get cooldown` names as the top layer for that file.
bundler_local_layer() { echo "Set for your local app ($CHECKOUT/.bundle/config): $1"; }

@test "bundler: a checkout's BUNDLE_COOLDOWN \"0\" is a GAP on the local config row, which names the file" {
  bundler_cooldown_checkout 0
  bundler_age_stub 4.0.24 0 "$(bundler_local_layer 0)"
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  cd "$CHECKOUT/sub"
  run verify_sourced --emit=plain
  local r; r=$(grep 'bundler local config override' <<<"$output")
  [[ "$r" == "GAP    PARSED      bundler local config override"* ]]
  [[ "$r" == *"$CHECKOUT/.bundle/config switches the publish-age gate off"* ]]
  [[ "$(grep 'bundler publish-age gate' <<<"$output")" == GAP*"set by the local config at $CHECKOUT/.bundle/config"* ]]
}

@test "bundler: a checkout's BUNDLE_COOLDOWN below the declared window is WEAK on the local config row; at or above it, OK" {
  bundler_cooldown_checkout 1
  bundler_age_stub 4.0.24 1 "$(bundler_local_layer 1)"
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  cd "$CHECKOUT/sub"
  run verify_sourced --emit=plain
  local r; r=$(grep 'bundler local config override' <<<"$output")
  [[ "$r" == "WEAK   PARSED      bundler local config override"* ]]
  [[ "$r" == *"shortens the publish-age gate"*"below the 2d"* ]]
  bundler_cooldown_checkout 7
  bundler_age_stub 4.0.24 7 "$(bundler_local_layer 7)"
  run verify_sourced --emit=plain
  r=$(grep 'bundler local config override' <<<"$output")
  [[ "$r" == "OK     PARSED      bundler local config override"*"leaves the publish-age gate on"* ]]
}

@test "bundler: the local config row judges BUNDLE_COOLDOWN only where bundler implements it, and only when the file sets it" {
  # Below 4.0.13 the line is inert, and the publish-age row already reports the
  # toolchain gap.
  bundler_cooldown_checkout 0
  bundler_age_stub 4.0.12 0
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  cd "$CHECKOUT/sub"
  run verify_sourced --emit=plain
  [[ "$(grep 'bundler local config override' <<<"$output")" == N/A*"is inert: bundler 4.0.12 has no cooldown"* ]]
  # A version that cannot be read proves nothing about cooldown either way.
  bundler_age_stub 'no version here' 0
  run verify_sourced --emit=plain
  local r; r=$(grep 'bundler local config override' <<<"$output")
  [[ "$r" == N/A*"was not judged"*"bundler's version could not be read"* ]]
  [[ "$r" != *"inert"* && "$r" != *"has no cooldown"* && "$r" != *"switches nothing off"* ]] \
    || { echo "unproven claim: $r" >&2; return 1; }
  # FIXTURE CONTROL: the same stub window with no BUNDLE_COOLDOWN line in the
  # file, and bundler naming the environment as the layer. The local row must
  # not blame a file that does not set the key, and the publish-age row passes
  # on bundler's account instead of guessing a layer.
  bundler_age_stub 4.0.24 0
  printf -- '---\nBUNDLE_JOBS: "4"\n' > "$CHECKOUT/.bundle/config"
  run verify_sourced --emit=plain
  [[ "$(grep 'bundler local config override' <<<"$output")" == N/A*"sets none of BUNDLE_FROZEN, BUNDLE_DEPLOYMENT and BUNDLE_COOLDOWN"* ]]
  [[ "$(grep 'bundler publish-age gate' <<<"$output")" == GAP*"bundler names the layer in force: Set via BUNDLE_COOLDOWN: 0"* ]]
}

# Bundler parses its config with its own serializer, and a key indented by one
# space is still a top-level key to it. MEASURED on 4.0.13 and 4.1.0: a repo
# file holding ` BUNDLE_COOLDOWN: "0"` gave "Set for your local app
# (<repo>/.bundle/config): 0" with BUNDLE_COOLDOWN=2 exported and
# ~/.bundle/config at 2, while the verifier, grepping column 0, said the local
# config row was N/A and that "no local config here sets it, so BUNDLE_COOLDOWN
# or the user config does".
@test "bundler: a checkout key indented by one space is still the local config's, and the publish-age row says so" {
  bundler_cooldown_checkout 0 ' '
  bundler_age_stub 4.0.24 0 "$(bundler_local_layer 0)"
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  cd "$CHECKOUT/sub"
  run verify_sourced --emit=plain
  local r p
  r=$(grep 'bundler local config override' <<<"$output"); p=$(grep 'bundler publish-age gate' <<<"$output")
  [[ "$r" == "GAP    PARSED      bundler local config override"*"$CHECKOUT/.bundle/config switches the publish-age gate off"* ]]
  [[ "$p" == GAP*"set by the local config at $CHECKOUT/.bundle/config"* ]]
  [[ "$p" != *"no local config here sets it"* ]] || { echo "publish-age row blames another layer: $p" >&2; return 1; }
  # A bundler that gives no account: the file is read, leading blanks allowed.
  bundler_age_stub 4.0.24 0 none
  run verify_sourced --emit=plain
  r=$(grep 'bundler local config override' <<<"$output"); p=$(grep 'bundler publish-age gate' <<<"$output")
  [[ "$r" == "GAP    PARSED      bundler local config override"*"$CHECKOUT/.bundle/config switches the publish-age gate off"* ]]
  [[ "$p" == GAP*"set by the local config at $CHECKOUT/.bundle/config"* ]]
  # With no account and no key in the file, the row names no layer at all.
  printf -- '---\nBUNDLE_JOBS: "4"\n' > "$CHECKOUT/.bundle/config"
  run verify_sourced --emit=plain
  p=$(grep 'bundler publish-age gate' <<<"$output")
  [[ "$p" == GAP*"bundler gave no account of which config layer sets it"* ]]
  [[ "$p" != *"no local config here sets it"* && "$p" != *"BUNDLE_COOLDOWN or the user config does"* ]] \
    || { echo "publish-age row guesses a layer: $p" >&2; return 1; }
}

@test "bundler: with a real bundler, a checkout's BUNDLE_COOLDOWN outranks the exported one and the local config row reports it" {
  have bundle || skip "bundler not installed"
  have ruby || skip "ruby not installed"
  ruby -e 'require "bundler"; exit(Gem::Version.new(Bundler::VERSION) >= Gem::Version.new("4.0.13") ? 0 : 1)' 2>/dev/null \
    || skip "this bundler predates cooldown (4.0.13)"
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  bundler_cooldown_checkout 0
  # Ground truth: bundler's own answer from inside the checkout, with the env
  # layer (BUNDLE_COOLDOWN=2) in force.
  run env -i PATH="$PATH" HOME="$TEST_HOME" bash -c \
    "set -a; . '$ENV_FILE'; set +a; [ \"\$BUNDLE_COOLDOWN\" = 2 ] || exit 9; cd '$CHECKOUT/sub' && bundle config get cooldown --parseable"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cooldown=0"* ]]
  cd "$CHECKOUT/sub"
  run verify_sourced --emit=plain
  [[ "$(grep 'bundler local config override' <<<"$output")" == "GAP    PARSED      bundler local config override"*"switches the publish-age gate off"* ]]
  [[ "$(grep 'bundler publish-age gate' <<<"$output")" == GAP* ]]
  # CONTROL: the same checkout without the line. Nothing here overrides the
  # window, so the local row has nothing to report and the gate reads OK.
  printf -- '---\nBUNDLE_JOBS: "4"\n' > "$CHECKOUT/.bundle/config"
  run verify_sourced --emit=plain
  [[ "$(grep 'bundler local config override' <<<"$output")" == N/A* ]]
  [[ "$(grep 'bundler publish-age gate' <<<"$output")" == "OK     PARSED      bundler publish-age gate"* ]]
}

@test "bundler: with a real bundler, keys indented by one space switch the gate and pinning off, and the local config row names the file" {
  have bundle || skip "bundler not installed"
  have ruby || skip "ruby not installed"
  ruby -e 'require "bundler"; exit(Gem::Version.new(Bundler::VERSION) >= Gem::Version.new("4.0.13") ? 0 : 1)' 2>/dev/null \
    || skip "this bundler predates cooldown (4.0.13)"
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  bundler_cooldown_checkout 0 ' '
  # Ground truth first: bundler itself, with BUNDLE_COOLDOWN=2 exported, names
  # the checkout's file as the layer in force.
  run env -i PATH="$PATH" HOME="$TEST_HOME" bash -c \
    "set -a; . '$ENV_FILE'; set +a; [ \"\$BUNDLE_COOLDOWN\" = 2 ] || exit 9; cd '$CHECKOUT/sub' && bundle config get cooldown"
  [ "$status" -eq 0 ]
  [[ "$(grep -m1 'Set ' <<<"$output")" == *"Set for your local app ("*"/.bundle/config): 0" ]]
  cd "$CHECKOUT/sub"
  run verify_sourced --emit=plain
  local r p
  r=$(grep 'bundler local config override' <<<"$output"); p=$(grep 'bundler publish-age gate' <<<"$output")
  [[ "$r" == "GAP    PARSED      bundler local config override"*"$CHECKOUT/.bundle/config switches the publish-age gate off"* ]]
  [[ "$p" == GAP*"set by the local config at $CHECKOUT/.bundle/config"* ]]
  [[ "$p" != *"no local config here sets it"* ]] || { echo "publish-age row blames another layer: $p" >&2; return 1; }
  # The pinning half had the same column-0 grep. Pinning has to be in effect
  # at the user level for the local file to have anything to switch off.
  [[ "$output" == *"OK     FUNCTIONAL  bundler lockfile pinning"* ]] || skip "lockfile pinning is not in effect at the user level here"
  printf -- '---\n BUNDLE_FROZEN: "false"\n' > "$CHECKOUT/.bundle/config"
  run env -i PATH="$PATH" HOME="$TEST_HOME" bash -c \
    "set -a; . '$ENV_FILE'; set +a; cd '$CHECKOUT/sub' && bundle config get frozen"
  [[ "$(grep -m1 'Set ' <<<"$output")" == *"Set for your local app ("*"/.bundle/config): false" ]]
  run verify_sourced --emit=plain
  r=$(grep 'bundler local config override' <<<"$output")
  [[ "$r" == "GAP    FUNCTIONAL  bundler local config override"*"switches lockfile pinning off"* ]]
}

@test "composer: our config in the home composer really reads is OK, anyone else's is a GAP" {
  stub_bin composer "case \"\$*\" in
  *--version*) echo 'Composer version 2.11.1 2026-01-01 00:00:00' ;;
  *'config --global home'*) echo '$TEST_HOME/.composer' ;;
  *--list*) echo '[home] $TEST_HOME/.composer ($TEST_HOME/.composer/config.json)'
            echo '[secure-http] true ($TEST_HOME/.composer/config.json)' ;;
  *) echo STUB ;;
esac"
  harden ECOSYSTEMS=composer COMPOSER_HOME="$TEST_HOME/.composer" -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      composer config in effect"* ]]
  echo '{"config":{}}' > "$TEST_HOME/.composer/config.json"
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      composer config in effect"* ]]
}

@test "composer: where only ~/.composer is there, our config in it is OK and the user's own is a GAP" {
  mkdir -p "$TEST_HOME/.composer"
  stub_bin composer "case \"\$*\" in
  *--version*) echo 'Composer version 2.11.1 2026-01-01 00:00:00' ;;
  *--list*) echo '[home] $TEST_HOME/.composer ($TEST_HOME/.composer/config.json)'
            echo '[secure-http] true ($TEST_HOME/.composer/config.json)' ;;
  *) echo STUB ;;
esac"
  # an unhardened home with a config of the user's
  printf '{\n    "config": {\n        "secure-http": true\n    }\n}\n' > "$TEST_HOME/.composer/config.json"
  run verify -- --emit=plain
  [[ "$output" == *"GAP    PARSED      composer config in effect"* ]] || { grep composer <<<"$output"; return 1; }
  rm -f "$TEST_HOME/.composer/config.json"
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  [ ! -e "$TEST_HOME/.config/composer" ]
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      composer config in effect"* ]] || { grep composer <<<"$output"; return 1; }
}

@test "npm: a window shorter than the declared one is WEAK and names the env var" {
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  echo 'export NPM_CONFIG_MIN_RELEASE_AGE=1' >> "$ENV_FILE"
  run verify_sourced --emit=plain
  [[ "$output" == *"does NOT implement min-release-age"* ]] && skip "this npm predates the gate"
  [[ "$output" == *"WEAK   PARSED      npm age gate"* ]]
  [[ "$output" == *"below the 2 day(s)"* ]]
  [[ "$output" == *"NPM_CONFIG_MIN_RELEASE_AGE"* ]]
}

# The verifier's config reads answer only when --no-plugins comes first:
# without it Poetry loads a project's .poetry/plugins (MEASURED, 2.5.2), so a
# read without it is a bug and gets no value back. A bare --version is
# harden.sh's, which asks from /.
poetry_age_stub() { # version value [exclude]
  stub_bin poetry "case \"\$*\" in
  '--no-plugins --version'|--version) echo 'Poetry (version $1)' ;;
  '--no-plugins config solver.min-release-age') echo '$2' ;;
  '--no-plugins config solver.min-release-age-exclude') echo '${3:-null}' ;;
  *) echo STUB ;;
esac"
}

@test "poetry below 2.4.0 is a toolchain GAP" {
  poetry_age_stub 2.3.4 0
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      poetry publish-age gate"* ]]
  [[ "$output" == *"has no solver.min-release-age"* ]]
  [[ "$output" =~ [1-9][0-9]*\ no\ configuration\ can\ close ]]
}

@test "poetry 2.4.0 is the first version the row accepts" {
  poetry_age_stub 2.4.0 2
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      poetry publish-age gate"* ]]
}

@test "poetry: min-release-age=0 is a GAP" {
  poetry_age_stub 2.5.1 0
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      poetry publish-age gate"* ]]
  [[ "$output" == *"disables the gate"* ]]
}

@test "poetry: a repo's exclude list and a short window are both WEAK" {
  poetry_age_stub 2.5.1 2 '["six"]'
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      poetry publish-age gate"* ]]
  [[ "$output" == *"exempts"* ]]
  # The detail must NAME what is exempt and where. These fields used to print
  # blank: cq() was defined below the poetry rows, so bash had not seen it yet.
  [[ "$output" == *'exempts ["six"] in '* ]]
  [[ "$output" != *"cq: command not found"* ]]
  poetry_age_stub 2.5.1 1
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"below the 2d"* ]]
}

@test "pip: a python whose ensurepip seeds an ungated pip is WEAK" {
  stub_bin python3 'case "$*" in
  *ensurepip*) echo 25.3 ;;
  *) exit 1 ;;
esac'
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      pip venv age gate"* ]]
  [[ "$output" == *"seeds pip 25.3"* ]]
}

@test "a job holding id-token: write is told so, and one without gets no row" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" != *"ci id-token exposure"* ]]
  echo 'export ACTIONS_ID_TOKEN_REQUEST_URL=https://example.invalid/token' >> "$ENV_FILE"
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      ci id-token exposure"* ]]
}

# ------------------------------------------------------- python startup hooks
# The probe reads a user site under the throwaway HOME whatever python3 is, so
# these plant files there. python3.99 keeps the fixture independent of the real
# interpreter's version. Assertions name the planted file by its FULL path, never
# by a bare name: the scan also reads this host's own site directories, and a
# fixture that reused a real file's name failed on the first runner that had it.
hook_site() {
  HOOK_SITE="$TEST_HOME/.local/lib/python3.99/site-packages"
  mkdir -p "$HOOK_SITE"
  HOOK_SITE=$(cd "$HOOK_SITE" && pwd -P)
}

# The classified scan on its own: one "U<TAB>path (who claims it)" line per hook
# nothing vouches for, one "K<TAB>path (why)" line per recognised one. In the
# verifier scv_dpkg_info is assigned unconditionally, so nothing in the environment
# can move it; here it points at a fixture, or nowhere.
hook_fns() { sed -n '/^scv_site_dirs() {$/,/^scv_dpkg_info=/p' "$VERIFY_SH" | sed '$d'; }
hook_scan() { # [VAR=value ...]
  env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" "$@" \
    bash -c "$(hook_fns)"$'\n'"scv_dpkg_info='${HOOK_DPKG:-/nonexistent}'; scv_startup_hooks"
}
U() { printf 'U\t%s (%s)' "$1" "${2:-claimed by no installed distribution}"; }
K() {
  local why="${2:-}"
  [ -n "$why" ] || why="a known tool's generated line"
  printf 'K\t%s (%s)' "$1" "$why"
}
table_rows() { grep -cE '^(OK|GAP|WEAK|N/A) ' <<<"$1"; }

@test "startup hooks: the probe is byte-identical on both surfaces" {
  local role="${BATS_TEST_DIRNAME}/../../templates/verify.sh.j2"
  block() { sed -n '/^# >>> python startup hooks$/,/^# <<< python startup hooks$/p' "$1"; }
  [ -n "$(block "$VERIFY_SH")" ]
  diff <(block "$role") <(block "$VERIFY_SH")
}

@test "startup hooks: an unvouched import line is WEAK, named with its owner, and warned on stderr" {
  hook_site
  mkdir -p "$HOOK_SITE/litellm-1.107.0.dist-info"
  echo 'import os' > "$HOOK_SITE/cook.pth"
  printf 'cook.pth,sha256=x,1\nlitellm/__init__.py,sha256=y,2\n' > "$HOOK_SITE/litellm-1.107.0.dist-info/RECORD"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run --separate-stderr verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PRESENT     python startup hooks"* ]]
  [[ "$output" == *"$HOOK_SITE/cook.pth (litellm-1.107.0)"* ]]
  [[ "$stderr" == *"warning: "*"startup hook"*"$HOOK_SITE/cook.pth (litellm-1.107.0)"* ]]
}

@test "startup hooks: the warning comes before anything starts Python with site processing" {
  # Ground truth from Python itself, two ways, into ONE file: the planted hook logs
  # whenever a real interpreter processes this user site (the verifier's pip runs
  # one), and a stub python3 logs every start that would process site hooks. The
  # scan's own question to the interpreter uses -I -S, which imports no site, so
  # the stub stays quiet for that and the planted hook is what would catch it
  # misbehaving. The verifier silences python3's stderr, so its own stderr appends
  # to the same file; O_APPEND keeps everything in the order it happened. A run
  # where nothing started Python proves nothing, so that fails too.
  local log="$BATS_TEST_TMPDIR/order.log" v
  harden ECOSYSTEMS=npm,pip -- --emit=plain >/dev/null
  for v in 9 10 11 12 13 14 15 16; do
    mkdir -p "$TEST_HOME/.local/lib/python3.$v/site-packages"
    printf '%s\n' "import os; open('$log', 'a').write('PYTHON STARTED (hook)\\n')" \
      > "$TEST_HOME/.local/lib/python3.$v/site-packages/cook.pth"
  done
  stub_bin python3 "case \" \$* \" in *' -S '*) exit 1 ;; esac
echo 'PYTHON STARTED (python3)' >> '$log'; exit 1"
  : > "$log"
  verify_sourced --emit=plain >/dev/null 2>>"$log" || true
  local warn py
  warn=$(grep -n 'startup hook' "$log" | head -1 | cut -d: -f1)
  py=$(grep -n 'PYTHON STARTED' "$log" | head -1 | cut -d: -f1)
  [ -n "$warn" ]
  [ -n "$py" ]
  [ "$warn" -lt "$py" ]
}

@test "startup hooks: an interpreter behind a shim is found by asking it, and asking fires nothing" {
  # The pyenv/asdf/mise shape: `python3` on PATH is a script, and the interpreter and
  # its site-packages live somewhere the PATH entry does not reveal. MEASURED before
  # the -I -S query existed: Python ran the hook and the scan reported nothing.
  local real v="$BATS_TEST_TMPDIR/venv" site marker="$BATS_TEST_TMPDIR/fired"
  real=$(command -v python3) || skip "python3 not installed"
  "$real" -m venv --without-pip "$v" 2>/dev/null || skip "this python3 cannot create a venv"
  site=$(cd "$v"/lib/python3*/site-packages && pwd -P)
  echo "import os; open('$marker', 'w')" > "$site/cook.pth"
  stub_bin python3 "exec '$v/bin/python' \"\$@\""
  run hook_scan
  [[ "$output" == *"$(U "$site/cook.pth")"* ]]
  [ ! -e "$marker" ]                       # the scan, and its question, ran no hook
  "$TEST_BIN/python3" -c pass
  [ -e "$marker" ]                         # control: it is a live hook
}

@test "startup hooks: sitecustomize and usercustomize are reported in the forms Python imports" {
  hook_site
  mkdir "$HOOK_SITE/sitecustomize"
  : > "$HOOK_SITE/sitecustomize/__init__.py"
  : > "$HOOK_SITE/usercustomize.py"
  run hook_scan
  [[ "$output" == *"$(U "$HOOK_SITE/sitecustomize")"* ]]
  [[ "$output" == *"$(U "$HOOK_SITE/usercustomize.py")"* ]]
}

@test "startup hooks: a path line leads the scan to a sitecustomize outside the site root" {
  # Python imports sitecustomize from anywhere on sys.path, and a .pth line that is
  # not an import adds a directory to it. MEASURED: paths.pth + sub/sitecustomize.py
  # ran and went unreported while only the site root was read.
  hook_site
  local abs="$BATS_TEST_TMPDIR/elsewhere" pp="$BATS_TEST_TMPDIR/onpythonpath" base="$BATS_TEST_TMPDIR/userbase"
  mkdir -p "$HOOK_SITE/sub" "$abs" "$pp" "$base/lib/python3.99/site-packages"
  printf 'sub  \n%s\n# a comment\n\n' "$abs" > "$HOOK_SITE/paths.pth"
  : > "$HOOK_SITE/sub/sitecustomize.py"
  : > "$abs/usercustomize.py"
  : > "$pp/sitecustomize.py"
  echo 'import os' > "$base/lib/python3.99/site-packages/moved.pth"
  run hook_scan PYTHONPATH="/nonexistent:$pp" PYTHONUSERBASE="$base"
  [[ "$output" == *"$(U "$HOOK_SITE/sub/sitecustomize.py")"* ]]
  [[ "$output" == *"$(U "$abs/usercustomize.py")"* ]]
  [[ "$output" == *"$(U "$pp/sitecustomize.py")"* ]]
  [[ "$output" == *"$(U "$(cd "$base" && pwd -P)/lib/python3.99/site-packages/moved.pth")"* ]]
  [[ "$output" != *"paths.pth"* ]]         # a path-only file is not itself a hook
}

@test "startup hooks: lines are split where CPython splits them, not on newline alone" {
  # str.splitlines() ends a line at \r, \v, \f, \x1c-\x1e, U+0085, U+2028 and U+2029.
  # MEASURED on 3.13.12: a payload after any of them, behind a `#`, ran unreported.
  hook_site
  local i=0 sep
  for sep in '\r' '\013' '\014' '\034' '\035' '\036' '\302\205' '\342\200\250' '\342\200\251'; do
    i=$((i + 1))
    # shellcheck disable=SC2059  # the separator IS the escape sequence
    printf "# harmless comment${sep}import os\n" > "$HOOK_SITE/sep$i.pth"
  done
  run hook_scan
  for i in 1 2 3 4 5 6 7 8 9; do
    [[ "$output" == *"$(U "$HOOK_SITE/sep$i.pth")"* ]] || { echo "separator $i hid the import line"; false; }
  done
}

@test "startup hooks: a BOM or a tab does not hide an import line, and ignored lines are not hooks" {
  # CPython 3.13 decodes .pth as utf-8-sig and accepts `import\t` (MEASURED: both
  # ran). A leading space and a dotfile are not executed.
  hook_site
  printf '\357\273\277import os\n' > "$HOOK_SITE/bom.pth"
  printf 'import\tos\n' > "$HOOK_SITE/tab.pth"
  echo ' import os' > "$HOOK_SITE/leading-space.pth"
  echo 'import os' > "$HOOK_SITE/.dotfile.pth"
  run hook_scan
  [[ "$output" == *"$(U "$HOOK_SITE/bom.pth")"* ]]
  [[ "$output" == *"$(U "$HOOK_SITE/tab.pth")"* ]]
  [[ "$output" != *"leading-space.pth"* ]]
  [[ "$output" != *".dotfile.pth"* ]]
}

@test "startup hooks: a known tool's line is listed as recognised, never dropped" {
  hook_site
  # Byte-for-byte what setuptools 60.0 through 84.2.1, uv venv and a setuptools
  # editable install write (MEASURED).
  printf "import os; var = 'SETUPTOOLS_USE_DISTUTILS'; enabled = os.environ.get(var, 'local') == 'local'; enabled and __import__('_distutils_hack').add_shim(); \n" \
    > "$HOOK_SITE/distutils-precedence.pth"
  printf 'import _virtualenv' > "$HOOK_SITE/_virtualenv.pth"
  echo 'import __editable___my_pkg_0_1_finder; __editable___my_pkg_0_1_finder.install()' \
    > "$HOOK_SITE/__editable__.my_pkg-0.1.pth"
  run hook_scan
  local n
  for n in distutils-precedence.pth _virtualenv.pth __editable__.my_pkg-0.1.pth; do
    [[ "$output" == *"$(K "$HOOK_SITE/$n")"* ]] || { echo "not listed as recognised: $n"; false; }
  done
  # In the report they are an OK row that says what it does not vouch for. Only
  # checked where this host has no unvouched hook of its own to turn the row WEAK.
  HOOK_DPKG=/var/lib/dpkg/info run hook_scan
  if [[ "$output" != *$'U\t'* ]]; then
    harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
    run verify_sourced --emit=plain
    [[ "$output" == *"OK     PRESENT     python startup hooks"* ]]
    [[ "$output" == *"$HOOK_SITE/_virtualenv.pth"* ]]
    [[ "$output" == *"not the module it imports"* ]]
  fi
  # The familiar name with a payload appended is no longer the tool's text.
  echo 'import os; os.system("true")' >> "$HOOK_SITE/distutils-precedence.pth"
  run hook_scan
  [[ "$output" == *"$(U "$HOOK_SITE/distutils-precedence.pth")"* ]]
}

@test "startup hooks: a recognised line with a planted module is still shown, because nothing vouches for the module" {
  # The limit of recognising by text, kept visible on purpose. A wheel can ship the
  # exact editable-finder line AND its own finder module. MEASURED: Python ran it,
  # and while recognised hooks were dropped from the report it left no trace.
  hook_site
  echo 'import __editable___evil_1_finder; __editable___evil_1_finder.install()' > "$HOOK_SITE/__editable__.evil-1.pth"
  printf 'def install():\n    pass\n' > "$HOOK_SITE/__editable___evil_1_finder.py"
  run hook_scan
  [[ "$output" == *"$(K "$HOOK_SITE/__editable__.evil-1.pth")"* ]]
}

@test "startup hooks: a Debian-packaged hook counts only while it matches dpkg's checksum" {
  # MEASURED: stock ubuntu-24.04 runners ship python3-zope.interface's nspkg.pth, and
  # its md5 is the one in the package's .md5sums. This stages the same shape under a
  # name no real host has.
  command -v md5sum >/dev/null 2>&1 || skip "no md5sum here; dpkg hosts have it"
  hook_site
  local f="$HOOK_SITE/fixture-nspkg.pth" g="$HOOK_SITE/fixture-nosum.pth"
  HOOK_DPKG="$BATS_TEST_TMPDIR/dpkg-info"
  mkdir -p "$HOOK_DPKG"
  echo "import sys, types, os;p = os.path.join(sys._getframe(1).f_locals['sitedir'], *('zope',))" > "$f"
  echo 'import os' > "$g"
  printf '%s\n%s\n' "$f" "$g" > "$HOOK_DPKG/python3-fixture.list"
  printf '%s  %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "${f#/}" > "$HOOK_DPKG/python3-fixture.md5sums"
  run hook_scan
  [[ "$output" == *"$(K "$f" "python3-fixture package, checksum matches")"* ]]
  # Listed by the package with no checksum on record: not vouched for, and not
  # called "changed", which is not known.
  [[ "$output" == *"$(U "$g" "python3-fixture package, which records no checksum for it")"* ]]
  # A wheel that overwrote it: still listed by the package, no longer its bytes.
  echo 'import os; os.system("true")' >> "$f"
  run hook_scan
  [[ "$output" == *"$(U "$f" "python3-fixture package, changed since it was installed")"* ]]
}

@test "startup hooks: an unmodified Debian-packaged hook on this host is recognised" {
  local f found=""
  for f in /usr/lib/python3/dist-packages/*.pth; do
    [ -f "$f" ] || continue
    grep -q '^import[[:blank:]]' "$f" || continue
    grep -lqxF -- "$f" /var/lib/dpkg/info/*.list 2>/dev/null && { found=$f; break; }
  done
  [ -n "$found" ] || skip "no Debian-packaged .pth with an import line on this host"
  HOOK_DPKG=/var/lib/dpkg/info run hook_scan
  [[ "$output" == *$'K\t'"$found ("* ]]
}

# ------------------------------------------------------------ report integrity
# The report prints its rows with printf '%b', which expands backslash escapes, and
# row text carries strings this script does not choose.

@test "report: a file name cannot erase or forge rows" {
  # MEASURED before row() escaped its fields: `a\c.pth` cut a 42-row table to 1, and
  # the second name below added an "OK ... none found, site-packages is clean" row.
  hook_site
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  echo 'import os' > "$HOOK_SITE/plain.pth"
  run verify_sourced --emit=plain
  local base; base=$(table_rows "$output")
  [ "$base" -gt 5 ]
  mv "$HOOK_SITE/plain.pth" "$HOOK_SITE/"'a\c.pth'
  run verify_sourced --emit=plain
  [ "$(table_rows "$output")" -eq "$base" ]
  [[ "$output" == *'a\c.pth'* ]]
  mv "$HOOK_SITE/"'a\c.pth' "$HOOK_SITE/"'b\nOK\tFUNCTIONAL\tpython startup hooks\tnone found, site-packages is clean\nOK\tPARSED\tzz.pth'
  run verify_sourced --emit=plain
  [ "$(table_rows "$output")" -eq "$base" ]
  [ "$(grep -c '^OK .*python startup hooks' <<<"$output")" -eq 0 ]
}

@test "report: a config value read from a hostile checkout cannot end the table" {
  # The same renderer, reached without any package: a backslash-c in a checkout's
  # .npmrc, with the verifier run from that checkout as AGENTS.md advises.
  # MEASURED at d64ec46 with `min-release-age=1\c`: 41 rows from a clean directory,
  # 10 from the checkout. ignore-scripts is used here because every npm echoes it.
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/clean" "$BATS_TEST_TMPDIR/checkout"
  printf 'ignore-scripts=x\\c\n' > "$BATS_TEST_TMPDIR/checkout/.npmrc"
  # Asked of npm directly, not read off the verifier's output: the bug this guards
  # against eats that output, so a check that depended on it would skip, not fail.
  cd "$BATS_TEST_TMPDIR/checkout"
  [ "$(env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" npm config get ignore-scripts 2>/dev/null)" = 'x\c' ] \
    || skip "this npm does not hand back the checkout's value"
  # Not verify_sourced: with the env layer loaded, NPM_CONFIG_IGNORE_SCRIPTS
  # outranks the checkout's .npmrc and the hostile value never reaches a row.
  cd "$BATS_TEST_TMPDIR/clean"
  run verify -- --emit=plain
  local base; base=$(table_rows "$output")
  [ "$base" -gt 5 ]
  cd "$BATS_TEST_TMPDIR/checkout"
  run verify -- --emit=plain
  [ "$(table_rows "$output")" -eq "$base" ]
  [[ "$output" == *'ignore-scripts=x\c'* ]]
}

# ---- VM#3: a record or env file someone else can write is not believed ----

forge_record() { # a COMPLETE-looking record scoped to npm only
  mkdir -p "$STATE_DIR"
  printf 'ecosystems_hardened=npm\nrelease_age_hours=48\njob_id=\nhardening_complete=true\n' > "$OUT_FILE"
}

@test "record: one writable by group or others is ignored, and the scope is not narrowed" {
  # MEASURED on old main: a planted record made the verifier say "this job
  # hardened: npm" and report 1 gap instead of 5.
  harden ECOSYSTEMS=npm,pip -- --emit=plain >/dev/null
  forge_record; chmod 666 "$OUT_FILE"
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    FUNCTIONAL  hardening run record"*"writable by group or others"*"NOT read"* ]]
  [[ "$output" != *"this job hardened: npm"* ]]
}

@test "record: one owned by another user is ignored" {
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || skip "needs passwordless sudo"
  local other=nobody; id -u "$other" >/dev/null 2>&1 || skip "no 'nobody' user"
  harden ECOSYSTEMS=npm,pip -- --emit=plain >/dev/null
  forge_record; chmod 644 "$OUT_FILE"; sudo -n chown "$other" "$OUT_FILE"
  run verify_sourced --emit=plain
  [[ "$output" == *"hardening run record"*"belongs to uid"*"NOT read"* ]]
  [[ "$output" != *"this job hardened: npm"* ]]
}

@test "record: our own record still scopes the run (the check is not a blanket refusal)" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"this job hardened: npm"* ]]
  [[ "$output" != *"hardening run record"* ]]
}

@test "env file: one writable by others is reported as a GAP, not read and not compared" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  chmod 666 "$ENV_FILE"
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PRESENT     env layer propagation"*"NOT read. Do not source it"* ]]
  [ "$status" -eq 1 ]
}

# ---- VM#14: an N/A must not contradict itself, a launcher is not a wrapper ----

@test "wrapper N/A: the reason is the wrapper record, not the ecosystem list" {
  # Old main: "npm PATH wrapper  not deployed ... — not required here: this job
  # hardened: npm". npm WAS hardened; the wrapper only comes with intel.
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  local r; r=$(grep 'npm PATH wrapper' <<<"$output")
  [[ "$r" == *"N/A"*"BYDESIGN"* ]]
  [[ "$r" == *"the PATH wrappers this job deployed are: none"*"only with INTEL=sfw"* ]]
  [[ "$r" != *"this job hardened"* ]]
  # GitHub names the input, not the variable.
  run verify_sourced --emit=github
  [[ "$(grep 'npm PATH wrapper' <<<"$output")" == *"only with intel: sfw"* ]]
}

@test "describe_binary: a script nobody recognised is not called a wrapper" {
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  run verify -- --emit=plain
  # stub_bin writes a #!/bin/bash script, which describe_binary names by its
  # interpreter.
  [[ "$(grep 'bun PATH wrapper' <<<"$output")" == *"(a shell script that is not ours)"* ]]
  [[ "$output" != *"another wrapper script"* ]]
}

# ---- VM#14: remediation names the delivery path that is actually in use ----

@test "uv age gate: the freeze remedy on this surface is harden.sh, not the role's timer" {
  uv_reporting 2026-01-01T00:00:00Z
  harden ECOSYSTEMS=uv -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  local r; r=$(grep 'uv age gate' <<<"$output")
  [[ "$r" == *"Re-run action/harden.sh"* ]]
  [[ "$r" != *"Re-apply the role"* ]]
  [[ "$r" != *"systemctl status"* ]]
}

# ---- VM#10: yarn is probed, not grepped, and below 4.10 is a toolchain gap ----

# yarn_stub <version> <config-get npmMinimalAgeGate stdout> <its exit code>
yarn_stub() {
  stub_bin yarn 'case "$*" in
  --version) echo "'"$1"'" ;;
  "config get npmMinimalAgeGate") printf "%s\n" "'"$2"'"; exit '"$3"' ;;
  "config get enableScripts") echo false ;;
  *) echo STUB ;;
esac'
}

@test "yarn: below 4.10 the age gate is a toolchain GAP naming 4.10, not 'the NaN failure'" {
  # MEASURED (apt yarnpkg 4.1.0): `yarn config get npmMinimalAgeGate` prints a
  # usage error on stdout and exits 1. Old main: the CI row was a WEAK PRESENT
  # grep of our own file, and the role read the usage text as a NaN value.
  yarn_stub 4.1.0 'Usage Error: Couldn'"'"'t find a configuration settings named "npmMinimalAgeGate"' 1
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  local r; r=$(grep 'yarn age gate' <<<"$output")
  [[ "$r" == GAP*"yarn 4.1.0 has no npmMinimalAgeGate (needs Yarn 4.10.0)"* ]]
  [[ "$r" != *"NaN"* ]]
  [[ "$output" == *"OK     PARSED      yarn lifecycle scripts blocked"* ]]
  [[ "$output" != *"file contents only"*"yarnrc"* ]]
  [ "$status" -eq 1 ]
  # A gap no config can close: --fail-on=config does not fail on it.
  run verify_sourced --emit=plain --fail-on=config
  [ "$status" -eq 0 ]
}

@test "yarn: 4.10 reading \"2d\" as 2 minutes is WEAK, below the promised window" {
  yarn_stub 4.10.3 2 0
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$(grep 'yarn age gate' <<<"$output")" == WEAK*"npmMinimalAgeGate=2 minutes, below the 48h"* ]]
}

@test "yarn: a working gate is OK, so GAP is not the default answer" {
  yarn_stub 4.11.0 2880 0
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$(grep 'yarn age gate' <<<"$output")" == OK*"npmMinimalAgeGate=2880 minutes"* ]]
}

@test "yarn: classic is a GAP for the whole ecosystem" {
  yarn_stub 1.22.22 undefined 0
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$(grep 'yarn hardening' <<<"$output")" == GAP*"classic and ignores .yarnrc.yml"* ]]
}

@test "yarn: a yarn that prints no version is not blamed on its version" {
  # A corepack shim that cannot resolve a version prints nothing for --version.
  # The row used to read "yarn <unknown> has no npmMinimalAgeGate (needs Yarn
  # 4.10.0)", sending the reader to upgrade a yarn whose version nobody knew.
  yarn_stub '' 'Internal Error: cannot resolve a yarn version' 1
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  local r; r=$(grep 'yarn age gate' <<<"$output")
  [[ "$r" == GAP*"yarn could not report its version"* ]]
  [[ "$r" != *"needs Yarn 4.10.0"* ]]
  [[ "$r" != *"<unknown>"* ]]
}

# ---- verifier cluster (VM#7, #8, #11, #14; CMP 4.8) --------------------------

@test "pip: only-binary=:all: is WEAK, never OK - a path or URL sdist still runs setup.py" {
  # MEASURED on pip 22.0.2 to 26.0.1: only-binary refuses an sdist pip resolves
  # from an index or --find-links and builds one named by path. This row was OK.
  stub_bin pip3 "case \"\$*\" in
  --version) echo 'pip 24.0 from /x (python 3.12)' ;;
  'config list') echo \"install.only-binary=':all:'\" ;;
  *) echo STUB ;;
esac"
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"WEAK   PARSED      pip sdist execution blocked"* ]]
  [[ "$output" == *"NOT one named by path or URL"* ]]
  [[ "$output" != *"OK     PARSED      pip sdist execution blocked"* ]]
}

@test "report: the footer separates PRESENT-only WEAK rows from caveated ones" {
  # The footer said "N row(s) verified only as PRESENT" with N counting every
  # WEAK row, PARSED and FUNCTIONAL ones included.
  stub_bin pip3 "case \"\$*\" in
  --version) echo 'pip 24.0 from /x (python 3.12)' ;;
  'config list') echo \"install.only-binary=':all:'\" ;;
  *) echo STUB ;;
esac"
  harden ECOSYSTEMS=pip -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  weak_all=$(grep -cE '^WEAK ' <<<"$output" || true)
  weak_present=$(grep -cE '^WEAK +PRESENT ' <<<"$output" || true)
  [ "$weak_all" -gt "$weak_present" ]
  [[ "$output" == *"$weak_all row(s) WEAK — not counted as coverage: $weak_present verified only as PRESENT"* ]]
  [[ "$output" != *"$weak_all row(s) verified only as PRESENT"* ]]
}

@test "cargo lockfile writers: a tool limit, not a config gap, and the detail says the wrapper warns" {
  # cargo-cooldown has no verb for add/generate-lockfile/vendor/remove, so no
  # re-run routes them. Counted as "fixable by re-running", it made
  # --fail-on=config fail every job that installed cargo-cooldown.
  skip_if_root_stages_cooldown
  stub_bin cargo 'case "${1:-}" in --version|-v) echo "cargo 1.99.0";; *) echo "STUB:cargo ARGS=[$*]";; esac'
  mkdir -p "$TEST_HOME/.cargo/bin"
  printf '#!/bin/sh\necho "cargo-cooldown 0.3.5"\n' > "$TEST_HOME/.cargo/bin/cargo-cooldown"
  chmod +x "$TEST_HOME/.cargo/bin/cargo-cooldown"
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    FUNCTIONAL  cargo lockfile writers routed"* ]]
  [[ "$output" == *"writes Cargo.lock and is NOT age-gated' warning"* ]]
  [[ "$output" != *"this state is SILENT"* ]]
  [[ "$output" =~ [1-9][0-9]*\ no\ configuration\ can\ close ]]
  # The wrapper really does warn on a writer, with the backend present.
  run env -i PATH="${TEST_BIN}:${TEST_HOME}/.cargo/bin:${PATH}" HOME="$TEST_HOME" cargo add serde
  [[ "$output" == *"'cargo add' writes Cargo.lock and is NOT age-gated"* ]]
}

@test "doc pointers are absolute URLs pinned to the ref GitHub reports, never repo-relative paths" {
  bundler_age_stub 2.4.20 2
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"bundler publish-age gate"* ]]
  [[ "$output" == *"See https://github.com/echennells/supply-chain-hardening/blob/main/docs/composer-bundler-cooldown-by-distro.md"* ]]
  [[ "$output" != *"See docs/"* ]]
  run env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" SCV_DOCS_REF=v2.1.0 \
    bash -c "set -a; source '$ENV_FILE'; set +a; HARDENING_ENV_FILE='$ENV_FILE' bash '$VERIFY_SH' --emit=plain"
  [[ "$output" == *"/blob/v2.1.0/docs/composer-bundler-cooldown-by-distro.md"* ]]
  # A value that is not a git ref never reaches the URL.
  run env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" SCV_DOCS_REF='x y;$(id)' \
    bash -c "set -a; source '$ENV_FILE'; set +a; HARDENING_ENV_FILE='$ENV_FILE' bash '$VERIFY_SH' --emit=plain"
  [[ "$output" == *"/blob/main/docs/composer-bundler-cooldown-by-distro.md"* ]]
}

@test "npm exclude: the matcher block is byte-identical on both surfaces" {
  block() { sed -n '/^# >>> npm exclude scope$/,/^# <<< npm exclude scope$/p' "$1"; }
  role="${BATS_TEST_DIRNAME}/../../templates/verify.sh.j2"
  [ -n "$(block "$VERIFY_SH")" ]
  diff <(block "$role") <(block "$VERIFY_SH")
}

# Stage a project .npmrc whose exclude list is $1, and run the verifier there.
npm_exclude_run() {
  mkdir -p "$BATS_TEST_TMPDIR/np"
  printf '{"name":"np","version":"1.0.0"}\n' > "$BATS_TEST_TMPDIR/np/package.json"
  printf 'min-release-age-exclude[]=%s\n' "$1" > "$BATS_TEST_TMPDIR/np/.npmrc"
  cd "$BATS_TEST_TMPDIR/np"
  run verify_sourced --emit=plain
}

@test "npm exclude: patterns are judged by npm's own matcher, scoped and unscoped apart" {
  # MEASURED on npm 11.19.1, 99999-day window: '*' exempted lodash but not
  # @types/node; '**' exempted both; '@*/*' every scoped package. The row
  # compared entries with a literal '*': '*' read "every package", the rest WEAK.
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  npm_exclude_run 'lodash'
  [[ "$output" == *"does NOT implement min-release-age"* ]] && skip "this npm predates the gate"
  [ "$(npm config get min-release-age-exclude 2>/dev/null)" = lodash ] || skip "this npm predates min-release-age-exclude (11.17)"
  [[ "$output" == *"WEAK   PARSED      npm age gate"*"exempts: lodash"* ]]
  npm_exclude_run '**'
  [[ "$output" == *"GAP    PARSED      npm age gate"*"matches EVERY package name, scoped or not"* ]]
  npm_exclude_run '*'
  [[ "$output" == *"GAP    PARSED      npm age gate"*"matches every UNSCOPED package name"* ]]
  [[ "$output" != *"EVERY package name"* ]]
  npm_exclude_run '@*/*'
  [[ "$output" == *"GAP    PARSED      npm age gate"*"matches every SCOPED package name"* ]]
  # MEASURED, same npm: '??*' and '[!z]*' each exempted lodash and express.
  # They miss one sentinel each ('a', zz9-sch-sentinel), which is how they
  # used to read WEAK; a match on ANY made-up name is broad.
  npm_exclude_run '??*'
  [[ "$output" == *"GAP    PARSED      npm age gate"*"matches made-up package names"* ]]
  npm_exclude_run '[!z]*'
  [[ "$output" == *"GAP    PARSED      npm age gate"*"matches made-up package names"* ]]
  npm_exclude_run '@types/*'
  [[ "$output" == *"WEAK   PARSED      npm age gate"*"exempts: @types/*"* ]]
}

@test "go discovery: both preambles look where the shared body looks, before their go rows" {
  # The shared body's `discover go` runs after the preambles. Without the same
  # lookup in each preamble, a go at /usr/local/go/bin off this PATH printed
  # "go not installed" from the preamble and OK go rows from the shared body.
  block() { sed -n '/^# >>> go discovery$/,/^# <<< go discovery$/p' "$1"; }
  role="${BATS_TEST_DIRNAME}/../../templates/verify.sh.j2"
  probes="${BATS_TEST_DIRNAME}/../../files/verify-probes.sh"
  [ -n "$(block "$VERIFY_SH")" ]
  diff <(block "$role") <(block "$VERIFY_SH")
  shared=$(sed -n 's/^discover go[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*|| true$/\1/p' "$probes")
  mine=$(block "$VERIFY_SH" | sed -n 's/^[[:space:]]*for scv__gd in \(.*\); do$/\1/p')
  [ -n "$shared" ] && [ "$shared" = "$mine" ]
  # And the block sits before each preamble's own go rows (the last match: the
  # block's own `if ! have go` matches too).
  for f in "$role" "$VERIFY_SH"; do
    [ "$(grep -n '^# <<< go discovery$' "$f" | cut -d: -f1)" -lt "$(grep -nE '^if (! )?have go; then$' "$f" | tail -1 | cut -d: -f1)" ]
  done
}

@test "go discovery: a go off PATH is found by the preamble too, so the table agrees with itself" {
  # A stub go in a directory the shared list names cannot be planted from here
  # (/usr/local/go/bin needs root, $HOME/go/bin is under the test HOME), so use
  # the second: HOME is the test's.
  mkdir -p "$TEST_HOME/go/bin"
  cat > "$TEST_HOME/go/bin/go" <<'GO'
#!/bin/sh
case "$1 $2" in
  "env GOSUMDB") echo sum.golang.org ;;
  "env GOTOOLCHAIN") echo local ;;
  "env GOVERSION") echo go1.24.2 ;;
  "env GOFLAGS") echo -mod=readonly ;;
  "version "*) echo "go version go1.24.2 linux/amd64" ;;
  env*) echo "" ;;
  *) exit 0 ;;
esac
GO
  chmod +x "$TEST_HOME/go/bin/go"
  run env -i PATH="/usr/bin:/bin" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" bash "$VERIFY_SH" --emit=plain
  [[ "$output" == *"go checksum verification"* ]]
  # Not a substring test: "cargo not installed" contains "go not installed".
  ! grep -qE '^N/A +ABSENT +go +go not installed' <<<"$output"
  grep -qE '^[A-Z/]+ +[A-Z-]+ +go settings persisted' <<<"$output"
}

@test "go: 'settings persisted' is OK from go env -w alone, and a GAP when GOTOOLCHAIN=local did not persist" {
  # The probe used to be GOFLAGS=-mod=readonly, which harden.sh no longer writes
  # (it made go ignore vendor/). GOTOOLCHAIN=local is the persisted setting that
  # differs from go's default, so it is what tells "persisted" from "not".
  stub_go_env
  harden ECOSYSTEMS=go -- --emit=plain >/dev/null
  run verify -- --emit=plain
  [[ "$output" == *"go settings persisted"*"GOTOOLCHAIN=local survives with the env layer stripped"* ]]

  filter_file "$TEST_HOME/.config/go/env" sed '/^GOTOOLCHAIN=/d'
  run verify -- --emit=plain
  [[ "$output" == *"GAP"*"go settings persisted"*"GOTOOLCHAIN='<unset>'"* ]]
}

@test "go: before go1.21 'settings persisted' is N/A, not a GAP, and verify passes --fail-on=config" {
  # go1.18-go1.20 have no GOTOOLCHAIN (see stub_go_env), and every other value
  # harden.sh persists equals go's default, so there is nothing to tell
  # persisted from unset. Probing GOTOOLCHAIN anyway printed "GOTOOLCHAIN='<unset>',
  # so a go.mod can make go download and run another toolchain", which go1.20
  # cannot do, and failed the step under --fail-on=any and --fail-on=config.
  # MEASURED in golang:1.18/1.19/1.20 images with the env file sourced.
  stub_go_env go1.20.14
  run harden ECOSYSTEMS=go -- --emit=plain
  [ "$status" -eq 0 ]
  # FIXTURE CONTROL: the stub refused GOTOOLCHAIN as go1.20 does, so nothing
  # persisted it, while the keys go1.20 knows were persisted.
  [ "$(grep -c '^GOTOOLCHAIN=' "$TEST_HOME/.config/go/env")" = 0 ]
  grep -qx "GOSUMDB=sum.golang.org" "$TEST_HOME/.config/go/env"

  for fo in config any; do
    run verify_sourced --emit=plain "--fail-on=$fo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"N/A"*"go settings persisted"*"go1.20 predates GOTOOLCHAIN (go1.21)"* ]]
    [ "$(grep -c '^GAP' <<<"$output")" = 0 ]
  done

  # The version gate is go's, not the stub's file: go1.21 knows GOTOOLCHAIN
  # and is probed as before.
  stub_go_env go1.21.13
  harden ECOSYSTEMS=go -- --emit=plain >/dev/null
  run verify_sourced --emit=plain --fail-on=config
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"*"go settings persisted"*"GOTOOLCHAIN=local survives with the env layer stripped"* ]]
}

# A directory holding every command on this PATH except timeout and gtimeout:
# the PATH of a stock Mac, which has neither (gtimeout comes with Homebrew's
# coreutils). Prints its path.
path_without_timeout() {
  local d="${BATS_TEST_TMPDIR}/notimeout" p f b
  mkdir -p "$d"
  local IFS=:
  for p in $PATH; do
    [ -d "$p" ] || continue
    for f in "$p"/*; do
      b=${f##*/}
      case "$b" in timeout|gtimeout) continue ;; esac
      [ -x "$f" ] && [ ! -e "$d/$b" ] && ln -s "$f" "$d/$b"
    done
  done
  echo "$d"
}

@test "with no timeout or gtimeout on PATH (stock macOS) the wrapper probe still runs" {
  # The probe asks a wrapper whether it ran (SCH_WRAPPER_PROBE) instead of
  # guessing from PATH position. Without timeout(1) it has to run through
  # run_bounded's own fallback, and the variable set on the call has to reach
  # the wrapper through it, or this row falls back to position evidence.
  stub_bin bun 'case "${1:-}" in --version) echo "1.3.4";; *) echo "STUB:bun ARGS=[$*]";; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  local nt
  nt=$(path_without_timeout)
  run env -i PATH="$TEST_BIN:$nt" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    bash -c 'if command -v timeout || command -v gtimeout; then echo "a timeout is still visible"; exit 99; fi
             set -a; . "$1"; set +a; HARDENING_ENV_FILE="$1" bash "$2" --emit=plain' _ "$ENV_FILE" "$VERIFY_SH"
  [ "$status" -ne 99 ] || { echo "$output"; false; }
  [[ "$output" == *"OK     FUNCTIONAL  bun PATH wrapper"*"observed running when bun was invoked"* ]] \
    || { echo "$output" | grep 'bun PATH wrapper'; false; }
}

@test "run_bounded stops a hanging command where neither timeout nor gtimeout exists" {
  # MEASURED at 6c77f4e with both hidden: a bun that hung on --version kept
  # verify.sh running until it was killed from outside after 60 s; every probe
  # fell back to an unbounded run. /bin/bash is bash 3.2 on the macOS job.
  local nt blk
  nt=$(path_without_timeout)
  blk="${BATS_TEST_TMPDIR}/rb.sh"
  sed -n '/^# >>> run_bounded$/,/^# <<< run_bounded$/p' "$VERIFY_SH" > "$blk"
  [ -s "$blk" ]
  run env -i PATH="$nt" /bin/bash -c '
    . "$1"
    command -v timeout >/dev/null || command -v gtimeout >/dev/null && { echo "a timeout is still visible"; exit 99; }
    t0=$SECONDS; run_bounded 2 sleep 30; echo "hang rc=$? secs=$((SECONDS - t0))"
    t0=$SECONDS; out=$(run_bounded 2 sh -c "sh -c \"sleep 30\" & sleep 30" 2>&1); echo "child rc=$? secs=$((SECONDS - t0))"
    run_bounded 5 sh -c "exit 7"; echo "fail rc=$?"
    echo "env=[$(FOO=bar run_bounded 5 sh -c "echo \$FOO")] after=[${FOO-unset}]"
    echo "capture=[$(run_bounded 5 echo hi)]"' _ "$blk"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" =~ hang\ rc=124\ secs=([0-9]+) ]]
  [ "${BASH_REMATCH[1]}" -lt 10 ]
  # A child left holding the $( ) open is stopped too, as timeout(1) stops
  # its whole process group.
  [[ "$output" =~ child\ rc=124\ secs=([0-9]+) ]]
  [ "${BASH_REMATCH[1]}" -lt 10 ]
  [[ "$output" == *"fail rc=7"* ]]
  [[ "$output" == *"env=[bar] after=[unset]"* ]]
  [[ "$output" == *"capture=[hi]"* ]]
}

@test "run_bounded is one block, the same in harden.sh, verify.sh and the role's verifier" {
  # Both verifiers run their wrapper rows before the shared probe body is
  # sourced, so each preamble carries the block (as with go discovery), and the
  # shared body uses it. A copy that drifts is a bound that differs by surface.
  block() { sed -n '/^# >>> run_bounded$/,/^# <<< run_bounded$/p' "$1"; }
  local role="${BATS_TEST_DIRNAME}/../../templates/verify.sh.j2"
  [ -n "$(block "$VERIFY_SH")" ]
  diff <(block "$VERIFY_SH") <(block "$HARDEN_SH")
  diff <(block "$VERIFY_SH") <(block "$role")
  # And nothing calls timeout(1) directly any more, outside that block.
  local f probes="${BATS_TEST_DIRNAME}/../../files/verify-probes.sh"
  for f in "$VERIFY_SH" "$HARDEN_SH" "$role" "$probes"; do
    run bash -c 'sed "/^# >>> run_bounded$/,/^# <<< run_bounded$/d" "$1" | grep -nE "(^|[;&|(]|then|else)[[:space:]]*([A-Z_]+=[^ ]* )*g?timeout [0-9]"' _ "$f"
    [ "$status" -ne 0 ] || { echo "$f: $output"; false; }
  done
}

@test "the shipped scripts parse under bash 3.2, the /bin/bash macOS runs them with" {
  # MEASURED: files/verify-probes.sh had a `case ... in /*)` inside `$( ... )`,
  # which bash 3.2 cannot parse ("syntax error near unexpected token ;;"), so on
  # a Mac whose bash is /bin/bash the verifier died at the NuGet section. It was
  # there since v2.0.0; nothing parsed the scripts with the bash macOS ships.
  # Only the macOS job has a bash 3 to check with.
  /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]' 2>/dev/null \
    || skip "/bin/bash is bash 4 or later here; this runs on the macOS job"
  local f
  for f in "$HARDEN_SH" "$VERIFY_SH" "${BATS_TEST_DIRNAME}/../../files/verify-probes.sh"; do
    run /bin/bash -n "$f"
    [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
  done
}

# ---- pnpm repo config override ------------------------------------------------
#
# A project's pnpm-workspace.yaml outranks the global config.yaml harden.sh
# writes (MEASURED on pnpm 10.34.9 to 12.21.0), and the action exports no
# pnpm_config_* variable, so in CI the workspace file is in effect. The row
# reads the file: pnpm 10 and 11 run a project's pnpmfile and fetch its
# configDependencies for any command in it, `pnpm config get` included.

# pnpm_stub <version>: answers from / and logs every directory it is run in.
pnpm_stub() {
  stub_bin pnpm 'echo "$PWD :: $*" >> "'"$BATS_TEST_TMPDIR"'/pnpm-calls"
case "$*" in
  --version) echo "'"$1"'" ;;
  "config get minimumReleaseAge"|"config get minimum-release-age") echo 2880 ;;
  "config get minimumReleaseAgeStrict") echo true ;;
  *) echo STUB ;;
esac'
}
# pn_project <pnpm-workspace.yaml content>: a workspace at $PNP (set in setup,
# because pn_verdict runs in a subshell), verified from a package below it, the
# way pnpm finds the file.
pn_project() {
  rm -rf "$PNP"; mkdir -p "$PNP/packages/a"
  printf '{"name":"p","version":"1.0.0","private":true}\n' > "$PNP/package.json"
  [ -z "${1:-}" ] || printf '%s\n' "$1" > "$PNP/pnpm-workspace.yaml"
}
verify_in() { local d="$1"; shift; ( cd "$d" && verify_sourced "$@" ); }
pn_row() { grep 'pnpm repo config override' <<<"$output"; }
pn_verdict() { # <yaml> -> the row, verified from $PNP/packages/a
  pn_project "$1"
  run verify_in "$PNP/packages/a" --emit=plain
  pn_row
}

@test "pnpm repo config override: a workspace 0 is a GAP, a shorter window WEAK, a longer one OK" {
  pnpm_stub 11.28.13
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  local r
  r=$(pn_verdict 'minimumReleaseAge: 0')
  [[ "$r" == "GAP    PRESENT     pnpm repo config override"*"minimumReleaseAge 0 in $PNP/pnpm-workspace.yaml switches the age gate off"* ]] || { echo "$r"; return 1; }
  r=$(pn_verdict "packages: ['packages/*']
minimumReleaseAge: '600'   # ten hours")
  [[ "$r" == WEAK*"minimumReleaseAge 600 in $PNP/pnpm-workspace.yaml is below the 48h (2880 minutes) promised here"* ]] || { echo "$r"; return 1; }
  r=$(pn_verdict 'minimumReleaseAge: 4320')
  [[ "$r" == OK*"minimumReleaseAge 4320"*"is at least the 48h"* ]] || { echo "$r"; return 1; }
  # A value pnpm 10 and 11 read as no gate.
  for v in null false true "''" -1; do
    r=$(pn_verdict "minimumReleaseAge: $v")
    [[ "$r" == GAP*"switches the age gate off"* ]] || { echo "$v: $r"; return 1; }
  done
  # A value that is no number at all is not judged either way.
  r=$(pn_verdict "minimumReleaseAge: '1d'")
  [[ "$r" == WEAK*"not a whole number of minutes"* ]] || { echo "$r"; return 1; }
}

@test "pnpm repo config override: an exclude list is WEAK naming its entries; '*' or '**' is a GAP" {
  pnpm_stub 11.28.13
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  local r
  r=$(pn_verdict "minimumReleaseAgeExclude:
  - left-pad
  - '@myorg/*'")
  [[ "$r" == WEAK*"exempts left-pad, @myorg/* from the age gate"* ]] || { echo "$r"; return 1; }
  r=$(pn_verdict "minimumReleaseAgeExclude: ['*', '!typescript']")
  [[ "$r" == GAP*"lists '*', which exempts every package"* ]] || { echo "$r"; return 1; }
  r=$(pn_verdict "minimumReleaseAgeExclude: ['**']")
  [[ "$r" == GAP*"lists '**'"* ]] || { echo "$r"; return 1; }
  r=$(pn_verdict "minimumReleaseAgeExclude: []
minimumReleaseAge: 2880")
  [[ "$r" == OK* ]] || { echo "$r"; return 1; }
}

@test "pnpm repo config override: a pnpm_config_* variable in this environment hides the workspace value (WEAK, not OK, not GAP)" {
  # The role exports both on a host; a context without them (a systemd unit, a
  # container CMD) uses the project's value, so neither OK nor GAP is true.
  pnpm_stub 11.28.13
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  local r
  # FIXTURE CONTROL: without the variable the same file is a GAP.
  r=$(pn_verdict 'minimumReleaseAge: 0')
  [[ "$r" == GAP* ]] || { echo "$r"; return 1; }
  echo 'export pnpm_config_minimum_release_age=2880' >> "$ENV_FILE"
  r=$(pn_verdict 'minimumReleaseAge: 0')
  [[ "$r" == WEAK*"pnpm_config_minimum_release_age=2880 in this environment outranks it"*"an env variable is what hides the project's weaker setting"*"systemd unit"* ]] || { echo "$r"; return 1; }
  echo "export pnpm_config_minimum_release_age_exclude='[]'" >> "$ENV_FILE"
  r=$(pn_verdict "minimumReleaseAgeExclude: [left-pad]")
  [[ "$r" == WEAK*"exempts left-pad"*"pnpm_config_minimum_release_age_exclude=[] in this environment replaces that list"* ]] || { echo "$r"; return 1; }
  # The upper-case name is read from pnpm 11.0.6, so it hides nothing on 11.0.0.
  filter_file "$ENV_FILE" sed 's/^export pnpm_config_minimum_release_age=/export PNPM_CONFIG_MINIMUM_RELEASE_AGE=/'
  pnpm_stub 11.0.0
  r=$(pn_verdict 'minimumReleaseAge: 0')
  [[ "$r" == GAP* ]] || { echo "$r"; return 1; }
  pnpm_stub 11.0.9
  r=$(pn_verdict 'minimumReleaseAge: 0')
  [[ "$r" == WEAK*"PNPM_CONFIG_MINIMUM_RELEASE_AGE=2880 in this environment outranks it"* ]] || { echo "$r"; return 1; }
}

@test "pnpm repo config override: pnpm is asked from /, never inside the project (its pnpmfile would run)" {
  # MEASURED on pnpm 10.34.9, 11.0.0 and 11.28.13: `pnpm config get` in a
  # project loaded its .pnpmfile.cjs and fetched its configDependencies.
  pnpm_stub 11.28.13
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  pn_project "minimumReleaseAge: 600
pnpmfile: hooks.cjs
configDependencies:
  is-number: '7.0.0+sha512-AAAA'"
  printf 'require("fs").writeFileSync(%s, "x")\n' "'$BATS_TEST_TMPDIR/pnpmfile-ran'" > "$PNP/hooks.cjs"
  printf '{"name":"p","version":"1.0.0","packageManager":"pnpm@9.15.9"}\n' > "$PNP/package.json"
  rm -f "$BATS_TEST_TMPDIR/pnpm-calls"
  run verify_in "$PNP/packages/a" --emit=plain
  [[ "$(pn_row)" == WEAK*"minimumReleaseAge 600"* ]] || { pn_row; return 1; }
  # The stub was run (the row asked it something) ...
  [ -s "$BATS_TEST_TMPDIR/pnpm-calls" ]
  # ... and never from the project or below it.
  # Both spellings of the project path: physical (PNP) and, on macOS, the /var one.
  ! grep -q -e "^$PNP" -e "^$BATS_TEST_TMPDIR/proj" "$BATS_TEST_TMPDIR/pnpm-calls" || { cat "$BATS_TEST_TMPDIR/pnpm-calls"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/pnpmfile-ran" ]
}

@test "pnpm repo config override: without PyYAML the plain-key reader reaches the same verdicts, and refuses YAML it does not follow" {
  pnpm_stub 11.28.13
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  local real r; real=$(command -v python3) || skip "no python3"
  stub_bin python3 "case \"\$*\" in *'import yaml'*) exit 3 ;; esac; exec '$real' \"\$@\""
  r=$(pn_verdict "packages:
  - 'packages/*'
minimumReleaseAge: 0   # off")
  [[ "$r" == GAP*"switches the age gate off"* ]] || { echo "$r"; return 1; }
  r=$(pn_verdict "minimumReleaseAgeExclude:
  - left-pad   # ours
  - \"@myorg/*\"")
  [[ "$r" == WEAK*"exempts left-pad, @myorg/*"* ]] || { echo "$r"; return 1; }
  # A flow-style document, a merge key and a repeated key are refused, not guessed.
  for y in '{minimumReleaseAge: 0}' $'base: &b\n  minimumReleaseAge: 0\n<<: *b' $'minimumReleaseAge: 5\nminimumReleaseAge: 0'; do
    r=$(pn_verdict "$y")
    [[ "$r" == WEAK*"could not be read by a plain-key reader"*"was not judged"* ]] || { echo "$y: $r"; return 1; }
  done
}

# The file is the checkout's, and pnpm follows every spelling YAML allows. MEASURED
# to set the gate on pnpm 11.29.0: all of these but the last-but-three (`? key`,
# measured on Yarn) and the spaced colon. 10.34.9 refused the tagged key. Read by whichever reader, none may come out as
# "sets neither" or OK.
pn_forms() {
  printf '%s\n' '{minimumReleaseAge: 0}' '--- {minimumReleaseAge: 0}' '  minimumReleaseAge: 0' \
    '"minimumRelease\\x41ge": 0' '\357\273\277minimumReleaseAge: 0' '# c\rminimumReleaseAge: 0\r' \
    '!!str minimumReleaseAge: 0' '"minimumReleaseAge" : 0' 'x: &k minimumReleaseAge\n*k : 0' \
    '? minimumReleaseAge\n: 0' 'x: &a\n  minimumReleaseAge: 0\n<<: *a' \
    'minimumReleaseAge: 0\nfoo: "\nminimumReleaseAge: 9999\n"' \
    'minimumReleaseAge: 0\nfoo: {\nminimumReleaseAge: 9999\n}'
}
pn_forms_check() {
  local y r n=0
  while IFS= read -r y; do
    pn_project ""
    printf -- "$y\n" > "$PNP/pnpm-workspace.yaml"
    run verify_in "$PNP/packages/a" --emit=plain
    r=$(pn_row)
    case "$r" in
      GAP*"switches the age gate off"*|WEAK*"could not be read"*"was not judged"*) n=$((n + 1)) ;;
      *) echo "$1, $y: $r"; return 1 ;;
    esac
  done < <(pn_forms)
  [ "$n" -eq 13 ] || { echo "$1: $n forms"; return 1; }
}

@test "pnpm repo config override: no spelling of the key reads as nothing set, with PyYAML or without" {
  pnpm_stub 11.28.13
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  local real r; real=$(command -v python3) || skip "no python3"
  pn_forms_check "as installed"
  # A line break to YAML 1.1 only: with PyYAML a comment hid the key pnpm used.
  r=$(pn_verdict $'minimumReleaseAge: 0\n# c\302\205minimumReleaseAge: 9999')
  [[ "$r" == GAP* || "$r" == WEAK*"could not be read"* ]] || { echo "NEL: $r"; return 1; }
  stub_bin python3 "case \"\$*\" in *'import yaml'*) exit 3 ;; esac; exec '$real' \"\$@\""
  pn_forms_check "without PyYAML"
  # What an ordinary workspace file holds is still read, not refused.
  r=$(pn_verdict $'---\n# pnpm\npackages:\n- "packages/*"\ncatalogs:\n  react18:\n    react: ^18.0.0\nonlyBuiltDependencies: [esbuild]\n"linkWorkspacePackages": true')
  [[ "$r" == "N/A"*"sets neither"* ]] || { echo "ordinary: $r"; return 1; }
}

@test "pnpm repo config override: pnpm 10's project .npmrc, quoted, escaped, after a byte-order mark or a lone CR" {
  pnpm_stub 10.34.9
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  local y
  while IFS= read -r y; do
    pn_project ""
    printf -- "$y" > "$PNP/.npmrc"
    run verify_in "$PNP" --emit=plain
    [[ "$(pn_row)" == GAP*"minimum-release-age 0 in $PNP/.npmrc switches the age gate off"* || "$(pn_row)" == WEAK*"could not be read"* ]] \
      || { echo "$y: $(pn_row)"; return 1; }
  done <<'FORMS'
minimum-release-age=0\n
"minimum-release-age"=0\n
"minimum\\u002drelease-age"=0\n
# c\rminimum-release-age=0\r
\357\273\277minimum-release-age=0\n
FORMS
  pn_project ""
  printf '# minimum-release-age=0\n//r.example/:_authToken=${T}\n' > "$PNP/.npmrc"
  run verify_in "$PNP" --emit=plain
  [[ "$(pn_row)" == "N/A"* ]] || { pn_row; return 1; }
}

@test "pnpm repo config override: N/A with no workspace file, with no age keys, from /, and on a pnpm with no age gate; a path with a space" {
  pnpm_stub 11.28.13
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  local r
  pn_project ""
  run verify_in "$PNP/packages/a" --emit=plain
  [[ "$(pn_row)" == "N/A"*"no pnpm-workspace.yaml at or above $PNP/packages/a"* ]] || { pn_row; return 1; }
  r=$(pn_verdict "packages: ['packages/*']")
  [[ "$r" == "N/A"*"$PNP/pnpm-workspace.yaml sets neither minimumReleaseAge nor minimumReleaseAgeExclude"* ]] || { echo "$r"; return 1; }
  # A path with a space in it is one path.
  PNP="$PNT/my proj"
  r=$(pn_verdict 'minimumReleaseAge: 0')
  [[ "$r" == GAP*"minimumReleaseAge 0 in $PNP/pnpm-workspace.yaml switches the age gate off"* ]] || { echo "$r"; return 1; }
  PNP="$PNT/proj"
  run verify_in / --emit=plain
  [[ "$(pn_row)" == "N/A"*"ran from /"* ]] || { pn_row; return 1; }
  pnpm_stub 10.15.1
  r=$(pn_verdict 'minimumReleaseAge: 0')
  [[ "$r" == "N/A"*"pnpm 10.15.1 has no minimumReleaseAge (pnpm 10.16.0)"* ]] || { echo "$r"; return 1; }
}

@test "pnpm repo config override: pnpm 12 refuses false and 0.5 (WEAK, nothing installs); strict false is WEAK on 11+, not on 10; pnpm 10 reads a project .npmrc" {
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  local r
  pnpm_stub 12.21.0
  r=$(pn_verdict 'minimumReleaseAge: false')
  [[ "$r" == WEAK*"which pnpm 12.21.0 refuses (ERR_PNPM_INVALID_SETTING), so nothing installs here"* ]] || { echo "$r"; return 1; }
  r=$(pn_verdict 'minimumReleaseAge: 0.5')
  [[ "$r" == WEAK*"refuses (ERR_PNPM_INVALID_SETTING)"* ]] || { echo "$r"; return 1; }
  r=$(pn_verdict 'minimumReleaseAge: null')
  [[ "$r" == OK*"which pnpm 12.21.0 ignores"* ]] || { echo "$r"; return 1; }
  r=$(pn_verdict 'minimumReleaseAgeStrict: false')
  [[ "$r" == WEAK*"minimumReleaseAgeStrict false"*"lets a release younger than the window install"* ]] || { echo "$r"; return 1; }
  pnpm_stub 10.34.9
  r=$(pn_verdict 'minimumReleaseAgeStrict: false')
  [[ "$r" == "N/A"* ]] || { echo "$r"; return 1; }
  pn_project ""
  printf 'minimum-release-age=0\n' > "$PNP/.npmrc"
  run verify_in "$PNP" --emit=plain
  [[ "$(pn_row)" == GAP*"minimum-release-age 0 in $PNP/.npmrc switches the age gate off"* ]] || { pn_row; return 1; }
  # pnpm 11 no longer reads a project .npmrc for this (MEASURED).
  pnpm_stub 11.28.13
  run verify_in "$PNP" --emit=plain
  [[ "$(pn_row)" == "N/A"*"no pnpm-workspace.yaml"* ]] || { pn_row; return 1; }
}

# ---- no project code ----------------------------------------------------------
#
# The verifier is run from inside checkouts nobody reviewed (AGENTS.md says to),
# so it must not run code a checkout supplies, nor code a directory other
# accounts can write supplies. See "no project code" in both preambles.

# A private directory: under the real HOME, which is outside /tmp and owned by
# whoever runs bats. Removed after each test.
scv_priv() {
  SCV_PRIV=$(mktemp -d "$HOME/.scv-test.XXXXXX") || return 1
  SCV_PRIV=$(cd "$SCV_PRIV" && pwd -P)
}
teardown() {
  [ -n "${SCV_PRIV:-}" ] && rm -rf "$SCV_PRIV"
  return 0
}
npc_block() { sed -n '/^# >>> no project code$/,/^# <<< no project code$/p' "$1"; }

@test "no project code: the scratch and corepack block is byte-identical on both surfaces" {
  local role="${BATS_TEST_DIRNAME}/../../templates/verify.sh.j2"
  [ -n "$(npc_block "$VERIFY_SH")" ]
  diff <(npc_block "$role") <(npc_block "$VERIFY_SH")
}

# npc_pick [VAR=value ...] -- <cwd>: source the block the way the verifier does
# and print the scratch directory it chose (empty: none), then whether it still
# exists once that shell has exited.
npc_pick() {
  local -a envs=(); local cwd
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; cwd=$2
  local blk; blk=$(npc_block "$VERIFY_SH")
  ( cd "$cwd" && env -i PATH="$PATH" "${envs[@]}" bash -c "$blk"$'\n''printf "scratch=%s tmpdir=%s corepack=%s mktemp=%s\n" "$SCV_SCRATCH" "$TMPDIR" "$COREPACK_ENV_FILE" "$(mktemp -d)"' )
}

@test "no project code: probe projects go in a scratch dir only root and this account can write, never under /tmp or the checkout" {
  scv_priv || skip "cannot make a directory under HOME"
  # ww stands in for /tmp: world-writable with the sticky bit. HOME="$ww/h" is a
  # home with no private base above it (BATS_TEST_TMPDIR itself is private on
  # macOS, where it is under the per-user TMPDIR).
  local ww="$BATS_TEST_TMPDIR/ww" out d dar darp none
  mkdir -p "$ww/sub" "$ww/h" "$SCV_PRIV/home" "$SCV_PRIV/proj/tmp"
  chmod 1777 "$ww"
  # macOS has a per-user temp dir (getconf DARWIN_USER_TEMP_DIR, 0700 under
  # root-owned parents), the last candidate there, so a Mac never runs out of
  # private bases: where this test expects none on Linux, a Mac picks that.
  dar=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || dar=""
  if [ -n "$dar" ]; then
    darp=$(cd -P "$dar" && pwd -P); none="scratch=$darp/scv."
    out=$(npc_pick TMPDIR="$dar" HOME="$ww/h" -- /)
    [[ "$out" == "scratch=$darp/scv."*" mktemp=$darp/scv."* ]] || { echo "the stock macOS TMPDIR was not taken: $out"; return 1; }
  else
    none="scratch= "
  fi
  # $HOME and everything above it must be private, or this host cannot run the test.
  out=$(npc_pick HOME="$SCV_PRIV/home" RUNNER_TEMP="$SCV_PRIV" -- /)
  [[ "$out" == "scratch=$SCV_PRIV/scv."* ]] || skip "the real HOME has a directory above it others can write: $out"
  # A world-writable TMPDIR is passed over for RUNNER_TEMP; TMPDIR then points
  # into the scratch dir, COREPACK_ENV_FILE is 0, and the dir is gone at exit.
  out=$(npc_pick TMPDIR="$ww/sub" HOME="$ww/h" RUNNER_TEMP="$SCV_PRIV" -- /)
  # mktemp names the scratch dir too: Apple's mktemp ignores TMPDIR.
  [[ "$out" == "scratch=$SCV_PRIV/scv."*" tmpdir=$SCV_PRIV/scv."*" corepack=0 mktemp=$SCV_PRIV/scv."*"/tmp."* ]] || { echo "$out"; return 1; }
  d=${out#scratch=}; d=${d%% *}
  [ ! -e "$d" ]
  # A base inside the working directory is not used: the checkout's files
  # would sit above the probes. The per-user cache is next.
  out=$(npc_pick TMPDIR="$ww/sub" RUNNER_TEMP="$SCV_PRIV/proj/tmp" HOME="$SCV_PRIV/home" -- "$SCV_PRIV/proj")
  [[ "$out" == "scratch=$SCV_PRIV/home/.cache/supply-chain-hardening/scv."* ]] || { echo "$out"; return 1; }
  [ "$(ls -ld "$SCV_PRIV/home/.cache/supply-chain-hardening" | cut -c1-10)" = drwx------ ]
  # Group-writable is accepted (a grant somebody made); owned by another
  # account, or world-writable with or without the sticky bit, is not.
  mkdir -p "$SCV_PRIV/g" "$SCV_PRIV/o"; chmod 0775 "$SCV_PRIV/g"; chmod 0777 "$SCV_PRIV/o"
  out=$(npc_pick TMPDIR="$SCV_PRIV/g" -- /)
  [[ "$out" == "scratch=$SCV_PRIV/g/scv."* ]] || { echo "$out"; return 1; }
  out=$(npc_pick TMPDIR="$SCV_PRIV/o" HOME="$ww/h" -- /)
  [[ "$out" == "$none"* ]] || { echo "$out"; return 1; }
  if [ "$(id -u)" != 0 ] && sudo -n chown 65534 "$SCV_PRIV/g" 2>/dev/null; then
    out=$(npc_pick TMPDIR="$SCV_PRIV/g" HOME="$ww/h" -- /)
    sudo -n chown "$(id -u)" "$SCV_PRIV/g"
    [[ "$out" == "$none"* ]] || { echo "$out"; return 1; }
  fi
  # The macOS per-user temp dir, stood in for here so every platform runs the
  # branch: a getconf that answers DARWIN_USER_TEMP_DIR (with the trailing slash
  # macOS prints) puts the scratch dir there, without a warning.
  mkdir -p "$SCV_PRIV/darwin" "$BATS_TEST_TMPDIR/fakeconf"
  printf '#!/bin/sh\n[ "$1" = DARWIN_USER_TEMP_DIR ] && echo "%s/darwin/"\n' "$SCV_PRIV" > "$BATS_TEST_TMPDIR/fakeconf/getconf"
  chmod +x "$BATS_TEST_TMPDIR/fakeconf/getconf"
  run --separate-stderr npc_pick PATH="$BATS_TEST_TMPDIR/fakeconf:$PATH" TMPDIR="$ww/sub" HOME="$ww/h" -- /
  [[ "$output" == "scratch=$SCV_PRIV/darwin/scv."*" mktemp=$SCV_PRIV/darwin/scv."* ]] || { echo "$output"; return 1; }
  [[ "$stderr" != *"found no directory"* ]] || { echo "$stderr"; return 1; }
  # Nothing private: the probes stay under TMPDIR, and stderr says so. On a Mac
  # the per-user temp dir is taken instead, without a warning.
  run --separate-stderr npc_pick TMPDIR="$ww/sub" HOME="$ww/h" -- /
  if [ -n "$dar" ]; then
    [[ "$output" == "scratch=$darp/scv."* ]] || { echo "$output"; return 1; }
    [[ "$stderr" != *"found no directory"* ]] || { echo "$stderr"; return 1; }
  else
    [[ "$output" == "scratch= tmpdir=$ww/sub corepack=0 mktemp=$ww/sub/tmp."* ]] || { echo "$output"; return 1; }
    [[ "$stderr" == *"warning: found no directory for the probes' throwaway projects"*"Point TMPDIR at a directory of your own"* ]] || { echo "$stderr"; return 1; }
  fi
}

# yarn_rc_stub <version> [gate]: a yarn that answers from / and, like the real
# one, runs a yarnPath it finds in a .yarnrc.yml at or above the directory it is
# run in (MEASURED on 1.22.22 and 4.1.0 to 4.19.0). Every call is logged with
# the directory it ran in.
yarn_rc_stub() {
  stub_bin yarn 'echo "$PWD :: $*" >> "'"$BATS_TEST_TMPDIR"'/yarn-calls"
d=$PWD
while [ -n "$d" ]; do
  if [ -f "$d/.yarnrc.yml" ]; then
    p=$(sed -n "s/^yarnPath:[[:space:]]*//p" "$d/.yarnrc.yml" | head -1)
    if [ -n "$p" ]; then case "$p" in /*) ;; *) p="$d/$p" ;; esac; exec node "$p" "$@"; fi
  fi
  [ "$d" = / ] && break; d=${d%/*}; [ -n "$d" ] || d=/
done
case "$*" in
  --version) echo "'"$1"'" ;;
  "config get npmMinimalAgeGate") echo "'"${2:-2880}"'" ;;
  "config get enableScripts") echo false ;;
  *) echo STUB ;;
esac'
}
# A yarn release as a project commits it: the version string the bundles carry,
# and a marker written if anything runs it.
yarn_release() { # <file> <version>
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env node\n/* yarn */ var y = {name:"@yarnpkg/cli",version:"%s",license:"BSD-2-Clause"};\nrequire("fs").writeFileSync("%s", "ran"); console.log("%s");\n' \
    "$2" "$BATS_TEST_TMPDIR/markers/yarn-release-ran" "$2" > "$1"
}
YNP() { printf '%s' "$PNT/yproj"; }
y_project() { # <.yarnrc.yml content>, verified from a package below it
  rm -rf "$(YNP)"; mkdir -p "$(YNP)/packages/a" "$BATS_TEST_TMPDIR/markers"
  printf '{"name":"p","version":"1.0.0","private":true}\n' > "$(YNP)/package.json"
  [ -z "${1:-}" ] || printf '%s\n' "$1" > "$(YNP)/.yarnrc.yml"
}
# The row itself, not the host rows that point at it.
y_row() { grep -E '^[A-Z/]+ +[A-Z-]+ +yarn repo config override ' <<<"$output"; }
y_verdict() { y_project "$1"; run verify_in "$(YNP)/packages/a" --emit=plain; y_row; }

@test "yarn repo config override: a project 0 or enableScripts true is a GAP, a shorter window or named exemptions WEAK, a longer one OK" {
  yarn_rc_stub 4.19.0
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  local r
  r=$(y_verdict 'npmMinimalAgeGate: 0')
  [[ "$r" == "GAP    PRESENT     yarn repo config override"*"npmMinimalAgeGate 0 in $(YNP)/.yarnrc.yml switches the age gate off"* ]] || { echo "$r"; return 1; }
  r=$(y_verdict 'enableScripts: true')
  [[ "$r" == GAP*"enableScripts true in $(YNP)/.yarnrc.yml re-enables dependency install scripts"* ]] || { echo "$r"; return 1; }
  r=$(y_verdict 'npmMinimalAgeGate: 600')
  [[ "$r" == WEAK*"npmMinimalAgeGate 600 in $(YNP)/.yarnrc.yml is below the 48h (2880 minutes) promised here"* ]] || { echo "$r"; return 1; }
  r=$(y_verdict 'npmMinimalAgeGate: "3d"')
  [[ "$r" == OK*"'3d' (4320 minutes on yarn 4.19.0)"*"is at least the 48h"* ]] || { echo "$r"; return 1; }
  r=$(y_verdict $'npmPreapprovedPackages:\n  - left-pad\n  - "@myorg/*"')
  [[ "$r" == WEAK*"npmPreapprovedPackages exempts left-pad, @myorg/* from the age gate"* ]] || { echo "$r"; return 1; }
  # MEASURED (4.19.0): "*" exempted typescript but no scoped name, "@*/*" every
  # scoped name, "**" everything.
  for p in '"*"' '"**"' '"@*/*"' '"?*"'; do
    r=$(y_verdict "npmPreapprovedPackages: [$p]")
    [[ "$r" == GAP*"lists '${p//\"/}', which exempts every "*"package"*" from the age gate"* ]] || { echo "$p: $r"; return 1; }
  done
  # A nearer file wins; a parent's 0 under a project's 4320 is not a finding.
  y_project 'npmMinimalAgeGate: 4320'
  printf 'npmMinimalAgeGate: 0\n' > "$PNT/.yarnrc.yml"
  run verify_in "$(YNP)/packages/a" --emit=plain
  rm -f "$PNT/.yarnrc.yml"
  [[ "$(y_row)" == OK*"npmMinimalAgeGate 4320 in $(YNP)/.yarnrc.yml"* ]] || { y_row; return 1; }
  # A YARN_* variable outranks every file, so it hides the project's 0 here.
  echo 'export YARN_NPM_MINIMAL_AGE_GATE=2880' >> "$ENV_FILE"
  r=$(y_verdict 'npmMinimalAgeGate: 0')
  [[ "$r" == WEAK*"YARN_NPM_MINIMAL_AGE_GATE=2880 in this environment outranks it"*"an env variable is what hides the project's weaker setting"* ]] || { echo "$r"; return 1; }
}

@test "yarn repo config override: values read the way each yarn reads them (4.10 leading integer, 4.11+ durations, below 4.10 refused)" {
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  local r
  # MEASURED: 4.10.3 reads "2d" as 2; 4.11.0 as 2880 and refuses "2 days".
  yarn_rc_stub 4.10.3
  r=$(y_verdict 'npmMinimalAgeGate: "2d"')
  [[ "$r" == WEAK*"'2d' (2 minutes on yarn 4.10.3)"*"is below"* ]] || { echo "$r"; return 1; }
  yarn_rc_stub 4.11.0
  r=$(y_verdict 'npmMinimalAgeGate: 2d')
  [[ "$r" == OK*"'2d' (2880 minutes on yarn 4.11.0)"* ]] || { echo "$r"; return 1; }
  r=$(y_verdict 'npmMinimalAgeGate: "2 days"')
  [[ "$r" == WEAK*"which yarn 4.11.0 refuses"*"so every yarn command here fails"*"was not judged"* ]] || { echo "$r"; return 1; }
  r=$(y_verdict 'npmMinimalAgeGate: ${GATE:-0}')
  [[ "$r" == WEAK*"which yarn expands from the environment"* ]] || { echo "$r"; return 1; }
  # Below 4.10 a project file holding the key stops every yarn command.
  yarn_rc_stub 4.9.4 'Usage Error: no such setting'
  r=$(y_verdict 'npmMinimalAgeGate: 0')
  [[ "$r" == WEAK*"which yarn 4.9.4 does not know: in a project's file that stops every yarn command"* ]] || { echo "$r"; return 1; }
}

@test "yarn repo config override: a yarnPath is the checkout's own yarn, graded by its version string and never run" {
  yarn_rc_stub 4.19.0
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  local r
  y_project 'yarnPath: .yarn/releases/yarn-4.9.4.cjs'
  yarn_release "$(YNP)/.yarn/releases/yarn-4.9.4.cjs" 4.9.4
  run verify_in "$(YNP)/packages/a" --emit=plain
  [[ "$(y_row)" == GAP*"names yarnPath $(YNP)/.yarn/releases/yarn-4.9.4.cjs, the checkout's own yarn"*"by its version string it is yarn 4.9.4, which has no npmMinimalAgeGate"* ]] || { y_row; return 1; }
  # The host rows still describe the host, and say which yarn runs here.
  [[ "$output" == *"OK     PARSED      yarn age gate"*"In $(YNP)/packages/a that is not the yarn that runs: the checkout's own yarn"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/markers/yarn-release-ran" ]
  # FIXTURE CONTROL: yarn run in the project runs it.
  ( cd "$(YNP)/packages/a" && PATH="$TEST_BIN:$PATH" yarn --version >/dev/null )
  [ -e "$BATS_TEST_TMPDIR/markers/yarn-release-ran" ]
  # A release that has the gate is WEAK, not OK: it is still the checkout's code.
  y_project 'yarnPath: .yarn/releases/yarn-4.19.0.cjs'
  yarn_release "$(YNP)/.yarn/releases/yarn-4.19.0.cjs" 4.19.0
  run verify_in "$(YNP)/packages/a" --emit=plain
  [[ "$(y_row)" == WEAK*"yarn 4.19.0, which has npmMinimalAgeGate"* ]] || { y_row; return 1; }
  # No version string: not judged. A missing file: every command fails.
  y_project 'yarnPath: ./evil.cjs'
  printf 'console.log(1)\n' > "$(YNP)/evil.cjs"
  r=$(run verify_in "$(YNP)/packages/a" --emit=plain; y_row)
  [[ "$r" == WEAK*"its version could not be read from the file, so whether it has an age gate was not judged"* ]] || { echo "$r"; return 1; }
  r=$(y_verdict 'yarnPath: ./gone.cjs')
  [[ "$r" == WEAK*"which does not exist, so every yarn command here fails"* ]] || { echo "$r"; return 1; }
  # plugins are the checkout's code too.
  r=$(y_verdict $'plugins:\n  - path: .yarn/plugins/x.cjs\n    spec: x')
  [[ "$r" == WEAK*"loads plugins (.yarn/plugins/x.cjs)"* ]] || { echo "$r"; return 1; }
  # A classic host yarn hands a yarnPath the whole job, so its row is N/A there.
  yarn_rc_stub 1.22.22
  y_project 'yarnPath: .yarn/releases/yarn-4.19.0.cjs'
  yarn_release "$(YNP)/.yarn/releases/yarn-4.19.0.cjs" 4.19.0
  run verify_in "$(YNP)/packages/a" --emit=plain
  [[ "$output" == *"N/A    ABSENT      yarn hardening"*"this host's yarn, 1.22.22, is classic"*"not the yarn that runs"* ]] || { echo "$output" | grep yarn; return 1; }
  [[ "$(y_row)" == WEAK*"yarn 4.19.0, which has npmMinimalAgeGate"* ]] || { y_row; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/markers/yarn-release-ran" ] || rm -f "$BATS_TEST_TMPDIR/markers/yarn-release-ran"
}

@test "yarn repo config override: yarn is asked from /, never inside the project" {
  yarn_rc_stub 4.19.0
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  y_project $'yarnPath: ./evil.cjs\nnpmMinimalAgeGate: 600'
  printf 'require("fs").writeFileSync("%s", "x")\n' "$BATS_TEST_TMPDIR/markers/yarnpath-ran" > "$(YNP)/evil.cjs"
  rm -f "$BATS_TEST_TMPDIR/yarn-calls"
  run verify_in "$(YNP)/packages/a" --emit=plain
  # A yarnPath with no version string: its values are not judged, only named.
  [[ "$(y_row)" == WEAK*"names yarnPath $(YNP)/evil.cjs, the checkout's own yarn"*"the project sets npmMinimalAgeGate, not judged"* ]] || { y_row; return 1; }
  [ -s "$BATS_TEST_TMPDIR/yarn-calls" ]
  ! grep -q -e "^$PNT/yproj" -e "^$BATS_TEST_TMPDIR/yproj" "$BATS_TEST_TMPDIR/yarn-calls" || { cat "$BATS_TEST_TMPDIR/yarn-calls"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/markers/yarnpath-ran" ]
}

@test "yarn repo config override: through a corepack shim the packageManager is the yarn graded" {
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  # A corepack shim is found by where `yarn` resolves: .../corepack/dist/yarn.js.
  mkdir -p "$BATS_TEST_TMPDIR/cp/corepack/dist"
  yarn_rc_stub 1.22.22
  mv "$TEST_BIN/yarn" "$BATS_TEST_TMPDIR/cp/corepack/dist/yarn.js"
  ln -s "$BATS_TEST_TMPDIR/cp/corepack/dist/yarn.js" "$TEST_BIN/yarn"
  local r
  y_project ''
  printf '{"name":"p","version":"1.0.0","packageManager":"yarn@4.9.4+sha512.abc"}\n' > "$(YNP)/package.json"
  run verify_in "$(YNP)/packages/a" --emit=plain
  [[ "$(y_row)" == GAP*"yarn 4.9.4, which corepack downloads because packageManager in $(YNP)/package.json names it: it has no npmMinimalAgeGate"* ]] || { y_row; return 1; }
  [[ "$output" == *"N/A    ABSENT      yarn hardening"*"classic"* ]]
  printf '{"name":"p","version":"1.0.0","packageManager":"yarn@4.19.0"}\n' > "$(YNP)/package.json"
  run verify_in "$(YNP)/packages/a" --emit=plain
  # Read from files only: WEAK, not OK, even with nothing weaker found.
  [[ "$(y_row)" == WEAK*"an official release that has npmMinimalAgeGate"*"was not asked, so these values come from the files alone"* ]] || { y_row; return 1; }
}

@test "yarn repo config override: without PyYAML the plain-key reader reaches the same verdicts, and refuses YAML it does not follow" {
  yarn_rc_stub 4.19.0
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  local real r y; real=$(command -v python3) || skip "no python3"
  stub_bin python3 "case \"\$*\" in *'import yaml'*) exit 3 ;; esac; exec '$real' \"\$@\""
  r=$(y_verdict $'npmMinimalAgeGate: 0   # off\nenableScripts: "true"')
  [[ "$r" == GAP*"switches the age gate off"*"re-enables dependency install scripts"*"plain-key reader"* ]] || { echo "$r"; return 1; }
  r=$(y_verdict $'npmPreapprovedPackages:\n  - left-pad   # ours\n  - "@myorg/*"\nplugins:\n  - path: .yarn/plugins/a.cjs\n    spec: "a"')
  [[ "$r" == WEAK*"loads plugins (.yarn/plugins/a.cjs)"*"exempts left-pad, @myorg/*"* ]] || { echo "$r"; return 1; }
  for y in '{npmMinimalAgeGate: 0}' $'base: &b 0\nnpmMinimalAgeGate: *b' $'npmMinimalAgeGate: |\n  0'; do
    r=$(y_verdict "$y")
    [[ "$r" == WEAK*"could not be read by the reader"*"was not judged"* ]] || { echo "$y: $r"; return 1; }
  done
}

# As pn_forms above, for yarn: each MEASURED to turn enableScripts on for Yarn
# 4.18.1, the last one as a yarn 1 lockfile, where a key needs no colon.
y_forms() {
  printf '%s\n' '{enableScripts: true}' '--- {enableScripts: true}' '  enableScripts: true' \
    '"enable\\x53cripts": true' '\357\273\277enableScripts: true' '# c\renableScripts: true\r' \
    '!!str enableScripts: true' '"enableScripts" : true' 'nodeLinker: &k enableScripts\n*k : true' \
    '? "enable\\x53cripts"\n: true' 'enableScripts: true\nnpmRegistryServer: "\nenableScripts: false\n"' \
    'enableScripts: true\nnpmScopes: {\nenableScripts: {}\n}' \
    'enableScripts: true\n# c\302\205enableScripts: false' '# yarn lockfile v1\nenableScripts true' \
    '# yarn lockfile v1\n"enable\\u0053cripts" true'
}
y_forms_check() {
  local y r n=0
  while IFS= read -r y; do
    y_project ''
    printf -- "$y\n" > "$(YNP)/.yarnrc.yml"
    run verify_in "$(YNP)/packages/a" --emit=plain
    r=$(y_row)
    case "$r" in
      GAP*"re-enables dependency install scripts"*|WEAK*"could not be read by the reader"*"was not judged"*) n=$((n + 1)) ;;
      *) echo "$1, $y: $r"; return 1 ;;
    esac
  done < <(y_forms)
  [ "$n" -eq 15 ] || { echo "$1: $n forms"; return 1; }
}

@test "yarn repo config override: no spelling of a key reads as nothing set, with PyYAML or without" {
  yarn_rc_stub 4.19.0
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  local real r; real=$(command -v python3) || skip "no python3"
  y_forms_check "as installed"
  stub_bin python3 "case \"\$*\" in *'import yaml'*) exit 3 ;; esac; exec '$real' \"\$@\""
  y_forms_check "without PyYAML"
  r=$(y_verdict $'---\n# yarn\nnodeLinker: node-modules\nnpmScopes:\n  acme:\n    npmRegistryServer: "https://npm.example"\nunsafeHttpWhitelist: [\n  a,\n]')
  [[ "$r" == "N/A"*"sets no yarnPath"* ]] || { echo "ordinary: $r"; return 1; }
}

# corepack reads package.json as JSON and climbs to the nearest one that has
# packageManager. Each form was MEASURED to run the older yarn on corepack 0.36.0.
@test "yarn repo config override: the packageManager graded is the one corepack runs, however package.json spells it" {
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  command -v python3 >/dev/null 2>&1 || skip "no python3"
  mkdir -p "$BATS_TEST_TMPDIR/cp/corepack/dist"
  yarn_rc_stub 4.19.0
  mv "$TEST_BIN/yarn" "$BATS_TEST_TMPDIR/cp/corepack/dist/yarn.js"
  ln -s "$BATS_TEST_TMPDIR/cp/corepack/dist/yarn.js" "$TEST_BIN/yarn"
  local y n=0
  while IFS= read -r y; do
    y_project ''
    printf -- "$y" > "$(YNP)/package.json"
    run verify_in "$(YNP)/packages/a" --emit=plain
    [[ "$(y_row)" == GAP*"yarn 4.9.1, which corepack downloads because packageManager in $(YNP)/package.json names it"* ]] || { echo "$y: $(y_row)"; return 1; }
    n=$((n + 1))
  done <<'FORMS'
{"packageManager":"yarn@4.9.1"}
{"packageManager":\n"yarn@4.9.1"}
{"x":{"packageManager":"yarn@4.12.0"},\n"packageManager":"yarn@4.9.1"}
{"packageManager":"yarn@4.12.0",\n"packageManager":"yarn@4.9.1"}
{"package\\u004danager":"yarn@4.9.1"}
{"devEngines":{"packageManager":{"name":"yarn","version":"4.9.1"}}}
FORMS
  [ "$n" -eq 6 ]
  # A nearer package.json without one does not end the search.
  y_project ''
  printf '{"packageManager":"yarn@4.9.1"}' > "$(YNP)/package.json"
  printf '{"name":"a","devEngines":{"packageManager":{"name":"yarn","version":"4.19.0"}}}' > "$(YNP)/packages/a/package.json"
  run verify_in "$(YNP)/packages/a" --emit=plain
  [[ "$(y_row)" == GAP*"yarn 4.9.1, which corepack downloads because packageManager in $(YNP)/package.json names it"* ]] || { y_row; return 1; }
  # A range, or a file that cannot be read, is not judged as some other yarn.
  for y in '{"devEngines":{"packageManager":{"name":"yarn","version":"^4.9.1"}}}' '{bad'; do
    y_project ''
    printf -- "$y" > "$(YNP)/package.json"
    run verify_in "$(YNP)/packages/a" --emit=plain
    [[ "$(y_row)" == WEAK*"the yarn corepack picks"*"a version this row cannot read"* ]] || { echo "$y: $(y_row)"; return 1; }
  done
  # Without python3, more than one mention is not guessed at.
  stub_bin python3 'exit 127'
  y_project ''
  printf '{"x":{"packageManager":"yarn@4.12.0"},\n"packageManager":"yarn@4.9.1"}' > "$(YNP)/package.json"
  run verify_in "$(YNP)/packages/a" --emit=plain
  [[ "$(y_row)" == WEAK*"whose packageManager could not be read"* ]] || { y_row; return 1; }
}

@test "yarn repo config override: yarn 1's .yarnrc with a quoted or escaped yarn-path (MEASURED, 1.22.22)" {
  yarn_rc_stub 1.22.22
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  y_project ''
  yarn_release "$(YNP)/.yarn/releases/yarn-4.9.1.cjs" 4.9.1
  printf '"yarn-path" ".yarn/releases/yarn-4.9.1.cjs"\n' > "$(YNP)/.yarnrc"
  run verify_in "$(YNP)/packages/a" --emit=plain
  [[ "$(y_row)" == GAP*"names yarn-path"* ]] || { y_row; return 1; }
  printf '"yarn\\u002dpath" ".yarn/releases/yarn-4.9.1.cjs"\n' > "$(YNP)/.yarnrc"
  run verify_in "$(YNP)/packages/a" --emit=plain
  [[ "$(y_row)" == WEAK*"$(YNP)/.yarnrc could not be read by the reader: a key written with an escape"* ]] || { y_row; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/markers/yarn-release-ran" ]
}

@test "yarn repo config override: N/A with no file, with no keys, from /, and a path with a space" {
  yarn_rc_stub 4.19.0
  harden ECOSYSTEMS=yarn -- --emit=plain >/dev/null
  local r
  y_project ''
  run verify_in "$(YNP)/packages/a" --emit=plain
  [[ "$(y_row)" == "N/A"*"no .yarnrc.yml at or above $(YNP)/packages/a, and the yarn that runs there is this host's"* ]] || { y_row; return 1; }
  r=$(y_verdict 'nodeLinker: node-modules')
  [[ "$r" == "N/A"*"$(YNP)/.yarnrc.yml sets no yarnPath, plugins, npmMinimalAgeGate"* ]] || { echo "$r"; return 1; }
  run verify_in / --emit=plain
  [[ "$(y_row)" == "N/A"*"ran from /"* ]] || { y_row; return 1; }
  local save=$PNT; PNT="$PNT/my dir"; mkdir -p "$PNT"
  r=$(y_verdict 'npmMinimalAgeGate: 0')
  PNT=$save
  [[ "$r" == GAP*"npmMinimalAgeGate 0 in $save/my dir/yproj/.yarnrc.yml switches the age gate off"* ]] || { echo "$r"; return 1; }
}

# mvn_trap <dir> <marker>: a <dir>/.mvn/jvm.config that writes <marker> when the
# JVM maven starts reads it. A -javaagent where a JDK can build one (MEASURED on
# maven 3.10.0), compiled for Java 8 where javac still targets it, so it loads
# in whichever JVM maven picks; otherwise a 3 MB heap and
# -XX:OnOutOfMemoryError, which fired on temurin 17 but not on every JDK.
mvn_trap() {
  local d=$1 m=$2
  mkdir -p "$d/.mvn" "$d/.mvnagent"
  if command -v javac >/dev/null 2>&1 && command -v jar >/dev/null 2>&1; then
    printf 'public class A { public static void premain(String a) throws Exception { java.nio.file.Files.write(java.nio.file.Paths.get(a), "ran".getBytes()); } }\n' > "$d/.mvnagent/A.java"
    ( cd "$d/.mvnagent" && { javac --release 8 A.java || javac A.java; } && printf 'Premain-Class: A\n' > m.txt && jar cfm agent.jar m.txt A.class ) >/dev/null 2>&1
  fi
  if [ -f "$d/.mvnagent/agent.jar" ]; then
    printf -- '-javaagent:%s/.mvnagent/agent.jar=%s\n' "$d" "$m" > "$d/.mvn/jvm.config"
  else
    printf '#!/bin/sh\necho ran > "%s"\n' "$m" > "$d/.mvnagent/oom"; chmod +x "$d/.mvnagent/oom"
    printf -- '-Xmx3m -XX:OnOutOfMemoryError=%s/.mvnagent/oom\n' "$d" > "$d/.mvn/jvm.config"
  fi
}

# trap_checkout <dir>: a checkout carrying every vector found to run code (and
# a few measured not to, as insurance). Each trap writes its own marker in
# $BATS_TEST_TMPDIR/markers if anything executes it.
trap_checkout() {
  local d=$1 mk="$BATS_TEST_TMPDIR/markers"
  rm -rf "$d"; mkdir -p "$d/sub" "$mk" "$d/tc/bin" "$d/.mvn" "$d/.cargo" "$d/.venv/bin" "$d/.yarn"
  tjs() { printf 'require("fs").writeFileSync("%s/%s", "ran"); console.log("9.9.9");\n' "$mk" "$2" > "$1"; }
  tsh() { printf '#!/bin/sh\necho ran > "%s/%s"\necho 9.9.9\n' "$mk" "$2" > "$1"; chmod +x "$1"; }
  printf '{"name":"trap","version":"1.0.0","packageManager":"yarn@4.9.4","scripts":{"preinstall":"echo ran > %s/npm-preinstall"}}\n' "$mk" > "$d/package.json"
  # yarn 1.22.22 and 4.x: yarnPath and plugins from any .yarnrc.yml above; classic's yarn-path
  tjs "$d/.yarn/evil.cjs" yarn-yarnpath
  printf 'require("fs").writeFileSync("%s/yarn-plugin", "ran");\nmodule.exports = { name: "p", factory: () => ({}) };\n' "$mk" > "$d/.yarn/plug.cjs"
  printf 'yarnPath: .yarn/evil.cjs\nplugins:\n  - path: .yarn/plug.cjs\n    spec: plug\n' > "$d/.yarnrc.yml"
  tjs "$d/.yarn/classic.js" yarn-classic-path; printf 'yarn-path ".yarn/classic.js"\n' > "$d/.yarnrc"
  # corepack 0.36: a .corepack.env that lets packageManager name any URL
  printf 'COREPACK_ENABLE_UNSAFE_CUSTOM_URLS=1\nCOREPACK_NPM_REGISTRY=http://127.0.0.1:9\n' > "$d/.corepack.env"
  # pnpm 10/11: the pnpmfile runs for `pnpm config get`
  tjs "$d/.pnpmfile.cjs" pnpm-pnpmfile; printf 'packages: ["sub"]\nminimumReleaseAge: 600\n' > "$d/pnpm-workspace.yaml"
  # npm: onload-script, gone since npm 7 (insurance)
  tjs "$d/.yarn/npm-onload.js" npm-onload; printf 'onload-script=%s/.yarn/npm-onload.js\n' "$d" > "$d/.npmrc"
  # rustup: an absolute path= toolchain; cargo: a rustc-wrapper
  tsh "$d/tc/bin/cargo" rustup-path-cargo; tsh "$d/tc/bin/rustc" rustup-path-rustc
  printf '[toolchain]\npath = "%s/tc"\n' "$d" > "$d/rust-toolchain.toml"
  tsh "$d/tc/wrap" cargo-rustc-wrapper; printf '[build]\nrustc-wrapper = "%s/tc/wrap"\n' "$d" > "$d/.cargo/config.toml"
  # maven: jvm.config goes on the java command line
  mvn_trap "$d" "$mk/maven-jvm-config"
  # gradle: a settings script and daemon jvmargs (insurance: --version reads neither)
  printf 'new File("%s/gradle-settings").text = "ran"\n' "$mk" > "$d/settings.gradle"
  tsh "$d/tc/oom-gradle" gradle-jvmargs; printf 'org.gradle.jvmargs=-Xmx3m -XX:OnOutOfMemoryError=%s/tc/oom-gradle\n' "$d" > "$d/gradle.properties"
  # dotnet: global.json naming an SDK the checkout ships; MSBuild's Directory.Build.props
  mkdir -p "$d/.dotnet/sdk/99.0.100"; tsh "$d/.dotnet/sdk/99.0.100/dotnet.dll" dotnet-sdk
  printf '{"sdk":{"version":"99.0.100","paths":[".dotnet","$host$"],"rollForward":"disable"}}\n' > "$d/global.json"
  printf '<Project InitialTargets="T"><Target Name="T"><Exec Command="echo ran > %s/dotnet-props" /></Target></Project>\n' "$mk" > "$d/Directory.Build.props"
  # python3 -m puts the working directory first on sys.path
  printf 'open("%s/python-pip-py", "w").write("ran")\n' "$mk" > "$d/pip.py"
  cp "$d/pip.py" "$d/sub/pip.py"
  # uv: a .venv whose interpreter is a script (uv runs it to query the venv)
  tsh "$d/.venv/bin/python" uv-venv-python; ln -s python "$d/.venv/bin/python3"
  printf 'home = /usr/bin\nversion = 3.12.0\ninclude-system-site-packages = false\n' > "$d/.venv/pyvenv.cfg"
  printf '[project]\nname = "trap"\nversion = "0.1.0"\n[tool.poetry.requires-plugins]\nevil = { path = "./evil" }\n' > "$d/pyproject.toml"
  # go: a toolchain line (go1.24 fetched and ran the named toolchain for `go env`)
  printf 'module trap\n\ngo 1.21\n\ntoolchain go1.999.0\n' > "$d/go.mod"
  # bundler: a Gemfile is Ruby, evaluated by bundle check/exec/install
  printf 'File.write("%s/bundler-gemfile", "ran")\nsource "https://rubygems.org"\n' "$mk" > "$d/Gemfile"
  # composer: a script on every command (insurance: the probes pass --no-plugins and no project)
  printf '{"name":"t/t","scripts":{"pre-command-run":"echo ran > %s/composer-script"}}\n' "$mk" > "$d/composer.json"
  # bun: a preload (insurance: read for `bun run`, not --version); deno: an import map
  tjs "$d/.yarn/bun-preload.js" bun-preload; printf 'preload = ["./.yarn/bun-preload.js"]\n' > "$d/bunfig.toml"
  printf '{"imports":{"x":"./.yarn/deno.ts"}}\n' > "$d/deno.json"
}
markers() { ls "$BATS_TEST_TMPDIR/markers" 2>/dev/null | tr '\n' ' '; }

@test "no project code: run inside a booby-trapped checkout, the verifier sets off none of its traps (FIXTURE CONTROL: they fire when run there)" {
  yarn_rc_stub 4.19.0
  harden -- --emit=plain >/dev/null
  local d="$PNT/trap" mk="$BATS_TEST_TMPDIR/markers" fired=""
  trap_checkout "$d"
  # FIXTURE CONTROL, for whatever is installed here: the traps are live.
  ( cd "$d" && python3 -m pip --version ) >/dev/null 2>&1 || true
  [ -e "$mk/python-pip-py" ] && fired="$fired python"
  ( cd "$d/sub" && PATH="$TEST_BIN:$PATH" yarn --version ) >/dev/null 2>&1 || true
  [ -e "$mk/yarn-yarnpath" ] && fired="$fired yarn"
  if command -v uv >/dev/null 2>&1; then
    ( cd "$d" && uv pip list ) >/dev/null 2>&1 || true
    [ -e "$mk/uv-venv-python" ] || { echo "control: uv pip list did not run the venv's python"; return 1; }
  fi
  if command -v mvn >/dev/null 2>&1; then
    local mo; mo=$( cd "$d/sub" && mvn -v 2>&1 ) || true
    [ -e "$mk/maven-jvm-config" ] || { echo "control: mvn -v did not apply .mvn/jvm.config ($(cat "$d/.mvn/jvm.config")); it said:"; echo "$mo" | head -8; return 1; }
  fi
  case "$(readlink -f "$(command -v cargo 2>/dev/null)" 2>/dev/null)" in
    */rustup)
      ( cd "$d" && cargo --version ) >/dev/null 2>&1 || true
      [ -e "$mk/rustup-path-cargo" ] || { echo "control: cargo --version did not use rust-toolchain.toml"; return 1; } ;;
  esac
  if command -v bundle >/dev/null 2>&1; then
    ( cd "$d" && env -u BUNDLE_APP_CONFIG bundle check ) >/dev/null 2>&1 || true
    [ -e "$mk/bundler-gemfile" ] || { echo "control: bundle check did not evaluate the Gemfile"; return 1; }
  fi
  [[ "$fired" == *python* && "$fired" == *yarn* ]] || { echo "controls fired: $fired / $(markers)"; return 1; }
  rm -f "$mk"/*
  run verify_in "$d/sub" --emit=plain
  [ -z "$(markers)" ] || { echo "the verifier ran: $(markers)"; echo "$output"; return 1; }
  # It still reported what the checkout changes, from the files.
  [[ "$output" == *"yarn repo config override"*"the checkout's own yarn"* ]] || { echo "$output" | grep yarn; return 1; }
  if command -v pnpm >/dev/null 2>&1; then [[ "$output" == *"pnpm repo config override"* ]]; fi
}

# The tools a verifier might start. Each gets a logging shim first on PATH that
# records the directory it was started in, then runs the real one.
npc_tools="yarn pnpm npm npx corepack node python3 python pip pip3 uv poetry go cargo rustc rustup composer php bundle bundler gem ruby mvn gradle java dotnet bun bunx deno npq-hero sfw"
npc_shims() { # <shim dir> <log>
  local t real
  mkdir -p "$1"
  for t in $npc_tools; do
    real=$(PATH="$TEST_BIN:$PATH" command -v "$t" 2>/dev/null) || continue
    case "$real" in /*) ;; *) continue ;; esac
    printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\t%%s\\n" "$PWD" "%s" "${TMPDIR:-}" "$(printf "%%s" "$*" | tr "\\n\\t" "  ")" >> "%s"\nexec "%s" "$@"\n' "$t" "$2" "$real" > "$1/$t"
    chmod +x "$1/$t"
  done
}
npc_verify() { # <dir> [VAR=value ...]: verify.sh in <dir>, the shims first on PATH
  local d=$1; shift
  ( cd "$d" && env -i PATH="$BATS_TEST_TMPDIR/shims:${TEST_BIN}:${PATH}" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
      GRADLE_USER_HOME="${TEST_HOME}/.gradle" HARDENING_OUTPUT_FILE="$OUT_FILE" "$@" \
      bash -c "set -a; source '$ENV_FILE'; set +a; HARDENING_ENV_FILE='$ENV_FILE' bash '$VERIFY_SH' --emit=plain" )
}

@test "no project code: no tool starts inside the checkout except the ones measured to read only settings there" {
  yarn_rc_stub 4.19.0
  harden -- --emit=plain >/dev/null
  local d="$PNT/trap" log="$BATS_TEST_TMPDIR/tool-calls" bad
  trap_checkout "$d"
  npc_shims "$BATS_TEST_TMPDIR/shims" "$log"
  rm -f "$log"
  run npc_verify "$d/sub"
  [ -s "$log" ] || { echo "no tool was logged"; echo "$output"; return 1; }
  # In the project (either spelling of its path): only npm (and the node it
  # runs), `uv ... --show-settings`, bundle/bundler config (and their ruby),
  # `poetry --no-plugins`, composer with --no-plugins (and its php), and
  # python3 -I (the YAML readers, the hook scan).
  bad=$(awk -F'\t' -v p1="$d" -v p2="$BATS_TEST_TMPDIR/trap" '
    $1 == p1 || index($1, p1 "/") == 1 || $1 == p2 || index($1, p2 "/") == 1 {
      if ($2 == "npm") next
      if ($2 == "node" && $4 ~ /(^|\/)npm(-cli\.js)?( |$)/) next
      if ($2 == "uv" && $4 ~ /--show-settings/) next
      if ($2 == "bundle" || $2 == "bundler") next
      if ($2 == "ruby" && $4 ~ /(\/bundler?( |$)|Bundler\.settings)/) next
      if ($2 == "poetry" && $4 ~ /^--no-plugins( |$)/) next
      if ($2 == "composer" && $4 ~ /--no-plugins/) next
      if ($2 == "php" && $4 ~ /composer/ && $4 ~ /--no-plugins/) next
      if ($2 ~ /^python/ && $4 ~ /^-I( |$)/) next
      print
    }' "$log")
  [ -z "$bad" ] || { echo "started inside the checkout:"; echo "$bad"; return 1; }
  [ -z "$(markers)" ] || { echo "the verifier ran: $(markers)"; return 1; }
}

@test "no project code: with a world-writable TMPDIR the probes run under a private base, and files planted above TMPDIR do not run" {
  yarn_rc_stub 4.19.0
  harden -- --emit=plain >/dev/null
  scv_priv || skip "cannot make a directory under HOME"
  local ww="$BATS_TEST_TMPDIR/ww" log="$BATS_TEST_TMPDIR/tool-calls" mk="$BATS_TEST_TMPDIR/markers" tmps
  mkdir -p "$ww/sub" "$ww/h" "$ww/tc/bin" "$ww/.mvn" "$mk"; chmod 1777 "$ww"
  # What another account could leave in /tmp, above every mktemp directory.
  mvn_trap "$ww" "$mk/tmp-maven-jvm-config"
  printf '#!/bin/sh\necho ran > "%s/tmp-rustup-path"\necho cargo 9.9.9\n' "$mk" > "$ww/tc/bin/cargo"; chmod +x "$ww/tc/bin/cargo"
  printf '[toolchain]\npath = "%s/tc"\n' "$ww" > "$ww/rust-toolchain.toml"
  printf '<Project InitialTargets="T"><Target Name="T"><Exec Command="echo ran > %s/tmp-dotnet-props" /></Target></Project>\n' "$mk" > "$ww/Directory.Build.props"
  printf '{"name":"tmproot","private":true,"workspaces":["*"],"scripts":{"preinstall":"echo ran > %s/tmp-bun-root"}}\n' "$mk" > "$ww/package.json"
  printf 'new File("%s/tmp-gradle-settings").text = "ran"\n' "$mk" > "$ww/settings.gradle"
  # FIXTURE CONTROL: where maven is installed, it applies the planted
  # jvm.config to a run in any directory below it.
  if command -v mvn >/dev/null 2>&1; then
    mkdir -p "$ww/sub/ctl"
    local mo; mo=$( cd "$ww/sub/ctl" && mvn -v 2>&1 ) || true
    [ -e "$mk/tmp-maven-jvm-config" ] || { echo "control: mvn -v below $ww did not apply $ww/.mvn/jvm.config ($(cat "$ww/.mvn/jvm.config")); it said:"; echo "$mo" | head -8; return 1; }
    rm -f "$mk/tmp-maven-jvm-config"
  fi
  npc_shims "$BATS_TEST_TMPDIR/shims" "$log"
  rm -f "$log"
  run npc_verify "$PNT" TMPDIR="$ww/sub" RUNNER_TEMP="$SCV_PRIV"
  [ -s "$log" ] || { echo "no tool was logged"; echo "$output"; return 1; }
  # Every tool started with a TMPDIR got the private scratch dir (a probe that
  # runs a tool under env -i passes none, and that tool's working directory is
  # one of the probe's own, under the same scratch dir), and none ran anywhere
  # below the world-writable directory.
  tmps=$(cut -f3 "$log" | grep -v '^$' | sort -u)
  [[ "$tmps" == "$SCV_PRIV/scv."* ]] && [ "$(printf '%s\n' "$tmps" | grep -vc "^$SCV_PRIV/scv\.")" -eq 0 ] || { echo "TMPDIR seen by tools: $tmps"; return 1; }
  ! cut -f1 "$log" | grep -q "^$ww" || { echo "started below $ww:"; grep "^$ww" "$log"; return 1; }
  [ -z "$(ls -d "$SCV_PRIV"/scv.* 2>/dev/null)" ] || { echo "scratch left behind: $(ls -d "$SCV_PRIV"/scv.*)"; return 1; }
  [ -z "$(markers)" ] || { echo "a planted file ran: $(markers)"; return 1; }
  [[ "$output" != *"found no directory for the probes"* ]]
  # With TMPDIR and HOME both below the world-writable directory: on a Mac the
  # per-user temp dir (getconf DARWIN_USER_TEMP_DIR) is still private, so the
  # probes go there and nothing planted runs. Elsewhere there is no private
  # base: the probes run under that TMPDIR, stderr says so, and (CONTROL) where
  # maven is installed its probes then run the planted jvm.config.
  rm -f "$log"
  run npc_verify "$PNT" TMPDIR="$ww/sub" HOME="$ww/h"
  local dar darp; dar=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || dar=""
  if [ -n "$dar" ]; then
    darp=$(cd -P "$dar" && pwd -P)
    tmps=$(cut -f3 "$log" | grep -v '^$' | sort -u)
    [ -n "$tmps" ] && [ "$(printf '%s\n' "$tmps" | grep -vc "^$darp/scv\.")" -eq 0 ] || { echo "TMPDIR seen by tools: $tmps"; return 1; }
    ! cut -f1 "$log" | grep -q "^$ww" || { echo "started below $ww:"; grep "^$ww" "$log"; return 1; }
    [ -z "$(markers)" ] || { echo "a planted file ran: $(markers)"; return 1; }
    [[ "$output" != *"found no directory for the probes"* ]]
  else
    [[ "$output" == *"warning: found no directory for the probes' throwaway projects"* ]] || { echo "$output" | head -5; return 1; }
    [ "$(cut -f3 "$log" | sort -u | grep -c "^$ww/sub")" -ge 1 ] || { cut -f3 "$log" | sort -u; return 1; }
    if command -v mvn >/dev/null 2>&1; then
      [ -e "$mk/tmp-maven-jvm-config" ] || { echo "control: the maven probes under $ww/sub did not apply the planted jvm.config: $(markers)"; return 1; }
    fi
  fi
}

# dotnet_nuget_stub <config get all output>: an SDK 10 dotnet that logs where
# it runs and answers the nuget questions the way 10.0.404 does (MEASURED).
dotnet_nuget_stub() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/getall"
  stub_bin dotnet 'echo "$PWD :: $*" >> "'"$BATS_TEST_TMPDIR"'/dotnet-calls"
case "$*" in
  --list-sdks) echo "10.0.404 [/usr/share/dotnet/sdk]" ;;
  --version) echo 10.0.404 ;;
  "nuget config paths --working-directory "*) echo "'"$TEST_HOME"'/.nuget/NuGet/NuGet.Config" ;;
  "nuget config get signatureValidationMode --show-path --working-directory "*) printf "require\tfile: %s\n" "'"$TEST_HOME"'/.nuget/NuGet/NuGet.Config" ;;
  "nuget config get all --working-directory "*) cat "'"$BATS_TEST_TMPDIR"'/getall" ;;
  *) echo "STUB: $*"; exit 1 ;;
esac'
}

@test "nuget: dotnet is never started in the project (a global.json there picks the SDK); the source list comes from config get all --working-directory" {
  harden ECOSYSTEMS=nuget -- --emit=plain >/dev/null
  [ -f "$TEST_HOME/.nuget/NuGet/NuGet.Config" ] || skip "harden.sh wrote no NuGet.Config here"
  local tab=$'\t' d="$PNT/nproj"
  mkdir -p "$d/sub"
  printf '{"sdk":{"version":"99.0.100","paths":[".dotnet","$host$"]}}\n' > "$d/global.json"
  # MEASURED (10.0.404): the project's entries come first; the hardened user
  # file's <clear/> is printed after them and does not drop them.
  dotnet_nuget_stub "packageSources:
${tab}add key=\"extra\" value=\"https://extra.invalid/v3/index.json\"
${tab}add key=\"off\" value=\"https://off.invalid/v3/index.json\"
${tab}clear
${tab}add key=\"nuget.org\" value=\"https://api.nuget.org/v3/index.json\" protocolVersion=\"3\"

disabledPackageSources:
${tab}add key=\"off\" value=\"true\"
"
  rm -f "$BATS_TEST_TMPDIR/dotnet-calls"
  run verify_in "$d/sub" --emit=plain
  [[ "$(grep 'nuget source allowlist' <<<"$output")" == GAP*"2 enabled source(s) in $d/sub; not official nuget.org: https://extra.invalid/v3/index.json"* ]] || { grep nuget <<<"$output"; return 1; }
  [ -s "$BATS_TEST_TMPDIR/dotnet-calls" ]
  ! grep -q -e "^$d" -e "^$BATS_TEST_TMPDIR/nproj" "$BATS_TEST_TMPDIR/dotnet-calls" || { cat "$BATS_TEST_TMPDIR/dotnet-calls"; return 1; }
  grep -q -- "--working-directory $d/sub" "$BATS_TEST_TMPDIR/dotnet-calls"
  # A project file that clears: only what it adds is in effect.
  dotnet_nuget_stub "packageSources:
${tab}clear
${tab}add key=\"nuget.org\" value=\"https://api.nuget.org/v3/index.json\" protocolVersion=\"3\"
"
  run verify_in "$d/sub" --emit=plain
  [[ "$(grep 'nuget source allowlist' <<<"$output")" == OK*"1 enabled source(s) in $d/sub, all official nuget.org"* ]] || { grep nuget <<<"$output"; return 1; }
}
