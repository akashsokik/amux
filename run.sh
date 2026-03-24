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

# Copy SPM resource bundles (tree-sitter grammars, fonts, etc.)
for bundle in .build/debug/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$RESOURCES_DIR/"
done

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

# Inject amux zsh sourcing into Ghostty's .zshenv so it auto-loads in every zsh session
GHOSTTY_ZSHENV="$GHOSTTY_RES/zsh/.zshenv"
if [ -f "$GHOSTTY_ZSHENV" ]; then
    cat >> "$GHOSTTY_ZSHENV" << 'ZSHEOF'

# -- amux shell integration (injected by build) --
if [[ -n "$AMUX_ZSH_SCRIPT" && -r "$AMUX_ZSH_SCRIPT" ]]; then
    'builtin' 'source' '--' "$AMUX_ZSH_SCRIPT"
fi
ZSHEOF
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

# Inject Claude Code hooks into global settings so amux receives agent lifecycle events
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOOK_SCRIPT="$AGENT_HOOKS_DST/amux-agent-hook.sh"
if [ -f "$HOOK_SCRIPT" ]; then
    mkdir -p "$HOME/.claude"
    if [ -f "$CLAUDE_SETTINGS" ]; then
        # Check if hooks already configured
        if ! grep -q "amux-agent-hook" "$CLAUDE_SETTINGS" 2>/dev/null; then
            python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS') as f:
    settings = json.load(f)
hook_entry = {'matcher': '', 'hooks': [{'type': 'command', 'command': '$HOOK_SCRIPT', 'timeout': 5}]}
hooks = settings.get('hooks', {})
for event in ['PreToolUse', 'PostToolUse', 'Stop', 'Notification', 'PermissionRequest', 'UserPromptSubmit']:
    existing = hooks.get(event, [])
    existing.append(hook_entry)
    hooks[event] = existing
settings['hooks'] = hooks
with open('$CLAUDE_SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" && echo "Configured Claude Code hooks -> $HOOK_SCRIPT"
        fi
    else
        # Create settings.json with just hooks
        python3 -c "
import json
hook_entry = {'matcher': '', 'hooks': [{'type': 'command', 'command': '$HOOK_SCRIPT', 'timeout': 5}]}
settings = {'hooks': {event: [hook_entry] for event in ['PreToolUse', 'PostToolUse', 'Stop', 'Notification', 'PermissionRequest', 'UserPromptSubmit']}}
with open('$CLAUDE_SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" && echo "Created Claude Code settings with hooks -> $HOOK_SCRIPT"
    fi
fi

echo "Built amux.app"

# Launch (pass current PATH so Homebrew binaries like starship are found)
open --env PATH="$PATH" "$APP_DIR"
