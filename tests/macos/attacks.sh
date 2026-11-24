#!/bin/bash
# The attacks this project exists to stop, with the real tools on a real machine.
#
#   attacks.sh before   on a machine nothing has hardened: every attack must FIRE.
#                       One that does not proves nothing afterwards (a fixture
#                       control, docs/design-principles.md, Axis 4), so it fails.
#   attacks.sh after    after the Action: every attack must be blocked, and by the
#                       control that is meant to block it. An error of some other
#                       kind is not a block, and fails too.
#
# Prints one line per attack. NOT-TESTED (Maven Central's 429, a registry with
# nothing new enough, a tool that is not here) is neither a pass nor a fail: it is
# a warning on the run, and the line says why. Written for the macOS job
# (.github/workflows/macos.yml); it runs on Linux too. Bash 3.2, no GNU tools.
#
# Every fixture is a throwaway directory. The packages are made here: nothing
# malicious is fetched, and the marker is a file in that directory.
set -u
MODE=${1:-}
case "$MODE" in before|after) ;; *) echo "usage: attacks.sh before|after" >&2; exit 2 ;; esac
HERE=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
W=$(mktemp -d); W=$(cd "$W" && pwd -P); M="$W/marks"; mkdir "$M"
HTTPD=""
trap '[ -z "$HTTPD" ] || kill "$HTTPD" 2>/dev/null; rm -rf "$W"' EXIT
fail=0; untested=""

result() { # <name> <FIRED|blocked|NOT-TESTED|UNCLEAR> <detail>
  printf 'ATTACK %-6s %-26s %-10s %s\n' "$MODE" "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ' | cut -c1-260)"
  case "$MODE:$2" in
    before:FIRED|after:blocked) ;;
    *:NOT-TESTED) untested="$untested $1"; echo "::warning title=NOT TESTED ($MODE)::$1: $3" ;;
    before:*) echo "::error title=The control did not fire::$1 ($2) on an unhardened machine, so a block afterwards proves nothing: $3"; fail=1 ;;
    after:FIRED) echo "::error title=The attack FIRED after hardening::$1: $3"; fail=1 ;;
    after:*) echo "::error title=Not blocked by the control::$1 did not fire, but not for the reason it should: $3"; fail=1 ;;
  esac
  # What the tool said, so that a refusal in words nobody has seen can be added.
  if [ "$2" = UNCLEAR ] && [ -f o ]; then echo "::group::$1: the tool's output"; tail -40 o; echo "::endgroup::"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }
line() { grep -iE -e "$2" "$1" 2>/dev/null | head -1; }
pkg() { mkdir -p "$1"; printf '{"name":"evilpkg","version":"1.0.0","scripts":{"postinstall":"touch %s"}}\n' "$2" > "$1/package.json"; }

# --- npm: a dependency's postinstall ----------------------------------------
npm_postinstall() {
  have npm || { result npm NOT-TESTED "npm is not installed"; return; }
  pkg "$W/e-npm" "$M/npm"; mkdir "$W/a-npm"; cd "$W/a-npm" || return
  echo '{"name":"a","version":"1.0.0"}' > package.json
  bounded 150 npm install ../e-npm > o 2>&1; rc=$?
  if [ -e "$M/npm" ]; then result npm FIRED "npm $(npm --version 2>/dev/null): the dependency's postinstall ran"
  elif [ $rc -eq 0 ] && [ -e node_modules/evilpkg/package.json ]; then result npm blocked "npm $(npm --version 2>/dev/null): installed, its postinstall did not run"
  else result npm UNCLEAR "rc=$rc $(tail -3 o)"; fi
}

# --- pnpm: the project's own postinstall, with and without our environment ---
# The files on their own have to hold it (env -i), or a shell that did not inherit
# the job's environment is open. XDG_CONFIG_HOME is kept: it is where pnpm looks.
pnpm_attack() { # <label> <directory that holds pnpm>
  local p="$2/pnpm" v
  [ -x "$p" ] || { result "pnpm $1" NOT-TESTED "no pnpm at $p"; return; }
  v=$(cd / && "$p" --version 2>/dev/null </dev/null | tail -1)
  local m
  for m in env clean; do
    mkdir "$W/a-pnpm$1$m"; cd "$W/a-pnpm$1$m" || return
    printf '{"name":"p","version":"1.0.0","scripts":{"postinstall":"touch %s/pnpm%s%s"}}\n' "$M" "$1" "$m" > package.json
    if [ $m = clean ]; then
      bounded 150 env -i PATH="$2:$PATH" HOME="$HOME" ${XDG_CONFIG_HOME:+XDG_CONFIG_HOME="$XDG_CONFIG_HOME"} "$p" install > o 2>&1 </dev/null; rc=$?
    else
      bounded 150 env PATH="$2:$PATH" "$p" install > o 2>&1 </dev/null; rc=$?
    fi
    if [ -e "$M/pnpm$1$m" ]; then result "pnpm $1 script ($m)" FIRED "pnpm $v: the project's postinstall ran"
    elif [ $rc -eq 0 ]; then result "pnpm $1 script ($m)" blocked "pnpm $v: rc=0, the postinstall did not run"
    else result "pnpm $1 script ($m)" UNCLEAR "pnpm $v: rc=$rc $(tail -3 o)"; fi
  done
}

