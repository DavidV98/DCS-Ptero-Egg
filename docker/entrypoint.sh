#!/bin/bash
# ============================================================
# DCS World Dedicated Server — Pterodactyl Entrypoint
#
# Responsibilities (in order):
#   1. Start virtual display (Xvfb)
#   2. Initialize Wine prefix on first run
#   3. Install DCS server if not present
#   4. Update DCS if AUTO_UPDATE=1
#   5. Generate missing config files
#   6. Launch DCS server, stream log to stdout
# ============================================================
set -e

cd /home/container

# ── Paths ─────────────────────────────────────────────────────────────────────
# The Wine prefix lives inside /home/container (the Pterodactyl data volume),
# so it persists across container restarts.
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"

# DCS installs to C:\Program Files\Eagle Dynamics\DCS World Server\ by default.
# On Linux, that maps to this path inside the Wine prefix:
DCS_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files/Eagle Dynamics/DCS World Server"
DCS_UPDATER="${DCS_INSTALL_DIR}/bin/DCS_updater.exe"
DCS_SERVER="${DCS_INSTALL_DIR}/bin/DCS_server.exe"

# ── Egg / environment variables (all have sensible defaults) ──────────────────
# Override these from the Pterodactyl panel via egg variables.
DCS_INSTALLER_URL="${DCS_INSTALLER_URL:-https://www.digitalcombatsimulator.com/gameloader/dcs_server_installer_latest/DCS_server_installer_latest.exe}"
DCS_WRITE_DIR="${DCS_WRITE_DIR:-DCS.server}"
DCS_SERVER_NAME="${DCS_SERVER_NAME:-DCS Pterodactyl Server}"
DCS_SERVER_PORT="${DCS_SERVER_PORT:-10308}"
DCS_SERVER_PASSWORD="${DCS_SERVER_PASSWORD:-}"
DCS_MAX_PLAYERS="${DCS_MAX_PLAYERS:-16}"
DCS_WEBGUI_PORT="${DCS_WEBGUI_PORT:-8088}"
DCS_BRANCH="${DCS_BRANCH:-}"
DCS_MODULES="${DCS_MODULES:-}"
AUTO_UPDATE="${AUTO_UPDATE:-0}"

# Saved Games folder — DCS stores config, logs, missions here.
# At runtime, Wine runs as the Linux 'container' user, so the Windows
# user directory is C:\users\container\ → this Linux path:
DCS_SAVE="${WINEPREFIX}/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}"

# Sentinel file: written after successful DCS installation.
# Lives in /home/container (the persistent volume) so it survives restarts.
SENTINEL="/home/container/.dcs_installed"

# Temp path for the downloaded installer (ephemeral, not in persistent volume).
DCS_INSTALLER_TMP="/tmp/dcs_installer.exe"

# Export Wine environment
export WINEPREFIX WINEARCH WINEDLLOVERRIDES WINEDEBUG
export DISPLAY=:0

# ── Process tracking ──────────────────────────────────────────────────────────
DCS_PID=""
XVFB_PID=""
TAIL_PID=""

# ── Signal handler ────────────────────────────────────────────────────────────
# Pterodactyl sends SIGTERM when the server is stopped from the panel.
# We relay it to DCS, give it a moment to flush, then clean up.
cleanup() {
    echo ""
    echo "[DCS] Stop signal received. Shutting down..."
    if [ -n "$DCS_PID" ]; then
        kill -SIGTERM "$DCS_PID" 2>/dev/null || true
        # Give DCS up to 15 seconds to exit gracefully before we force-quit.
        for i in $(seq 1 15); do
            kill -0 "$DCS_PID" 2>/dev/null || break
            sleep 1
        done
        kill -SIGKILL "$DCS_PID" 2>/dev/null || true
    fi
    [ -n "$TAIL_PID" ]  && kill "$TAIL_PID"  2>/dev/null || true
    [ -n "$XVFB_PID" ]  && kill "$XVFB_PID" 2>/dev/null || true
    echo "[DCS] Shutdown complete."
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ════════════════════════════════════════════════════════════
# STEP 1 — Virtual display
# ════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [1/5] Starting virtual display (Xvfb)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Xvfb :0 -screen 0 1024x768x16 -ac +extension GLX +render -noreset &
XVFB_PID=$!
sleep 2

# Verify the socket actually exists — if /tmp/.X11-unix wasn't pre-created
# in the Dockerfile, Xvfb silently fails to bind and Wine has no display.
if [ ! -S "/tmp/.X11-unix/X0" ]; then
    echo "   ERROR: Xvfb socket /tmp/.X11-unix/X0 not found."
    echo "   The Dockerfile is missing: RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix"
    exit 1
fi
echo "   ✓ Xvfb running and socket confirmed (PID: ${XVFB_PID})"

# ════════════════════════════════════════════════════════════
# STEP 2 — Wine prefix
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [2/5] Wine prefix (${WINEPREFIX})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "${WINEPREFIX}/system.reg" ]; then
    echo "   First run — initialising Wine prefix (win64)..."
    wineboot --init
    sleep 5

    echo "   Installing vcrun2019 (required by DCS)..."
    # Non-fatal: winetricks can fail on first run in some environments.
    # DCS may still launch. If it crashes with a missing DLL error,
    # trigger a reinstall to retry this step with a confirmed working display.
    winetricks -q vcrun2019 || echo "   WARNING: winetricks failed — continuing anyway."
    echo "   ✓ Wine prefix ready."
