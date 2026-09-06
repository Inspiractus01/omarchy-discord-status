import QtQuick
import QtQuick.Effects
import Quickshell.Io
import qs.Ui
import qs.Commons

// Discord voice-connection status. Backed by a small local daemon
// (~/.local/share/omarchy-discord-status/status-daemon.mjs, run as
// omarchy-discord-status.service) that polls the Discord web app over the
// Chrome DevTools Protocol and writes ~/.local/state/omarchy/indicators/
// discord-voice.json. Mute/disconnect here send real commands to that
// daemon, which clicks the actual Discord buttons -- not a simulated
// keypress -- so it stays correct regardless of keybind config.
Panel {
  id: root
  moduleName: "michal.discord-status"
  ipcTarget: "michal.discord-status"

  readonly property string stateFile: "/home/michal/.local/state/omarchy/indicators/discord-voice.json"
  readonly property string socketFile: "/home/michal/.local/state/omarchy/indicators/discord-voice.sock"

  property var status: ({ connected: null })

  function badgeColor() {
    if (root.status.connected === true) {
      return (root.status.muted || root.status.deafened) ? "red" : "green"
    }
    if (root.status.connected === false) return "grey"
    return "orange"
  }

  function statusLine() {
    if (root.status.connected === true) {
      var chan = root.status.channel || "?"
      var srv = root.status.server || "?"
      return chan + " / " + srv
    }
    if (root.status.connected === false) return "Not in a voice channel"
    return "Discord status unavailable"
  }

  function refresh() {
    if (!readProc.running) readProc.running = true
  }

  function sendCommand(cmd) {
    // Flip the local, displayed state immediately -- the round trip (socat ->
    // daemon -> CDP click -> daemon writes state -> this panel re-reads it)
    // is fast but not instant, and waiting for it back reads as a noticeable
    // delay on click. The next poll (or the refresh() below, once the command
    // process itself finishes) corrects this if the click didn't actually
    // take for some reason.
    var next = Object.assign({}, root.status)
    if (cmd === "mute") next.muted = !next.muted
    else if (cmd === "deafen") next.deafened = !next.deafened
    else if (cmd === "disconnect") next.connected = false
    root.status = next

    cmdProc.command = ["sh", "-c", "echo -n " + cmd + " | socat - UNIX-CONNECT:" + root.socketFile]
    if (!cmdProc.running) cmdProc.running = true
  }

  function joinRoom(guildId, channel) {
    var payload = JSON.stringify({ guildId: guildId, channel: channel })
    cmdProc.command = ["sh", "-c",
      "printf '%s' " + JSON.stringify(payload) + " | base64 -w0 | { read b64; echo -n \"join:$b64\" | socat - UNIX-CONNECT:" + root.socketFile + "; }"]
    if (!cmdProc.running) cmdProc.running = true
  }

  function openDiscord() {
    focusProc.command = ["sh", "-c",
      "hyprctl clients -j | jq -e '.[] | select(.class==\"brave-discord.com__channels_@me-Default\")' >/dev/null " +
      "&& hyprctl dispatch 'hl.dsp.focus({ window = [[class:^(brave-discord\\.com__channels_@me-Default)$]] })' " +
      "|| omarchy-launch-webapp https://discord.com/channels/@me --remote-debugging-port=9333"]
    if (!focusProc.running) focusProc.running = true
  }

  Process {
    id: readProc
    command: ["cat", root.stateFile]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.status = JSON.parse(text || "{}")
        } catch (e) {
          root.status = { connected: null }
        }
      }
    }
  }

  Process {
    id: cmdProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.refresh() }
  }

  Process {
    id: focusProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) refresh()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    onPressed: function(b) { root.toggle() }
    iconComponent: Component {
      Item {
        Image {
          id: discordImg
          anchors.fill: parent
          anchors.margins: Style.space(2)
          source: "file:///usr/share/icons/hicolor/48x48/apps/omarchy-discord.png"
          fillMode: Image.PreserveAspectFit
          smooth: true
          visible: false
          layer.enabled: true
        }
        MultiEffect {
          anchors.fill: discordImg
          source: discordImg
          colorization: 1.0
          colorizationColor: root.bar.foreground
        }
        Rectangle {
          width: Style.space(7)
          height: Style.space(7)
          radius: width / 2
          color: root.badgeColor()
          border.width: 1
          border.color: root.bar.background
          anchors.right: parent.right
          anchors.bottom: parent.bottom
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: Style.space(260)
    contentHeight: column.implicitHeight + Style.space(32)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(12)

      Text {
        text: "Discord"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        width: parent.width
        text: root.statusLine()
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        visible: root.status.connected === true
        text: (root.status.muted ? "Muted" : "Unmuted") + (root.status.deafened ? " · Deafened" : "")
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.status.connected === true && (root.status.members || []).length > 0

        Text {
          text: "In channel"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.status.members || []
          delegate: Row {
            spacing: Style.space(6)
            Image {
              width: Style.space(18)
              height: Style.space(18)
              source: modelData.avatar || ""
              fillMode: Image.PreserveAspectCrop
              smooth: true
            }
            Text {
              text: modelData.name || "?"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              visible: !!modelData.muted
              width: Style.space(6)
              height: Style.space(6)
              radius: width / 2
              color: "red"
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(10)
        visible: root.status.connected === true

        component IconToggle: Rectangle {
          id: toggle
          property string glyph: ""
          property bool active: false
          property string tip: ""
          signal activated()

          width: Style.space(32)
          height: Style.space(32)
          radius: 0
          color: "transparent"
          border.width: 1
          border.color: Qt.darker(root.bar.foreground, 1.3)

          Text {
            id: glyphText
            anchors.centerIn: parent
            text: toggle.glyph
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.icon
          }
          Rectangle {
            visible: toggle.active
            anchors.centerIn: parent
            width: parent.width * 0.8
            height: Style.space(2)
            radius: height / 2
            rotation: 45
            color: "red"
          }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: toggle.activated()
          }
        }

        IconToggle {
          glyph: ""
          active: !!root.status.muted
          tip: root.status.muted ? "Unmute" : "Mute"
          onActivated: root.sendCommand("mute")
        }

        IconToggle {
          glyph: ""
          active: !!root.status.deafened
          tip: root.status.deafened ? "Undeafen" : "Deafen"
          onActivated: root.sendCommand("deafen")
        }

        Rectangle {
          height: Style.space(32)
          width: disconnectText.implicitWidth + Style.space(16)
          radius: 0
          color: "transparent"
          border.width: 1
          border.color: "red"

          Text {
            id: disconnectText
            anchors.centerIn: parent
            text: "Disconnect"
            color: "red"
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.sendCommand("disconnect")
          }
        }
      }

      Button {
        text: "Open Discord"
        bordered: true
        onClicked: root.openDiscord()
      }

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: (root.status.frequentRooms || []).length > 0

        Repeater {
          model: root.status.frequentRooms || []
          delegate: Button {
            width: parent.width
            leftAlign: true
            bordered: true
            text: (modelData.kind === "popular" ? "★ " : "🕐 ") + (modelData.channel || "?") + " / " + (modelData.server || "?")
            onClicked: root.joinRoom(modelData.guildId, modelData.channel)
          }
        }
      }
    }
  }
}
