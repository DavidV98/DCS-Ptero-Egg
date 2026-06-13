# DCS World Dedicated Server — Pterodactyl Egg

Run a [DCS World](https://www.digitalcombatsimulator.com/) Dedicated Server on Linux under [Pterodactyl](https://pterodactyl.io/), using Wine. The egg handles the full lifecycle automatically: download from Eagle Dynamics, silent install, authentication, mission setup, and launch.

> **Status:** Verified working end to end — install, ~31 GB download, ED login, mission load, and `Listening on port 10308`. See [Acknowledgements](#acknowledgements) for the bring-up notes.

---

## Features

- **Fully automated install** — downloads and installs the DCS Dedicated Server with no manual steps, driving the GUI installer headlessly via `xdotool`.
- **Compact base install** — installs the engine + Caucasus, then adds terrain modules on demand (keeps the base download small instead of 450 GB+).
- **Terrain-linked mission variable** — pick which `.miz` the server loads from a panel variable; a default mission is seeded so the server always starts.
- **Automatic Eagle Dynamics login** — credentials supplied as panel variables are entered on first launch; the token persists afterward.
- **Auto-update on start** (optional) — keep DCS current via the bundled updater.
- **Live install progress** — the long download streams a heartbeat + updater log to the panel console so it never looks hung.
- **Built-in debug VNC** (optional) — a browser-based console for troubleshooting, bound for local use only.

---

## Repository layout

```
.
├── docker/
│   ├── Dockerfile        # Ubuntu 22.04 + WineHQ Staging runtime image
│   ├── entrypoint.sh     # Runs every start: prefix, login, mission, launch
│   └── install.sh        # Runs once: Wine setup, DCS download/install
├── egg-dcs-world.json    # The Pterodactyl egg (import this)
├── validate-egg.py       # Pre-import sanity checker (avoids 500 errors)
├── .github/workflows/
│   └── docker-publish.yml # Builds & pushes the image to GHCR on push
├── .gitignore
└── README.md
```

---

## Quick start

### 1. Build & publish the image

Pushing to `main` triggers the GitHub Actions workflow, which builds `docker/Dockerfile` and publishes to `ghcr.io/davidv98/dcs-ptero-egg:latest`. After the first build, set the GHCR package visibility to **Public** so Wings can pull it without credentials.

### 2. Validate and import the egg

```bash
python3 validate-egg.py egg-dcs-world.json
```

If it reports `PASS`, import `egg-dcs-world.json` in the panel under **Admin → Nests → Import Egg**.

### 3. Create a server

- Use the DCS egg, allocate ports `10308/udp`, `10309/udp`, and `8088/tcp`.
- Set at least **8 GB** RAM (more with extra terrains).
- Fill in `DCS_USERNAME` and `DCS_PASSWORD` (your Eagle Dynamics account).
- Click **Install**. The first install downloads several GB and takes 30–60+ minutes; progress streams to the console.

### 4. Start

On first start the server logs in with your ED credentials, loads the seeded mission, and reports `Listening on port 10308`. The panel flips to **Online**.

---

## Configuration variables

| Variable | Default | Purpose |
|---|---|---|
| `DCS_SERVER_NAME` | DCS Pterodactyl Server | Name in the server browser |
| `DCS_SERVER_PORT` | 10308 | Game port (UDP); DCS also uses port+1 |
| `DCS_WEBGUI_PORT` | 8088 | WebGUI control port (TCP) |
| `DCS_SERVER_PASSWORD` | *(blank)* | Join password (blank = public) |
| `DCS_MAX_PLAYERS` | 16 | Max concurrent players |
| `DCS_MISSION` | default.miz | Mission filename in the `Missions/` folder to load |
| `DCS_MODULES` | *(blank)* | Space-separated terrain modules to install |
| `DCS_BRANCH` | *(blank)* | Update branch (blank = stable) |
| `AUTO_UPDATE` | 0 | `1` = run the updater before each start |
| `DCS_USERNAME` | *(blank)* | Eagle Dynamics account (first-launch login) |
| `DCS_PASSWORD` | *(blank)* | Eagle Dynamics password (first-launch login) |
| `DCS_DEBUG_VNC` | 0 | `1` = start the debug VNC console on port 6080 |
| `DCS_WRITE_DIR` | DCS.server | Saved Games profile name (advanced) |
| `DCS_INSTALLER_URL` | *(ED URL)* | Direct installer URL (update if ED changes it) |

---

## Eagle Dynamics login

DCS requires an ED account login on first launch before it will host. Verified behaviour: DCS stores this login as an **encrypted `network.vault`** file in `<Saved Games>/DCS.server/Config/`. It's created on first successful login and **persists across restarts** because the prefix lives on the server's data volume. So you only log in once. The egg detects this file to decide whether a login is needed.

**Recommended first-login flow:**

1. Set `DCS_DEBUG_VNC=1` and start the server.
2. Open `http://<wings-host-ip>:6080/vnc.html` and log into the DCS Login window when it appears (tick Save Password + Auto Login).
3. Once the server reaches `Listening on port`, the token is cached. Set `DCS_DEBUG_VNC=0` and restart — no further login needed.

Setting `DCS_USERNAME`/`DCS_PASSWORD` enables a best-effort automatic fill of that login window via `xdotool`, but since the token format is opaque and unverified, the VNC path above is the reliable fallback if the auto-fill misses.

## Missions

The server will not start hosting without a mission, so a bundled Caucasus mission is seeded as `default.miz` on first install. To use your own:

1. Upload a `.miz` to the server's `Missions/` folder via the panel file manager.
2. Set `DCS_MISSION` to that filename.
3. Restart.

Pick a mission that matches an installed terrain (Caucasus ships with the base install; add others via `DCS_MODULES`).

---

## Terrain modules

Set `DCS_MODULES` to a space-separated list, e.g.:

```
MARIANAISLANDS_terrain SYRIA_terrain NEVADA_terrain
```

Free terrains install without an account. Paid terrains require the ED account set in `DCS_USERNAME`/`DCS_PASSWORD` to own them.

---

## WebGUI and remote control

DCS exposes a control interface on port 8088. It is designed to be reached either through your Eagle Dynamics account at digitalcombatsimulator.com (their servers connect to yours) or locally.

**Security:** the 8088 interface has no authentication of its own. **Do not expose it to the public internet.** Allocate it in the panel for local/tunnelled use, or restrict your firewall to Eagle Dynamics' control IP.

---

## Debug VNC console

Set `DCS_DEBUG_VNC=1` to start a browser-based view of the DCS GUI — useful for a one-time manual login or watching a mission load. It binds to port 6080 on the Wings host:

```
http://<your-wings-host-ip>:6080/vnc.html
```

**Security:** there is no VNC password. Use only on a trusted local network and never forward port 6080 publicly. Turn it off (`0`) in normal operation.

---

## Troubleshooting

**Egg import returns HTTP 500.** Run `python3 validate-egg.py egg-dcs-world.json`. The usual cause is `"features": null` (must be `[]`) or a `config` sub-field that isn't a JSON-encoded string.

**Reinstall does nothing / "server marked as offline" with no install log.** The install container image can't be pulled. The old `ghcr.io/pterodactyl/installers:ubuntu` namespace no longer publishes images (`manifest unknown`); this egg uses the current `ghcr.io/pelican-eggs/installers:ubuntu`. The validator flags the dead namespace if it creeps back in.

**Server stuck on "Starting".** It reached the DCS login screen but couldn't authenticate. Confirm `DCS_USERNAME`/`DCS_PASSWORD`, or set `DCS_DEBUG_VNC=1` and log in once manually.

**Install times out / updater loops.** The updater occasionally exits mid-download and is re-run automatically (up to 40 attempts). Each pass resumes. A correct UTF-8 locale (`C.UTF-8`, baked in) is required — older setups failed on liveries with accented filenames.

**Crash on `__std_tzdb_get_sys_info`.** Fixed: the install step adds the DCS-bundled `vc_redist.x64.exe`, and the launch forces the native `msvcp140_atomic_wait` DLL.

---

## Requirements

- A Pterodactyl panel + Wings node (Linux)
- ~60 GB free disk for the base install (much more with terrains)
- 8 GB+ RAM allocated per server
- An Eagle Dynamics account

---

## Acknowledgements

Built through iterative testing on a live Wine/Pterodactyl stack. Thanks to the broader DCS-on-Linux community whose notes on Wine quirks (UTF-8 paths, the VC++ runtime crash) informed the fixes baked into these scripts.

## License

Provided as-is. DCS World and all related assets are property of Eagle Dynamics. You are responsible for complying with the DCS EULA.
