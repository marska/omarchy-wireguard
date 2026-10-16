.pragma library

// Prints the tunnel's state as KEY:VALUE lines (nmcli -t format plus our own
// NAME/RX/TX/SINCE). $1 is the configured connection; empty picks the first
// WireGuard profile. An inactive profile prints no GENERAL.* lines, which
// reads as "down". Exit 3 means no such profile.
var statusScript = `
name=$1
if [ -z "$name" ]; then
  name=$(nmcli -t -f TYPE,NAME connection show | sed -n 's/^wireguard://p' | head -n1 | sed 's/\\\\:/:/g')
fi
[ -n "$name" ] || exit 3
out=$(nmcli -t -f GENERAL.STATE,GENERAL.DEVICES,IP4.ADDRESS,IP4.DNS,wireguard.peers connection show id "$name") || exit 3
printf 'NAME:%s\\n%s\\n' "$name" "$out"
dev=$(printf '%s\\n' "$out" | sed -n 's/^GENERAL.DEVICES://p')
sys=/sys/class/net/$dev
if [ -n "$dev" ] && [ -d "$sys" ]; then
  printf 'RX:%s\\nTX:%s\\nSINCE:%s\\n' "$(cat "$sys/statistics/rx_bytes")" "$(cat "$sys/statistics/tx_bytes")" "$(stat -c %Z "$sys")"
fi
`

function parseStatus(text) {
  var result = { name: "", state: "", device: "", address: "", dns: "", peerKey: "", endpoint: "", allowedIps: "", rx: -1, tx: -1, since: 0 }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var sep = line.indexOf(":")
    if (sep < 0) continue
    var key = line.slice(0, sep)
    var value = line.slice(sep + 1)
    if (key === "NAME") result.name = value
    else if (key === "GENERAL.STATE") result.state = value
    else if (key === "GENERAL.DEVICES") result.device = value
    else if (key.indexOf("IP4.ADDRESS") === 0 && result.address === "") result.address = value
    else if (key.indexOf("IP4.DNS") === 0 && result.dns === "") result.dns = value
    else if (key === "wireguard.peers") parsePeer(value, result)
    else if (key === "RX") result.rx = Number(value)
    else if (key === "TX") result.tx = Number(value)
    else if (key === "SINCE") result.since = Number(value)
  }
  return result
}

// "<public key> allowed-ips=a,b endpoint=host:port"; only the first peer of a
// multi-peer profile (separated by ";") is shown.
function parsePeer(value, result) {
  var parts = String(value).split(";")[0].trim().split(/\s+/)
  result.peerKey = parts[0] || ""
  for (var i = 1; i < parts.length; i++) {
    var part = parts[i]
    if (part.indexOf("allowed-ips=") === 0) result.allowedIps = part.slice(12).replace(/,/g, ", ")
    else if (part.indexOf("endpoint=") === 0) result.endpoint = part.slice(9)
  }
}

function parsePing(text) {
  var match = /time[=<]([0-9.]+)/.exec(String(text || ""))
  return match ? parseFloat(match[1]) : -1
}

function parseDnsLookup(text) {
  var match = /in ([0-9.]+)\s*ms/.exec(String(text || ""))
  return match ? parseFloat(match[1]) : -1
}

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n < 1024) return Math.round(n) + " B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
  return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}

function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

function formatMs(ms) {
  var value = parseFloat(ms)
  if (!isFinite(value) || value < 0) return "Timeout"
  return value.toFixed(value > 0 && value < 10 ? 1 : 0) + " ms"
}

function formatDuration(seconds) {
  var s = Math.max(0, Math.floor(seconds))
  var d = Math.floor(s / 86400)
  var h = Math.floor((s % 86400) / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (d > 0) return d + " d " + h + " h"
  if (h > 0) return h + " h " + m + " min"
  if (m > 0) return m + " min"
  return s + " s"
}

function shortKey(key) {
  var k = String(key || "")
  return k.length > 16 ? k.slice(0, 8) + "…" + k.slice(-6) : k
}
