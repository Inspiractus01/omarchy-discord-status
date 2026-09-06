// Polls the Discord PWA (via Chrome DevTools Protocol on 127.0.0.1:9333) for
// voice-connection state and writes it to a small state file the Omarchy bar
// widget watches. Also runs a tiny Unix socket that accepts "mute" / "disconnect"
// commands from the widget and clicks the real Discord buttons via the same
// CDP connection -- real control of the real session, not a simulated keypress.
//
// Detection is based on stable ARIA semantics rather than Discord's CSS class
// names (hashed, change every release):
//   - muted/deafened: read from the two role="switch" controls Discord always
//     renders bottom-left (mic mute, then deafen -- confirmed live, that order
//     doesn't depend on UI language, so this part works in any language with
//     zero configuration).
//   - connected: Discord adds a "disconnect" button only while in a voice
//     channel, but (confirmed live, against a real connected session) it does
//     NOT sit near the mute/deafen switches in the DOM, so there's no
//     structural way found to detect it without matching its label text --
//     which IS language-specific. Same for the mute/deafen commands' own
//     click targets (still keyed by label, for simplicity, even though the
//     state read for those two is now language-independent).
//
// If Discord isn't showing you Czech/Slovak, update the three labels below
// (open the Omarchy menu -> Discord Status, or Discord's own web app, right
// -click the button in question and inspect its aria-label) -- everything
// else adapts on its own.
const LABEL_DISCONNECT = 'Odpojit';
const LABEL_MUTE = 'Ztlumit';
const LABEL_DEAFEN = 'Ztlumit zvuk';

import { createServer } from 'node:net';
import { writeFileSync, readFileSync, mkdirSync, unlinkSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const CDP_PORT = 9333;
const STATE_DIR = path.join(homedir(), '.local/state/omarchy/indicators');
const STATE_FILE = path.join(STATE_DIR, 'discord-voice.json');
const FREQUENT_FILE = path.join(STATE_DIR, 'discord-frequent-rooms.json');
const SOCKET_FILE = path.join(STATE_DIR, 'discord-voice.sock');
const POLL_MS = 1500;

mkdirSync(STATE_DIR, { recursive: true });

// Keyed by "guildId:channelId" -> {count, guildId, channelId, channel, server}.
// Counts joins (a join = the connected channel changing to a new one), not
// time spent, so hopping in and out of a room repeatedly counts each hop --
// that matches "where I connect most", not "where I spend the most time".
// lastRoom is the single most recently joined room, tracked separately from
// the count so "most popular" and "most recent" can be two different rooms
// (or the same one, shown once) rather than one blended ranking.
let roomCounts = {};
let lastRoom = null;
try {
  const saved = JSON.parse(readFileSync(FREQUENT_FILE, 'utf8'));
  roomCounts = saved.roomCounts || {};
  lastRoom = saved.lastRoom || null;
} catch { roomCounts = {}; lastRoom = null; }
let lastRoomKey = lastRoom ? lastRoom.guildId + ':' + lastRoom.channelId : null;

function topRooms() {
  const mostPopular = Object.values(roomCounts).sort((a, b) => b.count - a.count)[0] || null;
  const rooms = [];
  if (mostPopular) rooms.push({ ...mostPopular, kind: 'popular' });
  if (lastRoom) {
    const sameAsPopular = mostPopular
      && mostPopular.guildId === lastRoom.guildId && mostPopular.channelId === lastRoom.channelId;
    if (!sameAsPopular) rooms.push({ ...lastRoom, kind: 'recent' });
  }
  return rooms;
}

function noteRoom(state) {
  if (!state.connected || !state.guildId || !state.channelId) return;
  const key = state.guildId + ':' + state.channelId;
  if (key === lastRoomKey) return;
  lastRoomKey = key;
  const existing = roomCounts[key];
  const room = {
    guildId: state.guildId,
    channelId: state.channelId,
    channel: state.channel,
    server: state.server,
    count: (existing ? existing.count : 0) + 1
  };
  roomCounts[key] = room;
  lastRoom = { guildId: state.guildId, channelId: state.channelId, channel: state.channel, server: state.server };
  writeFileSync(FREQUENT_FILE, JSON.stringify({ roomCounts, lastRoom }));
}

let lastWritten = null;
function writeState(state) {
  const json = JSON.stringify(state);
  if (json === lastWritten) return;
  lastWritten = json;
  writeFileSync(STATE_FILE, json);
}

async function findDiscordTarget() {
  try {
    const res = await fetch(`http://127.0.0.1:${CDP_PORT}/json`);
    const targets = await res.json();
    return targets.find(t => t.type === 'page' && t.url.includes('discord.com')) || null;
  } catch {
    return null;
  }
}

function evaluate(wsUrl, expression) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const timer = setTimeout(() => { ws.close(); reject(new Error('timeout')); }, 10000);
    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true, awaitPromise: true } }));
    });
    ws.addEventListener('message', (ev) => {
      clearTimeout(timer);
      const msg = JSON.parse(ev.data);
      ws.close();
      if (msg.result?.exceptionDetails) return reject(new Error(msg.result.exceptionDetails.text));
      resolve(msg.result?.result?.value);
    });
    ws.addEventListener('error', (e) => { clearTimeout(timer); reject(e); });
  });
}

