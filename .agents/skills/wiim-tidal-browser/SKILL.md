---
name: wiim-tidal-browser
description: Maintain or troubleshoot the WiiM TIDAL Browser repository. Use for its TIDAL catalog and login, WiiM discovery and native playback, browser UI, adapter extensions, and Python or macOS packaging.
---

# WiiM TIDAL Browser

Work from the repository root. The app uses Flask and Waitress with a Jinja template and vanilla JavaScript. It browses the catalog locally and hands track IDs to the WiiM, which resolves and plays audio using its own TIDAL login. There is no Node build step.

## Application code in `src/wiim_tidal/`

- `web.py` owns the local API. `create_app(settings, ..., catalog=..., player=...)` supports injected adapters. Browser POSTs go through `api()` in `static/app.js`, which supplies a JSON object and `X-Local-Token` from the page. Preserve loopback binding and host/origin checks across both launchers. New player setup callers use `/api/player/*`. Existing `/api/wiim/*` aliases and legacy health fields still support older clients.
- `tidal.py` owns PKCE, session restore, search, resolution and queue metadata. `catalog.py` maps TIDAL models to API records. The browser login requires the full final redirect URL and the same pending PKCE session. `config.py` owns per-user state and private atomic JSON writes. Use an isolated `WIIM_TIDAL_DATA_DIR` for disposable runs and clear any `TIDAL_SESSION_FILE` override. Keep saved tokens and pasted redirect URLs out of output and distribution artifacts.
- `wiim.py` sends `CreateQueue` to the UPnP PlayQueue service with ordered TIDAL IDs, empty URL fields and escaped DIDL-Lite metadata. `/api/play` resolves all metadata before replacing the queue. Preserve duplicate track IDs and caller order. Transport and status use the WiiM HTTPS `httpapi.asp` endpoint with its self-signed certificate. Status falls back from `getPlayerStatusEx` to `getPlayerStatus` and can provide controls without track metadata. Seek commands use seconds and status positions use milliseconds.
- `discovery.py` uses SSDP and accepts description and control URLs only on the responding local device. `wiim.py` remembers the discovered UDN so rediscovery can repair a changed IP address. For setup failures, distinguish macOS Local Network permission, SSDP visibility and direct access via the private IPv4 manual option. `WIIM_UPNP_PORT` controls the UPnP queue port when used with `WIIM_HOST`. Transport uses standard HTTPS independently.
- `templates/index.html`, `static/app.js` and `static/styles.css` implement the browser UI. Search returns `albums`, `artistAlbums` and `tracks`, with explicit `types` opting into separate artist matches. Album resolution is a first-track catalog estimate. Current-track resolution comes from the track's catalog stream metadata, while device-reported bitrate comes from `/api/now`. Keep these sources distinct in the UI. Playback has a cancellable queue replacement countdown and records `localStorage` recents after success. Player refreshes are tied to the selected device revision so a slow response from a previous selection cannot overwrite the current display.

## Adapter changes

Read `docs/adapters.md` and `src/wiim_tidal/adapters.py` for provider and player contracts. Catalog media IDs can be opaque strings or integers, while the built-in TIDAL adapter requires positive numeric IDs. Players declare which catalogs they can queue. The Python launcher uses `/api/identity` to reuse a server only when the selected pair matches. External entry points belong in the Python environment. The standalone Mac build ships the built-in adapters.

## Verify the affected path

- For backend changes, run `python -m unittest` in a Python 3.10+ environment with the project installed via `python -m pip install -e .`. `test_app.py` exercises Flask routes with temporary settings, mocked TIDAL and WiiM calls, and an alternate adapter pair. For an interactive local run, use `wiim-tidal serve --port <free-port>` to select the exact port and keep output in the terminal.
- For browser behavior, run `node tests/player.cjs` and `node tests/results.cjs`. They exercise the existing script using a mocked DOM and API. For Python packaging changes, follow `.github/workflows/checks.yml` and run `python tests/smoke_installed.py` with the built wheel installed and its `wiim-tidal` command on `PATH`.
- For native launcher, Local Network permission or release ZIP work, read [macOS packaging](references/macos-packaging.md). To verify actual playback, use a Mac and WiiM on the same LAN, confirm TIDAL sign-in in both Setup and WiiM Home, and use a short queue the user is ready to replace for the play/pause check.
