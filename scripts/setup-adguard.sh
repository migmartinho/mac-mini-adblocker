#!/usr/bin/env bash
# =============================================================================
# setup-adguard.sh — Install and configure AdGuard Home on macOS (Apple Silicon)
#
# Usage:
#   sudo bash scripts/setup-adguard.sh [--vpn-ip <IP>] [--lan-ip <IP>]
#
# Options:
#   --vpn-ip <IP>   WireGuard VPN server IP (default: 10.0.0.1)
#   --lan-ip <IP>   LAN IP to also listen on for LAN-wide blocking (optional)
#
# What this script does:
#   1. Downloads the latest AdGuard Home ARM64 binary from GitHub
#   2. Creates the working directory /opt/AdGuardHome
#   3. Deploys AdGuardHome.yaml from this repository
#   4. Patches bind_hosts in the config to include the VPN (and LAN) IP
#   5. Installs AdGuard Home as a LaunchDaemon (starts at boot)
#   6. Starts AdGuard Home
#   7. Verifies DNS resolution through AdGuard Home
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
VPN_IP="10.0.0.1"
LAN_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vpn-ip) VPN_IP="$2"; shift 2 ;;
    --lan-ip) LAN_IP="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Run as root (sudo bash scripts/setup-adguard.sh)" >&2
  exit 1
fi

AGH_BIN="/usr/local/bin/AdGuardHome"
AGH_WORK="/opt/AdGuardHome"
AGH_CFG="${AGH_WORK}/AdGuardHome.yaml"
RELEASE_URL="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_darwin_arm64.tar.gz"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "--- AdGuard Home: downloading latest ARM64 release ---"
if ! curl -fsSL -o "${TMP_DIR}/AdGuardHome.tar.gz" "${RELEASE_URL}"; then
  echo "WARNING: Could not download AdGuard Home (no internet access?)." >&2
  echo "  Download manually from: ${RELEASE_URL}" >&2
  echo "  Then run: sudo cp AdGuardHome/AdGuardHome ${AGH_BIN} && sudo chmod +x ${AGH_BIN}" >&2
  echo "  And re-run this script." >&2
  exit 1
fi

echo "--- AdGuard Home: extracting ---"
tar -xzf "${TMP_DIR}/AdGuardHome.tar.gz" -C "${TMP_DIR}"

# Stop any running instance before replacing the binary
if [[ -x "${AGH_BIN}" ]]; then
  "${AGH_BIN}" -s stop 2>/dev/null || true
fi

cp "${TMP_DIR}/AdGuardHome/AdGuardHome" "${AGH_BIN}"
chmod +x "${AGH_BIN}"
echo "  Installed: ${AGH_BIN}"

echo "--- AdGuard Home: creating working directory ---"
mkdir -p "${AGH_WORK}"

echo "--- AdGuard Home: deploying configuration ---"
cp "${REPO_ROOT}/configs/adguard-home/AdGuardHome.yaml" "${AGH_CFG}"

# ── Patch bind_hosts to include the actual VPN IP ──────────────────────────
# The repo config uses 10.0.0.1 as a placeholder; replace it if different.
if [[ "${VPN_IP}" != "10.0.0.1" ]]; then
  sed -i '' "s/10\.0\.0\.1/${VPN_IP}/g" "${AGH_CFG}"
  echo "  Patched VPN IP to ${VPN_IP}"
fi

# ── Optionally add LAN IP ──────────────────────────────────────────────────
if [[ -n "${LAN_IP}" ]]; then
  # Insert LAN IP into bind_hosts list (after the VPN IP line)
  sed -i '' "/- ${VPN_IP}/a\\
    - ${LAN_IP}" "${AGH_CFG}"
  echo "  Added LAN IP ${LAN_IP} to bind_hosts"

  # Also add LAN subnet to allowed_clients
  LAN_SUBNET="${LAN_IP%.*}.0/24"
  sed -i '' "/- 10\.0\.0\.0\/24/a\\
    - ${LAN_SUBNET}" "${AGH_CFG}"
  echo "  Added LAN subnet ${LAN_SUBNET} to allowed_clients"
fi

echo "--- AdGuard Home: installing LaunchDaemon ---"
if [[ -x "${AGH_BIN}" ]]; then
  "${AGH_BIN}" -s install 2>/dev/null || true
fi

echo "--- AdGuard Home: starting service ---"
"${AGH_BIN}" -s start

echo "--- AdGuard Home: verifying DNS resolution ---"
sleep 3
if dig @"${VPN_IP}" -p 53 example.com +short +time=5 +tries=1 &>/dev/null; then
  echo "  ✓ AdGuard Home is resolving DNS on ${VPN_IP}:53"
else
  echo "  ⚠ Could not verify AdGuard Home on ${VPN_IP}:53" >&2
  echo "    Check: ${AGH_WORK}/AdGuardHome.log" >&2
  echo "    It is possible the VPN interface is not yet up." >&2
fi

if dig @127.0.0.1 -p 53 example.com +short +time=5 +tries=1 &>/dev/null; then
  echo "  ✓ AdGuard Home is resolving DNS on 127.0.0.1:53"
else
  echo "  ⚠ Could not verify AdGuard Home on 127.0.0.1:53" >&2
fi

echo ""
echo "--- AdGuard Home setup complete ---"
echo "  Dashboard: http://localhost:3000"
echo "  Default credentials: admin / changeme"
echo "  IMPORTANT: Change the admin password immediately!"
