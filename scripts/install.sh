#!/bin/bash
# Build, install to /Applications, link the `screenoff` CLI, and launch the menu bar app.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

# Quitting turns any disabled displays back on, so a reinstall never strands a dark monitor.
osascript -e 'quit app "ScreenOff"' 2>/dev/null || true
sleep 1

rm -rf /Applications/ScreenOff.app
cp -R build/ScreenOff.app /Applications/

if [ -w /opt/homebrew/bin ]; then BIN_DIR=/opt/homebrew/bin; else BIN_DIR=/usr/local/bin; fi
ln -sf /Applications/ScreenOff.app/Contents/MacOS/ScreenOff "$BIN_DIR/screenoff"
echo "Linked $BIN_DIR/screenoff"

open /Applications/ScreenOff.app
echo "ScreenOff is running in the menu bar."
