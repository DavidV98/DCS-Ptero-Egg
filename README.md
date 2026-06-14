# 🛩️ DCS World Dedicated Server — Pterodactyl Egg

Run a [DCS World](https://www.digitalcombatsimulator.com/) **Dedicated Server** on Linux under [Pterodactyl](https://pterodactyl.io/), powered by Wine. The egg handles the entire lifecycle automatically — download from Eagle Dynamics, install, authentication, mission setup, and launch — with no manual steps required. 🚀

> ✅ **Verified working end to end:** clean install, ~30 GB download (base + Caucasus), automated installer, ED login, mission load, and `Listening on port`.

---

## ✨ Features

- 🤖 **Fully automated install** — downloads and installs the DCS Dedicated Server on first boot, driving the GUI installer headlessly via keyboard automation. No clicking required.
- 🌍 **Caucasus included** — the base install ships with the Caucasus terrain, so the default mission runs out of the box. Add more terrains on demand.
- 🗺️ **Mission as a variable** — choose which `.miz` the server loads from a panel variable; a default mission is seeded so the server always starts.
- 🔐 **Eagle Dynamics login** — log in once (via the debug console or credentials); the token persists, so you never log in again.
- 🔄 **Optional auto-update** — keep DCS current on every start with a single toggle.
- 📊 **Live install progress** — the long download streams a heartbeat to the panel console so it never looks frozen.
- 🖥️ **Built-in debug console** — an optional browser-based VNC for watching or assisting the first-boot install.

---

## 📁 Repository layout

```
.
├── docker/
│   ├── Dockerfile        # Ubuntu 22.04 + WineHQ Staging runtime image
│   ├── entrypoint.sh     # First-boot install + every-start launch logic
│   └── install.sh        # Minimal: prepares the data directory
├── egg-dcs-world.json    # The Pterodactyl egg (import this)
├── .github/workflows/
│   └── docker-publish.yml # Builds & pushes the image to GHCR on push
├── .gitignore
└── README.md
```

---

## 🚀 Quick start

### 1️⃣ Build & publish the image

Push to `main` and the GitHub Actions workflow builds `docker/Dockerfile` and publishes it to `ghcr.io/davidv98/dcs-ptero-egg:latest`. After the first build, set the GHCR package to **Public** so Wings can pull it.

### 2️⃣ Import the egg

Import `egg-dcs-world.json` in the panel under **Admin → Nests → Import Egg**.

### 3️⃣ Create a server

- Allocate ports `10308/udp`, `10309/udp`, and `8088/tcp` (plus `6080/tcp` if you want the debug console).
- Set **8 GB+** RAM (more with extra terrains).
- Fill in `DCS_USERNAME` and `DCS_PASSWORD`, **or** plan to log in once via the debug console.
- Click **Install** — this is quick; it only prepares the data directory.

### 4️⃣ Start 🎬

On first start the server downloads and installs DCS (**30–60+ minutes**, streamed live to the console), logs in, loads the mission, and reports `Listening on port`. The panel flips to **Online**. Subsequent starts launch in seconds.

---

## ⚙️ Configuration variables

| Variable | Default | Purpose |
|---|---|---|
| `DCS_SERVER_NAME` | DCS Pterodactyl Server | Name shown in the server browser |
| `DCS_SERVER_PORT` | `10308` | Game port (UDP); DCS also uses port + 1 |
| `DCS_WEBGUI_PORT` | `8088` | WebGUI control port (TCP) |
| `DCS_SERVER_PASSWORD` | *(blank)* | Join password — blank means public |
| `DCS_MAX_PLAYERS` | `16` | Maximum concurrent players |
| `DCS_MISSION` | `default.miz` | Mission filename in the `Missions/` folder to load |
| `DCS_MODULES` | *(blank)* | Space-separated terrain modules to add |
| `DCS_BRANCH` | *(blank)* | Update branch — blank means stable |
| `AUTO_UPDATE` | `0` | `1` runs the updater before each start |
| `DCS_USERNAME` | *(blank)* | Eagle Dynamics account (first-launch login) |
| `DCS_PASSWORD` | *(blank)* | Eagle Dynamics password (first-launch login) |
| `DCS_DEBUG_VNC` | `0` | `1` starts the debug VNC console on port 6080 |
| `DCS_WRITE_DIR` | `DCS.server` | Saved Games profile name (advanced) |
| `DCS_INSTALLER_URL` | *(ED URL)* | Direct installer URL — update if ED changes it |

---

## 🔑 Eagle Dynamics login

DCS requires an ED account login on first launch before it will host. The login is stored as an encrypted `network.vault` file in the prefix and **persists across restarts**, so you only do it once. The egg detects this file to decide whether a login is needed.

**Recommended first-login flow (most reliable):**

1. Set `DCS_DEBUG_VNC=1` and start the server. 🖥️
2. Open `http://<server-ip>:6080/vnc.html`. When the **DCS Login** window appears, type your username and password **by hand**, and importantly **tick both "Save password" and "Auto login"** ✅ before clicking **Log In**.
3. Once the server reaches `Listening on port`, the encrypted `network.vault` token is written. Set `DCS_DEBUG_VNC=0` and restart — no further login needed.

> ℹ️ Setting `DCS_USERNAME` / `DCS_PASSWORD` makes the egg *attempt* to auto-fill the login window, but the auto-fill is best-effort and may not tick the checkboxes reliably. **Always verify the login via VNC on the first run** — the manual tick-the-boxes step above is the dependable path.

---

## 🗺️ Missions

The server won't host without a mission, so a Caucasus mission is seeded as `default.miz` on first install. To use your own:

1. Upload a `.miz` to the server's `Missions/` folder via the file manager. 📤
2. Set `DCS_MISSION` to that filename.
3. Restart.

Pick a mission that matches an installed terrain — Caucasus ships with the base install; add others via `DCS_MODULES`.

---

## 🌍 Terrain modules

Set `DCS_MODULES` to a space-separated list to add more maps, for example:

```
SYRIA_terrain NEVADA_terrain MARIANAISLANDS_terrain
```

Free terrains install without an account; paid terrains require the ED account in `DCS_USERNAME` / `DCS_PASSWORD` to own them.

---

## 🌐 WebGUI & remote control

DCS exposes a control interface on port `8088`, reachable through your Eagle Dynamics account at digitalcombatsimulator.com or locally.

> ⚠️ **Security:** the `8088` interface has no authentication of its own. **Never expose it to the public internet.** Eagle Dynamics' control server connects from a single IP — **restrict inbound `8088/tcp` to `54.36.51.100`** (ED's web-control server). With that whitelist in place you administer the server by logging into your account at digitalcombatsimulator.com → **Profile → your server**. The control device must be logged into the same ED account as the server.

