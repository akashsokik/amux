#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Build
swift build 2>&1

# Create .app bundle
APP_DIR="$SCRIPT_DIR/.build/amux.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy binary
cp .build/debug/amux "$MACOS_DIR/amux"

# Write Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>amux</string>
    <key>CFBundleIdentifier</key>
    <string>com.amux.app</string>
    <key>CFBundleName</key>
    <string>amux</string>
    <key>CFBundleDisplayName</key>
    <string>amux</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Copy Ghostty shell integration resources (enables OSC 7/133 for all shells)
GHOSTTY_RES="$RESOURCES_DIR/ghostty/shell-integration"
mkdir -p "$GHOSTTY_RES"
SHELL_INTEG_SRC="$SCRIPT_DIR/vendor/ghostty-dist/shell-integration"
for shell_dir in bash zsh fish elvish nushell; do
    if [ -d "$SHELL_INTEG_SRC/$shell_dir" ]; then
        cp -R "$SHELL_INTEG_SRC/$shell_dir" "$GHOSTTY_RES/"
    fi
done

# Copy terminfo sentinel (helps Ghostty auto-detect resources dir)
TERMINFO_SRC="$SCRIPT_DIR/vendor/ghostty-dist/terminfo"
if [ -d "$TERMINFO_SRC" ]; then
    cp -R "$TERMINFO_SRC" "$RESOURCES_DIR/"
fi

echo "Built amux.app"

# Launch
open "$APP_DIR"