function statusExpr() {
  return `(function(){
  var btn = document.querySelector('[aria-label=${JSON.stringify(LABEL_DISCONNECT)}]');
  if (!btn) return JSON.stringify({connected:false});
  // Confirmed live: these two role="switch" controls (mic mute, then deafen,
  // in that fixed order) are always present regardless of UI language, so
  // reading mute/deafen state doesn't need the label constants at all.
  var switches = Array.from(document.querySelectorAll('[role="switch"]'));
  var muteEl = switches[0] || null;
  var deafEl = switches[1] || null;
  var panel = btn.closest('section') || (btn.parentElement && btn.parentElement.parentElement && btn.parentElement.parentElement.parentElement);
  var text = panel ? panel.innerText : '';
  var line = text.split('\\n').find(function(l){ return l.indexOf(' / ') !== -1; }) || '';
  var parts = line.split(' / ');
  var channelName = parts[0] || null;

  // Each connected member gets a sidebar row whose class name contains
  // "voiceUser" (Discord's own class names are hashed/unstable per release,
  // but this substring has held across the accounts/servers checked live).
  // Rows without a discordapp.com avatar background-image are non-member
  // rows (e.g. the "invite to channel" button), so filter on that instead
  // of trying to whitelist row shapes.
  var members = Array.from(document.querySelectorAll('[class*="voiceUser"]')).map(function(row){
    var avatarEl = Array.from(row.querySelectorAll('*')).find(function(e){
      var bg = getComputedStyle(e).backgroundImage;
      return bg && bg.indexOf('cdn.discordapp.com/avatars') !== -1;
    });
    if (!avatarEl) return null;
    var nameEl = Array.from(row.querySelectorAll('*')).find(function(e){
      return e.children.length === 0 && e.textContent && e.textContent.trim().length > 0;
    });
    var m = getComputedStyle(avatarEl).backgroundImage.match(/url\\("([^"]+)"\\)/);
    // Discord renders a small mic/deafen SVG next to a member's name only
    // while that state is active; no icon at all when a member is neither
    // muted nor deafened. Presence alone is the signal (locale-independent,
    // unlike matching the icon's describing text).
    var iconMuted = row.querySelector('[class*="iconGroup"]') !== null;
    return { name: nameEl ? nameEl.textContent.trim() : null, avatar: m ? m[1] : null, muted: iconMuted };
  }).filter(Boolean);

  var urlMatch = location.href.match(/\\/channels\\/(\\d+)\\/(\\d+)/);

  return JSON.stringify({
    connected: true,
    muted: muteEl ? muteEl.getAttribute('aria-checked') === 'true' : null,
    deafened: deafEl ? deafEl.getAttribute('aria-checked') === 'true' : null,
    channel: channelName,
    server: parts[1] || null,
    members: members,
    // Best-effort: reflects whichever channel is currently being VIEWED, which
    // is usually but not guaranteed to be the one voice-connected to (if the
    // user navigates elsewhere while staying in the call, this drifts).
    guildId: urlMatch ? urlMatch[1] : null,
    channelId: urlMatch ? urlMatch[2] : null
  });
})()`;
}

function clickExpr(label) {
  return `(function(){
    var el = document.querySelector('[aria-label=${JSON.stringify(label)}]');
    if (!el) return false;
    var rect = el.getBoundingClientRect();
    var x = rect.left + rect.width/2, y = rect.top + rect.height/2;
    ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(type){
      var Ev = type.indexOf('pointer') === 0 ? PointerEvent : MouseEvent;
      el.dispatchEvent(new Ev(type, {bubbles:true, cancelable:true, clientX:x, clientY:y, button:0}));
    });
    return true;
  })()`;
}

