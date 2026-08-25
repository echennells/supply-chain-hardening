#!/usr/bin/env bash
# Acceptance check for the pnpm publish-age gate — BY BEHAVIOUR.
#
# supply-chain-verify can only report the pnpm age gate as WEAK: its runtime
# probe (`pnpm config get minimum-release-age`) proves pnpm READ the value, not
# that it ACTS on it — and pnpm, like npm, echoes back keys it doesn't
# implement. The role has no cheap discriminator for pnpm the way it does for
# npm, so the honest runtime verdict stays WEAK. This script supplies the proof
# the verifier structurally won't: it applies the role's pnpm config and then
# watches pnpm actually refuse a too-fresh version, and allow an old one.
#
# It is the pnpm sibling of cargo-signoff-apt.sh. Unlike that one there is no
# wrapper or binary to reverse — the protection is pure config — so it checks
# AVAILABILITY (an old-enough package still installs) and EFFICACY (a fresh one
# is refused BY THE GATE, by its own error code), not reversibility.
#
# Run in a throwaway container:
#   docker run --rm -v "$PWD:/role" ubuntu:26.04 bash /role/tests/acceptance/pnpm-signoff.sh
#
# Exits non-zero if any check fails or fewer than expected ran.
set -u
export DEBIAN_FRONTEND=noninteractive
export HOME=/root

# A version old enough to clear any sane window, pinned so a fresh lodash
# release can never turn the AVAILABILITY check flaky. Published 2021.
OLD_PKG="lodash@4.17.21"

PASS=0; FAIL=0; RAN=0
EXPECTED_MIN=3

ok()   { RAN=$((RAN+1)); PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { RAN=$((RAN+1)); FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skip() { RAN=$((RAN+1)); printf '  \033[33mN/A \033[0m  %s\n' "$1"; }
eviden(){ printf '        evidence: %s\n' "$1"; }
hdr()  { printf '\n=== %s ===\n' "$1"; }

echo "Preparing host (ansible + a current pnpm; a few minutes)..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
  ansible python3 nodejs npm curl ca-certificates >/dev/null 2>&1

# Install a current pnpm. NOT via corepack: on Ubuntu 26 the apt-packaged
# corepack cannot run modern pnpm (ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING — its
# patched loader chokes on pnpm's ESM entry). `npm install -g` runs pnpm
# directly and works. Measured on ubuntu:26.04.
npm install -g pnpm@latest >/tmp/pnpm-install.log 2>&1
hash -r 2>/dev/null

PNPM_V=$(pnpm --version 2>/dev/null | tail -1)
if [ -z "$PNPM_V" ]; then
  echo "pnpm did not install or cannot execute — cannot measure the gate. Aborting."
  tail -15 /tmp/pnpm-install.log
  exit 2
fi
echo "pnpm: $PNPM_V  (minimumReleaseAge shipped in 10.16)"

# Behaviour-driven skip, never version-reasoned about the role: if this pnpm is
# too old to have the feature at all, the gate cannot be measured here.
case "$PNPM_V" in
  [0-9].*|10.0.*|10.1[0-5].*)
    skip "pnpm $PNPM_V predates minimumReleaseAge (10.16) — nothing to enforce"
    printf '\nRESULT: gate feature absent in this pnpm; not a role failure.\n'
    exit 0 ;;
esac

cd /role || { echo "mount the role at /role"; exit 2; }

apply_pnpm() {  # $1 = minutes window
  ansible-playbook site.yml --connection=local --limit localhost \
    --tags pnpm -e podman_enabled=false \
    -e "pnpm_minimum_release_age_minutes=$1" >/tmp/apply.log 2>&1
}
config_file() {  # whichever file this pnpm major reads
  case "$PNPM_V" in
    [0-9].*|10.*) echo "$HOME/.config/pnpm/rc" ;;
    *)            echo "$HOME/.config/pnpm/config.yaml" ;;
  esac
}
mkproj() { rm -rf /tmp/pn && mkdir -p /tmp/pn && printf '{"name":"pn","version":"1.0.0"}' > /tmp/pn/package.json; }

