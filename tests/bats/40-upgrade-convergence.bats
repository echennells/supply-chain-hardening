#!/usr/bin/env bats
# Upgrade path: a host hardened by an EARLIER version of this role must
# converge, including removing artifacts that version deployed.
#
# WHY THIS FILE EXISTS
#
# Every other suite runs against a container that was hardened once, from
# clean, by the current code. Real hosts are not like that — they carry state
# from previous applies, and the role has to reconcile it. That blind spot is
# not hypothetical: QA found /etc/profile.d/npq-aliases.sh sitting on a Node 18
# box, deployed by an older role version before any functional check existed,
# routing every interactive `npm install` through an npq that passes straight
# through to npm and exits 0. The role reported full coverage. No test could
# have caught it, because no test ever started from a previously-hardened host.
#
# These tests seed the prior state directly rather than checking out an old
# revision. That is deliberate: what matters is convergence FROM A STATE, not
# from a commit, and seeding also lets us construct states that no single past
# revision produced (mixed-age artifacts on a host applied to repeatedly).

load setup

ALIASES=/etc/profile.d/npq-aliases.sh

npq_path() { command -v npq-hero 2>/dev/null; }

npq_is_functional() {
  command -v npq-hero >/dev/null 2>&1 || return 1
  ! npq-hero --version 2>&1 | grep -qi 'npq suppressed'
}

# Replace npq-hero with a stub reproducing the real suppressed shape: warn on
# stderr, pass through to the package manager, exit 0.
shadow_npq_as_suppressed() {
  REAL_NPQ="$(npq_path)"
  [ -n "$REAL_NPQ" ] || return 1
  # npm installs global bins as SYMLINKS into ../lib/node_modules/... so
  # `cat > "$REAL_NPQ"` would write THROUGH the link and destroy npq's real
  # source file — corrupting it for every later test in this container, with
  # the restore step putting back a symlink to the wreckage.
  # cp -a preserves the link itself (-a implies -d, no dereference); removing
  # it first means the stub is a fresh regular file and the target is untouched.
  cp -a "$REAL_NPQ" "${REAL_NPQ}.upgradetest.bak" || return 1
  rm -f "$REAL_NPQ"
  cat > "$REAL_NPQ" <<'EOF'
#!/bin/bash
echo "error: npq suppressed due to old node version" >&2
exit 0
EOF
  chmod +x "$REAL_NPQ"
}

restore_npq() {
  if [ -n "${REAL_NPQ:-}" ] && [ -f "${REAL_NPQ}.upgradetest.bak" ]; then
    mv -f "${REAL_NPQ}.upgradetest.bak" "$REAL_NPQ"
  fi
}

@test "upgrade: a stale npq alias file is REMOVED when npq cannot function" {
  # The exact state QA found. An older role version deployed the aliases; the
  # host's npq is suppressed; re-applying must take the file away, because
  # leaving it preserves the false-protection state.
  command -v npq-hero >/dev/null 2>&1 || skip "npq not installed in this image"
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"

  shadow_npq_as_suppressed || skip "could not shadow npq-hero"

  # Seed the artifact an older role version would have left behind.
  cat > "$ALIASES" <<'EOF'
#!/bin/sh
# Managed by ansible-supply-chain-security
export NPQ_DISABLE_AUTO_CONTINUE=true
alias npm='npq-hero'
EOF
  [ -f "$ALIASES" ]

  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags npq -e podman_enabled=false -e verify_protections=false
  echo "$output" | tail -20

  local present=0
  [ -f "$ALIASES" ] && present=1
  restore_npq

  # The whole point: converged away, not merely left un-rewritten.
  [ "$present" -eq 0 ]
}

@test "upgrade: the gap is REPORTED, not silently converged" {
  # Removing the file is only half right. A host that loses its reputation
  # layer must say so — otherwise the fix trades a visible-but-false signal
  # for no signal at all.
  command -v npq-hero >/dev/null 2>&1 || skip "npq not installed in this image"
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"

  shadow_npq_as_suppressed || skip "could not shadow npq-hero"
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags npq -e podman_enabled=false -e verify_protections=false
  restore_npq

  echo "$output" | grep -q "npq requires Node >= 20.13.0"
}

@test "upgrade: aliases are restored once npq works again (converges both ways)" {
  # Convergence has to be bidirectional. A one-way removal would mean a host
  # that upgrades its Node never gets the reputation layer back.
  npq_is_functional || skip "npq non-functional in this image; forward case covered above"
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"

  rm -f "$ALIASES"
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags npq -e podman_enabled=false -e verify_protections=false
  echo "$output" | tail -20
  [ -f "$ALIASES" ]
  grep -q "alias npm='npq-hero'" "$ALIASES"
}

@test "upgrade: re-applying over existing state does not accumulate duplicates" {
  # Cheap guard against the other classic upgrade failure: config appended
  # rather than rewritten, so keys pile up and the LAST one silently wins.
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ -f "$HOME/.npmrc" ] || skip "no user npmrc on this host"
  local dupes
  dupes=$(grep -oE '^[a-z-]+=' "$HOME/.npmrc" | sort | uniq -d | head -5)
  if [ -n "$dupes" ]; then
    echo "duplicate keys in ~/.npmrc after apply:" >&2
    echo "$dupes" >&2
  fi
  [ -z "$dupes" ]
}
