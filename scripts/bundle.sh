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

codesign --force --sign - --entitlements resources/AdvancedMIO.entitlements "$APP"
echo "Built $APP"
