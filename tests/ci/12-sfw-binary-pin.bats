#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
# The pinned Socket Firewall binary (sfw_seed_binary in action/harden.sh).
#
# sfw downloads its firewall binary through the GitHub API, without credentials
# and so on the runner address's shared quota. MEASURED 2026-11-23: with that API
# answering 403, sfw 2.0.6 exits 1 in 0.3 s and every install in the job ran
# unfiltered. harden.sh now falls back to a pinned release from its download URL.
# It is a floor: sfw's own fetch goes first, and when it works nothing else is
# downloaded. What it must never do is put a file in sfw's cache that is not the
# pinned one, because sfw runs that cache without checking it, for root too.
#
# Stubs throughout: a launcher that caches the way sfw 2.0.6 does, a curl that
# records what it was asked for, and a copy of harden.sh whose pinned digests are
# those of the stub's payload where a test needs the download to be accepted.

load helpers

setup() {
  common_setup
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null \
    || skip "needs passwordless sudo: sfw's package is root's"
  PKG="$BATS_TEST_TMPDIR/prefix/lib/node_modules/sfw"
  mkdir -p "$PKG/dist"
  PKG=$(cd "$PKG" && pwd -P)
  CACHE="$PKG/.sfw-cache"
  CALLS="$BATS_TEST_TMPDIR/calls"
  PAYLOAD="$BATS_TEST_TMPDIR/payload"
  SHIPPED="$HARDEN_SH"
  printf '#!/bin/sh\nexec "$@"\n' > "$PAYLOAD"
  sfw_host linux-x64
}

# Root owns part of it.
teardown() {
  [ -z "${BATS_TEST_TMPDIR:-}" ] || sudo rm -rf -- "$BATS_TEST_TMPDIR/prefix"
}

sha256_of() {
  if have sha256sum; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1
}

# sfw_host <node platform-arch>: a runner whose root `npm install -g` has just
# put sfw there, cold. The launcher keeps its cache in its own package directory,
# runs `latest` without looking at it, writes next-check before it fetches, and
# fetches only where api-ok exists, as sfw does when the GitHub API answers.
sfw_host() {
  stub_bin npm 'case "$*" in
  "install -g --ignore-scripts sfw@2.0.6") exit 0 ;;
  "--version") echo "10.9.8" ;;
  *) echo "STUB:npm ARGS=[$*]" ;;
esac'
  stub_bin node 'case "$*" in *process.platform*) echo '"$1"' ;; *) echo 22 ;; esac'
  stub_bin curl 'o="" u=""
while [ $# -gt 0 ]; do case "$1" in -o) o=$2; shift ;; http*) u=$1 ;; esac; shift; done
echo "curl $u" >> "'"$CALLS"'"
if [ -e "'"$BATS_TEST_TMPDIR"'/cdn-down" ]; then echo "curl: (22) The requested URL returned error: 503" >&2; exit 22; fi
cp "'"$PAYLOAD"'" "$o"'
  sudo rm -rf -- "$PKG"
  mkdir -p "$PKG/dist"
  printf '{\n  "name": "sfw",\n  "version": "2.0.6"\n}\n' > "$PKG/package.json"
  cat > "$PKG/dist/sfw.mjs" <<LAUNCHER
#!/bin/bash
c="$CACHE"
if [ -e "\$c/latest" ]; then cached=yes; else cached=no; fi
echo "sfw uid=\$(id -u) skip=\${SFW_SKIP_UPDATE_CHECK:-unset} cached=\$cached" >> "$CALLS"
if [ "\$cached" = yes ]; then exec "\$c/latest" "\$@"; fi
mkdir -p "\$c" && echo later > "\$c/next-check" || exit 1
if [ -e "$BATS_TEST_TMPDIR/api-ok" ]; then
  mkdir -p "\$c/v9.9.9" && cp "$PAYLOAD" "\$c/v9.9.9/sfw-own" && chmod 0755 "\$c/v9.9.9/sfw-own" && ln -s "\$c/v9.9.9/sfw-own" "\$c/latest"
  exec "\$c/latest" "\$@"
fi
echo "[sfw] Failed to prepare firewall binary: Unable to fetch latest release and no valid cached release found." >&2
exit 1
LAUNCHER
  chmod 0755 "$PKG" "$PKG/dist" "$PKG/dist/sfw.mjs"
  sudo chown -R 0:0 "$PKG"
  sudo rm -f "$TEST_BIN/sfw.broken"
  stub_symlink sfw "$PKG/dist/sfw.mjs"
  : > "$CALLS"
}

