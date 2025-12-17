#!/bin/bash

set -e  # Exit on any error

APP_NAME="JTimer"
VERSION="1.0.0"
DMG_NAME="${APP_NAME}-${VERSION}"
TEMP_DMG="${DMG_NAME}-temp.dmg"
FINAL_DMG="${DMG_NAME}.dmg"

echo "📦 Creating ${APP_NAME} installer DMG..."

# Step 1: Check if app bundle exists
if [ ! -d "${APP_NAME}.app" ]; then
    echo "❌ Error: ${APP_NAME}.app not found. Run ./build-app.sh first."
    exit 1
fi

# Step 2: Create temporary directory for DMG contents
echo "1️⃣ Preparing DMG contents..."
DMG_TEMP_DIR="dmg-temp"
rm -rf "${DMG_TEMP_DIR}"
mkdir "${DMG_TEMP_DIR}"

# Copy app to temp directory
cp -R "${APP_NAME}.app" "${DMG_TEMP_DIR}/"

# Create Applications symlink for easy installation
ln -s /Applications "${DMG_TEMP_DIR}/Applications"

# Step 3: Create disk image
echo "2️⃣ Creating disk image..."
rm -f "${TEMP_DMG}" "${FINAL_DMG}"

# Calculate size needed (app size + 50MB buffer)
APP_SIZE=$(du -sm "${APP_NAME}.app" | cut -f1)
DMG_SIZE=$((APP_SIZE + 50))

# Create the DMG
hdiutil create -size ${DMG_SIZE}m -fs HFS+ -volname "${APP_NAME}" "${TEMP_DMG}"

# Step 4: Mount the DMG and copy contents
echo "3️⃣ Mounting and copying files..."
MOUNT_POINT=$(hdiutil attach "${TEMP_DMG}" | grep "/Volumes" | cut -d$'\t' -f3)

if [ -z "${MOUNT_POINT}" ]; then
    echo "❌ Error: Failed to mount DMG"
    exit 1
fi

# Copy files to mounted DMG
cp -R "${DMG_TEMP_DIR}/"* "${MOUNT_POINT}/"

# Set up DMG window properties (optional, requires more complex setup)
echo "4️⃣ Setting up DMG presentation..."

# Create a simple .DS_Store for basic layout (if osascript is available)
if command -v osascript >/dev/null 2>&1; then
    cat > setup_dmg.applescript << 'EOF'
tell application "Finder"
    tell disk "JTimer"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 900, 400}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "JTimer.app" of container window to {120, 120}
        set position of item "Applications" of container window to {380, 120}
        update without registering applications
        delay 1
    end tell
end tell
EOF

    osascript setup_dmg.applescript 2>/dev/null || echo "   ⚠️  Could not set DMG layout"
    rm -f setup_dmg.applescript
fi

# Step 5: Unmount and finalize
echo "5️⃣ Finalizing DMG..."
hdiutil detach "${MOUNT_POINT}"

# Convert to final compressed DMG
hdiutil convert "${TEMP_DMG}" -format UDZO -o "${FINAL_DMG}"

# Clean up
rm -f "${TEMP_DMG}"
rm -rf "${DMG_TEMP_DIR}"

echo "✅ DMG created successfully!"
echo ""
echo "📦 ${FINAL_DMG} is ready for distribution!"
echo "🚀 Users can:"
echo "   • Double-click the DMG to mount it"
echo "   • Drag ${APP_NAME}.app to Applications folder"
echo "   • Launch ${APP_NAME} from Applications or Launchpad"
echo ""

# Show final DMG info
ls -lh "${FINAL_DMG}"