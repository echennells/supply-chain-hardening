#!/usr/bin/env bash
# Acceptance check for the cargo hardening ON AN APT-CARGO HOST.
#
# This is the sibling of cargo-signoff.sh, which runs on a rustup image where
# cargo lives at ~/.cargo/bin/cargo and that dir is already on PATH. That layout
# HID a real bug: cargo-cooldown (the gate backend) is `cargo install`ed into
# $CARGO_HOME/bin, which on a rustup host is already on PATH — so the gate
# resolved by luck. On a distro where cargo comes from apt (/usr/bin/cargo),
# $CARGO_HOME/bin is NOT on PATH, `command -v cargo-cooldown` fails inside the
# wrapper, and the age gate is silently dead while the wrapper still reports
# healthy. The fix makes the wrapper prepend $CARGO_HOME/bin to its own PATH.
#
# The EFFICACY check below IS the regression for that bug: on an apt-cargo host
# it only passes if the wrapper's prepend actually makes the backend reachable.
# Remove the prepend and this check fails (a 99999-day window would BUILD).
#
# The gate only installs when the host rustc meets the role's MSRV. apt cargo is
# 1.75 on 24.04 (below MSRV -> gate intentionally skipped) and 1.93 on 26.04
# (above -> gate active). So this script DECIDES what to assert by measuring
# whether the backend was installed, never by reasoning about a version number:
#   backend present -> EFFICACY must enforce (the real test).
#   backend absent  -> EFFICACY is N/A, reported with the rustc version as proof
#                      the skip was the MSRV policy, not a broken install.
#
# Run in a throwaway container built from apt cargo (NOT rustup):
#   docker run --rm -v "$PWD:/role" ubuntu:26.04 bash /role/tests/acceptance/cargo-signoff-apt.sh
#   docker run --rm -v "$PWD:/role" ubuntu:24.04 bash /role/tests/acceptance/cargo-signoff-apt.sh
set -u
export DEBIAN_FRONTEND=noninteractive

PASS=0; FAIL=0; RAN=0
EXPECTED_MIN=6   # availability(4) + reversibility(1) + one of efficacy/skip(1)

