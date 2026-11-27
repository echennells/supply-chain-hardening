#!/usr/bin/env bats
# The per-user config files this project writes, and what is the user's in them
# (issue 48, item 1). MEASURED at d738db8: a fake token or registry in each was
# gone after one run, with no copy and no message, and so was a token added after
# hardening (cargo, maven and nuget kept a copy on the first run, and lost a token
# added later). Every test here that plants one fails there.
#
# ~/.npmrc is merged. The others are replaced whole, but only a file that is exactly
# what was last written goes without a copy and a warning.

load helpers

ROOT="${BATS_TEST_DIRNAME}/../.."
ALL=npm,pnpm,yarn,pip,uv,bun,bundler,cargo,maven,nuget,composer
# Replaced whole: the ones with a marker line, and Composer's JSON, which has none.
MARKED="pnpm-yaml pnpm-rc yarn pip uv bun bundler cargo maven nuget"
OTHERS="$MARKED composer"

setup() {
  common_setup
  # Every path under it, whatever the platform (pnpm's default differs on macOS).
  XDG="$TEST_HOME/.config"
  # Only asked for a version. The real ones can take seconds each in a fresh home
  # (a pnpm 12 here took 18 s, and corepack downloads).
  stub_bin pnpm 'echo 11.28.13'
  stub_bin yarn 'echo 4.18.1'
  # An npm that knows every key this project writes. harden.sh leaves one out where
  # the npm it finds would warn about it (npm 11.2.0 to 11.9.0), so without this the
  # expected block depends on the machine. Tests that ask the real npm use $PATH,
  # which does not have this one.
  stub_npm 11.19.1
  # The preflight looks at Maven's and NuGet's only where a tool would read them.
  stub_bin java 'echo "openjdk version 21" >&2'
  stub_bin dotnet 'echo 8.0.100'
}

teardown() {
  touch "$BATS_TEST_TMPDIR/stop"
  local d
  [ -f "$BATS_TEST_TMPDIR/rootdirs" ] || return 0
  while read -r d; do
    case "$d" in */sch-ucf-??????) sudo rm -rf -- "$d" ;; esac
  done < "$BATS_TEST_TMPDIR/rootdirs"
}

f() { # <kind>: where harden.sh puts it here
  case "$1" in
    npmrc) echo "$TEST_HOME/.npmrc" ;;
    pnpm-yaml) echo "$XDG/pnpm/config.yaml" ;;
    pnpm-rc) echo "$XDG/pnpm/rc" ;;
    yarn) echo "$TEST_HOME/.yarnrc.yml" ;;
    pip) echo "$TEST_HOME/.config/pip/pip.conf" ;;
    uv) echo "$XDG/uv/uv.toml" ;;
    bun) echo "$XDG/.bunfig.toml" ;;
    bundler) echo "$TEST_HOME/.bundle/config" ;;
    cargo) echo "$TEST_HOME/.cargo/config.toml" ;;
    maven) echo "$TEST_HOME/.m2/settings.xml" ;;
    nuget) echo "$TEST_HOME/.nuget/NuGet/NuGet.Config" ;;
    composer) echo "$XDG/composer/config.json" ;;
  esac
}

# apply [VAR=value ...]: one harden.sh run over the seven ecosystems
apply() { harden XDG_CONFIG_HOME="$XDG" ECOSYSTEMS="${ECO:-$ALL}" "$@" -- --emit=plain; }

# preflight: harden.sh --preflight in the same environment
pf() {
  env -i PATH="${TEST_BIN}:${PASSWD_BIN}:${PATH}" HOME="$TEST_HOME" XDG_CONFIG_HOME="$XDG" TMPDIR="$TEST_TMP" \
    bash "$HARDEN_SH" --preflight
}

# plant: a fake secret of the user's in each file, as each tool would hold it
plant() {
  mkdir -p "$XDG/pnpm" "$XDG/uv" "$TEST_HOME/.config/pip" "$TEST_HOME/.bundle" \
    "$TEST_HOME/.cargo" "$TEST_HOME/.m2" "$TEST_HOME/.nuget/NuGet" "$XDG/composer"
  printf '//registry.example/:_authToken=SECRET-npmrc\n' > "$(f npmrc)"
  printf 'registry: https://u:SECRET-pnpm-yaml@example/\n' > "$(f pnpm-yaml)"
  printf 'registry=https://u:SECRET-pnpm-rc@example/\n' > "$(f pnpm-rc)"
  printf 'npmAuthToken: "SECRET-yarn"\n' > "$(f yarn)"
  printf '[global]\nindex-url = https://u:SECRET-pip@example/simple\n' > "$(f pip)"
  printf '[[index]]\nurl = "https://u:SECRET-uv@example/simple"\n' > "$(f uv)"
  printf '[install]\nregistry = "https://u:SECRET-bun@example"\n' > "$(f bun)"
  printf -- '---\nBUNDLE_GEMS__EXAMPLE: "u:SECRET-bundler"\n' > "$(f bundler)"
  printf '[registries.corp]\ntoken = "SECRET-cargo"\n' > "$(f cargo)"
  printf '<settings><servers><server><id>corp</id><password>SECRET-maven</password></server></servers></settings>\n' > "$(f maven)"
  printf '<configuration><packageSourceCredentials><corp><add key="ClearTextPassword" value="SECRET-nuget" /></corp></packageSourceCredentials></configuration>\n' > "$(f nuget)"
  printf '{"config": {"http-basic": {"corp": {"username": "u", "password": "SECRET-composer"}}}}\n' > "$(f composer)"
}

mode() { ls -ld "$1" | cut -c1-10; }

copies() { # <kind>: its copies, one per line
  local b
  for b in "$(f "$1")".*~; do [ -e "$b" ] && echo "$b"; done
  return 0
}

# the bytes of everything under the home but the run's own record
snapshot() {
  ( cd "$TEST_HOME" && find . -path ./.cache -prune -o \( -type f -o -type l \) -print | sort | while IFS= read -r p; do
      ls -ld "$p" | awk '{print $1, $3, $4}'; printf '%s ' "$p"; cksum < "$p"
    done )
}

# the same, but the two Python cutoffs, which harden.sh sets from the clock
snapshot_but_cutoffs() {
  ( cd "$TEST_HOME" && find . -path ./.cache -prune -o -type f -print | sort | while IFS= read -r p; do
      ls -ld "$p" | awk '{print $1, $3, $4}'; printf '%s ' "$p"
      sed -e 's/^\(exclude-newer = \).*/\1/' -e 's/^\(uploaded-prior-to = \).*/\1/' "$p" | cksum
    done )
}

settings() { printf '%s\n' ignore-scripts=true audit=true save-exact=true fund=false update-notifier=false min-release-age=2 allow-git=none; }

# block: the block harden.sh puts at the top of ~/.npmrc, read back from it
block() { sed -n '/^; >>> supply-chain-hardening: /,/^; <<< supply-chain-hardening$/p' "$(f npmrc)"; }

# rest: what is below the block
rest() { sed '1,/^; <<< supply-chain-hardening$/d' "$(f npmrc)"; }

npmrc_is_ours_then() { # <file with the expected rest>: the block first, then exactly those bytes
  block > "$BATS_TEST_TMPDIR/b"
  [ -s "$BATS_TEST_TMPDIR/b" ]
  settings > "$BATS_TEST_TMPDIR/s"
  diff <(grep -v '^;' "$BATS_TEST_TMPDIR/b") "$BATS_TEST_TMPDIR/s"
  cat "$BATS_TEST_TMPDIR/b" "$1" | cmp - "$(f npmrc)"
}

# the ucf_ functions on their own, for a rule no run of harden.sh reaches quickly
lib() {
  sed -n '/^# >>> user_config$/,/^# <<< user_config$/p' "$HARDEN_SH" > "$BATS_TEST_TMPDIR/lib.sh"
  # shellcheck disable=SC1091
  . "$BATS_TEST_TMPDIR/lib.sh"
}

# rootdir: a new directory that is root's alone, for what root writes; gone with the test
rootdir() {
  local d
  d=$(sudo mktemp -d "$(cd -P /etc && pwd -P)/sch-ucf-XXXXXX") || return 1
  sudo chmod 755 "$d"
  printf '%s\n' "$d" | tee -a "$BATS_TEST_TMPDIR/rootdirs"
}

# a root other than this account, for a test of where it writes
need_sudo() {
  [ "$(id -u)" != 0 ] || skip "as root there is no other account"
  sudo -n true 2>/dev/null || skip "no passwordless sudo"
}

# ------------------------------------------------------------- nothing is lost

@test "user config: a fake secret in each of the files is still on disk after the first run" {
  plant
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  grep -q 'SECRET-npmrc' "$(f npmrc)"                  # still in use
  [ -z "$(copies npmrc)" ]                             # so no copy was needed
  local k
  for k in $OTHERS; do
    assert_file_lacks "$(f "$k")" SECRET               # replaced
    [ "$(copies "$k" | wc -l)" -eq 1 ] || { echo "$k: $(copies "$k")"; return 1; }
    grep -q "SECRET-$k" "$(copies "$k")"
    [ "$(mode "$(copies "$k")")" = -rw------- ]
    grep -q "replaced $(f "$k"), which was not exactly what this project last wrote.*$(copies "$k")\. It may hold a token or a password: delete it once" "$BATS_TEST_TMPDIR/log" \
      || { cat "$BATS_TEST_TMPDIR/log"; return 1; }
  done
  # Paths, never contents.
  ! grep SECRET "$BATS_TEST_TMPDIR/log" || false
}

@test "user config: a token added after hardening survives the next run, in each of them" {
  apply >/dev/null 2>&1
  # Appended, so the file still carries the marker: recognising our files by the
  # marker alone deleted it (MEASURED at d738db8).
  local k
  for k in npmrc $MARKED; do grep -q 'Managed by supply-chain-harden' "$(f "$k")"; done
  for k in npmrc $OTHERS; do printf '# SECRET-%s\n' "$k" >> "$(f "$k")"; done
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  grep -q 'SECRET-npmrc' "$(f npmrc)"
  for k in $OTHERS; do
    assert_file_lacks "$(f "$k")" SECRET
    grep -q "SECRET-$k" "$(copies "$k")" || { echo "$k lost"; return 1; }
  done
  ! grep SECRET "$BATS_TEST_TMPDIR/log" || false
}

@test "user config: CRLF files, and files with no last newline, are copied byte for byte; one of ours saved as CRLF is noticed" {
  local k
  plant
  for k in $OTHERS; do
    awk '{ printf "%s\r\n", $0 } END { printf "# no last newline" }' "$(f "$k")" > "$BATS_TEST_TMPDIR/x.$k"
    cat "$BATS_TEST_TMPDIR/x.$k" > "$(f "$k")"
  done
  apply >/dev/null 2>&1
  for k in $OTHERS; do
    cmp "$(copies "$k")" "$BATS_TEST_TMPDIR/x.$k" || { echo "$k"; return 1; }
    assert_file_lacks "$(f "$k")" SECRET
  done
  lib
  for k in $OTHERS; do
    awk '{ printf "%s\r\n", $0 }' "$(f "$k")" > "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k"; return 1; }
  done
}

