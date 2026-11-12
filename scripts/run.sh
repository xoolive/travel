#!/bin/sh
# Build the package, wrap the binary in a minimal .app bundle and launch it.
set -e
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
APP="build/Travel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/* "$APP/Contents/Resources/"
cp "$(swift build -c "$CONFIG" --show-bin-path)/Travel" "$APP/Contents/MacOS/Travel"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Travel</string>
    <key>CFBundleDisplayName</key><string>Travel</string>
    <key>CFBundleIdentifier</key><string>local.travel.app</string>
    <key>CFBundleExecutable</key><string>Travel</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Decoded recording</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>jsonl</string><string>zst</string><string>7z</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
# Extra arguments are recordings to load at launch (absolute paths).
[ -n "$NO_OPEN" ] || open "$APP" --args "$@"
