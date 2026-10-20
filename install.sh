#!/bin/bash
# Agent Board installer: builds (or copies the prebuilt) apps, starts them at login, and wires
# hooks into Claude Code, Cursor and Codex. Safe to re-run. Undo with ./uninstall.sh.
set -e
cd "$(dirname "$0")"

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 15 ]; then
  echo "Agent Board needs macOS 15 or newer."; exit 1
fi

UID_DOMAIN="gui/$(id -u)"
APPS="$HOME/Applications"
BOARD="$HOME/.agent-board"
mkdir -p "$BOARD/bin" "$APPS" "$HOME/Library/LaunchAgents"

echo "Installing scripts..."
cp bin/agent-board-event bin/agent-board-watch bin/agent-board-setup bin/codex-notify "$BOARD/bin/"
chmod +x "$BOARD/bin/"*

# build_app <bundle name> <swift source> <executable> <bundle id> <display name> <extra plist keys>
build_app() {
  local app="$APPS/$1.app" src="$2" exe="$3" id="$4" name="$5" extra="$6"
  local sum; sum=$(shasum "$src" | cut -c1-12)
  if [ -d "prebuilt/$1.app" ]; then
    # release download: use the universal build that ships with it
    if [ "$(cat "$app/Contents/source-sum" 2>/dev/null)" != "$sum" ]; then
      rm -rf "$app"; cp -R "prebuilt/$1.app" "$app"
      xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
      echo "$sum" > "$app/Contents/source-sum"
    fi
    return
  fi
  # Rebuild only when the source changed: macOS ties Accessibility permission to the exact binary.
  [ "$(cat "$app/Contents/source-sum" 2>/dev/null)" = "$sum" ] && return
  command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }
  echo "Building $name..."
  mkdir -p "$app/Contents/MacOS"
  if swiftc -O -o "$app/Contents/MacOS/$exe" "$src" -framework SwiftUI -framework AppKit 2>&1 | grep error; then exit 1; fi
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  $extra
</dict></plist>
PLIST
  codesign --force --sign - "$app" >/dev/null 2>&1 || true
  echo "$sum" > "$app/Contents/source-sum"
}

# launch_agent <label> <program> [args...]
launch_agent() {
  local label="$1"; shift
  local plist="$HOME/Library/LaunchAgents/$label.plist" args=""
  for a in "$@"; do args="$args<string>$a</string>"; done
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>$args</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$BOARD/$label.log</string>
</dict></plist>
PLIST
  launchctl bootout "$UID_DOMAIN/$label" 2>/dev/null || true
  for i in 1 2 3 4 5; do launchctl bootstrap "$UID_DOMAIN" "$plist" 2>/dev/null && break; sleep 1; done
}

build_app AgentBoard AgentBoard.swift AgentBoard com.agentboard.app "Agent Board" \
  "<key>NSAppleEventsUsageDescription</key><string>Agent Board brings the terminal tab your agent is running in to the front.</string>"
build_app AgentBoardAX AgentBoardAX.swift AgentBoardAX com.agentboard.helper "Agent Board Helper" ""

echo "Starting Agent Board..."
launch_agent com.agentboard.app "$APPS/AgentBoard.app/Contents/MacOS/AgentBoard"
launch_agent com.agentboard.helper "$APPS/AgentBoardAX.app/Contents/MacOS/AgentBoardAX"
launch_agent com.agentboard.codexwatch /usr/bin/python3 "$BOARD/bin/agent-board-watch"

CURSOR_CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
if [ -x "$CURSOR_CLI" ]; then
  "$CURSOR_CLI" --install-extension cursor-extension/agent-board-jump.vsix --force >/dev/null 2>&1 || true
fi

echo "Connecting your tools..."
/usr/bin/python3 "$BOARD/bin/agent-board-setup" install

cat <<'DONE'

Agent Board is running (look for the dog, or the paw in the menu bar).

One-time steps:
  1. Claude desktop app tracking: System Settings > Privacy & Security > Accessibility,
     turn on "Agent Board Helper".
  2. Cursor: run "Developer: Reload Window" once in open windows so clicks can open the exact terminal tab.
  3. Restart open Claude Code / Codex / Cursor sessions so they pick up the new hooks.

Optional: touch ~/.agent-board/no-ai-titles to stop 3-word titles being written by Claude Haiku.
DONE
