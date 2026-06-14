#!/bin/bash
# ============================================================
# DCS World Dedicated Server — Pterodactyl Install Script
#
# MINIMAL first-boot architecture: this phase does NOT install DCS and does
# NOT touch the Wine prefix. It only ensures /mnt/server exists with correct
# ownership. The Wine prefix and all DCS files are created on first server
# start by entrypoint.sh.
#
# IMPORTANT: we deliberately do NOT pre-create anything under .wine here.
# Pre-creating .wine/drive_c/... before `wineboot --init` runs leaves a
# half-built prefix missing the registry keys that define the 64-bit Program
# Files path, which makes the DCS installer fail with:
#   "Internal error: Failed to get path of 64-bit Program Files directory."
# Letting wineboot build the prefix from scratch on first boot avoids this.
#
# Runs as root in ghcr.io/pelican-eggs/installers:* and writes to /mnt/server.
# ============================================================
set -e

INSTALL_DIR="/mnt/server"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " DCS World Dedicated Server — environment setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "   This egg installs DCS on the FIRST server START, not here."
echo "   The install phase only ensures the data directory exists."
echo ""

# Ensure the server data directory exists and is owned by the runtime user.
# Do NOT create any .wine/* subdirectories — the Wine prefix must be built
# cleanly by wineboot on first start (see header note).
mkdir -p "${INSTALL_DIR}"
chown -R 1000:1000 "${INSTALL_DIR}"

echo "   ✓ Data directory ready"
echo "   ✓ Ownership set to UID 1000 (container user)"
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  Environment ready. DCS World will download and install on   ║"
echo "║  the FIRST server start — this takes 30-60+ minutes and the  ║"
echo "║  full progress streams to the server console.                ║"
echo "║                                                               ║"
echo "║  To watch/assist the first-boot installer GUI, set            ║"
echo "║  DCS_DEBUG_VNC=1 and allocate the VNC port (default 6080)     ║"
echo "║  on the server — reachable because the runtime container      ║"
echo "║  publishes your port allocations.                             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
