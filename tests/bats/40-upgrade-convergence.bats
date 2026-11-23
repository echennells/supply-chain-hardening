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
  applied=$output

  # The reset cache is filled from GitHub again. When GitHub refuses both
  # downloads, the pinned one and sfw's own, the role says so by name and the play
  # completes. The security half still has to hold: the planted binary is gone
  # and nothing in the cache is writable by another account. Only the "a fresh
  # binary is in place" half needs the download, so skip just that.
  if [[ "$output" == *"its runtime binary could not be fetched from GitHub"* ]]; then
    [ "$(readlink "$c/latest" 2>/dev/null)" != /tmp/sfwprior-bin ]
    if [ -d "$c" ]; then
      run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
      [ -z "$output" ]
    fi
    if [ -n "$stray" ]; then [ ! -e "${stray%/.sfw-cache}" ]; fi
    skip "sfw's binary could not be re-downloaded from GitHub; the reset's security checks passed"
  fi

  # Root-owned, writable by nobody else, and `latest` is the downloaded binary.
  run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  echo "non-root or group/other-writable: $output"
  [ -z "$output" ]
  [ "$(stat -c '%a' "$c")" = 755 ]
  t=$(readlink -f "$c/latest")
  [[ "$t" == "$c"/* ]]
  [ "$(stat -c %u "$t")" = 0 ]
  # The pinned binary, whose digest the role checked, and not the planted one
  # (sfw's own download where the release URL did not answer and the API did).
  if [[ "$applied" != *"was not used: downloading it failed"* ]]; then
    [ "$t" = "$c/$(sfw_pin_version)/sfw-free-$(sfw_pin_key)" ]
    [ "$(sha256sum < "$t" | cut -d' ' -f1)" = "$(sfw_pin_sum)" ]
  fi
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
  # Reinstalling replaces the package directory, so the warm downloads the
  # firewall binary again. If GitHub refuses it (a known CI flake), the role
  # names that and moves sfw aside rather than leave a wrapper that fails. That
  # is correct; what cannot be checked without the download is skipped, but
  # the 2.0.4 shim must not be what is left on PATH.
  if [[ "$output" == *"its runtime binary could not be fetched from GitHub"* ]]; then
    if s=$(readlink -f "$(command -v sfw 2>/dev/null)" 2>/dev/null) && [ -n "$s" ] \
       && grep -q '"version": "2.0.4"' "${s%/dist/*}/package.json"; then
      echo "the 2.0.4 shim is still what sfw runs: $s"
      return 1
    fi
    skip "sfw's binary could not be downloaded from GitHub after the reinstall; the 2.0.4 shim was not left in place"
  fi
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

# --- sfw_version: a bump, or a pin-down, reaches a host that has sfw ---------
#
# The install ran only when sfw was absent (or older than 2.0.6), so moving
# sfw_version never reached a host that already had sfw. MEASURED on 6c77f4e:
# with the installed package at another version than sfw_version, either way, a
# re-apply left it as it was (changed=0). Only one sfw release is 2.0.6 or later
# (the registry's list on 2026-11-20: 1.0.0, 2.0.1-2.0.4, 2.0.6), so the other
# version is the installed package.json relabelled: what the role reads to decide.

sfw_pkg_json() { echo "$(npm root -g)/sfw/package.json"; }
sfw_relabel() { sed -i "s/\"version\": *\"[^\"]*\"/\"version\": \"$1\"/" "$(sfw_pkg_json)"; }
sfw_label() { sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$(sfw_pkg_json)" 2>/dev/null | head -n 1; }
socket_apply() {
  cd "$ROLE_DIR"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags socket -e podman_enabled=false -e verify_protections=false "$@"
}
task_result() { printf '%s\n' "$output" | grep -F -A1 "$1" | tail -n 1; }

@test "upgrade: an installed sfw at another version than sfw_version is replaced, both ways, and a re-apply then changes nothing" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to install a global sfw"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  [ "$(dirname "$(sfw_pkg_json)")" = "${c%/.sfw-cache}" ] || skip "root's npm root -g is not where the sfw on PATH lives"
  want=$(sed -n 's/^sfw_version: *"\([^"]*\)".*/\1/p' "$ROLE_DIR/defaults/main.yml")
  sfw_snapshot "$c"
  local from
  for from in 2.0.7 2.0.5; do
    sfw_relabel "$from"
    [ "$(sfw_label)" = "$from" ]
    socket_apply
    echo "$output" | tail -20
    [ "$status" -eq 0 ]
    st=$(task_result "Install Socket Firewall Free via npm")
    echo "installed $from, sfw_version $want: install $st"
    [[ "$st" == changed:* ]] || { echo "an sfw labelled $from was not replaced with $want"; return 1; }
    [ "$(sfw_label)" = "$want" ]
    hash -r
    # Reinstalling replaces the package directory, so the warm downloads the
    # firewall binary again. When GitHub refuses it (a known flake), sfw is moved
    # aside and named in the summary; what still has to hold is the version,
    # and nothing anyone else can write in the cache.
    if [[ "$output" == *"its runtime binary could not be fetched from GitHub"* ]]; then
      if [ -d "$c" ]; then
        run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
        [ -z "$output" ]
      fi
      skip "sfw's binary could not be downloaded from GitHub after the reinstall; the version converged to $want"
    fi
    [ -e "$c/latest" ]
    run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
    [ -z "$output" ]
  done

  # Converged: nothing to replace.
  socket_apply
  [ "$status" -eq 0 ]
  st=$(task_result "Install Socket Firewall Free via npm")
  [[ "$st" == skipping:* ]] || { echo "a re-apply at sfw_version still ran the install: $st"; return 1; }

  # A pin below 2.0.6 does not take a working sfw down to a version the
  # wrappers cannot use; the apply says so.
  before=$(stat -c %i "${c%/.sfw-cache}")
  socket_apply -e sfw_version=2.0.4
  [ "$status" -eq 0 ]
  [[ "$(task_result "Install Socket Firewall Free via npm")" == skipping:* ]]
  [[ "$output" == *"sfw_version=2.0.4 is below 2.0.6"*"was left in place"* ]]
  # In the run summary, as a setting not applied, not as a missing protection.
  [[ "$output" == *"setting(s) were not applied as configured"* ]]
  [[ "$output" != *"protection(s) were NOT applied"* ]]
  [ "$(sfw_label)" = "$want" ]
  [ "$(stat -c %i "${c%/.sfw-cache}")" = "$before" ]
}

# A dist-tag or a range has no version to compare. Ansible's version test
# raised on one ("Version comparison failed: '<' not supported between
# instances of 'str' and 'int'"), so the version move above failed the play at
# its first task (MEASURED: sfw_version=latest and ^2.0.6 over sfw 2.0.6, rc=2;
# a full apply skipped every include after socket.yml). Before the version move
# existed such a pin was accepted, and installed only where sfw was absent or
# too old. It still is, and over a working sfw the summary says it was kept.
@test "upgrade: an sfw_version naming no single release (a dist-tag or a range) keeps a working sfw, says so, and the play goes on" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to install a global sfw"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  sfw_snapshot "$c"
  before=$(stat -c %i "${c%/.sfw-cache}")
  local pin
  for pin in latest '^2.0.6' 2; do
    socket_apply -e "sfw_version=$pin"
    echo "$output" | tail -20
    [[ "$output" != *"Version comparison failed"* ]] || { echo "sfw_version=$pin failed the play on a version test"; return 1; }
    [ "$status" -eq 0 ]
    [[ "$(task_result "Install Socket Firewall Free via npm")" == skipping:* ]]
    [[ "$output" == *"sfw_version=$pin is not a plain X.Y.Z version"*"that sfw was kept and is in use"* ]]
    # `2` is a range to npm (any 2.x), not a version below 2.0.6.
    [[ "$output" != *"is below 2.0.6"* ]]
    [ "$(stat -c %i "${c%/.sfw-cache}")" = "$before" ]
  done

  # Over an sfw older than 2.0.6 such a pin is what the install asks npm for,
  # and the record of an sfw still too old afterwards renders (it ran the same
  # version test). '<2.0.6' resolves to 2.0.4, so it stays too old.
  npm install -g --ignore-scripts sfw@2.0.4 >/dev/null 2>&1 || skip "could not install sfw@2.0.4 (offline?)"
  rm -rf "$c"; cp -a "$BATS_TEST_TMPDIR/sfw-cache-saved" "$c"
  hash -r
  sfw_path=$(command -v sfw)
  socket_apply -e 'sfw_version=<2.0.6'
  echo "$output" | tail -25
  [[ "$output" != *"Version comparison failed"* ]] || { echo "sfw_version=<2.0.6 failed the play on a version test"; return 1; }
  [ "$status" -eq 0 ]
  [[ "$(task_result "Install Socket Firewall Free via npm")" == changed:* ]]
  [[ "$output" == *"sfw 2.0.4 at $sfw_path predates 2.0.6"* ]]
  [[ "$output" == *"resolved to a release below 2.0.6, or the new copy is behind this one"* ]]
  hash -r
  [ -z "$(command -v sfw)" ]
  [ -e "$sfw_path.broken" ]
}

