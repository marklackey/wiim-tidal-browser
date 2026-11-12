# WiiM TIDAL

Search and compare TIDAL releases in your browser and play albums or tracks on a WiiM using its native TIDAL player. This is an independent project for personal use. The MVP was built for macOS and the WiiM Mini. You'll need a TIDAL account with playback access and a WiiM signed in to TIDAL.

## Install on a Mac

1. Download the macOS ZIP for your Mac's processor from the release assets and unzip it.
2. Drag **WiiM TIDAL.app** into **Applications**. Double-click it to open your default browser and start the server in the background.
3. From the WiiM TIDAL menu bar icon, choose **Local Network Access**, then **Request Access** and choose **Allow** if macOS asks.
4. In the browser’s **Setup**, choose **Connect TIDAL**, open the sign-in link, then paste the full URL from TIDAL's final redirect page. Click **Finish login**.
5. Click **Discover WiiM** and select your device. The Mac and WiiM must be on the same local network. If discovery fails, enter your WiiM's IPv4 address under **Setup → Enter address manually**.

The app includes Python. The native app runs the browser server on the first free port from 8765 through 8774. You can close the browser and the server will keep running. Use **Open in Browser** in the menu bar or double-click the app again to reopen the page. Choose **Quit WiiM TIDAL** in the menu bar or **Setup → Stop server** in the browser to stop it. Locking the screen leaves it running. If the Mac sleeps, the server is unavailable until wake. The browser refreshes playback when it becomes visible again. After restarting the Mac or logging out, open WiiM TIDAL again. Your saved login and device selection are retained. This build is ad hoc signed and has no Apple notarization. macOS may require you to approve a downloaded copy under **System Settings → Privacy & Security**.

## Install with Python

With Python 3.10+ and pipx installed, install the release wheel or install from the source checkout:

```bash
pipx install ./wiim_tidal_browser-0.1.7-py3-none-any.whl
# Or, from the source checkout:
pipx install .
wiim-tidal setup
```

Run `wiim-tidal` on subsequent launches. `wiim-tidal serve` runs in the foreground. The launcher selects a nearby port if 8765 is occupied. Use `--port 8766` to choose a specific port.

## How it works

- Select Albums, Tracks, Artists, or any combination before searching TIDAL. Open a match category, then a quality section and artist. Filter releases and look up track or first-track resolution estimates. These estimates reflect TIDAL catalog stream metadata. WiiM selects playback quality separately.
- Playing an album or track replaces the WiiM's current queue after a short countdown. Playback controls and recents are available in the browser.
- **Discover WiiM** can find a previously selected device at a new address. You can also set `WIIM_HOST` to a private IPv4 address and optionally set `WIIM_UPNP_PORT`.
- The server listens only on `127.0.0.1`. Your TIDAL session and WiiM selection are saved under `~/Library/Application Support/WiiM TIDAL`. Keep the session file private. Browser recents are stored by the browser.
- WiiM playback uses an undocumented UPnP service. TIDAL access uses the community [tidalapi](https://github.com/python-tidal/tidalapi) package. Firmware or API changes can affect compatibility.

If discovery fails, check **System Settings → Privacy & Security → Local Network** for WiiM TIDAL and check that the devices can communicate on the same network. Find your WiiM address in the WiiM Home app if you need manual setup. For the Python command’s server log, see `~/Library/Application Support/WiiM TIDAL/server.log`.

## Add a catalog or network player

TIDAL and WiiM are the default adapters. You can install a different catalog or network player adapter in the Python environment and select a compatible pair. See the [adapter guide](docs/adapters.md).

## Test on another computer

GitHub Actions builds and installs the wheel on fresh macOS and Ubuntu runners, then starts the installed app and checks that the browser page loads. For a test with real hardware, use another Mac or a Linux VM that can reach the WiiM on your local network. Use bridged networking in the VM if available so it can receive local discovery replies.

On either test machine, install Python 3.10+ and pipx, then run:

```bash
git clone https://github.com/marklackey/wiim-tidal-browser.git
cd wiim-tidal-browser
pipx install .
wiim-tidal setup
```

Sign in to TIDAL, discover the WiiM, and try searching, starting a track, and pausing it. If discovery fails in the VM, enter the WiiM’s IPv4 address in Setup to check whether direct playback control works. For the native Mac app, build the ZIP from the same checkout and try it on a second Apple silicon Mac, including the Local Network permission prompt.

## Develop and build

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e . build pyinstaller
python -m unittest
node tests/player.cjs
node tests/results.cjs
python -m build
scripts/build-macos.sh
```

Build the macOS ZIP on the architecture you plan to support. The build uses Xcode Command Line Tools for Swift. Artifacts appear in `dist/`. Set `MACOS_SIGN_IDENTITY` to use a Developer ID Application certificate for a distribution build. Apple recommends an Apple-issued signing identity so [macOS can reliably track local network permission](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). The code is split into the local web API, TIDAL authentication and catalog, WiiM transport and discovery, and browser assets. No Node build step is needed.

For existing source users, run `python login.py` once from the installed checkout to copy the legacy session and device settings into the per-user directory without replacing existing settings.
