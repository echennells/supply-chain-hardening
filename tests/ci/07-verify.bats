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
  # The pnpm repo config override fixture's project (pn_project).
  PNP="$BATS_TEST_TMPDIR/proj"
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
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     PARSED      composer config in effect"* ]]
  echo '{"config":{}}' > "$TEST_HOME/.composer/config.json"
  run verify_sourced --emit=plain
  [[ "$output" == *"GAP    PARSED      composer config in effect"* ]]
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

poetry_age_stub() { # version value [exclude]
  stub_bin poetry "case \"\$*\" in
  *--version*) echo 'Poetry (version $1)' ;;
  'config solver.min-release-age') echo '$2' ;;
  'config solver.min-release-age-exclude') echo '${3:-null}' ;;
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
  ! grep -q "^$PNP" "$BATS_TEST_TMPDIR/pnpm-calls" || { cat "$BATS_TEST_TMPDIR/pnpm-calls"; return 1; }
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

@test "pnpm repo config override: N/A with no workspace file, with no age keys, from /, and on a pnpm with no age gate" {
  pnpm_stub 11.28.13
  harden ECOSYSTEMS=pnpm -- --emit=plain >/dev/null
  local r
  pn_project ""
  run verify_in "$PNP/packages/a" --emit=plain
  [[ "$(pn_row)" == "N/A"*"no pnpm-workspace.yaml at or above $PNP/packages/a"* ]] || { pn_row; return 1; }
  r=$(pn_verdict "packages: ['packages/*']")
  [[ "$r" == "N/A"*"sets neither minimumReleaseAge nor minimumReleaseAgeExclude"* ]] || { echo "$r"; return 1; }
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
