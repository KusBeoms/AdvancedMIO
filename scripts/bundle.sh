#!/bin/bash
# Builds AdvancedMIO.app (macOS only). Usage: scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/AdvancedMIO.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/AdvancedMIO "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>AdvancedMIO</string>
<key>CFBundleIdentifier</key><string>com.kusbeoms.advancedmio</string>
<key>CFBundleExecutable</key><string>AdvancedMIO</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSMicrophoneUsageDescription</key><string>입력 장치의 오디오를 출력 장치로 전달하기 위해 필요합니다.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP"
echo "Built $APP"