# A harden.sh that differs only in the digests it pins: the payload's.
pin_the_payload() {
  local sum
  sum=$(sha256_of "$PAYLOAD")
  [ ${#sum} -eq 64 ]
  sed "s/^\(SFW_BINARY_SHA256_[A-Z0-9_]*\)=\"[0-9a-f]*\"/\1=\"$sum\"/" "$SHIPPED" > "$BATS_TEST_TMPDIR/harden-payload.sh"
  [ "$(grep -c "^SFW_BINARY_SHA256_[A-Z0-9_]*=\"$sum\"" "$BATS_TEST_TMPDIR/harden-payload.sh")" -eq 4 ]
  HARDEN_SH="$BATS_TEST_TMPDIR/harden-payload.sh"
}

harden_sfw() { run harden ECOSYSTEMS=npm INTEL=sfw "$@" -- --emit=plain; echo "$output"; cat "$CALLS"; }

# Neither what sfw runs nor a stray download: the cache holds at most the
# launcher's own next-check, and no staging directory is left.
assert_nothing_placed() {
  local f
  f=$(sudo find "$PKG" -name 'sfw-free-*' -o -name latest -o -name '.sfw-seed*')
  [ -z "$f" ] || { echo "left behind: $f"; return 1; }
  f=$(find "$TEST_TMP" -name 'sfw-free-*')
  [ -z "$f" ] || { echo "left behind: $f"; return 1; }
}

# One statement per condition, each with its own exit: bats runs tests under
# errexit, which ignores a failing `[ a ] && [ b ]` or `! cmd` that is not last.
assert_moved_aside() {
  [ ! -e "$TEST_BIN/sfw" ] || { echo "sfw is still on PATH"; return 1; }
  [ -e "$TEST_BIN/sfw.broken" ] || { echo "no sfw.broken"; return 1; }
  assert_file_lacks "$TEST_BIN/npm" "supply-chain-harden" || return 1
  assert_file_contains "$OUT_FILE" "sfw_installed=false" || return 1
}

assert_no_download() {
  if grep -E '^(curl|wget) ' "$CALLS"; then echo "it downloaded the pin"; return 1; fi
}

@test "sfw pin: where sfw's own fetch works, the pinned binary is not downloaded" {
  pin_the_payload
  touch "$BATS_TEST_TMPDIR/api-ok"
  harden_sfw
  [ "$status" -eq 0 ]
  assert_file_contains "$OUT_FILE" "sfw_installed=true"
  assert_no_download
  [ "$(readlink "$CACHE/latest")" = "$CACHE/v9.9.9/sfw-own" ]
  [ ! -e "$CACHE/v1.16.0" ]
  # FIXTURE CONTROL: the same runner with sfw's fetch refused does download it,
  # so an empty record above is not a stub nobody can reach.
  rm -f "$BATS_TEST_TMPDIR/api-ok"
  sfw_host linux-x64
  harden_sfw
  [ "$(grep -c '^curl ' "$CALLS")" -eq 1 ]
}

@test "sfw pin: where sfw's own fetch is refused, the pinned binary is verified, cached and used" {
  pin_the_payload
  harden_sfw
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw could not fetch its firewall binary (rc=1: [sfw] Failed to prepare firewall binary: Unable to fetch latest release"*"the pinned v1.16.0, its SHA-256 checked, is in its cache instead"* ]]
  assert_file_contains "$OUT_FILE" "sfw_installed=true"
  # The order: sfw's own fetch, the download, the pinned binary as root with no
  # second update check, and then as the account the wrappers run for.
  local me
  me=$(id -u)
  [ "$(sed -n 1p "$CALLS")" = "sfw uid=0 skip=unset cached=no" ]
  [ "$(sed -n 2p "$CALLS")" = "curl https://github.com/SocketDev/sfw-free/releases/download/v1.16.0/sfw-free-linux-x86_64" ]
  [ "$(sed -n 3p "$CALLS")" = "sfw uid=0 skip=1 cached=yes" ]
  [ "$(sed -n 4p "$CALLS")" = "sfw uid=$me skip=1 cached=yes" ]
  # Laid out as sfw lays it out, root's, and nobody else's to write.
  [ "$(readlink "$CACHE/latest")" = "$CACHE/v1.16.0/sfw-free-linux-x86_64" ]
  cmp "$PAYLOAD" "$CACHE/latest"
  local p
  for p in "$CACHE" "$CACHE/v1.16.0" "$CACHE/v1.16.0/sfw-free-linux-x86_64"; do
    set -- $(ls -ldn "$p")
    echo "$p: $1 uid $3"
    [[ "$1" == ?rwxr-xr-x* ]]
    [ "$3" -eq 0 ]
  done
  [ -z "$(sudo find "$PKG" -name '.sfw-seed*')" ]
  [ -z "$(find "$TEST_TMP" -name 'sfw-free-*')" ]
  # And npm goes through it.
  assert_file_contains "$TEST_BIN/npm" "supply-chain-harden"
  : > "$CALLS"
  run env PATH="$TEST_BIN:$PATH" "$TEST_BIN/npm" install foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB:npm ARGS=[install foo]"* ]]
  [ "$(cat "$CALLS")" = "sfw uid=$me skip=1 cached=yes" ]
}

@test "sfw pin: a download that is not the pinned file never reaches the cache" {
  # The script as shipped: the payload is not v1.16.0.
  harden_sfw
  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl ' "$CALLS")" -eq 1 ]
  [[ "$output" == *"Unable to fetch latest release"*"The pinned v1.16.0 was not used instead: the download has sha256 $(sha256_of "$PAYLOAD"), not the pinned $(sed -n 's/^SFW_BINARY_SHA256_LINUX_X86_64="\(.*\)"/\1/p' "$HARDEN_SH")"* ]]
  assert_nothing_placed
  assert_moved_aside
  # Only sfw's own attempt ran: the unverified file was never executed.
  [ "$(grep -c '^sfw ' "$CALLS")" -eq 1 ]
  # FIXTURE CONTROL: the same download, pinned, is accepted.
  sfw_host linux-x64
  pin_the_payload
  harden_sfw
  assert_file_contains "$OUT_FILE" "sfw_installed=true"
}

@test "sfw pin: where neither the API nor the release URL answers, sfw is moved aside as before and both reasons are given" {
  pin_the_payload
  touch "$BATS_TEST_TMPDIR/cdn-down"
  harden_sfw
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw could not prepare its firewall binary (rc=1: [sfw] Failed to prepare firewall binary: Unable to fetch latest release"* ]]
  [[ "$output" == *"The pinned v1.16.0 was not used instead: downloading it failed (exit 22: curl: (22) The requested URL returned error: 503)"* ]]
  assert_nothing_placed
  assert_moved_aside
}

@test "sfw pin: a pinned binary that does not run is moved aside with sfw, and the warning does not blame the download" {
  # A glibc binary on a musl host, a noexec mount: verified, cached, and useless.
  printf '#!/bin/sh\necho cannot-run-here >&2\nexit 126\n' > "$PAYLOAD"
  pin_the_payload
  harden_sfw
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw could not prepare its firewall binary (rc=126: cannot-run-here)"*"The pinned v1.16.0 was not used instead: its SHA-256 matched and it was put in sfw's cache, but it did not run"* ]]
  assert_moved_aside
  # The account check does not run over a warm that failed.
  [ "$(grep -c '^sfw ' "$CALLS")" -eq 2 ]
}

@test "sfw pin: each platform asks for its own asset and is held to its own digest; any other has no pin" {
  local plat asset key sum
  while read -r plat asset key; do
    sfw_host "$plat"
    harden_sfw
    [ "$status" -eq 0 ]
    [ "$(grep '^curl ' "$CALLS")" = "curl https://github.com/SocketDev/sfw-free/releases/download/v1.16.0/$asset" ]
    sum=$(sed -n "s/^SFW_BINARY_SHA256_$key=\"\(.*\)\"/\1/p" "$HARDEN_SH")
    [ ${#sum} -eq 64 ]
    [[ "$output" == *", not the pinned $sum"* ]]
    assert_nothing_placed
  done <<'PLATFORMS'
linux-x64 sfw-free-linux-x86_64 LINUX_X86_64
linux-arm64 sfw-free-linux-arm64 LINUX_ARM64
darwin-x64 sfw-free-macos-x86_64 MACOS_X86_64
darwin-arm64 sfw-free-macos-arm64 MACOS_ARM64
PLATFORMS
  for plat in linux-riscv64 linux-arm win32-x64 freebsd-x64; do
    sfw_host "$plat"
    harden_sfw
    [ "$status" -eq 0 ]
    assert_no_download
    [[ "$output" == *"The pinned v1.16.0 was not used instead: no binary is pinned for $plat"* ]]
    assert_nothing_placed
    assert_moved_aside
  done
}

@test "sfw pin: a binary sfw already has is never replaced, whatever its version" {
  # One that runs: an update check sfw cannot make is not a reason to replace it.
  pin_the_payload
  sudo mkdir -p "$CACHE/v99.0.0"
  sudo cp "$PAYLOAD" "$CACHE/v99.0.0/sfw-newer"
  sudo chmod 0755 "$CACHE/v99.0.0/sfw-newer"
  sudo ln -s "$CACHE/v99.0.0/sfw-newer" "$CACHE/latest"
  harden_sfw
  assert_file_contains "$OUT_FILE" "sfw_installed=true"
  assert_no_download
  [ "$(readlink "$CACHE/latest")" = "$CACHE/v99.0.0/sfw-newer" ]
  [ ! -e "$CACHE/v1.16.0" ]
  # One that does not: moved aside, as before, and still not replaced.
  sfw_host linux-x64
  sudo mkdir -p "$CACHE/v99.0.0"
  printf '#!/bin/sh\necho broken-newer >&2\nexit 3\n' | sudo tee "$CACHE/v99.0.0/sfw-newer" >/dev/null
  sudo chmod 0755 "$CACHE/v99.0.0/sfw-newer"
  sudo ln -s "$CACHE/v99.0.0/sfw-newer" "$CACHE/latest"
  harden_sfw
  assert_no_download
  [[ "$output" == *"rc=3: broken-newer"*"The pinned v1.16.0 was not used instead: a binary is already cached"* ]]
  [ "$(readlink "$CACHE/latest")" = "$CACHE/v99.0.0/sfw-newer" ]
  assert_moved_aside
}

@test "sfw pin: a package or cache directory another account could write is left alone" {
  pin_the_payload
  local state
  for state in pkg-mode pkg-owner cache-mode cache-owner release-mode cache-link; do
    sfw_host linux-x64
    case "$state" in
      pkg-mode)     sudo chmod 0777 "$PKG" ;;
      pkg-owner)    sudo chown "$(id -u)" "$PKG" ;;
      cache-mode)   sudo mkdir "$CACHE" && sudo chmod 0775 "$CACHE" ;;
      cache-owner)  sudo mkdir "$CACHE" && sudo chown "$(id -u)" "$CACHE" ;;
      release-mode) sudo mkdir -p "$CACHE/v1.16.0" && sudo chmod 0777 "$CACHE/v1.16.0" ;;
      cache-link)   mkdir -p "$BATS_TEST_TMPDIR/elsewhere" && sudo ln -s "$BATS_TEST_TMPDIR/elsewhere" "$CACHE" ;;
    esac
    echo "== $state"
    harden_sfw
    [ "$status" -eq 0 ]
    case "$state" in
      *-mode)  [[ "$output" == *"was not used instead: $PKG"*" can be written by other accounts (d"* ]] ;;
      *-owner) [[ "$output" == *"was not used instead: $PKG"*" belongs to uid $(id -u), and sfw was installed by uid 0"* ]] ;;
      *-link)  [[ "$output" == *"was not used instead: $CACHE is not a directory"* ]] ;;
    esac
    assert_nothing_placed
    [ -z "$(find "$BATS_TEST_TMPDIR/elsewhere" -name 'sfw-free-*' 2>/dev/null)" ]
    assert_moved_aside
  done
}

