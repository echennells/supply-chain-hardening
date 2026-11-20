#!/bin/bash
# Buildkite — .buildkite/hooks/pre-command
#
# Buildkite has no built-in step-to-step env mechanism, but it does run this
# hook in the same shell as the command, so sourcing here is enough.
#
# Install: save as .buildkite/hooks/pre-command and chmod +x.

set -euo pipefail

"${BUILDKITE_BUILD_CHECKOUT_PATH}/action/harden.sh" --emit=buildkite

# harden.sh runs as a subprocess, so pick up the env layer it wrote. Buildkite
# sets no RUNNER_TEMP, so it is in the agent user's per-user directory unless
# HARDENING_ENV_FILE says otherwise. set -e above means a failed harden.sh never
# reaches this line. Not tested on a real Buildkite agent.
# shellcheck disable=SC1090
source "${HARDENING_ENV_FILE:-${RUNNER_TEMP:-$HOME/.cache/supply-chain-hardening}/supply-chain-hardening.env}"
