# Bake the hardening into an image.
#
# The most portable option of all: no CI adapter, no env mechanism, no
# per-platform anything. Any CI that can run a container gets the hardening,
# and so does every developer who pulls the image.
#
#   docker build -t hardened-node -f Dockerfile .
#   docker run --rm -v "$PWD:/src" -w /src hardened-node npm ci

FROM node:22-bookworm

COPY action/harden.sh /usr/local/lib/harden.sh
RUN chmod +x /usr/local/lib/harden.sh

# --emit=plain writes the config files, deploys the PATH wrappers, and leaves
# a sourceable env file. WRITE_ETC=true puts the config under /etc too, so it
# applies to every user in the image, not just the build user.
RUN ECOSYSTEMS=npm,pnpm,yarn,pip,uv,bun \
    RELEASE_AGE_HOURS=48 \
    WRITE_ETC=true \
    HARDENING_ENV_FILE=/etc/supply-chain-hardening.env \
    /usr/local/lib/harden.sh --emit=plain

# The config files and wrappers are now baked into the image and need nothing
# further. The env layer is the only part that needs a decision, because
# Docker cannot turn a generated file into ENV instructions.
#
# Option A — source it for every login shell. Keeps a single source of truth,
# but only applies to shells that read profile.d (not `docker run img cmd`).
RUN echo '. /etc/supply-chain-hardening.env' >> /etc/profile.d/00-hardening.sh

# Option B — an entrypoint that sources it before anything, which DOES cover
# `docker run img cmd`. Uncomment to use instead of, or alongside, option A.
# RUN printf '#!/bin/sh\n. /etc/supply-chain-hardening.env\nexec "$@"\n' \
#       > /usr/local/bin/hardened-entrypoint && chmod +x /usr/local/bin/hardened-entrypoint
# ENTRYPOINT ["/usr/local/bin/hardened-entrypoint"]

# Option C — restate the load-bearing values as ENV. Most explicit, and the
# only one visible in `docker inspect`, but it duplicates what the script
# decided and will drift.
# ENV NPM_CONFIG_IGNORE_SCRIPTS=true \
#     NPM_CONFIG_MIN_RELEASE_AGE=2 \
#     PIP_DISABLE_PIP_VERSION_CHECK=1
#
# Note the config-file layer already blocks scripts and gates age on its own,
# so even with none of these the image is hardened — the env layer is the
# redundant second line of defence, exactly as it is in CI.
