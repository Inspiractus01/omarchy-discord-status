# omarchy-discord-status

Shows your Discord voice status in the Omarchy bar: connected or not, muted or not, which channel/server, who's in there with you. Click it to mute, disconnect, or jump straight back into your most-used rooms.

For Omarchy, where Discord runs as a web app in Brave (the default Omarchy setup).

## Requirements

- Omarchy, with Discord set up the default way (Omarchy's own "Discord" app, not the native Discord app, not Vencord)
- `node`, `socat`, `jq`

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Inspiractus01/omarchy-discord-status/main/install.sh | bash
```

Then quit Discord completely and reopen it. You'll need to log in again — the installer moves Discord into its own separate browser profile (see "Why a separate profile?" below).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Inspiractus01/omarchy-discord-status/main/uninstall.sh | bash
```

## Use

Look for the Discord icon in the top-right of the bar. It changes to show your status. Click it for a small panel with the current channel, who's in it, and buttons to mute/unmute, disconnect, open Discord, or jump into one of your two most-connected rooms.

## Why a separate profile?

This works by having Brave open a debugging port for the Discord tab, which this tool reads to know your status. That port has no password — anything running on your machine could connect to it. If Discord shared your normal Brave profile, that would mean anything on your machine could also read and control all your other open tabs. The installer gives Discord its own separate profile instead, so the debugging port only ever sees Discord.

## License

MIT
