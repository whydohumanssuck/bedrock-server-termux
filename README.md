# Termux Bedrock Server (1.21.130)

Run a **Minecraft Bedrock Dedicated Server (BDS)** for **Bedrock 1.21.130**
on an **Android phone through Termux**, or on a desktop Linux machine.

The official Linux BDS binary is **x86_64 only**. This project detects your
device automatically and, on **ARM64 Android**, installs a `proot-distro`
Debian container plus **box64** (the x86_64 emulation layer) so the official
server runs correctly. It downloads the **official** Minecraft server archive
at install time — no proprietary binaries are bundled in this repository.

> **Don't like reading?** The whole setup is one command:
> `bash <(curl -fsSL <repo-url>/install.sh)` — but copying the repo onto your
> phone with a file manager and running `./install.sh` in Termux also works.

---

## Features

- Pinned to Bedrock **1.21.130** and fails safely if the downloaded file isn't the right version.
- Automatic detection of Termux / Android / Linux and `aarch64` vs `x86_64`.
- Automatic `box64` + `proot-distro` compatibility layer on ARM64.
- One-command installer that also creates the whole BDS directory structure.
- Phone-friendly `server.properties` defaults tuned for 3–5 players.
- `start.sh` with **automatic crash/restart** handling and log rotation.
- `stop.sh` (graceful), `console.sh`, `backup.sh` (with world-save hold), `update.sh`, `status.sh`.
- Import/creation of worlds, plus support for **behavior packs** and **resource packs**.
- Instructions for **LAN** and **internet** multiplayer, and background-processing tips.

---

## Requirements (on your phone)

- **Termux** from [F-Droid](https://f-droid.org/en/packages/com.termux/) (the Play
  Store version is outdated and unmaintained). Install from F-Droid!
- A **64-bit** phone (`arm64-v8a`). Nearly all phones since ~2018 qualify.
- **~1–1.5 GB free space** for the Debian container + server + a world.
- **Storage & background restrictions disabled** for Termux (see troubleshooting).

You do **not** need root.

---

## Installation

### Step 1 — get Termux ready

```bash
termux-setup-storage      # grant storage permission when prompted
pkg update && pkg upgrade -y
pkg install -y git
```

### Step 2 — get the project onto your phone

Easiest (Termux):

```bash
git clone <HTTPS-URL-OF-THIS-REPO> mc-bedrock
cd mc-bedrock
```

Or, transfer the repo ZIP to your phone and unpack it into Termux with a file
manager (Termux USB / file manager should place it under
`~/storage/downloads/...`), then `cd` into it.

> **Where do my files live on ARM64 Termux?** The installer stages the whole
> project into the Debian container at `/root/mc-bedrock-server`. You drive
> everything from Termux (the `./*.sh` scripts bounce into the container
> automatically). To drop in a world or pack, either copy it into the
> `worlds/` / `behavior_packs/` / `resource_packs/` folders on the Termux side
> and re-run `./install.sh`, or open the container shell:
> `proot-distro login debian` then copy files to
> `/root/mc-bedrock-server/worlds/` (the container can also read
> `/sdcard/Download/...` directly).

### Step 3 — install

```bash
./install.sh
```

What the installer does, in order:

1. Detects that you are on ARM64 Termux and **installs `proot-distro`** if needed.
2. **Installs a Debian container** (`proot-distro install debian`) — this takes a
   few minutes the first time.
3. Copies the project into the container and reruns the installer **inside it**.
4. Inside the container: installs `curl`, `unzip`, `jq`, `tmux` and **`box64`**.
5. **Downloads the official Bedrock server** `bedrock-server-1.21.130.01.zip`.
6. **Verifies** the archive layout and that the binary contains version
   `1.21.130`. If the download is corrupt or the wrong version, it **aborts
   safely** with a clear message instead of installing something wrong.
7. Extracts the server, creates `worlds/`, `behavior_packs/`, `resource_packs/`,
   `logs/`, and writes a sensible `server.properties`.

When it finishes you'll see the “Next steps” summary.

> On a **desktop Linux** machine (x86_64) the same `./install.sh` works and
> skips all the Android/Termux steps. `apt` is used to install dependencies.

---

## Starting / Stopping / Console

```bash
# start the server (auto-restarts on crash)
./start.sh

# open the live console (detach with Ctrl+B then D)
./console.sh

# check if it's running
./status.sh

# stop the server gracefully
./stop.sh
```

`start.sh` runs the server with its console wired to a named pipe
(`logs/control.fifo`), writes logs to `logs/server.log`, rotates logs to keep
them small, and **automatically restarts the server on crashes** with
exponential backoff. `./stop.sh` sends the server's `stop` command through the
pipe, waits up to 45s for a clean shutdown, then force-closes if needed.

To run the server **in the foreground** (no tmux, e.g. for quick testing):

