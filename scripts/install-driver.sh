#!/bin/bash
# Installs (or with --uninstall removes) the AdvancedMIO virtual audio device and restarts coreaudiod.
# Usage: scripts/install-driver.sh [path/to/AdvancedMIO.driver] | --uninstall      (asks for your password)
set -euo pipefail
DEST=/Library/Audio/Plug-Ins/HAL/AdvancedMIO.driver
if [ "${1:-}" = "--uninstall" ]; then
    sudo rm -rf "$DEST"
else
    SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/AdvancedMIO.app/Contents/Resources/AdvancedMIO.driver}"
    [ -d "$SRC" ] || { echo "driver not found: $SRC (run scripts/bundle.sh first)"; exit 1; }
    sudo rm -rf "$DEST"
    sudo cp -R "$SRC" "$DEST"
    sudo chown -R root:wheel "$DEST"
fi
sudo killall coreaudiod || true      # launchd restarts it; the new device appears in a few seconds
echo "done"
