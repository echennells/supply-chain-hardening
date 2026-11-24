#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
# PATH wrappers: deployment and behavior.
#
# Wrappers exist for the gaps config files cannot close — bun's runtime
# auto-install, bunx fetch-and-execute, composer scripts, cargo's --locked
# (which has no config or env route at all). They are also the most delicate
# code here: a wrapper that is subtly wrong still LOOKS deployed, and the
# difference between a protected command and an unprotected one is invisible
# at the terminal.
#
# These tests plant stub binaries on PATH so harden.sh performs a real
# wrap — discover, move aside to -real, write the wrapper — and then run the
# deployed wrapper and inspect what it forwarded.

load helpers

setup() {
  common_setup
  # Wrapping moves a binary aside and writes to its original path, which the
  # script does with sudo so it works for both ~/.bun/bin and /usr/local/bin.
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null \
    || skip "needs passwordless sudo to wrap binaries"
}

# --- bun -------------------------------------------------------------------

@test "bun: wrapper replaces the discovered binary and preserves the original" {
  stub_bin bun
  run harden ECOSYSTEMS=bun -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_BIN/bun" "supply-chain-harden"
  [ -x "$(stub_real bun)" ]
}

@test "bun: runtime invocations get --no-install injected" {
  stub_bin bun
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run "$TEST_BIN/bun" run myscript.ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-install run myscript.ts"* ]]
}

@test "bun: package-management subcommands are NOT given --no-install" {
  # `bun install` must still be able to install; the gate for that path is
  # bunfig, not the wrapper. Injecting here would break every install.
  stub_bin bun
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run "$TEST_BIN/bun" install
  [ "$status" -eq 0 ]
  [[ "$output" != *"--no-install"* ]]
}

@test "bun: a metadata flag in FRONT of more arguments still gets --no-install" {
  # MEASURED on bun 1.4.4: `bun --version x cowsay hi` ignores the flag and
  # fetch-and-executes cowsay. Only the bare flag may skip --no-install.
  stub_bin bun
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run "$TEST_BIN/bun" --version x cowsay hi
  [[ "$output" == *"--no-install --version x cowsay hi"* ]]
  run "$TEST_BIN/bun" --version
  [[ "$output" != *"--no-install"* ]]
}

@test "bun: re-running the action does not wrap the wrapper" {
  stub_bin bun
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  # A double wrap would make bun-real itself a wrapper and recurse.
  run grep -c "supply-chain-harden" "$(stub_real bun)"
  [ "$output" = "0" ]
  run "$TEST_BIN/bun" run x
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB:bun"* ]]
}

@test "bun: version tiering writes saveTextLockfile only on bun >= 1.2" {
  # Exercises version_ge, which nothing else reaches. The key is silently
  # ignored by older bun, so emitting it always would be harmless — but the
  # comparison it depends on is also what gates future tier decisions, and a
  # broken comparator would fail open without any visible symptom.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0" ;; *) echo "STUB" ;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  assert_file_contains "$TEST_HOME/.bunfig.toml" "saveTextLockfile = true"
}

@test "bun: an older bun does not get the newer lockfile key" {
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.1.9" ;; *) echo "STUB" ;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  assert_file_lacks "$TEST_HOME/.bunfig.toml" "saveTextLockfile"
}

@test "bun: a version with fewer components still compares correctly" {
  # version_ge normalizes to three parts; "2" must read as 2.0.0, not fail.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "2" ;; *) echo "STUB" ;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  assert_file_contains "$TEST_HOME/.bunfig.toml" "saveTextLockfile = true"
}

@test "bun: an undetectable version falls forward, not silently backward" {
  # A tool whose --version fails must not quietly drop forward-compat keys.
  stub_bin bun 'exit 1'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  assert_file_contains "$TEST_HOME/.bunfig.toml" "saveTextLockfile = true"
}

# --- bunx ------------------------------------------------------------------

@test "bunx: wrapper is deployed alongside the bun wrapper" {
  stub_bin bun
  stub_bin bunx
  run harden ECOSYSTEMS=bun -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_BIN/bunx" "supply-chain-harden"
}

@test "bunx: injects --no-install so it cannot fetch-and-execute" {
  stub_bin bun
  stub_bin bunx
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run "$TEST_BIN/bunx" cowsay hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-install cowsay hello"* ]]
}

@test "bunx: preserves argv[0] as bunx, because bun dispatches on it" {
  # bun decides it is in bunx mode from argv[0]. A plain exec would run the
  # real binary in ordinary `bun` mode and silently change the meaning of
  # every bunx invocation.
  #
  # Asserted statically on purpose: `exec -a` cannot be observed through a
  # shell-script stub, because the kernel re-execs the interpreter and $0
  # becomes the script path regardless of the override. It works on a real
  # bun binary; verifying it here would only test the stub.
  stub_bin bun
  stub_bin bunx
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  assert_file_contains "$TEST_BIN/bunx" "exec -a bunx \"\$REAL_BUN\" --no-install"
  assert_file_lacks "$TEST_BIN/bunx" "^exec \"\$REAL_BUN\""
}

@test "bunx: points at the real bun binary, never at a bunx-real symlink" {
  # bunx is normally a symlink to bun; targeting bunx-real would resolve back
  # through it to the bun WRAPPER, re-injecting flags and losing argv[0].
  stub_bin bun
  stub_bin bunx
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  assert_file_contains "$TEST_BIN/bunx" "REAL_BUN='${TEST_BIN}/bun-real'"
  assert_file_lacks "$TEST_BIN/bunx" "bunx-real"
}

@test "bunx: metadata flags pass through without --no-install" {
  stub_bin bun
  stub_bin bunx
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run "$TEST_BIN/bunx" --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"--no-install"* ]]
}

@test "bunx: a metadata flag in FRONT of a package still gets --no-install" {
  # MEASURED on bun 1.4.3 and 1.4.4: `bunx --version cowsay hi` ignores the
  # flag and fetch-and-executes cowsay. Passing a leading metadata flag through
  # untouched made that a one-flag bypass; only the bare flag may skip it.
  stub_bin bun
  stub_bin bunx
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run "$TEST_BIN/bunx" --version cowsay hi
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-install --version cowsay hi"* ]]
}

@test "bunx: refuses to recurse when the real bun is gone" {
  stub_bin bun
  stub_bin bunx
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  rm -f "$(stub_real bun)"
  run -127 "$TEST_BIN/bunx" cowsay
  [ "$status" -eq 127 ]
  [[ "$output" == *"refusing to recurse"* ]]
}

@test "bunx: writing the wrapper executes nothing its comments mention" {
  # The wrapper body is an unquoted heredoc. A backticked `bunx --version
  # cowsay hi` in its comments once ran at harden time against whatever bunx
  # was next on PATH, and an unwrapped one fetch-and-executes cowsay.
  stub_bin bun
  stub_bin bunx
  mkdir -p "$BATS_TEST_TMPDIR/later"
  printf '#!/bin/bash\necho "$*" >> "%s/ran"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/later/bunx"
  chmod +x "$BATS_TEST_TMPDIR/later/bunx"
  harden PATH="${TEST_BIN}:${BATS_TEST_TMPDIR}/later:${PATH}" ECOSYSTEMS=bun -- --emit=plain >/dev/null
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "no wrapper heredoc expands a command while harden writes it" {
  run python3 "${BATS_TEST_DIRNAME}/heredoc-scan.py" "$HARDEN_SH"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the heredoc scan actually catches a command in an unquoted body" {
  # A checker that cannot fail is worse than none — it reads as coverage.
  cat > "$BATS_TEST_TMPDIR/h.sh" <<'FIXTURE'
cat <<EOF
# runs: `date`
EOF
cat <<'EOF'
# quoted delimiter, stays text: `date` $(date)
EOF
cat <<EOF
# escaped, stays text: \`date\` \$(date)
EOF
FIXTURE
  run python3 "${BATS_TEST_DIRNAME}/heredoc-scan.py" "$BATS_TEST_TMPDIR/h.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"h.sh:2:"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'expands at write time')" -eq 1 ]
}

