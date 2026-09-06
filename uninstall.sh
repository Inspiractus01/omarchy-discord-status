#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="michal.discord-status"
SHARE_DIR="$HOME/.local/share/omarchy-discord-status"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
DESKTOP_FILE="$HOME/.local/share/applications/Discord.desktop"
STATE_DIR="$HOME/.local/state/omarchy/indicators"

echo "==> Stopping service"
systemctl --user stop omarchy-discord-status.service 2>/dev/null || true
systemctl --user disable omarchy-discord-status.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/omarchy-discord-status.service"
systemctl --user daemon-reload 2>/dev/null || true

echo "==> Removing plugin"
omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
rm -rf "$PLUGIN_DIR"

echo "==> Removing daemon and state files"
rm -rf "$SHARE_DIR"
rm -f "$STATE_DIR/discord-voice.json" "$STATE_DIR/discord-voice.sock" "$STATE_DIR/discord-frequent-rooms.json"

echo "==> Restoring Discord's launch command"
if [[ -f "$DESKTOP_FILE" ]]; then
  sed -i -E 's/ --remote-debugging-port=[0-9]+ --user-data-dir=[^ ]*//' "$DESKTOP_FILE"
fi

echo "==> Done."
echo "    Quit and reopen Discord to go back to your regular Brave profile."
echo "    The isolated Discord profile (~/.local/share/discord-pwa-profile) was"
echo "    left in place -- delete it yourself if you don't need it."
