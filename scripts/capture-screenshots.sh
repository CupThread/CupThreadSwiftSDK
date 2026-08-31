#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DESTINATION="${1:-platform=iOS Simulator,name=iPhone 17}"

echo "==> Running UI tests on simulator ($DESTINATION)..."
xcodebuild test \
    -project "$REPO_ROOT/Demo/CupThreadDemo.xcodeproj" \
    -scheme CupThreadDemo \
    -destination "$DESTINATION"

echo "==> Converting screenshots to JPEG for DocC..."
"$REPO_ROOT/scripts/convert-screenshots.sh"

echo "==> Done! Screenshots updated in JPEG format."