@test "bunx-as-symlink: wrapping it does not clobber the bun wrapper" {
  # THE REAL LAYOUT. bunx ships as a symlink to bun, and after bun is wrapped
  # that link resolves to the bun WRAPPER. Writing the bunx wrapper with tee
  # followed the link and overwrote the bun wrapper, leaving one file that
  # injected --no-install into everything — `bun install` included. The log
  # still said both wrappers deployed successfully.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo "STUB:bun ARGS=[$*]";; esac'
  stub_symlink bunx bun
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null

  # bun install must NOT be given --no-install, or installs are broken.
  run "$TEST_BIN/bun" install
  [[ "$output" == *"ARGS=[install]"* ]] || {
    echo "bun install was mangled: $output"; return 1
  }
}

@test "bunx-as-symlink: bun runtime and bunx are both still hardened" {
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo "STUB:bun ARGS=[$*]";; esac'
  stub_symlink bunx bun
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null

  run "$TEST_BIN/bun" run script.ts
  [[ "$output" == *"--no-install run script.ts"* ]]
  run "$TEST_BIN/bunx" cowsay
  [[ "$output" == *"--no-install cowsay"* ]]
}

@test "bunx-as-symlink: the link is replaced by a regular file" {
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo "STUB:bun ARGS=[$*]";; esac'
  stub_symlink bunx bun
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  [ ! -L "$TEST_BIN/bunx" ]
  [ -f "$TEST_BIN/bunx" ]
  # And the two wrappers must be genuinely different files.
  run bash -c "cmp -s '$TEST_BIN/bun' '$TEST_BIN/bunx' && echo same || echo different"
  [ "$output" = "different" ]
}

# --- cargo -----------------------------------------------------------------

lockdir() { mkdir -p "$BATS_TEST_TMPDIR/proj/sub"; touch "$BATS_TEST_TMPDIR/proj/Cargo.lock"; echo "$BATS_TEST_TMPDIR/proj/sub"; }

@test "cargo: --locked is injected for a resolving subcommand" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' build"
  [[ "$output" == *"ARGS=[build --locked]"* ]]
}

@test "cargo: a leading global flag does not hide the subcommand" {
  # Reading argv[1] would treat -q as the subcommand and disable every control.
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' -q build"
  [[ "$output" == *"ARGS=[-q build --locked]"* ]]
}

@test "cargo: a value-taking global flag does not become the subcommand" {
  # `--color always build` must resolve to `build`, not to `always`.
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' --color always build"
  [[ "$output" == *"ARGS=[--color always build --locked]"* ]]
}

@test "cargo: a rustup toolchain override keeps its required first position" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' +nightly build"
  [[ "$output" == *"ARGS=[+nightly build --locked]"* ]]
}

@test "cargo: --locked lands before the -- separator, not in the user's program args" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' run -- myprog --flag"
  [[ "$output" == *"ARGS=[run --locked -- myprog --flag]"* ]]
}

@test "cargo: an explicit resolution flag is respected, not doubled" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' build --offline"
  [[ "$output" == *"ARGS=[build --offline]"* ]]
  [[ "$output" != *"--locked"* ]]
}

@test "cargo: lockfile lookup walks up from a workspace subdirectory" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  # The lockfile is two levels up from where cargo is invoked.
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' build"
  [[ "$output" == *"--locked"* ]]
}

@test "cargo: with no lockfile anywhere it warns instead of pretending" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/nolock"
  run bash -c "cd '$BATS_TEST_TMPDIR/nolock' && '$TEST_BIN/cargo' build 2>&1"
  [[ "$output" == *"no Cargo.lock found"* ]]
  [[ "$output" == *"ARGS=[build]"* ]]
}

@test "cargo: lockfile-writing subcommands are not given --locked" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' update 2>/dev/null"
  [[ "$output" == *"ARGS=[update]"* ]]
}

@test "cargo: an unknown subcommand passes through and says so" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' frobnicate 2>&1"
  [[ "$output" == *"not a recognised subcommand"* ]]
  [[ "$output" == *"ARGS=[frobnicate]"* ]]
}

@test "cargo: the re-entrancy guard stops cooldown recursing forever" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && SUPPLY_CHAIN_CARGO_WRAPPED=1 '$TEST_BIN/cargo' build"
  [[ "$output" == *"ARGS=[build]"* ]]
}

# A stub cargo that reports the cooldown environment it was handed, plus a
# cargo-cooldown where harden.sh looks for one, so builds route through it.
cooldown_stubs() {
  skip_if_root_stages_cooldown
  local ver="${1:-1.99.0}"
  stub_bin cargo 'case "${1:-}" in --version|-v) echo "cargo '"$ver"' (abc 2026-11-12)";; *) echo "STUB:cargo ARGS=[$*] MIN=${COOLDOWN_MINUTES-} CRATES=${CARGO_REGISTRY_MIN_PUBLISH_AGE-} NOW=${COOLDOWN_NOW-} SKIP=[${COOLDOWN_SKIP_REGISTRIES-unset}] GLOBAL=[${CARGO_REGISTRY_GLOBAL_MIN_PUBLISH_AGE-unset}] RESOLVER=[${CARGO_RESOLVER_INCOMPATIBLE_PUBLISH_AGE-unset}] TESTTIME=[${__CARGO_TEST_INVOCATION_TIME-unset}]";; esac'
  mkdir -p "$TEST_HOME/.cargo/bin"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_HOME/.cargo/bin/cargo-cooldown"
  chmod +x "$TEST_HOME/.cargo/bin/cargo-cooldown"
}

# ---- the gate backend: absolute path, never a PATH prepend, and whose it is ----
#
# MEASURED (VM#2; reproduced on Ubuntu 26.04 with apt cargo 1.93.1): the
# wrapper PREPENDED $CARGO_HOME/bin to PATH, so at a system path root and every
# other account ran the hardening user's cargo-cooldown and ~/.cargo/bin/cargo.

# cooldown_stubs plus a cargo stub that also prints the PATH it was given, and
# a pass-through sfw so a real one cannot change PATH under the test.
path_stubs() {
  cooldown_stubs
  stub_bin cargo 'case "${1:-}" in --version|-v) echo "cargo 1.99.0";; *) echo "STUB:cargo ARGS=[$*]"; echo "PATH=$PATH";; esac'
  stub_bin sfw 'exec "$@"'
}

