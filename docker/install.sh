#!/bin/bash
# ============================================================
# DCS World Dedicated Server — Pterodactyl Install Script
#
# Runs as root inside ghcr.io/pterodactyl/installers:ubuntu
# Everything written to /mnt/server becomes /home/container
# at runtime when Wings mounts the server data volume.
#
# GUI automation approach:
#   The DCS installer does not support /S (silent) mode reliably.
#   Instead, we run the installer with a virtual display (Xvfb)
#   and automate each dialog using xdotool.
#
# Installer dialog sequence (8 screens):
#   1. Select Setup Language     → Enter (OK, English default)
#   2. License Agreement         → click I Accept, click Next
#   3. Select Destination        → Enter (Next, default path)
#   4. Select License Type       → select Compact (no terrain), Next
#   5. Select Start Menu Folder  → Enter (Next)
#   6. Select Additional Tasks   → Enter (Next)
#   7. Ready to Install          → Enter (Install)
#   8. Completing Setup          → Enter (Finish, Start Download checked)
#
# Terrain modules are NOT selected in the installer.
# After the base install, DCS_updater.exe installs any modules
# listed in the DCS_MODULES egg variable.
# ============================================================
set -e
export DEBIAN_FRONTEND=noninteractive

# ── Paths ─────────────────────────────────────────────────────
INSTALL_DIR="/mnt/server"
WINEPREFIX="${INSTALL_DIR}/.wine"
DCS_PROGRAM_DIR="${WINEPREFIX}/drive_c/Program Files/Eagle Dynamics/DCS World Server"
DCS_UPDATER="${DCS_PROGRAM_DIR}/bin/DCS_updater.exe"
DCS_SERVER="${DCS_PROGRAM_DIR}/bin/DCS_server.exe"
DCS_VCREDIST="${DCS_PROGRAM_DIR}/distr/vc_redist.x64.exe"
DCS_INSTALLER_TMP="/tmp/dcs_installer.exe"
SENTINEL="${INSTALL_DIR}/.dcs_installed"

# ── Egg variables ─────────────────────────────────────────────
: "${DCS_INSTALLER_URL:=https://www.digitalcombatsimulator.com/gameloader/dcs_server_installer_latest/DCS_server_installer_latest.exe}"
: "${DCS_WRITE_DIR:=DCS.server}"
: "${DCS_SERVER_NAME:=DCS Pterodactyl Server}"
: "${DCS_SERVER_PORT:=10308}"
: "${DCS_SERVER_PASSWORD:=}"
: "${DCS_MAX_PLAYERS:=16}"
: "${DCS_MODULES:=}"
: "${DCS_MISSION:=default.miz}"
: "${DCS_WEBGUI_PORT:=8088}"

# ── Wine environment ──────────────────────────────────────────
export HOME="${INSTALL_DIR}"
export WINEPREFIX="${WINEPREFIX}"
export WINEARCH="win64"
export DISPLAY=":0"
export WINEDEBUG="-all"
export WINEDLLOVERRIDES="mscoree,mshtml=,winemenubuilder.exe=d"
# CRITICAL: UTF-8 locale. Without it, Wine fails to create file paths
# containing non-ASCII characters (e.g. DCS's C-101CC "Nº410" livery),
# stalling the updater in a retry loop. C.UTF-8 is built into Ubuntu.
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

# ════════════════════════════════════════════════════════════
# STEP 1 — System dependencies
# ════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [1/6] Installing Wine HQ Staging and dependencies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

dpkg --add-architecture i386
apt-get update -y -q
apt-get install -y -q --no-install-recommends \
    ca-certificates wget curl gnupg2 \
    software-properties-common \
    xvfb xdotool \
    winbind cabextract procps unzip

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
echo " [2/6] Starting virtual display"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
Xvfb :0 -screen 0 1024x768x16 -ac &
XVFB_PID=$!
sleep 2
echo "   ✓ Xvfb started (PID: ${XVFB_PID})"

# ════════════════════════════════════════════════════════════
# STEP 3 — Wine prefix
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [3/6] Initialising Wine prefix (win64)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
mkdir -p "${INSTALL_DIR}"

