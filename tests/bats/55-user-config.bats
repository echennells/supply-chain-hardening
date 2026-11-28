#!/usr/bin/env bats
# The role and what is the user's in the per-user config files it writes (issue 48,
# item 1). ~/.npmrc is merged, and so is npm's global config (/etc/npmrc and the file
# npm names); the others are replaced whole, and the preflight refuses one that is not
# exactly what the role last wrote.
#
# MEASURED at d738db8: an apply dropped a fake token or registry from eight of them,
# with no copy and no message, turned a 0600 ~/.npmrc into 0644, and did it again
# to a token added after hardening. At 860a91c it still did so to Composer's
# config.json, and to a token added after hardening to cargo's, Maven's and NuGet's.
#
# Each test applies the role for a home of its own (HOME is what the role reads;
# for Maven's settings.xml, which goes to the passwd home, -e sch_passwd_home
# stands in for it), with only the tasks that write these files. tests/ci/14-user-config.bats covers
# the same code on the action's side in more detail.

load setup

MARKED="pnpm-yaml pnpm-rc yarn pip uv bun bundler cargo maven nuget"
OTHERS="$MARKED composer"
TAGS=npm,pnpm,yarn,bun,uv,pip,bundler,cargo,maven,nuget,composer

setup() {
  require_root "applies the role, which writes /etc and /usr/local/bin"
  T=$(mktemp -d)
  H="$T/home"
  mkdir -p "$H"
  stub_java_dotnet
  # What the role also writes outside the home, so a test can leave it as it was.
  G=$(cd / && npm config get globalconfig 2>/dev/null) || G=""
  [ "$G" != /etc/npmrc ] || G=""
  SAVED="$G /root/.cargo/cooldown.toml /root/.config/composer/config.json /root/.composer/config.json /etc/npmrc /etc/pip.conf /etc/uv/uv.toml /etc/environment /etc/profile.d/supply-chain-hardening.sh /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/sbin/supply-chain-age-gate-refresh"
  local x
  for x in $SAVED; do
    if [ -e "$x" ]; then mkdir -p "$T/saved$(dirname "$x")"; cp -p "$x" "$T/saved$x"; fi
  done
  # the copies of npm's global config already there, so a test removes only its own
  npm_copies > "$T/copies"
}

npm_copies() { ls -d /etc/npmrc.*~ ${G:+"$G".*~} 2>/dev/null || true; }

teardown() {
  [ -n "${T:-}" ] || return 0
  local x
  for x in $SAVED; do
    if [ -e "$T/saved$x" ]; then cmp -s "$x" "$T/saved$x" || cp -p "$T/saved$x" "$x"; fi
  done
  for x in $(npm_copies); do
    grep -qxF -- "$x" "$T/copies" || rm -f -- "$x"
  done
  for x in /usr/bin/npm /usr/local/bin/npm; do
    if [ -e "$T/away$x" ] || [ -L "$T/away$x" ]; then mv -f "$T/away$x" "$x"; fi
  done
  if [ -f "$T/kc" ]; then
    rm -f /etc/sudoers.d/kcuser
    userdel -r kcuser 2>/dev/null || true
    rm -rf /home/kcuser /opt/kc-prefix /etc/kc-victim.conf /etc/kc-absent /etc/etc
  fi
  rm -rf "$T"
}

f() { # <kind>
  case "$1" in
    npmrc) echo "$H/.npmrc" ;;
    pnpm-yaml) echo "$H/.config/pnpm/config.yaml" ;;
    pnpm-rc) echo "$H/.config/pnpm/rc" ;;
    yarn) echo "$H/.yarnrc.yml" ;;
    pip) echo "$H/.config/pip/pip.conf" ;;
    uv) echo "$H/.config/uv/uv.toml" ;;
    bun) echo "$H/.bunfig.toml" ;;
    bundler) echo "$H/.bundle/config" ;;
    cargo) echo "$H/.cargo/config.toml" ;;
    maven) echo "$H/.m2/settings.xml" ;;
    nuget) echo "$H/.nuget/NuGet/NuGet.Config" ;;
    composer) echo "$H/.config/composer/config.json" ;;
  esac
}

copies() { local b; for b in "$(f "$1")".*~; do [ -e "$b" ] && echo "$b"; done; return 0; }

role() { # [ansible args]: output in $output, the play's status in $status
  cd "$ROLE_DIR"
  # corepack's cache is root's (in a new home it downloads pnpm, 45 s a run), and
  # with no uv on PATH the role installs no uv tools into the home.
  run env -u XDG_CONFIG_HOME HOME="$H" COREPACK_HOME=/root/.cache/node/corepack \
    GRADLE_USER_HOME="$H/.gradle" CARGO_HOME="$H/.cargo" \
    PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" ansible-playbook site.yml --connection=local --limit localhost \
    --tags "${ONLY:-$TAGS}" --skip-tags npq,socket -e sch_passwd_home="$H" \
    -e podman_enabled=false -e verify_protections=false -e socket_firewall_install=false -e age_gate_refresh=false "$@"
}

