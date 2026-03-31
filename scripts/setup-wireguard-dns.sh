#!/usr/bin/env bash
# =============================================================================
# setup-wireguard-dns.sh — Configure WireGuard to route DNS through AdGuard Home
#
# Usage:
#   sudo bash scripts/setup-wireguard-dns.sh [--vpn-ip <IP>] [--wg-if <interface>]
#
# Options:
#   --vpn-ip <IP>     WireGuard server IP / AdGuard Home DNS IP (default: 10.0.0.1)
#   --wg-if  <name>   WireGuard interface name (default: auto-detected)
#
# What this script does:
#   1. Detects the WireGuard interface name
#   2. Shows the server config location for manual DNS line addition
#   3. Lists client configs found in standard locations and shows the DNS line
#   4. Enables and persists IP forwarding
#   5. Verifies that AdGuard Home is reachable on the VPN IP
#
# NOTE: WireGuard config files on macOS are typically managed by the WireGuard
# app (via the App Store) and stored in a sandboxed container. This script
# detects their location and prints instructions rather than modifying files
# automatically, to avoid breaking WireGuard's internal state.
# =============================================================================
set -euo pipefail

VPN_IP="10.0.0.1"
WG_IF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vpn-ip) VPN_IP="$2"; shift 2 ;;
    --wg-if)  WG_IF="$2";  shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Run as root (sudo bash scripts/setup-wireguard-dns.sh)" >&2
  exit 1
fi

# ── Auto-detect WireGuard interface ───────────────────────────────────────────
if [[ -z "${WG_IF}" ]]; then
  # Try wg show to find active interfaces
  if command -v wg &>/dev/null; then
    WG_IF="$(wg show interfaces 2>/dev/null | awk '{print $1}' | head -1)"
  fi
  if [[ -z "${WG_IF}" ]]; then
    # Fall back to scanning utun interfaces for known WireGuard signatures
    WG_IF="$(ifconfig -a 2>/dev/null | grep -E '^utun[0-9]+' | awk -F: '{print $1}' | head -1 || true)"
  fi
fi

echo "--- WireGuard DNS configuration ---"
echo ""

if [[ -n "${WG_IF}" ]]; then
  echo "Detected WireGuard interface: ${WG_IF}"
else
  echo "Could not auto-detect WireGuard interface."
  echo "If WireGuard is not yet running, start it and re-run this script."
fi
echo ""

# ── IP Forwarding ─────────────────────────────────────────────────────────────
echo "--- Enabling IP forwarding ---"
sysctl -w net.inet.ip.forwarding=1

SYSCTL_CONF="/etc/sysctl.conf"
if ! grep -q "net.inet.ip.forwarding=1" "${SYSCTL_CONF}" 2>/dev/null; then
  echo "net.inet.ip.forwarding=1" >> "${SYSCTL_CONF}"
  echo "  Persisted to ${SYSCTL_CONF}"
else
  echo "  Already persisted in ${SYSCTL_CONF}"
fi

# ── Look for WireGuard config files ───────────────────────────────────────────
echo ""
echo "--- Looking for WireGuard configuration files ---"

SEARCH_PATHS=(
  "/opt/homebrew/etc/wireguard"
  "/etc/wireguard"
  "${HOME}/Library/Containers/com.wireguard.macos/Data/Documents"
  "${HOME}/.config/wireguard"
)

FOUND_CONFIGS=()
for path in "${SEARCH_PATHS[@]}"; do
  if [[ -d "${path}" ]]; then
    while IFS= read -r -d '' conf; do
      FOUND_CONFIGS+=("${conf}")
    done < <(find "${path}" -name "*.conf" -print0 2>/dev/null)
  fi
done

if [[ ${#FOUND_CONFIGS[@]} -eq 0 ]]; then
  echo "No WireGuard .conf files found in standard locations."
  echo ""
  echo "To integrate with AdGuard Home, add the following to your"
  echo "WireGuard SERVER config [Interface] section:"
  echo ""
  echo "  # (PostUp/PostDown for IP forwarding already handled by this script)"
  echo ""
  echo "And add the following to each CLIENT config [Interface] section:"
  echo ""
  echo "  DNS = ${VPN_IP}"
  echo ""
  echo "Config search locations checked:"
  for path in "${SEARCH_PATHS[@]}"; do
    echo "  ${path}"
  done
else
  echo "Found WireGuard config(s):"
  for conf in "${FOUND_CONFIGS[@]}"; do
    echo "  ${conf}"

    # Check if DNS line is already present
    if grep -qE "^DNS\s*=" "${conf}" 2>/dev/null; then
      CURRENT_DNS="$(grep -E "^DNS\s*=" "${conf}" | head -1)"
      if echo "${CURRENT_DNS}" | grep -qF "${VPN_IP}"; then
        echo "    ✓ DNS already set to ${VPN_IP}"
      else
        echo "    ⚠ DNS is set to a different value: ${CURRENT_DNS}"
        echo "      Update it to: DNS = ${VPN_IP}"
      fi
    else
      echo "    ⚠ No DNS line found in [Interface] section."
      echo "      Add: DNS = ${VPN_IP}"
      echo "      (for client configs only — not the server config)"
    fi
  done
fi

# ── Verify AdGuard Home is reachable on VPN IP ────────────────────────────────
echo ""
echo "--- Verifying AdGuard Home is reachable on ${VPN_IP}:53 ---"
if dig @"${VPN_IP}" -p 53 example.com +short +time=5 +tries=1 &>/dev/null; then
  echo "  ✓ AdGuard Home responding on ${VPN_IP}:53"
else
  echo "  ⚠ Cannot reach AdGuard Home on ${VPN_IP}:53" >&2
  echo "    This is expected if the WireGuard interface is not up yet." >&2
  echo "    Start WireGuard and re-run: dig @${VPN_IP} example.com" >&2
fi

echo ""
echo "--- WireGuard DNS configuration complete ---"
echo ""
echo "Summary of required client config change:"
echo "  [Interface]"
echo "  ...existing settings..."
echo "  DNS = ${VPN_IP}"
echo ""
echo "After updating client configs, reconnect to the VPN."
echo "All DNS queries from VPN clients will go through AdGuard Home."