else
    echo "   ✓ Existing Wine prefix found."
fi

# ════════════════════════════════════════════════════════════
# STEP 3 — DCS installation / update
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "$SENTINEL" ] || [ ! -f "$DCS_UPDATER" ]; then
    # ── Fresh install ─────────────────────────────────────────
    echo " [3/5] Installing DCS World Dedicated Server (first run)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   This will take several minutes."
    echo "   Downloading installer from Eagle Dynamics..."

    wget --progress=bar:force --show-progress \
         -O "$DCS_INSTALLER_TMP" \
         "$DCS_INSTALLER_URL" \
        || { echo "   ERROR: Download failed. Verify DCS_INSTALLER_URL is correct."; exit 1; }

    echo ""
    echo "   Running silent installer (/S flag)..."
    # /S = silent NSIS install. DCS will install to the default Windows path:
    # C:\Program Files\Eagle Dynamics\DCS World Server\
    wine "$DCS_INSTALLER_TMP" /S

    echo "   Waiting for installation to complete (up to 10 min)..."
    TIMEOUT=600
    ELAPSED=0
    while [ ! -f "$DCS_UPDATER" ] && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        [ $((ELAPSED % 60)) -eq 0 ] && echo "   ... ${ELAPSED}s elapsed"
    done

    if [ ! -f "$DCS_UPDATER" ]; then
        echo ""
        echo "   ERROR: Installation timed out after ${TIMEOUT}s."
        echo "   DCS_updater.exe was not found at:"
        echo "   ${DCS_UPDATER}"
        echo ""
        echo "   Possible causes:"
        echo "   - Installer URL is wrong or the download was incomplete"
        echo "   - Wine/D3D initialisation failed (check WINEDEBUG output)"
        echo "   - The installer wrote to a different path (check ${WINEPREFIX}/drive_c/)"
        exit 1
    fi

    # Write sentinel with install timestamp.
    date -u +'Installed %Y-%m-%dT%H:%M:%SZ' > "$SENTINEL"
    rm -f "$DCS_INSTALLER_TMP"
    echo "   ✓ DCS base server installed!"

    # ── Terrain modules (at install time) ─────────────────────
    if [ -n "$DCS_MODULES" ]; then
        echo ""
        echo "   Installing terrain modules: ${DCS_MODULES}"
        for module in $DCS_MODULES; do
            echo "   → ${module}"
            # --quiet suppresses the GUI updater window.
            wine "$DCS_UPDATER" --quiet install "$module" \
                && echo "     ✓ Installed" \
                || echo "     ✗ Failed — paid modules require an ED account login."
        done
    fi

elif [ "$AUTO_UPDATE" = "1" ]; then
    # ── Update existing install ───────────────────────────────
    echo " [3/5] Checking for DCS updates (AUTO_UPDATE=1)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ -n "$DCS_BRANCH" ]; then
        echo "   Branch: ${DCS_BRANCH}"
        wine "$DCS_UPDATER" --quiet update "@${DCS_BRANCH}" \
            && echo "   ✓ DCS updated." \
            || echo "   ⚠ Update failed — continuing with existing install."
    else
        wine "$DCS_UPDATER" --quiet update \
            && echo "   ✓ DCS updated." \
            || echo "   ⚠ Update failed — continuing with existing install."
    fi

    # Install any modules added to DCS_MODULES since last run.
    if [ -n "$DCS_MODULES" ]; then
        for module in $DCS_MODULES; do
            wine "$DCS_UPDATER" --quiet install "$module" 2>/dev/null || true
        done
    fi

