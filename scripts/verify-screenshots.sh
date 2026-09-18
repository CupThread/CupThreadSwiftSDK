#!/usr/bin/env bash
# Guard for the screenshot gallery invariant: the DocC catalog must commit
# exactly the six canonical JPEG screenshots — no PNG duplicates, no stray
# or empty image files. Invoked by scripts/capture-screenshots.sh after a
# successful capture; also safe to run standalone.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCC_RES_DIR="$REPO_ROOT/Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources"
SCREENSHOT_NAMES=(roadmap feature_requests submit_request whats_new changelog_overlay feedback_composer)

fail=0

shopt -s nullglob
for image in "$DOCC_RES_DIR"/*.png "$DOCC_RES_DIR"/*.jpg "$DOCC_RES_DIR"/*.jpeg; do
    base="$(basename "$image")"
    stem="${base%.*}"
    ext="${base##*.}"

    is_expected=0
    for name in "${SCREENSHOT_NAMES[@]}"; do
        if [ "$stem" = "$name" ]; then
            is_expected=1
            break
        fi
    done
    if [ "$is_expected" -eq 0 ]; then
        echo "ERROR: unexpected screenshot image committed: $base" >&2
        fail=1
        continue
    fi
    if [ "$ext" != "jpg" ]; then
        echo "ERROR: screenshots must use the canonical .jpg format: $base" >&2
        fail=1
        continue
    fi
    if [ ! -s "$image" ]; then
        echo "ERROR: canonical screenshot is empty: $base" >&2
        fail=1
    fi
done

for name in "${SCREENSHOT_NAMES[@]}"; do
    if [ ! -f "$DOCC_RES_DIR/$name.jpg" ]; then
        echo "ERROR: canonical screenshot missing: $name.jpg" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "Screenshot gallery verification FAILED." >&2
    exit 1
fi

echo "Screenshot gallery OK: exactly ${#SCREENSHOT_NAMES[@]} canonical .jpg assets, no PNG duplicates."
