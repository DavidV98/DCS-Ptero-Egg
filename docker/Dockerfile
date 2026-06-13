FROM ubuntu:22.04

LABEL maintainer="DavidV98"
LABEL description="DCS World Dedicated Server for Pterodactyl Panel (Wine/Linux)"

# ── Environment ──────────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    WINEARCH=win64 \
    WINEPREFIX=/home/container/.wine \
    DISPLAY=:0 \
    WINEDLLOVERRIDES="mscoree,mshtml=,winemenubuilder.exe=d" \
    WINEDEBUG=-all \
    # ── CRITICAL: UTF-8 locale ─────────────────────────────────────────────
    # Without a UTF-8 locale, Wine mangles non-ASCII characters in file paths
    # and fails to create them. DCS ships liveries with accented characters
    # (e.g. the C-101CC "Nº410" Chilean livery) that will break the updater
    # mid-download with "Can't create directory" errors, leaving the install
    # stuck in a retry loop. C.UTF-8 is built into Ubuntu and needs no
    # locale-gen, so it's the safest choice for a minimal container image.
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ── Wine HQ Staging + system dependencies ────────────────────────────────────
RUN dpkg --add-architecture i386 && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        curl \
        gnupg2 \
        software-properties-common \
        xvfb \
        xauth \
        xdotool \
        x11vnc \
        novnc \
        websockify \
        openbox \
        winbind \
        cabextract \
        tini \
        procps \
        lsof \
        zip \
        unzip \
        tzdata && \
    mkdir -pm755 /etc/apt/keyrings && \
    wget -qO /etc/apt/keyrings/winehq-archive.key \
        https://dl.winehq.org/wine-builds/winehq.key && \
    wget -qNP /etc/apt/sources.list.d/ \
        https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources && \
    apt-get update -y && \
    apt-get install -y --install-recommends winehq-staging winetricks && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ── /tmp/.X11-unix must exist before the container user starts Xvfb ──────────
# Without this, Xvfb silently fails to create its socket because only root
# can create /tmp/.X11-unix. 1777 = sticky + world-writable, same as /tmp.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# ── Pterodactyl requires 'container' user at /home/container ─────────────────
RUN useradd -m -d /home/container -s /bin/bash container

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

STOPSIGNAL SIGTERM

COPY --chown=container:container ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 10308/udp
EXPOSE 10309/udp
EXPOSE 8088/tcp
# noVNC debug console (only started when DCS_DEBUG_VNC=1) — LOCAL USE ONLY
EXPOSE 6080/tcp

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/entrypoint.sh"]