# The version move runs the install over a working sfw. When that install
# fails, npm leaves the old package in place. MEASURED with sfw 2.0.6 and
# sfw_version=2.0.99 (not published): the warm ran the old sfw (ok), another
# account's npm install still went through it, and the summary said "install
# failed. npm installs are not threat-intel filtered" and counted a protection
# NOT applied, on every apply.
@test "upgrade: a failed replacement over a working sfw names the sfw still in use, and claims no protection lost" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to apply the socket tasks"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  sfw_snapshot "$c"
  want=$SFW_SNAP_PIN
  bin=$(command -v sfw)
  before=$(stat -c %i "${c%/.sfw-cache}")

  socket_apply -e sfw_version=2.0.99
  echo "$output" | tail -25
  [ "$status" -eq 0 ]
  st=$(task_result "Install Socket Firewall Free via npm"); echo "install: $st"
  [[ "$st" == ok:* ]] || { echo "the install did not run, or counted as a change"; return 1; }
  [[ "$output" == *"replacing sfw $want with sfw_version 2.0.99 failed (exit "* ]] \
    || { echo "no entry names the failed replacement (did npm install 2.0.99?)"; return 1; }
  [[ "$output" == *"sfw $want at /"*" is still installed and in use"* ]]
  [[ "$output" != *"install failed. npm installs are not threat-intel filtered"* ]]
  [[ "$output" != *"protection(s) were NOT applied"* ]]
  [[ "$(task_result "Warm the Socket Firewall binary cache")" == ok:* ]]
  hash -r
  [ "$(command -v sfw)" = "$bin" ]
  [ "$(sfw_label)" = "$want" ]
  [ "$(stat -c %i "${c%/.sfw-cache}")" = "$before" ]
  [ -e "$c/latest" ]
}

