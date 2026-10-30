#!/bin/sh
# Builds MonitorInput.app, installs it into ~/Applications, enables launch at login and starts it.
# The CLI is linked as ~/bin/monitor-input. Undo: ./uninstall.sh
set -e
cd "$(dirname "$0")"
./build.sh

DEST="$HOME/Applications/MonitorInput.app"

# Earlier installs: a bare ~/bin/monitor-input started by a LaunchAgent.
OLD_PLIST="$HOME/Library/LaunchAgents/com.user.monitor-input.plist"
if [ -f "$OLD_PLIST" ]; then
    launchctl bootout "gui/$(id -u)/com.user.monitor-input" 2>/dev/null || true
    rm -f "$OLD_PLIST"
fi
pkill -f "monitor-input tray" 2>/dev/null || true
pkill -f "MonitorInput.app/Contents/MacOS/monitor-input" 2>/dev/null || true

mkdir -p "$HOME/Applications" "$HOME/bin"
rm -rf "$DEST"
cp -R MonitorInput.app "$DEST"
ln -sf "$DEST/Contents/MacOS/monitor-input" "$HOME/bin/monitor-input"

"$DEST/Contents/MacOS/monitor-input" login-item on
open "$DEST"
echo "Installed $DEST. Hotkeys config: ~/.config/monitor-input.conf"