@test "cargo-cooldown: the backend is named by absolute path and PATH is left alone" {
  path_stubs
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  grep -q "^COOLDOWN_EXE='$TEST_HOME/.cargo/bin/cargo-cooldown'\$" "$TEST_BIN/cargo"
  ! grep -q 'PATH="$COOLDOWN' "$TEST_BIN/cargo"
  # HOME as the user's own: cargo searches $CARGO_HOME/bin itself, so nothing changes.
  run bash -c "cd '$(lockdir)' && HOME='$TEST_HOME' PATH='$TEST_BIN:/usr/bin:/bin' '$TEST_BIN/cargo' build"
  [[ "$output" == *"ARGS=[cooldown build"* ]]
  [ "$(printf '%s\n' "$output" | sed -n 's/^PATH=//p')" = "$TEST_BIN:/usr/bin:/bin" ]
  # A caller whose CARGO_HOME is elsewhere: the backend's directory is APPENDED.
  run bash -c "cd '$(lockdir)' && HOME=/nonexistent PATH='$TEST_BIN:/usr/bin:/bin' '$TEST_BIN/cargo' build"
  [[ "$output" == *"ARGS=[cooldown build"* ]]
  [ "$(printf '%s\n' "$output" | sed -n 's/^PATH=//p')" = "$TEST_BIN:/usr/bin:/bin:$TEST_HOME/.cargo/bin" ]
}

@test "cargo-cooldown: a backend another account owns is refused" {
  [ "$(id -u)" != 0 ] || skip "the fixture needs a non-root caller"
  sudo -n true 2>/dev/null || skip "needs passwordless sudo to hand the backend to another account"
  path_stubs
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  # Another account owns the file, so that account can rewrite it, even though
  # it sits in this user's directory.
  chmod 755 "$TEST_HOME/.cargo/bin/cargo-cooldown" "$TEST_HOME/.cargo/bin"
  sudo chown 65534 "$TEST_HOME/.cargo/bin/cargo-cooldown"
  run bash -c "cd '$(lockdir)' && HOME='$TEST_HOME' '$TEST_BIN/cargo' build 2>&1"
  sudo rm -f "$TEST_HOME/.cargo/bin/cargo-cooldown"
  printf '%s\n' "$output"
  [ "$status" -eq 126 ]
  [[ "$output" == *"[supply-chain-harden] error: refusing to run the cargo publish-age gate backend"* ]]
  [[ "$output" == *"cargo-cooldown is not owned by root or by $(id -un)"* ]]
  [[ "$output" != *"STUB:cargo"* ]]
}

@test "cargo-cooldown: a root-owned backend in the caller's own directory is the caller's to run" {
  # Only this user and root can change what is in this user's directory, so
  # refusing a root-owned file there (`sudo cargo install` into ~/.cargo/bin)
  # was a false refusal. An earlier test here asserted that refusal.
  [ "$(id -u)" != 0 ] || skip "the fixture needs a non-root caller"
  sudo -n true 2>/dev/null || skip "needs passwordless sudo to hand the backend to root"
  path_stubs
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  chmod 755 "$TEST_HOME/.cargo/bin/cargo-cooldown" "$TEST_HOME/.cargo/bin"
  sudo chown 0 "$TEST_HOME/.cargo/bin/cargo-cooldown"
  run bash -c "cd '$(lockdir)' && HOME='$TEST_HOME' PATH='$TEST_BIN:/usr/bin:/bin' '$TEST_BIN/cargo' build 2>&1"
  sudo rm -f "$TEST_HOME/.cargo/bin/cargo-cooldown"
  printf '%s\n' "$output"
  [[ "$output" == *"ARGS=[cooldown build"* ]]
  [[ "$output" != *"refusing"* ]]
}

@test "cargo: a manifest newer than the lockfile gets a note naming the wrapper's --locked" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  d=$(lockdir)
  # -t, not -d: BSD touch on the macOS runners has no -d.
  touch -t 202001010000 "$BATS_TEST_TMPDIR/proj/Cargo.lock"
  : > "$BATS_TEST_TMPDIR/proj/Cargo.toml"
  run bash -c "cd '$d' && '$TEST_BIN/cargo' build 2>&1"
  [[ "$output" == *"ARGS=[build --locked]"* ]]
  [[ "$output" == *"[supply-chain-harden] note: this cargo wrapper adds --locked"* ]]
  [[ "$output" == *"cargo update --workspace"* ]]
  touch "$BATS_TEST_TMPDIR/proj/Cargo.lock"
  run bash -c "cd '$d' && '$TEST_BIN/cargo' build 2>&1"
  [[ "$output" != *"adds --locked"* ]]
}

@test "cargo-cooldown: the crates.io window, clock and skip list are pinned over the caller's" {
  # Each has a cooldown.toml form a committed repo file can set
  # ([registry] min-publish-age, now, skip_registries), and MEASURED on
  # cargo-cooldown 0.3.5 each built a fresh crate until the environment, which
  # outranks every file, was pinned.
  cooldown_stubs
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && CARGO_REGISTRY_MIN_PUBLISH_AGE=0 COOLDOWN_NOW=2099-01-01T00:00:00Z COOLDOWN_SKIP_REGISTRIES=crates-io '$TEST_BIN/cargo' build"
  [[ "$output" == *"ARGS=[cooldown build"* ]]
  [[ "$output" == *"MIN=2880 "* ]]
  [[ "$output" == *"CRATES=48 hours "* ]]
  [[ "$output" == *"SKIP=[]"* ]]
  [[ "$output" != *"NOW=2099"* ]]
}

@test "cargo-cooldown: commands it never sees keep the caller's native publish-age gate" {
  # Regression from v2.0.0. The environment was pinned for EVERY resolving or
  # writing command whenever cargo-cooldown was installed, which stripped
  # CARGO_REGISTRY_GLOBAL_MIN_PUBLISH_AGE from commands cargo-cooldown never
  # runs. MEASURED on cargo 1.100.0: generate-lockfile, tree and fetch then
  # resolved a version real cargo refused, and add wrote it.
  cooldown_stubs 1.100.0
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  for sub in generate-lockfile tree fetch add; do
    run bash -c "cd '$(lockdir)' && CARGO_REGISTRY_GLOBAL_MIN_PUBLISH_AGE='87600 hours' '$TEST_BIN/cargo' $sub 2>&1"
    [[ "$output" == *"GLOBAL=[87600 hours]"* ]] || { echo "$sub lost the caller's gate: $output"; return 1; }
    [[ "$output" != *"overriding caller"* ]]
  done
}

@test "cargo-cooldown: the routed path defers cargo's native gate to cargo-cooldown on 1.100+ only" {
  # MEASURED (cargo 1.100.0 + cargo-cooldown 0.3.5): cargo's native gate also
  # applied to cargo-cooldown's internal resolves and broke [[allow.exact]];
  # CARGO_RESOLVER_INCOMPATIBLE_PUBLISH_AGE=allow on the routed call fixed it,
  # and cargo-cooldown still denied. Older cargo warns about the setting.
  cooldown_stubs 1.100.0
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' build"
  [[ "$output" == *"ARGS=[cooldown build"* ]]
  [[ "$output" == *"RESOLVER=[allow]"* ]]
  cooldown_stubs 1.99.0
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && '$TEST_BIN/cargo' build"
  [[ "$output" == *"ARGS=[cooldown build"* ]]
  [[ "$output" == *"RESOLVER=[unset]"* ]]
}

