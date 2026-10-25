#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

# Argument provided by reusable workflow caller, see
# https://github.com/bazel-contrib/.github/blob/d197a6427c5435ac22e56e33340dff912bc9334e/.github/workflows/release_ruleset.yaml#L72
TAG=$1
VERSION=${TAG:1}
# The prefix is chosen to match what GitHub generates for source archives
# This guarantees that users can easily switch from a released artifact to a source archive
# with minimal differences in their code (e.g. strip_prefix remains the same)
PREFIX="rules_flutter-${VERSION}"
ARCHIVE="rules_flutter-$TAG.tar.gz"

# NB: configuration for 'git archive' is in /.gitattributes
git archive --format=tar --prefix="${PREFIX}"/ "${TAG}" | gzip >"$ARCHIVE"

# The sha256 SRI integrity of a file, for an `archive_override` block.
sri_of() {
  python3 -c 'import base64, hashlib, sys; print("sha256-" + base64.b64encode(hashlib.sha256(open(sys.argv[1], "rb").read()).digest()).decode())' "$1"
}

FLUTTER_INTEGRITY=$(sri_of "$ARCHIVE")
FLUTTER_URL="https://github.com/Mivr/rules_flutter/releases/download/${TAG}/rules_flutter-${TAG}.tar.gz"

# Neither module is on the Bazel Central Registry, so consumers need the
# `archive_override` for `ai_rules_dart` too. The version comes from the
# tagged MODULE.bazel, and the integrity from that release's own archive,
# verified against the release digest before anything is printed.
DART_VERSION=$(git show "${TAG}:MODULE.bazel" | sed -n 's/^bazel_dep(name = "ai_rules_dart", version = "\([^"]*\)".*/\1/p')
if [[ -z "$DART_VERSION" ]]; then
  echo "release_prep: no ai_rules_dart bazel_dep in ${TAG}:MODULE.bazel" >&2
  exit 1
fi
DART_TAG="v${DART_VERSION}"
DART_ARCHIVE="rules_dart-${DART_TAG}.tar.gz"
DART_URL="https://github.com/Mivr/rules_dart/releases/download/${DART_TAG}/${DART_ARCHIVE}"
DART_PREFIX="rules_dart-${DART_VERSION}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
curl --fail --show-error --location --output "$TMPDIR/$DART_ARCHIVE" "$DART_URL"
DART_HEX=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TMPDIR/$DART_ARCHIVE")
EXPECTED_DIGEST=$(gh api "repos/Mivr/rules_dart/releases/tags/${DART_TAG}" --jq ".assets[] | select(.name == \"${DART_ARCHIVE}\") | .digest")
if [[ "$EXPECTED_DIGEST" != "sha256:${DART_HEX}" ]]; then
  echo "release_prep: ${DART_ARCHIVE} sha256 ${DART_HEX} does not match release digest ${EXPECTED_DIGEST}" >&2
  exit 1
fi
DART_INTEGRITY=$(sri_of "$TMPDIR/$DART_ARCHIVE")

cat <<EOF
Add to your \`MODULE.bazel\` file:

\`\`\`starlark
bazel_dep(name = "ai_rules_flutter", version = "${VERSION}", repo_name = "rules_flutter")
bazel_dep(name = "ai_rules_dart", version = "${DART_VERSION}", repo_name = "rules_dart")

archive_override(
    module_name = "ai_rules_flutter",
    urls = ["${FLUTTER_URL}"],
    integrity = "${FLUTTER_INTEGRITY}",
    strip_prefix = "${PREFIX}",
)

archive_override(
    module_name = "ai_rules_dart",
    urls = ["${DART_URL}"],
    integrity = "${DART_INTEGRITY}",
    strip_prefix = "${DART_PREFIX}",
)
\`\`\`
EOF

# The notes are the `Changelog:` trailers since the previous release (see
# AGENTS.md). The release job checks out the tag alone, so fetch the history
# back to that release first.
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  git fetch --quiet --unshallow --tags origin
fi
echo
bazel run --noshow_progress --ui_event_filters=-info \
  @multitool//tools/git-cliff:workspace_root -- \
  --config cliff.toml --current --strip header
