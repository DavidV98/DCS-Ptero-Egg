#!/bin/bash
# ============================================================
# DCS World Dedicated Server — Pterodactyl Entrypoint
#
# ARCHITECTURE: first-boot install. The Pterodactyl install phase only
# prepares directories; this entrypoint performs the full DCS download +
# install on first server start, then launches normally on every start.
#
# STRUCTURE: organised into named functions with a main() orchestrator at the
# bottom. Each function is a self-contained step, which keeps the file readable
# and makes a later extraction into separate library files a mechanical change.
#
# Proven fixes baked in: C.UTF-8 locale, win64, keyboard-driven installer
# dialogs (Alt+A/Alt+N/Down/Alt+I/Alt+F, all verified via xdotool), native
# msvcp140 override (timezone-crash fix), vc_redist, updater retry loop,
# /tmp/.X11-unix socket dir, openbox WM, optional noVNC console.
# ============================================================
set -e
cd /home/container

# ════════════════════════════════════════════════════════════
# Configuration (paths, egg variables, Wine environment)
# ════════════════════════════════════════════════════════════
init_config() {
    # ── Paths ──────────────────────────────────────────────
    WINEPREFIX="${WINEPREFIX:-/home/container/.wine}"
    DCS_INSTALL_DIR="${WINEPREFIX}/drive_c/Program Files/Eagle Dynamics/DCS World Server"
    DCS_UPDATER="${DCS_INSTALL_DIR}/bin/DCS_updater.exe"
    DCS_SERVER="${DCS_INSTALL_DIR}/bin/DCS_server.exe"
    DCS_VCREDIST="${DCS_INSTALL_DIR}/distr/vc_redist.x64.exe"
    DCS_INSTALLER_TMP="/tmp/dcs_installer.exe"

    # ── Egg variables ──────────────────────────────────────
    DCS_INSTALLER_URL="${DCS_INSTALLER_URL:-https://www.digitalcombatsimulator.com/upload/iblock/e0e/anj9iu7zs26ikw81hj18obkxmyhqx2be/DCS_World_Server_modular.exe}"
    DCS_WRITE_DIR="${DCS_WRITE_DIR:-DCS.server}"
    DCS_SERVER_NAME="${DCS_SERVER_NAME:-DCS Pterodactyl Server}"
    DCS_SERVER_PORT="${DCS_SERVER_PORT:-10308}"
    DCS_SERVER_PASSWORD="${DCS_SERVER_PASSWORD:-}"
    DCS_MAX_PLAYERS="${DCS_MAX_PLAYERS:-16}"
    DCS_WEBGUI_PORT="${DCS_WEBGUI_PORT:-8088}"
    DCS_BRANCH="${DCS_BRANCH:-}"
    DCS_MODULES="${DCS_MODULES:-}"
    DCS_MISSION="${DCS_MISSION:-default.miz}"
    DCS_USERNAME="${DCS_USERNAME:-}"
    DCS_PASSWORD="${DCS_PASSWORD:-}"
    AUTO_UPDATE="${AUTO_UPDATE:-0}"
    DCS_DEBUG_VNC="${DCS_DEBUG_VNC:-0}"
    DCS_VNC_PORT="${DCS_VNC_PORT:-6080}"

    DCS_SAVE="${WINEPREFIX}/drive_c/users/container/Saved Games/${DCS_WRITE_DIR}"
    DCS_SAVE_WIN="C:\\users\\container\\Saved Games\\${DCS_WRITE_DIR}"
    NETWORK_VAULT="${DCS_SAVE}/Config/network.vault"

    # ── Wine environment ───────────────────────────────────
    export HOME="/home/container"
    export WINEPREFIX
    export WINEARCH="${WINEARCH:-win64}"
    export WINEDEBUG="${WINEDEBUG:--all}"
    export DISPLAY=:0
    export LANG="${LANG:-C.UTF-8}"
    export LC_ALL="${LC_ALL:-C.UTF-8}"
    # Native msvcp140_atomic_wait (timezone-crash fix) + suppress Mono/Gecko/menu.
    export WINEDLLOVERRIDES="msvcp140_atomic_wait=n,b;mscoree,mshtml=;winemenubuilder.exe=d"

    # ── Process tracking + login state ─────────────────────
    DCS_PID="" ; XVFB_PID="" ; OPENBOX_PID="" ; TAIL_PID="" ; NOVNC_PID=""
    AUTO_LOGIN_ENABLED=0
    NEED_INSTALL=0
}