@test "cargo: cargo's internal test clock is dropped on every path" {
  # __CARGO_TEST_INVOCATION_TIME=2099-... defeats cargo 1.100's native gate
  # (measured). Only cargo's own test suite needs it.
  cooldown_stubs 1.100.0
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && __CARGO_TEST_INVOCATION_TIME=2099-01-01T00:00:00Z '$TEST_BIN/cargo' tree 2>&1"
  [[ "$output" == *"TESTTIME=[unset]"* ]]
  run bash -c "cd '$(lockdir)' && __CARGO_TEST_INVOCATION_TIME=2099-01-01T00:00:00Z '$TEST_BIN/cargo' build 2>&1"
  [[ "$output" == *"TESTTIME=[unset]"* ]]
}

@test "cargo-cooldown: a per-registry window under a name bash cannot unset is refused" {
  cooldown_stubs
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$(lockdir)' && env 'CARGO_REGISTRIES_my-reg_MIN_PUBLISH_AGE=0' '$TEST_BIN/cargo' build"
  [ "$status" -eq 2 ]
  [[ "$output" == *"non-identifier name"* ]]
  [[ "$output" != *"STUB:cargo"* ]]
}

@test "cargo: a HARDLINKED rustup proxy gets an argv[0] shim, not a plain rename" {
  # RUSTUP_HARDLINK_PROXIES (and older rustup) make cargo a hardlink to rustup,
  # not a symlink. A plain rename leaves a file named cargo-real that rustup
  # rejects as an unknown proxy (MEASURED: every routed build failed).
  stub_bin rustup 'case "${1:-}" in --version|-v) echo "cargo 1.99.0";; *) echo "STUB:rustup ARGS=[$*]";; esac'
  ln "$TEST_BIN/rustup" "$TEST_BIN/cargo"
  cp "$TEST_BIN/rustup" "$BATS_TEST_TMPDIR/rustup.orig"
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  # The shim names the RESOLVED path. On macOS $TMPDIR is under /var, a symlink
  # to /private/var, so the unresolved $TEST_BIN never matches there.
  assert_file_contains "$TEST_BIN/cargo-real" "exec -a cargo \"$(cd "$TEST_BIN" && pwd -P)/rustup\""
  # And nothing was written into the shared inode.
  cmp -s "$TEST_BIN/rustup" "$BATS_TEST_TMPDIR/rustup.orig"
}

@test "cargo: refuses to recurse when the real binary is gone" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  rm -f "$(stub_real cargo)"
  run -127 "$TEST_BIN/cargo" build
  [ "$status" -eq 127 ]
  [[ "$output" == *"refusing to recurse"* ]]
}

# --- composer --------------------------------------------------------------

@test "composer: --no-scripts is injected on lifecycle invocations" {
  stub_bin composer
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run "$TEST_BIN/composer" install
  [[ "$output" == *"--no-scripts"* ]]
}

# MEASURED before this routing (composer 2.2.6 -> 2.11.2, this action's wrapper
# included): with --no-scripts injected, `composer test` exited 0 having run
# nothing and `composer run-script test` said 'Script "test" is not defined'.
composer_route_project() {
  have php || skip "php not installed (the wrapper reads composer.json with php)"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/sub"
  cat > "$PROJ/composer.json" <<'J'
{ "name": "t/t",
  "scripts": { "test": "echo t", "install": "echo x", "post-install-cmd": "echo p" },
  "scripts-aliases": { "test": ["t"] } }
J
  stub_bin composer
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
}

@test "composer: a root script run by name gets no --no-scripts" {
  composer_route_project
  local args
  for args in "test" "t" "run-script test" "run test" "-n test"; do
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && "$@"' _ "$PROJ" "$TEST_BIN/composer" $args
    [[ "$output" == *"STUB:composer"* ]] || { echo "'$args': $output"; return 1; }
    [[ "$output" != *"--no-scripts"* ]] || { echo "'$args' got --no-scripts: $output"; return 1; }
    [[ "$output" == *"--no-plugins"* ]] || { echo "'$args' lost --no-plugins: $output"; return 1; }
  done
  run bash -c 'cd / && "$1" -d "$2" test' _ "$TEST_BIN/composer" "$PROJ"
  [[ "$output" == *"STUB:composer"* && "$output" != *"--no-scripts"* ]]
  run bash -c 'cd "$2/sub" && "$1" test' _ "$TEST_BIN/composer" "$PROJ"
  [[ "$output" == *"STUB:composer"* && "$output" != *"--no-scripts"* ]]
}

@test "composer: a script named after a built-in, or an event, does not lift --no-scripts" {
  composer_route_project
  local args
  for args in "install" "post-install-cmd" "show" "nosuchscript" ""; do
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && "$@"' _ "$PROJ" "$TEST_BIN/composer" $args
    [[ "$output" == *"--no-scripts"* ]] || { echo "'$args' did not get --no-scripts: $output"; return 1; }
  done
}

# MEASURED on 2.7.1 and 2.11.2 (this action's wrapper included): a checkout
# defining scripts named after unique prefixes of built-ins (req, du, dump, up,
# upd, ins, rem) had them run, scripts enabled, on `composer req psr/log` and the
# rest, because composer resolves an exact command name before an abbreviation.
# A "scripts-aliases" alias spelled like a built-in ("i") ran in its place.
@test "composer: a script or alias that also names a built-in is refused, not run" {
  composer_route_project
  local hij="$BATS_TEST_TMPDIR/hijack" args
  mkdir -p "$hij"
  cat > "$hij/composer.json" <<'J'
{ "name": "t/h",
  "scripts": { "req": "echo h", "du": "echo h", "upd": "echo h", "check": "echo h", "foo": "echo h" },
  "scripts-aliases": { "foo": ["i", "upgrade"] } }
J
  for args in "req psr/log" "du" "upd" "check" "i" "upgrade"; do
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && "$@"' _ "$hij" "$TEST_BIN/composer" $args
    [ "$status" -eq 2 ] || { echo "'$args' exited $status: $output"; return 1; }
    [[ "$output" != *"STUB:composer"* ]] || { echo "'$args' reached composer: $output"; return 1; }
    [[ "$output" == *"[supply-chain-harden] refusing 'composer "* && "$output" == *"composer run-script "* ]] \
      || { echo "'$args' refusal does not name the control and the way out: $output"; return 1; }
  done
  run bash -c 'cd "$1" && "$2" run-script req' _ "$hij" "$TEST_BIN/composer"
  [[ "$output" == *"STUB:composer"* && "$output" != *"--no-scripts"* ]]
  # With no such script, the abbreviation is the built-in and keeps --no-scripts.
  run bash -c 'cd "$1" && "$2" req psr/log' _ "$PROJ" "$TEST_BIN/composer"
  [[ "$output" == *"STUB:composer"* && "$output" == *"--no-scripts"* ]]
}

@test "composer: in -nd DIR the DIR is a value, and composer does not change to it" {
  composer_route_project
  # MEASURED on 2.5.5, 2.7.1 and 2.11.2: `composer -nd DIR test` runs the test
  # script of the current directory; the wrapper took DIR for the subcommand.
  run bash -c 'cd "$2" && "$1" -nd /tmp test' _ "$TEST_BIN/composer" "$PROJ"
  [[ "$output" == *"STUB:composer"* && "$output" != *"--no-scripts"* ]]
  run bash -c 'cd / && "$1" -nd "$2" test' _ "$TEST_BIN/composer" "$PROJ"
  [[ "$output" == *"--no-scripts"* ]]
}

