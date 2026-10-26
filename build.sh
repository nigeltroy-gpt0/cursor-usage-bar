#!/bin/bash
# Builds "Cursor Usage Bar.app".
#   --install  copy it to /Applications and launch it
#   --dmg      also package build/cursor-usage-bar.dmg (drag-to-Applications installer)
set -euo pipefail
cd "$(dirname "$0")"

EXEC_NAME="CursorUsageBar"          # SwiftPM product / binary name
APP_NAME="Cursor Usage Bar"         # user-facing .app name
DMG_NAME="cursor-usage-bar.dmg"
APP="build/$APP_NAME.app"
if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
    VERSION="${VERSION:-0.0.0}"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXEC_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.local.cursorusagebar</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$EXEC_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications and launched"
fi

if [[ "${1:-}" == "--dmg" ]]; then
    DMG="build/$DMG_NAME"
    STAGING="build/dmg"
    rm -rf "$STAGING" "$DMG"
    mkdir -p "$STAGING"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGING"
    echo "Packaged $DMG"
fi
