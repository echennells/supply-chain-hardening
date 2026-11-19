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

@test "upgrade: a re-apply resets an sfw cache an earlier version left writable, and removes the stray tree" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to seed root-owned state"
  c=$(sfw_cache_dir) || skip "sfw not installed or layout not recognised"
  [ -e "$c/latest" ] || skip "sfw cache is cold (offline?)"
  id sfwprior >/dev/null 2>&1 || useradd -m -s /bin/bash sfwprior

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
  cp -a "$c" "$BATS_TEST_TMPDIR/cache"
  npm install -g --ignore-scripts sfw@2.0.4 >/dev/null 2>&1 || skip "could not install sfw@2.0.4 (offline?)"
  rm -rf "$c"; cp -a "$BATS_TEST_TMPDIR/cache" "$c"
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
