#!/usr/bin/env bash
set -euo pipefail

# Import the Developer ID Application signing certificate into a temporary
# keychain on a GitHub Actions runner.
#
# Required env:
#   CERT_P12_BASE64    — base64-encoded .p12
#   CERT_PASSWORD      — password the .p12 was exported with
#   KEYCHAIN_PASSWORD  — password to lock the throwaway keychain
#   RUNNER_TEMP        — provided by GitHub Actions

: "${CERT_P12_BASE64:?CERT_P12_BASE64 not set}"
: "${CERT_PASSWORD:?CERT_PASSWORD not set}"
: "${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD not set}"
: "${RUNNER_TEMP:?RUNNER_TEMP not set}"

CERT_PATH="$RUNNER_TEMP/cert.p12"
KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"

echo -n "$CERT_P12_BASE64" | base64 --decode -o "$CERT_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERT_PATH" -P "$CERT_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security list-keychain -d user -s "$KEYCHAIN_PATH" $(security list-keychain -d user | xargs)

security find-identity -v -p codesigning "$KEYCHAIN_PATH"
