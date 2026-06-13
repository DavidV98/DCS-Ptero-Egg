#!/bin/bash
# ============================================================
# DCS World Dedicated Server — Pterodactyl Entrypoint
#
# Runs on every server start. Responsibilities:
#   1. Start virtual display (Xvfb)
#   2. Initialise Wine prefix if missing
#   3. Optionally update DCS (AUTO_UPDATE=1)
#   4. Seed/select the mission from DCS_MISSION
#   5. Generate config from panel variables
#   6. Launch DCS server, stream log to stdout
#
# Hard-won fixes baked in (discovered during bring-up):
#   - WINEARCH=win64 (server is 64-bit)
#   - C.UTF-8 locale (Wine mangles non-ASCII livery paths otherwise)
#   - vc_redist install + msvcp140_atomic_wait=n override
#     (server aborts on __std_tzdb_get_sys_info without the native DLL)
#   - Pre-create Tracks/ and Missions/ (silence write errors)
#   - A mission MUST be present or the server idles without starting
# ============================================================
set -e
cd /home/container

# ── Paths ─────────────────────────────────────────────────────────────────────
WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
DCS_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files/Eagle Dynamics/DCS World Server"
DCS_UPDATER="${DCS_INSTALL_DIR}/bin/DCS_updater.exe"
DCS_SERVER="${DCS_INSTALL_DIR}/bin/DCS_server.exe"
DCS_VCREDIST="${DCS_INSTALL_DIR}/distr/vc_redist.x64.exe"

# ── Egg variables ─────────────────────────────────────────────────────────────
DCS_WRITE_DIR="${DCS_WRITE_DIR:-DCS.server}"
DCS_SERVER_NAME="${DCS_SERVER_NAME:-DCS Pterodactyl Server}"
DCS_SERVER_PORT="${DCS_SERVER_PORT:-10308}"
DCS_SERVER_PASSWORD="${DCS_SERVER_PASSWORD:-}"
DCS_MAX_PLAYERS="${DCS_MAX_PLAYERS:-16}"
DCS_WEBGUI_PORT="${DCS_WEBGUI_PORT:-8088}"
DCS_BRANCH="${DCS_BRANCH:-}"
DCS_MISSION="${DCS_MISSION:-default.miz}"
AUTO_UPDATE="${AUTO_UPDATE:-0}"
DCS_USERNAME="${DCS_USERNAME:-}"
DCS_PASSWORD="${DCS_PASSWORD:-}"
DCS_DEBUG_VNC="${DCS_DEBUG_VNC:-0}"
DCS_VNC_PORT="${DCS_VNC_PORT:-6080}"

# Saved Games profile directory (Wine runs as Linux user 'container')
DCS_SAVE="${WINEPREFIX}/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}"
# Windows-style path to the same dir, for use inside Lua config
DCS_SAVE_WIN="C:\\users\\container\\Saved Games\\${DCS_WRITE_DIR}"

# ── Wine environment ────────────────────────────────────────────────────────────
export WINEPREFIX
export WINEARCH="${WINEARCH:-win64}"
export WINEDEBUG="${WINEDEBUG:--all}"
export DISPLAY=:0
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
# Force the native (Microsoft) msvcp140_atomic_wait.dll. Wine's builtin is
# only ~65% implemented and aborts on __std_tzdb_get_sys_info, which DCS calls
# during startup. Combined with mscoree/mshtml disabled (no Mono/Gecko popups).
export WINEDLLOVERRIDES="msvcp140_atomic_wait=n,b;mscoree,mshtml=;winemenubuilder.exe=d"

# ── Process tracking ──────────────────────────────────────────────────────────
DCS_PID="" ; XVFB_PID="" ; TAIL_PID=""

