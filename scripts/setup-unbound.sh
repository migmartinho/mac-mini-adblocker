#!/usr/bin/env bash
# =============================================================================
# setup-unbound.sh — Install and configure Unbound on macOS (Apple Silicon)
#
# Usage:
#   sudo bash scripts/setup-unbound.sh
#
# What this script does:
#   1. Installs Unbound via Homebrew (if not already installed)
#   2. Creates required directories
#   3. Deploys unbound.conf from this repository
#   4. Downloads root hints from IANA
#   5. Initialises the DNSSEC trust anchor
#   6. Validates the configuration
#   7. Starts Unbound and enables it at boot
#   8. Registers a monthly cron job to keep root hints fresh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Run as root (sudo bash scripts/setup-unbound.sh)" >&2
  exit 1
fi

if ! command -v brew &>/dev/null; then
  echo "ERROR: Homebrew not found. Install from https://brew.sh" >&2
  exit 1
fi

HOMEBREW_PREFIX="$(brew --prefix)"
UNBOUND_ETC="${HOMEBREW_PREFIX}/etc/unbound"
UNBOUND_BIN="${HOMEBREW_PREFIX}/sbin/unbound"
UNBOUND_CHECKCONF="${HOMEBREW_PREFIX}/sbin/unbound-checkconf"
UNBOUND_ANCHOR="${HOMEBREW_PREFIX}/sbin/unbound-anchor"
LOG_DIR="${HOMEBREW_PREFIX}/var/log/unbound"

echo "--- Unbound: installing via Homebrew ---"
if "${HOMEBREW_PREFIX}/bin/brew" list unbound &>/dev/null; then
  echo "Unbound already installed — upgrading if needed..."
  # Run as the brew owner (not root) to avoid Homebrew ownership warnings
  BREW_OWNER="$(stat -f '%Su' "${HOMEBREW_PREFIX}/bin/brew")"
  su - "${BREW_OWNER}" -c "${HOMEBREW_PREFIX}/bin/brew upgrade unbound || true"
else
  BREW_OWNER="$(stat -f '%Su' "${HOMEBREW_PREFIX}/bin/brew")"
  su - "${BREW_OWNER}" -c "${HOMEBREW_PREFIX}/bin/brew install unbound"
fi

echo "--- Unbound: creating directories ---"
mkdir -p "${UNBOUND_ETC}"
mkdir -p "${LOG_DIR}"

echo "--- Unbound: deploying configuration ---"
cp "${REPO_ROOT}/configs/unbound/unbound.conf" "${UNBOUND_ETC}/unbound.conf"
echo "  Deployed: ${UNBOUND_ETC}/unbound.conf"

echo "--- Unbound: downloading root hints ---"
if ! curl -fsSL -o "${UNBOUND_ETC}/root.hints" \
     "https://www.internic.net/domain/named.cache"; then
  echo "WARNING: Could not download root hints (no internet access?)." >&2
  echo "  Download manually: curl -o ${UNBOUND_ETC}/root.hints https://www.internic.net/domain/named.cache" >&2
fi

echo "--- Unbound: initialising DNSSEC trust anchor ---"
if [[ -x "${UNBOUND_ANCHOR}" ]]; then
  "${UNBOUND_ANCHOR}" -a "${UNBOUND_ETC}/root.key" || true
else
  echo "WARNING: unbound-anchor not found at ${UNBOUND_ANCHOR}" >&2
fi

echo "--- Unbound: validating configuration ---"
if "${UNBOUND_CHECKCONF}" "${UNBOUND_ETC}/unbound.conf"; then
  echo "  Configuration OK"
else
  echo "ERROR: unbound configuration has errors. Check ${UNBOUND_ETC}/unbound.conf" >&2
  exit 1
fi

echo "--- Unbound: enabling and starting service ---"
"${HOMEBREW_PREFIX}/bin/brew" services stop unbound 2>/dev/null || true
"${HOMEBREW_PREFIX}/bin/brew" services start unbound

echo "--- Unbound: adding monthly root hints cron job ---"
CRON_CMD="0 3 1 * * curl -fsSL -o ${UNBOUND_ETC}/root.hints https://www.internic.net/domain/named.cache && ${HOMEBREW_PREFIX}/bin/brew services restart unbound"
# Add to root's crontab if not already present
if ! crontab -l 2>/dev/null | grep -qF "root.hints"; then
  ( crontab -l 2>/dev/null || true; echo "${CRON_CMD}" ) | crontab -
  echo "  Monthly root hints refresh cron job registered."
fi

echo ""
echo "--- Unbound: verifying DNS resolution ---"
sleep 2
if dig @127.0.0.1 -p 5335 example.com +short +time=5 +tries=1 &>/dev/null; then
  echo "  ✓ Unbound is resolving DNS successfully."
else
  echo "  ⚠ Could not verify Unbound resolution. Check logs:" >&2
  echo "    ${LOG_DIR}/unbound.log" >&2
fi

echo "--- Unbound setup complete ---"
