#!/bin/bash
# Magic Trackpad Pro - macOS Background Service Installer

SERVICE_NAME="com.magictrackpad.server"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist"
NODE_PATH=$(which node)
SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/server.js"
LOG_DIR="$HOME/Library/Logs/MagicTrackpad"

mkdir -p "$LOG_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

# Unload existing if running
launchctl unload "$PLIST_PATH" 2>/dev/null || true

cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${NODE_PATH}</string>
        <string>${SCRIPT_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/server.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/server.err.log</string>
    <key>WorkingDirectory</key>
    <string>$(cd "$(dirname "$0")/.." && pwd)</string>
</dict>
</plist>
EOF

launchctl load "$PLIST_PATH"

echo "✅ Magic Trackpad background service installed and running!"
echo "👉 The companion server will now automatically start every time you log in to your Mac."
echo "📋 Logs available at: ${LOG_DIR}/server.log"