```bash
cd bedrock_server && box64 ./bedrock_server
```

(On x86_64 machines, run `./bedrock_server` directly.)

---

## Backups

```bash
./backup.sh
```

Creates a timestamped `.tar.gz` of your worlds, `server.properties`,
`allowlist.json`, `permissions.json`, and packs in `backups/`. If the server is
running it sends `save hold` so the world files are consistent. By default it
keeps the newest **7** backups (`KEEP=7 ./backup.sh` to change).

Restore a backup:

```bash
tar -xzf backups/mc-backup-YYYYMMDD-HHMMSS.tar.gz -C bedrock_server
./stop.sh && ./start.sh
```

---

## Updating

```bash
./stop.sh
./update.sh                 # uses the pinned version (reads lib/version.sh)
BDS_BUILD=1.21.130.02 ./update.sh   # or target a specific new build
./start.sh
```

`update.sh` downloads the new archive, verifies it, preserves your worlds,
config, whitelist and packs, and swaps the server in place.

To change which version the whole project targets, edit
[`lib/version.sh`](lib/version.sh#L8) (set `BDS_BUILD`) — every script reads the
pin from that one file.

---

## Worlds (import / create)

- **Let the server create one:** just start it. The world appears in
  `bedrock_server/worlds/` with the name from `level-name` in
  `server.properties` (default `Bedrock level`).
- **Import an existing Bedrock world:** copy the world folder into this
  project's `worlds/` directory, then run `./install.sh` (or just `./start.sh`,
  which imports it). When exactly one world is present, the server points
  `level-name` at it automatically. See [`worlds/.README.txt`](worlds/.README.txt).
- **Create with a seed:** set `level-name` and `level-seed` in
  `server.properties`, delete that world folder if it exists, and start.

---

## Behavior & Resource Packs

Put each pack (a folder containing a `manifest.json`) into:

- `behavior_packs/` and/or
- `resource_packs/`

They are copied into the server's `behavior_packs/` / `resource_packs/`
directories at install and at every start. For advanced pack ordering or
`world_packs.json` tweaking, edit the copies directly inside
`bedrock_server/`. Details in [`behavior_packs/.README.txt`](behavior_packs/.README.txt)
and [`resource_packs/.README.txt`](resource_packs/.README.txt).

---

## Multiplayer

### LAN (same Wi-Fi)

1. Start the server (`./start.sh`).
2. On each phone/device, open **Minecraft** → **Play** → **Friends/LAN** tab.
   Your server should appear automatically (Bedrock uses UDP port **19132** for
   discovery). If it doesn't, tap **Add Server** and enter your phone's local
   IP as the address:
   ```bash
   # find your phone's LAN IP in Termux:
   ifconfig | grep -A1 wlan0 | grep 'inet '
   # or:  ip -4 addr show | grep inet
   ```
3. Everyone must be on the **same Wi-Fi**. Some routers block client-to-client
   traffic (“AP/Client isolation”) — if joining fails, that's the culprit.

### Internet (play from anywhere)

You need the phone's IP reachable from the internet. The standard options:

- **Port forwarding (recommended):** in your router admin, forward **UDP 19132**
  (and optionally UDP 19133 for IPv6) to your phone's LAN IP, and set a static
  LAN IP / DHCP reservation for the phone. Then players add your **public IP**
  (find it with `curl ifconfig.me` or at myip.com) as a server address.
- **NAT / UPnP:** if your router auto-opens ports, the server's
  `server-port` based setup usually works without manual config.
- **VPN/host + options** (e.g. Tailscale, ZeroTier) — simpler but players must
  install the same VPN.

For internet play keep `online-mode=true` (Xbox/Microsoft authentication) so
only players with a Microsoft account can join. Use the **allowlist**
(`white-list=true` + `allowlist.json`) to limit who can join:

```json
// bedrock_server/allowlist.json
[
  {
    "ignoresPlayerLimit": false,
    "name": "YourGamertag",
    "xuid": "2535461234567890"
  }
]
```

> **Connection troubleshooting:** Bedrock uses **UDP**, not TCP. A firewall or
> carrier/CGNAT that blocks inbound UDP will stop players joining from the
> internet even when everything else looks right.

---

## Performance & battery (phone, 3–5 players)

The template `server.properties` is already conservative:

- `max-players=5`
- `view-distance=6` and `tick-distance=4` (lower = less CPU)
- `max-threads=0` (auto; set e.g. `4` if your phone runs hot)

Also:
- Keep the phone plugged in or on battery saver while hosting.
- Set a screen-timeout “stay awake” / “Caffeine” and disable aggressive battery
  optimisation for Termux (see below).
- On very hot devices, cap `max-threads` and lower `view-distance` to `4`.

---

## Running in the background on Android

Termux processes get killed when the screen locks or the app is swiped away,
unless you:

1. **Disable battery optimisation** for Termux:
   `Settings → Apps → Termux → Battery → Unrestricted`.
