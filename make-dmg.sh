#!/bin/bash
# Builds Duck Keyboard in Release mode and packages it as a drag-to-Applications DMG.
#
#   ./make-dmg.sh                         build + DMG (signed with whatever Xcode uses)
#   NOTARY_PROFILE=ak ./make-dmg.sh       also notarize, so other Macs open it without warnings
#
# Output: dist/Duck-Keyboard-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AKAssistant"          # Xcode project / scheme
PRODUCT="Duck Keyboard"         # the .app name
VOLUME_NAME="Duck Keyboard"
BUILD_DIR="build"
DIST_DIR="dist"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"

VERSION=$(xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
VERSION=${VERSION:-0.1.0}
DMG="$DIST_DIR/Duck-Keyboard-$VERSION.dmg"

echo "▸ Building Duck Keyboard $VERSION (Release)…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  archive -quiet

# Prefer a Developer ID export (needed to share with other Macs); otherwise use the archived app as-is.
APP_PATH=""
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "▸ Exporting with Developer ID…"
  cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -quiet
  APP_PATH="$BUILD_DIR/export/$PRODUCT.app"
else
  echo "▸ No Developer ID certificate found; using the development-signed app (fine for this Mac)."
  APP_PATH="$ARCHIVE/Products/Applications/$PRODUCT.app"
fi

echo "▸ Creating DMG…"
STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING" && mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/How to open on another Mac.txt" <<'TXT'
Duck Keyboard — installing on another Mac
(Needs a Mac with Apple silicon: M1 or newer, macOS 15 or later.)

1. Drag Duck Keyboard into the Applications folder.
2. Open it from Applications. If macOS says it "can't be opened" or "can't verify" it:
   open System Settings › Privacy & Security, scroll down and click "Open Anyway",
   then confirm. (Or right-click the app › Open › Open.) You only do this once.
3. Follow onboarding: allow the Microphone and Accessibility, and download a speech model.
   If the hotkey doesn't react after allowing Accessibility, quit and reopen the app.

Everything runs on this Mac; models are downloaded once from Hugging Face.
TXT
rm -f "$DMG"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ Notarizing (a few minutes)…"
  codesign --sign "Developer ID Application" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "✓ Done: $DMG ($(du -h "$DMG" | cut -f1))"
# open -R "$DMG"
