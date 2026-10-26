#!/bin/zsh
set -euo pipefail
PLUGIN_ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PLUGIN_SOURCE="$PLUGIN_ROOT/Tools/CamiTunePluginHost"
PLUGIN_BUILD="$PLUGIN_ROOT/build/plugin-host"
PLUGIN_MODE="${CONFIGURATION:-Debug}"
PLUGIN_FIXTURES="$PLUGIN_ROOT/Tests/PluginHostRegression/fixtures"
PLUGIN_TEST_SOURCES=()
mkdir -p "$PLUGIN_BUILD"
PLUGIN_FLAGS=(-std=c++17 -O2 -mmacosx-version-min=13.0 -I"$PLUGIN_SOURCE/vendor" -framework AppKit -framework Accelerate -framework AVFoundation -framework AudioUnit -framework AudioToolbox -framework CoreAudioKit -framework CoreAudio -framework CoreMIDI -framework CoreFoundation)
if [[ "$PLUGIN_MODE" == "Debug" && "${CAMITUNE_PLUGIN_TESTING:-0}" == "1" && -f "$PLUGIN_FIXTURES/TestAudioUnit.mm" && -f "$PLUGIN_FIXTURES/TestAudioUnit.h" && -f "$PLUGIN_FIXTURES/FixtureEffect.h" ]]; then
    PLUGIN_FLAGS+=(-DCAMITUNE_PLUGIN_TESTING=1 -I"$PLUGIN_FIXTURES")
    PLUGIN_TEST_SOURCES+=("$PLUGIN_FIXTURES/TestAudioUnit.mm")
fi
# The app may be native-only; its helper must still host Intel VST3s separately.
PLUGIN_ARCHS=(arm64 x86_64)
for plugin_arch in "${PLUGIN_ARCHS[@]}"; do PLUGIN_FLAGS+=(-arch "$plugin_arch"); done
PLUGIN_KEY="$({ /usr/bin/find "$PLUGIN_SOURCE" -type f -exec /usr/bin/env LC_ALL=C /usr/bin/shasum -a 256 {} + ; if (( ${#PLUGIN_TEST_SOURCES} )); then /usr/bin/find "$PLUGIN_FIXTURES" -type f -exec /usr/bin/shasum -a 256 {} + ; fi; print -r -- "$PLUGIN_MODE ${PLUGIN_FLAGS[*]}"; xcrun clang++ --version; } | /usr/bin/env LC_ALL=C /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
if [[ ! -x "$PLUGIN_BUILD/camitune-plugin-host" || "$(cat "$PLUGIN_BUILD/build-key" 2>/dev/null || true)" != "$PLUGIN_KEY" ]]; then
    xcrun clang++ "${PLUGIN_FLAGS[@]}" -fobjc-arc "$PLUGIN_SOURCE/main.mm" "$PLUGIN_SOURCE/MIDIHost.mm" "$PLUGIN_SOURCE/ChannelHost.mm" "$PLUGIN_SOURCE/AudioUnitHost.mm" "$PLUGIN_SOURCE/VST3Host.mm" \
        "${PLUGIN_TEST_SOURCES[@]}" \
        "$PLUGIN_SOURCE/vendor/pluginterfaces/base/funknown.cpp" -o "$PLUGIN_BUILD/camitune-plugin-host"
    print -r -- "$PLUGIN_KEY" > "$PLUGIN_BUILD/build-key"
fi
if [[ $# -gt 0 ]]; then
    mkdir -p "$1/Helpers"
    cp "$PLUGIN_BUILD/camitune-plugin-host" "$1/Helpers/camitune-plugin-host"
    cp "$PLUGIN_SOURCE/vendor/pluginterfaces/LICENSE.txt" "$1/Helpers/VST3-LICENSE.txt"
fi
