#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build
BIN_DIR="$(swift build --show-bin-path)"
APP=".build/RevealLab.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/RevealLab" "$APP/Contents/MacOS/RevealLab"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RevealLab</string>
<key>CFBundleIdentifier</key><string>dev.onetime.reveal-lab</string>
<key>CFBundleName</key><string>Reveal Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ "${1:-}" = "--build-only" ]; then
    printf 'Built %s\n' "$APP"
else
    open "$APP"
fi
