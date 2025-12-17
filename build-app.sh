#!/bin/bash

set -e  # Exit on any error

APP_NAME="JTimer"
BUNDLE_ID="com.yourcompany.JTimer"
VERSION="1.0.0"
BUILD_DIR=".build"
APP_DIR="${APP_NAME}.app"

echo "🔨 Building ${APP_NAME} macOS App Bundle..."

# Step 0: Clean build artifacts
echo "🧹 Cleaning previous build artifacts..."
rm -rf .build
swift package clean

# Step 1: Build the Swift executable
echo "1️⃣ Building Swift executable..."
swift build --configuration release

# Check if the executable was created
if [ ! -f "${BUILD_DIR}/release/${APP_NAME}" ]; then
    echo "❌ Error: Swift build failed or executable not found"
    exit 1
fi

# Step 2: Clean and create app bundle structure
echo "2️⃣ Creating app bundle structure..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Step 3: Copy the executable
echo "3️⃣ Copying executable..."
cp "${BUILD_DIR}/release/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Step 4: Create Info.plist
echo "4️⃣ Creating Info.plist..."
cp Info.plist.template "${APP_DIR}/Contents/Info.plist"

# Step 5: Copy app icon and resources if they exist
echo "5️⃣ Adding app icon and resources..."
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
    echo "   ✅ App icon added"
else
    echo "   ⚠️  No app icon found (AppIcon.icns)"
fi

# Add menu bar icon
if [ -f "menubar-icon.png" ]; then
    cp menubar-icon.png "${APP_DIR}/Contents/Resources/menubar-icon.png"
    echo "   ✅ Menu bar icon added"
else
    echo "   ⚠️  No menu bar icon found (menubar-icon.png)"
fi

# Step 6: Set bundle permissions
echo "6️⃣ Setting permissions..."
chmod -R 755 "${APP_DIR}"

# Step 7: Ad-hoc code signing
echo "7️⃣ Code signing app..."
codesign --force --deep --sign - "${APP_DIR}"
if [ $? -eq 0 ]; then
    echo "   ✅ App signed successfully"
else
    echo "   ⚠️  Code signing failed (app may show security warnings)"
fi

# Step 8: Verify the bundle
echo "8️⃣ Verifying app bundle..."
if [ -f "${APP_DIR}/Contents/MacOS/${APP_NAME}" ] && [ -f "${APP_DIR}/Contents/Info.plist" ]; then
    echo "✅ App bundle created successfully!"
    echo ""
    echo "📱 ${APP_NAME}.app is ready!"
    echo "🚀 You can now:"
    echo "   • Double-click ${APP_NAME}.app to launch"
    echo "   • Copy to /Applications folder"
    echo "   • Create installer with: ./package-dmg.sh"
    echo ""

    # Show app bundle info
    ls -la "${APP_DIR}/Contents/MacOS/${APP_NAME}"
    du -sh "${APP_DIR}"
else
    echo "❌ Error: App bundle creation failed"
    exit 1
fi