---

## 🖥️ Debug VNC console

Set `DCS_DEBUG_VNC=1` to start a browser-based view of the DCS GUI — perfect for a one-time login or watching the first-boot install. Allocate port `6080` on the server and open:

```
http://<server-ip>:6080/vnc.html
```

> ⚠️ **Security:** there is no VNC password. Use it only on a trusted local network and never expose port `6080` publicly. Turn it off (`0`) in normal operation.

---

## 🛠️ Troubleshooting

**🟥 Reinstall does nothing / "server marked as offline" with no install log.**
The install container image can't be pulled. This egg uses the current `ghcr.io/pelican-eggs/installers:ubuntu` (the old `pterodactyl/installers` namespace no longer publishes images).

**🟧 Server stuck on "Starting" for a long time on first boot.**
That's expected — the first start downloads ~30 GB and installs DCS (30–60+ minutes). Progress streams to the console. It flips to **Online** once the server reports `Listening on port`.

**🟨 Installer fails with "Failed to get path of 64-bit Program Files directory."**
A broken Wine prefix. The entrypoint rebuilds the prefix from scratch whenever DCS isn't installed yet, so a restart resolves this automatically.

**🟦 Server stops at the login screen.**
No saved login. Set `DCS_DEBUG_VNC=1` and log in once via the browser console, or provide `DCS_USERNAME` / `DCS_PASSWORD`. After one login the token persists.

**🟪 Installer download fails (404).**
The `DCS_INSTALLER_URL` contains a version hash that changes when ED updates the build. Grab the current URL from the DCS download page and update the variable.

---

## 📋 Requirements

- 🖧 A Pterodactyl panel + Wings node (Linux)
- 💾 ~60 GB free disk for the base install (much more with extra terrains)
- 🧠 8 GB+ RAM allocated per server
- 👤 An Eagle Dynamics account

---

## 📄 License

Provided as-is. DCS World and all related assets are property of Eagle Dynamics. You are responsible for complying with the DCS EULA.
