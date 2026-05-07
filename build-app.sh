#!/bin/bash
# Build Braindrop and refresh the .app bundle.
# Run this once after code changes, then launch Braindrop.app from Finder.
# No terminal window will appear when the app is opened this way.

set -e
cd "$(dirname "$0")"

APP="$PWD/Braindrop.app"
BINARY="$APP/Contents/MacOS/Braindrop"
PLIST_SRC="$PWD/AppBundle/Info.plist"

echo "→ Building Braindrop (release)…"
swift build -c release 2>&1 | tail -3

echo "→ Copying binary into app bundle…"
cp .build/release/Braindrop "$BINARY"
chmod +x "$BINARY"

echo "→ Syncing Info.plist…"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"

echo "→ Ad-hoc signing…"
codesign --deep --force --sign - "$APP" 2>/dev/null

echo ""
echo "✓ Done.  Braindrop.app is ready."
echo ""
echo "  To install:  cp -r Braindrop.app /Applications/"
echo "  To run now:  open Braindrop.app"
echo ""

# Ask to launch now
read -p "Launch Braindrop now? [Y/n] " answer
if [[ "$answer" != "n" && "$answer" != "N" ]]; then
    pkill -x Braindrop 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "Launched. You can now close this terminal."
fi