# composer <= 2.1 takes --no-scripts only on the commands that declare it, and
# resolves an alias or a unique prefix to the command itself. MEASURED on
# 6c77f4e with composer 2.1.14 behind the role's wrapper (the same body as
# this one): `req`, `upd`, `ins`, `dump` and `rem` got no --no-scripts and ran
# the root update and autoload-dump scripts.
@test "composer: on composer <= 2.1 an alias or unique prefix of a lifecycle command gets --no-scripts" {
  stub_bin composer 'case "${1:-}" in
  --version) echo "Composer version 2.1.14 2021-11-30 10:51:43" ;;
  *) echo "STUB:composer ARGS=[$*]" ;;
esac'
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  grep -q '^NO_SCRIPTS_IS_GLOBAL=false$' "$TEST_BIN/composer"
  local args d="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$d"
  for args in "install" "ins" "upd" "up" "upgrade" "req x/y" "rem x/y" "dump" "du" "cr a/b" "rei x/y" "UPD"; do
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && "$@"' _ "$d" "$TEST_BIN/composer" $args
    [[ "$output" == *"STUB:composer"* && "$output" == *"--no-scripts"* ]] || { echo "'$args': $output"; return 1; }
  done
  # Not on a command that does not declare it there, nor on an ambiguous name.
  for args in "show" "sh" "conf" "in" "re" "exec x"; do
    # shellcheck disable=SC2086
    run bash -c 'cd "$1" && shift && "$@"' _ "$d" "$TEST_BIN/composer" $args
    [[ "$output" == *"STUB:composer"* && "$output" != *"--no-scripts"* ]] || { echo "'$args': $output"; return 1; }
  done
}

@test "composer: --no-plugins is conditional on the input" {
  stub_bin composer
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run "$TEST_BIN/composer" install
  [[ "$output" == *"--no-plugins"* ]]
  stub_bin composer
  harden ECOSYSTEMS=composer COMPOSER_ALLOW_PLUGINS=true -- --emit=plain >/dev/null
  run "$TEST_BIN/composer" install
  [[ "$output" != *"--no-plugins"* ]]
}

@test "composer: the wrapper pins the publish-age window against the caller's env" {
  stub_bin composer 'case "${1:-}" in
  --version) echo "Composer version 2.11.1 2026-10-01 00:00:00" ;;
  *) echo "PERIOD=$COMPOSER_POLICY_COOLDOWN_PERIOD BLOCK=$COMPOSER_POLICY_COOLDOWN_BLOCK" ;;
esac'
  harden ECOSYSTEMS=composer RELEASE_AGE_HOURS=72 -- --emit=plain >/dev/null
  COMPOSER_POLICY_COOLDOWN_PERIOD=60 COMPOSER_POLICY_COOLDOWN_BLOCK=0 run "$TEST_BIN/composer" install
  [[ "$output" == *"PERIOD=259200 BLOCK=1"* ]]
}

@test "composer: config also lands in the home composer really reads, and composer is not asked which that is" {
  # `composer config --global home` writes into the home it is asked about (MEASURED:
  # config.json, auth.json, .htaccess and a cache directory, on 2.0.14).
  stub_bin composer "case \"\$*\" in
  *--version*) echo 'Composer version 2.11.1 2026-01-01 00:00:00' ;;
  *'config --global'*) touch '$BATS_TEST_TMPDIR/asked' ;;
  *) echo STUB ;;
esac"
  harden ECOSYSTEMS=composer COMPOSER_HOME="$TEST_HOME/elsewhere" -- --emit=plain >/dev/null
  cmp "$TEST_HOME/.config/composer/config.json" "$TEST_HOME/elsewhere/config.json"
  [ ! -e "$BATS_TEST_TMPDIR/asked" ]
}

@test "composer: config.json stays valid JSON with the policy block on every audit tier" {
  # The audit block changes shape at 2.7 and 2.9, and the comma before "policy"
  # is written by a different branch on each side of that.
  local v
  for v in 2.2.6 2.7.1 2.9.5 2.11.1; do
    stub_bin composer "echo 'Composer version $v 2026-01-01 00:00:00'"
    harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
    run node -e '
      const c = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).config;
      process.exit(c.policy.cooldown.period === 172800 ? 0 : 1);
    ' "$TEST_HOME/.config/composer/config.json"
    [ "$status" -eq 0 ] || { echo "composer $v wrote invalid config" >&2; return 1; }
  done
}

# --- cargo <-> socket firewall ---------------------------------------------

cargo_sfw_stubs() {
  stub_bin cargo 'case "${1:-}" in --version|-v) echo "cargo 1.80.0";; *) echo "STUB:cargo ARGS=[$*]";; esac'
  stub_bin sfw   'echo "SFW-WRAPPED: $*"'
  mkdir -p "$BATS_TEST_TMPDIR/proj"; touch "$BATS_TEST_TMPDIR/proj/Cargo.lock"
}

@test "cargo+sfw: registry-touching commands are routed through sfw" {
  # The role defaults cargo_socket_firewall on; the action had no equivalent,
  # so cargo was the one ecosystem where installing sfw bought nothing.
  # Explicit true: an sfw installed by an earlier step, not by intel.
  cargo_sfw_stubs
  harden ECOSYSTEMS=cargo CARGO_SOCKET_FIREWALL=true -- --emit=plain >/dev/null
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' build"
  [[ "$output" == *"SFW-WRAPPED"* ]]
  [[ "$output" == *"--locked"* ]]
}

@test "cargo+sfw: a lockfile-writing command is routed too" {
  # `cargo update` is the one resolution path --locked can never cover, so it
  # is the one that most needs the network filter.
  cargo_sfw_stubs
  harden ECOSYSTEMS=cargo CARGO_SOCKET_FIREWALL=true -- --emit=plain >/dev/null
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' update 2>/dev/null"
  [[ "$output" == *"SFW-WRAPPED"* ]]
}

@test "cargo+sfw: commands that touch no registry are NOT routed" {
  # Prefixing everything would put a network filter in front of `cargo fmt`,
  # which has nothing to inspect and only adds latency and a failure mode.
  cargo_sfw_stubs
  harden ECOSYSTEMS=cargo CARGO_SOCKET_FIREWALL=true -- --emit=plain >/dev/null
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' fmt"
  [[ "$output" != *"SFW-WRAPPED"* ]]
  [[ "$output" == *"ARGS=[fmt]"* ]]
}

@test "cargo+sfw: absent sfw is a no-op, not a broken cargo" {
  # A wrapper rendered with the sfw route must not hard-require sfw: it would
  # break every build on a runner where sfw went missing after hardening.
  stub_bin cargo 'case "${1:-}" in --version|-v) echo "cargo 1.80.0";; *) echo "STUB:cargo ARGS=[$*]";; esac'
  mkdir -p "$BATS_TEST_TMPDIR/proj2"; touch "$BATS_TEST_TMPDIR/proj2/Cargo.lock"
  harden ECOSYSTEMS=cargo CARGO_SOCKET_FIREWALL=true -- --emit=plain >/dev/null
  run bash -c "cd '$BATS_TEST_TMPDIR/proj2' && '$TEST_BIN/cargo' build"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGS=[build --locked]"* ]]
}

@test "cargo+sfw: the input can turn it off with sfw still installed" {
  cargo_sfw_stubs
  harden ECOSYSTEMS=cargo CARGO_SOCKET_FIREWALL=false -- --emit=plain >/dev/null
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' build"
  [[ "$output" != *"SFW-WRAPPED"* ]]
  [[ "$output" == *"--locked"* ]]
}

