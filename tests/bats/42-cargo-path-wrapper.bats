#!/usr/bin/env bats
# Tests for the cargo PATH wrapper (cargo_path_wrapper: true).
#
# The wrapper is a first-invocation control: it injects --locked (there is no
# config or env route to it) and prefixes resolution-affecting commands with
# `cargo cooldown` / `sfw` when those are enabled. It is not an enforcement
# boundary — $CARGO, rust-toolchain.toml `path =` and RUSTC_WRAPPER all route
# around it — and it does not attempt to be one.
#
# TEST STRATEGY
#
# Dispatch tests run the ACTUAL DEPLOYED WRAPPER against a stub standing in for
# cargo, so they assert on the artifact the role installed rather than a
# re-render of the template. No network, no compile, no dependence on whether
# cargo-cooldown happens to exist on this host.

load setup

cargo_path() {
  # NOT `readlink -f`. rustup's ~/.cargo/bin/cargo is a symlink to the rustup
  # binary — a shared proxy for rustc, clippy and cargo — so resolving
  # canonically would point at a multiplexer. The role wraps the cargo path
  # itself, using the discovery order in tasks/cargo.yml.
  local p
  for p in "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo /usr/bin/cargo; do
    if [ -x "$p" ]; then echo "$p"; return 0; fi
  done
  command -v cargo
}

# $1 = "with-cooldown" | "without-cooldown"
make_probe() {
  PROBE_DIR="$(mktemp -d)"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' > "$PROBE_DIR/cargo-real"
  chmod +x "$PROBE_DIR/cargo-real"
  # Point the wrapper's embedded backend (COOLDOWN_EXE, an absolute path) at
  # PROBE_DIR, so THIS fixture controls whether cargo-cooldown is reachable. On
  # the rustup test image the rendered path holds a REAL cargo-cooldown, so
  # without this the `without-cooldown` probes would still find it and route to
  # `cooldown`, never exercising the --locked fallback. make_probe places a
  # cargo-cooldown in PROBE_DIR only for the with-cooldown case.
  sed -e "s|^REAL_CARGO=.*|REAL_CARGO='$PROBE_DIR/cargo-real'|" \
      -e "s|^COOLDOWN_EXE=.*|COOLDOWN_EXE='$PROBE_DIR/cargo-cooldown'|" \
      "$(cargo_path)" > "$PROBE_DIR/cargo"
  chmod +x "$PROBE_DIR/cargo"
  mkdir -p "$PROBE_DIR/proj"
  : > "$PROBE_DIR/proj/Cargo.lock"
  if [ "$1" = "with-cooldown" ]; then
    printf '#!/bin/sh\nexit 0\n' > "$PROBE_DIR/cargo-cooldown"
    chmod +x "$PROBE_DIR/cargo-cooldown"
  fi
}

probe() {
  ( cd "$PROBE_DIR/proj" && unset SUPPLY_CHAIN_CARGO_WRAPPED \
      && PATH="$PROBE_DIR:/usr/bin:/bin" "$PROBE_DIR/cargo" "$@" 2>/dev/null )
}
probe_err() {
  ( cd "$PROBE_DIR/proj" && unset SUPPLY_CHAIN_CARGO_WRAPPED \
      && PATH="$PROBE_DIR:/usr/bin:/bin" "$PROBE_DIR/cargo" "$@" 2>&1 >/dev/null )
}

teardown() {
  [ -n "${PROBE_DIR:-}" ] && rm -rf "$PROBE_DIR"
  apt_layout_teardown
  return 0
}

# ---- the wrapper must be valid shell ----
#
# A quoting error does not degrade gracefully here: the wrapper IS cargo, so an
# unparseable script means every cargo invocation dies with a bash syntax
# error. The deployed artifact is checked, not the template, so a bad render is
# caught too.

@test "cargo: the deployed wrapper is syntactically valid bash" {
  command -v cargo >/dev/null || skip "cargo not installed"
  run bash -n "$(cargo_path)"
  [ "$status" -eq 0 ]
}

# ---- deployment ----

@test "cargo: wrapper is deployed at the discovered cargo path" {
  command -v cargo >/dev/null || skip "cargo not installed"
  grep -q 'supply-chain-hardening' "$(cargo_path)"
}

@test "cargo: cargo-real is invokable and yields a real cargo" {
  command -v cargo >/dev/null || skip "cargo not installed"
  run "$(cargo_path)-real" --version
  [ "$status" -eq 0 ]
  [[ "$output" == cargo* ]]
}

