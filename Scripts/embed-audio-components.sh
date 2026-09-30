#!/bin/zsh
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIGURATION="${CONFIGURATION:-Debug}"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
RESOURCE_DIR="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-Contents/Resources}"
BUILD_ROOT="$ROOT/build"
DRIVER_CACHE="$BUILD_ROOT/driver/CamillaAudio.driver"
DRIVER_STAMP="$BUILD_ROOT/driver/build-key"
CAMILLADSP_REV="05e9cfcdf43c0dfe078ed3feb8af4c8bd701fd74"
CAMILLADSP_PATCHES=(
    "$ROOT/Contributions/CamillaDSP/0001-coreaudio-accept-device-uid.patch"
    "$ROOT/Contributions/CamillaDSP/0002-coreaudio-buffer-telemetry-without-rate-adjust.patch"
    "$ROOT/Contributions/CamillaDSP/0004-coreaudio-playback-clock-feedback.patch"
)
CAMILLADSP_CAPABILITY="coreaudio-uid-playback-clock-v1"
CAMILLADSP_BUILD_ROOT="$BUILD_ROOT/camilladsp"
CAMILLADSP_SOURCE="$CAMILLADSP_BUILD_ROOT/source"
CAMILLADSP_BINARY="$CAMILLADSP_BUILD_ROOT/camilladsp"
CAMILLADSP_STAMP="$CAMILLADSP_BUILD_ROOT/build-key"

mkdir -p "$RESOURCE_DIR/Drivers" "$RESOURCE_DIR/CamillaDSP"

has_required_camilla_capability() {
    local camitune_capability
    camitune_capability="$("$1" --cami-tune-capabilities 2>/dev/null)" || return 1
    [[ "$camitune_capability" == "$CAMILLADSP_CAPABILITY" ]]
}

copy_cached_components() {
    local copied=0
    if [[ -d "$DRIVER_CACHE" ]]; then
        rm -rf "$RESOURCE_DIR/Drivers/CamillaAudio.driver"
        /usr/bin/ditto "$DRIVER_CACHE" "$RESOURCE_DIR/Drivers/CamillaAudio.driver"
        copied=1
    fi
    if [[ -x "$CAMILLADSP_BINARY" ]] && has_required_camilla_capability "$CAMILLADSP_BINARY"; then
        cp "$CAMILLADSP_BINARY" "$RESOURCE_DIR/CamillaDSP/camilladsp"
        chmod +x "$RESOURCE_DIR/CamillaDSP/camilladsp"
        copied=1
    else
        rm -f "$RESOURCE_DIR/CamillaDSP/camilladsp"
        echo "CamiTune: no compatible cached engine; prepare Release audio components."
    fi
    return $((1 - copied))
}

# Build a pinned offline optimizer for every Release. Fast Debug uses its cache.
SPEAKER_HELPER="$ROOT/build/speaker-eq/release/camitune-speaker-eq"
if [[ "$CONFIGURATION" != "Debug" || "${CAMITUNE_PREPARE_AUDIO_COMPONENTS:-0}" == "1" ]]; then
    "$ROOT/Scripts/build-speaker-eq.sh" "$RESOURCE_DIR"
elif [[ -x "$SPEAKER_HELPER" ]]; then
    mkdir -p "$RESOURCE_DIR/Helpers"
    cp "$SPEAKER_HELPER" "$RESOURCE_DIR/Helpers/camitune-speaker-eq"
    chmod 755 "$RESOURCE_DIR/Helpers/camitune-speaker-eq"
else
    rm -f "$RESOURCE_DIR/Helpers/camitune-speaker-eq"
    echo "CamiTune: run Scripts/build-speaker-eq.sh once to enable Speaker Auto EQ in Debug."
fi

if [[ -x "$RESOURCE_DIR/Helpers/camitune-speaker-eq" ]]; then
    cp "$ROOT/Tools/CamiTuneSpeakerEQCore/THIRD_PARTY_NOTICES.txt" "$RESOURCE_DIR/Helpers/THIRD_PARTY_NOTICES.txt"
fi

ARCH="$(/usr/bin/uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "ERROR: Unsupported Mac architecture: $ARCH" >&2; exit 1 ;;
esac

# Driver cache key. Hash source/configuration files so ordinary Xcode rebuilds
# do not rebuild the driver unless its inputs changed.
DRIVER_INPUT_HASH="$({
    {
        find "$ROOT/Drivers/SystemAudioBridge/Driver" -type f -print
        find "$ROOT/Drivers/SystemAudioBridge/Shared" -type f -print
        echo "$ROOT/Sources/SystemAudioBridgeC/include/SystemAudioBridgeTransport.h"
        echo "$ROOT/Sources/SystemAudioBridgeC/include/SystemAudioBridgeCompletion.h"
        echo "$ROOT/Sources/SystemAudioBridgeC/include/SystemAudioBridgeProfileFormat.h"
        echo "$ROOT/Drivers/SystemAudioBridge/build-driver.sh"
    } | LC_ALL=C sort | while IFS= read -r file; do
        /usr/bin/shasum -a 256 "$file"
    done
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
DRIVER_BUILD_KEY="${ARCH}-${MIN_MACOS}-8ch-${DRIVER_INPUT_HASH}"
CURRENT_DRIVER_KEY="$(/bin/cat "$DRIVER_STAMP" 2>/dev/null || true)"

if [[ -d "$DRIVER_CACHE" && "$CURRENT_DRIVER_KEY" == "$DRIVER_BUILD_KEY" ]]; then
    echo "CamiTune: reusing cached System Audio Bridge driver."
