#!/usr/bin/env bash
set -euo pipefail

# Select the newest Xcode 26 and install a pinned XcodeGen on a GitHub Actions
# macOS runner.
#
# Required env:
#   RUNNER_TEMP, GITHUB_PATH — provided by GitHub Actions

: "${RUNNER_TEMP:?RUNNER_TEMP not set}"
: "${GITHUB_PATH:?GITHUB_PATH not set}"

XCODEGEN_VERSION="2.45.4"
XCODEGEN_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"

XCODE="$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -n1 || true)"
if [ -z "$XCODE" ]; then
    echo "error: no Xcode 26 found in /Applications" >&2
    ls /Applications | grep -i xcode >&2 || true
    exit 1
fi
sudo xcode-select -s "$XCODE"
xcodebuild -version

ZIP="$RUNNER_TEMP/xcodegen.zip"
curl -fsSL -o "$ZIP" "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
echo "$XCODEGEN_SHA256  $ZIP" | shasum -a 256 -c -
unzip -q -o "$ZIP" -d "$RUNNER_TEMP"
echo "$RUNNER_TEMP/xcodegen/bin" >> "$GITHUB_PATH"
"$RUNNER_TEMP/xcodegen/bin/xcodegen" --version
