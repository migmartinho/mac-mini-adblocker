# Architecture

This document describes the detailed data-flow and component layout of the mac-mini-adblocker stack.

---

## Components

### AdGuard Home

AdGuard Home is a network-wide DNS ad-blocking service similar to Pi-Hole. It:

- Intercepts DNS queries from clients.
- Checks each queried domain against one or more blocklists.
- Returns `NXDOMAIN` (or `0.0.0.0`) for blocked domains so that the client never makes an HTTP connection to ad servers.
- Forwards non-blocked queries to the upstream resolver (Unbound).
- Records every query in a queryable log and serves a real-time web dashboard.

Unlike Pi-Hole, AdGuard Home has a single binary with no external database dependency, runs natively on Apple Silicon, and is actively maintained with first-class support for encrypted DNS protocols (DoH, DoT, DoQ).

### Unbound

Unbound is a validating, recursive DNS resolver. It:

- Performs *recursive* DNS resolution: instead of delegating every query to an upstream provider (Google, Cloudflare, etc.) it starts at the root servers and follows the delegation chain itself.
- Validates DNSSEC signatures at every step, protecting against DNS cache-poisoning attacks.
- Caches results locally, reducing latency for repeated queries.
- Never exposes your DNS queries in plain text to a third-party resolver.

### WireGuard

WireGuard is the existing VPN server. Clients connect over UDP 51820, receiving:

- A VPN IP address in the `10.0.0.0/24` range.
- `DNS = 10.0.0.1` pushed in the client config — directing all DNS to AdGuard Home on the Mac Mini.

---

## Data Flow

### DNS Query — Happy Path (Domain Not Blocked)

```
1. VPN client types "github.com" in the browser.
2. OS sends DNS query: UDP → 10.0.0.1:53 (AdGuard Home).
3. AdGuard Home checks blocklists → NOT blocked.
4. AdGuard Home forwards query to upstream: UDP → 127.0.0.1:5335 (Unbound).
5. Unbound checks its cache → MISS.
6. Unbound queries root servers for "." → gets NS for ".com".
7. Unbound queries ".com" NS → gets NS for "github.com".
8. Unbound queries "github.com" NS → gets A records.
9. Unbound validates DNSSEC chain, caches result, returns to AdGuard Home.
10. AdGuard Home logs the query (allowed), returns A record to client.
11. Client connects to github.com IP.
```

### DNS Query — Blocked Domain

```
1. VPN client browser loads a page that requests "googlesyndication.com".
2. OS sends DNS query: UDP → 10.0.0.1:53.
3. AdGuard Home checks blocklists → BLOCKED.
4. AdGuard Home returns 0.0.0.0 (null IP) — no upstream query made.
5. AdGuard Home logs the query as "blocked".
6. Browser receives 0.0.0.0, connection fails immediately, no ad loaded.
```

---

## Network Diagram

```
                   ┌─────────────────────────────────────────────┐
                   │              Mac Mini (macOS Tahoe)          │
                   │                                              │
 VPN Clients ─────►│  wg0 / utun   10.0.0.1/24                   │
 (port 51820)      │       │                                      │
                   │       │ DNS :53                              │
                   │       ▼                                      │
 LAN Clients ─────►│  AdGuard Home                                │
 (via DHCP DNS)    │  bind: 127.0.0.1:53                         │
                   │        10.0.0.1:53                           │
                   │        192.168.1.x:53 (optional, LAN)        │
                   │  dashboard: :3000                            │
                   │       │                                      │
                   │       │ upstream :5335                       │
                   │       ▼                                      │
                   │  Unbound                                     │
                   │  bind: 127.0.0.1:5335                        │
                   │  (not accessible from network)               │
                   │       │                                      │
                   └───────┼──────────────────────────────────────┘
                           │ recursive queries
                           ▼
                   Root DNS Servers (.)
                   a.root-servers.net … m.root-servers.net
```

---

## Port Reference

| Service | Protocol | Address | Port | Purpose |
|---|---|---|---|---|
| WireGuard | UDP | `0.0.0.0` | `51820` | VPN tunnel |
| AdGuard Home DNS | UDP+TCP | `127.0.0.1`, `10.0.0.1` (+ LAN IP optional) | `53` | DNS for clients |
| AdGuard Home Web UI | TCP | `127.0.0.1` (or `0.0.0.0`) | `3000` | Dashboard |
| Unbound | UDP+TCP | `127.0.0.1` | `5335` | Internal upstream resolver |

---

## Blocking Modes

### VPN-Only (Default)

Only devices connected to the WireGuard VPN use the adblocker. No changes are required on the router.

- AdGuard Home listens on `127.0.0.1` and `10.0.0.1`.
- WireGuard client configs contain `DNS = 10.0.0.1`.
- The Mac Mini's LAN traffic uses the router's default DNS (unblocked).

### LAN-Wide (Optional Extension)

All devices on the local network — whether or not they are connected to the VPN — benefit from ad blocking.

- AdGuard Home also listens on the Mac Mini's LAN IP (e.g., `192.168.1.100`).
- The router's DHCP server is configured to advertise `192.168.1.100` as the primary DNS server.
- All devices that renew their DHCP lease will automatically use AdGuard Home.

Both modes can be active simultaneously: VPN clients use `10.0.0.1`, LAN clients use `192.168.1.100` — both resolve through the same AdGuard Home instance and blocklist.

---

## Security Considerations

1. **Unbound is not exposed to the network.** It binds only to `127.0.0.1:5335`. Only AdGuard Home (running on the same host) can reach it.
2. **AdGuard Home binds only to required interfaces.** It does not bind to `0.0.0.0:53` by default in the repository config — reducing the attack surface.
3. **DNSSEC validation** is enforced by Unbound, protecting against DNS spoofing.
4. **No plaintext DNS leaving the machine** — all external resolution is done recursively by Unbound over standard UDP/TCP to root/authoritative servers.
5. The AdGuard Home dashboard should be accessed over the local network or VPN only. Do **not** expose port 3000 to the internet.
