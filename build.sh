#!/bin/bash
# Usage: ./build.sh            build build/MDEdit.app
#        ./build.sh install    also copy it to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MDEdit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/MDEdit" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    rm -rf /Applications/MDEdit.app
    cp -R "$APP" /Applications/MDEdit.app
    echo "Installed /Applications/MDEdit.app"
fi