else
    echo "CamiTune: building System Audio Bridge driver…"
    SABR_CHANNELS=8 SABR_LAYOUT=7.1 SABR_MIN_MACOS="$MIN_MACOS" "$ROOT/Drivers/SystemAudioBridge/build-driver.sh"
    echo "$DRIVER_BUILD_KEY" > "$DRIVER_STAMP"
fi

# Debug may reuse the expensive engine/optimizer builds, but the HAL driver
# must match its current sources. Validate/rebuild it above before copying the
# cache; otherwise Install / Repair can silently reinstall an unfixed driver.
if [[ "$CONFIGURATION" == "Debug" && "${CAMITUNE_PREPARE_AUDIO_COMPONENTS:-0}" != "1" ]]; then
    if copy_cached_components; then
        echo "CamiTune: embedded cached audio runtime components for Debug."
    else
        echo "CamiTune: fast Debug build; bundled driver/CamillaDSP were not prepared."
        echo "CamiTune: use a Release build once, or set CAMITUNE_PREPARE_AUDIO_COMPONENTS=1 to prepare them."
    fi
    exit 0
fi

# CamillaDSP cache key. Release builds always require the patched binary.
mkdir -p "$CAMILLADSP_BUILD_ROOT"
if [[ -n "${CAMITUNE_CAMILLADSP_BINARY:-}" ]]; then
    if [[ ! -x "$CAMITUNE_CAMILLADSP_BINARY" ]]; then
        echo "ERROR: CAMITUNE_CAMILLADSP_BINARY is not executable: $CAMITUNE_CAMILLADSP_BINARY" >&2
        exit 1
    fi
    if ! has_required_camilla_capability "$CAMITUNE_CAMILLADSP_BINARY"; then
        echo "ERROR: CAMITUNE_CAMILLADSP_BINARY lacks required CamiTune audio capabilities." >&2
        exit 1
    fi
    INPUT_HASH="$(/usr/bin/shasum -a 256 "$CAMITUNE_CAMILLADSP_BINARY" | /usr/bin/awk '{print $1}')"
    CAMILLADSP_BUILD_KEY="override-${ARCH}-${INPUT_HASH}"
else
    PATCH_HASH="$(/usr/bin/shasum -a 256 "${CAMILLADSP_PATCHES[@]}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
    CAMILLADSP_BUILD_KEY="source-${ARCH}-${CAMILLADSP_REV}-${PATCH_HASH}"
fi
CURRENT_CAMILLA_KEY="$(/bin/cat "$CAMILLADSP_STAMP" 2>/dev/null || true)"

if [[ -x "$CAMILLADSP_BINARY" && "$CURRENT_CAMILLA_KEY" == "$CAMILLADSP_BUILD_KEY" ]] \
    && has_required_camilla_capability "$CAMILLADSP_BINARY"; then
    echo "CamiTune: reusing cached CamillaDSP."
else
    echo "CamiTune: building CamillaDSP with output-clock support…"
    if [[ -n "${CAMITUNE_CAMILLADSP_BINARY:-}" ]]; then
        cp "$CAMITUNE_CAMILLADSP_BINARY" "$CAMILLADSP_BINARY"
    else
        if ! command -v cargo >/dev/null 2>&1; then
            echo "ERROR: Rust/Cargo is required for a Release build because the CamillaDSP cache is missing." >&2
            echo "Install Rust from https://rustup.rs or set CAMITUNE_CAMILLADSP_BINARY." >&2
            exit 1
        fi
        rm -rf "$CAMILLADSP_SOURCE"
        mkdir -p "$CAMILLADSP_SOURCE"
        git -C "$CAMILLADSP_SOURCE" init -q
        git -C "$CAMILLADSP_SOURCE" remote add origin https://github.com/HEnquist/camilladsp.git
        git -C "$CAMILLADSP_SOURCE" fetch --depth 1 origin "$CAMILLADSP_REV"
        git -C "$CAMILLADSP_SOURCE" checkout -q --detach FETCH_HEAD
        for camitune_patch in "${CAMILLADSP_PATCHES[@]}"; do
            git -C "$CAMILLADSP_SOURCE" apply "$camitune_patch"
        done
        cargo build --release --manifest-path "$CAMILLADSP_SOURCE/Cargo.toml"
        cp "$CAMILLADSP_SOURCE/target/release/camilladsp" "$CAMILLADSP_BINARY"
    fi
    chmod +x "$CAMILLADSP_BINARY"
fi

# Verify both rebuilt and reused/overridden binaries before publishing the cache
# key or embedding. Old cached Debug binaries are also rejected by the installer.
if ! has_required_camilla_capability "$CAMILLADSP_BINARY"; then
    echo "ERROR: CamillaDSP does not provide the required CamiTune audio capabilities." >&2
    exit 1
fi
echo "$CAMILLADSP_BUILD_KEY" > "$CAMILLADSP_STAMP"

rm -rf "$RESOURCE_DIR/Drivers/CamillaAudio.driver"
/usr/bin/ditto "$DRIVER_CACHE" "$RESOURCE_DIR/Drivers/CamillaAudio.driver"
cp "$CAMILLADSP_BINARY" "$RESOURCE_DIR/CamillaDSP/camilladsp"
chmod +x "$RESOURCE_DIR/CamillaDSP/camilladsp"

echo "CamiTune: embedded driver and CamillaDSP into $RESOURCE_DIR"
