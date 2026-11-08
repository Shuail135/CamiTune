#!/bin/zsh
set -euo pipefail
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
# Make Cargo's fingerprint include the deployment target.
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C link-arg=-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
# Xcode does not inherit an interactive shell's Rust path.
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: Rust/Cargo is required to build Speaker Auto EQ." >&2
    exit 1
fi
HELPER_SLICES=()
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --release --locked --target "$target" --manifest-path "$ROOT/Tools/CamiTuneSpeakerEQCore/Cargo.toml" --target-dir "$ROOT/build/speaker-eq"
    HELPER_SLICES+=("$ROOT/build/speaker-eq/$target/release/camitune-speaker-eq")
done
HELPER="$ROOT/build/speaker-eq/release/camitune-speaker-eq"
mkdir -p "${HELPER:h}"
/usr/bin/lipo -create "${HELPER_SLICES[@]}" -output "$HELPER"
if [[ ! -x "$HELPER" ]]; then
    echo "ERROR: Speaker Auto EQ helper is missing: $HELPER" >&2
    exit 1
fi
python3 "$ROOT/Scripts/verify-macos-deployment.py" "$HELPER" --macos "$MACOSX_DEPLOYMENT_TARGET" --architectures arm64 x86_64
if [[ $# -gt 0 ]]; then
    mkdir -p "$1/Helpers"
    cp "$HELPER" "$1/Helpers/camitune-speaker-eq"
    chmod 755 "$1/Helpers/camitune-speaker-eq"
fi
