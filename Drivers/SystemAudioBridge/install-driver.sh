#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
PACKAGE="${SABR_BUILD_ROOT:-$REPO_ROOT/build/driver}/CamillaAudio-${SABR_DRIVER_VERSION:-0.8.2}.pkg"

if [[ ! -f "$PACKAGE" ]]; then
    "$SCRIPT_DIR/package-driver.sh"
fi

print "Installing System Audio Bridge requires an administrator password."
/usr/bin/sudo /usr/sbin/installer -pkg "$PACKAGE" -target /
