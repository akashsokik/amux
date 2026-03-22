#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHOSTTY_DIR="${SCRIPT_DIR}/vendor/ghostty"
OUTPUT_DIR="${SCRIPT_DIR}/lib"

echo "=== Building libghostty for amux ==="

# Check for Zig
if ! command -v zig &> /dev/null; then
    echo "Error: Zig compiler not found. Install via: brew install zig"
    exit 1
fi

# Clone or update Ghostty
if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "Cloning Ghostty..."
    mkdir -p "${SCRIPT_DIR}/vendor"
    git clone https://github.com/ghostty-org/ghostty.git "$GHOSTTY_DIR"
else
    echo "Updating Ghostty..."
    cd "$GHOSTTY_DIR" && git pull
fi

# Build libghostty
echo "Building libghostty..."
cd "$GHOSTTY_DIR"
zig build lib -Doptimize=ReleaseFast

# Copy outputs
mkdir -p "$OUTPUT_DIR"
cp zig-out/lib/libghostty.a "$OUTPUT_DIR/" 2>/dev/null || true
cp zig-out/lib/libghostty.dylib "$OUTPUT_DIR/" 2>/dev/null || true

# Copy headers
mkdir -p "${SCRIPT_DIR}/Sources/CGhostty/include"
cp include/ghostty.h "${SCRIPT_DIR}/Sources/CGhostty/include/" 2>/dev/null || true

echo "=== Build complete ==="
echo "Library: ${OUTPUT_DIR}/"
echo "Headers: ${SCRIPT_DIR}/Sources/CGhostty/include/"
