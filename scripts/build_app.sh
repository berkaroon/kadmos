#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/Users/stormtrooper/.gemini/antigravity/scratch/Kadmos"
DIST_DIR="$PROJECT_DIR/dist"
DERIVED_DIR="$PROJECT_DIR/.build/DerivedData"
APP_DIR="$DIST_DIR/Kadmos.app"
APPEX_REL="Contents/PlugIns/KadmosFinderSync.appex"
DMG_PATH="$DIST_DIR/Kadmos.dmg"

cd "$PROJECT_DIR"

echo "1) Running KadmosCore test suite..."
swift test

echo "2) Regenerating Kadmos.xcodeproj..."
python3 "$PROJECT_DIR/scripts/generate_xcodeproj.py"

echo "3) Building Release Kadmos.app (with embedded KadmosFinderSync.appex)..."
xcodebuild \
  -project "$PROJECT_DIR/Kadmos.xcodeproj" \
  -scheme "Kadmos" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

BUILT_APP="$DERIVED_DIR/Build/Products/Release/Kadmos.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "Error: Built Kadmos.app not found at $BUILT_APP" >&2
  exit 1
fi
if [ ! -d "$BUILT_APP/$APPEX_REL" ]; then
  echo "Error: Embedded KadmosFinderSync.appex not found at $BUILT_APP/$APPEX_REL" >&2
  exit 1
fi

echo "4) Assembling dist/Kadmos.app..."
rm -rf "$APP_DIR"
mkdir -p "$DIST_DIR"
ditto "$BUILT_APP" "$APP_DIR"

echo "5) Signing inside-out with Hardened Runtime (--options runtime) and strict Profile A entitlements..."
codesign --force --options runtime --sign - \
  --entitlements "$PROJECT_DIR/Config/KadmosFinderSync.entitlements" \
  "$APP_DIR/$APPEX_REL"

codesign --force --options runtime --sign - \
  --entitlements "$PROJECT_DIR/Config/Kadmos.entitlements" \
  "$APP_DIR"

echo "6) Verifying signatures, Hardened Runtime flags, and entitlements..."
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

APP_DV="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
APPEX_DV="$(codesign -dv --verbose=4 "$APP_DIR/$APPEX_REL" 2>&1)"
echo "$APP_DV" | grep -q "runtime" || { echo "Error: Hardened Runtime flag missing on Kadmos.app" >&2; exit 1; }
echo "$APPEX_DV" | grep -q "runtime" || { echo "Error: Hardened Runtime flag missing on KadmosFinderSync.appex" >&2; exit 1; }

echo "--- Kadmos.app entitlements ---"
codesign -d --entitlements - "$APP_DIR" 2>&1
echo "--- KadmosFinderSync.appex entitlements ---"
codesign -d --entitlements - "$APP_DIR/$APPEX_REL" 2>&1

echo "7) Creating dist/Kadmos.dmg..."
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/Kadmos.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "Kadmos" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo "Done: $APP_DIR and $DMG_PATH"