ok()   { RAN=$((RAN+1)); PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { RAN=$((RAN+1)); FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skip() { RAN=$((RAN+1)); printf '  \033[33mN/A \033[0m  %s\n' "$1"; }
eviden(){ printf '        evidence: %s\n' "$1"; }
hdr()  { printf '\n=== %s ===\n' "$1"; }

echo "Preparing an APT-CARGO host (installing ansible + cargo from apt; no rustup)..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
  ansible python3 curl ca-certificates gcc libc6-dev cargo rustc git >/dev/null 2>&1

# Precondition: cargo must come from the distro, not rustup. If a rustup cargo
# is on PATH this test is measuring the wrong thing — say so and stop.
CARGO_PRE=$(command -v cargo 2>/dev/null)
case "$CARGO_PRE" in
  */.cargo/bin/cargo|*/rustup/*)
    echo "PRECONDITION FAIL: cargo at $CARGO_PRE looks like rustup, not apt. Use cargo-signoff.sh for rustup hosts."
    exit 2 ;;
esac
echo "apt cargo: $CARGO_PRE -> $(cargo --version 2>&1)"

cd /role || { echo "mount the role at /role"; exit 2; }
ansible-playbook site.yml --connection=local --limit localhost \
  -e podman_enabled=false >/tmp/apply.log 2>&1
APPLY_RC=$?
echo "role apply rc=$APPLY_RC"
[ "$APPLY_RC" -eq 0 ] || { echo "apply failed; see below"; tail -25 /tmp/apply.log; exit 2; }

CARGO_BIN=$(command -v cargo)
CH="${CARGO_HOME:-$HOME/.cargo}"
COOLDOWN="$CH/bin/cargo-cooldown"

mkproj() {
  rm -rf /tmp/acc; mkdir -p /tmp/acc/src; cd /tmp/acc
  printf '[package]\nname="acc"\nversion="0.1.0"\nedition="2021"\n\n[dependencies]\narrayref = "0.3.9"\n' > Cargo.toml
  echo 'fn main(){ println!("built"); }' > src/main.rs
}

# ---------------------------------------------------------------------------
hdr "1. AVAILABILITY — cargo must still work through the wrapper"
# ---------------------------------------------------------------------------
if grep -q 'supply-chain-hardening' "$CARGO_BIN" 2>/dev/null; then
  ok "cargo is now the wrapper"; eviden "$CARGO_BIN is the supply-chain wrapper"
else
  bad "cargo was not wrapped"; eviden "$CARGO_BIN has no wrapper marker"
fi

out=$(cargo --version 2>&1)
case "$out" in cargo*) ok "cargo --version works"; eviden "$out" ;;
             *) bad "cargo --version is BROKEN"; eviden "$out" ;; esac

out=$(cd /tmp && rm -rf nc && cargo new nc 2>&1 | tail -1)
[ -d /tmp/nc ] && { ok "cargo new works"; eviden "$out"; } || { bad "cargo new is BROKEN"; eviden "$out"; }

mkproj
out=$(timeout 900 cargo build 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a real build with a real dependency succeeds"
  eviden "$(printf '%s' "$out" | grep -iE 'Finished|Compiling acc' | tail -1)"
else
  bad "a real build FAILS through the wrapper (exit $rc)"
  eviden "$(printf '%s' "$out" | grep -iE 'error' | head -2 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
hdr "2. EFFICACY — the gate must refuse a too-new version, BY NAME"
# ---------------------------------------------------------------------------
# Behaviour-driven: assert enforcement ONLY if the backend was actually
# installed. Below MSRV the role skips it on purpose; that is N/A, not a fail.
if [ -x "$COOLDOWN" ]; then
  echo "gate backend present: $("$COOLDOWN" --version 2>&1 | head -1)"

  # Prove the BUG-1 condition really holds here: the backend is NOT reachable
  # from a stock PATH — so only the wrapper's own prepend can rescue it. If this
  # assertion ever fails, the host already had ~/.cargo/bin on PATH and this
  # test degraded into the rustup case that hid the bug.
  if env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        command -v cargo-cooldown >/dev/null 2>&1; then
    skip "backend already on stock PATH — this host cannot exercise the BUG-1 prepend"
    eviden "cargo-cooldown resolves without the wrapper; efficacy still checked below"
  else
    ok "backend is OFF the stock PATH — enforcement now depends on the wrapper's prepend"
    eviden "env -i PATH=... command -v cargo-cooldown -> not found (this is the BUG-1 layout)"
  fi

  CFG="$CH/cooldown.toml"
  cp "$CFG" /tmp/cooldown.bak
  sed -i 's/^global-min-publish-age = .*/global-min-publish-age = "99999 days"/' "$CFG"
  mkproj; rm -f Cargo.lock
  out=$(timeout 900 cargo build 2>&1); rc=$?
  if printf '%s' "$out" | grep -qiE 'GLIBC|error while loading shared|unknown proxy name|No such file|syntax error|command not found'; then
    bad "build failed for INFRASTRUCTURE reasons, not the gate"
    eviden "$(printf '%s' "$out" | grep -iE 'GLIBC|loading shared|unknown proxy|not found' | head -1)"
  elif [ "$rc" -eq 0 ]; then
    bad "build SUCCEEDED under a 99999-day window — the gate is DEAD on this apt-cargo host (BUG 1 regressed)"
    eviden "exit 0; the wrapper is not making cargo-cooldown reachable"
  elif printf '%s' "$out" | grep -qiE 'publish.?age|blocked fresh versions'; then
    ok "fresh resolution REFUSED by the gate on an apt-cargo host (exit $rc)"
    eviden "$(printf '%s' "$out" | grep -iE 'blocked fresh versions|publish.?age' | head -1 | cut -c1-150)"
  else
    bad "build failed, but not with a gate message (exit $rc)"
    eviden "$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-150)"
  fi

  # A leading global flag must not bypass the gate (the argv[1] parse bug).
  mkproj; rm -f Cargo.lock; rm -rf target
  out=$(timeout 900 cargo -q build 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "'cargo -q build' SUCCEEDED under a 99999-day window — a leading flag bypasses the gate"
    eviden "exit 0 while bare 'cargo build' was refused"
  elif printf '%s' "$out" | grep -qiE 'publish.?age|blocked fresh versions'; then
    ok "'cargo -q build' is gated identically to 'cargo build'"
    eviden "$(printf '%s' "$out" | grep -iE 'blocked fresh|publish.?age' | head -1 | cut -c1-130)"
  else
    bad "'cargo -q build' failed, but not with a gate message (exit $rc)"
    eviden "$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-150)"
  fi
  cp /tmp/cooldown.bak "$CFG"

  # The gate gated a fresh version above (behaviour). The VERIFIER must agree.
  # A verifier that probes the backend by bare name reports a working gate as
  # broken on apt-cargo hosts — the same off-PATH assumption the wrapper had
  # (measured: "cargo-cooldown CANNOT EXECUTE" while the build was in fact
  # gated). This check fails if the verifier and reality disagree.
  vrow=$(/usr/local/bin/supply-chain-verify 2>/dev/null \
           | sed 's/\x1b\[[0-9;]*m//g' | grep -iE 'cargo publish-age gate' | head -1)
  vstat=$(printf '%s' "$vrow" | awk '{print $1}')
  if [ "$vstat" = "OK" ]; then
    ok "supply-chain-verify AGREES the gate is enforcing, matching the behaviour above"
    eviden "$(printf '%s' "$vrow" | sed 's/   */ /g' | cut -c1-140)"
  else
    bad "verifier DISAGREES with behaviour: the build was gated above, but the verifier row is '$vstat', not OK"
    eviden "$(printf '%s' "$vrow" | sed 's/   */ /g' | cut -c1-160)"
  fi
else
  skip "gate backend not installed — host rustc is below the role MSRV (expected on 24.04)"
  eviden "rustc: $(rustc --version 2>&1); no $COOLDOWN. The role skipped the gate by policy."
fi

# ---------------------------------------------------------------------------
hdr "3. REVERSIBILITY — the off-switch must restore the original binary"
# ---------------------------------------------------------------------------
cd /role
ansible-playbook site.yml --connection=local --limit localhost \
  -e podman_enabled=false -e cargo_path_wrapper=false >/tmp/off.log 2>&1
off_rc=$?
still_wrapped=$(grep -c 'supply-chain-hardening' "$CARGO_BIN" 2>/dev/null); still_wrapped=${still_wrapped:-0}
out=$(cargo --version 2>&1)
if [ "$off_rc" -eq 0 ] && [ "$still_wrapped" = "0" ] && case "$out" in cargo*) true;; *) false;; esac; then
  ok "cargo_path_wrapper=false removed the wrapper and cargo still works"
  eviden "$CARGO_BIN is unwrapped; $out"
else
  bad "off-switch did not cleanly restore (apply rc=$off_rc, wrapped=$still_wrapped)"
  eviden "$out"
fi

# ---------------------------------------------------------------------------
printf '\n===========================================================\n'
printf 'RESULT: %d passed, %d failed, %d checks ran\n' "$PASS" "$FAIL" "$RAN"
if [ "$RAN" -lt "$EXPECTED_MIN" ]; then
  printf 'INCOMPLETE — ran %d checks, expected at least %d. Treat as FAILED.\n' "$RAN" "$EXPECTED_MIN"
  exit 1
fi
[ "$FAIL" -eq 0 ] && { printf 'ALL CHECKS PASSED\n'; exit 0; }
printf '%d CHECK(S) FAILED — do not merge\n' "$FAIL"; exit 1
