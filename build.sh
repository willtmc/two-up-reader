#!/usr/bin/env bash
# Builds TwoUp.app and (unless --build-only is passed) installs it to ~/Applications.
set -euo pipefail

BUILD_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      BUILD_ONLY=true
      shift
      ;;
    -h|--help)
      echo "Usage: ./build.sh [--build-only]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: ./build.sh [--build-only]" >&2
      exit 1
      ;;
  esac
done

cd "$(dirname "${BASH_SOURCE[0]}")"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/TwoUp.app"

plutil -lint Info.plist >/dev/null

rm -rf build/TwoUp.app build/TwoUp.icns build/TwoUp.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift make_icon.swift build/TwoUp.icns

SWIFT_SOURCES=(main.swift)
if [[ -f Core.swift ]]; then
  SWIFT_SOURCES=(Core.swift main.swift)
fi

swiftc -O -swift-version 5 "${SWIFT_SOURCES[@]}" -o "$APP/Contents/MacOS/TwoUp" -framework Cocoa -framework WebKit

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/* "$APP/Contents/Resources/"
cp build/TwoUp.icns "$APP/Contents/Resources/TwoUp.icns"

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

if [[ "$BUILD_ONLY" == "true" ]]; then
  echo "Built $APP"
  exit 0
fi

mkdir -p "$HOME/Applications"
DEST="$HOME/Applications/TwoUp.app"
if [[ -d "$DEST" ]]; then
  if command -v trash >/dev/null 2>&1; then
    trash "$DEST"
  else
    rm -rf "$DEST"
  fi
fi
cp -R "$APP" "$DEST"
echo "Installed $DEST"