@test "user config: a second run over user content changes nothing, makes no second copy, and is quiet" {
  plant
  apply >/dev/null 2>&1
  local before
  before=$(snapshot_but_cutoffs)
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  diff <(printf '%s\n' "$before") <(snapshot_but_cutoffs)
  ! grep -E 'replaced .*not exactly|took your own|not read' "$BATS_TEST_TMPDIR/log" || false
  # with the user content still there, not because it is gone
  local k
  grep -q SECRET-npmrc "$(f npmrc)"
  for k in $OTHERS; do grep -q "SECRET-$k" "$(copies "$k")"; done
}

@test "user config: content that comes back every run is copied once, not once per run" {
  # A self-hosted runner whose jobs run 'bundle config set' first: the copies hold
  # the secret, so they must not pile up.
  local i
  for i in 1 2 3; do
    plant
    apply >/dev/null 2>&1
  done
  local k
  for k in $OTHERS; do
    [ "$(copies "$k" | wc -l)" -eq 1 ] || { copies "$k"; return 1; }
    [ "$(mode "$(copies "$k")")" = -rw------- ]
  done
}

@test "user config: no per-user file at all is created as before, and nothing is said about it" {
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  local k
  for k in npmrc $OTHERS; do
    [ -f "$(f "$k")" ]
    [ -z "$(copies "$k")" ]
  done
  [ "$(mode "$(f npmrc)")" = -rw------- ]
  [ "$(mode "$(f uv)")" = -rw-r--r-- ]
  ! grep -E 'replaced .*not exactly|took your own|is 0600 now' "$BATS_TEST_TMPDIR/log" || false
}

@test "user config: bunfig without XDG_CONFIG_HOME is kept the same way (~/.bunfig.toml)" {
  printf '[install]\nregistry = "https://u:SECRET-bun@example"\n' > "$TEST_HOME/.bunfig.toml"
  # --preflight follows XDG_CONFIG_HOME the way the write does.
  run pf
  [[ "$output" != *"$TEST_HOME/.bunfig.toml"* ]]
  [[ "$output" == *"$XDG/.bunfig.toml: not there, will be created"* ]]
  run env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" bash "$HARDEN_SH" --preflight
  [[ "$output" == *"STOP  $TEST_HOME/.bunfig.toml: not exactly"* ]]
  [[ "$output" != *"$XDG/.bunfig.toml"* ]]
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null 2>&1
  assert_file_lacks "$TEST_HOME/.bunfig.toml" SECRET
  grep -q SECRET-bun "$TEST_HOME"/.bunfig.toml.*~
}

# ------------------------------------------------------------------- upgrades
#
# tests/fixtures/user-config: what v2.0.0 and v2.1.0 wrote, each surface, made by
# running that version (role: ansible-core 2.16; no tools installed).

fixture() { # <version-surface>: put its files where they go
  local k d="$ROOT/tests/fixtures/user-config/$1"
  for k in npmrc $OTHERS; do
    mkdir -p "$(dirname "$(f "$k")")"
    cp "$d/$k" "$(f "$k")"
    chmod 644 "$(f "$k")"
  done
}

@test "user config: files v2.0.0 and v2.1.0 wrote, either surface, are upgraded without a word and without a copy" {
  local v k
  for v in v2.0.0-action v2.0.0-role v2.1.0-action v2.1.0-role; do
    rm -rf "$TEST_HOME"; mkdir -p "$TEST_HOME"
    fixture "$v"
    pf > "$BATS_TEST_TMPDIR/pf" || true
    ! grep -F "STOP  $TEST_HOME" "$BATS_TEST_TMPDIR/pf" || { echo "$v"; return 1; }
    apply > "$BATS_TEST_TMPDIR/log" 2>&1
    ! grep -E 'replaced .*not exactly|took your own|may set or defeat' "$BATS_TEST_TMPDIR/log" || { echo "$v"; return 1; }
    for k in npmrc $OTHERS; do
      [ -z "$(copies "$k")" ] || { echo "$v $k: $(copies "$k")"; return 1; }
    done
    for k in npmrc $MARKED; do
      grep -q 'self-check ' "$(f "$k")" || { echo "$v $k"; return 1; }
    done
    : > "$BATS_TEST_TMPDIR/none"
    npmrc_is_ours_then "$BATS_TEST_TMPDIR/none" || { echo "$v"; return 1; }
  done
}

@test "user config: one line added to a file v2.0.0 or v2.1.0 wrote makes it the user's, whatever the line" {
  lib
  local v k line
  # (a line is put second, after the marker, where it is met soonest)
  for v in v2.0.0-action v2.0.0-role v2.1.0-action v2.1.0-role; do
    for k in $OTHERS; do
      for line in 'some-key = "v"' '# a comment of mine' '; //registry/:_authToken=x' '  indented: 1' '[section]' 'registry: https://example/'; do
        { head -n 1 "$ROOT/tests/fixtures/user-config/$v/$k"; printf '%s\n' "$line"
          sed 1d "$ROOT/tests/fixtures/user-config/$v/$k"; } > "$BATS_TEST_TMPDIR/x"
        [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$v $k: $line"; return 1; }
      done
    done
  done
  # and last, where an appended token goes
  for k in $OTHERS; do
    { cat "$ROOT/tests/fixtures/user-config/v2.1.0-role/$k"; echo '# x'; } > "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k"; return 1; }
  done
}

@test "user config: a token added to an old ~/.npmrc is kept, and only that" {
  local v
  for v in v2.0.0-action v2.0.0-role v2.1.0-action v2.1.0-role; do
    rm -rf "$TEST_HOME"; mkdir -p "$TEST_HOME"
    fixture "$v"
    printf '# mine\n//registry.example/:_authToken=SECRET\n\n@corp:registry=https://corp.example/\n' > "$BATS_TEST_TMPDIR/mine"
    cat "$BATS_TEST_TMPDIR/mine" >> "$(f npmrc)"
    ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
    npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine" || { echo "$v"; cat "$(f npmrc)"; return 1; }
    [ -z "$(copies npmrc)" ]
    ! grep SECRET "$BATS_TEST_TMPDIR/log" || false
  done
}

# --------------------------------------------------------------------- ~/.npmrc

@test "npmrc: every line that is not ours stays, byte for byte and in order" {
  printf '# top comment\n; another\n\n@corp:registry=https://corp.example/\n//corp.example/:_authToken=${CORP_TOKEN}\n  spaced = value  \ncafile=/etc/ssl/corp.pem\nproxy=http://p:1\n[section]\nfund=true\nno trailing newline' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/mine"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  ! grep -E 'took your own|may set or defeat' "$BATS_TEST_TMPDIR/log" || false
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
  ECO=npm apply >/dev/null 2>&1
  cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
}

@test "npmrc: CRLF lines stay CRLF, and a CRLF-converted block is replaced, not doubled" {
  printf '//registry.example/:_authToken=SECRET\r\n\r\nproxy=http://p:1\r\n' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/mine"
  ECO=npm apply >/dev/null 2>&1
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  # an editor that saves the whole file with CRLF
  awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' "$(f npmrc)" > "$BATS_TEST_TMPDIR/crlf"
  cat "$BATS_TEST_TMPDIR/crlf" > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  ! grep 'took your own' "$BATS_TEST_TMPDIR/log" || false
}

@test "npmrc: a user's line for one of our settings is taken out after a 0600 copy, named, and its value never printed" {
  # Every spelling npm's ini reader takes for the key (MEASURED, npm 6 to 12).
  printf '%b' 'fund=SECRETVALUE\n"ignore-scripts"=false\n'"'"'audit'"'"'=false\nsave-exact ;x=false\nupdate-notifier[]=true\n\xc2\xa0allow-git=all\nkeep=1\rmin-release-age=0\rkeep2=2\n' > "$(f npmrc)"
  chmod 600 "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/orig"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  printf 'keep=1\rkeep2=2\n' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  grep -q 'took your own setting of fund, ignore-scripts, audit, save-exact, update-notifier, allow-git, min-release-age out of' "$BATS_TEST_TMPDIR/log"
  grep -q 'out of.*It may hold a token or a password: delete it once' "$BATS_TEST_TMPDIR/log" \
    || { cat "$BATS_TEST_TMPDIR/log"; return 1; }
  [ "$(copies npmrc | wc -l)" -eq 1 ]
  cmp "$(copies npmrc)" "$BATS_TEST_TMPDIR/orig"
  [ "$(mode "$(copies npmrc)")" = -rw------- ]
  grep -q "$(copies npmrc)" "$BATS_TEST_TMPDIR/log"
  ! grep SECRETVALUE "$BATS_TEST_TMPDIR/log" || false
  # and once only
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  ! grep 'took your own' "$BATS_TEST_TMPDIR/log" || false
  [ "$(copies npmrc | wc -l)" -eq 1 ]
}

@test "npmrc: what npm login leaves (our settings, no comments, no block) is ours again, with no copy and no warning" {
  apply >/dev/null 2>&1
  # `npm login` and `npm config set` rewrite the file without its comments, the
  # block markers included, and chmod it 0600 (MEASURED, npm 6 to 12).
  { settings; echo '//registry.example/:_authToken=SECRET'; } > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  echo '//registry.example/:_authToken=SECRET' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  [ -z "$(copies npmrc)" ]
  ! grep -E 'took your own|SECRET' "$BATS_TEST_TMPDIR/log" || false
}

@test "npmrc: the same with a real npm config set" {
  have npm || skip "npm not installed"
  apply >/dev/null 2>&1
  env -i PATH="$PATH" HOME="$TEST_HOME" npm config set //registry.example/:_authToken=SECRET --location=user >/dev/null 2>&1
  ! grep -q 'supply-chain-hardening' "$(f npmrc)" || skip "this npm kept the comments"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  echo '//registry.example/:_authToken=SECRET' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine" || { cat "$(f npmrc)"; return 1; }
  [ -z "$(copies npmrc)" ]
}

@test "npmrc: a line put inside the block stays, and an edited setting there is named" {
  apply >/dev/null 2>&1
  awk '{ print } /^audit=/ { print "//registry.example/:_authToken=SECRET"; print "; mine" } ' "$(f npmrc)" \
    | sed 's/^fund=false$/fund=true/' > "$BATS_TEST_TMPDIR/x"
  cat "$BATS_TEST_TMPDIR/x" > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  printf '//registry.example/:_authToken=SECRET\n; mine\n' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine" || { cat "$(f npmrc)"; return 1; }
  grep -q 'took your own setting of fund out of' "$BATS_TEST_TMPDIR/log"
}

@test "npmrc: a deleted end marker, and a block moved below other lines, lose nothing" {
  plant
  apply >/dev/null 2>&1
  { echo 'proxy=http://p:1'; grep -v '^; <<<' "$(f npmrc)"; } > "$BATS_TEST_TMPDIR/x"
  cat "$BATS_TEST_TMPDIR/x" > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  printf 'proxy=http://p:1\n//registry.example/:_authToken=SECRET-npmrc\n' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine" || { cat "$(f npmrc)"; return 1; }
  ! grep 'took your own' "$BATS_TEST_TMPDIR/log" || false
}

