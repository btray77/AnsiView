#!/bin/zsh
# Build a signed, notarized AnsiView disk image for public download.
#
# One time setup (stores an app specific password in your keychain):
#   xcrun notarytool store-credentials AnsiView --apple-id <you@example.com> --team-id 47HEHK53W5
# Then run:  ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-AnsiView}"
IDENTITY="Developer ID Application: BRAD TRAYNHAM (47HEHK53W5)"

xcodegen generate
xcodebuild -project AnsiView.xcodeproj -scheme AnsiView -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build clean build | grep -E "error:|BUILD"

APP=build/Build/Products/Release/AnsiView.app
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
DMG="dist/AnsiView-$VERSION.dmg"

codesign --verify --deep --strict "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/AnsiView")"

# Disk image contents: the app, an Applications shortcut, and install notes.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Packaging/ReadMe.txt "$STAGE/Read Me.txt"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "AnsiView $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
  echo "Notary profile '$PROFILE' not found; $DMG is signed but NOT notarized."
  echo "Run: xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id 47HEHK53W5"
  exit 1
fi

shasum -a 256 "$DMG"
echo "Ready: $DMG"
echo "For Sparkle updates: Packaging/sparkle/update-appcast.sh $DMG, attach the DMG to the GitHub"
echo "release v$VERSION, then commit and push docs/appcast.xml."
