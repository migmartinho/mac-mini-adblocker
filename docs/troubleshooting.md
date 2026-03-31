# Troubleshooting

Common issues and their solutions for the mac-mini-adblocker stack.

---

## AdGuard Home

### "Address already in use" on port 53

**Symptom:** AdGuard Home fails to start with an error like:
```
listen tcp 0.0.0.0:53: bind: address already in use
```

**Cause:** macOS `mDNSResponder` can bind to port 53 on some interfaces, or another DNS service is running.

**Fix:**

1. Check what is using port 53:
   ```bash
   sudo lsof -i UDP:53
   sudo lsof -i TCP:53
   ```

2. If it is `mDNSResponder`, configure AdGuard Home to bind only to specific interfaces instead of `0.0.0.0`:
   ```yaml
   dns:
     bind_hosts:
       - 127.0.0.1
       - 10.0.0.1   # WireGuard VPN interface
     port: 53
   ```
   `mDNSResponder` binds to the LAN interfaces but not to the WireGuard `utun` IP, so this avoids the conflict.

3. Restart AdGuard Home:
   ```bash
   sudo /usr/local/bin/AdGuardHome -s restart
   ```

---

### Dashboard not accessible after reboot

**Symptom:** Can reach the dashboard right after install, but not after reboot.

**Cause:** AdGuard Home was not installed as a LaunchDaemon.

**Fix:**
```bash
sudo /usr/local/bin/AdGuardHome -s install
sudo /usr/local/bin/AdGuardHome -s start
```

---

### VPN clients can resolve but blocking is not working

**Symptom:** DNS works through the VPN, but ads still appear and the Query Log shows no blocked queries.

**Cause:** The blocklists may not have been downloaded yet, or the client is using a different DNS server.

**Fix:**
1. In the dashboard, go to **Filters → DNS blocklists** and click **Update Now**.
2. On the client device, verify the DNS server is `10.0.0.1`:
   ```bash
   # macOS / Linux
   scutil --dns | grep nameserver
   # or
   cat /etc/resolv.conf
   ```
3. If using a split-tunnel WireGuard config (`AllowedIPs` does not include `0.0.0.0/0`), DNS queries for non-VPN destinations may bypass the tunnel. Add `DNS = 10.0.0.1` to the client `[Interface]` section.

---

### Query Log shows queries but "Blocked" count stays 0

**Symptom:** DNS queries appear in the log but nothing is blocked.

**Cause:** Blocklists are empty or disabled.

**Fix:**
1. Go to **Filters → DNS blocklists** and verify lists have a non-zero "Rules" count.
2. If lists show 0 rules, click **Update Now**.
3. Check that filtering is enabled: **Settings → General Settings → Use AdGuard browsing security web service** (this is a different feature — make sure **DNS blocklists** are enabled on the Filters page).

---

## Unbound

### Unbound fails to start — "cannot open root hints file"

**Cause:** The root hints file was not downloaded.

**Fix:**
```bash
curl -sS -o /opt/homebrew/etc/unbound/root.hints \
     https://www.internic.net/domain/named.cache
sudo brew services restart unbound
```

---

### Unbound fails configuration check

**Symptom:** `unbound-checkconf` reports an error.

**Cause:** The config file has a syntax error or references a path that does not exist.

**Fix:**
```bash
/opt/homebrew/sbin/unbound-checkconf /opt/homebrew/etc/unbound/unbound.conf
```
Read the error message carefully. Common issues:
- The `root-hints:` path does not match where you saved the file.
- A tab character was used instead of spaces in the config.
- The `chroot` directive is set to a non-existent directory.

---

### Slow DNS resolution

**Symptom:** First queries take 2–5 seconds, subsequent queries are fast.

**Cause:** Unbound is doing full recursive resolution starting from root servers. The first query for a domain is always slower because it walks the full delegation chain. Subsequent queries are served from cache.

**This is normal.** AdGuard Home has its own cache as well; once a domain is cached, resolution is under 1 ms.

If you find cold-start latency unacceptable, consider adding a fast DoT upstream as a fallback:
```yaml
# In AdGuardHome.yaml
dns:
  upstream_dns:
    - 127.0.0.1:5335   # Unbound (primary)
    - tls://1.1.1.1    # Cloudflare DoT (fallback)
```

---

### DNSSEC validation fails for a legitimate domain

**Symptom:** A domain that should resolve normally returns `SERVFAIL`.

**Cause:** The domain has a broken DNSSEC configuration (misconfigured DS record or expired RRSIG). This is a problem with the domain, not with your setup — Unbound is correctly rejecting an invalid signature.

**Workaround:** If you need to access the domain and cannot wait for the domain owner to fix their DNSSEC:
```bash
# In unbound.conf, add a domain override to skip DNSSEC for that domain:
domain-insecure: "example-broken-dnssec.com"
```
This should be used sparingly.

---

## WireGuard

### VPN clients cannot reach 10.0.0.1:53

**Symptom:** WireGuard tunnel is up, but `dig @10.0.0.1 example.com` times out from a VPN client.

**Cause 1:** IP forwarding is disabled on the Mac Mini.
```bash
sysctl net.inet.ip.forwarding  # should be 1
sudo sysctl -w net.inet.ip.forwarding=1
```

**Cause 2:** macOS firewall is blocking the connection.
Check System Settings → Network → Firewall → Options → ensure **AdGuardHome** is allowed to accept incoming connections.

**Cause 3:** AdGuard Home is not listening on `10.0.0.1`.
```bash
sudo lsof -i :53 | grep AdGuard
```
If `10.0.0.1` does not appear, check `bind_hosts` in `/opt/AdGuardHome/AdGuardHome.yaml`.

---

### WireGuard interface IP is not 10.0.0.1

If your WireGuard server uses a different subnet (e.g., `10.8.0.1`), update the `bind_hosts` in `AdGuardHome.yaml` and the `DNS =` line in all client configs accordingly.

---

## General

### How to restart all services at once

```bash
sudo /usr/local/bin/AdGuardHome -s stop
sudo brew services restart unbound
sudo /usr/local/bin/AdGuardHome -s start
```

### How to check service logs

```bash
# AdGuard Home logs
sudo tail -f /opt/AdGuardHome/AdGuardHome.log

# Unbound logs (via Homebrew services)
sudo brew services log unbound

# WireGuard logs
sudo wg show
log stream --predicate 'subsystem == "com.wireguard"' --level debug
```

### How to completely reset AdGuard Home

```bash
sudo /usr/local/bin/AdGuardHome -s stop
sudo /usr/local/bin/AdGuardHome -s uninstall
sudo rm -rf /opt/AdGuardHome
# Reinstall from scratch following the tutorial
```