@test "npmrc: a changed window is our own line changing, not the user's" {
  plant
  apply >/dev/null 2>&1
  ECO=npm apply RELEASE_AGE_HOURS=168 > "$BATS_TEST_TMPDIR/log" 2>&1
  block | grep -qx 'min-release-age=7'
  [ "$(grep -c min-release-age "$(f npmrc)")" -eq 1 ]
  [ -z "$(copies npmrc)" ]
  ! grep 'took your own' "$BATS_TEST_TMPDIR/log" || false
}

@test "npmrc: a key that cannot be read with certainty is kept and named, not guessed at" {
  # shellcheck disable=SC2016
  printf '%s\n' '"ignore\u002dscripts"=false' '${X}=1' 'ignore-${Y}=1' '//${HOST}/:_authToken=SECRET' '[fund]' 'a=b' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/mine"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  # shellcheck disable=SC2016
  grep -qF 'line 1, a quoted key with an escape in it; line 2, the key ${...}; line 3, the key ignore-${...}; line 5, a [section] named after fund' "$BATS_TEST_TMPDIR/log" \
    || { cat "$BATS_TEST_TMPDIR/log"; return 1; }
  ! grep -E 'SECRET|HOST|\$\{[A-Z]' "$BATS_TEST_TMPDIR/log" || false
}

@test "npmrc: a key npm would warn about is left out, an older version's line for it too, and one of the user's own stays" {
  # npm 11.2 to 11.9 warn about a key they do not know, wherever it is. npm_writes_key
  # in harden.sh decides; here it is the file that has to follow.
  bare_path
  stub_npm 11.5.1
  local s
  for s in v2.0.0-action v2.1.0-action v2.1.0-role; do
    cp "$ROOT/tests/fixtures/user-config/$s/npmrc" "$(f npmrc)"
    printf '//registry.example/:_authToken=SECRET\n' >> "$(f npmrc)"
    harden PATH="$BARE_PATH" ECOSYSTEMS=npm -- --emit=plain > "$BATS_TEST_TMPDIR/log" 2>&1
    ! grep -E '^(min-release-age|allow-git)' "$(f npmrc)" || false
    grep -qx 'ignore-scripts=true' "$(f npmrc)"
    grep -q SECRET "$(f npmrc)"
    ! grep -E 'took your own|SECRET' "$BATS_TEST_TMPDIR/log" || false
  done
  [ -z "$(copies npmrc)" ]
  printf 'min-release-age=9\nallow-git=all\n' > "$(f npmrc)"
  harden PATH="$BARE_PATH" ECOSYSTEMS=npm -- --emit=plain > "$BATS_TEST_TMPDIR/log" 2>&1
  [ "$(grep -cxE 'min-release-age=9|allow-git=all' "$(f npmrc)")" -eq 2 ]
  # and back, once npm knows them: then they are settings like the others
  stub_npm 11.19.1
  harden PATH="$BARE_PATH" ECOSYSTEMS=npm -- --emit=plain > "$BATS_TEST_TMPDIR/log" 2>&1
  grep -q 'took your own setting of allow-git out of' "$BATS_TEST_TMPDIR/log"
  grep -q "kept your own min-release-age" "$BATS_TEST_TMPDIR/log"
  grep -qx 'min-release-age=2' "$(f npmrc)"
}

@test "npmrc: before, which npm uses instead of min-release-age, is kept and named" {
  # MEASURED on npm 11.19.1 and 12.2.3: with min-release-age=36500 and
  # before=<yesterday> in one file, in either order, the install goes through.
  printf 'before=2026-01-01\n' > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  rest | grep -qx 'before=2026-01-01'
  grep -q 'line 1, before, which npm uses instead of min-release-age' "$BATS_TEST_TMPDIR/log"
}

@test "npmrc: a longer min-release-age of the user's own is not loosened; a shorter one, or one that is not a whole number, goes" {
  local v
  for v in 3 14 '"30"' ' 365 ; a year'; do
    printf 'a=b\nmin-release-age=%s\n' "$v" > "$(f npmrc)"
    cp "$(f npmrc)" "$BATS_TEST_TMPDIR/mine"
    ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
    npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine" || { echo "$v"; cat "$(f npmrc)"; return 1; }
    [ -z "$(copies npmrc)" ]
    grep -q "npm: kept your own min-release-age in $(f npmrc), which is longer than this project's" "$BATS_TEST_TMPDIR/log"
    ! grep -E 'took your own' "$BATS_TEST_TMPDIR/log" || false
    # and again, the same
    cp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
    ECO=npm apply >/dev/null 2>&1
    cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
    pf > "$BATS_TEST_TMPDIR/pf" || true
    grep -qF "$(f npmrc): your own min-release-age stays, because it is longer" "$BATS_TEST_TMPDIR/pf"
  done
  if have npm; then
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    [ "$(cd "$BATS_TEST_TMPDIR/empty" && env -i PATH="$PATH" HOME="$TEST_HOME" npm config get min-release-age 2>/dev/null)" = 365 ]
  fi
  # shorter, equal (dropped: the block says it), nonsense, and the last one wins
  for v in 0 1 007 2.5 99d -5 true 99999999999; do
    rm -f "$(f npmrc)"*
    printf 'min-release-age=%s\n' "$v" > "$(f npmrc)"
    ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
    [ -z "$(rest)" ] || { echo "$v"; rest; return 1; }
    grep -q 'took your own setting of min-release-age out of' "$BATS_TEST_TMPDIR/log" || { echo "$v"; return 1; }
  done
  rm -f "$(f npmrc)"*
  printf 'min-release-age=14\nmin-release-age=1\nmin-release-age[]=99\n' > "$(f npmrc)"
  ECO=npm apply >/dev/null 2>&1
  [ "$(rest)" = 'min-release-age=14' ]
}

@test "npmrc: a byte-order mark stays at the start of the file" {
  printf '\357\273\277//registry.example/:_authToken=SECRET\n' > "$(f npmrc)"
  ECO=npm apply >/dev/null 2>&1
  [ "$(head -c 3 "$(f npmrc)" | od -An -tx1 | tr -d ' \n')" = efbbbf ]
  [ "$(LC_ALL=C grep -c "$(printf '\357\273\277')" "$(f npmrc)")" -eq 1 ]
  grep -qx '//registry.example/:_authToken=SECRET' "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
  ECO=npm apply >/dev/null 2>&1
  cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
}

@test "npmrc: npm reads our settings from the merged file, whatever the user's lines are" {
  have npm || skip "npm not installed"
  local d="$BATS_TEST_TMPDIR/empty" k n=0 c
  mkdir -p "$d"
  ask() { (cd "$d" && env -i PATH="$PATH" HOME="$TEST_HOME" npm config get "$1" --userconfig "$(f npmrc)" 2>/dev/null); }
  for c in 'a=b\n' '[section]\nignore-scripts=false\n' 'ignore-scripts=false\n' '"ignore-scripts"=false\n' 'ignore-scripts ;x=false' \
           'ignore-scripts[]=false\n' 'x=1\rignore-scripts=false\r\n' '\xef\xbb\xbfignore-scripts=false\n' '\xc2\xa0ignore-scripts=false\n' \
           ' ignore-scripts = false \nfund=true\n' "'\"ignore-scripts\"'=false\n" '[s] \nignore-scripts=false\n' 'ignore-scripts#x=false\n'; do
    rm -f "$(f npmrc)"* ; n=$((n + 1))
    { printf '//kept/:_authToken=K\n'; printf '%b' "$c"; } > "$(f npmrc)"
    ECO=npm apply >/dev/null 2>&1
    rest | grep -qx '//kept/:_authToken=K'
    [ "$(ask ignore-scripts)" = true ] || { echo "case $n: $c: $(ask ignore-scripts)"; cat "$(f npmrc)"; return 1; }
    [ "$(ask fund)" = false ] || { echo "case $n: $c: fund $(ask fund)"; return 1; }
  done
  # FIXTURE CONTROL: without the rule, that line wins.
  printf 'ignore-scripts=true\n"ignore-scripts"=false\n' > "$(f npmrc)"
  [ "$(ask ignore-scripts)" = false ]
}

@test "npmrc: npm still sends the kept token" {
  have npm && have node || skip "npm not installed"
  # A registry that records the Authorization header it is sent.
  cat > "$BATS_TEST_TMPDIR/reg.js" <<'JS'
const http = require('http'), fs = require('fs')
const s = http.createServer((q, r) => {
  fs.appendFileSync(process.argv[3], (q.headers.authorization || 'none') + '\n')
  r.setHeader('content-type', 'application/json'); r.end('{"username":"me"}')
}).listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], String(s.address().port)))
setTimeout(() => process.exit(0), 60000)
JS
  node "$BATS_TEST_TMPDIR/reg.js" "$BATS_TEST_TMPDIR/port" "$BATS_TEST_TMPDIR/auth" 3>&- >/dev/null 2>&1 &
  local pid=$! i port
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.25; done
  port=$(cat "$BATS_TEST_TMPDIR/port")
  printf 'registry=http://127.0.0.1:%s/\n//127.0.0.1:%s/:_authToken=FAKETOKEN\n' "$port" "$port" > "$(f npmrc)"
  chmod 600 "$(f npmrc)"
  ECO=npm apply >/dev/null 2>&1
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  (cd "$BATS_TEST_TMPDIR/empty" && env -i PATH="$PATH" HOME="$TEST_HOME" npm whoami --userconfig "$(f npmrc)" >/dev/null 2>&1) || true
  kill "$pid" 2>/dev/null || true
  grep -qx 'Bearer FAKETOKEN' "$BATS_TEST_TMPDIR/auth" || { cat "$BATS_TEST_TMPDIR/auth"; return 1; }
}

# -------------------------------------------------------------------- composer

@test "composer: a home that only has ~/.composer keeps it, and the tokens in its auth.json stay composer's" {
  # composer reads the first that exists of ~/.config/composer and ~/.composer
  # wherever an XDG_ variable or /etc/xdg does. Making the first hid the second, and
  # its auth.json (MEASURED on 2.11.2).
  mkdir -p "$TEST_HOME/.composer"
  printf '{"github-oauth": {"github.com": "SECRET"}}\n' > "$TEST_HOME/.composer/auth.json"
  chmod 600 "$TEST_HOME/.composer/auth.json"
  cp "$TEST_HOME/.composer/auth.json" "$BATS_TEST_TMPDIR/auth"
  harden ECOSYSTEMS=composer -- --emit=plain > "$BATS_TEST_TMPDIR/log" 2>&1
  harden ECOSYSTEMS=composer -- --emit=plain >> "$BATS_TEST_TMPDIR/log" 2>&1
  [ ! -e "$TEST_HOME/.config/composer" ]
  grep -q '"period": 172800' "$TEST_HOME/.composer/config.json"
  cmp "$TEST_HOME/.composer/auth.json" "$BATS_TEST_TMPDIR/auth"
  [ "$(mode "$TEST_HOME/.composer/auth.json")" = -rw------- ]
  ! grep -E 'SECRET|not exactly' "$BATS_TEST_TMPDIR/log" || false
  # and where both are there, both stay
  mkdir -p "$TEST_HOME/.config/composer"
  harden ECOSYSTEMS=composer -- --emit=plain >/dev/null 2>&1
  [ -f "$TEST_HOME/.config/composer/config.json" ]
  cmp "$TEST_HOME/.composer/auth.json" "$BATS_TEST_TMPDIR/auth"
}

