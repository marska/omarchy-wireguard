import QtQuick
import QtQuick.Layouts
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

  property var pingSamples: []           // ms, -1 for a lost probe
  readonly property int pingWindow: 20
  readonly property real pingLatency: {
    var recent = pingSamples.slice(-5).filter(function(v) { return v >= 0 })
    if (recent.length === 0) return -1
    return recent.reduce(function(a, b) { return a + b }, 0) / recent.length
  }
  readonly property int packetLoss: {
    if (pingSamples.length === 0) return 0
    var lost = pingSamples.filter(function(v) { return v < 0 }).length
    return Math.round(100 * lost / pingSamples.length)
  }
  property real dnsLookupMs: -2          // -2 = no sample yet, -1 = failed
  property real now: Date.now() / 1000

  readonly property string stateText: {
    if (missing) return "BRAK PROFILU"
    if (info.state === "activating") return "ŁĄCZENIE…"
    if (info.state === "deactivating") return "ROZŁĄCZANIE…"
    return connected ? "POŁĄCZONY" : "ROZŁĄCZONY"
  }

  readonly property string tooltip: {
    if (missing) return "WireGuard: brak połączenia w NetworkManagerze"
    var name = info.name !== "" ? info.name : "WireGuard"
    if (lastError !== "") return name + ": " + lastError
    if (connected) return name + ": połączony" + (info.address !== "" ? " (" + info.address + ")" : "")
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
    pingSamples = pingSamples.concat([ms]).slice(-pingWindow)
  }

  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", 'printf %s "$1" | wl-copy', "bash", value])
  }

  onPreferredConnectionChanged: refresh()
  onPingHostChanged: pingSamples = []
  onOpenedChanged: if (opened) refresh()

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
        root.lastError = message !== "" ? message : "nmcli zakończył się kodem " + exitCode
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
            text: root.connected ? "Rozłącz VPN (w)" : "Połącz VPN (w)"
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
          tooltipText: root.pingHost !== "" ? "Ping do " + root.pingHost + " przez tunel" : ""
          hoverTip: true
        }
        InfoLabel { text: "Utrata" }
        DetailValue {
          text: root.pingSamples.length === 0 ? "--" : root.packetLoss + "%"
          color: root.packetLoss > 0 ? root.bar.urgent : root.bar.foreground
        }

        InfoLabel { text: "Odbieranie" }
        DetailValue { text: root.info.rx >= 0 ? Model.formatRate(root.downloadRate) : "--" }
        InfoLabel { text: "Wysyłanie" }
        DetailValue { text: root.info.tx >= 0 ? Model.formatRate(root.uploadRate) : "--" }

        InfoLabel { text: "Pobrane" }
        DetailValue { text: root.info.rx >= 0 ? Model.formatBytes(root.info.rx) : "--" }
        InfoLabel { text: "Wysłane" }
        DetailValue { text: root.info.tx >= 0 ? Model.formatBytes(root.info.tx) : "--" }

        InfoLabel { text: "Adres IP" }
        DetailValue {
          text: root.info.address || "--"
          copyable: !!root.info.address
          tooltipText: "Kopiuj IP"
        }
        InfoLabel { text: "Czas" }
        DetailValue { text: root.info.since > 0 ? Model.formatDuration(root.now - root.info.since) : "--" }
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
            tooltipText: "Kopiuj endpoint"
          }
          InfoLabel { text: "Allowed IPs" }
          DetailValue { text: root.info.allowedIps || "--" }
          InfoLabel { text: "Klucz publiczny" }
          DetailValue {
            text: Model.shortKey(root.info.peerKey)
            copyable: root.info.peerKey !== ""
            copyValue: root.info.peerKey
            tooltipText: "Kopiuj pełny klucz"
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

          InfoLabel { text: "Serwer" }
          DetailValue {
            text: root.info.dns || "--"
            copyable: !!root.info.dns
            tooltipText: "Kopiuj adres DNS"
          }
          InfoLabel { text: "Zapytanie" }
          DetailValue {
            text: root.dnsLookupMs === -2 ? "--" : (root.dnsLookupMs < 0 ? "Błąd" : Model.formatMs(root.dnsLookupMs))
            color: root.dnsLookupMs === -1 ? root.bar.urgent : root.bar.foreground
            tooltipText: "Czas rozwiązania " + root.dnsTestHost + " przez tunel"
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
    property string tooltipText: "Kopiuj do schowka"

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
