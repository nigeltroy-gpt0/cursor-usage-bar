#!/bin/bash
# Builds the app. By default this is a TEST build, "(Test) Cursor Usage Bar.app", with its own
# bundle ID, process name and settings, so it never touches an installed main-line copy.
#   --release  build the real "Cursor Usage Bar.app" (what CI ships)
#   --run      launch the built app from build/ (quits only a running copy of the same variant)
#   --install  copy it to /Applications and launch it (replaces only the same variant)
#   --dmg      also package a drag-to-Applications DMG in build/
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0 RUN=0 INSTALL=0 DMG=0
for arg in "$@"; do
    case "$arg" in
        --release) RELEASE=1 ;;
        --run) RUN=1 ;;
        --install) INSTALL=1 ;;
        --dmg) DMG=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

PRODUCT="CursorUsageBar"            # SwiftPM product / binary name
if [[ $RELEASE == 1 ]]; then
    APP_NAME="Cursor Usage Bar"
    EXEC_NAME="CursorUsageBar"
    BUNDLE_ID="com.local.cursorusagebar"
    DMG_NAME="cursor-usage-bar.dmg"
    TEST_BUILD="<false/>"
else
    APP_NAME="(Test) Cursor Usage Bar"
    EXEC_NAME="CursorUsageBarTest"
    BUNDLE_ID="com.local.cursorusagebar.test"
    DMG_NAME="cursor-usage-bar-test.dmg"
    TEST_BUILD="<true/>"
fi
APP="build/$APP_NAME.app"
if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
    VERSION="${VERSION:-0.0.0}"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$PRODUCT"

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
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>CUBTestBuild</key>$TEST_BUILD
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ $INSTALL == 1 ]]; then
    pkill -x "$EXEC_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications and launched"
elif [[ $RUN == 1 ]]; then
    pkill -x "$EXEC_NAME" 2>/dev/null && sleep 1 || true
    open "$APP"
    echo "Launched $APP"
fi

if [[ $DMG == 1 ]]; then
    DMG_PATH="build/$DMG_NAME"
    STAGING="build/dmg"
    rm -rf "$STAGING" "$DMG_PATH"
    mkdir -p "$STAGING"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
    rm -rf "$STAGING"
    echo "Packaged $DMG_PATH"
fi