@test "composer: what composer writes the first time it is asked anything is not the user's" {
  mkdir -p "$XDG/composer"
  local c
  for c in '{"config": {}}' '{\n    "config": {}\n}\n' '{}' '' '\n'; do
    printf "$c" > "$(f composer)"
    ECO=composer apply > "$BATS_TEST_TMPDIR/log" 2>&1
    grep -q '"secure-http": true' "$(f composer)"
    [ -z "$(copies composer)" ]
    ! grep 'not exactly' "$BATS_TEST_TMPDIR/log" || false
  done
  # but any setting is
  for c in '{"config": {"lock": false}}' '{"repositories": []}' '{\n  "config": {\n    "secure-http": false\n  }\n}'; do
    rm -f "$(f composer)"*
    printf "$c" > "$(f composer)"
    ECO=composer apply > "$BATS_TEST_TMPDIR/log" 2>&1
    [ -n "$(copies composer)" ] || { echo "$c"; return 1; }
    grep -q 'composer: replaced .*not exactly' "$BATS_TEST_TMPDIR/log"
  done
}

@test "composer: the directory it reads is worked out as composer does" {
  lib
  local H="$BATS_TEST_TMPDIR/ch" xdg=0
  [ ! -d /etc/xdg ] || xdg=1
  home() { env -i PATH="$PATH" HOME="$H" "$@" bash -c '. "$0"; ucf_composer_home' "$BATS_TEST_TMPDIR/lib.sh"; }
  mkdir -p "$H"
  [ "$(home COMPOSER_HOME=/ch XDG_RUNTIME_DIR=/r)" = /ch ]
  [ "$(home XDG_RUNTIME_DIR=/r)" = "$H/.config/composer" ]
  [ "$(home XDG_CONFIG_HOME="$H/xc")" = "$H/xc/composer" ]
  if [ "$xdg" = 0 ]; then [ "$(home)" = "$H/.composer" ]; else [ "$(home)" = "$H/.config/composer" ]; fi
  mkdir -p "$H/.composer"
  [ "$(home XDG_RUNTIME_DIR=/r)" = "$H/.composer" ]
  [ "$(home XDG_CONFIG_HOME="$H/xc")" = "$H/.composer" ]
  mkdir -p "$H/.config/composer" "$H/xc/composer"
  [ "$(home XDG_RUNTIME_DIR=/r)" = "$H/.config/composer" ]
  [ "$(home XDG_CONFIG_HOME="$H/xc")" = "$H/xc/composer" ]
  if [ "$xdg" = 0 ]; then [ "$(home)" = "$H/.composer" ]; fi
  # and as the composer here answers, where there is one
  have composer || return 0
  [ "$(home XDG_RUNTIME_DIR=/r)" = "$(cd / && env -i PATH="$PATH" HOME="$H" XDG_RUNTIME_DIR=/r COMPOSER_ALLOW_SUPERUSER=1 composer config --global home --no-plugins -n 2>/dev/null | tail -1)" ]
}

# ------------------------------------------------------------ root's yarn file