# ════════════════════════════════════════════════════════════
# Signal handling — graceful shutdown of DCS and helpers
# ════════════════════════════════════════════════════════════
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
    stop_helpers
    echo "[DCS] Shutdown complete."
    exit 0
}

stop_helpers() {
    [ -n "$TAIL_PID" ]    && kill "$TAIL_PID"    2>/dev/null || true
    [ -n "$NOVNC_PID" ]   && kill "$NOVNC_PID"   2>/dev/null || true
    pkill -f x11vnc 2>/dev/null || true
    [ -n "$OPENBOX_PID" ] && kill "$OPENBOX_PID" 2>/dev/null || true
    [ -n "$XVFB_PID" ]    && kill "$XVFB_PID"    2>/dev/null || true
}

# ════════════════════════════════════════════════════════════
# Display: Xvfb + openbox (+ optional noVNC console)
# ════════════════════════════════════════════════════════════
start_display() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Starting virtual display"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix 2>/dev/null || true
    Xvfb :0 -screen 0 1024x768x16 -ac +extension GLX +render -noreset &
    XVFB_PID=$!
    sleep 2
    if [ ! -S "/tmp/.X11-unix/X0" ]; then
        echo "   ERROR: Xvfb socket not found; cannot run Wine."
        exit 1
    fi
    openbox &
    OPENBOX_PID=$!
    sleep 1
    echo "   ✓ Xvfb (PID ${XVFB_PID}) + openbox (PID ${OPENBOX_PID})"
    start_vnc
}

start_vnc() {
    [ "${DCS_DEBUG_VNC}" = "1" ] || return 0
    echo "   [debug] Starting noVNC on port ${DCS_VNC_PORT} (allocate this port in the panel)"
    echo "   [debug] WARNING: no password — trusted network only"
    x11vnc -display :0 -nopw -forever -shared -quiet -bg >/dev/null 2>&1 || \
        echo "   [debug] x11vnc unavailable"
    if command -v novnc_proxy >/dev/null 2>&1; then
        novnc_proxy --vnc localhost:5900 --listen "${DCS_VNC_PORT}" >/dev/null 2>&1 &
        NOVNC_PID=$!
    elif [ -d /usr/share/novnc ]; then
        websockify --web /usr/share/novnc "${DCS_VNC_PORT}" localhost:5900 >/dev/null 2>&1 &
        NOVNC_PID=$!
    else
        echo "   [debug] noVNC web root not found"
    fi
}

# ════════════════════════════════════════════════════════════
# Wine prefix initialisation
# ════════════════════════════════════════════════════════════
init_wine_prefix() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Wine prefix"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ ! -f "${WINEPREFIX}/system.reg" ]; then
        echo "   First run — initialising Wine prefix (win64)..."
        wineboot --init
        sleep 5
        winetricks -q vcrun2019 || echo "   ⚠ winetricks vcrun2019 non-zero (continuing; vc_redist installs runtime later)"
        echo "   ✓ Wine prefix initialised"
    else
        echo "   ✓ Existing Wine prefix found"
    fi
}

# ════════════════════════════════════════════════════════════
# Decide install state (sets NEED_INSTALL)
# ════════════════════════════════════════════════════════════
determine_install_state() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Checking DCS install state"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ -f "${DCS_SERVER}" ]; then
        echo "   ✓ DCS_server.exe present — DCS is installed."
        NEED_INSTALL=0
    elif [ -f "${DCS_UPDATER}" ] || [ -d "${DCS_INSTALL_DIR}" ]; then
        echo "   ⚠ Partial/incomplete DCS install detected (DCS_server.exe missing)."
        echo "   ⚠ Cleaning the incomplete install and reinstalling from scratch."
        rm -rf "${DCS_INSTALL_DIR}"
        NEED_INSTALL=1
    else
        echo "   No DCS install found — first-boot install will run now."
        NEED_INSTALL=1
    fi
}

# ════════════════════════════════════════════════════════════
# GUI automation helpers (used by run_gui_installer)
# ════════════════════════════════════════════════════════════
# Returns window id on stdout + 0 on success; non-zero if it never appeared.
# Callers MUST check the result rather than printing success blindly.
wait_for_window() {
    local name="$1" timeout="${2:-90}" wid="" i=0
    for i in $(seq 1 "${timeout}"); do
        wid=$(xdotool search --name "${name}" 2>/dev/null | tail -1)
        if [ -n "${wid}" ]; then echo "${wid}"; return 0; fi
        sleep 1
    done
    return 1
}

