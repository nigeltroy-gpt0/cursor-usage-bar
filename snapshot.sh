#!/bin/bash
# Renders the dropdown (main + settings) and history window to build/snapshots/*.png,
# using stub data, in light and dark mode. No app launch, no Keychain, no network.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/snapshots"
WORK="build/snapshot-tool"
mkdir -p "$OUT" "$WORK"

# Embed a test-build Info.plist so the tool runs in stub-data mode, like a test build.
cat > "$WORK/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.local.cursorusagebar.snapshot</string>
    <key>CFBundleShortVersionString</key><string>$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)</string>
    <key>CUBTestBuild</key><true/>
</dict></plist>
PLIST

SOURCES=$(ls Sources/CursorUsageBar/*.swift | grep -v CursorUsageBarApp.swift)
swiftc -O -parse-as-library -o "$WORK/snapshot" Tools/Snapshot/main.swift $SOURCES -lsqlite3 \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$WORK/Info.plist"
"$WORK/snapshot" "$OUT"
