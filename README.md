# omarchy-wireguard

WireGuard status and on/off toggle for the [Omarchy](https://omarchy.org/) bar.

A bar widget for a WireGuard tunnel managed by NetworkManager. The icon is lit
when the tunnel is up and dimmed when it is down. Clicking it opens a popup in
the style of the built-in network panel:

- on/off switch (`nmcli connection up/down`, no sudo needed),
- ping and packet loss through the tunnel,
- live receive/send rate, total downloaded/uploaded, tunnel IP, connection time,
- peer endpoint, allowed IPs and public key (click to copy),
- tunnel DNS server and lookup time through the tunnel.

State follows `nmcli monitor`, so changes made elsewhere show up immediately.
Ping and DNS probes only run while the popup is open.

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell`
- A WireGuard connection in NetworkManager (`nmcli connection import type wireguard file wg0.conf`)
- `ping`, `resolvectl` (systemd-resolved), `wl-copy`

## Install

```bash
omarchy plugin add https://github.com/marska/omarchy-wireguard.git --enable
```

Move it next to the network icon if you like:

```bash
omarchy bar move marska.wireguard --before omarchy.network
```

## Usage

| Action | Result |
|---|---|
| Left click | Open/close the popup |
| Right click | Toggle the tunnel without opening the popup |
| Middle click | Refresh |
| `w` / Enter in the popup | Toggle the tunnel |
| `r` in the popup | Refresh |

From a terminal or keybinding:

```bash
omarchy-shell marska.wireguard toggleTunnel
omarchy-shell marska.wireguard status
omarchy-shell marska.wireguard open
```

## Settings

Set them on the widget entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `connection` | `""` | NetworkManager connection to control; empty picks the first WireGuard connection |
| `pingHost` | `""` | Host pinged through the tunnel; empty uses the tunnel's DNS server |
| `dnsTestHost` | `"example.com"` | Name resolved through the tunnel to time DNS lookups |
| `refreshIntervalSec` | `60` | Fallback refresh interval while the popup is closed |

```json
{ "id": "marska.wireguard", "connection": "work-vpn", "pingHost": "10.0.0.1" }
```

## Limitations

- Only the first peer of a multi-peer connection is shown.
- Last handshake time is not shown: reading it (`wg show`) requires root.

## License

MIT
