#!/usr/bin/env bats
# Tests for the cargo PATH wrapper (cargo_path_wrapper: true).
#
# WHY THIS WRAPPER IS THE WHOLE CARGO STORY
#
# Cargo executes build.rs and proc-macro code at COMPILE time with the building
# user's full privileges, before any of your code is called, and has no
# --ignore-scripts equivalent. So no config file can stop execution — the only
# control that prevents it is refusing to RESOLVE a too-new version. That
# control lives entirely in this wrapper.
#
# Calibrated against 2026-08-20: arrayref 0.3.10 published from a compromised
# maintainer account, added a first-ever dep on the proc-macro1 typosquat whose
# build.rs fetched and ran a remote binary during `cargo build`. Live 86
# minutes. blake3 depended on arrayref ^0.3.5.
#
# TEST STRATEGY
#
# Dispatch tests run the ACTUAL DEPLOYED WRAPPER with a stub standing in for
# cargo itself, so they assert on the artifact the role installed rather than a
# re-render of the template. A stub also means no network, no compile, and no
# dependence on whether cargo-cooldown happens to be installed on this host.

load setup

cargo_path() {
  # DELIBERATELY NOT `readlink -f`, which is what the deno wrapper tests use.
  # rustup's ~/.cargo/bin/cargo is a SYMLINK TO THE RUSTUP BINARY, so resolving
  # it canonically lands on `rustup` — a shared proxy for rustc, clippy, rustfmt
  # and friends. Wrapping that would replace every rust tool at once. The role
  # wraps the cargo path itself, so the test must look at the same path, using
  # the role's own discovery order (tasks/cargo.yml "Check if cargo is
  # installed").
  local p
  for p in "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo /usr/bin/cargo; do
    if [ -x "$p" ]; then echo "$p"; return 0; fi
  done
  command -v cargo
}

# Copy the deployed wrapper, repointing REAL_CARGO at an argv-printing stub.
# $1 = "with-cooldown" | "without-cooldown"
make_probe() {
  PROBE_DIR="$(mktemp -d)"
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' > "$PROBE_DIR/cargo-real"
  chmod +x "$PROBE_DIR/cargo-real"
  sed "s|^REAL_CARGO=.*|REAL_CARGO='$PROBE_DIR/cargo-real'|" "$(cargo_path)" > "$PROBE_DIR/cargo"
  chmod +x "$PROBE_DIR/cargo"
  mkdir -p "$PROBE_DIR/proj"
  : > "$PROBE_DIR/proj/Cargo.lock"
  if [ "$1" = "with-cooldown" ]; then
    printf '#!/bin/sh\nexit 0\n' > "$PROBE_DIR/cargo-cooldown"
    chmod +x "$PROBE_DIR/cargo-cooldown"
  fi
}

# Run the probe wrapper with a PATH containing ONLY the probe dir, so the
# presence or absence of a real cargo-cooldown on this host cannot leak in.
probe() {
  ( cd "$PROBE_DIR/proj" \
      && unset SUPPLY_CHAIN_CARGO_WRAPPED \
      && PATH="$PROBE_DIR:/usr/bin:/bin" "$PROBE_DIR/cargo" "$@" 2>/dev/null \
      | tr '\n' ' ' | sed 's/ $//' )
}

teardown() {
  [ -n "${PROBE_DIR:-}" ] && rm -rf "$PROBE_DIR"
  return 0
}

# ---- deployment ----

@test "cargo: wrapper is deployed at the discovered cargo path" {
  command -v cargo >/dev/null || skip "cargo not installed"
  grep -q 'supply-chain-hardening' "$(cargo_path)"
}

@test "cargo: original binary preserved as cargo-real" {
  command -v cargo >/dev/null || skip "cargo not installed"
  [ -x "$(cargo_path)-real" ]
}

# Asserting "cargo-real contains no role marker" would be wrong here: on rustup
# hosts cargo-real IS role-written (an argv[0] shim). Assert the property that
# actually matters instead — that invoking it produces a working cargo.
@test "cargo: cargo-real is invokable and yields a real cargo" {
  command -v cargo >/dev/null || skip "cargo not installed"
  run "$(cargo_path)-real" --version
  [ "$status" -eq 0 ]
  [[ "$output" == cargo* ]]
}

# The regression that a stubbed cargo-cooldown could never catch: rustup
# dispatches on argv[0], so a backup named cargo-real is an "unknown proxy
# name" unless something restores the name. cargo-cooldown shells out to
# `cargo locate-project` via $CARGO, hitting this on every real build.
@test "cargo: cargo-real survives being invoked under its own name" {
  command -v cargo >/dev/null || skip "cargo not installed"
  run "$(cargo_path)-real" locate-project
  [ "$status" -eq 0 ] || [[ "$output" != *"unknown proxy name"* ]]
  [[ "$output" != *"unknown proxy name"* ]]
}

# THE regression that matters most: a wrapper that breaks cargo is worse than
# no wrapper at all. This invokes the real binary through the real wrapper.
@test "cargo: wrapper does not break cargo itself" {
  command -v cargo >/dev/null || skip "cargo not installed"
  run cargo --version
  [ "$status" -eq 0 ]
  [[ "$output" == cargo* ]]
}

