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
  # Neutralise the wrapper's COOLDOWN_BIN prepend so THIS fixture controls
  # whether cargo-cooldown is reachable. The wrapper prepends its embedded
  # COOLDOWN_BIN ($CARGO_HOME/bin) to PATH before dispatching — added so the
  # gate resolves on apt-cargo hosts. On the rustup test image that dir holds a
  # REAL cargo-cooldown, so without this the `without-cooldown` probes would
  # still find it and route to `cooldown`, never exercising the --locked
  # fallback. Point it at PROBE_DIR, where make_probe places a cargo-cooldown
  # only for the with-cooldown case, so presence is fully under fixture control.
  sed -e "s|^REAL_CARGO=.*|REAL_CARGO='$PROBE_DIR/cargo-real'|" \
      -e "s|^COOLDOWN_BIN=.*|COOLDOWN_BIN='$PROBE_DIR'|" \
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

teardown() { [ -n "${PROBE_DIR:-}" ] && rm -rf "$PROBE_DIR"; return 0; }

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

# ---- BUG 1 regression: cargo-cooldown must be reachable on apt-cargo hosts ----
#
# On a rustup cargo, $CARGO_HOME/bin is on PATH, so `command -v cargo-cooldown`
# and cargo's own `cargo cooldown` subcommand resolution both find the backend.
# On a distro/apt cargo, ~/.cargo/bin is NOWHERE on PATH — so the backend builds
# fine but the wrapper cannot find it, and the age gate silently resolves fresh
# crates unchecked. Every test image used rustup, so this hid until a real
# Ubuntu 26.04 apt-cargo box surfaced it. The wrapper prepends $CARGO_HOME/bin
# to PATH; assert that it does.

@test "cargo: wrapper prepends the cooldown bin dir to PATH (apt-cargo reachability)" {
  command -v cargo >/dev/null || skip "cargo not installed"
  # COOLDOWN_BIN must be set to a non-empty $CARGO_HOME/bin, and the wrapper
  # must add it to PATH.
  run grep -E "^COOLDOWN_BIN='.+/bin'" "$(cargo_path)"
  [ "$status" -eq 0 ]
  grep -q 'PATH="$COOLDOWN_BIN:$PATH"' "$(cargo_path)"
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
