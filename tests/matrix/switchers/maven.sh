#!/usr/bin/env bash
# Switch active Java + Maven for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/maven.sh <java_version> <maven_version>
# e.g.:
#   switchers/maven.sh 17 bundled
#   switchers/maven.sh 17 3.9.9
#
# Java is installed via apt (openjdk-N-jdk-headless). Maven "bundled"
# uses apt's maven; specific versions are downloaded as tarballs to
# /opt/maven-<version>. Switcher swaps /usr/local/bin/mvn symlink.

set -euo pipefail

JAVA_VERSION="${1:?usage: $0 <java_version> <maven_version>}"
MAVEN_VERSION="${2:?usage: $0 <java_version> <maven_version>}"

# Set active Java via update-alternatives. Distro's openjdk-N-jdk
# package registers the alternative; the switcher just picks one.
JAVA_BIN="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64/bin/java"
[[ -x "$JAVA_BIN" ]] || {
  echo "switchers/maven.sh: java $JAVA_VERSION not installed at $JAVA_BIN" >&2
  exit 1
}
update-alternatives --set java "$JAVA_BIN" >/dev/null 2>&1 || true
export JAVA_HOME="/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64"

# Set active Maven
if [[ "$MAVEN_VERSION" = "bundled" ]]; then
  # apt's maven at /usr/bin/mvn
  [[ -x /usr/bin/mvn ]] || { echo "switchers/maven.sh: apt maven not installed" >&2; exit 1; }
  ln -sf /usr/bin/mvn /usr/local/bin/mvn
else
  MAVEN_DIR="/opt/apache-maven-${MAVEN_VERSION}"
  [[ -x "$MAVEN_DIR/bin/mvn" ]] || {
    echo "switchers/maven.sh: maven $MAVEN_VERSION not installed at $MAVEN_DIR" >&2
    exit 1
  }
  ln -sf "$MAVEN_DIR/bin/mvn" /usr/local/bin/mvn
fi

# Verify
reported=$(mvn --version 2>/dev/null | head -1 | sed -nE 's/^Apache Maven ([0-9.]+).*$/\1/p')
if [[ "$MAVEN_VERSION" != "bundled" ]] && [[ "$reported" != "$MAVEN_VERSION" ]]; then
  echo "switchers/maven.sh: expected maven $MAVEN_VERSION, got '$reported'" >&2
  exit 1
fi

echo "switchers/maven.sh: java=$JAVA_VERSION mvn=$reported active"