cleanup() {
    echo ""
    echo "[DCS] Stop signal received. Shutting down..."
    if [ -n "$DCS_PID" ]; then
        kill -SIGTERM "$DCS_PID" 2>/dev/null || true
        for i in $(seq 1 15); do
            kill -0 "$DCS_PID" 2>/dev/null || break
            sleep 1
        done
        kill -SIGKILL "$DCS_PID" 2>/dev/null || true
    fi
    [ -n "$TAIL_PID" ]  && kill "$TAIL_PID"  2>/dev/null || true
    [ -n "$NOVNC_PID" ] && kill "$NOVNC_PID" 2>/dev/null || true
    [ -n "$WM_PID" ]    && kill "$WM_PID"    2>/dev/null || true
    pkill -f x11vnc 2>/dev/null || true
    [ -n "$XVFB_PID" ]  && kill "$XVFB_PID" 2>/dev/null || true
    echo "[DCS] Shutdown complete."
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ════════════════════════════════════════════════════════════
# STEP 1 — Virtual display
# ════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [1/6] Starting virtual display (Xvfb)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Xvfb :0 -screen 0 1024x768x16 -ac +extension GLX +render -noreset &
XVFB_PID=$!
sleep 2
if [ ! -S "/tmp/.X11-unix/X0" ]; then
    echo "   ERROR: Xvfb socket not found. Dockerfile must create /tmp/.X11-unix (chmod 1777)."
    exit 1
fi
echo "   ✓ Xvfb running (PID: ${XVFB_PID})"

# ── Optional noVNC debug console (LOCAL USE ONLY) ─────────────────────────────
# When DCS_DEBUG_VNC=1, start a browser-accessible VNC view of the Xvfb display
# so you can watch/interact with the DCS GUI for troubleshooting. Reachable at
# http://<wings-host-ip>:${DCS_VNC_PORT}/vnc.html
# SECURITY: there is no VNC password. Only enable on a trusted local network;
# never expose ${DCS_VNC_PORT} to the public internet.
VNC_PID="" ; NOVNC_PID="" ; WM_PID=""
if [ "${DCS_DEBUG_VNC}" = "1" ]; then
    echo ""
    echo "   [debug] DCS_DEBUG_VNC=1 — starting noVNC console on port ${DCS_VNC_PORT}"
    echo "   [debug] Open http://<your-wings-host-ip>:${DCS_VNC_PORT}/vnc.html"
    echo "   [debug] WARNING: no password — LOCAL/TRUSTED NETWORK ONLY, never expose publicly"
    openbox &
    WM_PID=$!
    sleep 1
    x11vnc -display :0 -nopw -forever -shared -quiet -bg >/dev/null 2>&1 || true
    # novnc launcher script name differs across distros; try both.
    if command -v novnc_proxy >/dev/null 2>&1; then
        novnc_proxy --vnc localhost:5900 --listen ${DCS_VNC_PORT} >/dev/null 2>&1 &
        NOVNC_PID=$!
    else
        websockify --web /usr/share/novnc ${DCS_VNC_PORT} localhost:5900 >/dev/null 2>&1 &
        NOVNC_PID=$!
    fi
    echo "   [debug] noVNC started"
fi

# ════════════════════════════════════════════════════════════
# STEP 2 — Wine prefix
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [2/6] Wine prefix"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ ! -f "${WINEPREFIX}/system.reg" ]; then
    echo "   First run — initialising Wine prefix..."
    wineboot --init
    sleep 5
    winetricks -q vcrun2019 || echo "   WARNING: winetricks vcrun2019 failed (continuing)."
    echo "   ✓ Wine prefix initialised."
else
    echo "   ✓ Existing Wine prefix found."
fi

# Ensure the native VC++ runtime DLL is present (the timezone-crash fix).
# Idempotent: if already installed it's a quick no-op.
if [ -f "${DCS_VCREDIST}" ]; then
    if [ ! -f "${WINEPREFIX}/drive_c/windows/system32/msvcp140_atomic_wait.dll" ]; then
        echo "   Installing DCS-bundled vc_redist.x64.exe (provides msvcp140_atomic_wait)..."
        wine "${DCS_VCREDIST}" /quiet /norestart || echo "   WARNING: vc_redist install returned non-zero."
        sleep 10
    fi
fi

# ════════════════════════════════════════════════════════════
# STEP 3 — Optional update
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$AUTO_UPDATE" = "1" ] && [ -f "${DCS_UPDATER}" ]; then
    echo " [3/6] AUTO_UPDATE=1 — checking for updates"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ -n "$DCS_BRANCH" ]; then
        wine "${DCS_UPDATER}" --quiet update "@${DCS_BRANCH}" || echo "   ⚠ update failed (continuing)"
    else
        wine "${DCS_UPDATER}" --quiet update || echo "   ⚠ update failed (continuing)"
    fi
    pkill -f "DCS_updater.exe" 2>/dev/null || true
    echo "   ✓ Update check complete"