@test "user config: a file in root's home is read, kept and written as root, by the same rule" {
  # harden.sh's ucf_as_root hands its functions to a root shell. The rule is the
  # shared one: what differs is whose file it is.
  sudo -n true 2>/dev/null || skip "no passwordless sudo"
  lib
  sed -n '/^ucf_as_root() {$/,/^}$/p' "$HARDEN_SH" > "$BATS_TEST_TMPDIR/asroot.sh"
  # shellcheck disable=SC1091
  . "$BATS_TEST_TMPDIR/asroot.sh"
  # shellcheck disable=SC2034
  SUDO=sudo
  local d body
  d=$(rootdir)
  body=$'# Managed by supply-chain-harden action\nenableScripts: false'
  [ "$(ucf_as_root yarn "$d/.yarnrc.yml" <<<"$body")" = changed ]
  sudo head -1 "$d/.yarnrc.yml" | grep -q 'self-check sha256:'
  [ "$(sudo ls -ldn "$d/.yarnrc.yml" | awk '{print $1, $3}' | cut -c1-12)" = '-rw-r--r-- 0' ]
  [ "$(ucf_as_root yarn "$d/.yarnrc.yml" <<<"$body")" = ok ]
  # a token added to it since: kept, 0600, root's, and not printed
  echo 'npmAuthToken: "SECRET"' | sudo tee -a "$d/.yarnrc.yml" >/dev/null
  sudo chmod 600 "$d/.yarnrc.yml"
  run ucf_as_root yarn "$d/.yarnrc.yml" <<<"$body"
  [ "$status" -eq 0 ]
  [[ "$output" == "copy $d/.yarnrc.yml."*$'\n'changed ]] || { echo "$output"; return 1; }
  sudo grep -q SECRET "${lines[0]#copy }"
  [ "$(sudo ls -ldn "${lines[0]#copy }" | awk '{print $1, $3}' | cut -c1-12)" = '-rw------- 0' ]
  ! sudo grep -q SECRET "$d/.yarnrc.yml" || false
  [ "$(sudo ls -ldn "$d/.yarnrc.yml" | cut -c1-10)" = -rw------- ]
  sudo rm -rf "$d"
}

@test "user config: root's shell for that file gets nothing of the caller's PATH or environment" {
  # A root shell that found its tools on the caller's PATH would run what the caller
  # put there.
  sudo -n true 2>/dev/null || skip "no passwordless sudo"
  lib
  sed -n '/^ucf_as_root() {$/,/^}$/p' "$HARDEN_SH" > "$BATS_TEST_TMPDIR/asroot.sh"
  # shellcheck disable=SC1091
  . "$BATS_TEST_TMPDIR/asroot.sh"
  # shellcheck disable=SC2034
  SUDO=sudo
  local t
  mkdir -p "$BATS_TEST_TMPDIR/evil"
  for t in sed cat mktemp mv chmod ls cmp sha256sum awk bash env; do
    printf '#!/bin/sh\n[ "$(id -u)" != 0 ] || touch "%s/ran-%s"\nexec /usr/bin/env -i PATH=/usr/bin:/bin %s "$@"\n' "$BATS_TEST_TMPDIR" "$t" "$t" > "$BATS_TEST_TMPDIR/evil/$t"
    chmod +x "$BATS_TEST_TMPDIR/evil/$t"
  done
  local d
  d=$(rootdir)
  ( PATH="$BATS_TEST_TMPDIR/evil:$PATH"; BASH_ENV="$BATS_TEST_TMPDIR/evil/bash"; export BASH_ENV
    ucf_as_root yarn "$d/y" <<<$'# Managed by supply-chain-harden action\na: 1' ) | grep -qx changed
  [ -z "$(ls "$BATS_TEST_TMPDIR" | grep '^ran-')" ] || { ls "$BATS_TEST_TMPDIR"; return 1; }
  sudo rm -rf "$d"
}

# ------------------------------------- where root writes, and where it does not

@test "root: a path is one no other account controls, part by part" {
  need_sudo
  lib
  local d n="other accounts can write to" u x
  d=$(rootdir)
  u=$(id -u)
  sudo mkdir -p "$d/ok/etc" "$d/gw/etc" "$d/ow/etc" "$d/st/etc" "$d/mine/etc"
  sudo touch "$d/ok/etc/npmrc" "$d/ok/gwfile" "$d/ok/myfile"
  sudo chmod 775 "$d/gw"; sudo chmod 757 "$d/ow"; sudo chmod 1777 "$d/st"; sudo chmod 664 "$d/ok/gwfile"
  sudo chown "$u" "$d/mine" "$d/ok/myfile"
  sudo ln -s "$d/ok" "$d/abs"; sudo ln -s ../ok "$d/ok/rel"; sudo ln -s loop "$d/loop"
  sudo ln -s "$d/mine/etc" "$d/out"; sudo ln -s ok/etc/npmrc "$d/file"
  why() { sudo bash -c '. "$1"; shift; ucf_roots "$@"' bash "$BATS_TEST_TMPDIR/lib.sh" "$@"; }
  sed -n '/^# >>> user_config$/,/^# <<< user_config$/p' "$ROOT/files/user-config.sh" > "$BATS_TEST_TMPDIR/lib.sh"
  # what root may write
  for x in "$d/ok/etc/npmrc" "$d/ok/etc/new" "$d/ok/new/deeper/npmrc"; do
    [ -z "$(why "$x" plain)" ] || { why "$x" plain; return 1; }
    [ -z "$(why "$x")" ]
  done
  # what it may not, and what it says
  for x in gw ow st; do
    [[ "$(why "$d/$x/etc/npmrc" plain)" == *"is in $d/$x, which $n" ]]
    [[ "$(why "$d/$x/etc/npmrc")" == *"is in $d/$x, which $n" ]]
    [[ "$(why "$d/$x/new")" == *"is in $d/$x, which $n" ]]
  done
  [ "$(why "$d/mine/etc/npmrc" plain)" = "is in $d/mine, which is not root's" ]
  [ "$(why "$d/mine/new")" = "is in $d/mine, which is not root's" ]
  [ "$(why "$d/ok/myfile" plain)" = "is in $d/ok/myfile, which is not root's" ]
  [[ "$(why "$d/ok/gwfile" plain)" == *"$n" ]]
  [ -z "$(why "$d/ok/gwfile")" ]               # in a directory of root's alone, it is only replaced
  # a link: never in a plain path; followed elsewhere, when what it leads to is root's
  for x in abs/etc/npmrc ok/rel/etc/npmrc loop/x out/npmrc file; do
    [[ "$(why "$d/$x" plain)" == "goes through $d/"*", a symbolic link" ]] || { why "$d/$x" plain; return 1; }
  done
  [ -z "$(why "$d/abs/etc/npmrc")" ]
  [ -z "$(why "$d/ok/rel/etc/new")" ]
  [ -z "$(why "$d/file")" ]
  [ "$(why "$d/out/npmrc")" = "is in $d/mine, which is not root's" ]
  [[ "$(why "$d/loop/x")" == "goes through "*", a symbolic link" ]]
  # and a path that is not a path
  for x in "$d/ok/../ok/etc/npmrc" "$d//ok/etc/npmrc" "$d/./ok/npmrc" "ok/etc/npmrc" "" $'/etc/x\ny'; do
    [ -n "$(why "$x" plain)" ] || { echo "$x"; return 1; }
    [ -n "$(why "$x")" ]
  done
  # npm's global config is named as npm names it
  no() { sudo bash -c '. "$1"; shift; ucf_no_root "$@"' bash "$BATS_TEST_TMPDIR/lib.sh" npm-global "$1"; }
  [ -z "$(no "$d/ok/etc/npmrc")" ]
  for x in "$d/ok/etc/new" "$d/ok/npmrc" /etc/ld.so.preload; do [[ "$(no "$x")" == "is not what npm names"* ]]; done
  sudo rm -rf "$d"
}

@test "root: where another account controls the path nothing is read or written, and it says so" {
  need_sudo
  lib
  sed -n '/^ucf_as_root() {$/,/^}$/p' "$HARDEN_SH" > "$BATS_TEST_TMPDIR/asroot.sh"
  # shellcheck disable=SC1091
  . "$BATS_TEST_TMPDIR/asroot.sh"
  # shellcheck disable=SC2034
  SUDO=sudo
  local d body h="$BATS_TEST_TMPDIR/h" t
  d=$(rootdir)
  mkdir -p "$h"
  body=$'# Managed by supply-chain-harden action\na: 1'
  printf 'mine: 1\n' > "$h/mine"
  printf 'SECRET\n' | sudo tee "$d/theirs" >/dev/null
  sudo chmod 600 "$d/theirs"
  ln -s "$d/theirs" "$h/link"; ln -s "$d" "$h/dir"; mkfifo "$h/fifo"
  t=$(sudo ls -lanR "$d")
  for x in mine link dir/theirs dir/new fifo new; do
    run ucf_as_root yarn "$h/$x" <<<"$body"
    [ "$status" -eq 1 ]
    [[ "$output" == "error: $h/$x is in /"*"root writes only to paths no other account controls; it was left as it is" ]] || { echo "$x: $output"; return 1; }
  done
  [ "$(sudo ls -lanR "$d")" = "$t" ]
  [ "$(cat "$h/mine")" = 'mine: 1' ]
  [ "$(ls -A "$h" | tr '\n' ' ')" = 'dir fifo link mine ' ]
  # the same through the script the role runs, for npm's global config too
  for x in yarn npm-global; do
    for t in "$h/new/etc/npmrc" "$h/dir/etc/npmrc"; do
      run sudo env SCH_UCF_ROOT=1 SCH_UCF_FOREIGN=keep SCH_UCF_PATH="$t" SCH_UCF_BODY="; Managed by ansible-supply-chain-security" bash "$ROOT/files/user-config.sh" replace "$x"
      [ "$status" -eq 1 ]
      [[ "$output" == *"error: $t "*"root writes only to paths no other account controls"* ]] || { echo "$output"; return 1; }
      run sudo env SCH_UCF_ROOT=1 SCH_UCF_PATH="$t" bash "$ROOT/files/user-config.sh" classify "$x"
      [[ "$output" == "blocked $t "*"root writes only to paths no other account controls"* ]] || { echo "$output"; return 1; }
    done
  done
  [ ! -e "$h/new" ]
  # and a root that sudo made of this account, with this account's home
  run sudo env HOME="$h" SCH_UCF_FOREIGN=keep SCH_UCF_BODY="$body" bash "$ROOT/files/user-config.sh" replace yarn
  [ "$status" -eq 1 ]
  [[ "$output" == *"(run this as $(id -un), not as root)"* ]] || { echo "$output"; return 1; }
  [ ! -e "$h/.yarnrc.yml" ]
  sudo rm -rf "$d"
}

@test "root: with sudo and this account's home, harden.sh writes none of these files" {
  need_sudo
  printf '//registry.example/:_authToken=SECRET\n' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/before"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$(f yarn)"
  run sudo env -i SUDO_UID="$(id -u)" SUDO_USER="$(id -un)" PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" XDG_CONFIG_HOME="$XDG" TMPDIR="$TEST_TMP" \
    WRITE_ETC=false ECOSYSTEMS=npm,yarn bash "$HARDEN_SH" --emit=plain
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "$(f npmrc) is in /"
  ! echo "$output" | grep SECRET || false
  cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/before"
  [ -O "$(f npmrc)" ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
  sudo rm -rf "$TEST_HOME" "$TEST_TMP"         # what the run kept in them is root's
}

@test "root: every become that runs user-config.sh in the role says so" {
  python3 -c 'import yaml' 2>/dev/null || skip "no python3 with PyYAML"
  python3 - "$ROOT"/tasks/*.yml <<'PY'
import sys, yaml
n = 0
def walk(ts, f):
    global n
    for t in ts or []:
        for k in ('block', 'rescue', 'always'):
            walk(t.get(k), f)
        if 'user-config.sh' not in str(t):
            continue
        b, e = t.get('become', False), (t.get('environment') or {}).get('SCH_UCF_ROOT')
        if b is False:
            assert e is None, (f, t['name'])
            continue
        n += 1
        # on stdin: no file of the connecting account's is what root runs
        assert 'ansible.builtin.script' not in t and 'user-config.sh' in t['ansible.builtin.command']['stdin'], (f, t['name'])
        if b is True:
            assert e == '1', (f, t['name'])
        else:                      # the same condition decides both
            cond = b.strip('{} ')
            assert e is not None and "ternary('1', '0')" in e and "'as root' in" in cond and "'as root' in" in e, (f, t['name'])
for f in sys.argv[1:]:
    walk(yaml.safe_load(open(f)), f)
assert n == 5, n
PY
}

@test "npm: its global config is the one every account's npm reads, whatever this account's settings say" {
  have npm && have node || skip "npm not installed"
  lib
  local real x t="$BATS_TEST_TMPDIR/trap"
  mkdir -p "$t/etc"
  ask() { ( export HOME="$TEST_HOME"; "$@" ); }
  real=$(cd / && env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" "$(ucf_npm)" config get globalconfig 2>/dev/null | tail -1)
  case "$real" in /*) ;; *) skip "npm does not say" ;; esac
  [ "$(ask ucf_npm_global "$(ucf_npm)")" = "$real" ]
  # the control (in a home of its own, where npm may write): npm goes where these say.
  # Not prefix= where npm's own npmrc names the global one (Debian's npm, and the npm on
  # Grokbot's VM, 11-25): there it is not under the prefix, and prefix= does not move it.
  # MEASURED on npm 11.19.1 with globalconfig=/etc/npmrc in its own npmrc: prefix= left
  # /etc/npmrc, globalconfig= moved it.
  local pinned=""
  [ "$(cd / && env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" "$(ucf_npm)" prefix -g 2>/dev/null | tail -1)/etc/npmrc" = "$real" ] || pinned=1
  mkdir -p "$BATS_TEST_TMPDIR/ctl"
  for x in "prefix=$t" "globalconfig=$t/etc/npmrc"; do
    printf '%s\n' "$x" | tee "$TEST_HOME/.npmrc" > "$BATS_TEST_TMPDIR/ctl/.npmrc"
    if [ -z "$pinned" ] || [ "${x%%=*}" != prefix ]; then
      [ "$(cd / && env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/ctl" "$(ucf_npm)" config get globalconfig 2>/dev/null | tail -1)" = "$t/etc/npmrc" ]
    fi
    [ "$(ask ucf_npm_global "$(ucf_npm)")" = "$real" ]
  done
  rm -f "$TEST_HOME/.npmrc"
  for x in NPM_CONFIG_PREFIX="$t" npm_config_prefix="$t" NPM_CONFIG_GLOBALCONFIG="$t/etc/npmrc" Npm_Config_GlobalConfig="$t/etc/npmrc" PREFIX="$t" DESTDIR="$t" NODE_OPTIONS=--nonsense; do
    [ "$( export "$x"; ask ucf_npm_global "$(ucf_npm)" )" = "$real" ] || { echo "$x"; return 1; }
  done
  printf 'prefix=%s\n' "$t" > "$BATS_TEST_TMPDIR/rc"
  [ "$( export NPM_CONFIG_USERCONFIG="$BATS_TEST_TMPDIR/rc"; ask ucf_npm_global "$(ucf_npm)" )" = "$real" ]
  [ -z "$(ls -A "$TEST_HOME")" ]
}

# --------------------------------------------------------------- modes and links

@test "user config: ~/.npmrc ends 0600, or tighter if it was; nothing is loosened" {
  local m want
  for m in 644 600 660 400 444 666; do
    rm -f "$(f npmrc)"
    printf 'a=b\n' > "$(f npmrc)"; chmod "$m" "$(f npmrc)"
    ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
    case "$m" in 4*) want=-r-------- ;; *) want=-rw------- ;; esac
    [ "$(mode "$(f npmrc)")" = "$want" ] || { echo "$m: $(mode "$(f npmrc)")"; return 1; }
    case "$m" in 600|400) ! grep 'is 0600 now' "$BATS_TEST_TMPDIR/log" ;; *) grep -q "$(f npmrc): other accounts could read it" "$BATS_TEST_TMPDIR/log" ;; esac
  done
}

@test "user config: the other seven keep their mode or get a tighter one" {
  plant
  local k
  for k in $OTHERS; do chmod 600 "$(f "$k")"; done
  apply >/dev/null 2>&1
  for k in $OTHERS; do [ "$(mode "$(f "$k")")" = -rw------- ] || { echo "$k $(mode "$(f "$k")")"; return 1; }; done
  # and over a file of our own, loosened by hand
  for k in $OTHERS; do chmod 666 "$(f "$k")"; done
  apply >/dev/null 2>&1
  for k in $OTHERS; do [ "$(mode "$(f "$k")")" = -rw-r--r-- ] || { echo "$k $(mode "$(f "$k")")"; return 1; }; done
}

@test "user config: a symlinked file is written through, and the link stays" {
  mkdir -p "$TEST_HOME/dotfiles"
  plant
  local k
  for k in npmrc $OTHERS; do
    mv "$(f "$k")" "$TEST_HOME/dotfiles/$k"
    ln -s "$TEST_HOME/dotfiles/$k" "$(f "$k")"
  done
  # a relative link too
  rm -f "$(f npmrc)"; ln -s dotfiles/npmrc "$(f npmrc)"
  apply >/dev/null 2>&1
  for k in npmrc $OTHERS; do
    [ -L "$(f "$k")" ] || { echo "$k: link gone"; return 1; }
    [ ! -L "$TEST_HOME/dotfiles/$k" ]
  done
  for k in npmrc $MARKED; do grep -q 'Managed by supply-chain-harden' "$TEST_HOME/dotfiles/$k" || { echo "$k"; return 1; }; done
  grep -q '"secure-http": true' "$TEST_HOME/dotfiles/composer"
  grep -q SECRET-npmrc "$TEST_HOME/dotfiles/npmrc"
  # the copies are next to the link, not in the dotfiles checkout somebody commits
  [ -z "$(ls "$TEST_HOME/dotfiles" | grep '~$')" ]
  for k in $OTHERS; do grep -q "SECRET-$k" "$(copies "$k")"; done
  local before
  before=$(snapshot_but_cutoffs)
  apply >/dev/null 2>&1
  diff <(printf '%s\n' "$before") <(snapshot_but_cutoffs)
}

@test "user config: a dangling link is filled in; a link to a device is refused and the device left alone" {
  ln -s "$TEST_HOME/elsewhere" "$(f npmrc)"
  ECO=npm apply >/dev/null 2>&1
  [ -L "$(f npmrc)" ]
  grep -q '^ignore-scripts=true' "$TEST_HOME/elsewhere"
  rm -f "$(f npmrc)"; ln -s /dev/null "$(f npmrc)"
  ECO=npm run apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"$(f npmrc) is not a regular file; it was left as it is"* ]]
  [ -c /dev/null ]
  run pf
  [[ "$output" == *"STOP  $(f npmrc): is not a regular file"* ]]
}

@test "user config: a file in the way that cannot be written is refused by name, and nothing in it changes" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: nothing is unreadable"
  printf 'a=SECRET\n' > "$(f npmrc)"; chmod 000 "$(f npmrc)"
  ECO=npm run apply
  chmod 600 "$(f npmrc)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm: $(f npmrc) cannot be read by"* ]]
  [ "$(cat "$(f npmrc)")" = a=SECRET ]
  # a directory that cannot be written to: no atomic write and no copy is possible
  mkdir -p "$(dirname "$(f uv)")"
  printf 'x = "SECRET"\n' > "$(f uv)"
  chmod 555 "$(dirname "$(f uv)")"
  run pf
  chmod 755 "$(dirname "$(f uv)")"
  # The directory as it really is: a Mac's TMPDIR is under /var, a link to /private/var.
  local d; d=$(cd -P "$(dirname "$(f uv)")" && pwd -P)
  [[ "$output" == *"STOP  $(f uv): cannot be replaced: $d is not writable by"* ]] || { echo "$output"; return 1; }
  [ "$(cat "$(f uv)")" = 'x = "SECRET"' ]
  chmod 555 "$(dirname "$(f uv)")"
  ECO=uv run apply
  chmod 755 "$(dirname "$(f uv)")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"uv: $(f uv) cannot be replaced: $d is not writable by"* ]]
  [ "$(cat "$(f uv)")" = 'x = "SECRET"' ]
}

@test "user config: a read-only home is refused by name, not with a bare shell error" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$state"
  chmod 555 "$TEST_HOME"
  ECO=npm run apply RUNNER_TEMP="$state"
  chmod 755 "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm: $(f npmrc) cannot be created: $TEST_HOME is not a directory this account can write to"* ]] || { echo "$output"; return 1; }
  [ ! -e "$(f npmrc)" ]
}

@test "user config: another account's file that is already what we write stops nothing (a shared CARGO_HOME)" {
  sudo -n true 2>/dev/null || skip "no passwordless sudo"
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  local ch="$BATS_TEST_TMPDIR/cargo"
  mkdir -m 777 "$ch"
  cargo_apply() { harden ECOSYSTEMS=cargo CARGO_HOME="$ch" -- --emit=plain; }
  cargo_apply >/dev/null 2>&1
  sudo chown 0 "$ch/config.toml"
  run cargo_apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" CARGO_HOME="$ch" bash "$HARDEN_SH" --preflight > "$BATS_TEST_TMPDIR/pf" || true
  grep -qF "$ch/config.toml: exactly what this project last wrote" "$BATS_TEST_TMPDIR/pf"
  # with something in it that is not ours, it is refused by name
  echo '# SECRET' | sudo tee -a "$ch/config.toml" >/dev/null
  run cargo_apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo: $ch/config.toml belongs to another account (root)"* ]]
  sudo grep -q SECRET "$ch/config.toml"
  sudo rm -f "$ch/config.toml"
}

@test "user config: a file an earlier version wrote that this account cannot rewrite stops the preflight, not the run" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  lib
  local v k d out pfout
  # Each kind whose file has a directory of its own, made read-only. The run has to
  # write every one of them again, because what it writes now carries a checksum.
  # (Composer's has no marker, and what is written to it is the same as before.)
  for v in v2.0.0-action v2.0.0-role v2.1.0-action v2.1.0-role; do
    rm -rf "$TEST_HOME"; mkdir -p "$TEST_HOME"
    fixture "$v"
    for k in pnpm-rc pip uv bundler cargo maven nuget; do
      [ "$(user_cfg_class "$k" "$(f "$k")")" = ours ] || { echo "$v $k: not ours"; return 1; }
      d=$(dirname "$(f "$k")")
      chmod 555 "$d"
      out=$(ucf_stuck "$k" "$(f "$k")")
      chmod 755 "$d"
      [[ "$out" == "cannot be replaced: "*" is not writable by "* ]] || { echo "$v $k: '$out'"; return 1; }
    done
  done
  # Both preflights say so, before anything is written: harden.sh's and the role's.
  chmod 555 "$(dirname "$(f uv)")"
  run pf
  pfout=$output
  run env SCH_UCF_PATH="$(f uv)" bash "$ROOT/files/user-config.sh" classify uv
  chmod 755 "$(dirname "$(f uv)")"
  [[ "$pfout" == *"STOP  $(f uv): cannot be replaced: "* ]] || { echo "$pfout"; return 1; }
  [ "$status" -eq 42 ]
  [[ "$output" == "blocked $(f uv) cannot be replaced: "* ]] || { echo "$output"; return 1; }
}

@test "user config: this version's own file that the account cannot rewrite is left to the run, and the preflight says what that means" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  lib
  local d out
  ECO=cargo apply >/dev/null 2>&1
  grep -q 'self-check ' "$(f cargo)"
  d=$(dirname "$(f cargo)")
  chmod 555 "$d"
  out=$(ucf_stuck cargo "$(f cargo)")
  run pf
  chmod 755 "$d"
  [ -z "$out" ] || { echo "'$out'"; return 1; }
  [[ "$output" == *"note  $(f cargo): exactly what this project last wrote, but it cannot be replaced: "*"stops at that file, after the ones before it."* ]] || { echo "$output"; return 1; }
  ! grep -qF "$(f cargo): exactly what this project last wrote, replaced as before" <<<"$output" || false
  # A mode the run has to change is a write it cannot skip, so that one stops here.
  chmod 666 "$(f cargo)"
  chmod 555 "$d"
  out=$(ucf_stuck cargo "$(f cargo)")
  chmod 755 "$d"
  [[ "$out" == "cannot be replaced: "* ]] || { echo "'$out'"; return 1; }
}

@test "user config: a file another account owns is refused, and kept" {
  sudo -n true 2>/dev/null || skip "no passwordless sudo"
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  printf 'a=SECRET\n' > "$(f npmrc)"
  sudo chown 0 "$(f npmrc)"
  ECO=npm run apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"$(f npmrc) belongs to another account (root); it was left as it is"* ]]
  grep -q SECRET "$(f npmrc)"
}

# stub <name> <body>: first on PATH for the ucf_ functions of this test
stub() { mkdir -p "$BATS_TEST_TMPDIR/stub"; printf '#!/bin/bash\n%s\n' "$2" > "$BATS_TEST_TMPDIR/stub/$1"; chmod +x "$BATS_TEST_TMPDIR/stub/$1"; }
npmrc_body() { echo '; Managed by supply-chain-harden action'; settings; }

# A root in a container without CAP_CHOWN, or whose user namespace has no such group:
# "Operation not permitted" for owner:group. MEASURED (podman run --cap-drop CHOWN, files
# root:nogroup; reported from an agent's VM): ef4da26 stopped on "could not write ~/.npmrc".
root_without_chown() { # <allowed: owner|nothing>
  stub id '[ "${1:-}" != -u ] || { echo 0; exit 0; }; exec /usr/bin/id "$@"'
  if [ "$1" = owner ]; then stub chown 'case "$*" in *:*) exit 1 ;; esac; exit 0'; else stub chown 'exit 1'; fi
}

@test "user config: root that cannot keep a file's group writes it, and no other group gains by it" {
  lib
  local m want
  root_without_chown owner
  printf '//r/:_authToken=SECRET\n' > "$(f npmrc)"; chmod 644 "$(f npmrc)"
  ( PATH="$BATS_TEST_TMPDIR/stub:$PATH"; npmrc_body | ucf_npmrc "$(f npmrc)" ) > "$BATS_TEST_TMPDIR/o" || { cat "$BATS_TEST_TMPDIR/o"; false; }
  grep -q SECRET "$(f npmrc)"
  grep -q '^ignore-scripts=true' "$(f npmrc)"
  [ "$(ls -ld "$(f npmrc)" | cut -c1-10)" = -rw------- ]
  # only its group could read it: now nobody else can. Everybody could: they still can.
  for m in 640:-rw------- 644:-rw-r--r-- 600:-rw------- 604:-rw----r--; do
    want=${m#*:}
    printf 'npmAuthToken: SECRET\n' > "$(f yarn)"; chmod "${m%%:*}" "$(f yarn)"
    ( PATH="$BATS_TEST_TMPDIR/stub:$PATH"; echo '# Managed by supply-chain-harden action' | ucf_replace yarn "$(f yarn)" ) > "$BATS_TEST_TMPDIR/o" || { cat "$BATS_TEST_TMPDIR/o"; false; }
    [ "$(ls -ld "$(f yarn)" | cut -c1-10)" = "$want" ] || { echo "$m"; ls -l "$(f yarn)"; false; }
  done
}

@test "user config: root that cannot keep a file's owner leaves it, and says why" {
  lib
  root_without_chown nothing
  printf '//r/:_authToken=SECRET\n' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/orig"
  ( PATH="$BATS_TEST_TMPDIR/stub:$PATH"; npmrc_body | ucf_npmrc "$(f npmrc)" ) > "$BATS_TEST_TMPDIR/o" && { cat "$BATS_TEST_TMPDIR/o"; false; }
  cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/orig"
  grep -qF "error: $(f npmrc): its owner (uid $(id -u)) cannot be kept, because this root cannot change a file's owner. Run this as that account" "$BATS_TEST_TMPDIR/o" || { cat "$BATS_TEST_TMPDIR/o"; false; }
  [ -z "$(find "$TEST_HOME" -name '.sch-*')" ]
}

@test "user config: as root without CAP_CHOWN, for real, harden.sh finishes and keeps the token" {
  sudo -n true 2>/dev/null || skip "no passwordless sudo"
  command -v setpriv >/dev/null || skip "no setpriv (Linux, util-linux)"
  local other
  printf '//r/:_authToken=SECRET\n' > "$(f npmrc)"
  sudo chown 0:65534 "$(f npmrc)" "$TEST_HOME"
  # FIXTURE CONTROL: this root cannot do it
  run sudo setpriv --bounding-set=-chown --inh-caps=-chown chown 0:65534 "$HARDEN_SH"
  [ "$status" -ne 0 ]
  run sudo setpriv --bounding-set=-chown --inh-caps=-chown env -i PATH="${TEST_BIN}:/usr/bin:/bin" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    WRITE_ETC=false ECOSYSTEMS=npm,pip bash "$HARDEN_SH" --emit=plain
  sudo chown -R "$(id -u):$(id -g)" "$TEST_HOME" "$TEST_TMP"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q SECRET "$(f npmrc)"
  grep -q '^ignore-scripts=true' "$(f npmrc)"
  [ "$(ls -ld "$(f npmrc)" | cut -c1-10)" = -rw------- ]
}

@test "user config: a machine with no cmp and no xargs is like any other" {
  # cmp: no image of Fedora, Arch, UBI, Rocky or Alma (minimal) has diffutils. MEASURED at
  # ef4da26: "could not copy ~/.yarnrc.yml next to itself", rc 1, the rest not applied.
  # xargs: Amazon Linux's has no findutils, and no run got anywhere (v2.1.0 too).
  local d="$BATS_TEST_TMPDIR/few" t n
  bare_path
  mkdir "$d"
  for t in "${BARE_PATH#*:}"/*; do
    case "${t##*/}" in cmp|diff|xargs) ;; *) ln -s "$t" "$d/${t##*/}" ;; esac
  done
  run env -i PATH="$d" bash -c 'command -v cmp || command -v xargs'   # FIXTURE CONTROL
  [ "$status" -ne 0 ]
  mkdir -p "$TEST_HOME/.config/pip"
  printf 'npmAuthToken: SECRET\n' > "$(f yarn)"
  printf '[global]\nindex-url = https://u:SECRET@r/\n' > "$(f pip)"
  for n in 1 2; do
    run harden PATH="$TEST_BIN:$d" ECOSYSTEMS=' yarn , pip' -- --emit=plain
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(find "$TEST_HOME" -name '*~' | wc -l | tr -d ' ')" = 2 ] || { find "$TEST_HOME" -name '*~'; false; }
  done
  grep -qx 'ecosystems_hardened=yarn,pip' "$OUT_FILE"
  [ "$(grep -rl SECRET "$TEST_HOME" | wc -l | tr -d ' ')" = 2 ]
}

@test "user config: a run killed before the rename leaves the file as it was; TERM leaves no temporary file" {
  lib
  printf 'a=SECRET\nfund=true\n' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/orig"
  # mode and owner are set just before the rename
  stub chmod 'kill -KILL $PPID'
  ( PATH="$BATS_TEST_TMPDIR/stub:$PATH"; npmrc_body | ucf_npmrc "$(f npmrc)" ) >/dev/null 2>&1 || true
  cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/orig"
  rm -f "$TEST_HOME"/.sch-*
  stub chmod 'kill -TERM $PPID; sleep 1; exit 1'
  ( PATH="$BATS_TEST_TMPDIR/stub:$PATH"; npmrc_body | ucf_npmrc "$(f npmrc)" ) >/dev/null 2>&1 || true
  cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/orig"
  [ -z "$(ls -A "$TEST_HOME" | grep '^\.sch-')" ] || { ls -la "$TEST_HOME"; return 1; }
  # the same for a copy: cut short, it never gets the name of one
  stub cat 'case "$*" in *npmrc) head -c 3 "${@: -1}"; kill -KILL $PPID ;; *) exec /bin/cat "$@" ;; esac'
  rm -f "$BATS_TEST_TMPDIR/stub/chmod" "$TEST_HOME"/.npmrc.*
  ( PATH="$BATS_TEST_TMPDIR/stub:$PATH"; ucf_copy "$(f npmrc)" ) >/dev/null 2>&1 || true
  [ -z "$(copies npmrc)" ]
  cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/orig"
  # FIXTURE CONTROL: with nothing killed, the same call does change it
  rm -f "$BATS_TEST_TMPDIR/stub/cat" "$TEST_HOME"/.sch-*
  npmrc_body | ucf_npmrc "$(f npmrc)" | grep -qx changed
  ! cmp -s "$(f npmrc)" "$BATS_TEST_TMPDIR/orig" || false
  grep -qx 'a=SECRET' "$(f npmrc)"
}

@test "user config: where the rename is impossible (a bind mount) the old bytes stay on disk until the new ones are complete" {
  lib
  printf 'a=SECRET\n' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/orig"
  # rename(2) over a mount point is EBUSY; the copy's own rename still works
  stub mv 'case "${@: -1}" in *.npmrc) exit 1 ;; *) exec /bin/mv "$@" ;; esac'
  ( PATH="$BATS_TEST_TMPDIR/stub:$PATH"; npmrc_body | ucf_npmrc "$(f npmrc)" ) > "$BATS_TEST_TMPDIR/out"
  grep -qx changed "$BATS_TEST_TMPDIR/out"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/orig"
  [ "$(mode "$(f npmrc)")" = -rw------- ]
  [ -z "$(copies npmrc)" ]
  [ -z "$(ls -A "$TEST_HOME" | grep '^\.sch-')" ]
  # killed half way through that write
  cp "$BATS_TEST_TMPDIR/orig" "$(f npmrc)"
  stub cat 'case "$*" in */.sch-*) head -c 5 "${@: -1}"; kill -KILL $PPID ;; *) exec /bin/cat "$@" ;; esac'
  ( PATH="$BATS_TEST_TMPDIR/stub:$PATH"; npmrc_body | ucf_npmrc "$(f npmrc)" ) >/dev/null 2>&1 || true
  ! cmp -s "$(f npmrc)" "$BATS_TEST_TMPDIR/orig" || false          # the control: it was cut short
  cmp "$(copies npmrc)" "$BATS_TEST_TMPDIR/orig"
}

@test "user config: nothing planted at a copy's name is followed, entered or overwritten, an earlier copy included" {
  lib
  local i t what name
  printf 'a=SECRET\n' > "$(f npmrc)"
  for what in file link dangling dir fifo; do
    rm -rf "$TEST_HOME"/.npmrc.* "$BATS_TEST_TMPDIR/victim" "$BATS_TEST_TMPDIR/new"
    echo precious > "$BATS_TEST_TMPDIR/victim"
    t=$(date +%s)
    for i in 0 1 2 3; do
      name="$(f npmrc).$$.$(date -d "@$((t + i))" +%Y-%m-%d@%H:%M:%S 2>/dev/null || date -r "$((t + i))" +%Y-%m-%d@%H:%M:%S)~"
      case "$what" in
        file) echo earlier > "$name" ;;
        link) ln -s "$BATS_TEST_TMPDIR/victim" "$name" ;;
        dangling) ln -s "$BATS_TEST_TMPDIR/new" "$name" ;;
        dir) mkdir "$name" ;;
        fifo) mkfifo "$name" ;;
      esac
    done
    run ucf_copy "$(f npmrc)"
    [ "$status" -eq 0 ] || { echo "$what: $output"; return 1; }
    case "$output" in *-2~) ;; *) echo "$what: $output"; return 1 ;; esac
    cmp "$output" "$(f npmrc)"
    [ "$(mode "$output")" = -rw------- ]
    [ "$(cat "$BATS_TEST_TMPDIR/victim")" = precious ]
    [ ! -e "$BATS_TEST_TMPDIR/new" ]
    if [ "$what" = file ]; then [ "$(cat "$name")" = earlier ]; fi
    if [ "$what" = dir ]; then [ -z "$(ls -A "$name")" ]; fi
  done
}