# --- pnpm: a release that is hours old ---------------------------------------
pnpm_age() { # <label> <directory that holds pnpm>
  local p="$2/pnpm" n h
  [ -x "$p" ] || { result "pnpm $1 age gate" NOT-TESTED "no pnpm at $p"; return; }
  # TypeScript publishes a nightly; the newest one is the fresh release.
  n=$(cd / && npm view typescript dist-tags.next 2>/dev/null)
  h=$(cd / && npm view typescript time --json 2>/dev/null | python3 -I -c 'import sys,json,datetime
t=json.load(sys.stdin).get(sys.argv[1]); d=datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(t.replace("Z","+00:00")); print(int(d.total_seconds()//3600))' "$n" 2>/dev/null)
  case "$h" in ''|*[!0-9]*) result "pnpm $1 age gate" NOT-TESTED "the registry did not say how old typescript@${n:-next} is"; return ;; esac
  [ "$h" -lt 40 ] || { result "pnpm $1 age gate" NOT-TESTED "the newest typescript nightly is $h hours old, too close to the 48-hour window"; return; }
  mkdir "$W/a-age$1"; cd "$W/a-age$1" || return
  echo '{"name":"p","version":"1.0.0"}' > package.json
  bounded 200 env -i PATH="$2:$PATH" HOME="$HOME" CI=1 ${XDG_CONFIG_HOME:+XDG_CONFIG_HOME="$XDG_CONFIG_HOME"} "$p" add "typescript@$n" > o 2>&1 </dev/null; rc=$?
  if [ $rc -eq 0 ] && [ -e node_modules/typescript/package.json ]; then result "pnpm $1 age gate" FIRED "typescript@$n, $h hours old, installed"
  elif grep -qE 'ERR_PNPM_NO_(MATURE_)?MATCHING_VERSION' o; then result "pnpm $1 age gate" blocked "typescript@$n, $h hours old: $(line o ERR_PNPM_NO_)"
  else result "pnpm $1 age gate" UNCLEAR "rc=$rc $(tail -3 o)"; fi
}

# --- Bun: a trusted dependency's postinstall ---------------------------------
bun_postinstall() {
  have bun || { result bun NOT-TESTED "bun is not installed"; return; }
  pkg "$W/e-bun" "$M/bun"; mkdir "$W/a-bun"; cd "$W/a-bun" || return
  echo '{"name":"a","version":"1.0.0","trustedDependencies":["evilpkg"],"dependencies":{"evilpkg":"file:../e-bun"}}' > package.json
  bounded 150 bun install > o 2>&1; rc=$?
  if [ -e "$M/bun" ]; then result bun FIRED "bun $(bun --version 2>/dev/null): the trusted dependency's postinstall ran"
  elif [ $rc -eq 0 ] && [ -e node_modules/evilpkg/package.json ]; then result bun blocked "bun $(bun --version 2>/dev/null): installed, its postinstall did not run"
  else result bun UNCLEAR "rc=$rc $(tail -3 o)"; fi
}

# --- uv: an sdist's setup.py -------------------------------------------------
uv_sdist() {
  have uv || { result "uv sdist" NOT-TESTED "uv is not installed"; return; }
  mkdir -p "$W/e-uv/evilsd-1.0"; cd "$W/e-uv" || return
  printf 'from setuptools import setup\nopen("%s","w").write("x")\nsetup(name="evilsd",version="1.0")\n' "$M/uv" > evilsd-1.0/setup.py
  printf 'Metadata-Version: 2.1\nName: evilsd\nVersion: 1.0\n' > evilsd-1.0/PKG-INFO
  tar czf evilsd-1.0.tar.gz evilsd-1.0
  bounded 200 uv pip install --target t ./evilsd-1.0.tar.gz > o 2>&1; rc=$?
  if [ -e "$M/uv" ]; then result "uv sdist" FIRED "$(uv --version 2>/dev/null): setup.py ran"
  elif [ $rc -ne 0 ] && said=$(tr '\n' ' ' < o | sed 's/│/ /g' | tr -s ' ' | grep -oE '(Building source distributions? for [^ ]* is disabled|building from source is disabled)'); then result "uv sdist" blocked "$said"
  else result "uv sdist" UNCLEAR "rc=$rc $(tail -3 o)"; fi
}

# --- Composer: a lifecycle script in the root composer.json -------------------
composer_script() {
  have composer || { result "composer script" NOT-TESTED "composer is not installed"; return; }
  mkdir "$W/a-composer"; cd "$W/a-composer" || return
  printf '{"name":"x/y","scripts":{"post-install-cmd":"touch %s","post-autoload-dump":"touch %s"}}\n' "$M/composer" "$M/composer" > composer.json
  bounded 150 composer install --no-interaction > o 2>&1; rc=$?
  if [ -e "$M/composer" ]; then result "composer script" FIRED "the lifecycle script ran"
  elif [ $rc -eq 0 ]; then result "composer script" blocked "rc=0, the lifecycle script did not run"
  else result "composer script" UNCLEAR "rc=$rc $(tail -3 o)"; fi
}

# --- cargo: a manifest that no longer matches its lockfile --------------------
cargo_stale() {
  have cargo || { result "cargo stale lockfile" NOT-TESTED "cargo is not installed"; return; }
  mkdir "$W/a-cargo"; cd "$W/a-cargo" || return
  bounded 150 cargo init -q --name demo . > o0 2>&1
  printf 'itoa = "1"\n' >> Cargo.toml
  bounded 200 cargo generate-lockfile > o1 2>&1
  [ -f Cargo.lock ] || { result "cargo stale lockfile" UNCLEAR "no Cargo.lock to start from: $(tail -2 o1)"; return; }
  printf 'ryu = "1"\n' >> Cargo.toml
  bounded 250 cargo build > o 2>&1; rc=$?
  if grep -q '"ryu"' Cargo.lock; then result "cargo stale lockfile" FIRED "cargo build rewrote Cargo.lock (rc=$rc)"
  elif [ $rc -ne 0 ] && grep -qE '^error: .*--locked was passed' o; then result "cargo stale lockfile" blocked "$(line o '^error: .*--locked was passed')"
  else result "cargo stale lockfile" UNCLEAR "rc=$rc $(tail -3 o)"; fi
}

# --- Bundler: the same -------------------------------------------------------
bundler_stale() {
  have bundle || { result "bundler stale lockfile" NOT-TESTED "bundle is not installed"; return; }
  mkdir "$W/a-bundle"; cd "$W/a-bundle" || return
  printf 'source "https://rubygems.org"\ngem "rake"\n' > Gemfile
  BUNDLE_FROZEN=false bounded 200 bundle lock > o1 2>&1
  [ -f Gemfile.lock ] || { result "bundler stale lockfile" UNCLEAR "no Gemfile.lock to start from: $(tail -2 o1)"; return; }
  printf 'gem "ostruct"\n' >> Gemfile
  BUNDLE_PATH="$W/a-bundle/v" bounded 250 bundle install > o 2>&1; rc=$?
  if grep -qE '^    ostruct \(' Gemfile.lock; then result "bundler stale lockfile" FIRED "bundle install rewrote Gemfile.lock (rc=$rc)"
  elif [ $rc -ne 0 ] && grep -qiE 'frozen|deployment mode' o; then result "bundler stale lockfile" blocked "$(line o 'frozen|deployment mode')"
  else result "bundler stale lockfile" UNCLEAR "rc=$rc $(tail -3 o)"; fi
}

# --- Go: a go.mod that makes go download and run another toolchain ------------
go_toolchain() {
  have go || { result "go toolchain" NOT-TESTED "go is not installed"; return; }
  local here want got
  here=$(cd / && env GOTOOLCHAIN=local go version 2>/dev/null | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  want=$(curl -fsSL --max-time 30 'https://go.dev/VERSION?m=text' 2>/dev/null | head -1)
  case "$want" in go1.*) ;; *) result "go toolchain" NOT-TESTED "go.dev did not say what its newest release is"; return ;; esac
  [ "$here" != "$want" ] || { result "go toolchain" NOT-TESTED "the go here is already $want, the newest there is"; return; }
  mkdir "$W/a-go"; cd "$W/a-go" || return
  printf 'module x\n\ngo 1.21\n\ntoolchain %s\n' "$want" > go.mod
  # Only the settings on disk: go env -w is what has to hold it.
  got=$(bounded 250 env -i PATH="$PATH" HOME="$HOME" go version 2> o)
  case "$got" in
    *"$want "*) result "go toolchain" FIRED "go.mod made $here download and run $want" ;;
    *"$here "*) result "go toolchain" blocked "$got" ;;
    *) result "go toolchain" UNCLEAR "$got $(tail -2 o)" ;;
  esac
}