else
    echo " [3/6] Skipping update (AUTO_UPDATE=${AUTO_UPDATE})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# ════════════════════════════════════════════════════════════
# STEP 4 — Mission selection
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [4/6] Mission setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
mkdir -p "${DCS_SAVE}/Config" "${DCS_SAVE}/Missions" \
          "${DCS_SAVE}/Tracks"  "${DCS_SAVE}/Logs" "${DCS_SAVE}/Scripts"

MISSION_FILE="${DCS_SAVE}/Missions/${DCS_MISSION}"

# If the selected mission doesn't exist, seed a bundled one as 'default.miz'
# so the server always has something to load and can reach a running state.
if [ ! -f "${MISSION_FILE}" ]; then
    echo "   Mission '${DCS_MISSION}' not found in Missions/."
    echo "   Seeding a bundled mission so the server can start..."
    # Prefer a Caucasus mission (Caucasus ships with the base server).
    SEED=$(find "${DCS_INSTALL_DIR}" -iname "*caucasus*.miz" 2>/dev/null | head -1)
    # Fall back to ANY bundled mission if no Caucasus one is found.
    [ -z "${SEED}" ] && SEED=$(find "${DCS_INSTALL_DIR}" -iname "*.miz" 2>/dev/null | head -1)
    if [ -n "${SEED}" ]; then
        cp "${SEED}" "${MISSION_FILE}"
        echo "   ✓ Seeded: $(basename "${SEED}") → Missions/${DCS_MISSION}"
    else
        echo "   ERROR: No .miz files found in the install to seed."
        echo "   Upload a mission to Missions/ and set DCS_MISSION to its filename."
    fi
else
    echo "   ✓ Using mission: ${DCS_MISSION}"
fi

# ════════════════════════════════════════════════════════════
# STEP 5 — Configuration
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [5/6] Writing configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# serverSettings.lua — created on first run, then preserved so admin/WebGUI
# edits survive restarts. The mission path is always (re)written below if the
# file is being created fresh.
SETTINGS_FILE="${DCS_SAVE}/Config/serverSettings.lua"
if [ ! -f "${SETTINGS_FILE}" ]; then
    echo "   Creating serverSettings.lua..."
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
    echo "   ℹ Existing serverSettings.lua preserved (panel/WebGUI edits kept)"
fi

# autoexec.cfg — regenerated each start so the WebGUI port tracks the variable.
cat > "${DCS_SAVE}/Config/autoexec.cfg" << EOF
-- Auto-generated each start by the Pterodactyl entrypoint.
if not net then net = {} end
options           = options or {}
options.graphics  = options.graphics or {}
options.graphics.maxfps   = 30
options.graphics.render3D = false
webgui_port = ${DCS_WEBGUI_PORT}
crash_report_mode = "silent"
EOF
echo "   ✓ autoexec.cfg written (WebGUI port ${DCS_WEBGUI_PORT})"

# ── Eagle Dynamics auto-login ─────────────────────────────────────────────────
# DCS requires an ED account login on first launch before it will host.
#
# VERIFIED during bring-up: the login token persists as an ENCRYPTED file at
#   <Saved Games>/<profile>/Config/network.vault
# It is created on first successful login and survives restarts because the
# prefix lives on the server volume. The username is NOT stored in plaintext
# anywhere, so we cannot template credentials from a file — but we CAN reliably
# detect whether a login already exists by the presence of network.vault.
#
# RECOMMENDED for first setup: set DCS_DEBUG_VNC=1 and log in once via the
# browser console. The credential variables are a best-effort auto-fill; the
# VNC path is the reliable fallback since the vault format is opaque.
NETWORK_VAULT="${DCS_SAVE}/Config/network.vault"