# rustup dispatches on argv[0], so a backup named cargo-real is an "unknown
# proxy name" unless something restores the name. cargo hands subcommands its
# own path via $CARGO, so anything re-entering cargo hits this.
@test "cargo: cargo-real survives being invoked under its own name" {
  command -v cargo >/dev/null || skip "cargo not installed"
  run "$(cargo_path)-real" locate-project
  [[ "$output" != *"unknown proxy name"* ]]
}

@test "cargo: wrapper does not break cargo itself" {
  command -v cargo >/dev/null || skip "cargo not installed"
  run cargo --version
  [ "$status" -eq 0 ]
  [[ "$output" == cargo* ]]
}

# ---- THE regression: global flags before the subcommand ----
#
# The wrapper previously read the subcommand from argv[1]. `cargo -q build`
# therefore matched no case, fell through with NO controls and NO warning, and
# supply-chain-verify — which probed only the bare form — reported OK. `-q`,
# `--quiet` and `--color always` are ordinary Makefile and CI forms, so the
# bypass was correlated with unattended automation.
#
# The subcommand is the first NON-FLAG argument, as npm-wrapper.sh.j2 and
# deno-wrapper.sh.j2 determine it. Cargo needs one addition: five of its
# thirteen global flags take a value, which must be skipped or
# `cargo --color always build` resolves to the subcommand "always".

@test "cargo: -q before the subcommand does not bypass the controls" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [[ "$(probe -q build)" == *"cooldown build"* ]]
}

@test "cargo: --quiet before the subcommand does not bypass" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [[ "$(probe --quiet build)" == *"cooldown build"* ]]
}

@test "cargo: a value-taking global flag does not swallow the subcommand" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  # Naive first-non-flag parsing reads "always" as the subcommand here.
  [[ "$(probe --color always build)" == *"cooldown build"* ]]
}

@test "cargo: -v before the subcommand does not bypass" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [[ "$(probe -v build)" == *"cooldown build"* ]]
}

@test "cargo: flag-prefixed and bare forms reach the same decision" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  # Both must get --locked; only the leading flag differs.
  [[ "$(probe build)" == *"--locked"* ]]
  [[ "$(probe -q build)" == *"--locked"* ]]
}

# ---- argument order ----

@test "cargo: +toolchain stays first when the subcommand is rewritten" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  # rustup requires +toolchain as the FIRST argument. Rebuilding argv by
  # removing the subcommand and re-appending produced `cooldown build +nightly`,
  # which rustup rejects.
  [[ "$(probe +nightly build)" == "+nightly cooldown build" ]]
}

@test "cargo: +toolchain and a global flag both keep their positions" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [[ "$(probe +nightly -q build)" == "+nightly -q cooldown build" ]]
}

@test "cargo: short aliases are normalised for the gate" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [[ "$(probe b)" == *"cooldown build"* ]]
}

@test "cargo: --locked is inserted BEFORE -- so it reaches cargo not the program" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  [ "$(probe run -- myarg)" = "run --locked -- myarg" ]
}

@test "cargo: a user's own --locked after -- does not count as our flag" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  [ "$(probe run -- --locked)" = "run --locked -- --locked" ]
}

@test "cargo: explicit resolution flags are not duplicated" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  [ "$(probe build --offline)" = "build --offline" ]
  [ "$(probe build --locked)" = "build --locked" ]
  [ "$(probe build --frozen)" = "build --frozen" ]
}

# ---- unknown subcommands: warn, never silently pass ----
#
# The subcommand set is open — any cargo-* on PATH, plus repo-local [alias].
# Enumerating it cannot converge, so the wrapper says what it is doing instead.

@test "cargo: a third-party subcommand is passed through with a note" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [ "$(probe nextest run)" = "nextest run" ]
  [[ "$(probe_err nextest run)" == *"not a recognised subcommand"* ]]
}

@test "cargo: --locked is NOT injected into unknown subcommands" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  # `cargo watch -x check` would break if we injected a flag it does not accept.
  [[ "$(probe watch -x check)" != *"--locked"* ]]
}

@test "cargo: an unprotected build says so instead of failing open silently" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  rm -f "$PROBE_DIR/proj/Cargo.lock"
  # No lockfile and no gate means no protection at all. A silent pass-through
  # and a protected build must not look identical at the terminal.
  [[ "$(probe_err build)" == *"no Cargo.lock found"* ]]
}

