#!/bin/bash
# Builds "PortHop.app" next to this script. Does not touch any other app.
set -euo pipefail
cd "$(dirname "$0")"
APP="PortHop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -parse-as-library \
  Sources/*.swift -lsqlite3 -o "$APP/Contents/MacOS/PortHop"
# The porthop command line: the same engine, in Helpers (next to the tools it drives).
mkdir -p "$APP/Contents/Helpers"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 Sources/Models.swift Sources/Device.swift Sources/Catalog.swift Sources/Exporter.swift \
  Sources/Backup.swift Sources/Android.swift Sources/LocationScrubber.swift CLI/main.swift -lsqlite3 -o "$APP/Contents/Helpers/porthop"
cp Info.plist "$APP/Contents/Info.plist"
if [ ! -f AppIcon.icns ]; then Icon/make_icons.sh; fi
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The iPhone tools are built from the official source for macOS 13 and later (cached after the first run).
python3 build_tools.py
mkdir -p "$APP/Contents/Helpers" && cp build/tools-mac/bin/* "$APP/Contents/Helpers/"
L="$APP/Contents/Resources/Licenses"
mkdir -p "$L" && cp -R build/tools-mac/licenses/* "$L/" && cp build/tools-mac/SOURCES.txt "$L/" && cp LICENSE "$L/PortHop-LICENSE.txt"
codesign --force --deep --sign - "$APP"
# With --install, also copy it into Applications (skipped while that copy is open).
if [ "${1:-}" = "--install" ]; then
  if pgrep -f "/Applications/$APP/Contents/MacOS" >/dev/null; then echo "PortHop is open: quit it, then run ./build.sh --install again."
  else rm -rf "/Applications/$APP" && ditto "$APP" "/Applications/$APP" && rm -rf "$APP" && echo "Installed to /Applications (build copy removed, so only one PortHop exists)"; fi
fi
echo "Built $APP"
