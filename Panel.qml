import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// WireGuard tunnel from NetworkManager: a bar button (lit when up, dimmed when
// down) with a popup in the style of the network panel — on/off switch, link
// stats, peer and DNS. Left click opens the popup, right click toggles the
// tunnel, middle click refreshes. State follows `nmcli monitor` events; the
// timer is only a fallback. Ping/DNS probes run only while the popup is open.
Panel {
  id: root
  moduleName: "marska.wireguard"
  ipcTarget: "marska.wireguard"
  // Owns the single IpcHandler the target permits, to add toggleTunnel/status.
  manageIpc: false

  readonly property string preferredConnection: setting("connection", "")
  readonly property int refreshIntervalSec: setting("refreshIntervalSec", 60)
  readonly property string pingHostSetting: setting("pingHost", "")
  readonly property string dnsTestHost: setting("dnsTestHost", "example.com")

  property var info: Model.parseStatus("")
  property bool missing: false
  property string lastError: ""

  readonly property bool connected: info.state === "activated"
  readonly property bool transitioning: info.state === "activating" || info.state === "deactivating"
  readonly property bool busy: toggleProc.running || transitioning
  readonly property string pingHost: pingHostSetting !== "" ? pingHostSetting : info.dns

  // Throughput from deltas between successive samples; a new device resets
  // the baseline so a reconnect doesn't manufacture a spike.
  property real prevRx: -1
  property real prevTx: -1
  property real prevSampleTime: 0
  property string prevDevice: ""
  property real downloadRate: 0
  property real uploadRate: 0

  property var pingSamples: []           // ms, -1 for a lost probe; newest last
  property real lastPingAt: 0
  readonly property int pingWindow: 20   // samples behind the ping and loss figures
  readonly property int pingHistory: 60  // samples in the chart: 2 min at one probe per 2 s
  readonly property var recentPings: pingSamples.slice(-pingWindow)
  readonly property real pingLatency: {
    var recent = recentPings.slice(-5).filter(function(v) { return v >= 0 })
    if (recent.length === 0) return -1
    return recent.reduce(function(a, b) { return a + b }, 0) / recent.length
  }
  readonly property int packetLoss: {
    if (recentPings.length === 0) return 0
    var lost = recentPings.filter(function(v) { return v < 0 }).length
    return Math.round(100 * lost / recentPings.length)
  }
  readonly property real pingJitter: Model.jitter(pingSamples)
  readonly property real pingMax: Math.max.apply(null, pingSamples.concat([-1]))
  property real dnsLookupMs: -2          // -2 = no sample yet, -1 = failed
  property real now: Date.now() / 1000

  readonly property string stateText: {
    if (missing) return "NO PROFILE"
    if (info.state === "activating") return "CONNECTING…"
    if (info.state === "deactivating") return "DISCONNECTING…"
    return connected ? "CONNECTED" : "DISCONNECTED"
  }

  readonly property string tooltip: {
    if (missing) return "WireGuard: no connection in NetworkManager"
    var name = info.name !== "" ? info.name : "WireGuard"
    if (lastError !== "") return name + ": " + lastError
    if (connected) return name + ": connected" + (info.address !== "" ? " (" + info.address + ")" : "")
    return name + ": " + stateText.toLowerCase()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function toggleTunnel() {
    if (missing || info.name === "" || toggleProc.running) return
    lastError = ""
    toggleProc.command = ["nmcli", "connection", connected ? "down" : "up", "id", info.name]
    toggleProc.running = true
  }

  function applyStatus(next) {
    var t = Date.now() / 1000
    if (next.device !== "" && next.device === prevDevice && prevRx >= 0 && t > prevSampleTime) {
      downloadRate = Math.max(0, (next.rx - prevRx) / (t - prevSampleTime))
      uploadRate = Math.max(0, (next.tx - prevTx) / (t - prevSampleTime))
    } else {
      downloadRate = 0
      uploadRate = 0
    }
    if (next.device !== prevDevice) {
      pingSamples = []
      dnsLookupMs = -2
    }
    prevDevice = next.device
    prevRx = next.rx
    prevTx = next.tx
    prevSampleTime = t
    now = t
    info = next
  }

  function pushPing(ms) {
    pingSamples = pingSamples.concat([ms]).slice(-pingHistory)
    lastPingAt = Date.now() / 1000
  }

  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", 'printf %s "$1" | wl-copy', "bash", value])
  }

  onPreferredConnectionChanged: refresh()
  onPingHostChanged: pingSamples = []
  onOpenedChanged: {
    if (!opened) return
    // Probes pause while the popup is closed; don't join old samples to new ones.
    if (Date.now() / 1000 - lastPingAt > 10) pingSamples = []
    refresh()
  }

  IpcHandler {
    target: "marska.wireguard"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleTunnel(): void { root.toggleTunnel() }
    function refresh(): void { root.refresh() }
    function status(): string { return root.tooltip }
  }

  Process {
    id: statusProc
    command: ["bash", "-c", Model.statusScript, "bash", root.preferredConnection]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.missing = exitCode !== 0
      root.applyStatus(Model.parseStatus(root.missing ? "" : statusOut.text))
    }
  }

  Process {
    id: toggleProc
    stderr: StdioCollector { id: toggleErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var message = String(toggleErr.text || "").trim().replace(/^Error:\s*/, "")
        root.lastError = message !== "" ? message : "nmcli exited with code " + exitCode
        Quickshell.execDetached(["notify-send", "-u", "critical", "WireGuard", root.lastError])
      }
      root.refresh()
    }
  }

  Process {
    id: pingProc
    command: ["env", "LC_ALL=C", "ping", "-n", "-c", "1", "-W", "1", root.pingHost]
    stdout: StdioCollector { id: pingOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.pushPing(exitCode === 0 ? Model.parsePing(pingOut.text) : -1)
    }
  }

  Process {
    id: dnsProc
    command: ["resolvectl", "query", "--cache=no", "-i", root.info.device, root.dnsTestHost]
    stdout: StdioCollector { id: dnsOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.dnsLookupMs = exitCode === 0 ? Model.parseDnsLookup(dnsOut.text) : -1
    }
  }

  // Every NM change prints a line; debounce them into one status read.
  // Restarts itself if nmcli monitor exits.
  Process {
    id: monitorProc
    running: true
    command: ["nmcli", "monitor"]
    stdout: SplitParser { onRead: function(line) { debounce.restart() } }
    onExited: restartMonitor.start()
  }

  Timer { id: restartMonitor; interval: 5000; onTriggered: monitorProc.running = true }
  Timer { id: debounce; interval: 300; onTriggered: root.refresh() }

  // 1.5 s while the popup is open (live rates), otherwise a slow fallback.
  Timer {
    interval: root.opened ? 1500 : Math.max(10, root.refreshIntervalSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 2000
    running: root.opened && root.connected && root.pingHost !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!pingProc.running) pingProc.running = true
  }

  Timer {
    interval: 5000
    running: root.opened && root.connected && root.info.device !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!dnsProc.running) dnsProc.running = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"
    dimmed: !root.connected || root.busy
    active: root.lastError !== "" || root.missing
    tooltipText: root.opened ? "" : root.tooltip
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleTunnel()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.toggleTunnel()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "w" || t === "W") root.toggleTunnel()
      }
    }

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      // ---------- Hero: icon · connection + state · switch ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

        Text {
          id: heroIcon
          textFormat: Text.PlainText
          text: "󰖂"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.display
          opacity: root.connected ? 1.0 : 0.5
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        ToggleSwitch {
          id: powerSwitch
          interactive: !root.missing
          checked: root.connected || root.info.state === "activating"
          busy: root.busy
          foreground: root.bar.foreground
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onToggled: root.toggleTunnel()

          PanelToolTip {
            visible: powerSwitch.containsMouse
            text: root.connected ? "Disconnect VPN (w)" : "Connect VPN (w)"
            fontFamily: root.bar.fontFamily
          }
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: powerSwitch.left
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.info.name !== "" ? root.info.name : "WireGuard"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.lastError !== "" ? root.lastError.toUpperCase() : root.stateText
            color: root.lastError !== "" ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
          }
        }
      }

      // ---------- Link stats ----------
      GridLayout {
        visible: root.connected
        width: parent.width
        columns: 4
        columnSpacing: Style.space(20)
        rowSpacing: Style.spacing.labelGap

        InfoLabel { text: "Ping" }
        DetailValue {
          text: root.pingSamples.length === 0 ? "--" : Model.formatMs(root.pingLatency)
          color: root.packetLoss > 0 ? root.bar.urgent : root.bar.foreground
          tooltipText: root.pingHost !== "" ? "Ping to " + root.pingHost + " through the tunnel" : ""
          hoverTip: true
        }
        InfoLabel { text: "Packet Loss" }
        DetailValue {
          text: root.pingSamples.length === 0 ? "--" : root.packetLoss + "%"
          color: root.packetLoss > 0 ? root.bar.urgent : root.bar.foreground
        }

        InfoLabel { text: "Receiving" }
        DetailValue { text: root.info.rx >= 0 ? Model.formatRate(root.downloadRate) : "--" }
        InfoLabel { text: "Sending" }
        DetailValue { text: root.info.tx >= 0 ? Model.formatRate(root.uploadRate) : "--" }

        InfoLabel { text: "Downloaded" }
        DetailValue { text: root.info.rx >= 0 ? Model.formatBytes(root.info.rx) : "--" }
        InfoLabel { text: "Uploaded" }
        DetailValue { text: root.info.tx >= 0 ? Model.formatBytes(root.info.tx) : "--" }

        InfoLabel { text: "IP Address" }
        DetailValue {
          text: root.info.address || "--"
          copyable: !!root.info.address
          tooltipText: "Copy IP"
        }
        InfoLabel { text: "Uptime" }
        DetailValue { text: root.info.since > 0 ? Model.formatDuration(root.now - root.info.since) : "--" }
      }

      // ---------- Ping history ----------
      // Last 2 min of pings, newest on the right, scaled from 0 so a steady
      // link reads as a flat line. Lost probes break the line with a red bar.
      Column {
        visible: root.connected
        width: parent.width
        spacing: Style.spacing.labelGap

        Item {
          id: pingChart
          width: parent.width
          height: Style.space(36)
          clip: true

          readonly property var samples: root.pingSamples
          readonly property real lineWidth: Math.max(1, Style.space(1.5))
          readonly property real step: width / Math.max(1, root.pingHistory - 1)
          // Headroom above the worst sample; the floor keeps sub-ms LAN noise flat.
          readonly property real peak: Math.max(5, 1.15 * root.pingMax)

          function xAt(i) { return width - (samples.length - 1 - i) * step }
          function yAt(ms) { return lineWidth + (height - 2 * lineWidth) * (1 - ms / peak) }

          readonly property var segments: {
            var out = []
            var run = []
            for (var i = 0; i <= samples.length; i++) {
              if (i < samples.length && samples[i] >= 0) {
                run.push(Qt.point(xAt(i), yAt(samples[i])))
                continue
              }
              // A lone sample between losses has no neighbour; draw it as a dash.
              if (run.length === 1) run = [Qt.point(run[0].x - step / 2, run[0].y), Qt.point(run[0].x + step / 2, run[0].y)]
              if (run.length > 0) out.push(run)
              run = []
            }
            return out
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.spacing.hairline
            color: root.bar.foreground
            opacity: 0.15
          }

          Repeater {
            model: pingChart.samples.length
            Rectangle {
              visible: pingChart.samples[index] < 0
              x: pingChart.xAt(index) - width / 2
              width: Math.max(2, Style.space(2))
              height: pingChart.height
              color: root.bar.urgent
              opacity: 0.5
            }
          }

          Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
              strokeColor: root.bar.foreground
              strokeWidth: pingChart.lineWidth
              fillColor: "transparent"
              joinStyle: ShapePath.RoundJoin
              capStyle: ShapePath.RoundCap
              PathMultiline { paths: pingChart.segments }
            }
          }
        }

        Item {
          width: parent.width
          implicitHeight: chartSpan.implicitHeight

          InfoLabel {
            id: chartSpan
            anchors.left: parent.left
            text: "Last 2 min"
          }
          InfoLabel {
            anchors.right: parent.right
            visible: root.pingMax >= 0
            text: (root.pingJitter >= 0 ? "Jitter " + Model.formatMs(root.pingJitter) + " · " : "") + "Max " + Model.formatMs(root.pingMax)
          }
        }
      }

      // ---------- Peer ----------
      PanelSeparator {
        visible: root.info.peerKey !== ""
        foreground: root.bar.foreground
      }

      Column {
        visible: root.info.peerKey !== ""
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "PEER"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        GridLayout {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(20)
          rowSpacing: Style.spacing.labelGap

          InfoLabel { text: "Endpoint" }
          DetailValue {
            text: root.info.endpoint || "--"
            copyable: !!root.info.endpoint
            tooltipText: "Copy endpoint"
          }
          InfoLabel { text: "Allowed IPs" }
          DetailValue { text: root.info.allowedIps || "--" }
          InfoLabel { text: "Public Key" }
          DetailValue {
            text: Model.shortKey(root.info.peerKey)
            copyable: root.info.peerKey !== ""
            copyValue: root.info.peerKey
            tooltipText: "Copy full key"
          }
        }
      }

      // ---------- DNS ----------
      PanelSeparator {
        visible: root.connected
        foreground: root.bar.foreground
      }

      Column {
        visible: root.connected
        width: parent.width
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "DNS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        GridLayout {
          width: parent.width
          columns: 4
          columnSpacing: Style.space(20)
          rowSpacing: Style.spacing.labelGap

          InfoLabel { text: "Server" }
          DetailValue {
            text: root.info.dns || "--"
            copyable: !!root.info.dns
            tooltipText: "Copy DNS address"
          }
          InfoLabel { text: "Lookup" }
          DetailValue {
            text: root.dnsLookupMs === -2 ? "--" : (root.dnsLookupMs < 0 ? "Failed" : Model.formatMs(root.dnsLookupMs))
            color: root.dnsLookupMs === -1 ? root.bar.urgent : root.bar.foreground
            tooltipText: "Time to resolve " + root.dnsTestHost + " through the tunnel"
            hoverTip: true
          }
        }
      }
    }
  }

  component DetailValue: InfoValue {
    property bool copyable: false
    property bool hoverTip: false
    property string copyValue: text
    property string tooltipText: "Copy to clipboard"

    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight

    MouseArea {
      id: valueMouse
      anchors.fill: parent
      enabled: (copyable && parent.text !== "") || parent.hoverTip
      hoverEnabled: enabled
      cursorShape: copyable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (copyable) root.copyToClipboard(parent.copyValue)
    }

    PanelToolTip {
      visible: valueMouse.enabled && valueMouse.containsMouse && tooltipText !== ""
      text: tooltipText
      fontFamily: root.bar.fontFamily
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