# --check skips the install (a command), so a dry run over an sfw at another
# version reported changed=0 and nothing else: it looked converged.
@test "upgrade: a --check run over an sfw at another version says a real run would replace it, and changes nothing" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to apply the socket tasks"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  [ "$(dirname "$(sfw_pkg_json)")" = "${c%/.sfw-cache}" ] || skip "root's npm root -g is not where the sfw on PATH lives"
  sfw_snapshot "$c"
  want=$SFW_SNAP_PIN
  before=$(stat -c %i "${c%/.sfw-cache}")
  sfw_relabel 2.0.7
  socket_apply --check
  echo "$output" | tail -20
  [ "$status" -eq 0 ]
  [[ "$output" == *"this --check run did not replace the installed sfw 2.0.7 with sfw_version $want; a real run would"* ]]
  [ "$(sfw_label)" = 2.0.7 ]
  [ "$(stat -c %i "${c%/.sfw-cache}")" = "$before" ]
  sfw_relabel "$want"
}

# --- an sfw moved aside after a failed fetch --------------------------------
#
# When the warm cannot fetch the firewall binary, sfw is moved aside
# (sfw -> sfw.broken) and every later apply reinstalls it to try again. MEASURED
# on 6c77f4e with GitHub unreachable: each re-apply reported the install changed
# (changed=1), ending exactly where it began. It now counts as a change only
# when sfw comes back.
HOSTS_SAVED=""
hosts_block() { # <host>...
  cp /etc/hosts "$BATS_TEST_TMPDIR/hosts.saved" && HOSTS_SAVED=1
  local h
  for h in "$@"; do
    echo "127.0.0.1 $h" >> /etc/hosts
  done
}
# The API sfw asks, and the release URL the role takes its pinned binary from.
hosts_block_github() {
  hosts_block github.com api.github.com objects.githubusercontent.com release-assets.githubusercontent.com codeload.github.com
}
# What a used-up quota leaves: sfw cannot fetch, the release URL still answers.
hosts_block_api() { hosts_block api.github.com; }
hosts_restore() {
  [ -n "$HOSTS_SAVED" ] || return 0
  cat "$BATS_TEST_TMPDIR/hosts.saved" > /etc/hosts; HOSTS_SAVED=""
}

@test "upgrade: an sfw moved aside after a failed fetch is retried on every apply, and reported changed only when it comes back" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to move sfw and edit /etc/hosts"
  [ -w /etc/hosts ] || skip "/etc/hosts is not writable here"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  sfw_snapshot "$c"
  bin=$(command -v sfw)

  # What a failed warm leaves: sfw moved aside, and no binary cached.
  hosts_block_github
  mv "$bin" "$bin.broken"; rm -rf "$c"; hash -r
  socket_apply
  echo "$output" | tail -20
  [ "$status" -eq 0 ]
  [[ "$output" == *"its runtime binary could not be fetched from GitHub"* ]] \
    || { echo "the fetch did not fail with GitHub blocked; nothing to test"; return 1; }
  # With the release URL blocked too, the pinned binary is no way out, and the
  # record says both.
  [[ "$output" == *"(exit 1: [sfw] Failed to prepare firewall binary: "*"The pinned $(sfw_pin_version) was not used either: downloading it failed (Request failed: "* ]]
  [ ! -e "$c/latest" ]
  [ ! -e "${c%/.sfw-cache}/.sfw-seed" ]
  st=$(task_result "Install Socket Firewall Free via npm"); echo "blocked: install $st"
  [[ "$st" == ok:* ]]
  st=$(task_result "Warm the Socket Firewall binary cache"); echo "blocked: warm $st"
  [[ "$st" == ok:* ]]
  hash -r
  [ -z "$(command -v sfw)" ]

  # Reachable again: the same retry brings sfw back, and that is the change.
  hosts_restore
  socket_apply
  echo "$output" | tail -20
  [ "$status" -eq 0 ]
  if [[ "$output" == *"its runtime binary could not be fetched from GitHub"* ]]; then
    skip "GitHub refused the download with nothing blocked (a known flake); the blocked half passed"
  fi
  st=$(task_result "Warm the Socket Firewall binary cache"); echo "reachable: warm $st"
  [[ "$st" == changed:* ]]
  hash -r
  [ "$(command -v sfw)" = "$bin" ]
  rm -f "$bin.broken"
  [ -e "$c/latest" ]
  run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  [ -z "$output" ]
}

# --- the pinned firewall binary ----------------------------------------------
#
# sfw asks the GitHub API which binary to download, without credentials.
# MEASURED 2026-11-23: with that API answering 403, sfw 2.0.6 exits 1 in 0.3 s,
# the role moved it aside, and npm and cargo ran unfiltered. An sfw that has
# nothing cached now gets a pinned release from its download URL first, held to
# its SHA-256 before it can reach the cache (tasks/sfw_seed.yml).
sfw_pin_version() { sed -n 's/^sfw_binary_version: *"\([^"]*\)".*/\1/p' "$ROLE_DIR/defaults/main.yml"; }
sfw_pin_key() { (cd / && node -p '({"linux-x64": "linux-x86_64", "linux-arm64": "linux-arm64"})[process.platform + "-" + process.arch] || ""'); }
sfw_pin_sum() { sed -n "s/^  $(sfw_pin_key): *\"sha256:\([0-9a-f]*\)\".*/\1/p" "$ROLE_DIR/defaults/main.yml"; }
recap_changed() { printf '%s\n' "$output" | sed -n 's/.* changed=\([0-9]*\) .*/\1/p' | tail -n 1; }

