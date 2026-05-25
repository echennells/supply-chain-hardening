#!/usr/bin/env bash
# Switch active Java + Gradle for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/gradle.sh <java_version> <gradle_version>
# e.g.:
#   switchers/gradle.sh 17 bundled
#   switchers/gradle.sh 17 8.5
#
# Reuses Java install from maven.sh (apt openjdk-N-jdk-headless).
# Gradle "bundled" uses apt's gradle; specific versions are downloaded
# from gradle.org. Switcher swaps /usr/local/bin/gradle symlink.

set -euo pipefail

JAVA_VERSION="${1:?usage: $0 <java_version> <gradle_version>}"
GRADLE_VERSION="${2:?usage: $0 <java_version> <gradle_version>}"

JAVA_BIN="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64/bin/java"
[[ -x "$JAVA_BIN" ]] || {
  echo "switchers/gradle.sh: java $JAVA_VERSION not installed at $JAVA_BIN" >&2
  exit 1
}
update-alternatives --set java "$JAVA_BIN" >/dev/null 2>&1 || true
export JAVA_HOME="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64"

if [[ "$GRADLE_VERSION" = "bundled" ]]; then
  [[ -x /usr/bin/gradle ]] || { echo "switchers/gradle.sh: apt gradle not installed" >&2; exit 1; }
  ln -sf /usr/bin/gradle /usr/local/bin/gradle
else
  GRADLE_DIR="/opt/gradle-${GRADLE_VERSION}"
  [[ -x "$GRADLE_DIR/bin/gradle" ]] || {
    echo "switchers/gradle.sh: gradle $GRADLE_VERSION not installed at $GRADLE_DIR" >&2
    exit 1
  }
  ln -sf "$GRADLE_DIR/bin/gradle" /usr/local/bin/gradle
fi

reported=$(gradle --version 2>/dev/null | sed -nE 's/^Gradle ([0-9.]+)$/\1/p' | head -1)
if [[ "$GRADLE_VERSION" != "bundled" ]] && [[ "$reported" != "$GRADLE_VERSION" ]]; then
  echo "switchers/gradle.sh: expected gradle $GRADLE_VERSION, got '$reported'" >&2
  exit 1
fi

echo "switchers/gradle.sh: java=$JAVA_VERSION gradle=$reported active"
