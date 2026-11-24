#!/bin/bash
# usage: mac.sh <label>   attacks and normal use with the real tools. Never fails; prints PROBE lines.
set +e
L=$1; W=$(mktemp -d); cd "$W"; M="$W/marks"; mkdir "$M"
say() { echo "PROBE $L | $*"; }
fired() { if [ -e "$M/$1" ]; then echo FIRED; else echo blocked; fi; }
T() { perl -e 'alarm shift; exec @ARGV' 150 "$@"; }
mkpkg() { mkdir -p "$1"; printf '{"name":"evilpkg","version":"1.0.0","scripts":{"postinstall":"touch %s"}}\n' "$2" > "$1/package.json"; }
# --- attacks
mkpkg e1 "$M/npm"; mkdir a1; (cd a1; echo '{"name":"a","version":"1.0.0"}' > package.json; T npm install ../e1 >o 2>&1; echo $? > rc); say "attack npm postinstall: $(fired npm) rc=$(cat a1/rc)"
mkpkg e2 "$M/bun"; mkdir a2; (cd a2; echo '{"name":"a","version":"1.0.0","trustedDependencies":["evilpkg"],"dependencies":{"evilpkg":"file:../e2"}}' > package.json; T bun install >o 2>&1; echo $? > rc); say "attack bun postinstall (trusted): $(fired bun) rc=$(cat a2/rc) $(tail -1 a2/o | cut -c1-80)"
mkdir -p e3/evilsd-1.0; printf 'from setuptools import setup\nopen("%s","w").write("x")\nsetup(name="evilsd",version="1.0")\n' "$M/uv" > e3/evilsd-1.0/setup.py; printf 'Metadata-Version: 2.1\nName: evilsd\nVersion: 1.0\n' > e3/evilsd-1.0/PKG-INFO; (cd e3 && tar czf ../evilsd-1.0.tar.gz evilsd-1.0); T uv pip install --target t3 ./evilsd-1.0.tar.gz >o3 2>&1; rc=$?; say "attack uv sdist setup.py: $(fired uv) rc=$rc $(grep -iE 'no-build|error' o3 | head -1 | cut -c1-120)"
python3 -m venv pv >/dev/null 2>&1; T pv/bin/python -m pip install --target t3b ./evilsd-1.0.tar.gz >o3b 2>&1; rc=$?; mv "$M/uv" "$M/pip-seen" 2>/dev/null; say "pip sdist by path (known limitation): $([ -e "$M/pip-seen" ] && echo FIRED || echo blocked) rc=$rc"
mkdir a4; (cd a4; printf '{"name":"x/y","scripts":{"post-install-cmd":"touch %s","post-autoload-dump":"touch %s"}}\n' "$M/composer" "$M/composer" > composer.json; T composer install --no-interaction >o 2>&1; echo $? > rc); say "attack composer lifecycle script: $(fired composer) rc=$(cat a4/rc) $(grep -vE '^$' a4/o | tail -3 | tr '\n' ' ' | cut -c1-200)"
mkdir a5; (cd a5; T cargo init -q --name demo . ; printf 'itoa = "1"\n' >> Cargo.toml; T cargo generate-lockfile >/dev/null 2>&1; sed -i.bak 's/itoa = "1"/itoa = "1"\nryu = "1"/' Cargo.toml; T cargo build >o 2>&1; echo $? > rc); say "cargo build with a stale lockfile: rc=$(cat a5/rc) (hardened: non-zero) $(grep -E 'locked|error' a5/o | head -1 | cut -c1-100)"
mkdir a6; (cd a6; printf 'source "https://rubygems.org"\ngem "rake"\n' > Gemfile; BUNDLE_FROZEN=false T bundle lock >ol 2>&1; printf 'gem "ostruct"\n' >> Gemfile; BUNDLE_PATH=v T bundle install >o 2>&1; echo $? > rc); say "bundle install with a stale lockfile: rc=$(cat a6/rc) (hardened: non-zero) $(grep -iE 'frozen|error' a6/o | head -1 | cut -c1-100)"
# --- age gate, asked of npm itself
say "npm: $(npm --version) ignore-scripts=$(cd /; npm config get ignore-scripts 2>/dev/null) min-release-age=$(cd /; npm config get min-release-age 2>/dev/null) | node $(node --version)"
# --- normal use
n() { local l=$1; shift; mkdir -p "n-$l"; (cd "n-$l"; "$@" >o 2>&1; echo $? > rc); local r; r=$(cat "n-$l/rc"); say "normal $l: rc=$r$([ "$r" = 0 ] || echo " :: $(grep -iE 'error|EACCES|denied|not found|refus' "n-$l/o" | head -2 | tr '\n' ' ' | cut -c1-230)")"; }
n npm bash -c 'npm init -y >/dev/null && npm install is-number@7.0.0'
n npx bash -c 'npx --yes cowsay@1.6.0 hi'
n pnpm bash -c 'echo "{\"name\":\"x\"}" > package.json; pnpm add is-number@7.0.0'
n yarn bash -c 'echo "{\"name\":\"x\"}" > package.json; yarn add is-number@7.0.0'
n bun bash -c 'echo "{\"name\":\"x\"}" > package.json; bun add is-number@7.0.0'
n deno bash -c 'echo "console.log(1)" > a.ts; deno run a.ts && deno run -A npm:cowsay@1.6.0 hi'
n uv bash -c 'uv venv -q v && uv pip install -q --python v/bin/python six==1.16.0'
n pip bash -c 'python3 -m venv v && v/bin/python -m pip install -q six==1.16.0'
n pipcmd bash -c 'pip3 install -q --target t six==1.16.0'
n composer bash -c 'composer require --no-interaction psr/log:3.0.0'
n cargo bash -c 'cargo init -q --name d . && cargo add itoa@1.0.11 && cargo generate-lockfile; cargo build'
n bundle bash -c 'printf "source \"https://rubygems.org\"\ngem \"rake\"\n" > Gemfile; BUNDLE_FROZEN=false bundle lock && BUNDLE_PATH=v bundle install'
n gem bash -c 'gem install --user-install --no-document rake -v 13.2.1'
n go bash -c 'go mod init x && go get rsc.io/quote@v1.5.2'
n dotnet bash -c 'dotnet new console --no-restore >/dev/null && dotnet restore'
n mvn bash -c 'mvn -v'
n gradle bash -c 'gradle --version'
