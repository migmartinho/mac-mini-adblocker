# Tutorial: Setting Up an Ad-Blocker on a Mac Mini M1 with WireGuard VPN

This tutorial walks you through installing and configuring a complete DNS-based ad-blocking stack on a Mac Mini M1 running macOS Tahoe (26.x). By the end, every device connected to your WireGuard VPN will automatically have ads and tracking domains blocked at the DNS level. An optional second step shows you how to extend blocking to all devices on your local network.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Architecture at a Glance](#2-architecture-at-a-glance)
3. [Step 1 – Install Homebrew](#3-step-1--install-homebrew)
4. [Step 2 – Install and Configure Unbound](#4-step-2--install-and-configure-unbound)
5. [Step 3 – Install and Configure AdGuard Home](#5-step-3--install-and-configure-adguard-home)
6. [Step 4 – Integrate with WireGuard VPN](#6-step-4--integrate-with-wireguard-vpn)
7. [Step 5 – (Optional) LAN-Wide Blocking](#7-step-5--optional-lan-wide-blocking)
8. [Step 6 – Enable Services at Boot](#8-step-6--enable-services-at-boot)
9. [Step 7 – Verify Everything Works](#9-step-7--verify-everything-works)
10. [Using the AdGuard Home Dashboard](#10-using-the-adguard-home-dashboard)
11. [Maintenance](#11-maintenance)

---

## 1. Prerequisites

Before you start, make sure:

- Your Mac Mini is running **macOS Tahoe 26.x** on Apple Silicon (M1).
- You have **administrator (sudo) access**.
- **WireGuard** is already installed and your server is working.
  - The WireGuard interface is `utun*` (or `wg0` if using `wireguard-go`) with the server-side IP `10.0.0.1/24`.
  - The server listens on UDP port `51820`.
- **Port 53** is free. macOS Monterey and later can have `mDNSResponder` occupying port 53; see the troubleshooting note below.
- **Port 3000** is free for the AdGuard Home initial web setup.

### Check port 53 availability

```bash
sudo lsof -i UDP:53
sudo lsof -i TCP:53
```

If `mDNSResponder` appears, you can still proceed — AdGuard Home can be configured to listen only on specific interfaces (`10.0.0.1` and `127.0.0.1`) where mDNSResponder does **not** bind.

---

## 2. Architecture at a Glance

```
VPN Clients (phones, laptops)
      │
      │  WireGuard tunnel  (UDP 51820)
      ▼
Mac Mini – wg0 / utun (10.0.0.1)
      │
      │  DNS queries  →  10.0.0.1:53
      ▼
AdGuard Home   (listens on 10.0.0.1:53 and 127.0.0.1:53)
      │  apply blocklists, log queries, serve dashboard
      ▼
Unbound   (listens on 127.0.0.1:5335)
      │  recursive resolver, DNSSEC validation
      ▼
Root DNS servers  (a.root-servers.net, …)
```

**Optional LAN extension:**

```
Wi-Fi / Ethernet clients
      │
      │  DHCP DNS = 192.168.1.x  (Mac Mini LAN IP)
      ▼
AdGuard Home   (also listens on 192.168.1.x:53)
      │  … same chain as above
```

---

## 3. Step 1 – Install Homebrew

If you do not already have Homebrew:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then add it to your shell path (Apple Silicon path):

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Verify:

```bash
brew --version
```

---

## 4. Step 2 – Install and Configure Unbound

Unbound is a validating, recursive DNS resolver. Running it locally means your DNS queries never leave your machine in plain text — they go straight to the root servers.

### 4.1 Install Unbound

```bash
brew install unbound
```

### 4.2 Download the Root Hints File

The root hints file tells Unbound where the 13 root DNS server clusters are. Download the authoritative copy from IANA:

```bash
curl -o /opt/homebrew/etc/unbound/root.hints \
     https://www.internic.net/domain/named.cache
```

Set a monthly cron job to keep it fresh:

```bash
(crontab -l 2>/dev/null; echo "0 3 1 * * curl -sS -o /opt/homebrew/etc/unbound/root.hints https://www.internic.net/domain/named.cache") | crontab -
```

### 4.3 Deploy the Unbound Configuration

Copy the provided configuration:

```bash
cp configs/unbound/unbound.conf /opt/homebrew/etc/unbound/unbound.conf
```

The configuration makes Unbound:
- Listen on `127.0.0.1:5335` (only AdGuard Home talks to it, not external clients).
- Perform full recursive resolution starting from root servers.
- Validate DNSSEC.
- Cache results aggressively (up to 8 MB) to reduce latency.
- Use the `root.hints` file you just downloaded.

### 4.4 Validate the Configuration

```bash
/opt/homebrew/sbin/unbound-checkconf /opt/homebrew/etc/unbound/unbound.conf
```

Expected output: `unbound-checkconf: no errors in ...`

### 4.5 Start Unbound

```bash
sudo brew services start unbound
```

### 4.6 Test Unbound

```bash
dig @127.0.0.1 -p 5335 example.com
```

You should see a valid `ANSWER SECTION`. If you also see `flags: … ad;` it means DNSSEC validation is working.

---

## 5. Step 3 – Install and Configure AdGuard Home

AdGuard Home is the Pi-Hole equivalent that natively supports macOS and Apple Silicon. It provides a modern dashboard, extensive blocklists, DNS-over-HTTPS/TLS client support, and per-client statistics.

### 5.1 Download AdGuard Home

```bash
# Download the latest ARM64 release
curl -Lo /tmp/AdGuardHome_darwin_arm64.tar.gz \
  "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_darwin_arm64.tar.gz"

tar -xzf /tmp/AdGuardHome_darwin_arm64.tar.gz -C /tmp/
sudo cp /tmp/AdGuardHome/AdGuardHome /usr/local/bin/AdGuardHome
sudo chmod +x /usr/local/bin/AdGuardHome
```

Create the working directory:

```bash
sudo mkdir -p /opt/AdGuardHome
```

### 5.2 Copy the Configuration File

```bash
sudo cp configs/adguard-home/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml
```

Review `/opt/AdGuardHome/AdGuardHome.yaml` and change the `password` hash to your own. Generate a bcrypt hash:

```bash
# Install htpasswd utility if needed
brew install httpd

# Generate a bcrypt hash for your chosen password
htpasswd -bnBC 10 "" "your-password-here" | tr -d ':\n' | sed 's/$2y/$2a/'
```

Replace the `password:` field in `AdGuardHome.yaml` with the output.

### 5.3 Run the Initial Setup Wizard (first time only)

```bash
sudo /usr/local/bin/AdGuardHome -s install
sudo /usr/local/bin/AdGuardHome -s start
```

Open `http://localhost:3000` in your browser and complete the setup wizard:

1. **Admin interface:** leave as `0.0.0.0:3000` or restrict to `127.0.0.1:3000`.
2. **DNS server:** set the listening address to `0.0.0.0:53` — you will restrict this in the config file.
3. **Admin username / password:** choose something secure.
4. After the wizard, **stop the service** so you can deploy the repository config:

```bash
sudo /usr/local/bin/AdGuardHome -s stop
sudo cp configs/adguard-home/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml
sudo /usr/local/bin/AdGuardHome -s start
```

> **Note:** If you ran the wizard first, the wizard writes its own `AdGuardHome.yaml`. Overwriting with the repository config replaces all settings. Make sure you updated the `password` hash first (step 5.2).

### 5.4 Verify AdGuard Home Is Running

```bash
sudo /usr/local/bin/AdGuardHome -s status
```

Test DNS resolution through AdGuard Home:

```bash
dig @127.0.0.1 -p 53 example.com
dig @10.0.0.1  -p 53 doubleclick.net   # should return NXDOMAIN or 0.0.0.0
```

---

## 6. Step 4 – Integrate with WireGuard VPN

Tell WireGuard clients to use the Mac Mini's VPN tunnel IP (`10.0.0.1`) as their DNS server. This is done in **two places**:

### 6.1 Server Side — wg0.conf

Edit your WireGuard server configuration (usually `/etc/wireguard/wg0.conf` or managed via the WireGuard app):

```ini
[Interface]
Address    = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <server-private-key>

# Route all client traffic through the VPN (optional – for full-tunnel mode)
PostUp   = sysctl -w net.inet.ip.forwarding=1
PostDown = sysctl -w net.inet.ip.forwarding=0

[Peer]
# example peer
PublicKey  = <client-public-key>
AllowedIPs = 10.0.0.2/32
```

See `configs/wireguard/wg0.conf.example` for a complete annotated example.

### 6.2 Client Side — DNS Configuration

Each WireGuard **client** config must include:

```ini
[Interface]
Address    = 10.0.0.2/32
PrivateKey = <client-private-key>
DNS        = 10.0.0.1        # ← AdGuard Home on the Mac Mini
```

When a client connects, WireGuard automatically configures the system DNS to `10.0.0.1`. All DNS lookups on that device are now routed through AdGuard Home → Unbound → Root servers, with ad blocking applied.

### 6.3 Enable IP Forwarding on macOS

For WireGuard to route traffic correctly, IP forwarding must be enabled:

```bash
sudo sysctl -w net.inet.ip.forwarding=1
```

To persist across reboots, add a sysctl configuration file:

```bash
sudo bash -c 'echo "net.inet.ip.forwarding=1" > /etc/sysctl.conf'
```

### 6.4 Firewall — Allow DNS from the VPN Subnet

Open port 53 for WireGuard clients using the built-in macOS packet filter:

```bash
# Check current rules
sudo pfctl -sr

# Add rule (add to /etc/pf.conf under existing rules)
# pass in on utun0 proto { tcp udp } from 10.0.0.0/24 to 10.0.0.1 port 53
```

Alternatively, if you use the macOS Application Firewall, ensure that `AdGuardHome` is allowed to accept incoming connections (System Settings → Network → Firewall → Options).

---

## 7. Step 5 – (Optional) LAN-Wide Blocking

To extend ad-blocking to all devices on your local Wi-Fi/Ethernet network — without requiring them to connect to the VPN — do the following.

### 7.1 Find the Mac Mini's LAN IP

```bash
ipconfig getifaddr en0   # Ethernet
ipconfig getifaddr en1   # Wi-Fi
```

Suppose the result is `192.168.1.100`.

### 7.2 Add the LAN IP to AdGuard Home's Listening Addresses

Edit `/opt/AdGuardHome/AdGuardHome.yaml` and add the LAN IP to the `bind_hosts` list:

```yaml
dns:
  bind_hosts:
    - 127.0.0.1
    - 10.0.0.1       # WireGuard VPN interface
    - 192.168.1.100  # LAN IP – add this line
  port: 53
```

Restart AdGuard Home:

```bash
sudo /usr/local/bin/AdGuardHome -s restart
```

### 7.3 Configure Your Router's DHCP

Log in to your router and set the **Primary DNS** in the DHCP server settings to `192.168.1.100` (the Mac Mini's LAN IP). Leave the **Secondary DNS** as your router's IP or an external resolver as a fallback.

All new DHCP leases (devices reconnecting to the network) will now use AdGuard Home for DNS.

> **Assign a static IP** to the Mac Mini so the IP never changes. In your router's DHCP settings, bind the Mac Mini's MAC address to `192.168.1.100`.

---

## 8. Step 6 – Enable Services at Boot

Both Unbound and AdGuard Home must start automatically when the Mac Mini reboots.

### 8.1 Unbound (via Homebrew Services)

```bash
sudo brew services enable unbound
sudo brew services start unbound
```

### 8.2 AdGuard Home (built-in service installer)

```bash
# Register as a launchdaemon (runs as root, starts at boot)
sudo /usr/local/bin/AdGuardHome -s install
sudo /usr/local/bin/AdGuardHome -s start
```

Verify both services:

```bash
sudo brew services list | grep unbound
sudo /usr/local/bin/AdGuardHome -s status
```

### 8.3 Persist IP Forwarding

As noted in step 6.3:

```bash
sudo bash -c 'echo "net.inet.ip.forwarding=1" > /etc/sysctl.conf'
```

---

## 9. Step 7 – Verify Everything Works

### 9.1 Query Through the Full Stack

```bash
# Should return 0.0.0.0 or NXDOMAIN for an ad domain:
dig @10.0.0.1 doubleclick.net

# Should resolve normally:
dig @10.0.0.1 github.com
```

### 9.2 DNSSEC Validation

```bash
# Should return SERVFAIL (bogus DNSSEC signature intentionally broken):
dig @127.0.0.1 -p 5335 dnssec-failed.org

# Should resolve with 'ad' flag (authenticated):
dig @127.0.0.1 -p 5335 internetsociety.org
```

### 9.3 Test from a VPN Client

Connect a device to your WireGuard VPN and browse to `http://10.0.0.1:3000` (the dashboard). Open a browser and navigate to an ad-heavy website — ads should not load.

---

## 10. Using the AdGuard Home Dashboard

Access the dashboard at: **`http://<mac-mini-lan-ip>:3000`** (or `http://localhost:3000` from the Mac Mini itself)

| Section | What It Shows |
|---|---|
| **Dashboard** | Real-time queries, blocked percentage, top blocked domains |
| **Query Log** | Every DNS query with timestamp, client IP, and block status |
| **Filters** | Manage blocklists — add/remove lists, see last update time |
| **DNS Rewrites** | Custom local DNS entries (e.g., `nas.local → 192.168.1.50`) |
| **Clients** | Per-device statistics and per-client filter overrides |
| **Settings → DNS** | Upstream resolver, caching, DNSSEC, Safe Browsing |

### Recommended Blocklists

The provided configuration already includes these, but you can add more in **Filters → DNS blocklists → Add blocklist**:

| List | URL |
|---|---|
| AdGuard DNS filter | `https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt` |
| EasyList | `https://easylist.to/easylist/easylist.txt` |
| EasyPrivacy | `https://easylist.to/easylist/easyprivacy.txt` |
| Steven Black Hosts | `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts` |
| OISD (Big) | `https://big.oisd.nl/domainswild` |

---

## 11. Maintenance

### Update Blocklists

AdGuard Home updates blocklists automatically based on the `filters.update_interval` setting (set to `24` hours in the provided config). You can also trigger a manual update: **Filters → Update Now**.

### Update Unbound Root Hints

The cron job you set in step 4.2 handles this monthly. To run it manually:

```bash
curl -sS -o /opt/homebrew/etc/unbound/root.hints https://www.internic.net/domain/named.cache
sudo brew services restart unbound
```

### Update AdGuard Home

```bash
sudo /usr/local/bin/AdGuardHome -s stop

curl -Lo /tmp/AdGuardHome_darwin_arm64.tar.gz \
  "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_darwin_arm64.tar.gz"
tar -xzf /tmp/AdGuardHome_darwin_arm64.tar.gz -C /tmp/
sudo cp /tmp/AdGuardHome/AdGuardHome /usr/local/bin/AdGuardHome

sudo /usr/local/bin/AdGuardHome -s start
```

### Update Unbound

```bash
brew upgrade unbound
sudo brew services restart unbound
```

### Backup AdGuard Home Configuration

```bash
sudo cp /opt/AdGuardHome/AdGuardHome.yaml ~/AdGuardHome.yaml.backup
```

---

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for a comprehensive list of common issues.
