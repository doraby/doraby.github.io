#!/bin/bash
# Builds TaskTimeTracker.app so macOS permissions (Screen Recording) attach to
# the app itself rather than to your terminal. Run on your Mac:
#   cd timetracker && ./build-app.sh
#
# Compiles directly with swiftc (no `swift build` / Package.swift manifest
# involved) because some Command Line Tools-only installations fail to link
# the SwiftPM manifest compiler itself (a toolchain bug, unrelated to this
# app). This path only needs swiftc + the macOS SDK, which is more reliable.
set -euo pipefail
cd "$(dirname "$0")"

APP=TaskTimeTracker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

SDK=$(xcrun --sdk macosx --show-sdk-path)
ARCH=$(uname -m)   # arm64 on Apple Silicon, x86_64 on Intel Macs
swiftc -O \
    -sdk "$SDK" \
    -target "${ARCH}-apple-macosx13.0" \
    -framework AppKit \
    -framework SwiftUI \
    Sources/TaskTimeTracker/*.swift \
    -o "$APP/Contents/MacOS/TaskTimeTracker"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TaskTimeTracker</string>
    <key>CFBundleIdentifier</key><string>local.tasktimetracker</string>
    <key>CFBundleName</key><string>TaskTimeTracker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

echo "Built $PWD/$APP"
echo "Move it to /Applications and launch it, e.g.:"
echo "  mv -f $APP /Applications/ && open /Applications/$APP"
