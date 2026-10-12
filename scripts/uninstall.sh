#!/bin/bash
# Remove ScreenOff.app, the CLI link, and saved state.
set -euo pipefail

osascript -e 'quit app "ScreenOff"' 2>/dev/null || true
rm -rf /Applications/ScreenOff.app
rm -f /opt/homebrew/bin/screenoff /usr/local/bin/screenoff
rm -rf "$HOME/Library/Application Support/ScreenOff"
echo "ScreenOff removed."