@test "user config: a write leaves the old file or the new one to anyone reading it, never half of one" {
  # The write is a rename: no other process ever sees the target empty.
  plant
  lib
  local i=0 bad="$BATS_TEST_TMPDIR/bad"
  # bounded, and stopped by teardown too, so a failure here cannot hang the suite
  ( n=0
    while [ ! -e "$BATS_TEST_TMPDIR/stop" ] && [ "$n" -lt 20000 ]; do
      n=$((n + 1))
      grep -q SECRET-npmrc "$(f npmrc)" 2>/dev/null || { echo half >> "$bad"; }
    done ) 3>&- >/dev/null 2>&1 &
  local pid=$!
  while [ "$i" -lt 20 ]; do
    i=$((i + 1))
    { echo "; Managed by supply-chain-harden action"; echo "min-release-age=$i"; } | ucf_npmrc "$(f npmrc)" >/dev/null
  done
  touch "$BATS_TEST_TMPDIR/stop"; wait "$pid" 2>/dev/null || true
  [ ! -e "$bad" ] || { wc -l "$bad"; return 1; }
  [ -z "$(ls -A "$TEST_HOME" | grep '^\.sch-')" ]
}

# -------------------------------------------------------------- the self-check

@test "user config: any change to a file we wrote is noticed; a cutoff the refresher advanced is not one" {
  apply >/dev/null 2>&1
  lib
  local k
  for k in $OTHERS; do
    [ "$(user_cfg_class "$k" "$(f "$k")")" = ours ] || { echo "$k"; cat "$(f "$k")"; return 1; }
    cp "$(f "$k")" "$BATS_TEST_TMPDIR/x"; echo 'x = "SECRET"' >> "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k: a line more"; return 1; }
    : > "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = ours ] || { echo "$k: an empty file has nothing to lose"; return 1; }
  done
  for k in $MARKED; do
    cp "$(f "$k")" "$BATS_TEST_TMPDIR/x"; printf ' ' >> "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k: one space"; return 1; }
    sed '$d' "$(f "$k")" > "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k: a line gone"; return 1; }
    # the marker without its checksum, over a line of the user's
    { sed 's/; self-check [a-z0-9:-]*//' "$(f "$k")"; echo 'x = "SECRET"'; } > "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k: marker cut"; return 1; }
    # no marker
    grep -v 'Managed by' "$(f "$k")" > "$BATS_TEST_TMPDIR/x"; echo 'x = "SECRET"' >> "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k: no marker"; return 1; }
  done
  # templates/age-gate-refresh.sh.j2 rewrites these two lines in place
  sed 's/^exclude-newer = ".*"$/exclude-newer = "2026-12-31T00:00:00Z"/' "$(f uv)" > "$BATS_TEST_TMPDIR/x"
  ! cmp -s "$(f uv)" "$BATS_TEST_TMPDIR/x" || false
  [ "$(user_cfg_class uv "$BATS_TEST_TMPDIR/x")" = ours ]
  sed 's/^uploaded-prior-to = .*$/uploaded-prior-to = 2026-12-31T00:00:00Z/' "$(f pip)" > "$BATS_TEST_TMPDIR/x"
  ! cmp -s "$(f pip)" "$BATS_TEST_TMPDIR/x" || false
  [ "$(user_cfg_class pip "$BATS_TEST_TMPDIR/x")" = ours ]
  # only in the shape the refresher writes, and only those lines
  sed 's/^exclude-newer = ".*"$/exclude-newer = "SECRET"/' "$(f uv)" > "$BATS_TEST_TMPDIR/x"
  [ "$(user_cfg_class uv "$BATS_TEST_TMPDIR/x")" = foreign ]
}

