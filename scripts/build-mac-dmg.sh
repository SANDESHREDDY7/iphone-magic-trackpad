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
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
        <string>x86_64</string>
    </array>
    <key>LSRequiresNativeExecution</key>
    <true/>
</dict>
</plist>
EOF

# 4. Create Launcher Executable
cat << 'EOF' > "${APP_DIR}/Contents/MacOS/launcher"
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [ -x "/opt/homebrew/bin/node" ]; then
    NODE_EXEC="/opt/homebrew/bin/node"
elif [ -x "/usr/local/bin/node" ]; then
    NODE_EXEC="/usr/local/bin/node"
else
    NODE_EXEC=$(which node 2>/dev/null)
fi

if [ -z "$NODE_EXEC" ] || [ ! -x "$NODE_EXEC" ]; then
    osascript -e 'display alert "Node.js Not Found" message "Please install Node.js from https://nodejs.org to run Magic Trackpad Companion."'
    exit 1
fi

DIR="$(cd "$(dirname "$0")/../Resources/app" && pwd)"
cd "$DIR"

# Check if port 3000 is already running
if lsof -i :3000 >/dev/null 2>&1; then
    open "http://localhost:3000/dashboard"
    exit 0
fi

# Force arm64 on Apple Silicon to avoid Rosetta architecture mismatch
SYS_ARCH=$(uname -m)
if [ "$SYS_ARCH" = "arm64" ]; then
    arch -arm64 "$NODE_EXEC" server.js > "$HOME/Library/Logs/MagicTrackpad.log" 2>&1 &
else
    "$NODE_EXEC" server.js > "$HOME/Library/Logs/MagicTrackpad.log" 2>&1 &
fi
SERVER_PID=$!

# Wait for server to start listening (up to 5 seconds)
for i in {1..10}; do
    if lsof -i :3000 >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

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