stub_java_dotnet() { # the maven, gradle and nuget tasks' tool gates
  mkdir -p "$T/bin"
  printf '#!/bin/sh\necho "openjdk version 21" >&2\n' > "$T/bin/java"
  printf '#!/bin/sh\necho 8.0.100\n' > "$T/bin/dotnet"
  chmod +x "$T/bin/java" "$T/bin/dotnet"
}

changed() { echo "$output" | sed -n 's/^localhost .*changed=\([0-9]*\).*/\1/p' | tail -1; }

plant() {
  mkdir -p "$H/.config/pnpm" "$H/.config/uv" "$H/.config/pip" "$H/.bundle"
  printf '# mine\n//registry.example/:_authToken=SECRET-npmrc\nfund=SECRETVALUE\n' > "$(f npmrc)"
  printf 'registry: https://u:SECRET-pnpm-yaml@example/\n' > "$(f pnpm-yaml)"
  printf 'registry=https://u:SECRET-pnpm-rc@example/\n' > "$(f pnpm-rc)"
  printf 'npmAuthToken: "SECRET-yarn"\n' > "$(f yarn)"
  printf '[global]\nindex-url = https://u:SECRET-pip@example/simple\n' > "$(f pip)"
  printf '[[index]]\nurl = "https://u:SECRET-uv@example/simple"\n' > "$(f uv)"
  printf '[install]\nregistry = "https://u:SECRET-bun@example"\n' > "$(f bun)"
  printf -- '---\nBUNDLE_GEMS__EXAMPLE: "u:SECRET-bundler"\n' > "$(f bundler)"
  mkdir -p "$H/.cargo" "$H/.m2" "$H/.nuget/NuGet" "$H/.config/composer"
  printf '[registries.corp]\ntoken = "SECRET-cargo"\n' > "$(f cargo)"
  printf '<settings><servers><server><id>corp</id><password>SECRET-maven</password></server></servers></settings>\n' > "$(f maven)"
  printf '<configuration><packageSourceCredentials><corp><add key="ClearTextPassword" value="SECRET-nuget" /></corp></packageSourceCredentials></configuration>\n' > "$(f nuget)"
  printf '{"config": {"http-basic": {"corp": {"username": "u", "password": "SECRET-composer"}}}}\n' > "$(f composer)"
  local k
  for k in npmrc $OTHERS; do chmod 600 "$(f "$k")"; done
}

snapshot() { ( cd "$H" && find . -path ./.ansible -prune -o -path ./.cache -prune -o -path ./.npm -prune -o -path ./.local -prune -o \( -type f -o -type l \) -printf '%p %m %u %s\n' -exec cksum {} \; | sort ); }

@test "role: refuses the others when they hold something of the user's, before anything is changed, and says which" {
  plant
  local before k
  before=$(snapshot)
  role --diff
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[supply-chain-hardening\] Refusing to overwrite existing per-user config'
  for k in $OTHERS; do echo "$output" | grep -qF "$(f "$k")" || { echo "$k not named"; return 1; }; done
  echo "$output" | grep -q 'accept_user_config_overwrite=true'
  [ "$(changed)" = 0 ]
  diff <(echo "$before") <(snapshot)
  ! echo "$output" | grep SECRET || false
  # --tags for one of them stops on that one only
  ONLY=yarn role
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "$(f yarn)"
  ! echo "$output" | grep -qF "$(f uv)" || false
}

@test "role: --check --diff with the overwrite accepted says what would happen, changes nothing and prints no line of theirs" {
  plant
  local before
  before=$(snapshot)
  role --check --diff -e accept_user_config_overwrite=true
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  diff <(echo "$before") <(snapshot)
  echo "$output" | grep -qF "$(f npmrc): your own setting of fund would be taken out"
  echo "$output" | grep -qF "$(f uv): would be copied next to itself (0600) first"
  ! echo "$output" | grep SECRET || false
}

@test "role: with the overwrite accepted ~/.npmrc is merged, the others are copied 0600 and replaced, nothing is lost or printed, and a second run changes nothing" {
  plant
  role -vvv --diff -e accept_user_config_overwrite=true
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  ! echo "$output" | grep SECRET || false
  local k before
  # ~/.npmrc: the token and the comment stay; fund, which is ours, went, after a copy
  grep -qx '//registry.example/:_authToken=SECRET-npmrc' "$(f npmrc)"
  grep -qx '# mine' "$(f npmrc)"
  ! grep -q SECRETVALUE "$(f npmrc)" || false
  grep -q 'fund=SECRETVALUE' "$(copies npmrc)"
  [ "$(stat -c %a "$(f npmrc)")" = 600 ]
  [ "$(stat -c %a "$(copies npmrc)")" = 600 ]
  head -1 "$(f npmrc)" | grep -q '^; >>> supply-chain-hardening: Managed by ansible-supply-chain-security; self-check sha256:'
  echo "$output" | grep -qF "$(f npmrc): your own setting of fund was taken out"
  for k in $OTHERS; do
    ! grep -q SECRET "$(f "$k")" || false
    [ "$k" = composer ] || grep -q 'Managed by ansible-supply-chain-security; self-check sha256:' "$(f "$k")" || { echo "$k"; return 1; }
    grep -q "SECRET-$k" "$(copies "$k")" || { echo "$k lost"; return 1; }
    [ "$(stat -c %a "$(copies "$k")")" = 600 ]
    [ "$(stat -c %a "$(f "$k")")" = 600 ]              # kept, not loosened to 0644
    echo "$output" | grep -qF "$(copies "$k")"
  done
  before=$(snapshot)
  role
  [ "$status" -eq 0 ]
  [ "$(changed)" = 0 ] || { echo "$output" | grep -A3 '^changed'; return 1; }
  diff <(echo "$before") <(snapshot)
}