# --- Gradle: a dynamic version, from a repository on disk --------------------
gradle_dynamic() {
  have gradle || { result "gradle dynamic version" NOT-TESTED "gradle is not installed"; return; }
  local r="$W/a-gradle/repo/com/evil/dep"; mkdir -p "$r/1.0" "$W/a-gradle/p"; cd "$W/a-gradle/p" || return
  printf '<project><modelVersion>4.0.0</modelVersion><groupId>com.evil</groupId><artifactId>dep</artifactId><version>1.0</version></project>\n' > "$r/1.0/dep-1.0.pom"
  python3 -I -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1],"w").writestr("evil.txt","x")' "$r/1.0/dep-1.0.jar"
  printf '<metadata><groupId>com.evil</groupId><artifactId>dep</artifactId><versioning><latest>1.0</latest><release>1.0</release><versions><version>1.0</version></versions></versioning></metadata>\n' > "$r/maven-metadata.xml"
  echo "rootProject.name = 'v'" > settings.gradle
  cat > build.gradle <<G
repositories { maven { url = uri("file://$W/a-gradle/repo") } }
configurations { c }
dependencies { c 'com.evil:dep:1.+' }
tasks.register('r') { doLast { println "RESOLVED " + configurations.c.files*.name } }
G
  bounded 400 gradle --no-daemon --offline -q r > o 2>&1; rc=$?
  if grep -q 'RESOLVED \[dep-1.0.jar\]' o; then result "gradle dynamic version" FIRED "com.evil:dep:1.+ resolved"
  elif [ $rc -ne 0 ] && grep -q 'disallows usage of dynamic versions' o; then result "gradle dynamic version" blocked "$(line o 'disallows usage')"
  elif central_refused o; then result "gradle dynamic version" NOT-TESTED "Maven Central answered 429"
  else result "gradle dynamic version" UNCLEAR "rc=$rc $(grep -vE '^$' o | head -4)"; fi
}

