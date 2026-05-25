#!/usr/bin/env bash
# Switch active Ruby + bundler for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/bundler.sh <ruby_label> <bundler_version>
# e.g.:
#   switchers/bundler.sh system bundled
#   switchers/bundler.sh system 2.5.23
#
# Like pip.sh, the ruby axis is fixed at "system" — each distro's
# default ruby varies naturally (Ubuntu 22.04 ships ruby 3.0, Ubuntu
# 24.04 ships 3.2, Debian 12 ships 3.1), so the cross-distro axis IS
# the ruby version axis. Installing alternate rubies per cell would
# need rbenv/ruby-build which is significant additional install
# infrastructure — not justified for v1.
#
# bundler_version "bundled" uses whatever ships with the system ruby
# (apt's ruby-bundler package, or rubygems' default). Other values
# install via `gem install bundler -v X`.

set -euo pipefail

RUBY_LABEL="${1:?usage: $0 <ruby_label> <bundler_version>}"
BUNDLER_VERSION="${2:?usage: $0 <ruby_label> <bundler_version>}"

[[ "$RUBY_LABEL" = "system" ]] || {
  echo "switchers/bundler.sh: only 'system' ruby is supported in v1 (got '$RUBY_LABEL')" >&2
  exit 1
}

command -v ruby >/dev/null 2>&1 || {
  echo "switchers/bundler.sh: ruby not installed (install-versions.yml should have apt-installed it)" >&2
  exit 1
}
command -v bundle >/dev/null 2>&1 || {
  echo "switchers/bundler.sh: bundle not installed (install-versions.yml should have apt-installed ruby-bundler)" >&2
  exit 1
}

if [[ "$BUNDLER_VERSION" != "bundled" ]]; then
  gem install --quiet --no-document bundler -v "$BUNDLER_VERSION" 2>/dev/null || {
    echo "switchers/bundler.sh: failed to install bundler $BUNDLER_VERSION" >&2
    exit 1
  }
fi

reported=$(bundle --version 2>/dev/null | sed -nE 's/^Bundler version ([0-9.]+).*$/\1/p')
if [[ "$BUNDLER_VERSION" != "bundled" ]] && [[ ! "$reported" =~ ^${BUNDLER_VERSION//./\\.} ]]; then
  echo "switchers/bundler.sh: expected bundler $BUNDLER_VERSION, got '$reported'" >&2
  exit 1
fi

echo "switchers/bundler.sh: ruby=$(ruby --version | awk '{print $1, $2}') bundler=$reported active"
