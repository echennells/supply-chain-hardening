#!/usr/bin/env bats
# The role and what is the user's in the per-user config files it writes (issue 48,
# item 1). ~/.npmrc is merged; the others are replaced whole, and the preflight
# refuses one that is not exactly what the role last wrote.
#
# MEASURED at d738db8: an apply dropped a fake token or registry from eight of them,
# with no copy and no message, turned a 0600 ~/.npmrc into 0644, and did it again
# to a token added after hardening. At 860a91c it still did so to Composer's
# config.json, and to a token added after hardening to cargo's, Maven's and NuGet's.
#
# Each test applies the role for a home of its own (HOME is what the role reads),
# with only the tasks that write these files. tests/ci/14-user-config.bats covers
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
  G=$(bash "$ROLE_DIR/files/user-config.sh" path npm-global 2>/dev/null || true)
  SAVED="$G /root/.cargo/cooldown.toml /root/.config/composer/config.json /root/.composer/config.json /etc/npmrc /etc/pip.conf /etc/uv/uv.toml /etc/environment /etc/profile.d/supply-chain-hardening.sh /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/sbin/supply-chain-age-gate-refresh"
  local x
  for x in $SAVED; do
    if [ -e "$x" ]; then mkdir -p "$T/saved$(dirname "$x")"; cp -p "$x" "$T/saved$x"; fi
  done
}

teardown() {
  [ -n "${T:-}" ] || return 0
  local x
  for x in $SAVED; do
    if [ -e "$T/saved$x" ]; then cmp -s "$x" "$T/saved$x" || cp -p "$T/saved$x" "$x"; fi
  done
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
    GRADLE_USER_HOME="$H/.gradle" CARGO_HOME="$H/.cargo" ${ROLE_ENV:+"$ROLE_ENV"} \
    PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" ansible-playbook site.yml --connection=local --limit localhost \
    --tags "${ONLY:-$TAGS}" --skip-tags npq,socket \
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
  ! echo "$output" | grep SECRET
  # --tags for one of them stops on that one only
  ONLY=yarn role
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "$(f yarn)"
  ! echo "$output" | grep -qF "$(f uv)"
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
  ! echo "$output" | grep SECRET
}

@test "role: with the overwrite accepted ~/.npmrc is merged, the others are copied 0600 and replaced, nothing is lost or printed, and a second run changes nothing" {
  plant
  role -vvv --diff -e accept_user_config_overwrite=true
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  ! echo "$output" | grep SECRET
  local k before
  # ~/.npmrc: the token and the comment stay; fund, which is ours, went, after a copy
  grep -qx '//registry.example/:_authToken=SECRET-npmrc' "$(f npmrc)"
  grep -qx '# mine' "$(f npmrc)"
  ! grep -q SECRETVALUE "$(f npmrc)"
  grep -q 'fund=SECRETVALUE' "$(copies npmrc)"
  [ "$(stat -c %a "$(f npmrc)")" = 600 ]
  [ "$(stat -c %a "$(copies npmrc)")" = 600 ]
  head -1 "$(f npmrc)" | grep -q '^; >>> supply-chain-hardening: Managed by ansible-supply-chain-security; self-check sha256:'
  echo "$output" | grep -qF "$(f npmrc): your own setting of fund was taken out"
  for k in $OTHERS; do
    ! grep -q SECRET "$(f "$k")"
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
  [[ "$after_uv" != *2020-01-01* ]] && [[ "$after_pip" != *2020-01-01* ]]
  [ -z "$cls" ]
  [ "$edited" = "foreign $uv" ]
}

