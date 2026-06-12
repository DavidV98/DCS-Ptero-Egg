#!/bin/bash
# ============================================================
# DCS World Dedicated Server — Pterodactyl Install Script
#
# Runs as root inside ghcr.io/pterodactyl/installers:ubuntu
# Everything written to /mnt/server becomes /home/container
# at runtime when Wings mounts the server data volume.
# ============================================================
set -e
export DEBIAN_FRONTEND=noninteractive

# ── Paths ─────────────────────────────────────────────────────
INSTALL_DIR="/mnt/server"
WINEPREFIX="${INSTALL_DIR}/.wine"
DCS_PROGRAM_DIR="${WINEPREFIX}/drive_c/Program Files/Eagle Dynamics/DCS World Server"
DCS_UPDATER="${DCS_PROGRAM_DIR}/bin/DCS_updater.exe"
DCS_INSTALLER_TMP="/tmp/dcs_installer.exe"
SENTINEL="${INSTALL_DIR}/.dcs_installed"

# ── Egg variables (Pterodactyl injects these as env vars) ─────
: "${DCS_INSTALLER_URL:=https://www.digitalcombatsimulator.com/gameloader/dcs_server_installer_latest/DCS_server_installer_latest.exe}"
: "${DCS_WRITE_DIR:=DCS.server}"
: "${DCS_SERVER_NAME:=DCS Pterodactyl Server}"
: "${DCS_SERVER_PORT:=10308}"
: "${DCS_SERVER_PASSWORD:=}"
: "${DCS_MAX_PLAYERS:=16}"
: "${DCS_MODULES:=}"

# ── Wine environment ──────────────────────────────────────────
# HOME must point to INSTALL_DIR so Wine doesn't try to write
# to /root (which may not be writable or persistent).
export HOME="${INSTALL_DIR}"
export WINEPREFIX="${WINEPREFIX}"
export WINEARCH="win64"
export DISPLAY=":0"
export WINEDEBUG="-all"
# Suppress Mono/Gecko popups and menu builder — not needed for DCS.
export WINEDLLOVERRIDES="mscoree,mshtml=,winemenubuilder.exe=d"

# ════════════════════════════════════════════════════════════
# STEP 1 — Wine HQ Staging + system packages
# ════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [1/6] Installing Wine HQ Staging and dependencies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

dpkg --add-architecture i386
apt-get update -y -q
apt-get install -y -q --no-install-recommends \
    ca-certificates wget curl gnupg2 \
    software-properties-common \
    xvfb winbind cabextract procps unzip

# Auto-detect Ubuntu codename so this works on both Focal (20.04)
# and Jammy (22.04) installer images without changes.
CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}")
echo "   Ubuntu codename: ${CODENAME}"

mkdir -pm755 /etc/apt/keyrings
wget -qO /etc/apt/keyrings/winehq-archive.key \
    https://dl.winehq.org/wine-builds/winehq.key
wget -qNP /etc/apt/sources.list.d/ \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/${CODENAME}/winehq-${CODENAME}.sources"
apt-get update -y -q
apt-get install -y -q --install-recommends winehq-staging winetricks
echo "   ✓ Wine HQ Staging installed"

# ════════════════════════════════════════════════════════════
# STEP 2 — Virtual display
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [2/6] Starting virtual display (required by Wine)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Xvfb :0 -screen 0 1024x768x16 -ac &
XVFB_PID=$!
sleep 2
echo "   ✓ Xvfb started (PID: ${XVFB_PID})"

# ════════════════════════════════════════════════════════════
# STEP 3 — Wine prefix initialisation
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [3/6] Initialising Wine prefix (win64)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
mkdir -p "${INSTALL_DIR}"

# Wine 7+ prints a "don't run as root" warning here.
# This is expected and harmless for an install script.
wineboot --init
sleep 5

echo "   Installing vcrun2019 (Visual C++ runtime required by DCS)..."
winetricks -q vcrun2019
echo "   ✓ Wine prefix ready at ${WINEPREFIX}"

# Pre-create the Saved Games directory for the runtime 'container' user.
# At runtime, Wine runs as the Linux user 'container' (UID 1000), so DCS
# will look for its config at C:\users\container\Saved Games\DCS.server\.
# Pre-creating it here ensures serverSettings.lua is found on first start.
DCS_SAVE="${WINEPREFIX}/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}"
mkdir -p "${DCS_SAVE}/Config" \
          "${DCS_SAVE}/Missions" \
          "${DCS_SAVE}/Logs" \
          "${DCS_SAVE}/Scripts"

# ════════════════════════════════════════════════════════════
# STEP 4 — DCS World Server installation or update
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "${SENTINEL}" ] && [ -f "${DCS_UPDATER}" ]; then
    # ── Reinstall triggered — update existing DCS ─────────
    echo " [4/6] Existing install detected — running updater"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Originally installed: $(cat "${SENTINEL}")"
    wine "${DCS_UPDATER}" --quiet update \
        && echo "   ✓ DCS updated to latest" \
        || echo "   ⚠ Updater returned non-zero (continuing with existing install)"