async function poll() {
  const target = await findDiscordTarget();
  if (!target) {
    writeState({ connected: null, error: 'discord-not-running', frequentRooms: topRooms() });
    return;
  }
  try {
    const raw = await evaluate(target.webSocketDebuggerUrl, statusExpr());
    const state = JSON.parse(raw);
    noteRoom(state);
    state.frequentRooms = topRooms();
    writeState(state);
  } catch {
    writeState({ connected: null, error: 'cdp-eval-failed', frequentRooms: topRooms() });
  }
}

// A cold page load (location.assign) does NOT auto-join a voice channel the
// way clicking it in the sidebar does (confirmed live: same URL, assign()
// leaves you disconnected, a real click connects) -- so it's only used to
// switch guilds when needed; the actual join is always the channel click
// below. Trying to click the guild's own rail icon directly was the first
// approach, but the rail virtualizes far-down servers out of the DOM
// entirely and no reliable scrollable ancestor could be identified live, so
// a plain navigation is used for the guild switch instead.
function navigateToGuildExpr(guildId) {
  return `location.assign('https://discord.com/channels/${guildId}')`;
}

function clickChannelByNameExpr(channelName) {
  return `(function(){
    var el = Array.from(document.querySelectorAll('[aria-label]')).find(function(e){
      var v = e.getAttribute('aria-label');
      return v && v.indexOf(${JSON.stringify(channelName)} + ' (') === 0;
    });
    if (!el) return false;
    var rect = el.getBoundingClientRect();
    var x = rect.left + rect.width/2, y = rect.top + rect.height/2;
    ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(type){
      var Ev = type.indexOf('pointer') === 0 ? PointerEvent : MouseEvent;
      el.dispatchEvent(new Ev(type, {bubbles:true, cancelable:true, clientX:x, clientY:y, button:0}));
    });
    return true;
  })()`;
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

async function handleCommand(cmd) {
  const target = await findDiscordTarget();
  if (!target) return { ok: false, error: 'discord-not-running' };

  if (cmd.startsWith('join:')) {
    let payload;
    try {
      payload = JSON.parse(Buffer.from(cmd.slice('join:'.length), 'base64').toString('utf8'));
    } catch {
      return { ok: false, error: 'bad-join-payload' };
    }
    const { guildId, channel } = payload;
    if (!/^\d+$/.test(guildId) || !channel) return { ok: false, error: 'bad-join-target' };
    try {
      const currentGuild = await evaluate(target.webSocketDebuggerUrl,
        `(location.href.match(/\\/channels\\/(\\d+)/) || [])[1] || null`);
      if (currentGuild !== guildId) {
        // The server rail virtualizes far-down icons out of the DOM entirely,
        // so finding-and-clicking one reliably needs scrolling a list whose
        // real scrollable ancestor turned out not to be reliably identifiable
        // (tried live, gave up). A URL navigation to the guild is reliable
        // regardless of rail scroll position -- it's a full page load, so it
        // can't itself join a voice channel (confirmed: only a real sidebar
        // click does that), but it correctly lands the channel list, and the
        // subsequent channel click below does the actual joining.
        await evaluate(target.webSocketDebuggerUrl, navigateToGuildExpr(guildId));
        // Give the fresh page a moment to boot before polling for the channel.
        // Confirmed live: 2.5s was too eager and Discord's own client briefly
        // shows a different (seemingly arbitrary default) guild while it's
        // still hydrating right after a cold navigation; 5s consistently
        // lands on the right one.
        await sleep(5000);
      }
      let clicked = false;
      for (let attempt = 0; attempt < 6 && !clicked; attempt++) {
        clicked = await evaluate(target.webSocketDebuggerUrl, clickChannelByNameExpr(channel));
        if (!clicked) await sleep(500);
      }
      return { ok: clicked, error: clicked ? undefined : 'channel-not-found' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  const label = cmd === 'mute' ? LABEL_MUTE : cmd === 'deafen' ? LABEL_DEAFEN : cmd === 'disconnect' ? LABEL_DISCONNECT : null;
  if (!label) return { ok: false, error: 'unknown-command' };
  try {
    const clicked = await evaluate(target.webSocketDebuggerUrl, clickExpr(label));
    return { ok: !!clicked };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

if (existsSync(SOCKET_FILE)) unlinkSync(SOCKET_FILE);
const server = createServer((socket) => {
  let buf = '';
  socket.on('data', (d) => { buf += d.toString(); });
  socket.on('end', async () => {
    const cmd = buf.trim();
    const result = await handleCommand(cmd);
    socket.end(JSON.stringify(result));
    poll();
  });
});
server.listen(SOCKET_FILE);

setInterval(poll, POLL_MS);
poll();
