#!/bin/bash
# Ordinary use of every tool, before and after hardening.
#
#   normal-use.sh before <file>   records what works on the unhardened machine
#   normal-use.sh after  <file>   fails if something that worked no longer does
#
# A tool that did not work before says nothing about the hardening, and is left
# out with a line that says so. Releases old enough for any age gate.
set -u
MODE=${1:-} REC=${2:-}
case "$MODE" in before|after) ;; *) echo "usage: normal-use.sh before|after <record>" >&2; exit 2 ;; esac
HERE=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
[ "$MODE" = after ] || : > "$REC"

use() { # <label> <tool> <script>
  local rc was
  if ! command -v "$2" >/dev/null 2>&1; then echo "NORMAL $MODE $1: not installed"; return; fi
  mkdir -p "$W/$1"
  ( cd "$W/$1" && bounded 250 bash -c "$3" ) > "$W/$1.o" 2>&1; rc=$?
  if [ "$MODE" = before ]; then
    echo "$1 $rc" >> "$REC"
    echo "NORMAL before $1: rc=$rc$([ $rc -eq 0 ] || tail -2 "$W/$1.o" | tr '\n' ' ' | cut -c1-200)"
    return
  fi
  was=$(awk -v n="$1" '$1 == n { print $2 }' "$REC")
  if [ $rc -eq 0 ]; then echo "NORMAL after  $1: rc=0"
  elif [ "${was:-1}" != 0 ]; then echo "NORMAL after  $1: rc=$rc, and it did not work before either (rc=${was:-unknown})"
  elif central_refused "$W/$1.o"; then echo "::warning title=NOT TESTED::normal use of $1: Maven Central answered 429"
  else
    echo "::error title=Hardening broke ordinary use::$1: rc=$rc $(grep -iE 'error|EACCES|denied|not found|refus' "$W/$1.o" | head -2 | tr '\n' ' ' | cut -c1-260)"
    fail=1
  fi
}

use npm npm 'npm init -y >/dev/null && npm install is-number@7.0.0'
use npx npx 'npx --yes cowsay@1.6.0 hi'
for v in 10 11; do
  d=$(eval "printf '%s' \"\${PNPM$v:-}\"")
  [ -z "$d" ] || use "pnpm$v" "$d/pnpm" "export PATH='$d':\"\$PATH\"; echo '{\"name\":\"x\"}' > package.json; pnpm add is-number@7.0.0"
done
use yarn yarn 'echo "{\"name\":\"x\"}" > package.json; yarn add is-number@7.0.0'
use bun bun 'echo "{\"name\":\"x\"}" > package.json; bun add is-number@7.0.0'
use deno deno 'echo "console.log(1)" > a.ts; deno run a.ts && deno run -A npm:cowsay@1.6.0 hi'
use uv uv 'uv venv -q v && uv pip install -q --python v/bin/python six==1.16.0'
use pip python3 'python3 -m venv v && v/bin/python -m pip install -q six==1.16.0'
use pip3 pip3 'pip3 install -q --target t six==1.16.0'
use composer composer 'composer require --no-interaction psr/log:3.0.0'
use cargo cargo 'cargo init -q --name d . && cargo add itoa@1.0.11 && cargo generate-lockfile && cargo build'
use bundle bundle 'printf "source \"https://rubygems.org\"\ngem \"rake\"\n" > Gemfile; BUNDLE_FROZEN=false bundle lock && BUNDLE_PATH=v bundle install'
use gem gem 'gem install --user-install --no-document rake -v 13.2.1'
use go go 'go mod init x && go get rsc.io/quote@v1.5.2'
use dotnet dotnet 'dotnet new console --no-restore >/dev/null && dotnet restore'
use mvn mvn 'mvn -v'
use gradle gradle 'gradle --version'
exit $fail
