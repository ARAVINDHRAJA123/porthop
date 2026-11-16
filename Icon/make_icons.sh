#!/bin/bash
# Makes the Mac (AppIcon.icns) and Windows (windows/icon.ico) icon files from Icon/PortHop-1024.png.
# To change the icon: replace Icon/source-chatgpt.png, run
#   swift Icon/prepare_icon.swift Icon/source-chatgpt.png Icon/PortHop-1024.png
# then run this script.
set -euo pipefail
cd "$(dirname "$0")/.."
M=Icon/PortHop-1024.png
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir "$T/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$M" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$M" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/AppIcon.iconset" -o AppIcon.icns
for s in 16 24 32 48 256; do sips -z $s $s "$M" --out "$T/w$s.png" >/dev/null; done
python3 - "$T" <<'PY'
import struct, sys
d, sizes = sys.argv[1], [16, 24, 32, 48, 256]
data = [open(f"{d}/w{s}.png", "rb").read() for s in sizes]
off, entries = 6 + 16 * len(sizes), b""
for s, b in zip(sizes, data):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), off); off += len(b)
open("windows/icon.ico", "wb").write(struct.pack("<HHH", 0, 1, len(sizes)) + entries + b"".join(data))
PY
cp "$M" screenshots/icon.png
echo "Made AppIcon.icns and windows/icon.ico"