# Best-effort keypress to the active setup window.
key() { xdotool key --clearmodifiers "$@" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════
# Run the Inno Setup installer GUI via keyboard automation
# ════════════════════════════════════════════════════════════
run_gui_installer() {
    echo "   Launching installer..."
    wine "${DCS_INSTALLER_TMP}" &

    # Dialog 1: Select Setup Language (English default) → OK
    echo "   [GUI 1/8] Waiting for language dialog..."
    local WID
    if WID=$(wait_for_window "Select Setup Language" 90); then
        xdotool windowfocus --sync "${WID}" 2>/dev/null
        sleep 0.5
        key Return
        echo "   ✓ Language: English"
    else
        echo "   ⚠ Language dialog not seen in 90s — automation may be off."
        echo "   ⚠ If DCS_DEBUG_VNC=1, finish the dialogs by hand in the VNC now."
    fi

    # Dialogs 2-8 share the "Setup - DCS World Server" title.
    echo "   [GUI 2/8] Waiting for setup wizard..."
    if WID=$(wait_for_window "Setup - DCS World Server" 90); then
        xdotool windowfocus --sync "${WID}" 2>/dev/null; sleep 1
        key alt+a; sleep 0.7; key alt+n; sleep 3          # licence: accept + next
        echo "   ✓ Licence accepted"
        echo "   [GUI 3/8] Destination directory..."
        key alt+n; sleep 3                                 # destination → next
        echo "   ✓ Default path accepted"
        echo "   [GUI 4/8] Selecting Compact installation..."
        key Down; sleep 0.7; key alt+n; sleep 3            # combo focused: Down=Compact; next
        echo "   ✓ Compact installation selected"
        echo "   [GUI 5/8] Start menu folder..."
        key alt+n; sleep 3                                 # start menu → next
        echo "   ✓ Start menu OK"
        echo "   [GUI 6/8] Additional tasks..."
        key alt+n; sleep 3                                 # additional tasks → next
        echo "   ✓ Additional tasks OK"
        echo "   [GUI 7/8] Starting installation..."
        key alt+i; sleep 5                                 # ready → install
        echo "   ✓ Install triggered"
        echo "   [GUI 8/8] Finishing wizard (launches updater)..."
        wait_for_window "Setup - DCS World Server" 300 >/dev/null && key alt+f  # finish
        sleep 5
        echo "   ✓ Wizard finished"
    else
        echo "   ⚠ Setup wizard window not seen — likely a desync."
        echo "   ⚠ Finish the installer dialogs by hand via VNC (DCS_DEBUG_VNC=1)."
    fi
}

# ════════════════════════════════════════════════════════════
# Wait for the updater, then loop it until DCS_server.exe exists
# ════════════════════════════════════════════════════════════
download_game_files() {
    echo ""
    echo "   Waiting for DCS_updater.exe (the download stage)..."
    local UWAIT=0 ULIMIT=900
    while [ ! -f "${DCS_UPDATER}" ] && [ "${UWAIT}" -lt "${ULIMIT}" ]; do
        sleep 5; UWAIT=$((UWAIT+5))
        [ $((UWAIT % 60)) -eq 0 ] && echo "   ... waiting for installer to finish (${UWAIT}s)"
    done
    if [ ! -f "${DCS_UPDATER}" ]; then
        echo "   ERROR: DCS_updater.exe never appeared. The installer did not complete."
        echo "   Re-run with DCS_DEBUG_VNC=1 and finish the dialogs via the VNC console."
        return 1
    fi
    echo "   ✓ DCS_updater.exe present — download running"

    echo "   Downloading game files (re-running updater until complete)..."
    ( while [ ! -f "${DCS_SERVER}" ]; do
        echo "   [heartbeat $(date -u +%H:%M:%SZ)] size: $(du -sh "${DCS_INSTALL_DIR}" 2>/dev/null | cut -f1) (downloading...)"
        sleep 30
      done ) &
    local HEARTBEAT_PID=$!

    local ATTEMPT=0 MAXA=40
    while [ ! -f "${DCS_SERVER}" ] && [ "${ATTEMPT}" -lt "${MAXA}" ]; do
        ATTEMPT=$((ATTEMPT+1))
        echo "   [updater attempt ${ATTEMPT}/${MAXA}] $(date -u +%H:%M:%SZ)"
        wine "${DCS_UPDATER}" --quiet update 2>/dev/null
        pkill -f "DCS_updater.exe" 2>/dev/null || true
        sleep 5
    done
    kill "${HEARTBEAT_PID}" 2>/dev/null || true

    if [ ! -f "${DCS_SERVER}" ]; then
        echo "   ERROR: DCS_server.exe not present after ${MAXA} updater runs."
        return 1
    fi
    rm -f "${DCS_INSTALLER_TMP}"
    echo "   ✓ DCS download complete"
}

# ════════════════════════════════════════════════════════════
# Install the DCS-bundled VC++ runtime (timezone-crash fix)
# ════════════════════════════════════════════════════════════
install_vcredist() {
    echo "   Installing VC++ runtime (msvcp140 timezone-crash fix)..."
    if [ -f "${DCS_VCREDIST}" ]; then
        wine "${DCS_VCREDIST}" /quiet /norestart 2>/dev/null
        sleep 10
        [ -f "${WINEPREFIX}/drive_c/windows/system32/msvcp140_atomic_wait.dll" ] \
            && echo "   ✓ msvcp140_atomic_wait.dll present" \
            || echo "   ⚠ msvcp140_atomic_wait.dll missing (server may crash on launch)"
    fi
}

# ════════════════════════════════════════════════════════════
# Full first-boot install (orchestrates the three steps above)
# ════════════════════════════════════════════════════════════
install_dcs() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Installing DCS World Dedicated Server (first boot)"
    echo " This takes 30-60+ minutes. Full progress shown below."
    [ "${DCS_DEBUG_VNC}" = "1" ] && \
        echo " Watch/assist via VNC: http://<server-ip>:${DCS_VNC_PORT}/vnc.html"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Source: ${DCS_INSTALLER_URL}"

    wget --progress=bar:force --show-progress -O "${DCS_INSTALLER_TMP}" "${DCS_INSTALLER_URL}" \
        || { echo "   ERROR: Installer download failed. Check DCS_INSTALLER_URL (it 404s when ED updates the build)."; exit 1; }

    # GUI + download are best-effort wrt set -e: a single keypress returning
    # non-zero must not abort. The success signal is DCS_server.exe appearing.
    set +e
    run_gui_installer
    download_game_files || { echo "   ERROR: game file download failed."; set -e; exit 1; }
    install_vcredist
    set -e
    echo "   ✓ DCS World installed."
}

