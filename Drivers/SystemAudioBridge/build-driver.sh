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

if [[ "$CHANNELS" != <1-32> ]]; then
    print -u2 "SABR_CHANNELS must be between 1 and 32."
    exit 1
fi
# Count alone is ambiguous for immersive layouts. The default 8-channel build
# remains 7.1; other custom counts are discrete unless explicitly labeled.
SABR_LAYOUT_NAME="${SABR_LAYOUT:-auto}"
if [[ "$SABR_LAYOUT_NAME" == "auto" ]]; then
    case "$CHANNELS" in
        1) SABR_LAYOUT_NAME=mono ;;
        2) SABR_LAYOUT_NAME=stereo ;;
        6) SABR_LAYOUT_NAME=5.1 ;;
        8) SABR_LAYOUT_NAME=7.1 ;;
        *) SABR_LAYOUT_NAME=discrete ;;
    esac
fi
case "$SABR_LAYOUT_NAME" in
    mono) SABR_LAYOUT_BASE=100; SABR_LAYOUT_CHANNELS=1 ;;
    stereo) SABR_LAYOUT_BASE=101; SABR_LAYOUT_CHANNELS=2 ;;
    5.1) SABR_LAYOUT_BASE=121; SABR_LAYOUT_CHANNELS=6 ;;
    7.1) SABR_LAYOUT_BASE=128; SABR_LAYOUT_CHANNELS=8 ;;
    5.1.2) SABR_LAYOUT_BASE=194; SABR_LAYOUT_CHANNELS=8 ;;
    5.1.4) SABR_LAYOUT_BASE=195; SABR_LAYOUT_CHANNELS=10 ;;
    7.1.2) SABR_LAYOUT_BASE=196; SABR_LAYOUT_CHANNELS=10 ;;
    7.1.4) SABR_LAYOUT_BASE=192; SABR_LAYOUT_CHANNELS=12 ;;
    9.1.6) SABR_LAYOUT_BASE=193; SABR_LAYOUT_CHANNELS=16 ;;
    discrete) SABR_LAYOUT_BASE=147; SABR_LAYOUT_CHANNELS="$CHANNELS" ;;
    *) print -u2 "Unsupported SABR_LAYOUT: $SABR_LAYOUT_NAME"; exit 1 ;;
esac
if [[ "$CHANNELS" != "$SABR_LAYOUT_CHANNELS" ]]; then
    print -u2 "SABR_LAYOUT=$SABR_LAYOUT_NAME requires $SABR_LAYOUT_CHANNELS channels."
    exit 1
fi
SABR_LAYOUT_TAG_VALUE=$(( (SABR_LAYOUT_BASE << 16) | CHANNELS ))
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
    -DSABR_CHANNEL_LAYOUT_TAG="$SABR_LAYOUT_TAG_VALUE" \
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
/usr/bin/plutil -replace SystemAudioBridgeChannelLayoutTag -integer "$SABR_LAYOUT_TAG_VALUE" "$DRIVER/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$DRIVER"
/usr/bin/codesign --verify --strict "$DRIVER"
if ! /usr/bin/nm -gj "$BINARY" | /usr/bin/grep -q '^_SystemAudioBridge_Create$'; then
    print -u2 "Driver factory symbol was not exported."
    exit 1
fi

print "Built $DRIVER ($CHANNELS channels, $SABR_LAYOUT_NAME, macOS $MIN_MACOS+)"
