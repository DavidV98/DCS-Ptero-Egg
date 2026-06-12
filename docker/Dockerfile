FROM ubuntu:22.04

LABEL maintainer="DavidV98"
LABEL description="DCS World Dedicated Server for Pterodactyl Panel (Wine/Linux)"

# ── Environment ──────────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    # CRITICAL: DCS World Server is a 64-bit Windows application.
    # win32 will cause the installer and server to fail silently.
    WINEARCH=win64 \
    WINEPREFIX=/home/container/.wine \
    DISPLAY=:0 \
    # Suppress Mono/Gecko install prompts (DCS doesn't need them).
    WINEDLLOVERRIDES="mscoree,mshtml=,winemenubuilder.exe=d" \
    # Suppress Wine debug spam. Remove or set to "" to troubleshoot crashes.
    WINEDEBUG=-all

# ── Wine HQ Staging + system dependencies ────────────────────────────────────
# We use WineHQ Staging from winehq.org, NOT the ancient wine package from
# Ubuntu's default repos (which is Wine 6.x and has known DCS compatibility issues).
RUN dpkg --add-architecture i386 && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        curl \
        gnupg2 \
        software-properties-common \
        # Virtual framebuffer — Wine needs a display even for headless servers.
        xvfb \
        xauth \
        # Required by Wine's NTLM auth support.
        winbind \
        # Used by winetricks to install cab-packaged Windows runtimes.
        cabextract \
        # PID 1 process manager: reaps Wine child processes, forwards signals.
        tini \
        procps \
        lsof \
        zip \
        unzip \
        tzdata && \
    # ── Add WineHQ Staging repository (Ubuntu 22.04 / Jammy) ─────────────────
    mkdir -pm755 /etc/apt/keyrings && \
    wget -qO /etc/apt/keyrings/winehq-archive.key \
        https://dl.winehq.org/wine-builds/winehq.key && \
    wget -qNP /etc/apt/sources.list.d/ \
        https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources && \
    apt-get update -y && \
    apt-get install -y --install-recommends winehq-staging winetricks && \
    # ── Cleanup ───────────────────────────────────────────────────────────────
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ── Pterodactyl requires a 'container' user with home at /home/container ─────
# Wings mounts the server data volume at /home/container.
# Do NOT copy game files here — the volume mount will hide them at runtime.
RUN useradd -m -d /home/container -s /bin/bash container

# Create the X11 socket directory with sticky-bit permissions.
# Xvfb can't create it at runtime because the container user isn't root.
# 1777 = world-writable + sticky bit, same as /tmp itself.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

# Send SIGTERM so DCS and Wine can shut down gracefully before SIGKILL.
STOPSIGNAL SIGTERM

# Copy entrypoint into the image (outside /home/container — safe from volume mount).
COPY --chown=container:container ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Port reference (configure allocation in Pterodactyl panel) ────────────────
# DCS multiplayer:  10308/udp  (and 10309/udp if using consecutive ports)
# DCS WebGUI:       8088/tcp
# Note: EXPOSE is documentation only — actual port binding is done by Pterodactyl/Wings.
EXPOSE 10308/udp
EXPOSE 10309/udp
EXPOSE 8088/tcp

# ── tini as PID 1 ensures Wine subprocesses are properly reaped ──────────────
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/entrypoint.sh"]
