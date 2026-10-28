#!/bin/zsh
# Builds Seek.app, signs it with a stable identity, installs to ~/Applications, launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Seek.app
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Seek "$APP/Contents/MacOS/Seek"
cp Info.plist "$APP/Contents/Info.plist"

# Stable signature so macOS remembers folder-access grants across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --options runtime --entitlements Seek.entitlements --sign "${IDENTITY:--}" "$APP"

mkdir -p ~/Applications
pkill -x Seek 2>/dev/null || true
rm -rf ~/Applications/Seek.app
cp -R "$APP" ~/Applications/
open ~/Applications/Seek.app
echo "Installed and launched ~/Applications/Seek.app  (hotkey: ⌥Space)"
