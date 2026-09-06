#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Inspiractus01/omarchy-discord-status/main"
PLUGIN_ID="michal.discord-status"
SHARE_DIR="$HOME/.local/share/omarchy-discord-status"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
DESKTOP_FILE="$HOME/.local/share/applications/Discord.desktop"
PROFILE_DIR="$HOME/.local/share/discord-pwa-profile"
CDP_PORT=9333

echo "==> Checking dependencies"
command -v node >/dev/null || { echo "node not found. Install it (e.g. via mise, nvm, or your distro's package)."; exit 1; }
command -v socat >/dev/null || { echo "socat not found. Install it: omarchy pkg add socat"; exit 1; }
command -v jq >/dev/null || { echo "jq not found. Install it: omarchy pkg add jq"; exit 1; }
command -v hyprctl >/dev/null || { echo "hyprctl not found. This needs Omarchy/Hyprland."; exit 1; }
[[ -f "$DESKTOP_FILE" ]] || { echo "$DESKTOP_FILE not found. This tool only works with Discord launched as an Omarchy web app (the default Omarchy Discord setup), not the native app or a browser extension like Vencord."; exit 1; }

NODE_BIN="$(command -v node)"

echo "==> Installing daemon to $SHARE_DIR"
mkdir -p "$SHARE_DIR"
curl -fsSL "$REPO_RAW/bin/status-daemon.mjs" -o "$SHARE_DIR/status-daemon.mjs"

echo "==> Installing systemd service"
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/omarchy-discord-status.service" <<EOF
[Unit]
Description=Discord voice status (Omarchy bar widget backend)
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$NODE_BIN $SHARE_DIR/status-daemon.mjs
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now omarchy-discord-status.service

echo "==> Installing bar widget plugin"
mkdir -p "$PLUGIN_DIR"
curl -fsSL "$REPO_RAW/plugin/manifest.json" -o "$PLUGIN_DIR/manifest.json"
curl -fsSL "$REPO_RAW/plugin/Panel.qml" -o "$PLUGIN_DIR/Panel.qml"
omarchy plugin enable "$PLUGIN_ID" right >/dev/null 2>&1 || omarchy plugin enable "$PLUGIN_ID" >/dev/null

echo "==> Isolating Discord's browser profile"
# The remote-debugging port this tool needs has no authentication -- anything
# local that can reach it can read and control every open tab. Discord's
# Omarchy web app normally shares Brave's main profile/process with your
# regular browsing, so enabling it there would expose ALL of your tabs, not
# just Discord. Launching Discord with its own --user-data-dir keeps the
# debugging port scoped to Discord alone. You'll need to log into Discord
# again once, in this new isolated profile.
if grep -q -- "--remote-debugging-port" "$DESKTOP_FILE"; then
  echo "    Already configured, skipping."
else
  cp "$DESKTOP_FILE" "$DESKTOP_FILE.bak.$(date +%s)"
  mkdir -p "$PROFILE_DIR"
  sed -i -E "s#(Exec=omarchy-launch-webapp https://discord\.com/channels/@me)#\1 --remote-debugging-port=$CDP_PORT --user-data-dir=$PROFILE_DIR#" "$DESKTOP_FILE"
  echo "    Updated (backup: $DESKTOP_FILE.bak.*)"
fi

echo "==> Done."
echo "    Quit Discord completely if it's currently open, then reopen it"
echo "    (you'll need to log in again -- it's a fresh, isolated browser profile)."
echo "    Look for the Discord icon in the top-right of the Omarchy bar."