if [ -f "${NETWORK_VAULT}" ]; then
    echo "   ✓ network.vault present — ED login already established, no login needed."
    AUTO_LOGIN_ENABLED=0
elif [ -n "${DCS_USERNAME}" ] && [ -n "${DCS_PASSWORD}" ]; then
    echo "   No network.vault yet — will auto-fill the DCS Login window if it appears."
    echo "   (Best-effort: if it fails, set DCS_DEBUG_VNC=1 and log in manually once.)"
    AUTO_LOGIN_ENABLED=1
else
    echo "   ⚠ No network.vault and no DCS_USERNAME/DCS_PASSWORD set."
    echo "   ⚠ The server will stop at the login screen on first start."
    echo "   ⚠ Set DCS_DEBUG_VNC=1 and log in once via the browser console,"
    echo "   ⚠ or provide the credential variables. After one successful login"
    echo "   ⚠ network.vault is written and this is no longer needed."
    AUTO_LOGIN_ENABLED=0
fi

# ════════════════════════════════════════════════════════════
# STEP 6 — Launch
# ════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [6/6] Launching DCS World Dedicated Server"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Name:    ${DCS_SERVER_NAME}"
echo "   Port:    ${DCS_SERVER_PORT}/udp"
echo "   WebGUI:  ${DCS_WEBGUI_PORT}/tcp  (do NOT expose publicly)"
echo "   Mission: ${DCS_MISSION}"
echo ""

# The WINEDLLOVERRIDES exported above already carries the msvcp140 fix.
wine "${DCS_SERVER}" -w "${DCS_WRITE_DIR}" &
DCS_PID=$!

# ── Auto-fill the DCS Login window (first run only) ──────────────────────────
if [ "${AUTO_LOGIN_ENABLED:-0}" = "1" ]; then
    (
        echo "   [login] Waiting for DCS Login window..."
        WID=""
        for i in $(seq 1 60); do
            WID=$(xdotool search --name "DCS Login" 2>/dev/null | tail -1)
            [ -n "${WID}" ] && break
            sleep 2
        done
        if [ -n "${WID}" ]; then
            xdotool windowactivate --sync "${WID}" 2>/dev/null || true
            sleep 1
            # Username field is focused first; type, Tab to password, type,
            # then toggle "Save password" + "Auto login" so it persists, and
            # submit with Enter. Coordinates avoided in favour of keyboard nav.
            xdotool type --delay 60 "${DCS_USERNAME}"
            sleep 0.5
            xdotool key Tab
            sleep 0.5
            xdotool type --delay 60 "${DCS_PASSWORD}"
            sleep 0.5
            # Tab to the Save password checkbox and enable, then Auto login.
            xdotool key Tab; sleep 0.3; xdotool key space
            xdotool key Tab; sleep 0.3; xdotool key space
            sleep 0.5
            xdotool key Return
            echo "   [login] Credentials submitted. If successful, network.vault"
            echo "   [login] will be written and future starts skip the login."
        else
            echo "   [login] No DCS Login window appeared — already authenticated (good)."
        fi
    ) &
fi

# Stream the DCS log to stdout so Pterodactyl can detect startup and show
# console output. DCS logs to a file, not stdout.
DCS_LOG="${DCS_SAVE}/Logs/dcs.log"
echo "   Waiting for log file..."
WAITED=0
while [ ! -f "$DCS_LOG" ] && [ "$WAITED" -lt 120 ]; do
    sleep 2; WAITED=$((WAITED + 2))
done
if [ -f "$DCS_LOG" ]; then
    echo "   Streaming DCS log to console..."
    tail -F "$DCS_LOG" &
    TAIL_PID=$!
else
    echo "   WARNING: log not found after 120s; server may have failed to start."
fi

wait "$DCS_PID"
EXIT_CODE=$?
echo ""
echo "[DCS] Server exited with code ${EXIT_CODE}."
[ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
[ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
exit "$EXIT_CODE"