# CRITICAL: Wine refuses to use a prefix not owned by the current user, with
#   "wine: '/mnt/server/.wine' is not owned by you"
# The install container runs as root, but a pre-existing prefix (from an earlier
# partial install, or the server volume's existing ownership) may be owned by
# UID 1000. We run the install as root, so claim everything under INSTALL_DIR
# for root now; the script already chowns it back to UID 1000 at the very end.
# HOME must also point at INSTALL_DIR so Wine resolves the prefix correctly and
# doesn't try to use root's home.
export HOME="${INSTALL_DIR}"
CURRENT_UID="$(id -u)"
echo "   Running as UID ${CURRENT_UID}; claiming prefix ownership..."
chown -R "${CURRENT_UID}:${CURRENT_UID}" "${INSTALL_DIR}" 2>/dev/null || true

# If a prefix exists but is half-built/locked, Wine can still balk. A pre-existing
# valid prefix is fine to reuse; we only need ownership correct (handled above).
wineboot --init
sleep 5
echo "   Installing vcrun2019 (required by DCS)..."
winetricks -q vcrun2019
echo "   ✓ Wine prefix ready"

# Pre-create saved games directory for the runtime container user
DCS_SAVE="${WINEPREFIX}/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}"
mkdir -p "${DCS_SAVE}/Config" "${DCS_SAVE}/Missions" "${DCS_SAVE}/Logs" "${DCS_SAVE}/Scripts"

# ════════════════════════════════════════════════════════════
# STEP 4 — DCS installation or update
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "${SENTINEL}" ] && [ -f "${DCS_UPDATER}" ]; then
    # ── Reinstall: update existing ────────────────────────
    echo " [4/6] Existing install detected — running updater"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Installed: $(cat "${SENTINEL}")"
    wine "${DCS_UPDATER}" --quiet update \
        && echo "   ✓ DCS updated" \
        || echo "   ⚠ Updater returned non-zero (continuing)"