@test "role: a token added after hardening stops the play for the others, and stays in ~/.npmrc" {
  role
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  [ "$(stat -c %a "$(f npmrc)")" = 600 ]
  [ "$(stat -c %a "$(f uv)")" = 644 ]
  local k
  for k in npmrc $OTHERS; do printf '# SECRET-%s\n' "$k" >> "$(f "$k")"; done
  local before
  before=$(snapshot)
  role
  [ "$status" -ne 0 ]
  for k in $OTHERS; do echo "$output" | grep -qF "$(f "$k")" || { echo "$k not named"; return 1; }; done
  diff <(echo "$before") <(snapshot)
  ONLY=npm role
  [ "$status" -eq 0 ]
  grep -q SECRET-npmrc "$(f npmrc)"
  [ -z "$(copies npmrc)" ]
}

@test "role: the files v2.0.0 and v2.1.0 wrote, either surface, are upgraded without stopping or copying" {
  local v k d
  for v in v2.0.0-action v2.0.0-role v2.1.0-action v2.1.0-role; do
    rm -rf "$H"; mkdir -p "$H"
    for k in npmrc $OTHERS; do
      mkdir -p "$(dirname "$(f "$k")")"
      d="/opt/test-fixtures/user-config/$v/$k"
      [ -f "$d" ] || d="$ROLE_DIR/tests/fixtures/user-config/$v/$k"
      cp "$d" "$(f "$k")"; chmod 644 "$(f "$k")"
    done
    echo '//registry.example/:_authToken=SECRET-npmrc' >> "$(f npmrc)"
    role
    [ "$status" -eq 0 ] || { echo "$v"; echo "$output" | tail -30; return 1; }
    for k in npmrc $OTHERS; do
      [ -z "$(copies "$k")" ] || { echo "$v $k"; return 1; }
      [ "$k" = composer ] || grep -q 'Managed by ansible-supply-chain-security; self-check ' "$(f "$k")" || { echo "$v $k"; return 1; }
    done
    [ "$(sed '1,/^; <<< supply-chain-hardening$/d' "$(f npmrc)")" = '//registry.example/:_authToken=SECRET-npmrc' ] || { echo "$v"; cat "$(f npmrc)"; return 1; }
  done
}

@test "role: a symlinked ~/.npmrc is written through; one that cannot be written stops the play before anything changes" {
  mkdir -p "$H/dotfiles"
  printf '//registry.example/:_authToken=SECRET-npmrc\n' > "$H/dotfiles/npmrc"
  ln -s dotfiles/npmrc "$(f npmrc)"
  ONLY=npm role
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  [ -L "$(f npmrc)" ]
  grep -q SECRET-npmrc "$H/dotfiles/npmrc"
  grep -q '^ignore-scripts=true' "$H/dotfiles/npmrc"
  [ "$(stat -c %a "$H/dotfiles/npmrc")" = 600 ]
  rm -f "$(f npmrc)"; ln -s /dev/null "$(f npmrc)"
  role
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "$(f npmrc) is not a regular file"
  [ "$(changed)" = 0 ]
  [ -c /dev/null ]
}

@test "role: a cutoff the age-gate refresher advanced is still the role's own file" {
  # The deployed refresher targets the deploying user's files: root's here.
  local uv=/root/.config/uv/uv.toml pip=/root/.config/pip/pip.conf
  [ -x /usr/local/sbin/supply-chain-age-gate-refresh ] || skip "no refresher deployed"
  cp -p "$uv" "$T/uv"; cp -p "$pip" "$T/pip"
  sed -i 's/^exclude-newer = ".*"$/exclude-newer = "2020-01-01T00:00:00Z"/' "$uv"
  sed -i 's/^uploaded-prior-to = .*$/uploaded-prior-to = 2020-01-01T00:00:00Z/' "$pip"
  run /usr/local/sbin/supply-chain-age-gate-refresh --user
  local said="$output" cls
  cls=$(env -u XDG_CONFIG_HOME HOME=/root bash "$ROLE_DIR/files/user-config.sh" classify uv pip)
  local after_uv after_pip
  after_uv=$(grep '^exclude-newer' "$uv"); after_pip=$(grep '^uploaded-prior-to' "$pip")
  echo 'x = 1' >> "$uv"
  local edited
  edited=$(env -u XDG_CONFIG_HOME HOME=/root bash "$ROLE_DIR/files/user-config.sh" classify uv pip || true)
  cp -p "$T/uv" "$uv"; cp -p "$T/pip" "$pip"
  echo "$said"; echo "class: $cls; edited: $edited"
  [[ "$after_uv" != *2020-01-01* ]]
  [[ "$after_pip" != *2020-01-01* ]]
  [ -z "$cls" ]
  [ "$edited" = "foreign $uv" ]
}

