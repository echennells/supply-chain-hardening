#!/usr/bin/env bash
# Acceptance check for the cargo hardening. Answers the three questions that
# decide whether this is safe to merge, and prints the raw evidence for each so
# the verdict can be checked rather than trusted.
#
#   1. AVAILABILITY   Does cargo still work after the role is applied?
#                     (the only failure that really hurts)
#   2. EFFICACY       Does the gate actually refuse a too-new version, by name?
#   3. REVERSIBILITY  Does the documented off-switch restore the original binary?
#
# Run in a throwaway container:
#   docker run --rm -v "$PWD:/role" rust:slim-bookworm bash /role/tests/acceptance/cargo-signoff.sh
#
# Exits non-zero if any check fails or if fewer checks run than expected.
set -u
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/cargo/bin:$PATH"

EXPECTED_CHECKS=10
PASS=0; FAIL=0; RAN=0

ok()   { RAN=$((RAN+1)); PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { RAN=$((RAN+1)); FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
eviden(){ printf '        evidence: %s\n' "$1"; }
hdr()  { printf '\n=== %s ===\n' "$1"; }

echo "Preparing host (installing ansible + cargo-cooldown; a few minutes)..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
  ansible python3 curl ca-certificates gcc libc6-dev >/dev/null 2>&1
cargo install cargo-cooldown >/dev/null 2>&1

# The gate is only meaningful if its backend can actually run. Say so up front
# rather than reporting checks that silently measured nothing.
if cargo-cooldown --version >/dev/null 2>&1; then
  echo "cargo-cooldown: $(cargo-cooldown --version 2>&1 | head -1)"
else
  echo "cargo-cooldown could not be installed or cannot execute on this host."
  echo "The EFFICACY checks below would measure nothing. Aborting."
  exit 2
fi

cd /role || { echo "mount the role at /role"; exit 2; }
ansible-playbook site.yml --connection=local --limit localhost \
  -e podman_enabled=false >/tmp/apply.log 2>&1
APPLY_RC=$?
echo "role apply rc=$APPLY_RC"
[ "$APPLY_RC" -eq 0 ] || { echo "apply failed; see /tmp/apply.log"; tail -20 /tmp/apply.log; exit 2; }

CARGO_BIN=$(for p in "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo /usr/bin/cargo /usr/local/cargo/bin/cargo; do
  [ -x "$p" ] && { echo "$p"; break; }; done)

mkproj() {
  rm -rf /tmp/acc; mkdir -p /tmp/acc/src; cd /tmp/acc
  printf '[package]\nname="acc"\nversion="0.1.0"\nedition="2021"\n\n[dependencies]\narrayref = "0.3.9"\n' > Cargo.toml
  echo 'fn main(){ println!("built"); }' > src/main.rs
}

# ---------------------------------------------------------------------------
hdr "1. AVAILABILITY — cargo must still work"
# ---------------------------------------------------------------------------
out=$(cargo --version 2>&1)
case "$out" in
  cargo*) ok "cargo --version works";        eviden "$out" ;;
  *)      bad "cargo --version is BROKEN";   eviden "$out" ;;
esac

out=$(cd /tmp && rm -rf nc && cargo new nc 2>&1 | tail -1)
if [ -d /tmp/nc ]; then ok "cargo new works"; eviden "$out"
else bad "cargo new is BROKEN"; eviden "$out"; fi