@test "user config: the self-check's refresher lines are the ones templates/age-gate-refresh.sh.j2 rewrites" {
  local t="$ROOT/templates/age-gate-refresh.sh.j2"
  grep -qF "ts='[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9:.]*Z'" "$t"
  grep -qF "local ts='[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9:.]*Z'" "$HARDEN_SH"
  grep -qF '"^exclude-newer = \"$ts\"\$"' "$t"
  grep -qF '"^uploaded-prior-to = $ts\$"' "$t"
  [ "$(grep -c 'advance .*uv.toml\|advance .*pip.conf' "$t")" -eq 4 ]
}

@test "user config: with no sha256 tool the check is a cksum, and still works" {
  lib
  local d="$BATS_TEST_TMPDIR/nosha" t p
  mkdir -p "$d"
  for t in awk bash basename cat chmod cksum cmp cut date dirname env grep head id ls mkdir mktemp mv od readlink rm sed sh tr uname wc; do
    p=$(type -P "$t") && ln -s "$p" "$d/$t"
  done
  printf '# Managed by supply-chain-harden action\nno-build = true\n' | PATH="$d" ucf_replace uv "$TEST_HOME/uv.toml"
  grep -q 'self-check cksum:' "$TEST_HOME/uv.toml"
  [ "$(PATH="$d" user_cfg_class uv "$TEST_HOME/uv.toml")" = ours ]
  # and where there is one, it is still checked the way it was written
  [ "$(user_cfg_class uv "$TEST_HOME/uv.toml")" = ours ]
  echo 'x = 1' >> "$TEST_HOME/uv.toml"
  [ "$(PATH="$d" user_cfg_class uv "$TEST_HOME/uv.toml")" = foreign ]
}

