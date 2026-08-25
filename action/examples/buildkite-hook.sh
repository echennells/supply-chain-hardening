#!/bin/bash
# Buildkite — .buildkite/hooks/pre-command
#
# Buildkite has no built-in step-to-step env mechanism, but it does run this
# hook in the same shell as the command, so sourcing here is enough.
#
# Install: save as .buildkite/hooks/pre-command and chmod +x.

set -euo pipefail

"${BUILDKITE_BUILD_CHECKOUT_PATH}/action/harden.sh" --emit=buildkite

# harden.sh runs as a subprocess, so pick up the env layer it wrote.
# shellcheck disable=SC1090
source "${TMPDIR:-/tmp}/supply-chain-hardening.env"