mkproj
out=$(timeout 900 cargo build 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a real build with a real dependency succeeds"
  eviden "$(printf '%s' "$out" | grep -iE 'Finished|Compiling acc' | tail -1)"
else
  bad "a real build FAILS through the wrapper (exit $rc)"
  eviden "$(printf '%s' "$out" | grep -iE 'error' | head -2 | tr '\n' ' ')"
fi

lock=$(grep -A1 'name = "arrayref"' Cargo.lock 2>/dev/null | grep version | tr -d ' ')
[ -n "$lock" ] && ok "lockfile written normally" && eviden "arrayref $lock" \
              || bad "no lockfile produced"

# ---------------------------------------------------------------------------
hdr "2. EFFICACY — the gate must refuse a too-new version, BY NAME"
# ---------------------------------------------------------------------------
# Window wide enough that every crate on crates.io violates it, and NO lockfile,
# so this is a fresh resolution — the case the gate exists for.
CH="${CARGO_HOME:-$HOME/.cargo}"
cp "$CH/cooldown.toml" /tmp/cooldown.bak
sed -i 's/^global-min-publish-age = .*/global-min-publish-age = "99999 days"/' "$CH/cooldown.toml"
mkproj
rm -f Cargo.lock
out=$(timeout 900 cargo build 2>&1); rc=$?

# A refusal only counts if the gate names it. Infrastructure failures — a
# missing binary, a loader error, a network fault — must NOT read as enforcement.
if printf '%s' "$out" | grep -qiE 'GLIBC|error while loading shared|unknown proxy name|No such file|syntax error|command not found'; then
  bad "build failed for INFRASTRUCTURE reasons, not the gate"
  eviden "$(printf '%s' "$out" | grep -iE 'GLIBC|loading shared|unknown proxy' | head -1)"
elif [ "$rc" -eq 0 ]; then
  bad "build SUCCEEDED under a 99999-day window — the gate is not enforcing"
  eviden "exit 0; lockfile: $(grep -A1 'name = "arrayref"' Cargo.lock 2>/dev/null | grep version | tr -d ' ')"
elif printf '%s' "$out" | grep -qiE 'publish.?age|blocked fresh versions'; then
  ok "fresh resolution REFUSED by the gate (exit $rc)"
  eviden "$(printf '%s' "$out" | grep -iE 'blocked fresh versions|publish.?age' | head -1 | cut -c1-150)"
else
  bad "build failed, but not with a gate message (exit $rc)"
  eviden "$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-150)"
fi

[ -f Cargo.lock ] && bad "a lockfile was written despite the refusal" \
                  || ok "nothing written on refusal (prior state preserved)"

# A global flag before the subcommand must NOT bypass the gate. This was a
# real, silent, total bypass: `cargo -q build` matched no case, fell through
# with no controls and no warning, while the verifier reported OK.
rm -f Cargo.lock; rm -rf target
out=$(timeout 900 cargo -q build 2>&1); rc=$?
if printf '%s' "$out" | grep -qiE 'GLIBC|loading shared|unknown proxy name|syntax error'; then
  bad "'cargo -q build' failed for INFRASTRUCTURE reasons, not the gate"
  eviden "$(printf '%s' "$out" | head -1 | cut -c1-150)"
elif [ "$rc" -eq 0 ]; then
  bad "'cargo -q build' SUCCEEDED under a 99999-day window — a leading flag bypasses the gate"
  eviden "exit 0 while bare 'cargo build' was refused"
elif printf '%s' "$out" | grep -qiE 'publish.?age|blocked fresh versions'; then
  ok "'cargo -q build' is gated identically to 'cargo build'"
  eviden "$(printf '%s' "$out" | grep -iE 'blocked fresh|publish.?age' | head -1 | cut -c1-130)"
else
  bad "'cargo -q build' failed, but not with a gate message (exit \$rc)"
  eviden "$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-150)"
fi

cp /tmp/cooldown.bak "$CH/cooldown.toml"

# ---------------------------------------------------------------------------
hdr "3. RESILIENCE — the gate survives a rustup-style clobber"
# ---------------------------------------------------------------------------
# `rustup update` rewrites ~/.cargo/bin/cargo, silently overwriting the wrapper
# and removing the age gate until the next role apply. This simulates that
# (copy the real binary back over the wrapper), re-applies the role, and
# confirms the wrapper is restored, cargo still works, and re-apply did NOT
# double-wrap (cargo-real must remain a real cargo, not a wrapped one).
# Clobber with a GENUINELY UNMARKED cargo (what rustup update writes), not
# cargo-real — on rustup hosts cargo-real is the argv[0] shim and carries the
# marker by design, so copying it would unwrap nothing.
REAL_SRC=$(ls /usr/local/rustup/toolchains/*/bin/cargo "$HOME"/.rustup/toolchains/*/bin/cargo 2>/dev/null | head -1)
cp -f "$REAL_SRC" "$CARGO_BIN" 2>/dev/null
clobbered=$(grep -c 'supply-chain-hardening' "$CARGO_BIN" 2>/dev/null); clobbered=${clobbered:-0}
cd /role
ansible-playbook site.yml --connection=local --limit localhost -e podman_enabled=false >/tmp/reapply.log 2>&1
re_rc=$?
rewrapped=$(grep -c 'supply-chain-hardening' "$CARGO_BIN" 2>/dev/null); rewrapped=${rewrapped:-0}
out=$(cargo --version 2>&1)
if [ "$clobbered" = "0" ] && [ "$re_rc" -eq 0 ] && [ "$rewrapped" -gt 0 ] && case "$out" in cargo*) true;; *) false;; esac; then
  ok "re-apply after a rustup-style clobber restored the wrapper and cargo works"
  eviden "clobber unwrapped it, re-apply rc=$re_rc, wrapper back; $out"
else
  bad "re-apply did not restore the gate (clobbered=$clobbered reapply_rc=$re_rc rewrapped=$rewrapped)"
  eviden "$out; $(tail -3 /tmp/reapply.log | tr '\n' ' ')"
fi
# Verify cargo-real by INVOKING it (the shim carries the marker by design, so a
# grep would false-positive — same discipline as the bats suite).
real_out=$("${CARGO_BIN}-real" --version 2>&1)
if case "$real_out" in cargo*) true;; *) false;; esac; then
  ok "re-apply did not corrupt cargo-real (it still yields a working cargo)"
  eviden "${CARGO_BIN}-real --version -> $real_out"
else
  bad "re-apply corrupted cargo-real"
  eviden "$real_out"
fi

# ---------------------------------------------------------------------------
hdr "4. REVERSIBILITY — the off-switch must restore the original binary"
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
printf 'RESULT: %d passed, %d failed, %d of %d checks ran\n' "$PASS" "$FAIL" "$RAN" "$EXPECTED_CHECKS"
if [ "$RAN" -ne "$EXPECTED_CHECKS" ]; then
  # An absent signal must never read as a passing one.
  printf 'INCOMPLETE — expected %d checks, ran %d. Treat as FAILED.\n' "$EXPECTED_CHECKS" "$RAN"
  exit 1
fi
[ "$FAIL" -eq 0 ] && { printf 'ALL CHECKS PASSED\n'; exit 0; }
printf '%d CHECK(S) FAILED — do not merge\n' "$FAIL"; exit 1