# ---- the publish-age gate ----

@test "cargo: build routes through cargo cooldown when the backend exists" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [ "$(probe build)" = "cooldown build" ]
}

@test "cargo: update routes through cargo cooldown (the cargo update vector)" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [ "$(probe update)" = "cooldown update" ]
}

@test "cargo: short aliases are normalised before routing" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  # `cargo b` must not reach cooldown as an unknown subcommand
  [ "$(probe b)" = "cooldown build" ]
}

@test "cargo: rustup +toolchain override survives routing" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  # Without explicit handling, `cargo +nightly build` would be dispatched on
  # "+nightly" and every rustup user would silently lose both controls.
  [ "$(probe +nightly build)" = "+nightly cooldown build" ]
}

# ---- the --locked fallback ----

@test "cargo: falls back to --locked when the cooldown backend is absent" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  [ "$(probe build)" = "build --locked" ]
}

@test "cargo: degrading to --locked warns instead of failing silently" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  run bash -c "cd '$PROBE_DIR/proj' && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>&1 >/dev/null"
  [[ "$output" == *"cargo-cooldown not installed"* ]]
}

@test "cargo: --locked is inserted BEFORE -- so it reaches cargo not the program" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  # Appending would hand --locked to the user's binary instead of to cargo.
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

@test "cargo: install gets --locked so it honours the published lockfile" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  # Without --locked, cargo install re-resolves every transitive dep to
  # newest-compatible at install time — the arrayref vector exactly.
  [ "$(probe install ripgrep)" = "install --locked ripgrep" ]
}

@test "cargo: no lockfile means no --locked (would be a hard error)" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  rm -f "$PROBE_DIR/proj/Cargo.lock"
  # Walk-up must find nothing; run from a dir with no Cargo.lock above it.
  run bash -c "cd '$PROBE_DIR/proj' && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>/dev/null | tr '\n' ' ' | sed 's/ \$//'"
  [ "$output" = "build" ]
}

@test "cargo: lockfile is found from a workspace SUBdirectory" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe without-cooldown
  mkdir -p "$PROBE_DIR/proj/crates/inner"
  run bash -c "cd '$PROBE_DIR/proj/crates/inner' && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>/dev/null | tr '\n' ' ' | sed 's/ \$//'"
  [ "$output" = "build --locked" ]
}

# ---- lockfile laundering (regression: adversarial review of the first cut) ----
#
# The original wrapper gated build/check/test/run/update but left `cargo add`
# and `cargo generate-lockfile` to fall through. Both WRITE Cargo.lock, and
# lockfile-baseline="floor" then grandfathers whatever they wrote — so two
# ungated commands defeated the gate completely:
#
#   cargo add arrayref@0.3.9   # ungated, pins a fresh version
#   cargo build               # succeeds; the gate never sees the crate
#
# Confirmed by execution against a 99999-day window before the fix. These tests
# pin the dispatch so it cannot silently regress.

# Stub that records every invocation and simulates `add` writing a lockfile.
make_recording_probe() {
  make_probe "$1"
  cat > "$PROBE_DIR/cargo-real" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$RECORD"
case "$1" in add|generate-lockfile) : > "$PWD/Cargo.lock" ;; esac
exit 0
STUB
  chmod +x "$PROBE_DIR/cargo-real"
  export RECORD="$PROBE_DIR/calls.log"
  : > "$RECORD"
  printf '[package]\nname="p"\nversion="0.1.0"\n' > "$PROBE_DIR/proj/Cargo.toml"
  rm -f "$PROBE_DIR/proj/Cargo.lock"
}

@test "cargo: add re-evaluates the result through the gate" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_recording_probe with-cooldown
  ( cd "$PROBE_DIR/proj" && unset SUPPLY_CHAIN_CARGO_WRAPPED \
      && RECORD="$RECORD" PATH="$PROBE_DIR:/usr/bin:/bin" "$PROBE_DIR/cargo" add somecrate ) >/dev/null 2>&1 || true
  # The add itself must run, and the wrapper must then ask the gate about the
  # dependency set it produced.
  grep -q '^add somecrate$' "$RECORD"
  grep -q 'cooldown check' "$RECORD"
}

@test "cargo: generate-lockfile is gated the same way" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_recording_probe with-cooldown
  ( cd "$PROBE_DIR/proj" && unset SUPPLY_CHAIN_CARGO_WRAPPED \
      && RECORD="$RECORD" PATH="$PROBE_DIR:/usr/bin:/bin" "$PROBE_DIR/cargo" generate-lockfile ) >/dev/null 2>&1 || true
  grep -q 'cooldown check' "$RECORD"
}

@test "cargo: lockfile writers warn when no backend can age-check them" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_recording_probe without-cooldown
  run bash -c "cd '$PROBE_DIR/proj' && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' add somecrate 2>&1 >/dev/null"
  # --locked cannot help a command whose purpose is to CHANGE the lockfile, so
  # the wrapper must say so rather than implying coverage it does not have.
  [[ "$output" == *"can write a lockfile entry for a freshly published crate"* ]]
}

