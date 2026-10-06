#!/bin/zsh
# Builds "macshot Studio.app" (release) from the upstream macshot sources.
# Usage: ./build-app.sh [--install]   (--install copies it to ~/Applications)
set -euo pipefail
HERE=${0:A:h}
UPSTREAM=${${MACSHOT_SRC:-$HERE/../macshot/macshot}:A}
APP="$HERE/build/macshot Studio.app"
cd "$HERE"

./sync-sources.sh
swift build -c release
BIN=$(swift build -c release --show-bin-path)/MacshotStudio

rm -rf "${APP:?}" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/macshot Studio"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

# Translations used by L("…") and the app icon.
for lproj in "$UPSTREAM"/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done
xcrun actool "$UPSTREAM/Assets.xcassets" --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$HERE/build/assets-info.plist" >/dev/null

# Ad-hoc signature so macOS will launch it locally and remember permissions.
codesign --force --deep --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ ${1:-} == --install ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"macshot Studio.app"
  cp -R "$APP" ~/Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/"macshot Studio.app"
  echo "Installed to ~/Applications/macshot Studio.app"
fi