sfw_pin_preconditions() {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to empty sfw's cache and edit /etc/hosts"
  [ -w /etc/hosts ] || skip "/etc/hosts is not writable here"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  pkg=${c%/.sfw-cache}; bin=$(command -v sfw)
  v=$(sfw_pin_version); sum=$(sfw_pin_sum)
  [ -n "$v" ] || return 1
  [ ${#sum} -eq 64 ] || return 1
  sfw_snapshot "$c"
}

# The release URL is a network dependency too. Only the role's own record that
# the DOWNLOAD failed (no answer, or a 403, 429 or 5xx) excuses what needs it.
skip_if_pin_unreachable() {
  if printf '%s' "$output" | grep -qE 'The pinned v[0-9.]+ was not used either: downloading it failed [(](Request failed: (<urlopen error|HTTP Error (403|429|5[0-9][0-9]))|failed to create temporary content file)'; then
    skip "the pinned binary could not be downloaded from GitHub's release URL${1:+; $1}"
  fi
}

# sfw in place, whole, with nothing cached.
sfw_cold() {
  [ ! -e "$bin.broken" ] || mv -f "$bin.broken" "$bin"
  rm -rf "$c"; hash -r
}

@test "upgrade: with the GitHub API refused, an sfw with nothing cached runs the pinned binary, and a re-apply changes nothing" {
  sfw_pin_preconditions
  id sfwprior >/dev/null 2>&1 || useradd -m -s /bin/bash sfwprior
  hosts_block_api

  # FIXTURE CONTROL: without the pin this is a failed fetch, and npm and cargo
  # are left with no sfw.
  sfw_cold
  socket_apply -e sfw_binary_pin=false
  [ "$status" -eq 0 ]
  [[ "$output" == *"its runtime binary could not be fetched from GitHub (exit 1: [sfw] Failed to prepare firewall binary: Unable to fetch latest release"* ]] \
    || { echo "the fetch did not fail with the API blocked; nothing to test"; return 1; }
  [[ "$output" != *"The pinned v"* ]]
  hash -r; [ -z "$(command -v sfw)" ]
  [ -e "$bin.broken" ]

  # The same host with it: the retry brings sfw back.
  socket_apply
  echo "$output" | tail -20
  [ "$status" -eq 0 ]
  skip_if_pin_unreachable "the API-refused control failed as it should"
  [[ "$output" != *"could not be fetched from GitHub ("* ]]
  [[ "$(task_result "Warm the Socket Firewall binary cache")" == changed:* ]]
  hash -r; [ "$(command -v sfw)" = "$bin" ]
  rm -f "$bin.broken"
  t=$(readlink -f "$c/latest")
  [ "$t" = "$c/$v/sfw-free-$(sfw_pin_key)" ]
  [ "$(sha256sum < "$t" | cut -d' ' -f1)" = "$sum" ]
  # Root's, readable by everyone, writable by nobody else, nothing left behind.
  [ "$(stat -c '%u:%g %a' "$t")" = "0:0 755" ]
  [ "$(stat -c '%u:%g %a' "$c")" = "0:0 755" ]
  [ "$(stat -c '%u:%g %a' "$c/$v")" = "0:0 755" ]
  run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  [ -z "$output" ]
  [ ! -e "$pkg/.sfw-seed" ]
  # The next update check is an hour off, as after sfw's own fetch, so sfw run
  # by hand by another account works too (it cannot write that file, and fails
  # when it has to).
  local left=$(( $(date -d "$(cat "$c/next-check")" +%s) - $(date +%s) ))
  echo "next update check in ${left}s"
  [ "$left" -gt 3000 ]
  [ "$left" -le 3600 ]
  [ "$(stat -c '%u:%g %a' "$c/next-check")" = "0:0 644" ]
  run su - sfwprior -c "sfw true"
  echo "$output"
  [ "$status" -eq 0 ]

  # Another account's npm goes through it: sfw runs its child behind its own CA.
  PROJ=$(mktemp -d /tmp/sfw-pin.XXXXXX)
  printf '{"name":"sfw-pin-probe","version":"1.0.0"}\n' > "$PROJ/package.json"
  mkdir "$PROJ/pkg"; printf '{"name":"sfw-pin-dep","version":"1.0.0"}\n' > "$PROJ/pkg/package.json"
  printf 'console.log("CA=" + (process.env.NODE_EXTRA_CA_CERTS || "none"))\n' > "$PROJ/env.js"
  chown -R sfwprior "$PROJ"; chmod 755 "$PROJ"
  run su - sfwprior -c "cd '$PROJ' && npm install --no-audit --no-fund ./pkg 2>&1 && npm exec --yes -- node ./env.js 2>&1"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CA="*socketFirewall* ]]
  [[ "$output" != *"[supply-chain-hardening] warning"* ]]
  [ -e "$PROJ/node_modules/sfw-pin-dep" ]
  rm -rf -- "$PROJ"

  # Converged: the reset accepts the cache as it is, nothing is downloaded, and
  # nothing changes. sfw's update check is due here and refused; it keeps what
  # it has.
  printf '2026-01-01T00:00:00.000Z' > "$c/next-check"
  before=$(stat -c %i "$t")
  socket_apply
  [ "$status" -eq 0 ]
  echo "second apply: changed=$(recap_changed)"
  [ "$(recap_changed)" = 0 ]
  [[ "$(task_result "Reset an sfw cache")" == ok:* ]]
  [[ "$(task_result "Download the pinned firewall binary")" == skipping:* ]]
  [ "$(readlink -f "$c/latest")" = "$t" ]
  [ "$(stat -c %i "$t")" = "$before" ]
}

@test "upgrade: a download that is not the pinned binary is refused, and sfw does not get to fetch one itself" {
  sfw_pin_preconditions
  # The API is NOT blocked: sfw's own download is what this must not reach. With
  # the API reachable, the code before this change ended here with sfw's current
  # release in the cache, run as root.
  zeros=$(printf '0%.0s' $(seq 64))
  bad() { socket_apply -e "{\"sfw_binary_checksums\": {\"$(sfw_pin_key)\": \"sha256:$zeros\"}}"; }
  refused_now() {
    echo "$output" | grep -E 'Socket Firewall —|changed=' | cut -c1-300
    [ "$status" -eq 0 ] || return 1
    # What it downloaded is the release the shipped pin names, so the digest is
    # the only thing that kept it out.
    [[ "$output" == *"Socket Firewall — REFUSED: the pinned firewall binary (sfw_binary_version $v) is not the file its checksum names: the download's sha256 is $sum, not the pinned $zeros. "*"sfw was moved aside"* ]] || return 1
    [[ "$output" != *"could not be fetched from GitHub ("* ]] || return 1
    [[ "$output" == *"protection(s) were NOT applied"* ]] || return 1
    [[ "$(task_result "Warm the Socket Firewall binary cache")" == skipping:* ]] || return 1
    [ ! -e "$c/latest" ] || return 1
    [ ! -L "$c/latest" ] || return 1
    [ -z "$(find "$pkg" -name 'sfw-free-*' -o -name .sfw-seed)" ] || return 1
    hash -r; [ -z "$(command -v sfw)" ] || return 1
    [ -e "$bin.broken" ]
  }
  sfw_cold
  bad
  if [[ "$output" == *"was not used"*"downloading it failed"* ]]; then
    skip "the pinned binary could not be downloaded from GitHub's release URL"
  fi
  refused_now
  # Again: refused again, ending where it began, so nothing changed.
  bad
  refused_now
  [ "$(recap_changed)" = 0 ]
  # With the right digest the next apply brings sfw back.
  socket_apply
  [ "$status" -eq 0 ]
  skip_if_pin_unreachable "the refusals passed"
  [[ "$output" != *"REFUSED"* ]]
  hash -r; [ "$(command -v sfw)" = "$bin" ]
  [ "$(sha256sum < "$(readlink -f "$c/latest")" | cut -d' ' -f1)" = "$sum" ]
}

@test "upgrade: a binary sfw already has cached is left alone, whatever its version" {
  sfw_pin_preconditions
  hosts_block_api
  # A newer release, as the refresh timer leaves it: the pin is not in the cache.
  t=$(readlink -f "$c/latest")
  mv "${t%/*}" "$c/v99.0.0"
  ln -sfn "$c/v99.0.0/${t##*/}" "$c/latest"
  t=$c/v99.0.0/${t##*/}
  printf '2026-01-01T00:00:00.000Z' > "$c/next-check"
  before=$(stat -c '%i %Y %s' "$t")
  socket_apply
  echo "$output" | tail -20
  [ "$status" -eq 0 ]
  [ "$(recap_changed)" = 0 ]
  [[ "$(task_result "Download the pinned firewall binary")" == skipping:* ]]
  [ "$(readlink -f "$c/latest")" = "$t" ]
  [ "$(stat -c '%i %Y %s' "$t")" = "$before" ]
  [ ! -e "$c/$v" ]
  hash -r; [ "$(command -v sfw)" = "$bin" ]
}

NODE_STUB=""
node_stub_teardown() {
  [ -z "$NODE_STUB" ] || rm -f "$NODE_STUB"
  NODE_STUB=""
}

@test "upgrade: where the pinned binary cannot be used, sfw is fetched as before and the reason is in the record" {
  # A platform with no pin, a pin with no digest for this one, a version that is
  # not a release name, and a package directory another account could write. None
  # downloads anything. With the API blocked, "as before" is a failed fetch.
  sfw_pin_preconditions
  [ ! -e /usr/local/sbin/node ] || skip "/usr/local/sbin/node exists"
  hosts_block_api

  refused() { # <reason>
    echo "$output" | grep -E 'Socket Firewall —' | head -3
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"its runtime binary could not be fetched from GitHub (exit 1: [sfw] Failed"*"The pinned "*" was not used either: $1. "* ]] || return 1
    [[ "$(task_result "Download the pinned firewall binary")" == skipping:* ]] || return 1
    [ ! -e "$c/latest" ] || return 1
    [ -z "$(find "$pkg" -name 'sfw-free-*' -o -name .sfw-seed)" ] || return 1
    hash -r; [ -z "$(command -v sfw)" ]
  }

  sfw_cold
  NODE_STUB=/usr/local/sbin/node
  printf '#!/bin/sh\ncase "$*" in *process.platform*) echo linux-riscv64; exit 0 ;; esac\nexec %s "$@"\n' "$(readlink -f "$(command -v node)")" > "$NODE_STUB"
  chmod 755 "$NODE_STUB"; hash -r
  socket_apply
  node_stub_teardown; hash -r
  refused "no binary is pinned for linux-riscv64"

  sfw_cold
  socket_apply -e '{"sfw_binary_checksums": {}}'
  refused "sfw_binary_checksums has no entry for $(sfw_pin_key)"

  sfw_cold
  socket_apply -e "{\"sfw_binary_checksums\": {\"$(sfw_pin_key)\": \"md5:abc\"}}"
  refused "sfw_binary_checksums has no sha256 for $(sfw_pin_key)"

  sfw_cold
  socket_apply -e 'sfw_binary_version=../../../tmp'
  refused "sfw_binary_version is not a release name: ../../../tmp"

  sfw_cold
  chmod 0777 "$pkg"
  socket_apply
  chmod 0755 "$pkg"
  refused "$pkg is root 777, and only root may be able to write it"
}

@test "upgrade: where the pinned binary cannot be used and sfw's own fetch works, that one is in use and the summary says so" {
  sfw_pin_preconditions
  sfw_cold
  socket_apply -e '{"sfw_binary_checksums": {}}'
  echo "$output" | tail -20
  [ "$status" -eq 0 ]
  # sfw's own fetch needs the API's quota, which this runner may have used up.
  if printf '%s' "$output" | grep -qE 'could not be fetched from GitHub [(]exit 1: \[sfw\] Failed to prepare firewall binary: (Unable to fetch latest release|GET https://[^ ]+ failed with (403|429|5[0-9][0-9]))'; then
    skip "GitHub refused sfw's own download"
  fi
  [[ "$output" == *"the pinned firewall binary (sfw_binary_version $v) was not used: sfw_binary_checksums has no entry for $(sfw_pin_key). sfw downloaded its current release itself"* ]]
  # A setting that was not honoured, not a protection that is missing.
  [[ "$output" == *"setting(s) were not applied as configured"* ]]
  [[ "$output" != *"protection(s) were NOT applied"* ]]
  hash -r; [ "$(command -v sfw)" = "$bin" ]
  [ -e "$c/latest" ]
  # sfw made its own update check, as before.
  [ -e "$c/next-check" ]
  run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  [ -z "$output" ]
}

@test "upgrade: a pinned binary that does not run is moved aside with sfw, recorded as that, and not counted as a change" {
  # Another architecture's asset: its digest matches its own pin, so it reaches
  # the cache, and it cannot run. As a glibc binary on a musl host would.
  sfw_pin_preconditions
  [ "$(sfw_pin_key)" = linux-x86_64 ] || skip "stages the arm64 asset on x86_64"
  [ ! -e /usr/local/sbin/node ] || skip "/usr/local/sbin/node exists"
  hosts_block_api
  sfw_cold
  NODE_STUB=/usr/local/sbin/node
  printf '#!/bin/sh\ncase "$*" in *process.platform*) echo linux-arm64; exit 0 ;; */sfw\ */true) echo "skip=${SFW_SKIP_UPDATE_CHECK:-unset}" >> %s ;; esac\nexec %s "$@"\n' "$BATS_TEST_TMPDIR/warm" "$(readlink -f "$(command -v node)")" > "$NODE_STUB"
  chmod 755 "$NODE_STUB"; hash -r
  socket_apply
  node_stub_teardown; hash -r
  echo "$output" | tail -20
  [ "$status" -eq 0 ]
  skip_if_pin_unreachable
  # The warm over a binary this run put there makes no update check, or what the
  # host runs first would be whatever is newest.
  [ "$(cat "$BATS_TEST_TMPDIR/warm")" = "skip=1" ]
  [[ "$output" == *"installed, with the pinned firewall binary $v in its cache, but sfw could not run it (exit "*"sfw was moved aside so npm and cargo keep working, unfiltered"* ]]
  [[ "$output" != *"could not be fetched from GitHub ("* ]]
  [ "$(recap_changed)" = 0 ]
  [ -z "$(command -v sfw)" ]
  [ -e "$bin.broken" ]
}

@test "upgrade: a --check run over an sfw with nothing cached downloads nothing, and leaves sfw where it is" {
  sfw_pin_preconditions
  local how
  # With the API refused, a --check run used to move sfw aside; with it reachable,
  # it downloaded sfw's release. Both reported changed=0.
  for how in refused reachable; do
    if [ "$how" = refused ]; then hosts_block_api; else hosts_restore; fi
    sfw_cold
    socket_apply --check
    echo "$how:"; echo "$output" | tail -12
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"Look for an sfw that has no firewall binary cached"* ]] || return 1
    [ ! -e "$c" ] || { find "$c"; return 1; }
    [ -z "$(find "$pkg" -name 'sfw-free-*' -o -name .sfw-seed)" ] || return 1
    hash -r; [ "$(command -v sfw)" = "$bin" ] || return 1
    [ ! -e "$bin.broken" ] || return 1
    [[ "$output" == *"sfw has no firewall binary cached; this --check run downloaded none. A real run would."* ]] || return 1
    [[ "$output" != *"could not be fetched from GitHub ("* ]] || return 1
  done
}

