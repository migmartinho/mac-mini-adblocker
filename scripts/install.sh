#!/usr/bin/env bash
# =============================================================================
# install.sh — One-shot installer for mac-mini-adblocker
#
# Usage:
#   sudo bash scripts/install.sh [--lan-ip <LAN_IP>] [--vpn-ip <VPN_SERVER_IP>]
#
# Options:
#   --lan-ip   <IP>   Mac Mini LAN IP for LAN-wide blocking (optional).
#                     If omitted, only VPN-only mode is configured.
#   --vpn-ip   <IP>   WireGuard server IP (default: 10.0.0.1)
#   --wg-if    <IF>   WireGuard interface name (default: utun for Apple VPN,
#                     or wg0 if using wireguard-go)
#   --help            Show this help message
#
# Requirements:
#   - macOS Tahoe 26.x on Apple Silicon
#   - Homebrew installed (https://brew.sh)
#   - WireGuard already set up
#   - Run as root (sudo)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
VPN_IP="10.0.0.1"
LAN_IP=""
WG_IF=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan-ip)  LAN_IP="$2";  shift 2 ;;
    --vpn-ip)  VPN_IP="$2";  shift 2 ;;
    --wg-if)   WG_IF="$2";   shift 2 ;;
    --help)
      sed -n '/^# Usage:/,/^# ==/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# ── Root check ────────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo bash scripts/install.sh)" >&2
  exit 1
fi

# ── macOS check ───────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  echo "ERROR: This script is for macOS only." >&2
  exit 1
fi

# ── Homebrew check ────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  echo "ERROR: Homebrew is not installed or not in PATH." >&2
  echo "Install it from https://brew.sh, then re-run this script." >&2
  exit 1
fi

HOMEBREW_PREFIX="$(brew --prefix)"

echo "======================================================================"
echo "  mac-mini-adblocker — installation starting"
echo "======================================================================"
echo "  Repository:     ${REPO_ROOT}"
echo "  VPN server IP:  ${VPN_IP}"
echo "  LAN IP:         ${LAN_IP:-'(not set — VPN-only mode)'}"
echo "  Homebrew:       ${HOMEBREW_PREFIX}"
echo "======================================================================"
echo ""

# ── Step 1: Unbound ───────────────────────────────────────────────────────────
echo "[1/3] Installing and configuring Unbound..."
bash "${SCRIPT_DIR}/setup-unbound.sh"
echo ""

# ── Step 2: AdGuard Home ──────────────────────────────────────────────────────
echo "[2/3] Installing and configuring AdGuard Home..."
bash "${SCRIPT_DIR}/setup-adguard.sh" \
  --vpn-ip "${VPN_IP}" \
  ${LAN_IP:+--lan-ip "${LAN_IP}"}
echo ""

# ── Step 3: WireGuard DNS patch ───────────────────────────────────────────────
echo "[3/3] Configuring WireGuard to use AdGuard Home DNS..."
bash "${SCRIPT_DIR}/setup-wireguard-dns.sh" \
  --vpn-ip "${VPN_IP}" \
  ${WG_IF:+--wg-if "${WG_IF}"}
echo ""

# ── IP Forwarding ─────────────────────────────────────────────────────────────
echo "Enabling IP forwarding..."
sysctl -w net.inet.ip.forwarding=1

if ! grep -q "net.inet.ip.forwarding=1" /etc/sysctl.conf 2>/dev/null; then
  echo "net.inet.ip.forwarding=1" >> /etc/sysctl.conf
  echo "  Persisted to /etc/sysctl.conf"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "  Installation complete!"
echo ""
echo "  AdGuard Home dashboard: http://localhost:3000"
echo "  Default credentials:    admin / changeme"
echo ""
echo "  IMPORTANT: Change the admin password immediately!"
echo "  → Log in at http://localhost:3000 → Settings → Admin username"
echo ""
if [[ -n "${LAN_IP}" ]]; then
  echo "  LAN-wide mode enabled."
  echo "  → Set your router's DHCP DNS to: ${LAN_IP}"
fi
echo ""
echo "  WireGuard client configs should include:"
echo "  DNS = ${VPN_IP}"
echo "======================================================================"