@test "role: no directory that is already there changes mode or owner, the home first of all" {
  # MEASURED at d738db8: a 0750 home became 0755 (tasks/bun.yml), and every config
  # directory of the user's with it.
  local d dirs="." x
  for d in .config .config/pnpm .config/pip .config/uv .config/composer .config/pypoetry .composer .bundle \
           .cargo .m2 .nuget .nuget/NuGet .gradle .gradle/init.d; do
    mkdir -p "$H/$d"; dirs="$dirs $d"
  done
  chown -R 12345:12345 "$H"
  for d in $dirs; do chmod 700 "$H/$d"; done
  chmod 750 "$H"
  local before after rootbefore rootafter
  before=$(cd "$H" && stat -c '%a %u:%g %n' $dirs)
  # of root's, the ones that are there now (which depends on the tests before this one)
  local rootdirs=""
  for d in /root /root/.config /root/.cargo /root/.composer /root/.config/composer; do
    [ ! -d "$d" ] || rootdirs="$rootdirs $d"
  done
  rootbefore=$(stat -c '%a %u:%g %n' $rootdirs)
  ONLY=$TAGS,gradle role
  after=$(cd "$H" && stat -c '%a %u:%g %n' $dirs)
  rootafter=$(stat -c '%a %u:%g %n' $rootdirs)
  echo "$output" | tail -4
  [ "$status" -eq 0 ]
  diff <(echo "$before") <(echo "$after")
  diff <(echo "$rootbefore") <(echo "$rootafter")
  # the files did land
  for x in .npmrc .yarnrc.yml .bunfig.toml .bundle/config .cargo/config.toml .m2/settings.xml .nuget/NuGet/NuGet.Config .gradle/init.d/supply-chain-security.gradle .config/uv/uv.toml; do
    [ -f "$H/$x" ] || { echo "$x missing"; return 1; }
  done
}

@test "role: a directory it has to make is 0755 whatever the umask, and nothing in it is writable by others" {
  umask 0000
  ONLY=$TAGS,gradle role
  umask 022
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  local d
  for d in .config/pnpm .config/pip .config/uv .config/composer .config/pypoetry .bundle .cargo .m2 .nuget/NuGet .gradle/init.d; do
    [ "$(stat -c %a "$H/$d")" = 755 ] || { stat -c '%a %n' "$H/$d"; return 1; }
  done
}

@test "role: root's own composer config is left alone and listed when it holds something of root's" {
  # The role here runs as root with a home elsewhere, so /root is another home to it.
  local r=/root/.config/composer/config.json
  mkdir -p "$(dirname "$r")"
  printf '{"config": {"http-basic": {"corp": {"username": "u", "password": "SECRET-root"}}}}\n' > "$r"
  cp "$r" "$T/before"
  ONLY=composer role --diff
  cmp "$r" "$T/before"; local same=$?
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  [ "$same" -eq 0 ]
  echo "$output" | grep -q "Composer sudo coverage — $r is not exactly what this project last wrote, so it was left alone"
  ! echo "$output" | grep SECRET || false
  # and one this project wrote is kept up to date
  rm -f "$r"
  ONLY=composer role
  grep -q '"secure-http": true' "$r"
  ! echo "$output" | grep -q 'Composer sudo coverage' || false
}

@test "role: a home that only has ~/.composer keeps it, and its auth.json is not touched" {
  mkdir -p "$H/.composer"
  printf '{"github-oauth": {"github.com": "SECRET"}}\n' > "$H/.composer/auth.json"
  chmod 600 "$H/.composer/auth.json"
  cp -p "$H/.composer/auth.json" "$T/auth"
  ONLY=composer role
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  ONLY=composer role
  [ "$(changed)" = 0 ] || { echo "$output" | grep -B2 '^changed'; return 1; }
  [ ! -e "$H/.config/composer" ]
  grep -q '"secure-http": true' "$H/.composer/config.json"
  cmp "$H/.composer/auth.json" "$T/auth"
  [ "$(stat -c %a "$H/.composer/auth.json")" = 600 ]
}

# ---- npm's global config: /etc/npmrc, and the file npm names where that is another
#
# Merged like ~/.npmrc. MEASURED at d738db8 (NodeSource's /usr/etc/npmrc): when it was
# replaced, a registry and a token in it were gone after an apply, with no copy, and
# --diff printed them. MEASURED on Azure VMs (2026-11-28): RHEL 9.9's and 10.3's npm
# packages ship /etc/npmrc with prefix=/usr/local, the preflight stopped on it, and
# with accept_etc_overwrite=true the replaced file left npm's prefix at /usr.

