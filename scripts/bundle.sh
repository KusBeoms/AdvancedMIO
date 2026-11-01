#!/bin/bash
# Builds build/AdvancedMIO.app (macOS only).  Usage: scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AdvancedMIO"

APP=build/AdvancedMIO.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AdvancedMIO"
cp resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Virtual audio device (AudioServerPlugIn). Installed into /Library/Audio/Plug-Ins/HAL by the app or scripts/install-driver.sh.
DRV="$APP/Contents/Resources/AdvancedMIO.driver"
mkdir -p "$DRV/Contents/MacOS"
clang -bundle -O2 -Wall -Wno-unused-parameter -arch arm64 -arch x86_64 \
    -framework CoreFoundation -framework CoreAudio \
    -o "$DRV/Contents/MacOS/AdvancedMIODriver" driver/AdvancedMIODriver.c
cp driver/Info.plist "$DRV/Contents/Info.plist"
codesign --force --sign - "$DRV"

codesign --force --sign - --entitlements resources/AdvancedMIO.entitlements "$APP"
echo "Built $APP"