# --- Gradle: a plain-http repository -----------------------------------------
gradle_http() {
  have gradle || { result "gradle http repository" NOT-TESTED "gradle is not installed"; return; }
  mkdir -p "$W/a-gradleh"; cd "$W/a-gradleh" || return
  echo "rootProject.name = 'v'" > settings.gradle
  cat > build.gradle <<'G'
repositories { maven { url = uri("http://127.0.0.1:9/m2"); allowInsecureProtocol = true } }
tasks.register('r') { doLast { println "CONFIGURED " + repositories*.url } }
G
  bounded 400 gradle --no-daemon --offline -q r > o 2>&1; rc=$?
  if grep -q 'CONFIGURED \[http://127.0.0.1:9/m2\]' o; then result "gradle http repository" FIRED "the build took an http:// repository"
  elif [ $rc -ne 0 ] && grep -q 'refusing HTTP repo' o; then result "gradle http repository" blocked "$(line o 'refusing HTTP repo')"
  else result "gradle http repository" UNCLEAR "rc=$rc $(grep -vE '^$' o | head -4)"; fi
}

# --- Maven: a parent POM from a plain-http repository -------------------------
# Maven 3.8.1+ blocks plain http itself, from its installation's settings, so those
# are replaced (-gs) with empty ones in both modes: the user settings the Action
# wrote are then all that stands in the way. Nothing is needed from Maven Central.
# `external:http:*` does not cover localhost, so the server is reached by this
# machine's own address.
maven_http() {
  have mvn || { result "maven http repository" NOT-TESTED "mvn is not installed"; return; }
  local ip port d="$W/a-mvn"
  ip=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
  case "$ip" in ''|127.*) result "maven http repository" NOT-TESTED "this machine has no address but loopback"; return ;; esac
  mkdir -p "$d/m2/com/evil/parent/1.0" "$d/p"; cd "$d/p" || return
  printf '<project><modelVersion>4.0.0</modelVersion><groupId>com.evil</groupId><artifactId>parent</artifactId><version>1.0</version><packaging>pom</packaging></project>\n' > "$d/m2/com/evil/parent/1.0/parent-1.0.pom"
  ( cd "$d" && exec python3 -I -u -c 'import http.server,socketserver,functools
s=socketserver.TCPServer(("0.0.0.0",0),http.server.SimpleHTTPRequestHandler); open("port","w").write(str(s.server_address[1])); s.serve_forever()' ) >> "$d/access" 2>&1 &
  HTTPD=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/port" ] && break; sleep 1; done
  port=$(cat "$d/port" 2>/dev/null)
  if ! curl -fsS --max-time 10 "http://$ip:$port/m2/com/evil/parent/1.0/parent-1.0.pom" >/dev/null 2>&1; then
    result "maven http repository" NOT-TESTED "this machine does not reach its own http server at $ip:$port"; return
  fi
  : > "$d/access"
  echo '<settings/>' > "$d/empty.xml"
  cat > pom.xml <<P
<project><modelVersion>4.0.0</modelVersion>
<parent><groupId>com.evil</groupId><artifactId>parent</artifactId><version>1.0</version><relativePath/></parent>
<artifactId>victim</artifactId><packaging>pom</packaging>
<repositories><repository><id>http-repo</id><url>http://$ip:$port/m2</url></repository></repositories></project>
P
  bounded 400 mvn -B -gs "$d/empty.xml" -Dmaven.repo.local="$d/local" validate > o 2>&1; rc=$?
  if grep -q 'GET /m2/com/evil/parent' "$d/access" && [ $rc -eq 0 ]; then result "maven http repository" FIRED "the parent POM came over http ($(mvn -v 2>/dev/null | head -1))"
  elif grep -q 'Blocked mirror for repositories: \[http-repo' o && grep -q 'central-https-only' o && ! grep -q 'GET /m2/com/evil/parent' "$d/access"; then result "maven http repository" blocked "$(line o 'Blocked mirror')"
  elif central_refused o; then result "maven http repository" NOT-TESTED "Maven Central answered 429"
  else result "maven http repository" UNCLEAR "rc=$rc $(grep -E 'ERROR|WARN' o | head -3)"; fi
}

