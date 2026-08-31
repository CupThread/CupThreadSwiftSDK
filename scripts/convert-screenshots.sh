#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCC_RES_DIR="$REPO_ROOT/Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources"

mkdir -p "$DOCC_RES_DIR"

echo "==> Converting screenshots in DocC Resources to JPEG..."

for name in roadmap feature_requests submit_request whats_new changelog_overlay feedback_composer; do
    src_png="$DOCC_RES_DIR/$name.png"
    if [ -f "$src_png" ]; then
        echo "Converting $name.png -> $name.jpg..."
        sips -s format jpeg -s formatOptions 75 "$src_png" --out "$DOCC_RES_DIR/$name.jpg" >/dev/null 2>&1
        rm -f "$src_png"
    fi
done

# Clean up any leftover PNG files in docc resources
rm -f "$DOCC_RES_DIR"/*.png

echo "==> JPEG screenshots for DocC in $DOCC_RES_DIR:"
ls -lh "$DOCC_RES_DIR"/*.jpg
