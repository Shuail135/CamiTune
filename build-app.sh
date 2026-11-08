#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

# Verification and packaging share DerivedData and native helper caches.
if [[ "${1:-}" != "--build-lock-held" ]]; then
    exec python3 Scripts/verify-build.py release "$@"
fi
shift

APP_NAME="CamiTune"
APP_VERSION="${APP_VERSION:-$(/usr/bin/awk '$1 == "MARKETING_VERSION" && $2 == "=" { print $3 }' Config/Version.xcconfig)}"
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    if [[ "${GITHUB_REF_NAME:-}" =~ '^v([0-9]+\.[0-9]+\.[0-9]+)$' ]]; then
        APP_VERSION="${GITHUB_REF_NAME#v}"
    else
        echo "ERROR: Release tags must use the format vMAJOR.MINOR.PATCH (for example v0.1.2)."
        exit 1
    fi
fi
if [[ ! "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "ERROR: APP_VERSION must be MAJOR.MINOR.PATCH; check Config/Version.xcconfig or the explicit override." >&2
    exit 1
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
for executable in "$APP/Contents/MacOS/CamiTune" "$ARCHIVE/Products/Applications/CamiTune.app/Contents/MacOS/CamiTune"; do
    if [[ -f "$executable" && -n "$(/usr/sbin/lsof -t "$executable" 2>/dev/null)" ]]; then
        echo "ERROR: Close the application using $executable before packaging." >&2
        exit 1
    fi
done
rm -rf "$ARCHIVE" "$APP"

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
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    archive

BUILT_APP="$ARCHIVE/Products/Applications/CamiTune.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "ERROR: Xcode archive did not produce $BUILT_APP" >&2
    exit 1
fi

if [[ ! -x "$BUILT_APP/Contents/Resources/Helpers/camitune-speaker-eq" ]]; then
    echo "ERROR: Release archive is missing the speaker optimizer helper." >&2
    exit 1
fi
if [[ ! -x "$BUILT_APP/Contents/Resources/Helpers/camitune-plugin-host" ]]; then
    echo "ERROR: Release archive is missing the AU/VST3 plug-in host." >&2
    exit 1
fi
/usr/bin/ditto "$BUILT_APP" "$APP"
python3 Scripts/verify-macos-deployment.py "$APP" --macos 11.0 --architectures arm64 x86_64
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

echo
echo "Built: $APP"
echo "Open it with: open '$APP'"