# ---------------------------------------------------------------------------
hdr "1. AVAILABILITY — the role's normal window still installs an old package"
# ---------------------------------------------------------------------------
# Default 48h window (release_age_hours). A 2021 package clears it easily, so
# this proves pnpm works AND the gate is permissive for genuinely-old versions
# rather than a blanket block. It also proves the role wrote the config to the
# file THIS pnpm major actually reads.
apply_pnpm "2880"; APPLY_RC=$?
[ "$APPLY_RC" -eq 0 ] || { echo "role apply failed; see below"; tail -20 /tmp/apply.log; exit 2; }

CFG=$(config_file)
if grep -qiE 'minimum-?release-?age' "$CFG" 2>/dev/null; then
  ok "role wrote the age-gate config to the file pnpm $PNPM_V reads"
  eviden "$(grep -iE 'minimum-?release-?age' "$CFG" | head -1) ($CFG)"
else
  bad "age-gate config not found in $CFG for pnpm $PNPM_V"
  eviden "$(ls -1 "$HOME/.config/pnpm/" 2>/dev/null | tr '\n' ' ')"
fi

mkproj
out=$(cd /tmp/pn && pnpm add "$OLD_PKG" 2>&1); rc=$?
if [ -d /tmp/pn/node_modules/lodash ]; then
  ok "an old-enough package installs under the normal window ($OLD_PKG)"
  eviden "$(printf '%s' "$out" | grep -iE '\+ lodash|Done' | tail -1)"
else
  bad "an old package was blocked or pnpm failed under the normal window (rc=$rc)"
  eviden "$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-150)"
fi

# ---------------------------------------------------------------------------
hdr "2. EFFICACY — a wide window is refused BY THE GATE, by its own error"
# ---------------------------------------------------------------------------
# ~190-year window: every published version is 'too fresh'. A refusal only
# counts if pnpm names it — ERR_PNPM_NO_MATURE_MATCHING_VERSION — so a network
# fault or a broken pnpm cannot masquerade as enforcement.
apply_pnpm "99999999"
mkproj
out=$(cd /tmp/pn && pnpm add "$OLD_PKG" 2>&1); rc=$?
if printf '%s' "$out" | grep -q 'ERR_PNPM_NO_MATURE_MATCHING_VERSION'; then
  if [ -d /tmp/pn/node_modules/lodash ]; then
    bad "gate emitted its error but installed anyway — not actually enforcing"
    eviden "node_modules/lodash present despite the age error"
  else
    ok "fresh resolution REFUSED by the gate, by name (exit $rc)"
    eviden "$(printf '%s' "$out" | grep -iE 'minimumReleaseAge|was published' | head -1 | cut -c1-150)"
  fi
elif [ -d /tmp/pn/node_modules/lodash ]; then
  bad "SUCCEEDED under a 190-year window — the gate is NOT enforcing"
  eviden "node_modules/lodash present; window did nothing"
else
  bad "install failed, but not with the gate's error (could be network/pnpm)"
  eviden "$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-150)"
fi

# ---------------------------------------------------------------------------
printf '\n===========================================================\n'
printf 'RESULT: %d passed, %d failed, %d checks ran\n' "$PASS" "$FAIL" "$RAN"
if [ "$RAN" -lt "$EXPECTED_MIN" ]; then
  printf 'INCOMPLETE — ran %d, expected at least %d. Treat as FAILED.\n' "$RAN" "$EXPECTED_MIN"
  exit 1
fi
[ "$FAIL" -eq 0 ] && { printf 'ALL CHECKS PASSED\n'; exit 0; }
printf '%d CHECK(S) FAILED — do not merge\n' "$FAIL"; exit 1
