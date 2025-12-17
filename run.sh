#!/bin/bash

# JTimer - Development Run Script
echo "🧹 Cleaning build artifacts..."
rm -rf .build
swift package clean

echo "🔨 Building JTimer for development..."
swift build

if [ $? -eq 0 ]; then
    echo "✅ Build successful! Launching JTimer..."
    echo "The app will appear in your menu bar. Look for the ⏱ icon."
    echo "Press Ctrl+C to quit."
    echo ""
    echo "💡 Tip: For a distributable app, run: ./build-app.sh"
    echo ""
    ./.build/debug/JTimer
else
    echo "❌ Build failed. Please check the errors above."
    exit 1
fi