# -------------------------------------------------------------------- preflight

@test "preflight: STOP for each file that is not ours, a note for ~/.npmrc, and it is what the run does" {
  plant
  printf 'fund=true\nbefore=2026-01-01\n' >> "$(f npmrc)"
  chmod 644 "$(f npmrc)"
  local before k
  before=$(snapshot)
  pf > "$BATS_TEST_TMPDIR/pf" || true
  diff <(printf '%s\n' "$before") <(snapshot)          # it changed nothing
  ! grep SECRET "$BATS_TEST_TMPDIR/pf" || false
  for k in $OTHERS; do
    grep -qF "STOP  $(f "$k"): not exactly what this project last wrote" "$BATS_TEST_TMPDIR/pf" || { cat "$BATS_TEST_TMPDIR/pf"; return 1; }
  done
  ! grep -F "STOP  $(f npmrc)" "$BATS_TEST_TMPDIR/pf" || false
  grep -qF "note  $(f npmrc): merged, never replaced" "$BATS_TEST_TMPDIR/pf"
  grep -qF "note  $(f npmrc): except your own setting of fund, which would win over the block" "$BATS_TEST_TMPDIR/pf"
  grep -qF "note  $(f npmrc): kept, but may set or defeat one of the settings in the block: line 3, before" "$BATS_TEST_TMPDIR/pf"
  grep -qF "note  $(f npmrc): other accounts can read it (-rw-r--r--); it becomes 0600." "$BATS_TEST_TMPDIR/pf"
  # The run then says the same.
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  grep -q 'took your own setting of fund out of' "$BATS_TEST_TMPDIR/log"
  grep -q 'line 3, before, which npm uses' "$BATS_TEST_TMPDIR/log"
  grep -q "other accounts could read it (-rw-r--r--); it is 0600 now" "$BATS_TEST_TMPDIR/log"
  # And after it nothing stops.
  pf > "$BATS_TEST_TMPDIR/pf" || true
  ! grep -F "STOP  $TEST_HOME" "$BATS_TEST_TMPDIR/pf" || false
  for k in $OTHERS; do
    grep -qF "$(f "$k"): exactly what this project last wrote, replaced as before" "$BATS_TEST_TMPDIR/pf" || { cat "$BATS_TEST_TMPDIR/pf"; return 1; }
  done
  ! grep 'except your own setting\|it becomes 0600' "$BATS_TEST_TMPDIR/pf" || false
}

@test "preflight: a home with none of them says each will be created" {
  pf > "$BATS_TEST_TMPDIR/pf" || true
  local k
  for k in npmrc $OTHERS; do
    grep -qF "$(f "$k"): not there, will be created" "$BATS_TEST_TMPDIR/pf" || { cat "$BATS_TEST_TMPDIR/pf"; return 1; }
  done
  [ -z "$(find "$TEST_HOME" -type f)" ]
}

@test "preflight: npm's global config is named, and judged; action/harden.sh does not write it" {
  # The lines of --preflight about it, for a path of this test's choosing: the one
  # npm gives is the machine's own.
  lib
  local g="$TEST_HOME/npm/etc/npmrc" me
  me=$(id -un)
  sed -n "/^  f=\$(ucf_path npm-global)\$/,/^  # The files in a home directory/p" "$HARDEN_SH" > "$BATS_TEST_TMPDIR/pf.sh"
  grep -q '_pf_stop' "$BATS_TEST_TMPDIR/pf.sh"
  gpf() {
    ( HOME="$TEST_HOME"; out=""
      ucf_path() { printf '%s\n' "$g"; }
      _pf_line() { echo "      $*"; }; _pf_note() { echo "NOTE  $*"; }; _pf_stop() { echo "STOP  $*"; }
      # shellcheck disable=SC1091
      . "$BATS_TEST_TMPDIR/pf.sh" )
  }
  [ "$(gpf)" = "      $g: npm's global config, not there, will be created" ]
  mkdir -p "$TEST_HOME/npm/etc"
  cp "$ROOT/tests/fixtures/user-config/v2.1.0-role/npmrc" "$g"
  [[ "$(gpf)" == "      $g: npm's global config, exactly what this project last wrote"* ]]
  # a marker is not enough
  printf '//corp.example/:_authToken=SECRET\n' >> "$g"
  [[ "$(gpf)" == "STOP  $g: npm's global config, not exactly "*"accept_etc_overwrite=true"* ]]
  [[ "$(gpf)" != *SECRET* ]]
  # one the user cannot write stops nothing, and is said
  chmod 555 "$TEST_HOME/npm/etc"
  if [ "$(id -u)" != 0 ]; then
    [[ "$(gpf)" == "NOTE  $g: npm's global config. It cannot be replaced: "*"lists it in the run summary." ]] || { gpf; return 1; }
  fi
  chmod 755 "$TEST_HOME/npm/etc"
  # nor one that neither this account nor root alone controls
  g=/tmp/sch-not-there/etc/npmrc
  [[ "$(gpf)" == "NOTE  $g: npm's global config. It "*"root writes only to paths no other account controls. The role leaves it alone"* ]] || { gpf; return 1; }
  g=/etc/ld.so.preload
  [[ "$(gpf)" == "NOTE  $g: npm's global config. It is not what npm names its global config"* ]] || { gpf; return 1; }
  # harden.sh itself never writes one
  ! grep -nE 'put_user_cfg npm-global|ucf_replace npm-global' "$HARDEN_SH" || false
}

# --------------------------------------------------------- the same on both surfaces

@test "user config: the block in files/user-config.sh is harden.sh's, byte for byte" {
  sed -n '/^# >>> user_config$/,/^# <<< user_config$/p' "$ROOT/files/user-config.sh" > "$BATS_TEST_TMPDIR/role"
  sed -n '/^# >>> user_config$/,/^# <<< user_config$/p' "$HARDEN_SH" > "$BATS_TEST_TMPDIR/act"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/role")" -gt 300 ]
  diff "$BATS_TEST_TMPDIR/role" "$BATS_TEST_TMPDIR/act"
  # no second copy of any of it in harden.sh
  [ "$(grep -c '^user_cfg_class() {' "$HARDEN_SH")" -eq 1 ]
}

@test "user config: the script parses on bash 3.2 and BSD terms (no bash 4 construct)" {
  bash -n "$ROOT/files/user-config.sh"
  ! grep -vE '^[[:space:]]*#' "$ROOT/files/user-config.sh" \
    | grep -nE 'declare -A|mapfile|readarray|\$\{[a-z_]+(,,|\^\^)|readlink -f|sed -i|grep -P|stat -c' || false
}

@test "user config: each of them is written through the shared code on both surfaces, and by nothing else" {
  local k
  [ "$(grep -c "put_user_cfg npmrc " "$HARDEN_SH")" -eq 1 ]
  [ "$(cat "$ROOT"/tasks/*.yml | grep -c 'ansible.builtin.script: user-config.sh npmrc$')" -eq 1 ]
  for k in $OTHERS composer-home; do
    grep -q "put_user_cfg $k " "$HARDEN_SH" || { echo "harden.sh: $k"; return 1; }
    cat "$ROOT"/tasks/*.yml | grep -q "ansible.builtin.script: user-config.sh replace $k\$" || { echo "role: $k"; return 1; }
  done
  # root's own yarn file is written by the same code, as root, on both
  grep -q 'PUT_AS_ROOT=1 put_user_cfg yarn "$root_home/.yarnrc.yml"' "$HARDEN_SH"
  [ "$(grep -cE '(script: user-config.sh|bash -s --) replace yarn$' "$ROOT/tasks/yarn.yml")" -eq 2 ]
  # no template or redirect into one of them is left
  ! grep -nE '> "\$HOME/\.(npmrc|yarnrc\.yml|bundle/config|m2|config/(pnpm|pip|composer))|> "\$(cargo|nuget)_home/(config.toml|NuGet)' "$HARDEN_SH" || false
  ! grep -nE 'dest: .*(ansible_(facts\.)?env\.HOME \}\}/\.(npmrc|yarnrc\.yml|bundle/config|m2)|\.config/pip/pip\.conf|pnpm_config_dir|uv_config_dir|bun_bunfig_path|config\.json|NuGet\.Config|cargo_home \}\}/config\.toml)' "$ROOT"/tasks/*.yml || false
}

@test "user config: the role's tasks judge the same files, at the paths they write" {
  # tasks/preflight.yml names every kind, with the tags of its include.
  lib
  local k
  for k in $UCF_KINDS; do
    grep -qE "^      $k: \[" "$ROOT/tasks/preflight.yml" || { echo "$k"; return 1; }
  done
  # and the role's own path expression for each is the one ucf_path gives
  HOME=/h XDG_CONFIG_HOME=/x
  [ "$(ucf_path uv)" = /x/uv/uv.toml ]
  [ "$(ucf_path bun)" = /x/.bunfig.toml ]
  [ "$(ucf_path pnpm-rc)" = /x/pnpm/rc ]
  [ "$(ucf_path pip)" = /h/.config/pip/pip.conf ]      # tasks/pip.yml does not follow XDG_CONFIG_HOME
  unset XDG_CONFIG_HOME
  [ "$(ucf_path uv)" = /h/.config/uv/uv.toml ]
  [ "$(ucf_path bun)" = /h/.bunfig.toml ]
  [ "$(ucf_path npmrc)" = /h/.npmrc ]
  [ "$(ucf_path yarn)" = /h/.yarnrc.yml ]
  [ "$(ucf_path bundler)" = /h/.bundle/config ]
  case "$(uname -s)" in
    Darwin) [ "$(ucf_path pnpm-yaml)" = /h/Library/Preferences/pnpm/config.yaml ] ;;
    *) [ "$(ucf_path pnpm-yaml)" = /h/.config/pnpm/config.yaml ] ;;
  esac
}

@test "user config: no task of the role sets a mode on a directory that may be the user's" {
  # A `state: directory` with a mode changes a directory that is there (MEASURED: a
  # 0750 home became 0755). Only fixed system paths may have one.
  python3 -c 'import yaml' 2>/dev/null || skip "no PyYAML"
  python3 - "$ROOT"/tasks/*.yml <<'PY'
import sys, yaml
bad = []
def walk(tasks, f):
    for t in tasks or []:
        if not isinstance(t, dict): continue
        for k in ('block', 'rescue', 'always'): walk(t.get(k), f)
        m = t.get('ansible.builtin.file') or t.get('file')
        if isinstance(m, dict) and m.get('state') == 'directory' and 'mode' in m:
            paths = t['loop'] if m['path'] == '{{ item }}' else [m['path']]
            for p in paths:
                if '{{' in p or not p.startswith(('/etc/', '/usr/')): bad.append((f, t.get('name'), p))
for f in sys.argv[1:]: walk(yaml.safe_load(open(f)), f)
for b in bad: print(b)
sys.exit(bool(bad))
PY
}