# --- NuGet: an unsigned package from a feed the project names -----------------
nuget_unsigned() {
  have dotnet || { result "nuget unsigned package" NOT-TESTED "dotnet is not installed"; return; }
  local d="$W/a-nuget"; mkdir -p "$d/feed" "$d/p"; cd "$d/p" || return
  python3 -I - "$d/feed/Evil.1.0.0.nupkg" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("Evil.nuspec", '<?xml version="1.0"?><package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd"><metadata><id>Evil</id><version>1.0.0</version><authors>x</authors><description>x</description></metadata></package>')
z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="nuspec" ContentType="application/octet"/><Default Extension="_" ContentType="application/octet"/></Types>')
z.writestr("_rels/.rels", '<?xml version="1.0" encoding="utf-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Type="http://schemas.microsoft.com/packaging/2010/07/manifest" Target="/Evil.nuspec" Id="R1"/></Relationships>')
z.writestr("lib/netstandard2.0/_._", "")
z.close()
PY
  printf '<configuration><packageSources><add key="evil" value="%s/feed" /></packageSources></configuration>\n' "$d" > nuget.config
  printf '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net$(BundledNETCoreAppTargetFrameworkVersion)</TargetFramework></PropertyGroup><ItemGroup><PackageReference Include="Evil" Version="1.0.0" /></ItemGroup></Project>\n' > v.csproj
  bounded 300 dotnet restore --packages "$d/pk" v.csproj > o 2>&1; rc=$?
  if [ $rc -eq 0 ] && [ -d "$d/pk/evil/1.0.0" ]; then result "nuget unsigned package" FIRED ".NET $(cd / && dotnet --version 2>/dev/null): restored an unsigned package"
  elif [ $rc -ne 0 ] && grep -q 'NU3004' o; then result "nuget unsigned package" blocked "$(line o NU3004)"
  else result "nuget unsigned package" UNCLEAR "rc=$rc $(grep -iE 'error|NU[0-9]{4}' o | head -2)"; fi
}

npm_postinstall
pnpm_attack 10 "${PNPM10:-/nonexistent}"; pnpm_attack 11 "${PNPM11:-/nonexistent}"
pnpm_age 10 "${PNPM10:-/nonexistent}"; pnpm_age 11 "${PNPM11:-/nonexistent}"
bun_postinstall; uv_sdist; composer_script; cargo_stale; bundler_stale
go_toolchain; gradle_dynamic; gradle_http; maven_http; nuget_unsigned
cd / || exit 1
[ -z "$untested" ] || echo "ATTACK $MODE NOT TESTED:$untested"
exit $fail
