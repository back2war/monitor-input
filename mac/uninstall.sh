#!/bin/sh
# Reverses install.sh. The hotkeys config (~/.config/monitor-input.conf) is kept.
DEST="$HOME/Applications/MonitorInput.app"
[ -x "$DEST/Contents/MacOS/monitor-input" ] && "$DEST/Contents/MacOS/monitor-input" login-item off
pkill -f "MonitorInput.app/Contents/MacOS/monitor-input" 2>/dev/null
rm -rf "$DEST"
[ -L "$HOME/bin/monitor-input" ] && rm "$HOME/bin/monitor-input"
echo "Removed $DEST"