# ════════════════════════════════════════════════════════════
# Optional update on an already-installed server (AUTO_UPDATE=1)
# ════════════════════════════════════════════════════════════
maybe_update() {
    [ "${NEED_INSTALL}" = "0" ] && [ "${AUTO_UPDATE}" = "1" ] || return 0
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " AUTO_UPDATE=1 — checking for updates"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ -n "${DCS_BRANCH}" ]; then
        wine "${DCS_UPDATER}" --quiet update "@${DCS_BRANCH}" 2>/dev/null || echo "   ⚠ update failed (continuing)"
    else
        wine "${DCS_UPDATER}" --quiet update 2>/dev/null || echo "   ⚠ update failed (continuing)"
    fi
    pkill -f "DCS_updater.exe" 2>/dev/null || true
    echo "   ✓ Update check complete"
}

# ════════════════════════════════════════════════════════════
# Install any terrain modules listed in DCS_MODULES
# ════════════════════════════════════════════════════════════
install_modules() {
    [ -n "${DCS_MODULES}" ] || return 0
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Terrain modules: ${DCS_MODULES}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local m
    for m in ${DCS_MODULES}; do
        echo "   → ${m}"
        wine "${DCS_UPDATER}" --quiet install "${m}" 2>/dev/null \
            && echo "     ✓ ${m}" || echo "     ⚠ ${m} failed (paid maps need an ED account)"
        pkill -f "DCS_updater.exe" 2>/dev/null || true
    done
}

# ════════════════════════════════════════════════════════════
# Seed mission + write serverSettings.lua / autoexec.cfg
# ════════════════════════════════════════════════════════════
configure_server() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Mission + configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    mkdir -p "${DCS_SAVE}/Config" "${DCS_SAVE}/Missions" "${DCS_SAVE}/Tracks" "${DCS_SAVE}/Logs" "${DCS_SAVE}/Scripts"

    local MISSION_FILE="${DCS_SAVE}/Missions/${DCS_MISSION}" SEED
    if [ ! -f "${MISSION_FILE}" ]; then
        SEED=$(find "${DCS_INSTALL_DIR}" -iname "*caucasus*.miz" 2>/dev/null | head -1)
        [ -z "${SEED}" ] && SEED=$(find "${DCS_INSTALL_DIR}" -iname "*.miz" 2>/dev/null | head -1)
        if [ -n "${SEED}" ]; then
            cp "${SEED}" "${MISSION_FILE}"
            echo "   ✓ Seeded mission: $(basename "${SEED}") → Missions/${DCS_MISSION}"
        else
            echo "   ⚠ No bundled .miz to seed; upload one and set DCS_MISSION."
        fi
    else
        echo "   ✓ Mission present: ${DCS_MISSION}"
    fi

    local SETTINGS_FILE="${DCS_SAVE}/Config/serverSettings.lua"
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
        echo "   ✓ serverSettings.lua created"
    else
        echo "   ℹ Existing serverSettings.lua preserved"
    fi

    cat > "${DCS_SAVE}/Config/autoexec.cfg" << EOF
