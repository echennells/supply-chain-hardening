# Bake the hardening into an image.
#
# The most portable option of all: no CI adapter, no env mechanism, no
# per-platform anything. Any CI that can run a container gets the hardening,
# and so does every developer who pulls the image.
#
#   docker build --build-arg HARDEN_STAMP="$(date -u +%F)" \
#     -t hardened-node -f action/examples/Dockerfile .              # from the repo root
#   docker run --rm -v "$PWD:/src" -w /src hardened-node npm ci
#
# Read docs/container-images.md first: harden after the toolchains are in, as the
# user the image runs as, and rebuild at least every 7 days with a new
# HARDEN_STAMP (or with --pull --no-cache): a rebuild the cache can serve keeps
# the old uv and pip cutoffs. CI builds this file as it is and runs the verifier
# in the result (tests/ci/agent-shell/run.sh, cell image-recipe).

# A tag moves. Pin your copy by digest (node:22-bookworm@sha256:...), and move
# the digest on purpose.
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
# a sourceable env file. WRITE_ETC=true also writes /etc/npmrc, /etc/pip.conf
# and /etc/uv/uv.toml, for a tool that reads them whoever runs it. On this base
# image none does: its npm reads /usr/local/etc/npmrc, not /etc/npmrc, and it
# has no pip or uv. So a user other than root gets the env layer, through the
# entrypoint, and nothing more (docs/container-images.md: build as the user the
# image runs as).
#
# The uv and pip cutoffs are instants taken when this RUN runs, and the build
# cache keeps its layer, cutoffs and all, while nothing above it changes. A new
# HARDEN_STAMP runs it again, and every RUN after it.
ARG HARDEN_STAMP=
RUN echo "harden stamp: ${HARDEN_STAMP:-none}" && \
    ECOSYSTEMS=npm,pnpm,yarn,pip,uv,bun \
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
# `docker run img cmd`. On, alongside option A. It ends in the base image's own
# entrypoint, so `docker run img --version` and `docker run img -e '...'` still
# run node, as on node:22-bookworm. A command started with another entrypoint
# (`docker run --entrypoint ...`) or as a HEALTHCHECK goes without it. Docker
# resets an inherited CMD when ENTRYPOINT is set (its Dockerfile reference), so
# CMD restates the base image's.
RUN printf '#!/bin/sh\n. /etc/supply-chain-hardening.env\nexec docker-entrypoint.sh "$@"\n' \
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
# For root, the user they were written for, the config files block scripts on
# their own, so the env layer is the second line of defence there, as it is in
# CI. For any other user of this image it is the only one.

# Fail the build on a gap, with the env layer loaded as the entrypoint loads it.
# --fail-on=config fails on every gap a new run of harden.sh would close. A gap
# that only a newer tool closes is printed and does not fail it, and this base
# image has two: its npm 10.9.9 has no age gate (npm 11.10.0 added it), and its
# Yarn 1.22.22 reads no .yarnrc.yml. So this build passes with npm's age gate
# off. Install npm 11.10.0 or later (and Yarn 4.10 or later, or no Yarn) above
# harden.sh and use --fail-on=any to fail on those too.
RUN . /etc/supply-chain-hardening.env && \
    /usr/local/lib/supply-chain-hardening/action/verify.sh --emit=plain --fail-on=config
