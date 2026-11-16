#!/bin/bash
# Builds "iPhone Album Extractor 2.app" next to this script. Does not touch any other app.
set -euo pipefail
cd "$(dirname "$0")"
APP="iPhone Album Extractor 2.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -parse-as-library \
  Sources/*.swift -lsqlite3 -o "$APP/Contents/MacOS/iPhoneAlbumExtractor"
cp Info.plist "$APP/Contents/Info.plist"
if [ ! -f AppIcon.icns ]; then
  swift make_icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset
fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p build
clang -O2 -arch arm64 -I/opt/homebrew/include -L/opt/homebrew/lib Helpers/applist.c -limobiledevice-1.0 -lplist-2.0 -o build/applist
python3 bundle_tools.py "$APP"
mkdir -p "$APP/Contents/Resources/Licenses" && cp Licenses/* "$APP/Contents/Resources/Licenses/"
codesign --force --deep --sign - "$APP"
# Keep the copy in Applications current, unless that copy is open right now.
if ! pgrep -f "/Applications/$APP/Contents/MacOS" >/dev/null; then
  rm -rf "/Applications/$APP" && ditto "$APP" "/Applications/$APP" && echo "Installed to /Applications"
fi
echo "Built $APP"
