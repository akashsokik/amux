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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

# Copy app icon
if [ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/"
fi

# Copy Ghostty shell integration resources (enables OSC 7/133 for all shells)
GHOSTTY_RES="$RESOURCES_DIR/ghostty/shell-integration"
mkdir -p "$GHOSTTY_RES"
SHELL_INTEG_SRC="$SCRIPT_DIR/vendor/ghostty-dist/shell-integration"
for shell_dir in bash zsh fish elvish nushell; do
    if [ -d "$SHELL_INTEG_SRC/$shell_dir" ]; then
        cp -R "$SHELL_INTEG_SRC/$shell_dir" "$GHOSTTY_RES/"
    fi
done

# Copy amux shell integration scripts (status indicators for sidebar)
AMUX_SHELL_INTEG="$RESOURCES_DIR/shell-integration"
mkdir -p "$AMUX_SHELL_INTEG"
AMUX_SHELL_SRC="$SCRIPT_DIR/Resources/shell-integration"
if [ -d "$AMUX_SHELL_SRC" ]; then
    cp -R "$AMUX_SHELL_SRC"/* "$AMUX_SHELL_INTEG/"
fi

# Copy agent hook scripts (claude wrapper + hook helper)
AGENT_HOOKS_SRC="$SCRIPT_DIR/Resources/agent-hooks"
AGENT_HOOKS_DST="$RESOURCES_DIR/agent-hooks"
if [ -d "$AGENT_HOOKS_SRC" ]; then
    mkdir -p "$AGENT_HOOKS_DST"
    cp -R "$AGENT_HOOKS_SRC"/* "$AGENT_HOOKS_DST/"
    chmod +x "$AGENT_HOOKS_DST"/*
fi

# Copy terminfo sentinel (helps Ghostty auto-detect resources dir)
TERMINFO_SRC="$SCRIPT_DIR/vendor/ghostty-dist/terminfo"
if [ -d "$TERMINFO_SRC" ]; then
    cp -R "$TERMINFO_SRC" "$RESOURCES_DIR/"
fi

echo "Built amux.app"

# Launch (pass current PATH so Homebrew binaries like starship are found)
open --env PATH="$PATH" "$APP_DIR"
