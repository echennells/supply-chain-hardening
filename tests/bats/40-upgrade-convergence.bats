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
  require_root "writes $ALIASES"

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

  require_root "writes $ALIASES"
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
  require_root "removes $ALIASES"

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

# --- the sfw cache an earlier role version left writable ----------------------
#
# v2.0.0 through 8281a6b chowned sfw's cache (.sfw-cache) to the deploying
# user, and a host hardened by an earlier version was found with it at mode
# 0777 and a user-owned `latest`. sfw runs .sfw-cache/latest without re-checking its
# digest, for every caller including root, so either state lets that account
# pick the binary root runs (VM#1, verified on Debian 13). The old chown also
# used a fixed /usr/local/lib/node_modules path, so on a NodeSource host (npm
# prefix /usr) it created a stray user-owned tree there instead. A re-apply
# must undo all of it, and must leave a clean cache alone.

sfw_cache_dir() {
  local s
  s=$(readlink -f "$(command -v sfw 2>/dev/null)" 2>/dev/null) || return 1
  s=${s%/*}; s=${s%/*}
  [ -f "$s/package.json" ] || return 1
  echo "$s/.sfw-cache"
}

# The sfw tests below change the suite's real sfw: they plant a writable cache
# or install sfw@2.0.4. A test that fails partway would leave that for every
# later file in the container (42-*, 49-*), which then fail for the wrong
# reason: on a tree without the 2.0.4 replacement, 42-*'s real-sfw cargo test
# failed with 2.0.4's "EACCES ... next-check". sfw_snapshot saves the clean
# state; teardown puts it back only when a test left it otherwise.
sfw_snapshot() {
  SFW_SNAP_CACHE=$1
  SFW_SNAP_BIN=$(command -v sfw)
  SFW_SNAP_PIN=$(sed -n 's/^sfw_version: *"\([^"]*\)".*/\1/p' "$ROLE_DIR/defaults/main.yml")
  cp -a "$SFW_SNAP_CACHE" "$BATS_TEST_TMPDIR/sfw-cache-saved"
}

sfw_teardown() {
  [ -n "${SFW_SNAP_CACHE:-}" ] || return 0
  local c=$SFW_SNAP_CACHE shim t
  hash -r
  shim=$(readlink -f "$(command -v sfw 2>/dev/null)" 2>/dev/null)
  if [ -z "$shim" ] || ! grep -q "\"version\": \"$SFW_SNAP_PIN\"" "${shim%/dist/*}/package.json" 2>/dev/null; then
    echo "# teardown: restoring sfw@$SFW_SNAP_PIN" >&3
    rm -f "$SFW_SNAP_BIN.broken"
    npm install -g --ignore-scripts "sfw@$SFW_SNAP_PIN" >/dev/null 2>&1
    hash -r
  fi
  t=$(readlink -f "$c/latest" 2>/dev/null)
  if [ ! -d "$c" ] || [ -L "$c" ] || [[ "$t" != "$c"/* ]] \
     || [ -n "$(find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print -quit 2>/dev/null)" ]; then
    echo "# teardown: restoring the clean sfw cache" >&3
    rm -rf "$c"; cp -a "$BATS_TEST_TMPDIR/sfw-cache-saved" "$c"
  fi
  rm -f /tmp/sfwprior-bin /tmp/sfwprior-root-marker
  return 0
}

@test "upgrade: a re-apply resets an sfw cache an earlier version left writable, and removes the stray tree" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to seed root-owned state"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  id sfwprior >/dev/null 2>&1 || useradd -m -s /bin/bash sfwprior
  sfw_snapshot "$c"

  # Seed both prior states on the real cache: 0777, and a `latest` owned by a
  # non-root account that points at a binary of its own.
  printf '#!/bin/sh\necho NOT-THE-REAL-SFW\n' > /tmp/sfwprior-bin
  chmod 755 /tmp/sfwprior-bin; chown sfwprior /tmp/sfwprior-bin
  chmod 0777 "$c"
  ln -sfn /tmp/sfwprior-bin "$c/latest"; chown -h sfwprior "$c/latest"
  # And the stray tree, on a host whose real cache is elsewhere.
  stray=""
  if [ "${c%/sfw/.sfw-cache}" != /usr/local/lib/node_modules ] && [ ! -e /usr/local/lib/node_modules/sfw ]; then
    stray=/usr/local/lib/node_modules/sfw/.sfw-cache
    mkdir -p "$stray"; chown sfwprior "$stray" "${stray%/.sfw-cache}"
  fi

  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags socket -e podman_enabled=false -e verify_protections=false
  echo "$output" | tail -25
  rm -f /tmp/sfwprior-bin
  [ "$status" -eq 0 ]

  # Root-owned, writable by nobody else, and `latest` is the downloaded binary.
  run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  echo "non-root or group/other-writable: $output"
  [ -z "$output" ]
  [ "$(stat -c '%a' "$c")" = 755 ]
  t=$(readlink -f "$c/latest")
  [[ "$t" == "$c"/* ]]
  [ "$(stat -c %u "$t")" = 0 ]
  run sfw --version
  [[ "$output" != *NOT-THE-REAL-SFW* ]]
  if [ -n "$stray" ]; then
    [ ! -e "${stray%/.sfw-cache}" ]
  fi
}

@test "upgrade: the reset comes before the role's own root npm installs, so none of them runs a planted sfw binary" {
  # npm.yml and npq.yml run `npm install -g` as root, through the npm wrapper an
  # earlier apply left and so through sfw. MEASURED on Debian 13 (apt npm) while
  # the reset still opened socket.yml, which runs after both: with the cache
  # 0777 and `latest` repointed by another account, an apply with
  # refresh_tools=true ran the planted binary as root from "Install lockfile-lint
  # globally", nine seconds before the reset. refresh_tools=true is what makes
  # that install run on a host that already has lockfile-lint.
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to seed root-owned state"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  grep -q '^# Managed by ansible-supply-chain-security' /usr/local/bin/npm 2>/dev/null \
    || skip "no npm wrapper at /usr/local/bin/npm to route root's installs through sfw"
  id sfwprior >/dev/null 2>&1 || useradd -m -s /bin/bash sfwprior
  sfw_snapshot "$c"

  m=/tmp/sfwprior-root-marker
  rm -f "$m"
  printf '#!/bin/sh\n[ "$(id -u)" = 0 ] && echo ran-as-root >> %s\nexit 0\n' "$m" > /tmp/sfwprior-bin
  chmod 755 /tmp/sfwprior-bin; chown sfwprior /tmp/sfwprior-bin
  chmod 0777 "$c"
  ln -sfn /tmp/sfwprior-bin "$c/latest"; chown -h sfwprior "$c/latest"

  # FIXTURE CONTROL: in this state root's npm, through the wrapper, runs the
  # planted binary. Without that, a missing marker below would prove nothing.
  /usr/local/bin/npm view is-number version </dev/null >/dev/null 2>&1 || true
  if [ ! -e "$m" ]; then
    echo "FIXTURE CONTROL failed: root's npm did not run the planted sfw binary" >&2
    false
  fi
  rm -f "$m"

  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags npm -e podman_enabled=false -e verify_protections=false -e refresh_tools=true
  rm -f /tmp/sfwprior-bin
  printf '%s\n' "$output" | grep -A1 -E 'TASK \[.*(Reset an sfw cache|Install lockfile-lint globally|Install npq globally|Install Socket Firewall)' || true
  [ "$status" -eq 0 ]
  # The root install this is about ran; a skipped one would leave no marker
  # either way.
  st=$(printf '%s\n' "$output" | grep -A1 'TASK \[.*Install lockfile-lint globally' | tail -n 1)
  [ -n "$st" ]
  [[ "$st" != skipping:* ]]
  # The reset came first, and the planted binary never ran as root.
  reset_at=$(printf '%s\n' "$output" | grep -n 'TASK \[.*Reset an sfw cache' | head -n 1 | cut -d: -f1)
  install_at=$(printf '%s\n' "$output" | grep -n 'TASK \[.*Install lockfile-lint globally' | head -n 1 | cut -d: -f1)
  echo "reset task at line $reset_at, lockfile-lint install at line $install_at"
  [ -n "$reset_at" ] && [ "$reset_at" -lt "$install_at" ]
  if [ -e "$m" ]; then
    echo "the planted sfw binary ran as root during the apply: $(cat "$m")" >&2
    false
  fi
}

@test "upgrade: a re-apply leaves a clean sfw cache alone (no re-download)" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  # A fresh next-check, so the apply-time warm makes no update check either.
  date -u -d '+30 min' +%Y-%m-%dT%H:%M:%S.000Z | tr -d '\n' > "$c/next-check"
  before=$(stat -c %i "$(readlink -f "$c/latest")")

  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags socket -e podman_enabled=false -e verify_protections=false
  st=$(printf '%s\n' "$output" | grep -A1 'TASK \[.*Reset an sfw cache' | tail -n 1)
  echo "reset task: $st"
  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$(readlink -f "$c/latest")")" = "$before" ]
  # The reset task ran and found nothing to change.
  [[ "$st" == ok:* ]]
}

@test "upgrade: an sfw that root does not own is reported and left alone, and the play completes" {
  # The reset refuses to judge or warm an sfw whose files another account
  # could have written (root would run them). Its record used a regex
  # back-reference written '\\1', which Ansible's templating turns into a
  # literal backslash: the set_fact raised "'NoneType' object has no
  # attribute 'group'" and failed the play (MEASURED with ansible-core 2.16).
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to change the owner of sfw"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  pkg=${c%/.sfw-cache}
  id sfwprior >/dev/null 2>&1 || useradd -m -s /bin/bash sfwprior
  before=$(stat -c %i "$(readlink -f "$c/latest")")

  chown sfwprior "$pkg"
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags socket -e podman_enabled=false -e verify_protections=false
  chown root "$pkg"
  echo "$output" | tail -25
  [ "$status" -eq 0 ]
  [[ "$output" == *"Socket Firewall — root resolves sfw to $pkg/"*"which root does not own"* ]]
  # Neither reset nor re-downloaded.
  [ "$(stat -c %i "$(readlink -f "$c/latest")")" = "$before" ]
}

# --- an sfw older than 2.0.6 ---------------------------------------------------
#
# The npm and cargo wrappers run sfw with SFW_SKIP_UPDATE_CHECK=1 so that a
# non-root caller never writes its root-owned cache, and only sfw 2.0.6 reads
# that variable (2.0.4's shouldCheckForUpdate() has no such test; there is no
# 2.0.5). Role releases before v2.0.0 installed a floating `sfw@2`, which was
# 2.0.4 until 2026-05-22, and the install used to run only when sfw was absent,
# so those hosts kept it. MEASURED on NodeSource with this branch before the
# fix: every non-root npm and cargo call failed an hour after the apply with
# "[sfw] Failed to prepare firewall binary: EACCES ... next-check". A re-apply
# must replace it, and when it cannot, move it aside and say so.

@test "upgrade: an sfw older than 2.0.6 is replaced, or moved aside and reported when it cannot be" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to install a global sfw"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  want=$(sed -n 's/^sfw_version: *"\([^"]*\)".*/\1/p' "$ROLE_DIR/defaults/main.yml")
  true_bin=/usr/bin/true; [ -x "$true_bin" ] || true_bin=/bin/true
  id sfwprior >/dev/null 2>&1 || useradd -m -s /bin/bash sfwprior

  # The prior state: 2.0.4, installed and warmed by root. Installing it
  # replaces the package directory, so put the warm cache back afterwards;
  # that keeps this test to one binary download.
  sfw_snapshot "$c"
  npm install -g --ignore-scripts sfw@2.0.4 >/dev/null 2>&1 || skip "could not install sfw@2.0.4 (offline?)"
  rm -rf "$c"; cp -a "$BATS_TEST_TMPDIR/sfw-cache-saved" "$c"
  shim=$(readlink -f "$(command -v sfw)")
  run grep -c SFW_SKIP_UPDATE_CHECK "$shim"
  [ "$output" = 0 ]

  # 1) The replacement leaves it old (sfw_version pins 2.0.4 here): moved
  #    aside, so the wrappers pass through instead of failing, and recorded.
  sfw_path=$(command -v sfw)
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags socket -e podman_enabled=false -e verify_protections=false -e sfw_version=2.0.4
  echo "$output" | tail -25
  [ "$status" -eq 0 ]
  [[ "$output" == *"Socket Firewall — sfw 2.0.4 at $sfw_path predates 2.0.6"* ]]
  [[ "$output" == *"sfw_version must be 2.0.6 or later"* ]]
  hash -r
  [ -z "$(command -v sfw)" ]
  [ -e "$sfw_path.broken" ]

  # 2) The default pin: sfw is reinstalled at sfw_version, warmed by root, and
  #    a non-root caller runs it read-only once the update check is due.
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags socket -e podman_enabled=false -e verify_protections=false
  echo "$output" | tail -25
  rm -f "$sfw_path.broken"
  [ "$status" -eq 0 ]
  hash -r
  shim=$(readlink -f "$(command -v sfw)")
  grep -q SFW_SKIP_UPDATE_CHECK "$shim"
  grep -q "\"version\": \"$want\"" "${shim%/dist/*}/package.json"
  [ -e "$c/latest" ]
  run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  [ -z "$output" ]
  printf '2026-01-01T00:00:00.000Z' > "$c/next-check"
  run su -s /bin/sh sfwprior -c "SFW_SKIP_UPDATE_CHECK=1 '$(command -v sfw)' $true_bin"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$c/next-check")" = "2026-01-01T00:00:00.000Z" ]
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

cargo_teardown() {
  if [ -n "${SEEDED_SYS_CARGO:-}" ]; then
    rm -f "$SYS_CARGO" "$SYS_CARGO-real"
    rm -rf /usr/local/libexec/supply-chain-hardening "${OLD_BIN:-/nonexistent-sch}"
  fi
  if [ -n "${CARGO_WRAPPER_BAK:-}" ] && [ -f "$CARGO_WRAPPER_BAK" ]; then
    cp -a "$CARGO_WRAPPER_BAK" "$HOME/.cargo/bin/cargo" && rm -f "$CARGO_WRAPPER_BAK"
  fi
  return 0
}

# Both sections above leave state for later files when a test fails partway;
# bats runs one teardown, so it calls both.
teardown() {
  sfw_teardown
  cargo_teardown
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
