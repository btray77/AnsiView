#!/bin/sh
# Xcode build phase (after Embed Frameworks): signs Sparkle's helpers with the app's identity.
# The Swift package ships them ad hoc signed, and notarization needs every executable signed with
# the Developer ID, the hardened runtime and a timestamp. Order follows Sparkle's sandboxing guide:
# inside out, Downloader keeping its entitlements, never --deep. Xcode signs the app afterwards.
set -eu
[ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] && exit 0
FW="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
[ -d "$FW" ] || exit 0
ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$ID" ] || ID="-"
if [ "$ID" = "-" ]; then TIMESTAMP="--timestamp=none"; else TIMESTAMP="--timestamp"; fi
sign() { /usr/bin/codesign --force --sign "$ID" --options runtime "$TIMESTAMP" "$@"; }
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