# ---- install and lockfile writers ----

@test "cargo: install gets --locked and an honest note about age" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  [ "$(probe install ripgrep)" = "install --locked ripgrep" ]
  # The previous 112-line crates.io age check was inert for binary-only crates
  # and failed open on any network or interpreter problem. A deliberate,
  # interactive command gets an accurate line rather than a control that only
  # looks like one.
  [[ "$(probe_err install ripgrep)" == *"not age-gated"* ]]
}

@test "cargo: lockfile writers do not get --locked (it is contradictory)" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  [[ "$(probe update)" != *"--locked"* ]]
  [[ "$(probe add somecrate)" != *"--locked"* ]]
}

@test "cargo: update routes through the gate when it exists" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  # `cargo update` is the one resolution path --locked can never cover.
  [ "$(probe update)" = "cooldown update" ]
}

# ---- guards ----

@test "cargo: non-resolving subcommands pass through untouched" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [ "$(probe new mycrate)" = "new mycrate" ]
  [ "$(probe --version)" = "--version" ]
  [ "$(probe clean)" = "clean" ]
}

@test "cargo: cooldown and binstall pass through (no recursion)" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [ "$(probe cooldown build)" = "cooldown build" ]
  [ "$(probe binstall foo)" = "binstall foo" ]
}

@test "cargo: re-entrancy guard stops the cooldown->cargo->cooldown loop" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  run bash -c "cd '$PROBE_DIR/proj' && SUPPLY_CHAIN_CARGO_WRAPPED=1 PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build"
  [ "$output" = "build" ]
}

@test "cargo: recursion guard refuses when cargo-real is missing" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  sed "s|^REAL_CARGO=.*|REAL_CARGO='/nonexistent/cargo'|" "$PROBE_DIR/cargo" > "$PROBE_DIR/bad"
  chmod +x "$PROBE_DIR/bad"
  run "$PROBE_DIR/bad" build
  [ "$status" -eq 127 ]
}

# ---- the gate backend: absolute path, never a PATH prepend, and whose it is ----
#
# BUG 1 (apt-cargo reachability) was first fixed by PREPENDING $CARGO_HOME/bin
# to PATH, and an earlier test here asserted that prepend. On a SYSTEM-path
# cargo (apt's /usr/bin/cargo) that put the deploying user's home in front of
# root and every other account. MEASURED (VM#2, reproduced on Ubuntu 26.04 with
# apt cargo 1.93.1 and cargo-cooldown 0.3.5): `sudo -H cargo build` and a second
# account's build ran the deployer's cargo-cooldown and ~/.cargo/bin/cargo, and
# a second account's apply re-rendered the wrapper so the first account's
# builds went ungated. The wrapper now names the backend by absolute path,
# never prepends, appends the backend's directory only when cargo would not
# otherwise find it, and refuses a backend whose owner is neither the caller
# nor root.

# Stub cargo-real that also reports the PATH it was started with, plus a
# pass-through sfw first on PATH: the wrapper prefixes network commands with
# sfw when it is installed (it is, in the test image), and the real one may
# change PATH itself, which is not what these tests are about.
path_probe() {
  printf '#!/bin/sh\nprintf "%%s\\n" "$*"\nprintf "PATH=%%s\\n" "$PATH"\n' > "$PROBE_DIR/cargo-real"
  printf '#!/bin/sh\nexec "$@"\n' > "$PROBE_DIR/sfw"
  chmod +x "$PROBE_DIR/cargo-real" "$PROBE_DIR/sfw"
}

@test "cargo: the wrapper names its gate backend by absolute path" {
  command -v cargo >/dev/null || skip "cargo not installed"
  run grep -E "^COOLDOWN_EXE='/.+/cargo-cooldown'" "$(cargo_path)"
  [ "$status" -eq 0 ]
  # The prepend that ran the deployer's binaries for everyone must be gone.
  ! grep -q 'PATH="$COOLDOWN' "$(cargo_path)"
}

@test "cargo: a gated build leaves the caller's PATH order alone" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  path_probe
  out=$(probe build)
  [[ "$out" == *"cooldown build"* ]]
  # probe() runs with PATH="$PROBE_DIR:/usr/bin:/bin"; the backend's directory
  # is already on it, so nothing may be added in front or behind.
  [[ "$out" == *"PATH=$PROBE_DIR:/usr/bin:/bin"* ]]
}

