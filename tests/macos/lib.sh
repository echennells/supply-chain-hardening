# shellcheck shell=bash
# Shared by attacks.sh and normal-use.sh.

# shellcheck source=../lib/central-429.sh
. "$HERE/../lib/central-429.sh"

# bounded <seconds> <command...>: macOS has no timeout(1).
bounded() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }
