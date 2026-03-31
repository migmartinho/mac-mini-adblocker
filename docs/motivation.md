# Motivation and Design Decisions

This document explains *why* each component was chosen, why Pi-Hole was not used, and why the specific architecture was designed the way it was.

---

## Why Not Pi-Hole?

Pi-Hole is the most popular DNS-based ad blocker, but it **does not support macOS**. Pi-Hole requires a Linux kernel and its installation scripts explicitly check for Debian/Fedora/Arch-based systems. Running Pi-Hole on a Mac Mini would require a full Linux virtual machine, which adds complexity, resource overhead, and a separate update cycle.

## Why AdGuard Home?

AdGuard Home was chosen as the Pi-Hole equivalent for macOS because:

| Criterion | AdGuard Home | Pi-Hole |
|---|---|---|
| macOS / Apple Silicon support | ✅ Native ARM64 binary | ❌ Linux only |
| Single binary (no external DB) | ✅ Yes | ❌ Requires FTL + dnsmasq |
| Web dashboard | ✅ Built-in | ✅ Built-in |
| Encrypted DNS (DoH, DoT, DoQ) | ✅ Yes | ⚠️ Requires extra setup |
| Per-client blocking rules | ✅ Yes | ✅ Yes |
| Active maintenance | ✅ Yes | ✅ Yes |
| Blocklist compatibility | ✅ All major formats | ✅ All major formats |

AdGuard Home provides everything Pi-Hole does, runs natively on the M1 Mac Mini without virtualization, and has a cleaner architecture (one process, one config file).

---

## Why Unbound?

A common simpler approach is to point AdGuard Home's upstream directly at a public resolver like `8.8.8.8` (Google) or `1.1.1.1` (Cloudflare). This works, but it means:

1. **All DNS queries are forwarded in plaintext to a third party.** Even with DoH/DoT, Google and Cloudflare still see every domain you query.
2. **You trust a third party's resolver.** If that resolver is compromised, manipulated, or censored, your resolution is too.

Unbound eliminates this by performing *recursive* resolution: it queries the root name servers directly and follows the delegation chain to the authoritative server. No third party sees the full picture of your browsing.

Additional benefits:
- **DNSSEC validation** — Unbound validates the cryptographic signatures at every step of the chain, protecting against DNS cache poisoning.
- **Local caching** — frequently queried domains are served from the local cache with sub-millisecond latency.
- **Privacy** — individual authoritative servers only see the single domain they are authoritative for, not your complete query history.

Unbound listens exclusively on `127.0.0.1:5335`, making it invisible to the network.

---

## Why WireGuard?

The problem statement specifies an existing WireGuard VPN server. WireGuard was an excellent choice for this use case because:

- It is built into the Linux and macOS kernels (available as `wireguard-go` on macOS).
- It is significantly faster and more battery-efficient than OpenVPN or IPsec.
- Its client configs support a `DNS =` directive, which makes it trivially easy to route all client DNS through AdGuard Home without any client-side configuration beyond the standard WireGuard profile.

---

## Why DNS-Based Blocking (Not Proxy/HTTP)?

DNS-based ad blocking is:

1. **Protocol-agnostic** — it works for HTTP, HTTPS, apps, smart TVs, IoT devices — anything that uses DNS.
2. **Low overhead** — one DNS query check per new domain (not per HTTP request).
3. **Network-wide** — a single DNS resolver can protect every device on the network.
4. **No TLS interception required** — unlike HTTPS inspection proxies, DNS blocking does not require installing a root certificate on every device.

The trade-off is that it cannot block ads served from the same domain as the main content (e.g., first-party ads on some platforms), but this covers the vast majority of tracking and advertising infrastructure.

---

## Why VPN-First, LAN-Wide Optional?

Requiring only VPN changes:

1. **No router modifications needed** — suitable for users who do not have admin access to their router, or who use an ISP-provided locked-down router.
2. **No risk of breaking LAN DNS for other devices** — a mistake in the setup cannot take down the entire household's internet.
3. **Easier rollback** — remove the `DNS = 10.0.0.1` line from client configs and everything reverts instantly.

LAN-wide blocking is offered as an optional step because it provides broader coverage but requires a one-time router configuration change.

---

## Why macOS LaunchDaemons (Not launchctl manually)?

macOS uses `launchd` as its init system. LaunchDaemons in `/Library/LaunchDaemons/` run as root at boot and are the correct mechanism for system-level services on macOS. Using `brew services` for Unbound and AdGuard Home's built-in `-s install` flag for itself both ultimately register LaunchDaemon plists, ensuring:

- Services start before any user logs in.
- Services restart automatically on failure (via `KeepAlive`).
- Logs are written to standard macOS locations.

This is the idiomatic macOS approach — no `cron @reboot`, no login items, no shell scripts in `~/.zprofile`.
