#!/bin/zsh
set -euo pipefail
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
# Xcode does not inherit an interactive shell's Rust path.
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: Rust/Cargo is required to build Speaker Auto EQ." >&2
    exit 1
fi
cargo build --release --locked --manifest-path "$ROOT/Tools/CamiTuneSpeakerEQCore/Cargo.toml" --target-dir "$ROOT/build/speaker-eq"
HELPER="$ROOT/build/speaker-eq/release/camitune-speaker-eq"
if [[ ! -x "$HELPER" ]]; then
    echo "ERROR: Speaker Auto EQ helper is missing: $HELPER" >&2
    exit 1
fi
if [[ $# -gt 0 ]]; then
    mkdir -p "$1/Helpers"
    cp "$HELPER" "$1/Helpers/camitune-speaker-eq"
    chmod 755 "$1/Helpers/camitune-speaker-eq"
fi
