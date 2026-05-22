#!/usr/bin/env bash
set -euo pipefail

# Tag a release and push, kicking off the GitHub Actions release workflow.
# Usage: ./scripts/release.sh 0.1.0

if [ $# -ne 1 ]; then
    echo "usage: $0 <version>   e.g. $0 0.1.0" >&2
    exit 2
fi

VERSION="$1"
TAG="v$VERSION"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must be MAJOR.MINOR.PATCH (got '$VERSION')" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
    echo "error: release from main only (current: $BRANCH)" >&2
    exit 1
fi

if ! git diff-index --quiet HEAD --; then
    echo "error: working tree has uncommitted changes" >&2
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists" >&2
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

echo
echo "Tag $TAG @ $(git rev-parse --short HEAD)"
git log -1 --pretty=format:'    %s%n'
read -r -p "Push tag and trigger release? [y/N] " ans
case "$ans" in
    y|Y|yes) ;;
    *) echo "aborted."; exit 0 ;;
esac

git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo
echo "==> pushed $TAG. Watch the build:"
echo "    gh run watch  (or)  https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '<owner>/<repo>')/actions"