@test "upgrade: a --check run over a cached binary that does not run reports it and moves nothing" {
  sfw_pin_preconditions
  t=$(readlink -f "$c/latest")
  mv "$t" "$t.real"
  printf '#!/bin/sh\nexit 7\n' > "$t"; chmod 755 "$t"
  printf '2026-01-01T00:00:00.000Z' > "$c/next-check"
  before=$(cat "$c/next-check")
  socket_apply --check
  echo "$output" | tail -12
  mv -f "$t.real" "$t"
  [ "$status" -eq 0 ]
  hash -r; [ "$(command -v sfw)" = "$bin" ]
  [ ! -e "$bin.broken" ]
  # An update check would have written this, and fetched.
  [ "$(cat "$c/next-check")" = "$before" ]
  [[ "$output" == *"could not be fetched from GitHub (exit 7"* ]]
}

# --- an sfw under another npm prefix than root's npm uses --------------------
#
# MEASURED 2026-11-20 on a live Ubuntu 24.04 host with NodeSource Node 24: sfw
# 2.0.4 sat under /usr/local (an earlier role run with Ubuntu's apt npm, whose
# prefix is /usr/local), and root's npm, now NodeSource's, has prefix /usr. The
# replacement went to /usr/lib/node_modules and /usr/bin/sfw, root's PATH still
# found /usr/local/bin/sfw 2.0.4 first, the warm moved that aside, and the run
# summary said the replacement "left it unchanged: sfw_version must be 2.0.6 or
# later", which was false. The 2.0.6 was neither warmed nor checked in that run.
# The test image is NodeSource too, so the image's own sfw is moved out of the
# way and 2.0.4 is staged under /usr/local, as on that host.
PREFIX_STAGED=""
sfw_prefix_teardown() {
  [ -n "$PREFIX_STAGED" ] || return 0
  local own=$PREFIX_OWN saved="$BATS_TEST_TMPDIR/own-sfw"
  echo "# teardown: putting the image's sfw back under $own" >&3
  rm -rf /usr/local/lib/node_modules/sfw
  rm -f /usr/local/bin/sfw /usr/local/bin/sfw.broken
  [ -n "$PREFIX_MADE_LIB" ] && rm -rf /usr/local/lib/node_modules
  if [ -d "$saved/pkg" ]; then
    rm -rf "$own/lib/node_modules/sfw"; rm -f "$own/bin/sfw" "$own/bin/sfw.broken"
    mv "$saved/pkg" "$own/lib/node_modules/sfw"
    # The link's (relative) target is kept, and it is back in its directory.
    mv "$saved/bin" "$own/bin/sfw"
  fi
  hash -r
  PREFIX_STAGED=""
}