@test "cargo+sfw: the default follows intel, so intel: none renders no sfw route" {
  # Issue #29. It defaulted true on its own, so with the default intel: none
  # every wrapper was rendered to route through an sfw nothing installed, and
  # verify reported GAP PRESENT on every stock runner. sfw on PATH here proves
  # the route is absent from the wrapper, not merely skipped at runtime.
  cargo_sfw_stubs
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' build"
  [[ "$output" != *"SFW-WRAPPED"* ]]
  [[ "$output" == *"ARGS=[build --locked]"* ]]
  run grep -c '^  if \[ "true" = "true" \]' "$TEST_BIN/cargo"
  [ "$output" = "0" ]
}

@test "cargo+sfw: the default follows intel, so intel: sfw routes cargo" {
  cargo_sfw_stubs
  stub_bin npm 'case "$*" in "--version") echo "10.9.8" ;; *) echo "STUB" ;; esac'
  stub_bin node 'echo 22'
  harden ECOSYSTEMS=cargo INTEL=sfw -- --emit=plain >/dev/null
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' build"
  [[ "$output" == *"SFW-WRAPPED"* ]]
  [[ "$output" == *"--locked"* ]]
}

@test "cargo+sfw: a non-boolean cargo_socket_firewall is refused" {
  # Anything but the literal "true" rendered the route off, so a typo read as
  # "filtering on" and silently was not.
  run harden ECOSYSTEMS=cargo CARGO_SOCKET_FIREWALL=yes -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be true or false"* ]]
}

# --- deno ------------------------------------------------------------------

@test "deno: the age gate is injected for a fetching subcommand" {
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" run app.ts
  [[ "$output" == *"run --minimum-dependency-age=P2D app.ts"* ]]
}

@test "deno: a leading flag does not hide the subcommand" {
  # `deno -A run app.ts` is THE common form. Reading $1 as the subcommand
  # matched nothing here and ran with no age gate at all, silently.
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" -A run app.ts
  [[ "$output" == *"--minimum-dependency-age=P2D"* ]] || {
    echo "no age gate injected: $output"; return 1
  }
  [[ "$output" == *"-A run --minimum-dependency-age=P2D app.ts"* ]]
}

@test "deno: --quiet before the subcommand is handled too" {
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" --quiet run app.ts
  [[ "$output" == *"--minimum-dependency-age=P2D"* ]]
}

@test "deno: a value-taking global flag before the subcommand does not hide it" {
  # MEASURED on deno 2.9.8: `deno --log-level debug run app.ts` (and `-L debug`)
  # are accepted by deno. Before the value-flag skip, the scanner read "debug" as
  # the subcommand, missed the run case, and exec'd deno UNGATED. The space-
  # separated value is the hazard; `--log-level=debug` is one `-*` token and was
  # always fine.
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" --log-level debug run app.ts
  [[ "$output" == *"--minimum-dependency-age=P2D"* ]] || {
    echo "no age gate injected for 'deno --log-level debug run': $output"; return 1
  }
  run "$TEST_BIN/deno" -L debug run app.ts
  [[ "$output" == *"--minimum-dependency-age=P2D"* ]]
}

@test "deno: the flag lands after the subcommand, not after the script" {
  # Everything after the script path belongs to the script.
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" run app.ts --my-app-flag
  [[ "$output" == *"run --minimum-dependency-age=P2D app.ts --my-app-flag"* ]]
}

@test "deno: non-fetching subcommands are left alone" {
  # deno ERRORS when given --minimum-dependency-age on a subcommand that does
  # not accept it, so a too-wide list breaks commands rather than weakening
  # the gate. fmt and lint must pass through untouched.
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" fmt
  [[ "$output" != *"minimum-dependency-age"* ]]
  run "$TEST_BIN/deno" lint
  [[ "$output" != *"minimum-dependency-age"* ]]
}

@test "deno: task is NOT given the flag" {
  # `deno task` was in the injection list and is how most deno projects invoke
  # everything. If it rejects the flag, every task in the repo breaks.
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" task build
  [[ "$output" != *"minimum-dependency-age"* ]]
}

@test "deno: doc and publish are NOT given the flag (they break on it — deno 2.9.5)" {
  # MEASURED on deno 2.9.5 (found on an Omarchy/Arch host): `deno doc` parses
  # --minimum-dependency-age as a positional module path ("Module not found
  # …/--minimum-dependency-age=…") and `deno publish` rejects it — injecting
  # there BROKE both commands while `deno run` stayed correctly gated.
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" doc mod.ts
  [[ "$output" != *"minimum-dependency-age"* ]]
  run "$TEST_BIN/deno" publish
  [[ "$output" != *"minimum-dependency-age"* ]]
}

@test "deno: bare deno and --version pass through" {
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" --version
  [[ "$output" != *"minimum-dependency-age"* ]]
}

@test "deno: the age window follows release_age_hours" {
  stub_bin deno
  harden ECOSYSTEMS=deno RELEASE_AGE_HOURS=168 -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" run app.ts
  [[ "$output" == *"--minimum-dependency-age=P7D"* ]]
}

deno_stub_version() { # a deno stub that reports the given version
  stub_bin deno 'case "${1:-}" in --version|-V) echo "deno '"$1"' (stable, release, x86_64-unknown-linux-gnu)" ;; *) echo "STUB:deno ARGS=[$*]" ;; esac'
}

@test "deno: info gets the age flag only from 2.8.3 (2.8.2 rejects it)" {
  # MEASURED on deno 2.8.2: "error: unexpected argument
  # '--minimum-dependency-age' found" -- injecting it broke `deno info`.
  deno_stub_version 2.8.2
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" info npm:is-number
  [[ "$output" == *"ARGS=[info npm:is-number]"* ]]
  deno_stub_version 2.8.3
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" info npm:is-number
  [[ "$output" == *"ARGS=[info --minimum-dependency-age=P2D npm:is-number]"* ]]
}

@test "deno: x runs with --ignore-scripts on 2.9.3+ and is refused below" {
  # MEASURED on 2.7.14-2.9.8: `deno x` runs the package's lifecycle scripts
  # with no prompt, and nothing in the role stopped it; --ignore-scripts does
  # (2.9.3, 2.9.8).
  deno_stub_version 2.9.3
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" x npm:cowsay hi
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGS=[x --ignore-scripts npm:cowsay hi]"* ]]
  deno_stub_version 2.9.2
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  run "$TEST_BIN/deno" x npm:cowsay hi
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing 'deno x'"* ]]
  [[ "$output" != *"STUB:deno"* ]]
}

@test "deno: refuses to recurse when the real binary is gone" {
  stub_bin deno
  harden ECOSYSTEMS=deno -- --emit=plain >/dev/null
  sudo rm -f "$(stub_real deno)"
  run -127 "$TEST_BIN/deno" run app.ts
  [ "$status" -eq 127 ]
  [[ "$output" == *"refusing to recurse"* ]]
}

# --- socket firewall / npm -------------------------------------------------

sfw_stubs() {
  # An npm that reports a version and pretends the PINNED, script-less sfw
  # install succeeds, a node new enough to clear the >= 20 gate, and an sfw
  # whose warm-up (`sfw /bin/true`) succeeds by running its argument.
  stub_bin npm 'case "$*" in
  "install -g --ignore-scripts sfw@2.0.6") exit 0 ;;
  "--version") echo "10.9.8" ;;
  *) echo "STUB:npm ARGS=[$*]" ;;
