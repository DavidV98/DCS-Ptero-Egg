#!/bin/bash
# ============================================================
# DCS World Dedicated Server — Pterodactyl Install Script
#
# NEW ARCHITECTURE (first-boot install):
#   This install phase is intentionally MINIMAL. It no longer downloads
#   or installs DCS. All system dependencies (Wine, Xvfb, xdotool, openbox,
#   noVNC, VC++ runtime) live in the Docker IMAGE, and the heavy DCS install
#   (download + GUI automation + ~GB updater) happens on FIRST SERVER START
#   in entrypoint.sh.
#
#   Why: the Pterodactyl install container cannot publish ports, so the debug
#   VNC was unreachable during install. The runtime container DOES publish the
#   server's port allocations, so moving the install to first boot makes the
#   VNC console reachable through the panel and removes the install-container
#   networking limitation entirely.
#
#   Runs as root in ghcr.io/pelican-eggs/installers:* and writes to /mnt/server.
# ============================================================
set -e

INSTALL_DIR="/mnt/server"
DCS_WRITE_DIR="${DCS_WRITE_DIR:-DCS.server}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " DCS World Dedicated Server — environment setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "   This egg installs DCS on the FIRST server START, not here."
echo "   The install phase only prepares the directory structure."
echo ""

# Pre-create the directory layout DCS and the entrypoint expect, so first
# boot has a clean tree to write into. The Wine prefix and DCS files are
# created at first start by entrypoint.sh.
mkdir -p "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/.wine/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}/Config"
mkdir -p "${INSTALL_DIR}/.wine/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}/Missions"
mkdir -p "${INSTALL_DIR}/.wine/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}/Tracks"
mkdir -p "${INSTALL_DIR}/.wine/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}/Logs"
mkdir -p "${INSTALL_DIR}/.wine/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}/Scripts"

# Everything under /mnt/server must be owned by UID 1000 (the runtime
# 'container' user) so the server can read/write it on start.
chown -R 1000:1000 "${INSTALL_DIR}"

echo "   ✓ Directory structure prepared"
echo "   ✓ Ownership set to UID 1000 (container user)"
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  Environment ready. DCS World will download and install on   ║"
echo "║  the FIRST server start — this takes 30-60+ minutes and the  ║"
echo "║  full progress streams to the server console.                ║"
echo "║                                                               ║"
echo "║  To watch/assist the first-boot installer GUI, set            ║"
echo "║  DCS_DEBUG_VNC=1 and open the VNC console on the allocated    ║"
echo "║  port (default 6080) — reachable because the runtime          ║"
echo "║  container publishes your port allocations.                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
