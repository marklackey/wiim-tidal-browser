# Catalog and player adapters

The app pairs one catalog adapter with one network player adapter. TIDAL and WiiM are the built-in pair. The catalog searches for music and resolves catalog IDs. The player discovers or selects a device and sends queue and transport commands over its local interface.

A player adapter needs a documented or otherwise supported way to queue tracks from the selected catalog. General HTTP playback controls alone cannot play a track by its catalog ID. The scope is network players with HTTP, UPnP, or a Connect-style control interface. Playback happens on the device.

## Install and select an adapter

Register an adapter factory in this project’s `pyproject.toml` or in a separate Python package installed into the same environment as `wiim-tidal-browser`.

```toml
[project.entry-points."wiim_tidal.catalogs"]
example-catalog = "my_music_package.catalog:Catalog"

[project.entry-points."wiim_tidal.players"]
example-player = "my_music_package.player:Player"
```

Each factory takes a `Settings` instance. The returned object's `id` must match the entry point name. Use `settings.data_dir` for state and choose filenames unique to your adapter. The included TIDAL and WiiM adapters retain their existing session and device files.

Select a pair before starting the Python app.

```bash
WIIM_TIDAL_CATALOG=example-catalog WIIM_TIDAL_PLAYER=example-player wiim-tidal setup
```

Both variables are optional. Their defaults are `tidal` and `wiim`. The command reuses a running server only if it has the same pair. Use a Python installation for external packages. The standalone Mac ZIP ships the built-in adapters.

## Catalog adapter

Implement `CatalogAdapter` from `wiim_tidal.adapters`. Search and detail responses use JSON-ready dictionaries. Media IDs can be positive integers or opaque strings of up to 200 ASCII letters, digits, or `._~:-`. A string ID cannot be `.` or `..`.

| Method | Result |
| --- | --- |
| `search(query, types, separate_artist_matches=...)` | A dictionary with `albums`, `artistAlbums`, and `tracks` arrays. The categories are `album`, `artist`, and `track`. Return empty arrays for unrequested categories. `separate_artist_matches` requests distinct artist and album matches. |
| `album(id)` | A dictionary with `album` and `tracks`. |
| `track(id)` | One track. |
| `resolution(id, track=...)` | A dictionary with numeric `bits` and `hz`. An adapter without resolution data can raise `ValueError` with a short display message. |
| `queue_tracks(ids)` | Ordered `QueueTrack` objects. Preserve duplicates. The track ID goes to the player as a reference in the active catalog. |

An album has `id`, `name`, `artist`, `quality`, and optionally `tags`, `year`, ISO `releaseDate`, `version`, HTTPS `art`, and an HTTP or HTTPS `url`. A track has `id`, `title`, `artist`, `album`, `album_id`, `quality`, and optionally `number`, `year`, and `releaseDate`. Use quality labels such as `Hi-Res Lossless`, `Lossless`, or `Unknown`. An album opened from a track needs the track's `album_id`.

Set `login_required=False` and `connected=True` for a catalog that can be searched without sign-in. For browser sign-in, `begin_login()` returns an authorization URL and `finish_login(redirect)` validates and consumes the full redirect URL the user pastes. `start_restore()` can restore a saved session in the background and should expose its progress through `restoring` and `connected`. A catalog that uses a different interactive sign-in flow will need a corresponding Setup UI. Keep account tokens and any temporary audio URLs out of the JSON responses.

## Network player adapter

Implement `PlayerAdapter`. Set `catalogs` to the provider IDs this device can queue. The app rejects unsupported pairs at startup. A player can implement native queue behavior for each provider it declares.

| Method or property | Result |
| --- | --- |
| `selected_device` | The current device, or `None`. |
| `discover()` | A dictionary with `devices` and `selected`. Use `selected=None` if the user needs to choose. |
| `select_discovered(id)` | The selected device. Accept IDs from the adapter's discovery results. |
| `manual(host, port)` | The selected device after validating its network address. Set `manual_port=None` if the device does not support manual entry. |
| `queue(catalog_id, tracks, name)` | The count accepted by the device. The app passes ordered `QueueTrack` objects and the provider ID. |
| `control(action, value)` | Applies `previous`, `next`, `toggle`, `play`, `pause`, `volume`, or `seek`. Volume is 0–100 and seek uses seconds. |
| `now_playing()` | A dictionary with available fields such as `title`, `artist`, `album`, `albumArtURI`, `trackId`, `catalogId`, `playbackStatus`, `positionMs`, `durationMs`, and `volume`. Position and duration are in milliseconds. Use `play`, `pause`, or `stop` for playback state. Use `controlsAvailable: false` when controls are unavailable. |

A public device record contains a stable string `id`, a display `name`, and optionally a `host`. Device credentials belong in adapter-private state. Report unsupported actions or known connection failures with `PlayerError` and a user-facing message. Return a track ID only when you can associate it with a catalog, and include `catalogId` if it might differ from the configured one.

The app runs locally and guards browser mutations with its local token. Adapters run in the app process as trusted Python code. They own timeouts, network address validation, and thread safety. WiiM's local HTTP and UPnP code is in `src/wiim_tidal/wiim.py` and `src/wiim_tidal/discovery.py`. TIDAL's session, search, and track mapping are in `src/wiim_tidal/tidal.py`. The integration test in `test_app.py` exercises the same API with a different catalog and player pair.