@test "cargo: a backend directory cargo would not search is appended, never prepended" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  path_probe
  mkdir -p "$PROBE_DIR/backend"
  printf '#!/bin/sh\nexit 0\n' > "$PROBE_DIR/backend/cargo-cooldown"
  chmod +x "$PROBE_DIR/backend/cargo-cooldown"
  sed -i "s|^COOLDOWN_EXE=.*|COOLDOWN_EXE='$PROBE_DIR/backend/cargo-cooldown'|" "$PROBE_DIR/cargo"
  out=$(probe build)
  [[ "$out" == *"cooldown build"* ]]
  [[ "$out" == *"PATH=$PROBE_DIR:/usr/bin:/bin:$PROBE_DIR/backend"* ]]
}

# ---- the root-owned backend copy on an apt-style cargo (a fresh install) ----
#
# A cargo outside every home (apt's /usr/bin/cargo) is wrapped for root and for
# every account, so tasks/cargo.yml copies the deploying user's pinned
# cargo-cooldown to a root-owned /usr/local/libexec copy and the wrapper names
# that, never the deployer's ~/.cargo/bin. Until this test only the upgrade
# path in 40-upgrade-convergence.bats reached that copy: the image's cargo is
# rustup's, in /root/.cargo/bin, so the build-time apply never wraps a system
# path. Here the layout is built by hand: the toolchain's real cargo binary at
# /usr/bin/cargo (Ubuntu 24.04's apt cargo, 1.75, is too old to build the
# backend, so a real apt cargo would only exercise the degraded path), and a
# deploying account with the pinned cargo-cooldown in its CARGO_HOME and no
# cargo of its own there, so discovery picks /usr/bin/cargo. The apply runs as
# root with that account's HOME, like the per-user config tests in 25-*.
APT_LAYOUT=""
APT_BACKEND_DIR=/usr/local/libexec/supply-chain-hardening
apt_layout_teardown() {
  [ -n "$APT_LAYOUT" ] || return 0
  rm -f /usr/bin/cargo /usr/bin/cargo-real /tmp/marker-cargodev-cooldown-ran
  case "$APT_LAYOUT" in *backend*) rm -rf "$APT_BACKEND_DIR" ;; esac
  id cargodev >/dev/null 2>&1 && userdel -r cargodev >/dev/null 2>&1
  APT_LAYOUT=""
}

