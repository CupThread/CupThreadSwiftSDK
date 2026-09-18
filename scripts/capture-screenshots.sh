#!/usr/bin/env bash
# Refresh the six showcase screenshots in the DocC catalog.
#
# The pipeline is all-or-nothing: UI tests stage lossless PNGs into a fresh
# temporary directory, the staged set is validated (exactly the six expected
# names, non-empty, produced by this run), each PNG is converted to the one
# canonical JPEG quality, and only then are the committed JPEG assets
# swapped in. A failed or interrupted run leaves the committed gallery
# untouched. Direct UI-test runs without this script never modify the
# source tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCC_RES_DIR="$REPO_ROOT/Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources"
SCREENSHOT_NAMES=(roadmap feature_requests submit_request whats_new changelog_overlay feedback_composer)

DESTINATION="${1:-platform=iOS Simulator,name=iPhone 17}"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cupthread-screenshots.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"; rm -f "$DOCC_RES_DIR"/*.jpg.incoming' EXIT

START_EPOCH=$(date +%s)

echo "==> Running UI tests on simulator ($DESTINATION); staging screenshots in $STAGING_DIR..."
# xcodebuild only forwards TEST_RUNNER_-prefixed variables to the UI test
# runner process (with the prefix stripped), so the helper in
# CupThreadDemoUITests sees CUPTHREAD_SCREENSHOT_OUTPUT_DIR.
TEST_RUNNER_CUPTHREAD_SCREENSHOT_OUTPUT_DIR="$STAGING_DIR" xcodebuild test \
    -project "$REPO_ROOT/Demo/CupThreadDemo.xcodeproj" \
    -scheme CupThreadDemo \
    -destination "$DESTINATION"

echo "==> Validating staged screenshots..."
shopt -s nullglob
staged_files=("$STAGING_DIR"/*)
if [ "${#staged_files[@]}" -ne "${#SCREENSHOT_NAMES[@]}" ]; then
    echo "ERROR: expected exactly ${#SCREENSHOT_NAMES[@]} staged screenshots, found ${#staged_files[@]}:" >&2
    printf '  %s\n' "${staged_files[@]##*/}" >&2
    exit 1
fi

for name in "${SCREENSHOT_NAMES[@]}"; do
    staged_png="$STAGING_DIR/$name.png"
    if [ ! -f "$staged_png" ]; then
        echo "ERROR: missing staged screenshot: $name.png" >&2
        exit 1
    fi
    if [ ! -s "$staged_png" ]; then
        echo "ERROR: staged screenshot is empty: $name.png" >&2
        exit 1
    fi
    mtime=$(stat -f %m "$staged_png")
    if [ "$mtime" -lt "$START_EPOCH" ]; then
        echo "ERROR: staged screenshot predates this run: $name.png" >&2
        exit 1
    fi
    actual_format="$(sips -g format "$staged_png" 2>/dev/null | awk '/format:/{print $2}')"
    if [ "$actual_format" != "png" ]; then
        echo "ERROR: staged screenshot is not a PNG: $name.png (format: $actual_format)" >&2
        exit 1
    fi
done

echo "==> Converting staged PNGs to canonical JPEG (formatOptions 75)..."
CONVERTED_DIR="$STAGING_DIR/converted"
mkdir -p "$CONVERTED_DIR"
for name in "${SCREENSHOT_NAMES[@]}"; do
    sips -s format jpeg -s formatOptions 75 "$STAGING_DIR/$name.png" --out "$CONVERTED_DIR/$name.jpg" >/dev/null
    for prop in pixelWidth pixelHeight; do
        before="$(sips -g "$prop" "$STAGING_DIR/$name.png" | awk '/pixel/{print $2}')"
        after="$(sips -g "$prop" "$CONVERTED_DIR/$name.jpg" | awk '/pixel/{print $2}')"
        if [ "$before" != "$after" ]; then
            echo "ERROR: conversion changed dimensions for $name ($prop: $before -> $after)" >&2
            exit 1
        fi
    done
done

echo "==> Replacing committed JPEG assets..."
for name in "${SCREENSHOT_NAMES[@]}"; do
    incoming="$DOCC_RES_DIR/$name.jpg.incoming"
    cp "$CONVERTED_DIR/$name.jpg" "$incoming"
    mv -f "$incoming" "$DOCC_RES_DIR/$name.jpg"
done

echo "==> Verifying the committed gallery..."
"$REPO_ROOT/scripts/verify-screenshots.sh"

echo "==> Done! Six canonical JPEG screenshots updated in $DOCC_RES_DIR"
ls -lh "$DOCC_RES_DIR"/*.jpg