else
    # ── Fresh install ─────────────────────────────────────
    echo " [4/6] Fresh install — downloading and running installer"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Source: ${DCS_INSTALLER_URL}"

    wget --progress=bar:force --show-progress \
         -O "${DCS_INSTALLER_TMP}" \
         "${DCS_INSTALLER_URL}" \
        || { echo "   ERROR: Download failed."; kill "${XVFB_PID}" 2>/dev/null; exit 1; }

    echo ""
    echo "   Launching installer with GUI automation..."
    echo "   (The installer runs in a virtual display — no visible window)"

    # ── Helper: wait for a named window to appear ─────────
    wait_for_window() {
        local name="$1"
        local timeout="${2:-60}"
        local wid=""
        for i in $(seq 1 "${timeout}"); do
            wid=$(xdotool search --name "${name}" 2>/dev/null | tail -1)
            [ -n "${wid}" ] && echo "${wid}" && return 0
            sleep 1
        done
        echo "   ERROR: Window '${name}' did not appear after ${timeout}s" >&2
        return 1
    }

    # ── Helper: click at position relative to a window ────
    wclick() {
        local wid="$1"
        local x="$2"
        local y="$3"
        xdotool windowfocus --sync "${wid}" 2>/dev/null || true
        sleep 0.3
        xdotool mousemove --window "${wid}" "${x}" "${y}"
        sleep 0.2
        xdotool click 1
        sleep 0.3
    }

    # ── Start the installer ───────────────────────────────
    wine "${DCS_INSTALLER_TMP}" &
    INSTALLER_PID=$!

    # ── Dialog 1: Select Setup Language ──────────────────
    # English is already selected. Click OK.
    echo "   [GUI 1/8] Language selection..."
    WID=$(wait_for_window "Select Setup Language" 60)
    wclick "${WID}" 160 120      # OK button
    echo "   ✓ Language: English"

    # All remaining dialogs share the title "Setup - DCS World Server"
    # Wait for it to appear once, then reuse the same window ID throughout
    # (Inno Setup reuses the same window for all wizard pages)
    sleep 2
    WID=$(wait_for_window "Setup - DCS World Server" 30)

    # ── Dialog 2: License Agreement ───────────────────────
    # Must click "I accept the agreement" radio before Next is enabled
    echo "   [GUI 2/8] Accepting licence..."
    sleep 2
    xdotool windowfocus --sync "${WID}"
    sleep 0.5
    wclick "${WID}" 75 300       # "I accept the agreement" radio button
    sleep 0.5
    wclick "${WID}" 365 352      # Next button
    echo "   ✓ Licence accepted"

    # ── Dialog 3: Select Destination Location ─────────────
    # Default path: C:\Program Files\Eagle Dynamics\DCS World Server
    # This is exactly what all our scripts expect. Accept it.
    echo "   [GUI 3/8] Installation directory..."
    sleep 3
    xdotool windowfocus --sync "${WID}"
    sleep 0.5
    wclick "${WID}" 365 330      # Next button
    echo "   ✓ Path: C:\\Program Files\\Eagle Dynamics\\DCS World Server"

    # ── Dialog 4: Select License Type (terrain modules) ───
    # Default is "Full installation (Recommended)" = 464GB+
    # We select "Compact installation" (no terrain, ~1-2GB base only).
    # Terrain modules are added afterwards via DCS_updater.exe using DCS_MODULES.
    echo "   [GUI 4/8] Selecting Compact installation (no terrain)..."
    sleep 3
    xdotool windowfocus --sync "${WID}"
    sleep 0.5
    # Click the dropdown to focus it
    wclick "${WID}" 320 132
    sleep 0.5
    # Open dropdown with Alt+Down, navigate to second option, confirm
    xdotool key alt+Down
    sleep 0.5
    xdotool key Down             # "Compact installation" is the second option
    sleep 0.3
    xdotool key Return
    sleep 0.5
    wclick "${WID}" 365 352      # Next button
    echo "   ✓ Compact installation selected"

    # ── Dialog 5: Select Start Menu Folder ────────────────
    echo "   [GUI 5/8] Start menu folder..."
    sleep 3
    xdotool windowfocus --sync "${WID}"
    sleep 0.5
    wclick "${WID}" 365 330      # Next button
    echo "   ✓ Start menu OK"

    # ── Dialog 6: Select Additional Tasks ─────────────────
    # "Create desktop icon" is checked — irrelevant for a server, leave it
    echo "   [GUI 6/8] Additional tasks..."
    sleep 3
    xdotool windowfocus --sync "${WID}"
    sleep 0.5
    wclick "${WID}" 365 330      # Next button
    echo "   ✓ Additional tasks OK"

    # ── Dialog 7: Ready to Install ────────────────────────
    echo "   [GUI 7/8] Starting installation..."
    sleep 3
    xdotool windowfocus --sync "${WID}"
    sleep 0.5
    wclick "${WID}" 365 330      # Install button
    echo "   ✓ Installation in progress..."

    # ── Dialog 8: Completing the DCS World Server Setup Wizard ──
    # "Start Download" checkbox is ticked by default.
    # Clicking Finish closes the wizard and launches DCS_updater.exe
    # which performs the actual game file download.
    echo "   [GUI 8/8] Waiting for setup wizard to complete..."
    # Wait up to 5 minutes for the wizard to finish its copy phase
    WIZARD_TIMEOUT=300
    WIZARD_ELAPSED=0
    while kill -0 "${INSTALLER_PID}" 2>/dev/null && [ "${WIZARD_ELAPSED}" -lt "${WIZARD_TIMEOUT}" ]; do
        # Check if the completing dialog is showing
        xdotool windowfocus --sync "${WID}" 2>/dev/null || true
        TITLE=$(xdotool getactivewindow getwindowname 2>/dev/null || echo "")
        if echo "${TITLE}" | grep -q "DCS World Server"; then
            # Try clicking Finish — if we're still on dialog 7 this is a no-op
            wclick "${WID}" 365 350 2>/dev/null || true
        fi
        sleep 5
        WIZARD_ELAPSED=$((WIZARD_ELAPSED + 5))
    done
    echo "   ✓ Setup wizard complete"

    # ── Wait for DCS_updater.exe to be created by the installer ──────────
    # The Inno Setup wizard installs DCS_updater.exe, then (with "Start
    # Download" checked) launches it to download the actual game files.
    echo ""
    echo "   Waiting for DCS_updater.exe to appear..."
    UPDATER_TIMEOUT=120
    UPDATER_ELAPSED=0
    while [ ! -f "${DCS_UPDATER}" ] && [ "${UPDATER_ELAPSED}" -lt "${UPDATER_TIMEOUT}" ]; do
        sleep 5
        UPDATER_ELAPSED=$((UPDATER_ELAPSED + 5))
    done

    if [ ! -f "${DCS_UPDATER}" ]; then
        echo ""
        echo "   ERROR: DCS_updater.exe not found after installer completed."
        echo "   The Inno Setup wizard did not install the updater."
        echo "   Check: ${DCS_UPDATER}"
        kill "${XVFB_PID}" 2>/dev/null
        exit 1
    fi
    echo "   ✓ DCS_updater.exe found"

    # Kill the installer-launched updater instance so we control the download
    # ourselves through an explicit retry loop (more reliable than watching
    # the auto-launched one, which can exit early on a fresh install).
    pkill -f "DCS_updater.exe" 2>/dev/null || true
    sleep 5

    # ── Active updater retry loop with live progress feedback ────────────
    # PROVEN BEHAVIOUR: on a fresh install the DCS updater frequently exits
    # before the full download completes (network hiccups, leftover-file
    # cleanup prompts between phases, etc.) and must simply be re-run — it
    # resumes from where it stopped. Rather than passively waiting for files
    # to appear, we actively re-invoke the updater until DCS_server.exe
    # exists, which is the definitive signal that the core install is done.
    #
    # PROGRESS FEEDBACK: the updater writes its progress bar to its GUI
    # window (Xvfb), not to stdout, so we can't pipe the percentage directly.
    # Instead we provide two real signals to the panel console:
    #   1. We tail the updater's own log file (autoupdate_log.txt) if present.
    #   2. A background heartbeat prints the install size every 30s so the
    #      operator can see bytes actually landing on disk during the download.
    echo ""
    echo "   Starting game file download (the main ~several-GB download)."
    echo "   The updater will be re-run automatically until it completes."
    echo "   This can take 20-60+ minutes depending on connection speed."
    echo "   Live progress (disk size + updater log) is shown below."
    echo ""

    # The updater log lives in the install dir. Name varies by version, so
    # we search for either known name once it appears.
    UPDATER_LOG_DIR="${DCS_PROGRAM_DIR}/_downloads"

    # ── Background heartbeat: prints install size every 30s ──────────────
    (
        while [ ! -f "${DCS_SERVER}" ]; do
            SIZE=$(du -sh "${DCS_PROGRAM_DIR}" 2>/dev/null | cut -f1)
            echo "   [heartbeat $(date -u +%H:%M:%SZ)] installed size: ${SIZE:-unknown} (still downloading...)"
            sleep 30
        done
    ) &
    HEARTBEAT_PID=$!

    # ── Background log tail: streams the updater's own log when it appears ─
    (
        # Wait for a log file to be created, then follow it
        LOGFILE=""
        for i in $(seq 1 60); do
            LOGFILE=$(find "${UPDATER_LOG_DIR}" -maxdepth 1 -iname "autoupdate*log*" 2>/dev/null | head -1)
            [ -n "${LOGFILE}" ] && break
            sleep 5
        done
        if [ -n "${LOGFILE}" ]; then
            echo "   [log] following updater log: $(basename "${LOGFILE}")"
            # Prefix each line so it's distinguishable in the panel console
            tail -F "${LOGFILE}" 2>/dev/null | sed 's/^/   [dcs] /'
        fi
    ) &
    LOGTAIL_PID=$!

    # Ensure both background helpers are cleaned up no matter how we exit.
    stop_progress_helpers() {
        kill "${HEARTBEAT_PID}" 2>/dev/null || true
        kill "${LOGTAIL_PID}"   2>/dev/null || true
        # Also kill the tail child the subshell spawned
        pkill -P "${LOGTAIL_PID}" 2>/dev/null || true
    }

    MAX_ATTEMPTS=40          # generous upper bound to avoid an infinite loop
    ATTEMPT=0
    while [ ! -f "${DCS_SERVER}" ] && [ "${ATTEMPT}" -lt "${MAX_ATTEMPTS}" ]; do
        ATTEMPT=$((ATTEMPT + 1))
        echo "   [updater attempt ${ATTEMPT}/${MAX_ATTEMPTS}] $(date -u +%H:%M:%SZ)"

        # --quiet runs without the interactive GUI. The "extra files" cleanup
        # prompt that appeared during manual testing does not block in quiet
        # mode; the updater handles it and exits, and we simply re-run.
        wine "${DCS_UPDATER}" --quiet update 2>/dev/null || true

        # Make sure no updater lingers before the next attempt.
        pkill -f "DCS_updater.exe" 2>/dev/null || true
        sleep 5
    done

    stop_progress_helpers

    if [ ! -f "${DCS_SERVER}" ]; then
        echo ""
        echo "   ERROR: DCS_server.exe still not present after ${MAX_ATTEMPTS} updater runs."
        echo "   Expected at: ${DCS_SERVER}"
        echo "   The download may be failing repeatedly — check connectivity"
        echo "   to the Eagle Dynamics servers, or run the updater manually"
        echo "   to see the on-screen error."
        kill "${XVFB_PID}" 2>/dev/null
        exit 1
    fi

    date -u +'%Y-%m-%dT%H:%M:%SZ' > "${SENTINEL}"
    rm -f "${DCS_INSTALLER_TMP}"
    echo "   ✓ DCS base server installed and downloaded!"
