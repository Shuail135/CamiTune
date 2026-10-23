#!/bin/zsh
set -euo pipefail
SURROUND_ROOT="${0:A:h:h}"
SURROUND_BUILD="$SURROUND_ROOT/build/surround-compatibility"
mkdir -p "$SURROUND_BUILD"
xcrun clang -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -I "$SURROUND_ROOT/Sources/SystemAudioBridgeC/include" \
    "$SURROUND_ROOT/Tests/SurroundCompatibilityCheck/capture.c" \
    "$SURROUND_ROOT/Sources/SystemAudioBridgeC/SystemAudioBridgeClient.c" \
    -framework CoreAudio -framework CoreFoundation -framework AudioToolbox \
    -o "$SURROUND_BUILD/capture"
xcrun clang -O2 -Wall -Wextra -Werror \
    "$SURROUND_ROOT/Tests/SurroundCompatibilityCheck/layout.c" \
    -framework CoreAudio -framework CoreFoundation -framework AudioToolbox \
    -o "$SURROUND_BUILD/layout"
python3 "$SURROUND_ROOT/Tests/SurroundCompatibilityCheck/run.py" "$@"
