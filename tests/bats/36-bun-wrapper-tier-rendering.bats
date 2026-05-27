#!/usr/bin/env bats
# bun-wrapper.sh.j2 authority + subcommand-routing test.
#
# The deployed wrapper at /usr/local/bin/bun (or wherever bun was
# found) is what closes the runtime auto-install gap that ~/.bunfig.toml
# cannot close (per bun's docs: bunfig.toml only loads for `bun run`
# in a local project, not from $HOME). This file renders the wrapper
# template via ansible-playbook and asserts:
#
#   1. --no-install gets injected for runtime paths (bun run / naked
#      file execution / bun test / bun build)
#   2. --no-install is NOT injected for package-management subcommands
#      (install, add, remove, etc.) — those need to consult bunfig as
#      normal for the OTHER hardening (lifecycle scripts, age gate)
#   3. Recursion guard is present
#
# Same pattern as 34-composer-wrapper-tier-rendering.bats.

load setup

WRAPPER_DIR=/tmp/bun-wrapper-renders

setup_file() {
  mkdir -p "$WRAPPER_DIR"
  local playbook
  playbook=$(mktemp --suffix=.yml)
  cat > "$playbook" <<EOF
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - ansible.builtin.template:
        src: $ROLE_DIR/templates/bun-wrapper.sh.j2
        dest: "$WRAPPER_DIR/bun-wrapper.sh"
        mode: "0755"
      vars:
        bun_real_path: /usr/local/bin/bun-real
EOF
  ansible-playbook "$playbook" >/dev/null 2>&1
  rm -f "$playbook"
}

teardown_file() {
  rm -rf "$WRAPPER_DIR"
}

@test "bun-wrapper: deployed at expected path with executable perms" {
  [ -x "$WRAPPER_DIR/bun-wrapper.sh" ]
}

@test "bun-wrapper: package-management subcommands skip --no-install injection" {
  # Each of these passes through to REAL_BUN without the flag. This is
  # the "we don't break bun install" assertion. If any of these
  # subcommands ever drift OUT of the case statement, bun install /
  # bun add would gain --no-install which would either silently
  # do-nothing or error depending on bun's parser — either way wrong.
  for cmd in install i add a remove rm uninstall un update up upgrade link unlink pm outdated why audit publish patch patch-commit init create; do
    grep -qE "[|]${cmd}[|)]" "$WRAPPER_DIR/bun-wrapper.sh" \
      || { echo "FAIL: subcommand '$cmd' not in wrapper's skip list" >&2; return 1; }
  done
}

@test "bun-wrapper: --version / --help / -v / -h skip --no-install injection" {
  # bun --version / -v / --help / -h should not get --no-install
  # injected — these are bare-metadata commands; injection would
  # either be silently ignored or break depending on parser.
  for arg in -- -h --help -v --version --revision; do
    pattern=$(printf '%s' "$arg" | sed 's/[][|.\\*?(){}^$+]/\\&/g')
    grep -qE "[|]${pattern}[|)]" "$WRAPPER_DIR/bun-wrapper.sh" \
      || { echo "FAIL: flag '$arg' not in wrapper's skip list" >&2; return 1; }
  done
}

@test "bun-wrapper: runtime paths receive --no-install via exec line" {
  # The "default" branch of the case statement exec's with --no-install
  # as the first arg before "$@". This is what closes the runtime
  # auto-install gap.
  grep -qE 'exec ".*REAL_BUN.*" --no-install "\$@"' "$WRAPPER_DIR/bun-wrapper.sh"
}

@test "bun-wrapper: recursion guard present" {
  # If REAL_BUN points at the wrapper itself, refuse to recurse.
  # Same pattern as composer/deno/pip wrappers.
  grep -q "refusing to recurse" "$WRAPPER_DIR/bun-wrapper.sh"
}

@test "bun-wrapper: skip-list and inject-default are mutually exclusive (no double-routing)" {
  # The case statement must end with *) → inject --no-install. Without
  # this default branch, any unrecognized arg would silently fall
  # through and the wrapper would exec bun with no protection. The
  # case syntax forces explicit handling; this asserts the catch-all
  # is the inject path, not pass-through.
  grep -qE '^\s*\*\)\s*$' "$WRAPPER_DIR/bun-wrapper.sh"
  # And the inject must be the *next* exec line, not the skip-pass-through one.
  # Grep for the catch-all followed (within a few lines) by the --no-install exec.
  awk '
    /^\s*\*\)/ {in_default=1; next}
    in_default && /exec .* --no-install/ {found=1; exit}
    in_default && /;;/ {exit}
  ' "$WRAPPER_DIR/bun-wrapper.sh" | grep -q "" || true
  # Re-do as a simpler explicit check: the line immediately following
  # the catch-all must contain --no-install.
  match_line=$(grep -nE '^\s*\*\)\s*$' "$WRAPPER_DIR/bun-wrapper.sh" | head -1 | cut -d: -f1)
  [ -n "$match_line" ] || { echo "FAIL: no catch-all branch" >&2; return 1; }
  # Search the next 10 lines for the --no-install exec
  tail -n +"$match_line" "$WRAPPER_DIR/bun-wrapper.sh" | head -10 | grep -q -- "--no-install" \
    || { echo "FAIL: catch-all branch doesn't inject --no-install" >&2; return 1; }
}
