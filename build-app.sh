#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CamiTune"
APP_VERSION="${APP_VERSION:-0.3.0}"
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    if [[ "${GITHUB_REF_NAME:-}" =~ '^v([0-9]+\.[0-9]+\.[0-9]+)$' ]]; then
        APP_VERSION="${GITHUB_REF_NAME#v}"
    else
        echo "ERROR: Release tags must use the format vMAJOR.MINOR.PATCH (for example v0.1.2)."
        exit 1
    fi
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(/bin/date -u +%Y%m%d%H%M%S)}"
ARCHIVE="$PWD/dist/CamiTune.xcarchive"
APP="$PWD/dist/CamiTune.app"
DERIVED_DATA="$PWD/dist/DerivedData"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "ERROR: Full Xcode is required. Install Xcode and select it with xcode-select." >&2
    exit 1
fi

mkdir -p dist
rm -rf "$ARCHIVE" "$APP" "$DERIVED_DATA"

echo "Building $APP_NAME $APP_VERSION with CamiTune.xcodeproj…"
xcodebuild \
    -project CamiTune.xcodeproj \
    -scheme CamiTune \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$DERIVED_DATA" \
    MARKETING_VERSION="$APP_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO \
    archive

BUILT_APP="$ARCHIVE/Products/Applications/CamiTune.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "ERROR: Xcode archive did not produce $BUILT_APP" >&2
    exit 1
fi

/usr/bin/ditto "$BUILT_APP" "$APP"
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo
echo "Built: $APP"
echo "Open it with: open '$APP'"