@test "cargo: on a system-path cargo, root's build runs the root-owned backend copy and never the deployer's own" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  require_root "writes /usr/bin/cargo and adds an account"
  local pin sysroot have p ch
  pin=$(sed -n 's/^cargo_cooldown_version: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$ROLE_DIR/defaults/main.yml" | head -1)
  have=$("$HOME/.cargo/bin/cargo-cooldown" --version 2>/dev/null | awk '{print $NF}')
  [ -n "$pin" ] && [ "$have" = "$pin" ] || skip "no cargo-cooldown $pin in ~/.cargo/bin to stand in for the deployer's build"
  [ ! -e /usr/bin/cargo ] && [ ! -e /usr/bin/cargo-real ] || skip "a cargo is already installed at /usr/bin"
  [ ! -e /usr/local/bin/cargo ] || skip "discovery would pick /usr/local/bin/cargo first"
  [ ! -e "$APT_BACKEND_DIR" ] || skip "$APT_BACKEND_DIR already exists"
  sysroot=$(RUSTUP_AUTO_INSTALL=0 rustc --print sysroot 2>/dev/null)
  [ -x "$sysroot/bin/cargo" ] && [ -x "$sysroot/bin/rustc" ] || skip "no real cargo/rustc binaries in the toolchain"
  APT_LAYOUT=cargo,backend
  install -m 0755 "$sysroot/bin/cargo" /usr/bin/cargo
  id cargodev >/dev/null 2>&1 || useradd -m -s /bin/bash cargodev
  install -d -o cargodev -g cargodev /home/cargodev/.cargo /home/cargodev/.cargo/bin
  install -m 0755 -o cargodev -g cargodev "$HOME/.cargo/bin/cargo-cooldown" /home/cargodev/.cargo/bin/cargo-cooldown

  cd "$ROLE_DIR"
  run env HOME=/home/cargodev CARGO_HOME=/home/cargodev/.cargo \
    ansible-playbook site.yml --connection=local --limit localhost \
      --tags cargo -e podman_enabled=false -e verify_protections=false
  echo "$output" | grep -E 'fatal|FAILED|gate backend|PLAY RECAP' -A1 | head -20
  [ "$status" -eq 0 ]
  # The wrapper went to the system path and names the root-owned copy, which is
  # the deployer's pinned build, byte for byte, and nothing in the deployer's home.
  grep -q 'supply-chain-hardening' /usr/bin/cargo
  grep -qx "COOLDOWN_EXE='$APT_BACKEND_DIR/cargo/cargo-cooldown'" /usr/bin/cargo
  if grep -q '/home/cargodev' /usr/bin/cargo; then echo "the wrapper names the deployer's home"; return 1; fi
  [ "$(stat -c '%U %a' "$APT_BACKEND_DIR/cargo/cargo-cooldown")" = "root 755" ]
  [ "$(stat -c '%U %a' "$APT_BACKEND_DIR/cargo")" = "root 755" ]
  cmp "$APT_BACKEND_DIR/cargo/cargo-cooldown" "$HOME/.cargo/bin/cargo-cooldown"

  # The deployer's own binary becomes one that must never run as root.
  printf '#!/bin/sh\ntouch /tmp/marker-cargodev-cooldown-ran\nexit 1\n' > /home/cargodev/.cargo/bin/cargo-cooldown
  chown cargodev:cargodev /home/cargodev/.cargo/bin/cargo-cooldown
  rm -f /tmp/marker-cargodev-cooldown-ran
  p="$BATS_TEST_TMPDIR/aptproj"; ch="$BATS_TEST_TMPDIR/aptcargohome"
  mkdir -p "$p/src" "$ch"
  printf '[package]\nname = "aptproj"\nversion = "0.1.0"\nedition = "2021"\n' > "$p/Cargo.toml"
  echo 'fn main() {}' > "$p/src/main.rs"
  # Root's own CARGO_HOME and PATH hold no cargo-cooldown, so the copy the
  # wrapper appends to PATH is the only one cargo can start.
  local clean=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  ( cd "$p" && env CARGO_HOME="$ch" RUSTC="$sysroot/bin/rustc" PATH="$clean" /usr/bin/cargo-real generate-lockfile --offline )

  # FIXTURE CONTROL: cargo does start the deployer's binary when it can reach it.
  run bash -c 'cd "$1" && env CARGO_HOME="$2" RUSTC="$3" PATH="/home/cargodev/.cargo/bin:$4" /usr/bin/cargo-real cooldown build --offline' \
    _ "$p" "$ch" "$sysroot/bin/rustc" "$clean"
  [ -e /tmp/marker-cargodev-cooldown-ran ] || { echo "the planted cargo-cooldown never ran even when reachable: $output"; return 1; }
  rm -f /tmp/marker-cargodev-cooldown-ran

  run bash -c 'cd "$1" && env CARGO_HOME="$2" RUSTC="$3" PATH="$4" /usr/bin/cargo build --offline 2>&1' \
    _ "$p" "$ch" "$sysroot/bin/rustc" "$clean"
  echo "$output" | tail -8
  [ "$status" -eq 0 ]
  # cargo-cooldown ran (its own line), and it was not the deployer's.
  [[ "$output" == *"cooled down"* ]]
  [ ! -e /tmp/marker-cargodev-cooldown-ran ]
}

@test "cargo: a backend owned by another account is refused, attributably, and never run" {
  command -v cargo >/dev/null || skip "cargo not installed"
  [ "$(id -u)" = 0 ] || skip "needs root to give the backend to another account"
  make_probe with-cooldown
  printf '#!/bin/sh\ntouch "%s/backend-ran"\nexit 0\n' "$PROBE_DIR" > "$PROBE_DIR/cargo-cooldown"
  chown 65534 "$PROBE_DIR/cargo-cooldown"
  run bash -c "cd '$PROBE_DIR/proj' && unset SUPPLY_CHAIN_CARGO_WRAPPED && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>&1"
  [ "$status" -eq 126 ]
  [[ "$output" == *"[supply-chain-hardening] error: refusing to run the cargo publish-age gate backend"* ]]
  [[ "$output" == *"not owned by root"* ]]
  # Neither the backend nor cargo ran: not a quiet degrade to --locked.
  [ ! -e "$PROBE_DIR/backend-ran" ]
  [[ "$output" != *"--locked"* ]]
  [[ "$output" != *"cooldown build"* ]]
}

