#!/bin/bash
set -e

APP_NAME="Substage"
APP_BUNDLE="$APP_NAME.app"
BUILD_DIR=".build/release"

echo "Building $APP_NAME..."
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "AppBundle/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Add a simple app icon if available, otherwise skip
if [ -f "AppBundle/AppIcon.icns" ]; then
    cp "AppBundle/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "Code signing (ad-hoc)..."
codesign --deep --force --sign - \
    --entitlements "AppBundle/Substage.entitlements" \
    "$APP_BUNDLE"

echo ""
echo "✓ Built: $(pwd)/$APP_BUNDLE"
echo ""
echo "To install: cp -r $APP_BUNDLE /Applications/"
echo "To run:     open $APP_BUNDLE"
echo ""
echo "First launch: go to System Settings → Privacy & Security → Accessibility"
echo "and grant Substage access for global hotkeys."
