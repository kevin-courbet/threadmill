#!/bin/bash

set -euo pipefail

APP_NAME="Threadmill"
BUILD_DIR=".build/debug"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
APPICON_SOURCE_DIR="Resources/Assets.xcassets/AppIcon.appiconset"

rm -rf "$APP_DIR" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cp "$APPICON_SOURCE_DIR/icon_16x16.png" "$ICONSET_DIR/icon_16x16.png"
cp "$APPICON_SOURCE_DIR/icon_16x16@2x.png" "$ICONSET_DIR/icon_16x16@2x.png"
cp "$APPICON_SOURCE_DIR/icon_32x32.png" "$ICONSET_DIR/icon_32x32.png"
cp "$APPICON_SOURCE_DIR/icon_32x32@2x.png" "$ICONSET_DIR/icon_32x32@2x.png"
cp "$APPICON_SOURCE_DIR/icon_128x128.png" "$ICONSET_DIR/icon_128x128.png"
cp "$APPICON_SOURCE_DIR/icon_128x128@2x.png" "$ICONSET_DIR/icon_128x128@2x.png"
cp "$APPICON_SOURCE_DIR/icon_256x256.png" "$ICONSET_DIR/icon_256x256.png"
cp "$APPICON_SOURCE_DIR/icon_256x256@2x.png" "$ICONSET_DIR/icon_256x256@2x.png"
cp "$APPICON_SOURCE_DIR/icon_512x512.png" "$ICONSET_DIR/icon_512x512.png"
cp "$APPICON_SOURCE_DIR/icon_512x512@2x.png" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Threadmill</string>
    <key>CFBundleExecutable</key>
    <string>Threadmill</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.threadmill.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Threadmill</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

rm -rf "$ICONSET_DIR"