@test "cargo: a root-owned backend in a directory another account can write is refused" {
  command -v cargo >/dev/null || skip "cargo not installed"
  [ "$(id -u)" = 0 ] || skip "needs root to stage another account's directory"
  make_probe without-cooldown
  mkdir -p "$PROBE_DIR/theirs"
  printf '#!/bin/sh\nexit 0\n' > "$PROBE_DIR/theirs/cargo-cooldown"
  chmod 755 "$PROBE_DIR/theirs/cargo-cooldown"
  chown 65534 "$PROBE_DIR/theirs"
  sed -i "s|^COOLDOWN_EXE=.*|COOLDOWN_EXE='$PROBE_DIR/theirs/cargo-cooldown'|" "$PROBE_DIR/cargo"
  run bash -c "cd '$PROBE_DIR/proj' && unset SUPPLY_CHAIN_CARGO_WRAPPED && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>&1"
  [ "$status" -eq 126 ]
  [[ "$output" == *"directory $PROBE_DIR/theirs is not owned by root"* ]]
}

@test "cargo: another account may run a root-owned backend" {
  command -v cargo >/dev/null || skip "cargo not installed"
  [ "$(id -u)" = 0 ] || skip "needs root to run as another account"
  command -v setpriv >/dev/null || skip "setpriv not installed"
  make_probe with-cooldown
  chmod 755 "$PROBE_DIR"
  chown -R 65534 "$PROBE_DIR/proj"
  run setpriv --reuid=65534 --regid=65534 --clear-groups bash -c \
    "cd '$PROBE_DIR/proj' && unset SUPPLY_CHAIN_CARGO_WRAPPED && HOME=/nonexistent PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>&1"
  [[ "$output" == *"cooldown build"* ]]
  [[ "$output" != *"refusing"* ]]
}

@test "cargo: a root-owned backend in the caller's own directory is the caller's to run" {
  # Only the caller (and root) can change what is in a directory the caller
  # owns, so refusing there was a false refusal. Root still refuses it: that
  # directory's owner could swap the file.
  command -v cargo >/dev/null || skip "cargo not installed"
  [ "$(id -u)" = 0 ] || skip "needs root to stage another account's directory"
  command -v setpriv >/dev/null || skip "setpriv not installed"
  make_probe without-cooldown
  chmod 755 "$PROBE_DIR"
  mkdir -p "$PROBE_DIR/own"
  printf '#!/bin/sh\nexit 0\n' > "$PROBE_DIR/own/cargo-cooldown"
  chmod 755 "$PROBE_DIR/own/cargo-cooldown"
  chown 65534 "$PROBE_DIR/own"
  chown -R 65534 "$PROBE_DIR/proj"
  sed -i "s|^COOLDOWN_EXE=.*|COOLDOWN_EXE='$PROBE_DIR/own/cargo-cooldown'|" "$PROBE_DIR/cargo"
  run setpriv --reuid=65534 --regid=65534 --clear-groups bash -c \
    "cd '$PROBE_DIR/proj' && unset SUPPLY_CHAIN_CARGO_WRAPPED && HOME=/nonexistent PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>&1"
  [[ "$output" == *"cooldown build"* ]]
  [[ "$output" != *"refusing"* ]]
  run bash -c "cd '$PROBE_DIR/proj' && unset SUPPLY_CHAIN_CARGO_WRAPPED && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>&1"
  [ "$status" -eq 126 ]
  [[ "$output" == *"directory $PROBE_DIR/own is not owned by root"* ]]
}

@test "cargo: a backend another account owns is refused even in the caller's own directory" {
  command -v cargo >/dev/null || skip "cargo not installed"
  [ "$(id -u)" = 0 ] || skip "needs root to stage other accounts' files"
  command -v setpriv >/dev/null || skip "setpriv not installed"
  make_probe without-cooldown
  chmod 755 "$PROBE_DIR"
  mkdir -p "$PROBE_DIR/own"
  printf '#!/bin/sh\ntouch "%s/backend-ran"\nexit 0\n' "$PROBE_DIR/own" > "$PROBE_DIR/own/cargo-cooldown"
  chmod 755 "$PROBE_DIR/own/cargo-cooldown"
  chown 1 "$PROBE_DIR/own/cargo-cooldown"
  chown 65534 "$PROBE_DIR/own"
  chown -R 65534 "$PROBE_DIR/proj"
  sed -i "s|^COOLDOWN_EXE=.*|COOLDOWN_EXE='$PROBE_DIR/own/cargo-cooldown'|" "$PROBE_DIR/cargo"
  run setpriv --reuid=65534 --regid=65534 --clear-groups bash -c \
    "cd '$PROBE_DIR/proj' && unset SUPPLY_CHAIN_CARGO_WRAPPED && HOME=/nonexistent PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>&1"
  [ "$status" -eq 126 ]
  [[ "$output" == *"cargo-cooldown is not owned by root or by "* ]]
  [ ! -e "$PROBE_DIR/own/backend-ran" ]
}