# gnpm <global config> <key>: what npm (the real one behind our wrapper) reads for the
# key with that global config and no user config, asked from /
gnpm() {
  local n
  n=$(real_binary npm) || n=$(command -v npm)
  (cd / && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T/nohome" npm_config_userconfig=/dev/null \
     npm_config_globalconfig="$1" npm_config_logs_max=0 npm_config_cache=/dev/null/x "$n" config get "$2" 2>/dev/null | tail -1)
}

# rest <file>: what is below this project's block in it
rest() { sed '1,/^; <<< supply-chain-hardening$/d' "$1"; }

# npm_scripts_row: the verifier's npm script-blocking row, from a home with no npmrc and
# no env layer, so npm's global config is all npm reads
npm_scripts_row() {
  mkdir -p "$T/vhome"
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$T/vhome" /usr/local/bin/supply-chain-verify --json 2>/dev/null \
    | grep '"protection": "npm lifecycle scripts blocked"'
}

@test "role: RHEL's own /etc/npmrc is merged: prefix and python stay, its update-notifier line goes after a copy, npm's prefix is still /usr/local, and a second run changes nothing" {
  local c before rhel=$'prefix=/usr/local\npython=/usr/bin/python3\nupdate-notifier=false'
  # exactly as RHEL 10.3's nodejs-npm 10.9.9 ships it (MEASURED)
  printf '%s\n' "$rhel" > /etc/npmrc; chmod 644 /etc/npmrc; chown root:root /etc/npmrc
  printf '%s\n' "$rhel" > "$T/orig"
  # CONTROL: npm reads this file, and takes its prefix from it, not from where npm is
  [ "$(gnpm /etc/npmrc python)" = /usr/bin/python3 ]
  [ "$(gnpm /dev/null prefix)" != /usr/local ]
  [ "$(gnpm /etc/npmrc prefix)" = /usr/local ]
  # --check: the preflight says it and nothing changes
  ONLY=npm role --check
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  echo "$output" | grep -qF "/etc/npmrc: npm's global config, merged like ~/.npmrc, never replaced: this project's settings go in a block at the top, and it keeps prefix, python. It takes out its own lines for update-notifier, which set what the block sets, after a copy of the file next to it (0600)."
  echo "$output" | grep -qF "/etc/npmrc: its own line for update-notifier would be taken out"
  cmp /etc/npmrc "$T/orig"
  [ "$(npm_copies)" = "$(cat "$T/copies")" ]
  ONLY=npm role --diff
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  head -1 /etc/npmrc | grep -q '^; >>> supply-chain-hardening: Managed by ansible-supply-chain-security; self-check sha256:'
  [ "$(rest /etc/npmrc)" = "$(printf 'prefix=/usr/local\npython=/usr/bin/python3')" ]
  [ "$(grep -c '^update-notifier=' /etc/npmrc)" -eq 1 ]           # the block's own
  [ "$(stat -c '%a %U %G' /etc/npmrc)" = '644 root root' ]
  c=$(ls -d /etc/npmrc.*~ | grep -vxF -f "$T/copies")
  [ "$(echo "$c" | wc -l)" -eq 1 ]
  cmp "$c" "$T/orig"
  [ "$(stat -c '%a %U' "$c")" = '600 root' ]
  echo "$output" | grep -qF "/etc/npmrc: its own line for update-notifier was taken out"
  echo "$output" | grep -qF "/etc/npmrc: the file as it was is at $c."
  [ "$(gnpm /etc/npmrc prefix)" = /usr/local ]
  [ "$(gnpm /etc/npmrc python)" = /usr/bin/python3 ]
  [ "$(gnpm /etc/npmrc ignore-scripts)" = true ]
  before=$(cksum < /etc/npmrc)
  ONLY=npm role
  [ "$status" -eq 0 ]
  [ "$(changed)" = 0 ] || { echo "$output" | grep -B3 '^changed'; return 1; }
  [ "$(cksum < /etc/npmrc)" = "$before" ]
  [ "$(ls -d /etc/npmrc.*~ | grep -vxF -f "$T/copies")" = "$c" ]
  echo "$output" | grep -qF "/etc/npmrc: npm's global config, merged like ~/.npmrc, never replaced: this project's settings go in a block at the top, and it keeps prefix, python. Nothing in it changes."
}

@test "role: a corporate registry and token in npm's global config stay where npm reads them, ignore-scripts=false goes after a copy, the mode is kept, and nothing of theirs is printed" {
  local f m c corp=$'registry=https://corp.example.invalid/\n//corp.example.invalid/:_authToken=SECRET-TOKEN\nignore-scripts=false'
  printf '%s\n' "$corp" > /etc/npmrc; chmod 600 /etc/npmrc
  if [ -n "$G" ]; then mkdir -p "$(dirname "$G")"; printf '%s\n' "$corp" > "$G"; chmod 644 "$G"; fi
  # CONTROL: npm reads the line that turns install scripts back on, and so the verifier,
  # which asks npm, reports it
  [ "$(gnpm /etc/npmrc ignore-scripts)" = false ]
  [[ "$(npm_scripts_row)" == *'"status": "GAP"'* ]] || { npm_scripts_row; return 1; }
  # no accept_etc_overwrite: nothing stops the play
  ONLY=npm role --diff -vvv
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  ! echo "$output" | grep SECRET || false
  ! echo "$output" | grep -q 'Refusing to overwrite' || false
  for f in /etc/npmrc $G; do
    m=644; [ "$f" != /etc/npmrc ] || m=600
    [ "$(rest "$f")" = "$(printf 'registry=https://corp.example.invalid/\n//corp.example.invalid/:_authToken=SECRET-TOKEN')" ] || { echo "$f"; cat "$f"; return 1; }
    [ "$(stat -c '%a %U' "$f")" = "$m root" ]
    c=$(ls -d "$f".*~ | grep -vxF -f "$T/copies")
    [ "$(echo "$c" | wc -l)" -eq 1 ]
    grep -qx 'ignore-scripts=false' "$c"
    grep -qx '//corp.example.invalid/:_authToken=SECRET-TOKEN' "$c"
    [ "$(stat -c '%a %U' "$c")" = '600 root' ]
    echo "$output" | grep -qF "$f: npm's global config, merged like ~/.npmrc, never replaced: this project's settings go in a block at the top, and it keeps registry, //...:_authToken. It takes out its own lines for ignore-scripts"
    echo "$output" | grep -qF "$f: your own setting of ignore-scripts was taken out"
    echo "$output" | grep -qF "$f: the file as it was is at $c."
    [ "$(gnpm "$f" registry)" = https://corp.example.invalid/ ]
    [ "$(gnpm "$f" ignore-scripts)" = true ]
  done
  echo "$output" | grep -qF "/etc/npmrc: other accounts cannot read it (-rw-------), and its mode is kept"
  # the kept registry and token are no reason for a GAP: scripts are blocked
  [[ "$(npm_scripts_row)" == *'"status": "OK"'* ]] || { npm_scripts_row; return 1; }
  # a second run, with accept_etc_overwrite this time: it changes nothing, and copies nothing
  ONLY=npm role -e accept_etc_overwrite=true
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  [ "$(changed)" = 0 ] || { echo "$output" | grep -B3 '^changed'; return 1; }
  for f in /etc/npmrc $G; do [ "$(ls -d "$f".*~ | grep -cvxF -f "$T/copies")" -eq 1 ]; done
}

@test "role: root merges into no /etc/npmrc that is a link, is not root's, or that others can write; each is left as it is and named" {
  local x why before
  printf 'registry=https://corp.example.invalid/\n//corp.example.invalid/:_authToken=SECRET\n' > "$T/theirs"
  chmod 600 "$T/theirs"
  for x in link nobody writable; do
    rm -f /etc/npmrc
    case "$x" in
      link)     ln -s "$T/theirs" /etc/npmrc; why="goes through /etc/npmrc, a symbolic link" ;;
      nobody)   cp "$T/theirs" /etc/npmrc; chown nobody /etc/npmrc; why="is in /etc/npmrc, which is not root's" ;;
      writable) cp "$T/theirs" /etc/npmrc; chmod 666 /etc/npmrc; why="is in /etc/npmrc, which other accounts can write to" ;;
    esac
    before=$(stat -c '%F %U %a' /etc/npmrc; cksum < "$T/theirs"; cksum < /etc/npmrc)
    ONLY=npm role
    [ "$status" -eq 0 ] || { echo "$x"; echo "$output" | tail -30; return 1; }
    echo "$output" | grep -qF "/etc/npmrc: npm's global config. It $why, and root writes only to paths no other account controls. The run leaves it as it is" \
      || { echo "$x: no preflight line"; return 1; }
    echo "$output" | grep -qF "npm's global config — /etc/npmrc $why, and root writes only to paths no other account controls" \
      || { echo "$x: not in the summary"; return 1; }
    ! echo "$output" | grep SECRET || false
    [ "$(stat -c '%F %U %a' /etc/npmrc; cksum < "$T/theirs"; cksum < /etc/npmrc)" = "$before" ] || { echo "$x changed"; return 1; }
    [ "$(npm_copies)" = "$(cat "$T/copies")" ]
  done
  rm -f /etc/npmrc                   # teardown puts the one that was there back
}