# ---- Socket Firewall (threat-intel layer) ----
#
# sfw covers the axis the age gate cannot: it filters the DOWNLOAD, so it
# applies to a lockfile written on someone else's machine, and it never
# participates in version selection so it cannot rewrite a lockfile.
#
# The binding constraint is availability. Measured upstream behaviour:
#   corrupt sfw binary -> FAILS CLOSED, propagating exit 9. Prefixing cargo
#     unconditionally would break every build on the host.
#   no network         -> FAILS OPEN, warns and exits 0, build unfiltered.
# So the wrapper must only use sfw when it is actually present, and must never
# make cargo's availability depend on it existing.

stub_sfw() {
  printf '#!/bin/sh\necho SFW-USED\nexec "$@"\n' > "$PROBE_DIR/sfw"
  chmod +x "$PROBE_DIR/sfw"
}

@test "cargo: network commands are routed through sfw when it is present" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  stub_sfw
  [[ "$(probe build)" == SFW-USED* ]]
}

@test "cargo: sfw absent must NOT break cargo (availability over filtering)" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  # probe() uses a PATH that contains no sfw at all.
  run bash -c "cd '$PROBE_DIR/proj' && PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SFW-USED"* ]]
}

@test "cargo: non-network subcommands skip sfw (no proxy startup cost)" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  stub_sfw
  # `cargo --version` must not spin up a filtering proxy.
  [[ "$(probe --version)" != *"SFW-USED"* ]]
}

@test "cargo: sfw wraps the real cargo, not the wrapper (no recursion)" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  stub_sfw
  # SFW-USED must appear exactly once: sfw execs cargo-real directly, so the
  # wrapper is not re-entered through it.
  [ "$(probe build | grep -c 'SFW-USED')" -eq 1 ]
}

# ---- pass-through and guards ----

@test "cargo: non-resolving subcommands pass through untouched" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [ "$(probe new mycrate)" = "new mycrate" ]
  [ "$(probe --version)" = "--version" ]
  [ "$(probe clean)" = "clean" ]
}

@test "cargo: binstall and cooldown pass through (no recursion)" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  [ "$(probe binstall foo)" = "binstall foo" ]
  [ "$(probe cooldown build)" = "cooldown build" ]
}

@test "cargo: re-entrancy guard stops the cooldown->cargo->cooldown loop" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  # cargo-cooldown invokes cargo internally. Without this guard the inner call
  # routes back into cooldown forever and every build hangs.
  run bash -c "cd '$PROBE_DIR/proj' && SUPPLY_CHAIN_CARGO_WRAPPED=1 PATH='$PROBE_DIR:/usr/bin:/bin' '$PROBE_DIR/cargo' build 2>/dev/null | tr '\n' ' ' | sed 's/ \$//'"
  [ "$output" = "build" ]
}

@test "cargo: recursion guard refuses when cargo-real is missing" {
  command -v cargo >/dev/null || skip "cargo not installed"
  make_probe with-cooldown
  sed "s|^REAL_CARGO=.*|REAL_CARGO='/nonexistent/cargo'|" "$PROBE_DIR/cargo" > "$PROBE_DIR/cargo-bad"
  chmod +x "$PROBE_DIR/cargo-bad"
  run "$PROBE_DIR/cargo-bad" build
  [ "$status" -eq 127 ]
}

# ---- the gate config ----

# $CARGO_HOME, not ~/.cargo. Cargo reads config from $CARGO_HOME, which the
# official rust images set to /usr/local/cargo and CI runners often point at a
# cache volume. Asserting ~/.cargo would pass on a host where the file is inert.
cargo_home_dir() { echo "${CARGO_HOME:-$HOME/.cargo}"; }

@test "cargo: cooldown.toml is deployed at CARGO_HOME with a non-zero window" {
  [ -f "$(cargo_home_dir)/cooldown.toml" ]
  run grep -E 'global-min-publish-age' "$(cargo_home_dir)/cooldown.toml"
  [ "$status" -eq 0 ]
  # A window of 0 would be a disabled gate reported as a configured one.
  [[ ! "$output" =~ =[[:space:]]*\"0 ]]
}

@test "cargo: cooldown violations deny rather than fall back" {
  [ -f "$(cargo_home_dir)/cooldown.toml" ]
  # "fallback" downgrades and only warns — a fail-open posture.
  grep -qE 'incompatible-publish-age[[:space:]]*=[[:space:]]*"deny"' "$(cargo_home_dir)/cooldown.toml"
}

# Regression catcher for the bug above: the config must land where the TOOL
# reads it, not merely somewhere plausible. On a host with CARGO_HOME set away
# from ~/.cargo, a file at ~/.cargo/cooldown.toml is inert.
@test "cargo: cooldown.toml is not stranded outside CARGO_HOME" {
  [ "$(cargo_home_dir)" = "$HOME/.cargo" ] && skip "CARGO_HOME is ~/.cargo here; nothing to strand"
  [ -f "$(cargo_home_dir)/cooldown.toml" ]
}
