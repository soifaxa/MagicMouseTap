#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MagicMouseTap"
BUNDLE="$ROOT/build/${APP_NAME}.app"
MACOS_DIR="$BUNDLE/Contents/MacOS"
RESOURCES_DIR="$BUNDLE/Contents/Resources"
SRC="$ROOT/Sources"
MIN_MACOS="13.0"

# Detect architecture for a native build; override with ARCH=arm64|x86_64|universal
ARCH="${ARCH:-$(uname -m)}"

echo "==> Building Magic Mouse Tap ($ARCH)"

rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

compile() {
  local target="$1"
  local output="$2"
  swiftc \
    -O \
    -target "${target}-apple-macos${MIN_MACOS}" \
    -import-objc-header "$SRC/BridgingHeader.h" \
    -F /System/Library/PrivateFrameworks \
    -framework MultitouchSupport \
    -framework Cocoa \
    -framework ApplicationServices \
    -o "$output" \
    "$SRC/main.swift" \
    "$SRC/AppDelegate.swift" \
    "$SRC/TouchManager.swift"
}

BINARY="$MACOS_DIR/$APP_NAME"

if [[ "$ARCH" == "universal" ]]; then
  compile "arm64" "$MACOS_DIR/${APP_NAME}-arm64"
  compile "x86_64" "$MACOS_DIR/${APP_NAME}-x86_64"
  lipo -create \
    "$MACOS_DIR/${APP_NAME}-arm64" \
    "$MACOS_DIR/${APP_NAME}-x86_64" \
    -output "$BINARY"
  rm -f "$MACOS_DIR/${APP_NAME}-arm64" "$MACOS_DIR/${APP_NAME}-x86_64"
else
  compile "$ARCH" "$BINARY"
fi

cp "$ROOT/Info.plist" "$BUNDLE/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Ad-hoc sign so Accessibility permissions stick to a stable identity.
codesign --force --deep --sign - "$BUNDLE"

echo "==> Built: $BUNDLE"
echo ""
echo "Next steps:"
echo "  1. open \"$BUNDLE\""
echo "  2. Enable the app in System Settings → Privacy & Security → Accessibility"
echo "  3. Tap the Magic Mouse surface to click"
echo ""
echo "Optional: cp -R \"$BUNDLE\" /Applications/"