esac'
  stub_bin node 'echo 22'
  stub_bin sfw 'exec "$@"'
}

@test "sfw: the wrapper lands on the npm PATH resolves, not a hardcoded path" {
  # It used to write unconditionally to /usr/local/bin/npm while treating
  # `command -v npm` as the real binary. On a setup-node runner (npm in the
  # toolcache, prepended to PATH) or any nvm/fnm host, the wrapper sat on a
  # path nothing reached — sfw-installed reported true and every install
  # bypassed it.
  sfw_stubs
  harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain >/dev/null
  assert_file_contains "$TEST_BIN/npm" "supply-chain-harden"
  [ -x "$(stub_real npm)" ]
}

@test "sfw: the wrapper delegates to the preserved binary" {
  sfw_stubs
  harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain >/dev/null
  run "$TEST_BIN/npm" install foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB:npm ARGS=[install foo]"* ]]
}

@test "sfw: re-running does not wrap the wrapper" {
  sfw_stubs
  harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain >/dev/null
  harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain >/dev/null
  run grep -c "supply-chain-harden" "$(stub_real npm)"
  [ "$output" = "0" ]
  run "$TEST_BIN/npm" --version
  [ "$output" = "10.9.8" ]
}

@test "sfw: refuses to recurse when the real npm is gone" {
  sfw_stubs
  harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain >/dev/null
  sudo rm -f "$(stub_real npm)"
  run -127 "$TEST_BIN/npm" install foo
  [ "$status" -eq 127 ]
  [[ "$output" == *"refusing to recurse"* ]]
}

@test "sfw: a node older than 20 is refused rather than half-applied" {
  stub_bin npm 'case "$*" in "--version") echo "10.9.8" ;; *) echo "STUB" ;; esac'
  stub_bin node 'echo 18'
  run harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"requires Node >= 20"* ]]
  assert_file_lacks "$TEST_BIN/npm" "supply-chain-harden"
  assert_file_contains "$OUT_FILE" "sfw_installed=false"
}

@test "sfw: a failed install does not leave a wrapper claiming success" {
  stub_bin npm 'case "$*" in
  "install -g --ignore-scripts sfw@2.0.6") exit 1 ;;
  "--version") echo "10.9.8" ;;
  *) echo "STUB" ;;
esac'
  stub_bin node 'echo 22'
  run harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw global install failed"* ]]
  assert_file_lacks "$TEST_BIN/npm" "supply-chain-harden"
  assert_file_contains "$OUT_FILE" "sfw_installed=false"
}

@test "sfw: a warm-up failure moves sfw aside and deploys no wrapper" {
  # MEASURED on sfw 2.0.6: on a cold cache with the GitHub API refused or
  # rate-limited, the shim exits 1 INSIDE the user's npm install, while this
  # script reported sfw installed. The warm-up surfaces that here instead.
  sfw_stubs
  stub_bin sfw 'echo "[sfw] Failed to prepare firewall binary" >&2; exit 1'
  run harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not prepare its firewall binary"* ]]
  [[ "$output" == *"Failed to prepare firewall binary"* ]]
  assert_file_lacks "$TEST_BIN/npm" "supply-chain-harden"
  assert_file_contains "$OUT_FILE" "sfw_installed=false"
  # Moved aside, so the cargo wrapper's `command -v sfw` guard fails too.
  [ ! -e "$TEST_BIN/sfw" ]
  [ -e "$TEST_BIN/sfw.broken" ]
  run "$TEST_BIN/npm" --version
  [ "$output" = "10.9.8" ]
}

@test "sfw: the npm install is pinned and runs no install scripts" {
  # The role pins sfw_version and passes --ignore-scripts (ECH-185); the
  # action floated sfw@2 with scripts on.
  sfw_stubs
  # The record path is baked in now: harden runs under `env -i`, so a
  # $TEST_TMP read at stub run time would be empty.
  local rec="$TEST_TMP/sfw-install-args"
  stub_bin npm 'case "$*" in
  "install -g --ignore-scripts sfw@2.0.6") echo "PINNED-INSTALL" > "'"$rec"'"; exit 0 ;;
  "install -g"*) echo "UNPINNED: $*" > "'"$rec"'"; exit 0 ;;
  "--version") echo "10.9.8" ;;
  *) echo "STUB:npm ARGS=[$*]" ;;
esac'
  harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain >/dev/null
  assert_file_contains "$TEST_TMP/sfw-install-args" "PINNED-INSTALL"
}

# --- sfw runs read-only ----------------------------------------------------
#
# sfw keeps its cache in its own package directory, root-owned after the root
# `npm install -g`, and by default rewrites .sfw-cache/next-check there once
# the last update check is an hour old. A non-root caller cannot, and sfw
# treats that as fatal. MEASURED (sfw 2.0.6, this action at 8281a6b, a
# non-root user, next-check backdated): npm, npx and cargo through sfw all
# failed with "[sfw] Failed to prepare firewall binary: EACCES ... next-check".
# SFW_SKIP_UPDATE_CHECK=1 runs the cached binary without writing. The stubs
# here record what sfw was handed.

@test "sfw: the npm, npx and cargo wrappers run sfw with SFW_SKIP_UPDATE_CHECK=1" {
  sfw_stubs
  stub_bin sfw 'echo "SFW SKIP=${SFW_SKIP_UPDATE_CHECK:-unset}"; exec "$@"'
  stub_bin npx
  cargo_sfw_stubs
  stub_bin sfw 'echo "SFW SKIP=${SFW_SKIP_UPDATE_CHECK:-unset}"; exec "$@"'
  harden ECOSYSTEMS=npm,cargo INSTALL_SFW=true -- --emit=plain >/dev/null
  run env PATH="$TEST_BIN:$PATH" "$TEST_BIN/npm" install foo
  [[ "$output" == *"SFW SKIP=1"* ]]
  [[ "$output" == *"STUB:npm ARGS=[install foo]"* ]]
  run env PATH="$TEST_BIN:$PATH" "$TEST_BIN/npx" cowsay
  [[ "$output" == *"SFW SKIP=1"* ]]
  [[ "$output" == *"STUB:npx"* ]]
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' build"
  [[ "$output" == *"SFW SKIP=1"* ]]
  [[ "$output" == *"--locked"* ]]
}

@test "sfw: the hardening-time user check runs sfw the way the wrappers will" {
  # An sfw that fails exactly as the real one does an hour after hardening:
  # for a non-root caller that has not set SFW_SKIP_UPDATE_CHECK. The user
  # check has to pass the variable, or it judges sfw by a call the wrappers
  # never make.
  [ "$(id -u)" != 0 ] || skip "the user check is only distinct from the root warm for a non-root caller"
  sfw_stubs
  stub_bin sfw 'if [ "$(id -u)" != 0 ] && [ -z "${SFW_SKIP_UPDATE_CHECK:-}" ]; then
  echo "[sfw] Failed to prepare firewall binary: EACCES: permission denied, open next-check" >&2; exit 1
fi
exec "$@"'
  run harden ECOSYSTEMS=npm INSTALL_SFW=true -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" != *"could not prepare its firewall binary"* ]]
  assert_file_contains "$TEST_BIN/npm" "supply-chain-harden"
  assert_file_contains "$OUT_FILE" "sfw_installed=true"
  run env PATH="$TEST_BIN:$PATH" "$TEST_BIN/npm" install foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB:npm ARGS=[install foo]"* ]]
}