fi

# ════════════════════════════════════════════════════════════
# STEP 4b — Visual C++ runtime (timezone-crash fix)
# ════════════════════════════════════════════════════════════
# DCS calls __std_tzdb_get_sys_info in msvcp140_atomic_wait.dll at startup.
# Wine's builtin copy of that DLL is incompletely implemented and aborts the
# process. Installing the VC++ redistributable that DCS bundles places the
# real Microsoft DLL into the prefix; the entrypoint then forces native use
# via WINEDLLOVERRIDES. Without this the server crashes before it can host.
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [4b/6] Installing Visual C++ runtime (timezone-crash fix)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -f "${DCS_VCREDIST}" ]; then
    wine "${DCS_VCREDIST}" /quiet /norestart || echo "   ⚠ vc_redist returned non-zero (continuing)"
    sleep 10
    if [ -f "${WINEPREFIX}/drive_c/windows/system32/msvcp140_atomic_wait.dll" ]; then
        echo "   ✓ msvcp140_atomic_wait.dll present in prefix"
    else
        echo "   ⚠ msvcp140_atomic_wait.dll not found — server may crash on launch"
    fi
else
    echo "   ⚠ vc_redist.x64.exe not found at expected path; skipping"
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
            || echo "     ✗ Failed (paid modules may require an Eagle Dynamics account)"
    done