# path_without <tool>...: every command on PATH but those, as symlinks.
path_without() {
  local d p x
  d=$(mktemp -d "$BATS_TEST_TMPDIR/path.XXXXXX")
  local IFS=:
  for p in $PATH; do
    # A name an earlier directory has already is refused and stays that one's.
    ln -s "$p"/* "$d/" 2>/dev/null || true
  done
  unset IFS
  for x in "$@"; do rm -f "$d/$x"; done
  echo "$d"
}

@test "sfw pin: the digest is checked with shasum where there is no sha256sum, and refused where there is neither" {
  have shasum || skip "shasum not installed"
  pin_the_payload
  # A sudo that gives the script a PATH without sha256sum. It escalates nothing,
  # so the package is this account's, as after an install without root.
  local np
  np=$(path_without sha256sum)
  [ ! -e "$np/sha256sum" ]
  [ -e "$np/shasum" ]
  stub_bin sudo '[ "$1" != -n ] || shift; PATH="'"$np"'" exec "$@"'
  sudo chown -R "$(id -u)" "$PKG"
  harden_sfw
  assert_file_contains "$OUT_FILE" "sfw_installed=true"
  cmp "$PAYLOAD" "$CACHE/v1.16.0/sfw-free-linux-x86_64"
  # ... and it is a check: another file is refused.
  rm -rf -- "$CACHE"; rm -f "$TEST_BIN/npm"
  stub_bin npm 'case "$*" in --version) echo 10.9.8 ;; esac'
  printf '#!/bin/sh\n# not it\nexec "$@"\n' > "$PAYLOAD"
  harden_sfw
  [[ "$output" == *"the download has sha256 $(sha256_of "$PAYLOAD"), not the pinned "* ]]
  assert_nothing_placed
  # Neither tool: no digest, so no.
  rm -rf -- "$CACHE"; mv "$TEST_BIN/sfw.broken" "$TEST_BIN/sfw"
  np=$(path_without sha256sum shasum)
  stub_bin sudo '[ "$1" != -n ] || shift; PATH="'"$np"'" exec "$@"'
  pin_the_payload
  harden_sfw
  [[ "$output" == *"the download has sha256 unknown, not the pinned "* ]]
  assert_nothing_placed
  rm -f "$TEST_BIN/sudo"
}

@test "sfw pin: wget downloads it where there is no curl, and with neither the reason says so" {
  pin_the_payload
  rm -f "$TEST_BIN/curl"
  local np
  np=$(path_without curl wget)
  # As root, sudo finds its own tools; the download is this account's.
  harden_sfw PATH="$TEST_BIN:$np"
  [[ "$output" == *"was not used instead: downloading it failed (exit 127: neither curl nor wget is installed)"* ]]
  assert_nothing_placed
  assert_moved_aside
  sfw_host linux-x64
  rm -f "$TEST_BIN/curl"
  stub_bin wget 'o="" u=""
while [ $# -gt 0 ]; do case "$1" in -O) o=$2; shift ;; http*) u=$1 ;; esac; shift; done
echo "wget $u" >> "'"$CALLS"'"
cp "'"$PAYLOAD"'" "$o"'
  harden_sfw PATH="$TEST_BIN:$np"
  assert_file_contains "$OUT_FILE" "sfw_installed=true"
  [ "$(grep '^wget ' "$CALLS")" = "wget https://github.com/SocketDev/sfw-free/releases/download/v1.16.0/sfw-free-linux-x86_64" ]
  rm -f "$TEST_BIN/wget"
}
