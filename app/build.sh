#!/bin/bash
# Builds Cue.app into ./build. Needs Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

echo "› Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Cue"

APP="build/Cue.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cue"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/MenuBarIcon*.png "$APP/Contents/Resources/"
if command -v iconutil >/dev/null; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so macOS will run it locally (no Apple developer account needed).
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Cue.app"
  cp -R "$APP" /Applications/
  echo "✓ Installed to /Applications/Cue.app"
  open /Applications/Cue.app
fi
