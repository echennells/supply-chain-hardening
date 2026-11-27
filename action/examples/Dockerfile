# Bake the hardening into an image.
#
# The most portable option of all: no CI adapter, no env mechanism, no
# per-platform anything. Any CI that can run a container gets the hardening,
# and so does every developer who pulls the image.
#
#   docker build -t hardened-node -f action/examples/Dockerfile .    # from the repo root
#   docker run --rm -v "$PWD:/src" -w /src hardened-node npm ci
#
# Read docs/container-images.md first: harden after the toolchains are in, as the
# user the image runs as, and rebuild at least every 7 days. CI builds this file
# as it is and runs the verifier in the result (tests/ci/agent-shell/run.sh,
# cell image-recipe).

FROM node:22-bookworm

# Install every toolchain the image needs above this line: the hardening covers
# the tools it finds, and an install after it can replace a wrapped binary.

# harden.sh, and the verifier with its probes. verify.sh reads
# ../files/verify-probes.sh, so the action/ and files/ layout is kept.
COPY action/harden.sh action/verify.sh /usr/local/lib/supply-chain-hardening/action/
COPY files/verify-probes.sh /usr/local/lib/supply-chain-hardening/files/
RUN chmod 0755 /usr/local/lib/supply-chain-hardening/action/harden.sh \
               /usr/local/lib/supply-chain-hardening/action/verify.sh \
 && chmod 0644 /usr/local/lib/supply-chain-hardening/files/verify-probes.sh

# Where harden.sh writes the env file and its run record, and where verify.sh
# reads them; as ENV, so a verify.sh run in the image finds them too. The record
# tells the verifier what was asked for. Its default is under the build user's
# ~/.cache, a 0700 directory; here both are root's, and harden.sh writes them
# 0644, so any user the image runs as can read them.
ENV HARDENING_ENV_FILE=/etc/supply-chain-hardening.env \
    HARDENING_OUTPUT_FILE=/etc/supply-chain-hardening.outputs

# --emit=plain writes the config files, deploys the PATH wrappers, and leaves
# a sourceable env file. WRITE_ETC=true puts the config under /etc too, so it
# applies to every user in the image, not just the build user.
RUN ECOSYSTEMS=npm,pnpm,yarn,pip,uv,bun \
    RELEASE_AGE_HOURS=48 \
    WRITE_ETC=true \
    /usr/local/lib/supply-chain-hardening/action/harden.sh --emit=plain

# The config files and wrappers are now baked into the image and need nothing
# further. The env layer is the only part that needs a decision, because
# Docker cannot turn a generated file into ENV instructions.
#
# Option A — source it for every login shell. Keeps a single source of truth,
# but only applies to shells that read profile.d (not `docker run img cmd`).
RUN echo '. /etc/supply-chain-hardening.env' >> /etc/profile.d/00-hardening.sh

# Option B — an entrypoint that sources it before anything, which DOES cover
# `docker run img cmd`. On, alongside option A. A command started with another
# entrypoint (`docker run --entrypoint ...`) goes without it. Docker resets an
# inherited CMD when ENTRYPOINT is set (its Dockerfile reference), so CMD
# restates the base image's.
RUN printf '#!/bin/sh\n. /etc/supply-chain-hardening.env\nexec "$@"\n' \
      > /usr/local/bin/hardened-entrypoint && chmod +x /usr/local/bin/hardened-entrypoint
ENTRYPOINT ["/usr/local/bin/hardened-entrypoint"]
CMD ["node"]

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

# Fail the build on a gap, with the env layer loaded as the entrypoint loads it.
# --fail-on=config fails on every gap a new run of harden.sh would close. A gap
# that only a newer tool closes is printed and does not fail it: this base
# image's npm 10 has no age gate, and Yarn 1 has none. Install newer tools
# before harden.sh and use --fail-on=any to fail on those too.
RUN . /etc/supply-chain-hardening.env && \
    /usr/local/lib/supply-chain-hardening/action/verify.sh --emit=plain --fail-on=config