@test "cargo: a command that never runs the backend is not refused over it" {
  command -v cargo >/dev/null || skip "cargo not installed"
  [ "$(id -u)" = 0 ] || skip "needs root to give the backend to another account"
  make_probe with-cooldown
  chown 65534 "$PROBE_DIR/cargo-cooldown"
  # `cargo add` only warns about the gate; `cargo fmt` never touches it.
  run bash -c "cd '$PROBE_DIR/proj' && unset SUPPLY_CHAIN_CARGO_WRAPPED && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' add serde 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"add serde"* ]]
  run bash -c "cd '$PROBE_DIR/proj' && unset SUPPLY_CHAIN_CARGO_WRAPPED && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' fmt 2>&1"
  [ "$status" -eq 0 ]
}

# ---- --locked is ours, so it is attributed when it bites ----
#
# After a Cargo.toml edit, cargo stops with "--locked was passed to prevent
# this", naming a flag the caller never typed (VM test report, section 6).

@test "cargo: a manifest newer than the lockfile gets a note naming the wrapper's --locked" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  touch -d '2020-01-01' "$PROBE_DIR/proj/Cargo.lock"
  : > "$PROBE_DIR/proj/Cargo.toml"
  err=$(probe_err build)
  [[ "$err" == *"[supply-chain-hardening] note: this cargo wrapper adds --locked"* ]]
  [[ "$err" == *"cargo update --workspace"* ]]
  [[ "$(probe build)" == *"build --locked"* ]]
}

@test "cargo: no --locked note when the lockfile is newer than the manifest" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  touch -d '2020-01-01' "$PROBE_DIR/proj/Cargo.toml"
  touch "$PROBE_DIR/proj/Cargo.lock"
  err=$(probe_err build)
  [[ "$err" != *"adds --locked"* ]]
}

# ---- the gate config ----

cargo_home_dir() { echo "${CARGO_HOME:-$HOME/.cargo}"; }

@test "cargo: cooldown.toml is deployed at CARGO_HOME with a non-zero window" {
  [ -f "$(cargo_home_dir)/cooldown.toml" ] || skip "cooldown gate not enabled"
  run grep -E 'global-min-publish-age' "$(cargo_home_dir)/cooldown.toml"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ =[[:space:]]*\"0 ]]
}

@test "cargo: cooldown violations deny rather than fall back" {
  [ -f "$(cargo_home_dir)/cooldown.toml" ] || skip "cooldown gate not enabled"
  grep -qE 'incompatible-publish-age[[:space:]]*=[[:space:]]*"deny"' "$(cargo_home_dir)/cooldown.toml"
}

# ---- sfw runs read-only ----
#
# sfw's cache is root-owned, and by default sfw rewrites .sfw-cache/next-check
# there once the last update check is an hour old. A non-root caller cannot,
# and sfw treats that as fatal: VM#1 measured every non-root cargo build
# failing with "[sfw] Failed to prepare firewall binary: EACCES ... next-check"
# one hour after each apply. The wrapper must run sfw with
# SFW_SKIP_UPDATE_CHECK=1, and must not hand a non-root caller to an sfw whose
# cache is cold (only root can fill it).

# An sfw laid out like a global npm install (bin -> lib/node_modules/sfw/dist),
# so the wrapper can find its cache. The stub reports the variable and runs
# the command it was given.
make_sfw_pkg() {
  local pkg="$PROBE_DIR/lib/node_modules/sfw"
  mkdir -p "$pkg/dist" "$pkg/.sfw-cache"
  printf '{"name":"sfw","version":"0.0.0"}\n' > "$pkg/package.json"
  printf '#!/bin/sh\necho "SFW-STUB SKIP=${SFW_SKIP_UPDATE_CHECK:-unset}"\nexec "$@"\n' > "$pkg/dist/sfw.mjs"
  chmod +x "$pkg/dist/sfw.mjs"
  ln -s "$pkg/dist/sfw.mjs" "$PROBE_DIR/sfw"
  SFW_CACHE_DIR="$pkg/.sfw-cache"
}