else
    echo " [3/5] DCS installed. Skipping update (AUTO_UPDATE=0)."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# ════════════════════════════════════════════════════════════
# STEP 4 — Configuration
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [4/5] Server configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p "${DCS_SAVE}/Config" \
          "${DCS_SAVE}/Missions" \
          "${DCS_SAVE}/Logs" \
          "${DCS_SAVE}/Scripts"

# serverSettings.lua ─────────────────────────────────────────
# Only created on first run. Admin edits via the panel file manager
# or the DCS WebGUI are preserved across restarts.
SETTINGS_FILE="${DCS_SAVE}/Config/serverSettings.lua"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "   Creating serverSettings.lua..."
    # IMPORTANT: DCS uses the 'cfg' table, not 'options'.
    # Using the wrong key causes the server to silently ignore the file.
    cat > "$SETTINGS_FILE" << EOF
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
    echo "   ✓ serverSettings.lua created."
else
    echo "   ℹ Existing serverSettings.lua preserved (admin edits kept)."
fi

# autoexec.cfg ───────────────────────────────────────────────
# Regenerated every start so panel variable changes take effect immediately.
AUTOEXEC_FILE="${DCS_SAVE}/Config/autoexec.cfg"
echo "   Writing autoexec.cfg..."
cat > "$AUTOEXEC_FILE" << EOF
-- Auto-generated by Pterodactyl entrypoint on every start.
-- Static settings (name, password, port) live in serverSettings.lua.
if not net then net = {} end

-- Headless server optimisations.
options           = options or {}
options.graphics  = options.graphics or {}
options.graphics.maxfps   = 30
options.graphics.render3D = false

-- DCS WebGUI remote control port.
webgui_port = ${DCS_WEBGUI_PORT}

-- Suppress crash reporter GUI (still writes a crash log).
crash_report_mode = "silent"
EOF
echo "   ✓ autoexec.cfg written."

# ════════════════════════════════════════════════════════════
# STEP 5 — Launch
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [5/5] Launching DCS World Dedicated Server"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Server:   ${DCS_SERVER_NAME}"
echo "   Port:     ${DCS_SERVER_PORT}/udp"
echo "   WebGUI:   ${DCS_WEBGUI_PORT}/tcp"
echo "   Profile:  ${DCS_WRITE_DIR}"
echo ""

# The -w flag tells DCS which 'Saved Games' profile directory to use.
# Running in background so we can tail the log file to stdout below.
wine "$DCS_SERVER" -w "$DCS_WRITE_DIR" &
DCS_PID=$!

# ── Log streaming ──────────────────────────────────────────────
# DCS writes its output to a log file, not stdout/stderr.
# We tail the log to stdout so Pterodactyl can read it for the
# "Server: listening" startup detection string and live console output.
DCS_LOG="${DCS_SAVE}/Logs/dcs.log"
echo "   Waiting for DCS log file to appear..."
WAITED=0
while [ ! -f "$DCS_LOG" ] && [ "$WAITED" -lt 120 ]; do
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ -f "$DCS_LOG" ]; then
    echo "   Streaming log to console..."
    tail -F "$DCS_LOG" &
    TAIL_PID=$!
else
    echo "   WARNING: Log not found after 120s."
    echo "   The server may have crashed. Check Wine errors by setting WINEDEBUG=\"\"."
fi

# ── Wait ────────────────────────────────────────────────────────
# Block here until DCS exits (naturally or from SIGTERM via cleanup()).
wait "$DCS_PID"
EXIT_CODE=$?

echo ""
echo "[DCS] Server process exited with code ${EXIT_CODE}."

[ -n "$TAIL_PID" ]  && kill "$TAIL_PID"  2>/dev/null || true
[ -n "$XVFB_PID" ]  && kill "$XVFB_PID" 2>/dev/null || true

exit "$EXIT_CODE"
