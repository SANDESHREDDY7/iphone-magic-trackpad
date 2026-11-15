#!/bin/bash
SERVICE_NAME="com.magictrackpad.server"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist"

if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "✅ Magic Trackpad background service uninstalled."
else
    echo "Service is not installed."
fi