@test "cargo+sfw: the wrapper runs sfw with SFW_SKIP_UPDATE_CHECK=1" {
  command -v cargo >/dev/null || skip "cargo not installed"
  grep -q 'pfx="sfw"' "$(cargo_path)" || skip "wrapper rendered without the sfw route (cargo_socket_firewall=false)"
  make_probe without-cooldown
  make_sfw_pkg
  ln -s "$PROBE_DIR/cargo-real" "$SFW_CACHE_DIR/latest"
  run probe fetch
  echo "$output"
  [[ "$output" == *"SFW-STUB SKIP=1"* ]]
  [[ "$output" == *"fetch --locked"* ]]
}

@test "cargo+sfw: a cold sfw cache warns a non-root caller and runs cargo, instead of failing in sfw" {
  command -v cargo >/dev/null || skip "cargo not installed"
  [ "$(id -u)" = 0 ] || skip "needs root to run the probe as another account"
  grep -q 'pfx="sfw"' "$(cargo_path)" || skip "wrapper rendered without the sfw route (cargo_socket_firewall=false)"
  make_probe without-cooldown
  make_sfw_pkg
  chmod -R a+rX "$PROBE_DIR"
  run su -s /bin/bash nobody -c "cd '$PROBE_DIR/proj' && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' fetch 2>&1"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw has no firewall binary cached"* ]]
  [[ "$output" != *"SFW-STUB"* ]]
  [[ "$output" == *"fetch --locked"* ]]
  # Warm: the same caller is routed through sfw.
  ln -s "$PROBE_DIR/cargo-real" "$SFW_CACHE_DIR/latest"
  run su -s /bin/bash nobody -c "cd '$PROBE_DIR/proj' && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' fetch 2>&1"
  echo "$output"
  [[ "$output" == *"SFW-STUB SKIP=1"* ]]
}

@test "cargo+sfw: the real sfw runs a non-root caller's cargo once its update check is due" {
  # The tests above use a stub sfw. This one runs the installed sfw, so it
  # fails if sfw writes its root-owned cache for a non-root caller: backdate
  # next-check past sfw's 1h window, as VM#1 measured, and run the deployed
  # wrapper as nobody against a stub cargo. sfw's firewall runs its child
  # behind a local proxy (MEASURED, sfw-free 1.16.0: CARGO_HTTP_PROXY is set,
  # for any child command), so the stub reports it as proof sfw was in the chain.
  command -v cargo >/dev/null || skip "cargo not installed"
  [ "$(id -u)" = 0 ] || skip "needs root to backdate sfw's cache and run as another account"
  grep -q 'pfx="sfw"' "$(cargo_path)" || skip "wrapper rendered without the sfw route (cargo_socket_firewall=false)"
  sfw_bin=$(command -v sfw) || skip "sfw not installed"
  s=$(readlink -f "$sfw_bin"); s=${s%/*}; c=${s%/*}/.sfw-cache
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  make_probe without-cooldown
  printf '#!/bin/sh\nprintf "%%s\\n" "$*"\necho "PROXY=${CARGO_HTTP_PROXY:-none}"\n' > "$PROBE_DIR/cargo-real"
  chmod -R a+rX "$PROBE_DIR"
  saved=$(cat "$c/next-check" 2>/dev/null)
  printf '2026-01-01T00:00:00.000Z' > "$c/next-check"

  run su -s /bin/bash nobody -c "cd '$PROBE_DIR/proj' && PATH='$PROBE_DIR:${sfw_bin%/*}:/usr/bin:/bin' '$PROBE_DIR/cargo' fetch 2>&1"
  after=$(cat "$c/next-check")
  [ -n "$saved" ] && printf '%s' "$saved" > "$c/next-check"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Failed to prepare firewall binary"* ]]
  [[ "$output" != *"sfw has no firewall binary cached"* ]]
  [[ "$output" == *"fetch --locked"* ]]
  [[ "$output" == *"PROXY=http://127.0.0.1:"* ]]
  [ "$after" = "2026-01-01T00:00:00.000Z" ]
}
