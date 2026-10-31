#!/bin/zsh
# Fills the String Catalogs from the strings the compiler extracted (SWIFT_EMIT_LOC_STRINGS) in the
# last Release build under build/. Run after building; then build again so the catalogs compile.
#   xcodebuild -project AnsiView.xcodeproj -scheme AnsiView -configuration Release -derivedDataPath build build
#   Packaging/sync-strings.sh
set -e
cd "$(dirname "$0")/.."
INTERMEDIATES=build/Build/Intermediates.noindex/AnsiView.build/Release
sync() {
  local catalog=$1 target=$2
  local files=(${(f)"$(find $INTERMEDIATES/$target.build -name '*.stringsdata' 2>/dev/null)"})
  if [[ -z "$files" ]]; then echo "no extracted strings for $target (build first)"; return 1; fi
  local args=()
  for f in $files; do args+=(--stringsdata "$f"); done
  xcrun xcstringstool sync "$catalog" $args
  echo "$catalog: $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["strings"]))' "$catalog") keys"
}
sync App/Localizable.xcstrings AnsiView
sync Preview/Localizable.xcstrings AnsiPreview
sync Saver/Localizable.xcstrings AnsiSaver
# QuickAction/PNG and QuickAction/GIF InfoPlist.xcstrings hold only the Quick Actions' names and
# are edited by hand.
