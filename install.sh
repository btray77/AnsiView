#!/bin/zsh
# Build AnsiView, install it to ~/Applications and register the Quick Look extension.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate
xcodebuild -project AnsiView.xcodeproj -scheme AnsiView -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build build | grep -E "error:|BUILD"

mkdir -p ~/Applications
rm -rf ~/Applications/AnsiView.app
cp -R build/Build/Products/Release/AnsiView.app ~/Applications/

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f ~/Applications/AnsiView.app
# Register the extensions now rather than whenever LaunchServices gets to them.
for appex in ~/Applications/AnsiView.app/Contents/PlugIns/*.appex; do pluginkit -a "$appex"; done
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1

for id in Preview Thumbnail Spotlight; do pluginkit -m -i com.traynham.AnsiView.$id; done
echo "Installed. Select a .ANS file in Finder and press space."
