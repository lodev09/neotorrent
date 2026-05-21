#!/usr/bin/env bash
set -euo pipefail

# Submit a file (.zip / .dmg / .pkg) to Apple's notary service and poll until
# it reaches a terminal state. On failure or timeout, dumps the notarization
# log so we don't have to fish for it manually.
#
# Required env:
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#
# Usage:
#   scripts/notarize.sh <path-to-file>
#
# Tunables:
#   NOTARIZE_POLL_TIMEOUT_SECS  (default 3600)
#   NOTARIZE_POLL_INTERVAL_SECS (default 30)

FILE="${1:?file path required}"
: "${APPLE_ID:?APPLE_ID not set}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID not set}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD not set}"

POLL_TIMEOUT="${NOTARIZE_POLL_TIMEOUT_SECS:-3600}"
POLL_INTERVAL="${NOTARIZE_POLL_INTERVAL_SECS:-30}"

cred=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")

echo "==> Submitting $FILE to notary service"
SUBMIT_JSON="$(xcrun notarytool submit "$FILE" "${cred[@]}" --output-format json)"
echo "$SUBMIT_JSON"
SUBMISSION_ID="$(echo "$SUBMIT_JSON" | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')"

echo "==> Submission ID: $SUBMISSION_ID"
echo "==> Polling (timeout ${POLL_TIMEOUT}s, interval ${POLL_INTERVAL}s)"

START="$(date +%s)"
STATUS=""
while :; do
    INFO_JSON="$(xcrun notarytool info "$SUBMISSION_ID" "${cred[@]}" --output-format json)"
    STATUS="$(echo "$INFO_JSON" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("status", "Unknown"))')"
    NOW="$(date +%s)"
    ELAPSED=$((NOW - START))
    echo "    [${ELAPSED}s] status: $STATUS"

    case "$STATUS" in
        Accepted) break ;;
        Invalid|Rejected) break ;;
        "In Progress") ;;
        *)
            echo "warn: unexpected status '$STATUS' — continuing to poll" >&2
            ;;
    esac

    if [ "$ELAPSED" -ge "$POLL_TIMEOUT" ]; then
        echo "error: notarization poll timed out after ${ELAPSED}s (still ${STATUS})" >&2
        echo "       Submission ID: $SUBMISSION_ID" >&2
        echo "       Apple may still complete it asynchronously; check later with:" >&2
        echo "         xcrun notarytool info $SUBMISSION_ID --apple-id … --team-id … --password …" >&2
        exit 1
    fi

    sleep "$POLL_INTERVAL"
done

if [ "$STATUS" != "Accepted" ]; then
    echo "==> Notarization failed (status: $STATUS). Fetching log…" >&2
    xcrun notarytool log "$SUBMISSION_ID" "${cred[@]}"
    exit 1
fi

echo "==> Accepted"
