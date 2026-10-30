#!/bin/sh
# Installs monitor-input into ~/bin and starts the menu bar agent at login (LaunchAgent).
# Uninstall: launchctl bootout gui/$(id -u)/com.user.monitor-input; rm ~/Library/LaunchAgents/com.user.monitor-input.plist
set -e
cd "$(dirname "$0")"
[ -x ./monitor-input ] || ./build.sh

mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents"
cp ./monitor-input "$HOME/bin/monitor-input"

PLIST="$HOME/Library/LaunchAgents/com.user.monitor-input.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.user.monitor-input</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/bin/monitor-input</string>
        <string>tray</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardErrorPath</key><string>/tmp/monitor-input.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/com.user.monitor-input" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Hotkeys config: ~/.config/monitor-input.conf"