@test "upgrade: an sfw under another npm prefix than root's npm is replaced where it is, with no false message" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  require_root "moves the global sfw and installs one under /usr/local"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  own=$(cd / && npm prefix -g)
  [ -n "$own" ] && [ "$own" != /usr/local ] || skip "root's npm already uses /usr/local; there is no second prefix to stage"
  [ "${c%/.sfw-cache}" = "$own/lib/node_modules/sfw" ] && [ -L "$own/bin/sfw" ] \
    || skip "the image's sfw is not where root's npm puts it"
  [ ! -e /usr/local/lib/node_modules/sfw ] && [ ! -e /usr/local/bin/sfw ] || skip "an sfw is already under /usr/local"
  want=$(sed -n 's/^sfw_version: *"\([^"]*\)".*/\1/p' "$ROLE_DIR/defaults/main.yml")
  gc=$(cd / && npm config get globalconfig)

  # The live host's layout: no sfw under root's npm's prefix, 2.0.4 under
  # /usr/local, warm (the image's cache, so the install's own npm call through
  # the wrapper does not download the binary for 2.0.4).
  PREFIX_OWN=$own; PREFIX_MADE_LIB=""
  [ -d /usr/local/lib/node_modules ] || PREFIX_MADE_LIB=1
  mkdir -p "$BATS_TEST_TMPDIR/own-sfw"
  PREFIX_STAGED=1
  mv "$own/lib/node_modules/sfw" "$BATS_TEST_TMPDIR/own-sfw/pkg"
  mv "$own/bin/sfw" "$BATS_TEST_TMPDIR/own-sfw/bin"
  hash -r
  (cd / && npm install -g --prefix /usr/local --globalconfig "$gc" --ignore-scripts sfw@2.0.4) >/dev/null 2>&1 \
    || skip "could not install sfw@2.0.4 (offline?)"
  lc=/usr/local/lib/node_modules/sfw/.sfw-cache
  cp -a "$BATS_TEST_TMPDIR/own-sfw/pkg/.sfw-cache" "$lc"
  # An absolute `latest` would point at the moved copy, outside this cache.
  t=$(readlink "$lc/latest")
  case "$t" in "$c"/*) ln -sfn "$lc/${t#"$c"/}" "$lc/latest" ;; esac
  hash -r
  [ "$(command -v sfw)" = /usr/local/bin/sfw ]
  grep -q '"version": "2.0.4"' /usr/local/lib/node_modules/sfw/package.json

  socket_apply
  echo "$output" | grep -E 'Socket Firewall|fatal|FAILED|PLAY RECAP' | head -20
  [ "$status" -eq 0 ]
  # What the summary said on that host. Each is false once the replacement
  # lands where the old sfw was.
  if [[ "$output" == *"left it unchanged"* || "$output" == *"predates 2.0.6"* ]]; then
    echo "the run summary still reports the sfw it replaced"; return 1
  fi
  [[ "$(task_result "Install Socket Firewall Free via npm")" == changed:* ]]
  # The replacement went where the old sfw was, and nothing into root's npm's
  # own prefix.
  grep -q "\"version\": \"$want\"" /usr/local/lib/node_modules/sfw/package.json
  grep -rqs SFW_SKIP_UPDATE_CHECK /usr/local/lib/node_modules/sfw/dist/
  [ ! -e "$own/lib/node_modules/sfw" ] || { echo "a second sfw was installed under $own"; return 1; }
  [ ! -e "$own/bin/sfw" ]
  [ ! -L "$own/bin/sfw" ]
  hash -r
  if [[ "$output" == *"its runtime binary could not be fetched from GitHub"* ]]; then
    skip "sfw's binary could not be downloaded from GitHub after the reinstall; it was replaced under /usr/local, at $want, with no false message"
  fi
  # One sfw on root's PATH, at sfw_version, warmed by root, and nobody else can
  # write its cache.
  run type -ap sfw
  [ "$output" = /usr/local/bin/sfw ] || { echo "sfw on PATH: $output"; return 1; }
  [ ! -e /usr/local/bin/sfw.broken ]
  [ -e "$lc/latest" ]
  run find "$lc" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  [ -z "$output" ]

  # Converged: the next apply has nothing to replace.
  socket_apply
  [ "$status" -eq 0 ]
  [[ "$(task_result "Install Socket Firewall Free via npm")" == skipping:* ]]
  [[ "$(task_result "Warm the Socket Firewall binary cache")" == ok:* ]]
}

# An older sfw with no npm prefix to replace it in (a local install under /opt,
# linked into /usr/local/bin) still shadows the replacement, which goes to root's
# npm's prefix. The warm moves the old one aside, so root's PATH then reaches
# the new copy, cold. The summary used to say "Remove it, or install sfw 2.0.6
# in its place, as root, and re-apply", advice for a file already moved aside.
# MEASURED: a plain re-apply warms the new copy and converges.
SHADOW_STAGED=""
sfw_shadow_teardown() {
  [ -n "$SHADOW_STAGED" ] || return 0
  local l
  for l in /usr/local/bin/sfw /usr/local/bin/sfw.broken; do
    case "$(readlink "$l" 2>/dev/null)" in /opt/sch-oldsfw/*) rm -f "$l" ;; esac
  done
  rm -rf /opt/sch-oldsfw
  hash -r
  SHADOW_STAGED=""
}

@test "upgrade: an older sfw outside any npm prefix that shadows the replacement is moved aside, and the summary says a re-apply finishes" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  require_root "stages an sfw under /opt and links it into /usr/local/bin"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  [ ! -e /usr/local/bin/sfw ] && [ ! -L /usr/local/bin/sfw ] && [ ! -e /opt/sch-oldsfw ] \
    || skip "an sfw is already in /usr/local/bin"
  sfw_snapshot "$c"
  img=$SFW_SNAP_BIN

  SHADOW_STAGED=1
  mkdir -p /opt/sch-oldsfw
  (cd /opt/sch-oldsfw && npm install --ignore-scripts --no-audit --no-fund sfw@2.0.4) >/dev/null 2>&1 \
    || skip "could not install sfw@2.0.4 (offline?)"
  old=/opt/sch-oldsfw/node_modules/sfw
  # Warm with a copy of the image's cache, so the install's own npm call (the
  # npm wrapper runs whichever sfw is first on PATH) downloads nothing.
  cp -a "$c" "$old/.sfw-cache"
  t=$(readlink "$old/.sfw-cache/latest")
  case "$t" in "$c"/*) ln -sfn "$old/.sfw-cache/${t#"$c"/}" "$old/.sfw-cache/latest" ;; esac
  ln -s "$(readlink -f /opt/sch-oldsfw/node_modules/.bin/sfw)" /usr/local/bin/sfw
  hash -r
  [ "$(command -v sfw)" = /usr/local/bin/sfw ] || skip "/usr/local/bin is not ahead of $img on PATH"

  socket_apply
  echo "$output" | grep -E 'Socket Firewall|fatal|FAILED|PLAY RECAP' | head -20
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw 2.0.4 at /usr/local/bin/sfw predates 2.0.6"* ]]
  [[ "$output" == *"It was moved aside to /usr/local/bin/sfw.broken, and root now runs $img, which this run did not warm"*"Re-apply to finish."* ]] \
    || { echo "the summary does not say the old sfw is aside and a re-apply finishes"; return 1; }
  [[ "$output" != *"Remove it, or install sfw"* ]]
  [ -L /usr/local/bin/sfw.broken ]
  hash -r
  [ "$(command -v sfw)" = "$img" ]

  # The re-apply the summary asks for: nothing to install, the new copy warmed.
  socket_apply
  echo "$output" | grep -E 'Socket Firewall|fatal|FAILED|PLAY RECAP' | head -20
  [ "$status" -eq 0 ]
  [[ "$(task_result "Install Socket Firewall Free via npm")" == skipping:* ]]
  [[ "$output" != *"predates 2.0.6"* ]]
  if [[ "$output" == *"its runtime binary could not be fetched from GitHub"* ]]; then
    skip "sfw's binary could not be downloaded from GitHub for the warm; the shadow was moved aside and the summary said so"
  fi
  # The new copy has nothing cached, so this apply puts the pinned binary there
  # and counts that as its change (or, the release URL refused, sfw downloads
  # its own, which the warm has never counted).
  st=$(task_result "Warm the Socket Firewall binary cache")
  if [[ "$output" == *"(sfw_binary_version "*" was not used: downloading it failed"* ]]; then
    [[ "$st" == ok:* ]]
  else
    [[ "$st" == changed:* ]]
  fi
  hash -r
  [ "$(command -v sfw)" = "$img" ]
  [ -e "$c/latest" ]
  run find "$c" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  [ -z "$output" ]
  # And then there is nothing left to do.
  socket_apply
  [ "$status" -eq 0 ]
  [ "$(recap_changed)" = 0 ]
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
  hosts_restore
  node_stub_teardown
  sfw_prefix_teardown
  sfw_shadow_teardown
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
