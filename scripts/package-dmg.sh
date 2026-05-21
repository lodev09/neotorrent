#!/usr/bin/env bash
set -euo pipefail

# Package NeoTorrent.app into a DMG.
#
# Env:
#   APP_PATH   — path to NeoTorrent.app (required)
#   VERSION    — overrides the version string in the DMG filename (default:
#                read from CFBundleShortVersionString)
#   OUT_DIR    — output directory (default: ./dist)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:?APP_PATH not set}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"

if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP_PATH does not exist" >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "error: create-dmg not found. Install via 'brew install create-dmg'." >&2
    exit 1
fi

if [ -z "${VERSION:-}" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
fi

mkdir -p "$OUT_DIR"
DMG_PATH="$OUT_DIR/NeoTorrent-$VERSION.dmg"
rm -f "$DMG_PATH"

# create-dmg wants a source *folder*; stage a copy of the .app there.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_PATH" "$STAGE/NeoTorrent.app"

echo "==> create-dmg $DMG_PATH"
create-dmg \
    --volname "NeoTorrent $VERSION" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "NeoTorrent.app" 165 200 \
    --app-drop-link 495 200 \
    --hide-extension "NeoTorrent.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGE"

echo "==> done: $DMG_PATH"
