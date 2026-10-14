#!/bin/bash
# Build a universal, Developer ID-signed, notarized DMG and publish it as a GitHub release.
#
# One-time setup (stores notarization credentials in the keychain):
#   xcrun notarytool store-credentials ScreenOff --apple-id <apple-id> --team-id 297W77MNZY
#
# Env overrides:
#   IDENTITY=...        signing identity
#   NOTARY_PROFILE=...  notarytool keychain profile (default: ScreenOff)
#   SKIP_NOTARIZE=1     sign + build DMG only
#   PUBLISH=0           don't create the GitHub release
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-Developer ID Application: Pawel Szydlowski (297W77MNZY)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ScreenOff}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
OUT=build/release
APP="$OUT/ScreenOff.app"
DMG="$OUT/ScreenOff-$VERSION.dmg"

if [ "${PUBLISH:-1}" = 1 ] && gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists. Bump CFBundleShortVersionString in Resources/Info.plist." >&2
    exit 1
fi

echo "==> Building universal binary ($VERSION)"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/ScreenOff"

echo "==> Assembling and signing app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenOff"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Creating DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "ScreenOff $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "${SKIP_NOTARIZE:-0}" != 1 ]; then
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

shasum -a 256 "$DMG"

if [ "${PUBLISH:-1}" = 1 ]; then
    echo "==> Publishing GitHub release $TAG"
    gh release create "$TAG" "$DMG" --title "ScreenOff $VERSION" --notes "$(cat <<EOF
Universal (Apple Silicon + Intel), Developer ID signed and notarized. Requires macOS 14+.

**Install:** open the DMG and drag ScreenOff to Applications.

**CLI:** link the bundled binary into your PATH:
\`\`\`bash
ln -sf /Applications/ScreenOff.app/Contents/MacOS/ScreenOff /opt/homebrew/bin/screenoff
\`\`\`
EOF
)"
fi
