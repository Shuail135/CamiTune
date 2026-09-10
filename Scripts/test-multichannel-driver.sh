#!/bin/zsh
set -euo pipefail
# Pure factory/property tests: no HAL installation, connection, or audio playback.
TEST_REPO="${0:A:h:h}"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/camitune-layout-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
TEST_SDK="$(xcrun --sdk macosx --show-sdk-path)"
for spec in '1:100' '2:101' '6:121' '8:128' '8:194' '10:195' '10:196' '12:192' '16:193' '32:147'; do
    TEST_COUNT="${spec%%:*}"
    TEST_BASE="${spec##*:}"
    TEST_TAG=$(( (TEST_BASE << 16) | TEST_COUNT ))
    xcrun clang -std=gnu11 -O2 -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
        -isysroot "$TEST_SDK" -mmacosx-version-min=13.0 \
        -DkNumber_Of_Channels="$TEST_COUNT" -DSABR_CHANNEL_LAYOUT_TAG="$TEST_TAG" \
        "$TEST_REPO/Tests/DriverTransportTests/multichannel_layout_test.c" \
        "$TEST_REPO/Drivers/SystemAudioBridge/Driver/SystemAudioBridge.c" \
        "$TEST_REPO/Drivers/SystemAudioBridge/Driver/SystemAudioBridgeDriverTransport.c" \
        -framework Accelerate -framework CoreAudio -framework CoreFoundation \
        -o "$TEST_BUILD/layout-test"
    "$TEST_BUILD/layout-test"
done
