#!/bin/bash
# ==============================================================================
# Magic Trackpad Pro - macOS .app & .dmg Packaging Script
# ==============================================================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${PROJECT_DIR}/dist"
APP_NAME="Magic Trackpad"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
DMG_NAME="MagicTrackpad-macOS.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
DMG_TEMP="${DIST_DIR}/dmg_temp"

echo "🔨 Building macOS App Bundle and DMG..."

# 1. Clean previous build
rm -rf "${APP_DIR}" "${DMG_PATH}" "${DMG_TEMP}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources/app"

# 2. Copy application files
echo "📦 Copying server & web assets..."
cp "${PROJECT_DIR}/server.js" "${APP_DIR}/Contents/Resources/app/"
cp "${PROJECT_DIR}/package.json" "${APP_DIR}/Contents/Resources/app/"
cp -R "${PROJECT_DIR}/public" "${APP_DIR}/Contents/Resources/app/"
cp -R "${PROJECT_DIR}/node_modules" "${APP_DIR}/Contents/Resources/app/"

# 3. Create Info.plist
cat <<EOF > "${APP_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.magictrackpad.server</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

# 4. Create Launcher Executable
cat << 'EOF' > "${APP_DIR}/Contents/MacOS/launcher"
#!/bin/bash
DIR="$(cd "$(dirname "$0")/../Resources/app" && pwd)"
NODE_EXEC=$(which node || echo "/usr/local/bin/node" || echo "/opt/homebrew/bin/node")

if [ ! -x "$NODE_EXEC" ]; then
    osascript -e 'display alert "Node.js Not Found" message "Please install Node.js from https://nodejs.org to run Magic Trackpad Companion."'
    exit 1
fi

cd "$DIR"

# Check if port 3000 is already running
if lsof -i :3000 >/dev/null 2>&1; then
    open "http://localhost:3000/dashboard"
    exit 0
fi

# Launch server in background
"$NODE_EXEC" server.js > "$HOME/Library/Logs/MagicTrackpad.log" 2>&1 &
SERVER_PID=$!

sleep 1

# Open the desktop QR dashboard
open "http://localhost:3000/dashboard"
wait $SERVER_PID
EOF

chmod +x "${APP_DIR}/Contents/MacOS/launcher"

echo "✅ Created ${APP_DIR}"

# 5. Create .DMG with Applications symlink
echo "💿 Generating mountable DMG disk image..."
mkdir -p "${DMG_TEMP}"
cp -R "${APP_DIR}" "${DMG_TEMP}/"
ln -s /Applications "${DMG_TEMP}/Applications"

hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_TEMP}" -ov -format UDZO "${DMG_PATH}"
rm -rf "${DMG_TEMP}"

echo ""
echo "🎉 Build Complete!"
echo "📍 Application: ${APP_DIR}"
echo "📍 DMG Disk Image: ${DMG_PATH}"