@test "role: no directory that is already there changes mode or owner, the home first of all" {
  # MEASURED at d738db8: a 0750 home became 0755 (tasks/bun.yml), and every config
  # directory of the user's with it. At 860a91c a global npmrc named in the home
  # (NPM_CONFIG_GLOBALCONFIG) also made the home root's.
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
  rootbefore=$(stat -c '%a %u:%g %n' /root /root/.config /root/.cargo /root/.composer /root/.config/composer 2>/dev/null)
  ROLE_ENV="NPM_CONFIG_GLOBALCONFIG=$H/globalrc" ONLY=$TAGS,gradle role
  after=$(cd "$H" && stat -c '%a %u:%g %n' $dirs)
  rootafter=$(stat -c '%a %u:%g %n' /root /root/.config /root/.cargo /root/.composer /root/.config/composer 2>/dev/null)
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
  ! echo "$output" | grep SECRET
  # and one this project wrote is kept up to date
  rm -f "$r"
  ONLY=composer role
  grep -q '"secure-http": true' "$r"
  ! echo "$output" | grep -q 'Composer sudo coverage'
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

# ---- npm's global config (where it is not /etc/npmrc)
#
# MEASURED at d738db8 (NodeSource's /usr/etc/npmrc): a registry and a token in it
# were gone after an apply, with no copy, and --diff printed them. In a home it and
# its directory became root's.

@test "role: npm's global config is refused when it holds something we did not write, and copied when that is accepted" {
  [ -n "$G" ] || skip "npm's global config here is /etc/npmrc"
  # what v2.1.0 wrote there is ours
  cp "/opt/test-fixtures/user-config/v2.1.0-role/npmrc" "$G"; chmod 644 "$G"
  ONLY=npm role
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  grep -q 'Managed by ansible-supply-chain-security; self-check sha256:' "$G"
  [ "$(stat -c '%a %U' "$G")" = '644 root' ]
  ONLY=npm role
  [ "$(changed)" = 0 ]
  # a token added since, in a file that carries the marker
  printf '//corp.example/:_authToken=SECRET\n' >> "$G"
  cp "$G" "$T/before"
  ONLY=npm role --diff
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Refusing to overwrite npm's global config"
  echo "$output" | grep -qF "$G"
  echo "$output" | grep -q 'accept_etc_overwrite=true'
  [ "$(changed)" = 0 ]
  cmp "$G" "$T/before"
  ! echo "$output" | grep SECRET
  # not a reason to stop a run that does not write it
  ONLY=bundler role
  [ "$status" -eq 0 ]
  # a corporate one with no marker, 0600
  printf 'registry=https://corp.example/\n//corp.example/:_authToken=SECRET\n' > "$G"; chmod 600 "$G"
  cp "$G" "$T/before"
  ONLY=npm role
  [ "$status" -ne 0 ]
  cmp "$G" "$T/before"
  ONLY=npm role --diff -vvv -e accept_etc_overwrite=true
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  ! echo "$output" | grep SECRET
  local c
  c=$(ls "$G".*~)
  cmp "$c" "$T/before"
  [ "$(stat -c %a "$c")" = 600 ]
  [ "$(stat -c %a "$G")" = 644 ]                      # every account reads it
  echo "$output" | grep -qF "$G: the file as it was is at $c"
  rm -f "$c"
}

@test "role: a global npmrc in the user's home stays the user's, and one an earlier version made root's is given back" {
  # As a user of its own, with sudo: as root there is nothing to take or give back.
  id kcuser >/dev/null 2>&1 || useradd -m -s /bin/bash kcuser
  echo 'kcuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/kcuser
  local h=/home/kcuser g=/home/kcuser/npm/etc/npmrc
  rm -rf "$h/npm" "$h/.npmrc"; mkdir -p "$h/npm"; chown -R kcuser:kcuser "$h/npm"; chmod 700 "$h/npm"
  asuser() {
    run su - kcuser -c "cd $ROLE_DIR && NPM_CONFIG_GLOBALCONFIG=$g PATH=/usr/local/bin:/usr/bin:/bin ansible-playbook site.yml \
      --connection=local --limit localhost --tags npm --skip-tags npq,socket -e podman_enabled=false -e verify_protections=false \
      -e socket_firewall_install=false $*"
  }
  asuser
  echo "$output" | tail -3
  [ "$status" -eq 0 ]
  [ "$(stat -c '%U %a' "$h/npm")" = 'kcuser 700' ]
  [ "$(stat -c %U "$h/npm/etc")" = kcuser ] && [ "$(stat -c %U "$g")" = kcuser ]
  grep -q '^ignore-scripts=true' "$g"
  # as d738db8 left it: root's file, in root's directory
  cp /opt/test-fixtures/user-config/v2.1.0-role/npmrc "$g"
  chown root:root "$h/npm/etc" "$g"
  asuser --check
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  [ "$(stat -c %U "$g")" = root ]
  asuser
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  [ "$(stat -c %U "$h/npm/etc")" = kcuser ] && [ "$(stat -c %U "$g")" = kcuser ]
  grep -q 'self-check sha256:' "$g"
  asuser
  [ "$(changed)" = 0 ] || { echo "$output" | grep -B2 '^changed'; return 1; }
  # and the user's own is refused, then kept as a copy
  printf '//corp.example/:_authToken=SECRET\n' > "$g"; chmod 600 "$g"
  asuser
  [ "$status" -ne 0 ]
  grep -q SECRET "$g"
  asuser -e accept_etc_overwrite=true
  [ "$status" -eq 0 ] || { echo "$output" | tail -20; return 1; }
  grep -q SECRET "$g".*~
  [ "$(stat -c '%U %a' "$g".*~)" = 'kcuser 600' ]
  rm -f /etc/sudoers.d/kcuser; userdel -r kcuser 2>/dev/null || true
}
