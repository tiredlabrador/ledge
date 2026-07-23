#!/bin/zsh
# Regenerate Ledge.icns from a full-bleed square source PNG.
# Applies the macOS squircle mask + padding + shadow, then builds the .icns.
# Usage: ./make-icon.sh [source.png]   (defaults to Icon/source.png)
set -e
cd "$(dirname "$0")"

IN="${1:-Icon/source.png}"
[ -f "$IN" ] || { echo "source not found: $IN"; exit 1; }

swift make-icon.swift "$IN" /tmp/ledge-master.png

rm -rf /tmp/Ledge.iconset && mkdir -p /tmp/Ledge.iconset
S=("16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
   "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
   "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x")
for pair in "${S[@]}"; do
  set -- ${=pair}
  sips -z $1 $1 /tmp/ledge-master.png --out "/tmp/Ledge.iconset/$2.png" >/dev/null
done

iconutil -c icns /tmp/Ledge.iconset -o Ledge.icns
echo "Wrote Ledge.icns"
