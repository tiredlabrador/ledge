#!/bin/zsh
# Build a UNIVERSAL (Apple Silicon + Intel) Ledge.app and zip it for release.
# Output: dist/Ledge.app and dist/Ledge.zip
set -e
cd "$(dirname "$0")"

SRC=(Sources/Ledge/*.swift)
mkdir -p dist build-tmp

echo "Compiling arm64…"
swiftc -O -swift-version 5 -target arm64-apple-macosx15.0 $SRC -o build-tmp/ledge-arm64
echo "Compiling x86_64…"
swiftc -O -swift-version 5 -target x86_64-apple-macosx15.0 $SRC -o build-tmp/ledge-x86
echo "Merging into a universal binary…"
lipo -create -output build-tmp/ledge-universal build-tmp/ledge-arm64 build-tmp/ledge-x86

APP="dist/Ledge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp build-tmp/ledge-universal "$APP/Contents/MacOS/Ledge"
[ -f Ledge.icns ] && cp Ledge.icns "$APP/Contents/Resources/Ledge.icns"
codesign --force --sign - "$APP"

echo "Zipping…"
rm -f dist/Ledge.zip
ditto -c -k --keepParent "$APP" dist/Ledge.zip

rm -rf build-tmp
lipo -info "$APP/Contents/MacOS/Ledge"
echo "Done → dist/Ledge.zip"