if not net then net = {} end
options           = options or {}
options.graphics  = options.graphics or {}
options.graphics.maxfps   = 30
options.graphics.render3D = false
webgui_port = ${DCS_WEBGUI_PORT}
crash_report_mode = "silent"
EOF
    echo "   ✓ autoexec.cfg written (WebGUI ${DCS_WEBGUI_PORT})"
}

# ════════════════════════════════════════════════════════════
# Determine ED login state (sets AUTO_LOGIN_ENABLED)
# ════════════════════════════════════════════════════════════
check_login_state() {
    if [ -f "${NETWORK_VAULT}" ]; then
        echo "   ✓ network.vault present — ED login established."
        AUTO_LOGIN_ENABLED=0
    elif [ -n "${DCS_USERNAME}" ] && [ -n "${DCS_PASSWORD}" ]; then
        echo "   No network.vault — will auto-fill the DCS Login window if it appears."
        AUTO_LOGIN_ENABLED=1
    else
        echo "   ⚠ No network.vault and no credentials. Server will stop at the login"
        echo "   ⚠ screen. Set DCS_DEBUG_VNC=1 and log in once via the VNC console,"
        echo "   ⚠ or set DCS_USERNAME/DCS_PASSWORD."
        AUTO_LOGIN_ENABLED=0
    fi
}

# Background helper: fill the DCS Login window on first boot (best-effort).
auto_login() {
    [ "${AUTO_LOGIN_ENABLED}" = "1" ] || return 0
    (
        local WID="" i
        for i in $(seq 1 60); do
            WID=$(xdotool search --name "DCS Login" 2>/dev/null | tail -1)
            [ -n "${WID}" ] && break
            sleep 2
        done
        if [ -n "${WID}" ]; then
            xdotool windowactivate --sync "${WID}" 2>/dev/null; sleep 1
            xdotool type --delay 60 "${DCS_USERNAME}"; sleep 0.5
            xdotool key Tab; sleep 0.5
            xdotool type --delay 60 "${DCS_PASSWORD}"; sleep 0.5
            xdotool key Tab; sleep 0.3; xdotool key space   # save password
            xdotool key Tab; sleep 0.3; xdotool key space   # auto login
            sleep 0.5; xdotool key Return
            echo "   [login] Credentials submitted; network.vault should persist."
        fi
    ) &
}

# ════════════════════════════════════════════════════════════
# Launch the server and stream its log to stdout
# ════════════════════════════════════════════════════════════
launch_server() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Launching DCS World Dedicated Server"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Name:    ${DCS_SERVER_NAME}"
    echo "   Port:    ${DCS_SERVER_PORT}/udp    WebGUI: ${DCS_WEBGUI_PORT}/tcp"
    echo "   Mission: ${DCS_MISSION}"
    echo ""

    wine "${DCS_SERVER}" -w "${DCS_WRITE_DIR}" &
    DCS_PID=$!

    auto_login

    # DCS logs to a file, not stdout — tail it so the panel sees output and the
    # "Listening on port" done-string is detected.
    local DCS_LOG="${DCS_SAVE}/Logs/dcs.log" WAITED=0
    while [ ! -f "$DCS_LOG" ] && [ "$WAITED" -lt 180 ]; do sleep 2; WAITED=$((WAITED+2)); done
    if [ -f "$DCS_LOG" ]; then
        tail -F "$DCS_LOG" &
        TAIL_PID=$!
    else
        echo "   WARNING: dcs.log not found after 180s; server may have failed to start."
    fi

    wait "$DCS_PID"
    local EXIT_CODE=$?
    echo ""
    echo "[DCS] Server exited with code ${EXIT_CODE}."
    stop_helpers
    exit "$EXIT_CODE"
}

# ════════════════════════════════════════════════════════════
# main — orchestrator
# ════════════════════════════════════════════════════════════
main() {
    init_config
    trap cleanup SIGTERM SIGINT SIGHUP

    start_display
    init_wine_prefix
    determine_install_state

    [ "${NEED_INSTALL}" = "1" ] && install_dcs
    maybe_update
    install_modules
    configure_server
    check_login_state
    launch_server
}

main "$@"