2. **Lock Termux in the task switcher** (hold the app card → “Lock”).
3. Keep the screen on while hosting (`./start.sh` prints a note).
4. Optionally run the server inside **tmux** (already the default) so toggling
   windows doesn't kill it.

To make the server survive reboots you'd add an init/Tasker script that runs
`proot-distro login debian -- bash -lc 'cd /root/mc-bedrock-server && ./start.sh'`.

---

## Directory layout

```
project/
├── install.sh            # one-shot installer
├── start.sh              # start + crash/restart supervisor
├── stop.sh               # graceful stop
├── backup.sh             # world backups
├── update.sh             # update the server, preserve data
├── status.sh             # running? + health
├── console.sh       # attach to the server console
├── lib/
│   ├── common.sh         # shared helpers
│   └── version.sh        # ✏️ the version pin lives here
├── config/
│   ├── server.properties.template
│   ├── allowlist.json
│   └── permissions.json
├── worlds/               # drop imports here (.README.txt explains)
├── behavior_packs/       # drop packs here
├── resource_packs/       # drop packs here
├── data/                 # downloaded *.zip archives (gitignored)
├── logs/                 # server.log (gitignored)
├── backups/              # backups/*.tar.gz (gitignored)
└── bedrock_server/       # ⚠️ created at install time by download (gitignored)
```

---

## Troubleshooting

**`install.sh` says "container 'debian' already exists" (or stops at the
Debian container step after a partial run).**
- The installer now detects an existing container and continues. Just run
  `./install.sh` again.
- Still stuck? Fix the container state and retry:
  `proot-distro reset debian && ./install.sh`

**`install.sh` fails to download the server.**
- The official CDN (`minecraft.azureedge.net`) is sometimes unreachable on
  phones with strict DNS. The installer tries several official mirrors and the
  current download page. Check with `curl -v https://minecraft.azureedge.net/`.
- You can manually download `bedrock-server-1.21.130.01.zip` from
  [Minecraft's official server download page](https://www.minecraft.net/en-us/download/server/bedrock),
  drop it in `data/`, and run `./install.sh --no-download`.

**`install.sh` says the downloaded file failed the version/safety check.**
- Delete the bad archive and redownload: `rm -f data/bedrock-server-*.zip && ./install.sh --force`.
- Ensure you fetched the **official** file (see the URL above), not a third-party
  repack.

**The server won't start / immediately crashes.**
- Check `logs/server.log`.
- On ARM64, confirm `box64` is installed: `command -v box64`. Inside the Debian
  container run `apt-get install -y box64` if the installer couldn't.
- Confirm required libs exist: `apt-get install -y libcurl4 libstdc++6`.
- If you changed `server.properties`, check for typos (the server is picky).

**I'm on a Play-Store Termux / `pkg install` fails.**
- Uninstall it and install Termux from **F-Droid**. Play Store Termux is stale.

**Players on the same Wi-Fi can't see the server (LAN).**
- Confirm they're on the same network; try “Add Server” with your phone's LAN IP.
- Check your router's **AP/client isolation** setting and disable it.

**Internet players can't join.**
- Confirm UDP 19132 is forwarded/NAT'd to the phone.
- Confirm you're not behind **CGNAT** (your public IP should not be in
  `100.64.0.0/10`). If you are, use a VPN like Tailscale instead.
- Keep `online-mode=true`.

**Termux keeps getting killed in the background.**
- Enable “Unrestricted” battery for Termux and lock the app in the switcher
  (see *Running in the background*).

**How do I run inside the container manually?**
```bash
proot-distro login debian
cd /root/mc-bedrock-server
./start.sh
```

---

## How the version check / “fail safely” works

- `lib/version.sh` holds the pinned `BDS_BUILD=1.21.130.01` and
  `BDS_GAME_VERSION=1.21.130`.
- `install.sh` only downloads that exact filename from official sources.
- After download it checks the archive contains `bedrock_server` and
  `server.properties`, and (best-effort, without executing x86_64 code on ARM)
  looks for the `1.21.130` version string inside the binary.
- If the archive is missing/corrupt/not the right version, the installer
  **aborts with a clear message** and tells you to redownload — it will never
  silently install the wrong server.
- `update.sh` applies the same checks when changing versions.

---

## Security notes

- Nothing in this repo contains Minecraft/BDS proprietary binaries; the server
  is downloaded from official sources at install time.
- Keep `online-mode=true` and, on public servers, enable the allowlist.
- Disable `allow-cheats` unless you trust everyone.

---

## License

This project is just shell scripts (MIT, see `LICENSE`). It is not affiliated
with or endorsed by Mojang/Microsoft. “Minecraft” and “Bedrock” are trademarks
of their respective owners. Downloading and running the Bedrock server is
subject to Minecraft's EULA and the server's own license.
