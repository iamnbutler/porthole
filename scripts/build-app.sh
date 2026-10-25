#!/bin/sh
# Builds Porthole.app (release), signs it with the Developer ID identity if one is
# present, and installs it to /Applications. Screen Recording grants follow the
# signature, so a stable identity keeps them across rebuilds.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/porthole
version=$(sed -n 's/^let portholeVersion = "\(.*\)"/\1/p' Sources/porthole/Config.swift)

app=dist/Porthole.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/porthole"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>win.porthole</string>
  <key>CFBundleName</key><string>Porthole</string>
  <key>CFBundleDisplayName</key><string>Porthole</string>
  <key>CFBundleExecutable</key><string>porthole</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Porthole lets your agents take screenshots and record audio on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Porthole lets your agents record what this Mac plays.</string>
</dict>
</plist>
PLIST

identity=${PORTHOLE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
if [ -n "$identity" ]; then
  codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
else
  echo "no Developer ID identity; signing ad hoc (Screen Recording must be re-granted after each build)"
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Porthole.app
  ditto "$app" /Applications/Porthole.app
  echo "installed /Applications/Porthole.app ($version)"
else
  echo "built $app ($version)"
fi
