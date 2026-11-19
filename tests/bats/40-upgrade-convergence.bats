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

# Reproduce a FAILED install: npq-hero absent ENTIRELY, distinct from
# shadow_npq_as_suppressed's old-Node case (binary present, passes through).
# Same cp -a / rm dance so npm's symlink-into-node_modules is preserved for
# restore and never written through. Restores via restore_npq (same backup).
hide_npq() {
  REAL_NPQ="$(npq_path)"
  [ -n "$REAL_NPQ" ] || return 1
  cp -a "$REAL_NPQ" "${REAL_NPQ}.upgradetest.bak" || return 1
  rm -f "$REAL_NPQ"
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

@test "upgrade: a stale npq alias file is REMOVED when npq-hero is MISSING, not only suppressed" {
  # The exact state this role put a stock Ubuntu 26 box into. A non-root
  # `npm install -g npq` could not write /usr/local, so the install FAILED and
  # npq-hero was never present — yet the alias file `alias npm='npq-hero'` had
  # already shipped. The functional probe used to split only "npq suppressed"
  # from FUNCTIONAL, so a `command not found` fell through to FUNCTIONAL, the
  # alias was kept, and every interactive npm/yarn/pnpm broke with
  # "npq-hero: command not found". Removal must fire for MISSING too.
  command -v npq-hero >/dev/null 2>&1 || skip "npq not installed in this image"
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"

  hide_npq || skip "could not hide npq-hero"

  # Seed the broken artifact the failed apply left behind.
  cat > "$ALIASES" <<'EOF'
#!/bin/sh
# Managed by ansible-supply-chain-security
export NPQ_DISABLE_AUTO_CONTINUE=true
alias npm='npq-hero'
EOF
  [ -f "$ALIASES" ]

  # Force the reinstall to fail too (bogus version), so npq-hero STAYS missing
  # through the apply — otherwise the fixed `become` install would just heal it
  # and we'd be testing the happy path instead of the removal path.
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags npq -e podman_enabled=false -e verify_protections=false \
    -e npq_version=99.99.99-nonexistent-testonly
  echo "$output" | tail -20

  local present=0
  [ -f "$ALIASES" ] && present=1
  restore_npq

  # Missing backend must fail SAFE: no alias pointing at a binary that isn't there.
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

# ---- cargo: a system-path wrapper that an earlier version left behind ----
#
# MEASURED (VM#2's u2204/u2404 layout, reproduced on Ubuntu 26.04 with apt
# cargo 1.93.1): old main wrapped /usr/bin/cargo with the deployer's
# ~/.cargo/bin PREPENDED to PATH. Once the deployer had a ~/.cargo/bin/cargo of
# their own (rustup, which the role's "rustc too old" record recommends), the
# fixed role discovered that one first and re-rendered only it, so
# /usr/bin/cargo kept the prepend and root and a second account still ran the
# deployer's cargo-cooldown and ~/.cargo/bin/cargo. In this image cargo is in
# /root/.cargo/bin, so the system-path wrapper is seeded at /usr/local/bin.

SYS_CARGO=/usr/local/bin/cargo
SYS_BACKEND=/usr/local/libexec/supply-chain-hardening/cargo/cargo-cooldown

# The shape old main rendered at a system path: the marker, REAL_CARGO, and a
# COOLDOWN_BIN directory prepended to PATH, here one owned by another account.
# Its cargo-real is a stub that prints its argv and PATH. Refuses to clobber.
seed_old_sys_cargo() {
  [ -e "$SYS_CARGO" ] || [ -e "$SYS_CARGO-real" ] || [ -e "${SYS_BACKEND%/*}" ] && return 1
  SEEDED_SYS_CARGO=1
  OLD_BIN=$(mktemp -d /tmp/sch-oldbin.XXXXXX)
  chmod 755 "$OLD_BIN"; chown 65534 "$OLD_BIN"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*"\nprintf "PATH=%%s\\n" "$PATH"\n' > "$SYS_CARGO-real"
  chmod 755 "$SYS_CARGO-real"
  cat > "$SYS_CARGO" <<OLD
#!/bin/bash
# cargo — supply-chain-hardening wrapper
REAL_CARGO='$SYS_CARGO-real'
COOLDOWN_BIN='$OLD_BIN'
if [ -n "\$COOLDOWN_BIN" ] && [ -d "\$COOLDOWN_BIN" ]; then
  case ":\$PATH:" in *":\$COOLDOWN_BIN:"*) ;; *) PATH="\$COOLDOWN_BIN:\$PATH"; export PATH ;; esac
fi
exec "\$REAL_CARGO" "\$@"
OLD
  chmod 755 "$SYS_CARGO"
}

cargo_backend_is_pinned() {
  local pin have
  pin=$(sed -n 's/^cargo_cooldown_version: *"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' "$ROLE_DIR/defaults/main.yml" | head -1)
  have=$("$HOME/.cargo/bin/cargo-cooldown" --version 2>/dev/null | awk '{print $NF}')
  [ -n "$pin" ] && [ "$have" = "$pin" ]
}

