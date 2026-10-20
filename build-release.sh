#!/bin/bash
# Builds AgentBoard.zip for a GitHub release: universal (Apple Silicon + Intel) prebuilt apps
# plus everything install.sh needs, so people can install without developer tools.
set -e
cd "$(dirname "$0")"
OUT=dist/AgentBoard; rm -rf dist; mkdir -p "$OUT/prebuilt"
build() { # <bundle> <source> <exe> <id> <name> <extra plist>
  local app="$OUT/prebuilt/$1.app"; mkdir -p "$app/Contents/MacOS"
  for arch in arm64 x86_64; do
    swiftc -O -target $arch-apple-macos15.0 -o "dist/$3-$arch" "$2" -framework SwiftUI -framework AppKit
  done
  lipo -create "dist/$3-arm64" "dist/$3-x86_64" -output "$app/Contents/MacOS/$3"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$4</string>
  <key>CFBundleName</key><string>$5</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  $6
</dict></plist>
PLIST
  codesign --force --sign - "$app"
}
build AgentBoard AgentBoard.swift AgentBoard com.agentboard.app "Agent Board" \
  "<key>NSAppleEventsUsageDescription</key><string>Agent Board brings the terminal tab your agent is running in to the front.</string>"
build AgentBoardAX AgentBoardAX.swift AgentBoardAX com.agentboard.helper "Agent Board Helper" ""
cp -R bin cursor-extension install.sh uninstall.sh AgentBoard.swift AgentBoardAX.swift README.md LICENSE "$OUT/"
(cd dist && zip -qry AgentBoard.zip AgentBoard)
echo "dist/AgentBoard.zip"; lipo -archs "$OUT/prebuilt/AgentBoard.app/Contents/MacOS/AgentBoard"
