#!/bin/bash
# Removes Agent Board: stops it, deletes the apps, and takes its hooks back out of
# Claude Code, Cursor and Codex (your other settings are left alone).
UID_DOMAIN="gui/$(id -u)"
for label in com.agentboard.app com.agentboard.helper com.agentboard.codexwatch; do
  launchctl bootout "$UID_DOMAIN/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
[ -f "$HOME/.agent-board/bin/agent-board-setup" ] && /usr/bin/python3 "$HOME/.agent-board/bin/agent-board-setup" uninstall
rm -rf "$HOME/Applications/AgentBoard.app" "$HOME/Applications/AgentBoardAX.app"
CURSOR_CLI="/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
[ -x "$CURSOR_CLI" ] && "$CURSOR_CLI" --uninstall-extension agentboard.agent-board-jump >/dev/null 2>&1
echo "Agent Board removed. Task history is in ~/.agent-board (delete it if you like)."
