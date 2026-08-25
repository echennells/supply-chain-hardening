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

@test "bunx: refuses to recurse when the real bun is gone" {
  stub_bin bun
  stub_bin bunx
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  rm -f "$(stub_real bun)"
  run -127 "$TEST_BIN/bunx" cowsay
  [ "$status" -eq 127 ]
  [[ "$output" == *"refusing to recurse"* ]]
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

@test "cargo: refuses to recurse when the real binary is gone" {
  stub_bin cargo
  harden ECOSYSTEMS=cargo -- --emit=plain >/dev/null
  rm -f "$(stub_real cargo)"
  run -127 "$TEST_BIN/cargo" build
  [ "$status" -eq 127 ]
  [[ "$output" == *"refusing to recurse"* ]]
}

# --- composer --------------------------------------------------------------

@test "composer: --no-scripts is injected on every invocation" {
  stub_bin composer
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null
  run "$TEST_BIN/composer" install
  [[ "$output" == *"--no-scripts"* ]]
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

# --- absence ---------------------------------------------------------------

@test "a missing tool is reported, not fatal, and the run continues" {
  # No stubs planted: nothing to wrap.
  run harden ECOSYSTEMS=bun,cargo,composer,npm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.npmrc" "ignore-scripts=true"
}
