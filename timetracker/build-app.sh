#!/bin/bash
# Builds TaskTimeTracker.app so macOS permissions (Screen Recording) attach to
# the app itself rather than to your terminal. Run on your Mac:
#   cd timetracker && ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=TaskTimeTracker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/TaskTimeTracker "$APP/Contents/MacOS/"

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
