#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
BUILD_ROOT="${SABR_BUILD_ROOT:-$REPO_ROOT/build/driver}"
CHANNELS="${SABR_CHANNELS:-8}"
MIN_MACOS="${SABR_MIN_MACOS:-13.0}"
DRIVER_VERSION="${SABR_DRIVER_VERSION:-0.7.12}"
DRIVER="$BUILD_ROOT/CamillaAudio.driver"
BINARY="$DRIVER/Contents/MacOS/CamillaAudio"

if [[ "$CHANNELS" != "2" && "$CHANNELS" != "6" && "$CHANNELS" != "8" ]]; then
    print -u2 "SABR_CHANNELS must be 2 (stereo), 6 (5.1), or 8 (7.1)."
    exit 1
fi
CLANG="$(/usr/bin/xcrun --sdk macosx --find clang)"
ACTOOL="$(/usr/bin/xcrun --sdk macosx --find actool)"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
ICON_CATALOG="$REPO_ROOT/Resources/Assets.xcassets"
ICON_PARTIAL_INFO="$BUILD_ROOT/AppIcon-PartialInfo.plist"

/bin/rm -rf "$DRIVER"
/bin/mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources"
"$CLANG" \
    -std=gnu11 \
    -O2 \
    -fblocks \
    -Wall \
    -Wextra \
    -Werror \
    -Wno-deprecated-declarations \
    -bundle \
    -isysroot "$SDK" \
    -mmacosx-version-min="$MIN_MACOS" \
    -DkDriver_Name='"System Audio Bridge"' \
    -DkPlugIn_BundleID='"local.camillaaudio.driver"' \
    -DkHas_Driver_Name_Format=false \
    -DkDevice_Name='"System Audio Bridge"' \
    -DkManufacturer_Name='"System Audio Bridge contributors"' \
    -DkDevice_IsHidden=true \
    -DkDevice_HasInput=false \
    -DkDevice_HasOutput=true \
    -DkDevice2_HasInput=false \
    -DkDevice2_HasOutput=true \
    -DkNumber_Of_Channels="$CHANNELS" \
    "$SCRIPT_DIR/Driver/SystemAudioBridge.c" \
    "$SCRIPT_DIR/Driver/SystemAudioBridgeDriverTransport.c" \
    -framework Accelerate \
    -framework CoreAudio \
    -framework CoreFoundation \
    -o "$BINARY"
/bin/cp "$SCRIPT_DIR/Driver/Info.plist" "$DRIVER/Contents/Info.plist"
/bin/cp "$REPO_ROOT/LICENSE" "$DRIVER/Contents/Resources/"
"$ACTOOL" "$ICON_CATALOG" \
    --compile "$DRIVER/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target "$MIN_MACOS" \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_PARTIAL_INFO" \
    >/dev/null
if [[ ! -f "$DRIVER/Contents/Resources/AppIcon.icns" ]]; then
    print -u2 "Asset compilation did not produce AppIcon.icns for the driver bundle."
    exit 1
fi
/usr/bin/xattr -cr "$DRIVER"
/usr/bin/plutil -replace CFBundleVersion -string "${SABR_DRIVER_BUILD:-1}" "$DRIVER/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$DRIVER_VERSION" "$DRIVER/Contents/Info.plist"
/usr/bin/plutil -replace SystemAudioBridgeChannelCount -integer "$CHANNELS" "$DRIVER/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$DRIVER"
/usr/bin/codesign --verify --strict "$DRIVER"
if ! /usr/bin/nm -gj "$BINARY" | /usr/bin/grep -q '^_SystemAudioBridge_Create$'; then
    print -u2 "Driver factory symbol was not exported."
    exit 1
fi

print "Built $DRIVER ($CHANNELS channels, macOS $MIN_MACOS+)"