apply_cargo() {
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags cargo -e podman_enabled=false -e verify_protections=false "$@"
  echo "$output" | tail -20
}

teardown() {
  if [ -n "${SEEDED_SYS_CARGO:-}" ]; then
    rm -f "$SYS_CARGO" "$SYS_CARGO-real"
    rm -rf /usr/local/libexec/supply-chain-hardening "${OLD_BIN:-/nonexistent-sch}"
  fi
  if [ -n "${CARGO_WRAPPER_BAK:-}" ] && [ -f "$CARGO_WRAPPER_BAK" ]; then
    cp -a "$CARGO_WRAPPER_BAK" "$HOME/.cargo/bin/cargo" && rm -f "$CARGO_WRAPPER_BAK"
  fi
  return 0
}

@test "upgrade: an older cargo wrapper at a system path is re-rendered with the root-owned backend" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "seeds files under /usr/local"
  command -v setpriv >/dev/null || skip "setpriv not installed"
  cargo_backend_is_pinned || skip "no cargo-cooldown at the pinned version in ~/.cargo/bin"
  seed_old_sys_cargo || skip "a cargo or backend already exists under /usr/local"

  apply_cargo
  [ "$status" -eq 0 ]

  # Re-rendered by THIS version: an absolute root-owned backend, no prepend.
  grep -q "^REAL_CARGO='$SYS_CARGO-real'\$" "$SYS_CARGO"
  grep -q "^COOLDOWN_EXE='$SYS_BACKEND'\$" "$SYS_CARGO"
  ! grep -q '^COOLDOWN_BIN=' "$SYS_CARGO"
  ! grep -q 'PATH="$COOLDOWN' "$SYS_CARGO"
  [ -n "$(find "$SYS_BACKEND" -user 0 -perm 0755)" ]
  # The deployer's own wrapper still names the deployer's own copy.
  grep -q "^COOLDOWN_EXE='$HOME/.cargo/bin/cargo-cooldown'\$" "$HOME/.cargo/bin/cargo"

  # Behaviour, as another account: gated through the root-owned copy, and the
  # old directory is nowhere on the PATH cargo gets. A pass-through sfw first,
  # because the wrapper prefixes sfw when one is installed.
  printf '#!/bin/sh\nexec "$@"\n' > "$OLD_BIN.sfw"; mkdir -p "$OLD_BIN.pass"
  mv "$OLD_BIN.sfw" "$OLD_BIN.pass/sfw"; chmod 755 "$OLD_BIN.pass" "$OLD_BIN.pass/sfw"
  run setpriv --reuid=65534 --regid=65534 --clear-groups bash -c \
    "cd /tmp && HOME=/nonexistent PATH='$OLD_BIN.pass:/usr/bin:/bin' '$SYS_CARGO' build 2>&1"
  rm -rf "$OLD_BIN.pass"
  echo "$output"
  [[ "$output" == *"cooldown build"* ]]
  [[ "$output" == *"PATH=$OLD_BIN.pass:/usr/bin:/bin:${SYS_BACKEND%/*}"* ]]
  [[ "$output" != *"PATH=$OLD_BIN:"* ]]
  [[ "$output" != *"refusing"* ]]
}

@test "upgrade: an apply that turns its own gate off leaves the root-owned backend another wrapper names" {
  # A second deployer whose cargo is in ~/.cargo/bin used to delete the shared
  # copy when they set cargo_cooldown_enforce=false (MEASURED with a stub
  # backend on Ubuntu 26.04): the first deployer's /usr/bin/cargo still named
  # it, and that user's builds then ran with --locked only, with no warning.
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "seeds files under /usr/local"
  cargo_backend_is_pinned || skip "no cargo-cooldown at the pinned version in ~/.cargo/bin"
  seed_old_sys_cargo || skip "a cargo or backend already exists under /usr/local"

  apply_cargo
  [ "$status" -eq 0 ]
  grep -q "^COOLDOWN_EXE='$SYS_BACKEND'\$" "$SYS_CARGO"
  [ -x "$SYS_BACKEND" ]
  local before
  before=$(sha256sum < "$SYS_CARGO")
  CARGO_WRAPPER_BAK=$(mktemp)
  cp -a "$HOME/.cargo/bin/cargo" "$CARGO_WRAPPER_BAK"

  apply_cargo -e cargo_cooldown_enforce=false
  [ "$status" -eq 0 ]
  # This apply's own wrapper is rendered with the gate off ...
  grep -q "^COOLDOWN_EXE=''\$" "$HOME/.cargo/bin/cargo"
  # ... but the system-path wrapper and the copy it runs are untouched.
  [ -x "$SYS_BACKEND" ]
  [ "$(sha256sum < "$SYS_CARGO")" = "$before" ]
}
