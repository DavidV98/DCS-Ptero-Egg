# Stage 1: The Builder Stage
# We use a lean Debian base image for stability and a minimal footprint.
FROM debian:bookworm-slim AS builder

# Set maintainer metadata and add a label for easy identification.
LABEL maintainer="DavidV98"
LABEL description="DCS World Dedicated Server Builder for Pterodactyl Panel"

# Configure multi-arch support and install core dependencies.
# This includes Wine, Winetricks, and wget for downloading files.
# xdotool is included for the potential need to automate GUI interactions if necessary.
# Install required packages
RUN             dpkg --add-architecture i386 \
                && apt update -y \
                && apt install -y --no-install-recommends \
                    curl \
                    wget \
                    gnupg2 \
                    tzdata \
                    software-properties-common \
                    libntlm0 \
                    winbind \
                    xvfb \
                    x11-utils \
                    xauth \
                    python3 \
                    libncurses5:i386 \
                    libncurses6:i386 \
                    libsdl2-2.0-0 \
                    libsdl2-2.0-0:i386

# Install rcon
RUN             cd /tmp/ \
                && curl -sSL https://github.com/gorcon/rcon-cli/releases/download/v0.10.3/rcon-0.10.3-amd64_linux.tar.gz > rcon.tar.gz \
                && tar xvf rcon.tar.gz \
                && mv rcon-0.10.3-amd64_linux/rcon /usr/local/bin/

# Install wine and with recommends
RUN             mkdir -pm755 /etc/apt/keyrings
RUN             wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
RUN             wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources
RUN             apt update
RUN             apt install --install-recommends winehq-stable cabextract wine-binfmt wine32 -y

# Set up Winetricks
RUN	            wget -q -O /usr/sbin/winetricks https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
                && chmod +x /usr/sbin/winetricks

# Set the WINE architecture and disable the graphical user interface (GUI) for a headless setup.
ENV WINEARCH="win32"
ENV WINEDLLOVERRIDES="winemenubuilder.exe=d"
ENV DISPLAY=:0.0

# Create a non-root user and set the working directory.
RUN useradd -d /home/container -m container
USER container
WORKDIR /home/container

# Download the official DCS World Dedicated Server modular installer.
# This ensures that your container is not reliant on a third-party project for the installer.
# The URL must be kept up-to-date with the latest from Eagle Dynamics.
# The installer is specifically for a dedicated server and does not include textures or sounds.[5]
ENV DCS_DOWNLOAD_URL="https://www.digitalcombatsimulator.com/en/downloads/world/server/"
RUN wget -O /home/container/DCS_World_Server_modular.exe "${DCS_DOWNLOAD_URL}"

# Stage 2: The Final Production Image
# We use a clean Debian base image again to build a minimal runtime environment.
FROM debian:bookworm-slim

# Add maintainer and a label for the final image.
LABEL maintainer="DavidV98"
LABEL description="Pterodactyl Egg for DCS World Dedicated Server for Pterodactyl Panel"

# Configure multi-arch support and install only the necessary runtime dependencies.
# We are only installing Wine, Wget, and xdotool.
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    wget \
    wine \
    wine32 \
    xdotool \
    xvfb \
    x11-utils \
    xauth \
    # Clean up the package cache again.
    && rm -rf /var/lib/apt/lists/*


    
# Create a non-root user to run the server process.
RUN useradd -m container

# Make Pterodactyl data folder
RUN mkdir -p /home/container
    
# Set the working directory for the container process.
WORKDIR /home/container

# Copy the DCS installer and the entrypoint script from the builder stage.
COPY --from=builder --chown=container:container /home/container/DCS_World_Server_modular.exe /home/container/DCS_World_Server_modular.exe
COPY --chown=container:container entrypoint.sh /home/container/entrypoint.sh

# Expose the default ports for the DCS server.
# DCS uses two contiguous ports starting from the specified port, for example, 10308 and 10309.[6]
# It also requires a separate port for its web-based remote control GUI.[6]
EXPOSE 10308/tcp 10308/udp
EXPOSE 8088/tcp

# Set the non-root user for the container.
USER container

# Ensure the entrypoint script is executable.
RUN chmod +x /home/container/entrypoint.sh

# Set the entrypoint for the container. The script will be the main process (PID 1).
CMD [ "/home/container/entrypoint.sh" ]