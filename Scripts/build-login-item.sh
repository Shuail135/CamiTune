#!/bin/zsh
set -euo pipefail
LOGIN_ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGIN_SOURCE="$LOGIN_ROOT/Tools/CamiTuneLoginItem"
LOGIN_BUILD="$LOGIN_ROOT/build/login-item"
LOGIN_HELPER="$LOGIN_BUILD/CamiTuneLoginItem.app"
LOGIN_MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
LOGIN_FLAGS=(-fobjc-arc -O2 -Werror=unguarded-availability -mmacosx-version-min="$LOGIN_MIN_MACOS" -arch arm64 -arch x86_64 -framework AppKit)
LOGIN_KEY="$({ /usr/bin/shasum -a 256 "$LOGIN_SOURCE/main.m" "$LOGIN_SOURCE/Info.plist"; print -r -- "${LOGIN_FLAGS[*]}"; xcrun clang --version; xcrun --sdk macosx --show-sdk-version; } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
mkdir -p "$LOGIN_HELPER/Contents/MacOS"
if [[ ! -x "$LOGIN_HELPER/Contents/MacOS/CamiTuneLoginItem" || "$(cat "$LOGIN_BUILD/build-key" 2>/dev/null || true)" != "$LOGIN_KEY" ]]; then
    xcrun clang "${LOGIN_FLAGS[@]}" "$LOGIN_SOURCE/main.m" -o "$LOGIN_HELPER/Contents/MacOS/CamiTuneLoginItem"
    print -r -- "$LOGIN_KEY" > "$LOGIN_BUILD/build-key"
fi
cp "$LOGIN_SOURCE/Info.plist" "$LOGIN_HELPER/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "${CURRENT_PROJECT_VERSION:-1}" "$LOGIN_HELPER/Contents/Info.plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string "$LOGIN_MIN_MACOS" "$LOGIN_HELPER/Contents/Info.plist"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$LOGIN_HELPER"
python3 "$LOGIN_ROOT/Scripts/verify-macos-deployment.py" "$LOGIN_HELPER/Contents/MacOS/CamiTuneLoginItem" --macos "$LOGIN_MIN_MACOS" --architectures arm64 x86_64 --quiet
if [[ $# -gt 0 ]]; then
    LOGIN_DESTINATION="$1/Library/LoginItems/CamiTuneLoginItem.app"
    mkdir -p "${LOGIN_DESTINATION:h}"
    /usr/bin/ditto "$LOGIN_HELPER" "$LOGIN_DESTINATION"
fi