@test "sfw: a cold sfw cache warns a non-root caller and passes through, for npm, npx and cargo" {
  # With nothing cached, sfw downloads the binary even with
  # SFW_SKIP_UPDATE_CHECK=1, and only root can create the cache (MEASURED:
  # "EACCES ... mkdir .sfw-cache"). A root reinstall of sfw leaves it cold.
  # The wrappers must say so in our name and run the tool unfiltered, as they
  # do when sfw is absent, rather than fail every call in sfw's words.
  [ "$(id -u)" != 0 ] || skip "root can fill the cache itself, so the guard does not apply"
  sfw_stubs
  stub_bin npx
  cargo_sfw_stubs
  # sfw laid out like a global npm install, so the wrappers can find its cache.
  local pkg="$BATS_TEST_TMPDIR/prefix/lib/node_modules/sfw"
  mkdir -p "$pkg/dist" "$pkg/.sfw-cache"
  printf '{"name":"sfw","version":"0.0.0"}\n' > "$pkg/package.json"
  printf '#!/bin/bash\necho SFW-STUB\nexec "$@"\n' > "$pkg/dist/sfw.mjs"
  chmod +x "$pkg/dist/sfw.mjs"
  stub_symlink sfw "$pkg/dist/sfw.mjs"
  ln -s "$pkg/dist/sfw.mjs" "$pkg/.sfw-cache/latest"
  harden ECOSYSTEMS=npm,cargo INSTALL_SFW=true -- --emit=plain >/dev/null
  assert_file_contains "$TEST_BIN/npm" "supply-chain-harden"
  # Warm: routed through sfw.
  run env PATH="$TEST_BIN:$PATH" "$TEST_BIN/npm" install foo
  [[ "$output" == *"SFW-STUB"* ]]
  # Cold, in a cache this account cannot write (root's, on a real host).
  rm -f "$pkg/.sfw-cache/latest"
  chmod a-w "$pkg/.sfw-cache"
  run env PATH="$TEST_BIN:$PATH" "$TEST_BIN/npm" install foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw has no firewall binary cached"* ]]
  [[ "$output" != *"SFW-STUB"* ]]
  [[ "$output" == *"STUB:npm ARGS=[install foo]"* ]]
  run env PATH="$TEST_BIN:$PATH" "$TEST_BIN/npx" cowsay
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw has no firewall binary cached"* ]]
  [[ "$output" == *"STUB:npx"* ]]
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' build 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw has no firewall binary cached"* ]]
  [[ "$output" != *"SFW-STUB"* ]]
  [[ "$output" == *"ARGS=[build --locked]"* ]]
  # Cold, but in a cache this account CAN write (its own sfw, or a run that
  # could not escalate): sfw downloads the binary itself, so it is used.
  chmod u+w "$pkg/.sfw-cache"
  run env PATH="$TEST_BIN:$PATH" "$TEST_BIN/npm" install foo
  [[ "$output" == *"SFW-STUB"* ]]
  [[ "$output" != *"sfw has no firewall binary cached"* ]]
  run bash -c "cd '$BATS_TEST_TMPDIR/proj' && PATH='$TEST_BIN:$PATH' '$TEST_BIN/cargo' build 2>&1"
  [[ "$output" == *"SFW-STUB"* ]]
}

# --- absence ---------------------------------------------------------------

@test "a missing tool is reported, not fatal, and the run continues" {
  # No stubs planted: nothing to wrap.
  run harden ECOSYSTEMS=bun,cargo,composer,npm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.npmrc" "ignore-scripts=true"
}

@test "test isolation: harden() wraps a pass-through in TEST_BIN, never a tool outside the test's directory" {
  # Tools outside BATS_TEST_TMPDIR, on PATH after TEST_BIN, the way
  # /usr/bin/composer is on a CI runner. Without shield_host_tools
  # (helpers.bash), harden.sh moved each to <name>-real in that directory and
  # wrote its wrapper in its place.
  local host="$BATS_FILE_TMPDIR/host-bin-$BATS_TEST_NUMBER" t oldpath="$PATH"
  mkdir -p "$host"
  for t in composer bun bunx cargo deno; do
    printf '#!/bin/bash\ncase "${1:-}" in --version|-v|version) echo "%s 9.9.9" ;; *) echo "HOST:%s ARGS=[$*]" ;; esac\n' "$t" "$t" > "$host/$t"
    chmod +x "$host/$t"
  done
  (cd "$host" && cksum composer bun bunx cargo deno) > "$BATS_TEST_TMPDIR/before"
  PATH="$host:$PATH"
  run harden ECOSYSTEMS=composer,bun,cargo,deno -- --emit=plain
  PATH="$oldpath"
  [ "$status" -eq 0 ]
  (cd "$host" && cksum composer bun bunx cargo deno) > "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ "$(ls "$host")" = "$(printf 'bun\nbunx\ncargo\ncomposer\ndeno')" ]
  # harden.sh did wrap: the stub in TEST_BIN, which still reaches the tool.
  assert_file_contains "$TEST_BIN/composer" "supply-chain-harden"
  run env PATH="$TEST_BIN:$host:$PATH" "$TEST_BIN/composer" show
  [[ "$output" == *"HOST:composer ARGS=["*"show"* ]]
}

# --- rustup proxies ----------------------------------------------------------

@test "cargo: no version probe lets a rustup proxy download a toolchain" {
  # On a rustup host cargo and rustc are proxies, and a bare `--version` downloads
  # the active toolchain when it is not installed. MEASURED on rustup 1.29.3 with a
  # toolchain named and a fresh HOME: harden.sh took 11 s and left 757 MB behind,
  # and on the macos-15 runner that happened once per test HOME until the disk was
  # full. Every version probe has to carry RUSTUP_AUTO_INSTALL=0. The stubs record
  # what each call was given.
  local log="$BATS_TEST_TMPDIR/rustup-env.log"
  stub_bin cargo "echo \"cargo auto=\${RUSTUP_AUTO_INSTALL:-unset} args=\$*\" >> '$log'; echo 'cargo 1.99.0 (stub)'"
  stub_bin rustc "echo \"rustc auto=\${RUSTUP_AUTO_INSTALL:-unset} args=\$*\" >> '$log'; echo 'rustc 1.99.0 (stub)'"
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  grep -q 'cargo auto=0 args=--version' "$log"       # harden.sh asked, guarded
  # The verifier only asks rustc when a lockfile is present and no backend is.
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  : > "$BATS_TEST_TMPDIR/proj/Cargo.lock"
  cd "$BATS_TEST_TMPDIR/proj"
  run verify_sourced --emit=plain
  grep -q 'rustc auto=0 args=--version' "$log"       # the verifier asked, guarded
  run grep -E 'auto=unset args=(--version|-V)' "$log"
  [ "$status" -ne 0 ] || { echo "unguarded: $output"; false; }
  # The role asks rustc the same question; it has to carry the guard too.
  run grep -nE 'cmd: .*(rustc|cargo) --version' "${BATS_TEST_DIRNAME}/../../tasks/cargo.yml"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\n'* ]] || { echo "more than one probe; check each: $output"; false; }
  [[ "$output" == *"RUSTUP_AUTO_INSTALL=0 "* ]]
}
