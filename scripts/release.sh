#!/usr/bin/env bash
set -euo pipefail

# Bump version in project.yml, commit, tag, push — triggers the release workflow.
# Usage:
#   ./scripts/release.sh           # prompts, defaults to bumping the patch
#   ./scripts/release.sh 0.2.0     # use the given version

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="apps/NeoTorrent/project.yml"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "error: release from main only (current: $BRANCH)" >&2
    exit 1
fi

if ! git diff-index --quiet HEAD --; then
    echo "error: working tree has uncommitted changes" >&2
    exit 1
fi

echo "==> fetching origin"
git fetch --tags origin main

LOCAL="$(git rev-parse @)"
REMOTE="$(git rev-parse @{u})"
if [ "$LOCAL" != "$REMOTE" ]; then
    echo "error: local main is not in sync with origin/main" >&2
    echo "       local=$LOCAL  remote=$REMOTE" >&2
    exit 1
fi

CURRENT="$(/usr/bin/sed -n 's/.*CFBundleShortVersionString: "\([^"]*\)".*/\1/p' "$PROJECT" | head -n1)"
CURRENT_BUILD="$(/usr/bin/sed -n 's/.*CFBundleVersion: "\([^"]*\)".*/\1/p' "$PROJECT" | head -n1)"
LATEST="$(git tag --list 'v*.*.*' --sort=-v:refname | head -n1 || true)"

BASE="${LATEST#v}"
BASE="${BASE:-$CURRENT}"
BASE="${BASE:-0.1.0}"
IFS='.' read -r MAJ MIN PAT <<<"$BASE"
DEFAULT="$MAJ.$MIN.$((PAT + 1))"

if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "error: CFBundleVersion in $PROJECT must be a plain integer (got '$CURRENT_BUILD')" >&2
    exit 1
fi
NEXT_BUILD=$((CURRENT_BUILD + 1))

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Current version: ${CURRENT:-<unknown>}"
    echo "Latest tag:      ${LATEST:-<none>}"
    read -r -p "Version [$DEFAULT]: " VERSION
    VERSION="${VERSION:-$DEFAULT}"
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must be MAJOR.MINOR.PATCH (got '$VERSION')" >&2
    exit 1
fi

TAG="v$VERSION"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi

cat <<EOF

────────── Release summary ──────────
  Branch:    $BRANCH @ $(git rev-parse --short HEAD)
  Version:   ${CURRENT:-<unknown>} → $VERSION
  Build:     ${CURRENT_BUILD} → $NEXT_BUILD
  Tag:       $TAG
  Last:      $(git log -1 --pretty=format:'%s')

  Will:
    1. set CFBundleShortVersionString="$VERSION", CFBundleVersion="$NEXT_BUILD" in $PROJECT
    2. commit "Bump version to $VERSION"
    3. push origin main
    4. tag $TAG and push (triggers release workflow)
─────────────────────────────────────
EOF
read -r -p "Proceed? [y/N] " ans
case "$ans" in
    y|Y|yes) ;;
    *) echo "aborted."; exit 0 ;;
esac

/usr/bin/sed -i '' \
    -e "s/CFBundleShortVersionString: \"[^\"]*\"/CFBundleShortVersionString: \"$VERSION\"/" \
    -e "s/CFBundleVersion: \"[^\"]*\"/CFBundleVersion: \"$NEXT_BUILD\"/" \
    "$PROJECT"

if git diff --quiet -- "$PROJECT"; then
    echo "error: $PROJECT unchanged (was the version already $VERSION?)" >&2
    exit 1
fi

git add "$PROJECT"
git commit -m "Bump version to $VERSION"
git push origin main

git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo
echo "==> pushed $TAG. Watch the build:"
echo "    gh run watch  (or)  https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '<owner>/<repo>')/actions"