# kcuser: an account with sudo, as the role is meant to be run; gone with the test
kcuser() {
  touch "$T/kc"
  userdel -r kcuser 2>/dev/null || true
  rm -rf /home/kcuser
  useradd -m -s /bin/bash kcuser
  echo 'kcuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/kcuser
  chmod 440 /etc/sudoers.d/kcuser
}

askc() { su - kcuser -c "$1"; }

askc_role() { # [ansible args]
  run su - kcuser -c "cd $ROLE_DIR && PATH=/usr/local/bin:/usr/bin:/bin ansible-playbook site.yml \
    --connection=local --limit localhost --tags npm --skip-tags npq,socket -e podman_enabled=false \
    -e verify_protections=false -e socket_firewall_install=false $*"
}

# the npm kcuser has is one of its own, which says its global config is $1
kcnpm() {
  local b
  for b in /usr/bin/npm /usr/local/bin/npm; do
    if [ -e "$b" ] || [ -L "$b" ]; then mkdir -p "$T/away$(dirname "$b")"; mv -f "$b" "$T/away$b"; fi
  done
  askc 'mkdir -p ~/.nvm/versions/node/v99.0.0/bin'
  cat > /home/kcuser/.nvm/versions/node/v99.0.0/bin/npm <<'EOF'
#!/bin/sh
case "$*" in --version) echo 11.19.1 ;; "config get globalconfig") cat /home/kcuser/where ;; esac
EOF
  chmod 755 /home/kcuser/.nvm/versions/node/v99.0.0/bin/npm
  printf '%s\n' "$1" > /home/kcuser/where
}

