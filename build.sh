#!/bin/zsh
# Builds TwoUp.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/TwoUp.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ ! -f Resources/TwoUp.icns ]]; then
  swiftc -O make_icon.swift -o build/make_icon
  ./build/make_icon build/icon.png
  mkdir -p build/TwoUp.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out build/TwoUp.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out build/TwoUp.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/TwoUp.iconset -o Resources/TwoUp.icns
fi

swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/TwoUp" -framework Cocoa -framework WebKit
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/* "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

DEST="$HOME/Applications/TwoUp.app"
if [[ -d "$DEST" ]]; then trash "$DEST"; fi
cp -R "$APP" "$DEST"
echo "Installed $DEST"
