#!/bin/bash

# Ensure script uses Unix-style line endings to prevent 'command not found' errors.[9]
# Pterodactyl's installer can handle this, but it's good practice for local testing.
# dos2unix /home/container/entrypoint.sh

# Define key variables for the DCS installation and configuration.
# The Pterodactyl panel will pass these values as environment variables.
INSTALL_DIR="/home/container/DCS_World"
WINE_PREFIX_DIR="/home/container/.wine"
INSTALLER_PATH="/home/container/DCS_World_Server_modular.exe"
UPDATER_EXE="${INSTALL_DIR}/bin/DCS_Updater.exe"
SERVER_EXE="${INSTALL_DIR}/bin/DCS_server.exe"

# Set Wine environment variables.
export WINEPREFIX="${WINE_PREFIX_DIR}"
export WINEARCH="win64"
export WINEDLLOVERRIDES="winemenubuilder.exe=d"
# Use a virtual display for the GUI installer.
export DISPLAY=:0.0

# Function to perform the initial DCS server installation.
install_dcs_server() {
    echo "DCS server not found. Starting installation process..."
    
    # Create a Wine prefix.
    wineboot -u
    
    # Run the DCS dedicated server modular installer.
    # The installer is a Windows GUI application. Headless automation is complex,
    # so we will run it in an Xvfb virtual display for a "headless" install.
    xvfb-run -a wine "${INSTALLER_PATH}" --server
    
    # After initial install, run the updater to get all files.
    update_dcs_server
    
    echo "DCS server installation completed."
}

# Function to update the DCS server and install modules.
update_dcs_server() {
    echo "Checking for updates to DCS World..."
    
    # The Pterodactyl variable `DCS_BRANCH` controls this.
    if]; then
        echo "Updating to branch: ${DCS_BRANCH}"
        xvfb-run -a wine "${UPDATER_EXE}" update "@${DCS_BRANCH}"
    else
        echo "No specific branch defined. Updating to the latest stable release."
        xvfb-run -a wine "${UPDATER_EXE}" update
    fi
    
    # Repair the installation to ensure all files are correct.
    echo "Running repair to ensure file integrity..."
    xvfb-run -a wine "${UPDATER_EXE}" repair
    
    # Install modules specified by the `DCS_MODULES` Pterodactyl variable.
    if]; then
        echo "Installing specified modules: ${DCS_MODULES}"
        
        for module in ${DCS_MODULES}; do
            echo "Installing module: ${module}"
            xvfb-run -a wine "${UPDATER_EXE}" install "${module}"
        done
        
        echo "Module installation process completed."
    fi
}

# Function to dynamically generate configuration files from Pterodactyl variables.
generate_config_files() {
    echo "Generating server configuration files..."
    
    # Define a path for the user's saved games, which is where config files are stored.
    # The -w flag in the startup command points the server to this directory.[10]
    SAVED_GAMES_PATH="/home/container/.wine/drive_c/users/container/Saved Games/DCS.server/Config"
    mkdir -p "${SAVED_GAMES_PATH}"

    # Create autoexec.cfg with headless-optimized settings.[11]
    cat > "${SAVED_GAMES_PATH}/autoexec.cfg" <<EOL
if not net then net = {} end
-- We don't need high FPS in a headless server.
options.graphics.maxfps = 30
-- We do not want the graphics engine to render anything.
options.graphics.render3D = false
-- Don't need high quality screenshots.
options.graphics.ScreenshotQuality = 0
-- Capture crash report logs, but do not block the process from closing.
crash_report_mode = "silent"
-- Set the web GUI port from the Pterodactyl variable.
webgui_port = ${WEBGUI_PORT}
-- Other autoexec settings from Pterodactyl variables can be added here.
EOL

    echo "autoexec.cfg generated."

    # Create serverSettings.lua with the name and password from Pterodactyl variables.[6]
    cat > "${SAVED_GAMES_PATH}/serverSettings.lua" <<EOL
options = {
    name = "${SERVER_NAME}",
    password = "${SERVER_PASSWORD}",
    port = ${SERVER_PORT},
}
EOL

    echo "serverSettings.lua generated."
}

# --- Main Logic ---

# Set PUID and PGID for the container process.
# This ensures file ownership is correct on the host machine.[12]
echo "Setting container PUID and PGID..."
export PUID=${SERVER_PUID}
export PGID=${SERVER_PGID}

# Check if the DCS server is already installed.
if; then
    install_dcs_server
else
    echo "DCS server already installed. Skipping installation."
    # The server is already installed, so we run the update process.
    update_dcs_server
fi

# Generate configuration files before launching the server.
generate_config_files

# Finally, launch the server using the Pterodactyl startup command.
echo "Environment prepared. Executing Pterodactyl's startup command..."
# The `exec` command replaces the current shell process with the server process.
exec "$@"