# what is root's: owner, mode and content
rootside() {
  stat -c '%U:%G %a %n' / /etc /etc/npmrc /etc/passwd /etc/shadow /etc/sudoers /root /usr /usr/etc /opt 2>/dev/null
  cksum < /etc/npmrc; cksum < /etc/passwd; cksum < /etc/shadow
  ls -la /root | awk '{print $1, $3, $4, $NF}'
  ls -A /etc | grep -v '^\.pwd\.lock$\|^cron\|-$' | cksum
  stat -c '%U %a %n' /etc/kc-victim.conf && cksum < /etc/kc-victim.conf
}

@test "role: root writes npm's global config to no path of the user's choosing" {
  kcuser
  printf 'SECRET\n' > /etc/kc-victim.conf; chmod 600 /etc/kc-victim.conf
  askc_role
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  local before trap
  before=$(rootside)
  # in the npm settings of the account: a prefix that is a link to /, one whose etc is a
  # link to /root, a file of root's, one that is not there, and a link to one
  askc 'mkdir -p ~/p; ln -s / ~/x; ln -s /root ~/p/etc; ln -s /etc/kc-victim.conf ~/l'
  for trap in prefix=/home/kcuser/x prefix=/home/kcuser/p globalconfig=/etc/kc-victim.conf \
              globalconfig=/etc/kc-absent globalconfig=/home/kcuser/l globalconfig=/home/kcuser/x/etc/npmrc; do
    askc "printf '%s\n' '$trap' > ~/.npmrc"
    askc_role
    [ "$status" -eq 0 ] || { echo "$trap"; echo "$output" | tail -20; return 1; }
    diff <(echo "$before") <(rootside) || { echo "$trap"; return 1; }
    [ ! -e /etc/kc-absent ] && [ ! -e /etc/etc ] || { echo "$trap"; return 1; }
  done
  # and in its environment
  run su - kcuser -c "cd $ROLE_DIR && NPM_CONFIG_PREFIX=/home/kcuser/x NPM_CONFIG_GLOBALCONFIG=/etc/kc-victim.conf PATH=/usr/local/bin:/usr/bin:/bin \
    ansible-playbook site.yml --connection=local --limit localhost --tags npm --skip-tags npq,socket -e podman_enabled=false \
    -e verify_protections=false -e socket_firewall_install=false"
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  diff <(echo "$before") <(rootside)
  askc 'rm -f ~/.npmrc; [ ! -w /etc ] && [ ! -w /etc/npmrc ]'
}

@test "role: whatever the npm of the user says, root writes only where no other account controls the path, and the summary says what it left" {
  kcuser
  printf 'SECRET\n' > /etc/kc-victim.conf; chmod 600 /etc/kc-victim.conf
  askc_role
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  local before where
  before=$(rootside)
  askc 'mkdir -p ~/p; ln -s / ~/x; ln -s /root ~/p/etc; ln -s /etc/kc-victim.conf ~/l'
  mkdir -p /opt/kc-prefix/etc /opt/kc-prefix/gw/etc /opt/kc-prefix/theirs/etc; chmod 775 /opt/kc-prefix/gw
  chown -R nobody /opt/kc-prefix/theirs
  ln -s /etc /opt/kc-prefix/link
  kcnpm /dev/null
  for where in /home/kcuser/x/etc/npmrc /home/kcuser/p/etc/npmrc /home/kcuser/l /etc/kc-victim.conf /etc/kc-absent \
               /etc/ld.so.preload /opt/kc-prefix/link/npmrc /opt/kc-prefix/gw/etc/npmrc /opt/kc-prefix/theirs/etc/npmrc \
               /opt/kc-prefix/../../etc/npmrc /tmp/kc/etc/npmrc; do
    echo "$where" > /home/kcuser/where
    askc_role
    [ "$status" -eq 0 ] || { echo "$where"; echo "$output" | tail -20; return 1; }
    echo "$output" | grep -q "npm's global config — $where " || { echo "$where"; echo "$output" | tail -20; return 1; }
    ! echo "$output" | grep SECRET || false
    diff <(echo "$before") <(rootside) || { echo "$where"; return 1; }
  done
  for a in "" --check; do
    askc_role $a
    [ "$status" -eq 0 ] || { echo "$a"; echo "$output" | tail -20; return 1; }
    echo "$output" | grep -q "npm's global config — /tmp/kc/etc/npmrc is in /tmp, which other accounts can write to"
    diff <(echo "$before") <(rootside)
  done
  [ ! -e /etc/ld.so.preload ] && [ ! -e /etc/kc-absent ] || return 1
  [ -z "$(find /opt/kc-prefix /tmp/kc -name 'npmrc*' 2>/dev/null)" ]
  # the one it may
  echo /opt/kc-prefix/new/etc/npmrc > /home/kcuser/where
  askc_role
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  [ "$(stat -c '%U %a' /opt/kc-prefix/new/etc/npmrc /opt/kc-prefix/new/etc /opt/kc-prefix/new | tr '\n' ' ')" = 'root 644 root 755 root 755 ' ]
  grep -q '^ignore-scripts=true' /opt/kc-prefix/new/etc/npmrc
  ! echo "$output" | grep -q "npm's global config — " || false
  askc_role
  [ "$(changed)" = 0 ] || { echo "$output" | grep -B2 '^changed'; return 1; }
}

