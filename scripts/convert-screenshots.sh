#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCC_RES_DIR="$REPO_ROOT/Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources"
DOCS_DIR="$REPO_ROOT/docs"

mkdir -p "$DOCC_RES_DIR" "$DOCS_DIR"

# Ensure docs/screenshots is a symlink pointing to the single canonical resources folder
if [ ! -L "$DOCS_DIR/screenshots" ]; then
    rm -rf "$DOCS_DIR/screenshots"
    ln -s ../Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources "$DOCS_DIR/screenshots"
fi

if ! command -v cwebp &>/dev/null; then
    echo "Warning: cwebp not found in PATH. Install via 'brew install webp'"
    exit 0
fi

echo "==> Converting screenshots in DocC Resources to WebP..."

for name in roadmap feature_requests submit_request whats_new changelog_overlay feedback_composer; do
    src_png="$DOCC_RES_DIR/$name.png"
    if [ -f "$src_png" ]; then
        echo "Converting $name.png -> $name.webp..."
        cwebp -q 90 -m 6 "$src_png" -o "$DOCC_RES_DIR/$name.webp" >/dev/null 2>&1
        rm -f "$src_png"
    fi
done

# Clean up any leftover PNG files in docc resources
rm -f "$DOCC_RES_DIR"/*.png

echo "==> Single canonical WebP files in $DOCC_RES_DIR:"
ls -lh "$DOCC_RES_DIR"/*.webp
