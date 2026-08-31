#!/bin/sh
# Builds the DocC documentation site as a plain static folder.
#
# Usage:
#   scripts/build-docs.sh [output-directory] [hosting-base-path]
#
# - output-directory defaults to ./docs-site
# - hosting-base-path defaults to the repository name (the GitHub Pages path,
#   e.g. /CupThreadSwiftSDK for cupthread.github.io/CupThreadSwiftSDK); pass
#   "/" when hosting at a domain root.
#
# The output folder needs no Jekyll processing (a .nojekyll is written), so it
# can be deployed to GitHub Pages directly — see .github/workflows/docs.yml —
# or previewed locally with:
#   python3 -m http.server 8080 --directory docs-site
#
# Base-path note: the path MUST be injected while BUILDING the archive
# (docc convert, via OTHER_DOCC_FLAGS). Newer docc versions ignore
# --hosting-base-path on `process-archive transform-for-static-hosting`, so
# passing it only at transform time yields index.html with root-relative
# asset URLs (blank page when hosted under a subpath). We still pass it to
# the transform too, for docc versions that only honor it there.
set -eu

SCHEME="CupThreadFeedback"
DERIVED_DATA=".docbuild"
ARCHIVE="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/$SCHEME.doccarchive"

OUTPUT_DIR="${1:-docs-site}"
if [ "$#" -ge 2 ]; then
    BASE_PATH="$2"
else
    BASE_PATH="${GITHUB_REPOSITORY#*/}"
    [ -n "$BASE_PATH" ] || BASE_PATH="$SCHEME"
fi

# Normalize: docc wants a leading slash and no trailing slash ("/CupThreadSwiftSDK").
BASE_PATH="${BASE_PATH%/}"
BASE_PATH="/${BASE_PATH#/}"

echo "==> Building $SCHEME.doccarchive (base path: $BASE_PATH)"
if [ "$BASE_PATH" = "/" ]; then
    xcodebuild docbuild \
        -scheme "$SCHEME" \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED_DATA"
else
    xcodebuild docbuild \
        -scheme "$SCHEME" \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED_DATA" \
        "OTHER_DOCC_FLAGS=--hosting-base-path $BASE_PATH"
fi

echo "==> Transforming archive for static hosting"
rm -rf "$OUTPUT_DIR"
xcrun docc process-archive transform-for-static-hosting "$ARCHIVE" \
    --output-path "$OUTPUT_DIR" \
    --hosting-base-path "$BASE_PATH"

# GitHub Pages would otherwise run Jekyll and drop files starting with "_".
touch "$OUTPUT_DIR/.nojekyll"

# The DocC SPA has no route for the site root ("/" renders its 404 view);
# the real landing page is the module page. Patch only the ROOT index.html
# so visitors of .../CupThreadSwiftSDK/ land on the module page. Deeper
# index.html copies are untouched (pathname != baseUrl there). "&" in the
# replacement keeps docc's original baseUrl script (trailing slash included).
MODULE_PATH="documentation/$(echo "$SCHEME" | tr '[:upper:]' '[:lower:]')"
sed -i '' "s#<script>var baseUrl = \"[^\"]*\"</script>#&<script>if(location.pathname===baseUrl)location.replace(baseUrl+\"${MODULE_PATH}/\");</script>#" \
    "$OUTPUT_DIR/index.html"

# Optional DocC theme-settings file; a stub avoids a benign 404 in the console.
printf '{}\n' > "$OUTPUT_DIR/theme-settings.json"

# Sync static resources (such as .webp images) to all DocC SPA image locations
RESOURCES_DIR="Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources"
if [ -d "$RESOURCES_DIR" ]; then
    mkdir -p "$OUTPUT_DIR/images" "$OUTPUT_DIR/images/cupthreadswiftsdk.CupThreadFeedback" "$OUTPUT_DIR/images/cupthreadfeedback"
    cp -R "$RESOURCES_DIR"/* "$OUTPUT_DIR/images/" 2>/dev/null || true
    cp -R "$RESOURCES_DIR"/* "$OUTPUT_DIR/images/cupthreadswiftsdk.CupThreadFeedback/" 2>/dev/null || true
    cp -R "$RESOURCES_DIR"/* "$OUTPUT_DIR/images/cupthreadfeedback/" 2>/dev/null || true
fi

echo "==> Documentation site written to $OUTPUT_DIR/"
