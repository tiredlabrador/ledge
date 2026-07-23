#!/bin/zsh
# Build Ledge and install it to ~/Applications/Ledge.app
set -e
cd "$(dirname "$0")"

swift build -c release

APP="$HOME/Applications/Ledge.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/Ledge "$APP/Contents/MacOS/Ledge"
codesign --force --sign - "$APP"
echo "Built and installed: $APP"
