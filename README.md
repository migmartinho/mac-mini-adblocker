# mac-mini-adblocker

A complete, self-hosted DNS ad-blocking and privacy stack for an Apple Silicon Mac Mini (M1, 8 GB RAM, macOS Tahoe 26.x) that integrates with an existing WireGuard VPN server.

---

## What This Repository Provides

| Component | Role |
|---|---|
| **AdGuard Home** | DNS-level ad/tracker blocker with a web dashboard |
| **Unbound** | Local recursive DNS resolver (no dependency on Google/Cloudflare) |
| **WireGuard** | Existing VPN server — clients routed through AdGuard Home |
| **LaunchDaemons** | macOS-native service management (starts everything at boot) |

---

## Quick Start

```bash
# 1. Clone the repository onto your Mac Mini
git clone https://github.com/migmartinho/mac-mini-adblocker.git
cd mac-mini-adblocker

# 2. Run the installation script (requires Homebrew)
sudo bash scripts/install.sh

# 3. Open the AdGuard Home dashboard
open http://localhost:3000
```

> **Detailed instructions:** see [TUTORIAL.md](TUTORIAL.md)

---

## Architecture Overview

```
VPN Clients (phones, laptops, …)
        │  WireGuard tunnel (UDP 51820)
        ▼
  Mac Mini – wg0 (10.0.0.1)
        │  DNS queries → port 53
        ▼
  AdGuard Home  (127.0.0.1:53 + 10.0.0.1:53)
        │  blocklists applied, dashboard updated
        ▼
  Unbound  (127.0.0.1:5335)
        │  recursive resolution, DNSSEC
        ▼
  Root DNS Servers  (.)
```

Optionally, by pointing your router's DHCP DNS option to the Mac Mini's LAN IP, every device on your Wi-Fi/Ethernet network benefits from the same ad-blocking without needing to be connected to the VPN.

---

## Repository Layout

```
mac-mini-adblocker/
├── README.md                        ← this file
├── TUTORIAL.md                      ← step-by-step setup guide
├── docs/
│   ├── architecture.md              ← detailed architecture & data flow
│   ├── motivation.md                ← why these tools were chosen
│   └── troubleshooting.md           ← common issues & fixes
├── configs/
│   ├── adguard-home/
│   │   └── AdGuardHome.yaml         ← AdGuard Home configuration
│   ├── unbound/
│   │   ├── unbound.conf             ← Unbound configuration
│   │   └── root.hints.instructions  ← how to download root hints
│   ├── wireguard/
│   │   └── wg0.conf.example         ← WireGuard server config template
│   └── launchdaemons/
│       ├── homebrew.mxcl.adguardhome.plist
│       └── homebrew.mxcl.unbound.plist
└── scripts/
    ├── install.sh                   ← one-shot install orchestrator
    ├── setup-adguard.sh             ← install & configure AdGuard Home
    ├── setup-unbound.sh             ← install & configure Unbound
    └── setup-wireguard-dns.sh       ← patch WireGuard to use AdGuard DNS
```

---

## Supported Blocking Modes

| Mode | How | DNS coverage |
|---|---|---|
| **VPN-only** (default) | AdGuard Home listens on `10.0.0.1:53`; WireGuard pushes `DNS = 10.0.0.1` to clients | Only VPN clients |
| **LAN-wide** (optional) | AdGuard Home also listens on the Mac Mini's LAN IP; router DHCP uses that IP as DNS | All devices on Wi-Fi/Ethernet + VPN |

---

## Requirements

- macOS Tahoe 26.x on Apple Silicon (M1 or later)
- [Homebrew](https://brew.sh) installed
- WireGuard already installed and running (kernel extension via `wireguard-go` or native `utun`)
- Port **53 (UDP/TCP)** available (disable macOS mDNS on that port if needed — see [TUTORIAL.md](TUTORIAL.md))
- Port **3000 (TCP)** available for the AdGuard Home initial setup UI
- Firewall rules allowing VPN clients to reach `10.0.0.1:53`

---

## License

MIT