else
    echo " [5/6] No terrain modules specified — skipping"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Set DCS_MODULES in the egg to install terrain maps."
    echo "   Example: CAUCASUS_terrain MARIANAISLANDS_terrain"
fi

# ════════════════════════════════════════════════════════════
# STEP 6 — Mission seeding + initial server configuration
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [6/6] Seeding mission and writing configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Pre-create all the dirs DCS writes to (Tracks/ avoids a startup error).
mkdir -p "${DCS_SAVE}/Config" "${DCS_SAVE}/Missions" \
          "${DCS_SAVE}/Tracks"  "${DCS_SAVE}/Logs" "${DCS_SAVE}/Scripts"

# Windows-style path to the Saved Games dir for use in Lua config.
DCS_SAVE_WIN="C:\\users\\container\\Saved Games\\${DCS_WRITE_DIR}"

# Seed a bundled mission as the configured DCS_MISSION filename so the server
# has something to load on first start (it idles without a mission). Admins
# can later upload their own .miz to Missions/ and set DCS_MISSION to match.
MISSION_FILE="${DCS_SAVE}/Missions/${DCS_MISSION}"
if [ ! -f "${MISSION_FILE}" ]; then
    SEED=$(find "${DCS_PROGRAM_DIR}" -iname "*caucasus*.miz" 2>/dev/null | head -1)
    [ -z "${SEED}" ] && SEED=$(find "${DCS_PROGRAM_DIR}" -iname "*.miz" 2>/dev/null | head -1)
    if [ -n "${SEED}" ]; then
        cp "${SEED}" "${MISSION_FILE}"
        echo "   ✓ Seeded mission: $(basename "${SEED}") → Missions/${DCS_MISSION}"
    else
        echo "   ⚠ No bundled .miz found to seed; upload one to Missions/ before starting"
    fi
else
    echo "   ✓ Mission already present: ${DCS_MISSION}"
fi

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
    ["isPublic"]      = true,
    ["listShuffle"]   = false,
    ["require_pure_textures"] = true,
    ["missionList"]   =
    {
        [1] = "${DCS_SAVE_WIN}\\Missions\\${DCS_MISSION}",
    },
    ["current_mission"] = 1,
    ["advanced"] =
    {
        ["allow_ownship_export"]  = false,
        ["allow_object_export"]   = false,
        ["allow_sensor_export"]   = false,
        ["pause_on_load"]         = false,
        ["pause_without_clients"] = false,
        ["resume_mode"]           = 1,
        ["maxPing"]               = 0,
        ["disable_events"]        = false,
        ["voice_chat_server"]     = false,
        ["server_can_screenshot"] = false,
    },
}
EOF
    echo "   ✓ serverSettings.lua created (mission autostart enabled)"
else
    echo "   ℹ Existing serverSettings.lua preserved"
fi

chown -R 1000:1000 "${INSTALL_DIR}"
echo "   ✓ Ownership set to UID 1000 (container user)"

kill "${XVFB_PID}" 2>/dev/null || true

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║        DCS World Dedicated Server — Install Complete!        ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  Config: /home/container/.wine/drive_c/users/container/      ║"
echo "║          Saved Games/DCS.server/Config/serverSettings.lua   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
