#!/bin/bash
set -euo pipefail

# Build script for HostSwitch macOS Menu Bar app
#
# Produces a universal binary (Apple silicon + Intel). macOS 27 no longer
# ships Rosetta for ordinary apps, so an Intel-only build cannot launch there.

APP="HostSwitch.app"
BIN_DIR="$APP/Contents/MacOS"
BUILD_DIR=".build"
SOURCES="main.swift HostSwitch.swift"
FRAMEWORKS="-framework SwiftUI -framework Foundation -framework AppKit"
MIN_MACOS="11.0"

echo "Building HostSwitch Menu Bar Utility..."

mkdir -p "$BIN_DIR" "$BUILD_DIR"

for ARCH in arm64 x86_64; do
    echo "  • Compiling $ARCH slice"
    swiftc -parse-as-library -o "$BUILD_DIR/HostSwitch-$ARCH" $SOURCES \
        $FRAMEWORKS \
        -target "$ARCH-apple-macos$MIN_MACOS"
done

lipo -create -output "$BIN_DIR/HostSwitch" \
    "$BUILD_DIR/HostSwitch-arm64" \
    "$BUILD_DIR/HostSwitch-x86_64"

# Apple silicon refuses to run unsigned code. An ad-hoc signature is enough
# for a locally built app.
codesign --force --sign - "$APP"

echo "✅ Build successful!"
echo "📁 Menu bar app created at: $APP ($(lipo -archs "$BIN_DIR/HostSwitch"))"
echo ""
echo "To run the app:"
echo "  open $APP"
echo ""
echo "📋 Usage:"
echo "  • The app will appear in your menu bar with a network icon"
echo "  • Click the icon to view and toggle hosts entries"
echo "  • Only manages entries in the dedicated section marked with:"
echo "    ####### HostSwitchStart"
echo "    ####### HostSwitchEnd"
echo ""
echo "🔒 Note: The app will request administrator privileges when modifying /etc/hosts"
echo "      This is required by macOS for system file security"