else
    # ── Fresh install ─────────────────────────────────────
    echo " [4/6] Fresh install — downloading DCS World Server"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Source: ${DCS_INSTALLER_URL}"
    echo "   This will take several minutes..."
    echo ""

    wget --progress=bar:force --show-progress \
         -O "${DCS_INSTALLER_TMP}" \
         "${DCS_INSTALLER_URL}" \
        || {
            echo ""
            echo "   ERROR: Download failed."
            echo "   Check that DCS_INSTALLER_URL is a direct link to the .exe,"
            echo "   not a webpage. Eagle Dynamics occasionally changes this URL."
            kill "${XVFB_PID}" 2>/dev/null
            exit 1
        }

    echo ""
    echo "   Running silent installer (/S)..."
    # /S = silent NSIS install. DCS installs to the default Windows path:
    # C:\Program Files\Eagle Dynamics\DCS World Server\
    wine "${DCS_INSTALLER_TMP}" /S

    echo "   Waiting for installation to complete (10 min max)..."
    TIMEOUT=600
    ELAPSED=0
    while [ ! -f "${DCS_UPDATER}" ] && [ "${ELAPSED}" -lt "${TIMEOUT}" ]; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        [ $((ELAPSED % 60)) -eq 0 ] && echo "   ... ${ELAPSED}s elapsed"
    done

    if [ ! -f "${DCS_UPDATER}" ]; then
        echo ""
        echo "   ╔══════════════════════════════════════════════════╗"
        echo "   ║  ERROR: Installation timed out after ${TIMEOUT}s   ║"
        echo "   ╚══════════════════════════════════════════════════╝"
        echo ""
        echo "   DCS_updater.exe was not found at:"
        echo "   ${DCS_UPDATER}"
        echo ""
        echo "   Most likely causes:"
        echo "   • DCS_INSTALLER_URL returned an HTML page (not an .exe)"
        echo "   • The installer needed a GUI interaction Wine couldn't handle"
        echo "   • Eagle Dynamics changed the installer path or format"
        echo ""
        echo "   To debug: set WINEDEBUG=\"\" in the egg and check the console"
        echo "   for Wine errors during the install phase."
        kill "${XVFB_PID}" 2>/dev/null
        exit 1
    fi

    date -u +'%Y-%m-%dT%H:%M:%SZ' > "${SENTINEL}"
    rm -f "${DCS_INSTALLER_TMP}"
    echo "   ✓ DCS base server installed!"
fi

# ════════════════════════════════════════════════════════════
# STEP 5 — Terrain modules
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -n "${DCS_MODULES}" ]; then
    echo " [5/6] Installing terrain modules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for module in ${DCS_MODULES}; do
        echo "   → ${module}"
        wine "${DCS_UPDATER}" --quiet install "${module}" \
            && echo "     ✓ Installed" \
            || echo "     ✗ Failed — paid modules require an Eagle Dynamics account"
    done
else
    echo " [5/6] No terrain modules specified — skipping"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Caucasus terrain is included with the base install."
    echo "   To add more, set DCS_MODULES in the egg variables."
    echo "   e.g. MARIANAISLANDS_terrain SYRIA_terrain"
fi

# ════════════════════════════════════════════════════════════
# STEP 6 — Initial server configuration
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [6/6] Writing initial server configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Only write on first install — preserve any admin edits on reinstall.
SETTINGS_FILE="${DCS_SAVE}/Config/serverSettings.lua"
if [ ! -f "${SETTINGS_FILE}" ]; then
    cat > "${SETTINGS_FILE}" << EOF
cfg =
{
    ["name"]          = "${DCS_SERVER_NAME}",
    ["description"]   = "",
    ["password"]      = "${DCS_SERVER_PASSWORD}",
    ["port"]          = "${DCS_SERVER_PORT}",
    ["maxPlayers"]    = "${DCS_MAX_PLAYERS}",
    ["bind_address"]  = "",
    ["listShuffle"]   = false,
    ["isPublic"]      = true,
    ["missionList"]   = {},
    ["advanced"] =
    {
        ["allow_ownship_export"]  = false,
        ["allow_object_export"]   = false,
        ["allow_sensor_export"]   = false,
        ["event_role"]            = false,
        ["pause_on_load"]         = true,
        ["pause_without_clients"] = false,
        ["resume_mode"]           = 0,
        ["maxPing"]               = 0,
        ["voice_chat_server"]     = false,
        ["server_can_screenshot"] = false,
        ["disable_events"]        = false,
        ["client_outbound_limit"] = 0,
        ["client_inbound_limit"]  = 0,
    },
}
EOF
    echo "   ✓ serverSettings.lua created"
else
    echo "   ℹ Existing serverSettings.lua preserved (admin edits kept)"
fi

# ── Fix ownership ─────────────────────────────────────────────
# The installer runs as root. Pterodactyl's container user is UID 1000.
# Everything under /mnt/server must be owned by 1000 so the runtime
# container can read and write it.
chown -R 1000:1000 "${INSTALL_DIR}"
echo "   ✓ Ownership set to UID 1000 (container user)"

kill "${XVFB_PID}" 2>/dev/null || true

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║        DCS World Dedicated Server — Install Complete!        ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  Server config (edit via File Manager or panel variables):   ║"
echo "║  /home/container/.wine/drive_c/users/container/              ║"
echo "║  Saved Games/DCS.server/Config/serverSettings.lua           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
