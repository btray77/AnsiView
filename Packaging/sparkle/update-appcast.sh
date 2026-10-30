#!/bin/zsh
# Adds a release DMG to docs/appcast.xml (the Sparkle feed) with Sparkle's generate_appcast.
#
#   Packaging/sparkle/update-appcast.sh dist/AnsiView-2.0.1.dmg
#
# The EdDSA private key comes from the login keychain (made once by Sparkle's generate_keys).
# Extra arguments go to generate_appcast, for example --ed-key-file <file> for a key kept in a file.
# Then attach the DMG to the GitHub release v<version> and commit and push docs/appcast.xml.
set -euo pipefail
cd "$(dirname "$0")/../.."

[[ $# -ge 1 ]] || { echo "usage: $0 <AnsiView-x.y.z.dmg> [generate_appcast options]"; exit 2; }
DMG=${1:A}; shift
BIN=${SPARKLE_BIN:-build/SourcePackages/artifacts/sparkle/Sparkle/bin}
APPCAST=${APPCAST:-docs/appcast.xml}
[[ -x $BIN/generate_appcast ]] || { echo "No $BIN/generate_appcast: build once (./install.sh) so Swift Package Manager fetches Sparkle"; exit 1; }

# Read the version and key from the app inside the disk image.
MOUNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
APP=$(print -l "$MOUNT"/*.app(N) | head -1)
if [[ -z $APP ]]; then hdiutil detach "$MOUNT" >/dev/null; echo "No app in $DMG"; exit 1; fi
SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
hdiutil detach "$MOUNT" >/dev/null
if [[ -z $KEY || $KEY == REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY ]]; then
  echo "SUPublicEDKey in $DMG is not set: put the public key from generate_keys in project.yml and rebuild."
  exit 1
fi

# generate_appcast works on a folder: the DMG plus the current appcast, which it extends.
STAGE=$(mktemp -d)
cp "$DMG" "$STAGE/"
[[ -f $APPCAST ]] && cp "$APPCAST" "$STAGE/appcast.xml"
"$BIN/generate_appcast" \
  --download-url-prefix "https://github.com/btray77/AnsiView/releases/download/v$SHORT/" \
  --link "https://github.com/btray77/AnsiView" \
  --maximum-deltas 0 \
  "$@" "$STAGE"

# Check the new item before replacing the feed.
OUT="$STAGE/appcast.xml"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$OUT" || { echo "No item for build $BUILD in the new appcast"; exit 1; }
grep -q "releases/download/v$SHORT/${DMG:t}" "$OUT" || { echo "No download URL for ${DMG:t}"; exit 1; }
grep -q 'sparkle:edSignature="' "$OUT" || { echo "The new item is not signed"; exit 1; }
cp "$OUT" "$APPCAST"
rm -rf "$STAGE"
echo "Updated $APPCAST with AnsiView $SHORT ($BUILD). Attach ${DMG:t} to the GitHub release v$SHORT, then commit and push $APPCAST."
