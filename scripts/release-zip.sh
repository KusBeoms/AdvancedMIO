#!/bin/bash
# Builds the app and packs dist/AdvancedMIO-<version>.zip for a GitHub release.
# The release tag must be v<version> (e.g. v0.3.0): the in-app updater compares the tag with CFBundleShortVersionString.
# Usage: scripts/release-zip.sh
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/AdvancedMIO.app/Contents/Info.plist)
mkdir -p dist
ZIP="dist/AdvancedMIO-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/AdvancedMIO.app "$ZIP"
echo "Packed $ZIP  → upload it to a release tagged v$VERSION"