@test "role: a global npmrc in the user's home is written as the user, and one that is root's is left alone and named" {
  kcuser
  local h=/home/kcuser g=/home/kcuser/.nvm/versions/node/v99.0.0/etc/npmrc
  kcnpm "$g"
  chmod 700 "$h/.nvm/versions/node/v99.0.0"
  askc_role
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  [ "$(stat -c '%U %a' "$h/.nvm/versions/node/v99.0.0")" = 'kcuser 700' ]
  [ "$(stat -c %U "$(dirname "$g")")" = kcuser ]
  [ "$(stat -c %U "$g")" = kcuser ]
  grep -q '^ignore-scripts=true' "$g"
  askc_role
  [ "$(changed)" = 0 ] || { echo "$output" | grep -B2 '^changed'; return 1; }
  # as d738db8 left it: root's file, in root's directory
  cp /opt/test-fixtures/user-config/v2.1.0-role/npmrc "$g"
  chown root:root "$(dirname "$g")" "$g"
  cp "$g" "$T/before"
  for a in --check ""; do
    askc_role $a
    [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
    echo "$output" | grep -q "npm's global config — $g belongs to another account (root)"
    echo "$output" | grep -qF "mv -- $(dirname "$g") $(dirname "$g").old"
    [ "$(stat -c %U "$(dirname "$g")" "$g" | tr '\n' ' ')" = 'root root ' ]
    cmp "$g" "$T/before"
  done
  # what it says to do, which needs no root
  askc "mv $(dirname "$g") $(dirname "$g").old"
  askc_role
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  [ "$(stat -c %U "$(dirname "$g")" "$g" | tr '\n' ' ')" = 'kcuser kcuser ' ]
  grep -q 'self-check sha256:' "$g"
  # and the user's own is merged, as the user: the token stays below the block, the file
  # stays the user's and 0600, and with nothing taken out there is no copy
  printf '//corp.example/:_authToken=SECRET\n' > "$g"; chmod 600 "$g"
  askc_role
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  ! echo "$output" | grep SECRET || false
  head -1 "$g" | grep -q '^; >>> supply-chain-hardening: Managed by ansible-supply-chain-security; self-check '
  [ "$(rest "$g")" = '//corp.example/:_authToken=SECRET' ]
  [ "$(stat -c '%U %a' "$g")" = 'kcuser 600' ]
  [ -z "$(ls -d "$g".*~ 2>/dev/null)" ]
  askc_role -e accept_etc_overwrite=true
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  [ "$(changed)" = 0 ] || { echo "$output" | grep -B2 '^changed'; return 1; }
  # a prefix of the user's outside the home
  mkdir -p /opt/kc-prefix/etc; chown -R kcuser:kcuser /opt/kc-prefix
  g=/opt/kc-prefix/etc/npmrc
  echo "$g" > "$h/where"
  askc_role
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  [ "$(stat -c %U "$g" /opt/kc-prefix/etc | tr '\n' ' ')" = 'kcuser kcuser ' ]
}

@test "role: run as root by way of sudo with a user's home, it writes none of these files" {
  # The preflight refuses HOME=/root there; this is the HOME that sudo can keep.
  kcuser
  askc "printf '//registry.example/:_authToken=SECRET\n' > ~/.npmrc; ln -s /etc/kc-absent ~/.yarnrc.yml"
  run su - kcuser -c "cd $ROLE_DIR && sudo env HOME=/home/kcuser SUDO_USER=kcuser PATH=/usr/local/bin:/usr/bin:/bin ansible-playbook site.yml \
    --connection=local --limit localhost --tags npm,yarn --skip-tags npq,socket -e podman_enabled=false -e verify_protections=false"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '/home/kcuser/.npmrc is in /home/kcuser, which is not root'
  ! echo "$output" | grep SECRET || false
  [ "$(stat -c '%U' /home/kcuser/.npmrc)" = kcuser ]
  [ "$(cat /home/kcuser/.npmrc)" = '//registry.example/:_authToken=SECRET' ]
  [ ! -e /etc/kc-absent ]
}
