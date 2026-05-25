#!/usr/bin/env bash
# Switch the active PHP + composer for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/composer.sh <php_version> <composer_minor>
# e.g.:
#   switchers/composer.sh 8.2 2.7
#
# After this returns successfully, the next `composer` invocation runs
# composer-<minor>.phar interpreted by /usr/bin/php<php_version>, and
# `composer --version` reports the expected version. The role's
# detection in tasks/composer.yml then runs against this combination
# on the next site.yml apply.
#
# Side effects:
#   /usr/local/bin/composer       overwritten with the cell's composer phar
#   /usr/local/bin/composer-real  removed if present (cleans previous cell's wrap)
#   /usr/bin/php                  update-alternatives switched to php<v>

set -euo pipefail

PHP_VERSION="${1:?usage: $0 <php_version> <composer_minor>}"
COMPOSER_MINOR="${2:?usage: $0 <php_version> <composer_minor>}"

PHP_BIN="/usr/bin/php${PHP_VERSION}"
COMPOSER_PHAR="/usr/local/bin/composer-${COMPOSER_MINOR}.phar"
COMPOSER_PATH="/usr/local/bin/composer"
COMPOSER_REAL="/usr/local/bin/composer-real"

[[ -x "$PHP_BIN" ]] || { echo "switchers/composer.sh: php $PHP_VERSION not installed at $PHP_BIN" >&2; exit 1; }
[[ -x "$COMPOSER_PHAR" ]] || { echo "switchers/composer.sh: composer $COMPOSER_MINOR not installed at $COMPOSER_PHAR" >&2; exit 1; }

# Switch default php (composer phar shebang is `#!/usr/bin/env php`, so
# whatever update-alternatives points at decides the interpreter).
update-alternatives --set php "$PHP_BIN" >/dev/null

# Un-wrap composer (remove the wrapper + the -real backup left by the
# previous cell, if any). Then drop the cell's phar in place. The role's
# next apply will detect this as is_real and wrap it freshly.
rm -f "$COMPOSER_REAL"
cp -f "$COMPOSER_PHAR" "$COMPOSER_PATH"
chmod 0755 "$COMPOSER_PATH"

# Sanity check — composer --version should report the requested minor.
# A mismatch here usually means the phar download was corrupted or the
# wrong file got mapped; fail loud rather than mis-attribute test results.
reported=$("$COMPOSER_PATH" --version --no-ansi 2>/dev/null \
  | sed -nE 's/^Composer version ([0-9]+\.[0-9]+).*$/\1/p' | head -1)
if [[ "$reported" != "$COMPOSER_MINOR" ]]; then
  echo "switchers/composer.sh: expected composer $COMPOSER_MINOR but got '$reported' from $COMPOSER_PATH" >&2
  exit 1
fi

echo "switchers/composer.sh: php=$PHP_VERSION composer=$reported active"
