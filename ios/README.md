# WiiM TIDAL for iPhone

Native SwiftUI browsing and WiiM control for iOS 17 or later. The app uses the same community `tidalapi` package and Python catalog adapter as the desktop app. Python runs inside the app for catalog access. The WiiM plays the audio using its own TIDAL account.

## Run on an iPhone

1. From the repository root, run `bash ios/prepare-python.sh`. This prepares the pinned iOS CPython framework and catalog dependencies in the ignored `ios/.python/` directory.
2. Open `ios/WiiMTIDAL.xcodeproj` in Xcode. In **Signing & Capabilities**, select your own development team for **both WiiMTIDAL and WiiMWidget**, with automatic signing enabled. Replace the bundled team selection; it does not grant access to the maintainer’s account. If Xcode requires unique bundle identifiers, use a pair such as `com.yourname.wiimtidal` and `com.yourname.wiimtidal.player` (the extension must keep the app identifier as its prefix). Choose your iPhone, enable Developer Mode if prompted, and run **WiiMTIDAL**.
3. Put the iPhone and WiiM on the same Wi-Fi. Sign in to TIDAL in WiiM Home.
4. In **Settings**, tap **Discover WiiM** and select your speaker. Allow Local Network access when prompted. You can also enter its IPv4 address from WiiM Home. The default queue port is 49152.
5. In **Browse**, choose **Connect TIDAL**, approve on TIDAL’s page, and return to the app. It connects automatically. This sign-in supports catalog search, quality labels, Hi-Res filtering, and playback.
6. Search, open an album, and play it or an individual track. A short cancellable countdown precedes queue replacement.

**Hi-Res sign-in** is optional. Choose **Enable Hi-Res details** in the account menu, sign in, and paste the full final redirect URL to enable catalog estimates such as 24-bit / 96 kHz. WiiM’s own account and audio settings determine playback quality.

A Mac with Xcode and Python 3 with pip is required to build. You do not need the maintainer’s Apple Account or signing keys. A free Apple Account supports personal-device testing; its provisioning profiles expire after seven days, so rebuild and reinstall as needed. TestFlight and App Store distribution require Apple Developer Program membership. [Apple account requirements](https://developer.apple.com/help/account/basics/about-your-developer-account)

## Lock-screen player

While music is playing, the app starts a Live Activity on the Lock Screen and Dynamic Island. It offers previous, play/pause, next, and refresh controls. Tap the card to open the Player tab. **Settings → Lock Screen player** turns it off; allow Live Activities in iOS Settings if prompted.

These controls run in the app through a `LiveActivityIntent` and send commands directly to the selected WiiM, even when the app is backgrounded. iOS may require Face ID or the device passcode before running a button. The iPhone must remain on the speaker’s Wi-Fi.

The WiiM plays audio independently, so the app does not claim an iPhone audio session or play silent audio to stay alive. iOS suspends ordinary polling in the background. The card marks old track information as stale; **Refresh** and playback buttons fetch current device status. Changes made by another controller and automatic track changes appear on the next refresh or when the app returns to the foreground. No push server is required.

## Features shared with the desktop app

| Desktop feature | iPhone location |
| --- | --- |
| Device approval login, saved session, optional Hi-Res login | Browse account menu |
| Search albums, artists and tracks together | Browse category chips |
| Match → quality → artist groups, chronological releases | Search results |
| Expand/collapse groups | Results view-options menu |
| Artist, album and Hi-Res filters | Results → Filters |
| Quality labels and lazy, cached resolution estimates | Results and album pages |
| Album artwork, track lists, individual/album playback, open in TIDAL | Album page |
| Cancellable queue replacement, ordered IDs, duplicate preservation, 100-track limit | Playback confirmation |
| Recent shelf and dated history after successful playback | Browse and History |
| Current artwork, track, artist and album | Player and persistent Browse mini-player |
| Play/pause/resume, previous/next, seek, elapsed/remaining time, volume | Player |
| Current album tracks with current-track highlighting | Player → Album tracks |
| Current-track catalog resolution and device-reported bitrate | Player |
| Refresh, reconnect on foreground, periodic recovery | Pull to refresh and automatic checks |
| Speaker discovery, selection, manual IP and queue port | Settings |
| Rediscover a selected speaker after an IP change | Foreground discovery for a saved device identity |
| Space and arrow-key playback shortcuts | Player with a hardware keyboard |

The iPhone also shows the last queue sent from that phone. It is labeled accordingly because other controllers can replace WiiM’s queue. Listening history is local to each installation, as browser history is local to the desktop browser.

Discovery uses WiiM’s `_linkplay._tcp` Bonjour advertisement and validates its UPnP description using the desktop parser. Firmware or networks that do not expose Bonjour can use manual IP setup. Discovery is restricted to private IPv4 addresses and same-device control URLs. The desktop’s SSDP multicast search requires an additional entitlement on iOS, so the native app uses Apple’s Bonjour API. [Apple Local Network guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

The desktop server’s start/stop controls and macOS menu bar have no corresponding iPhone service. The native app requires no local web server. WiiM continues playing when the iPhone app is backgrounded. iOS suspends its network polling until it returns to the foreground.

## Implementation

- `WiiMTIDAL/PlayerModel.swift` owns connection, transport, queue confirmation, recents, and history. Device and command revisions reject stale status responses.
- `WiiMTIDAL/PlayerViews.swift` implements Now Playing, the mini-player, progress and volume controls, current-album access, and settings.
- `WiiMTIDAL/CatalogView.swift` preserves both login flows and implements albums and history. `SearchResultsView.swift` implements desktop-style grouping, filters, and release ordering.
- `WiiMTIDAL/WiiMClient.swift` implements the same WiiM HTTP commands and UPnP queue format as the desktop. Status position/duration are milliseconds; seek commands are seconds. Self-signed TLS is accepted only for the chosen private IP, with session certificate pinning.
- `WiiMTIDAL/WiiMDiscovery.swift` resolves Bonjour services. `catalog_bridge.py` calls shared catalog and UPnP description code on a serialized worker.
- `WiiMTIDAL/LockScreenPlayer.swift` manages Live Activity lifecycle and background commands against the shared player model. `WiiMActivity.swift` shares the activity data and intent declaration with the `WiiMWidget` extension. A stale activity cannot control a different selected speaker.
- `prepare-python.sh` and `bundle-python.sh` prepare and embed CPython and `tidalapi`. Rerun preparation after changing requirements. Tokens remain in private, backup-excluded application storage.

## Verification

From the repository root:

```sh
PYTHONPATH=src .venv/bin/python -m unittest discover -s ios/tests -p 'test_*.py'
bash ios/tests/run.sh
```

The native test script requires Xcode and an iOS 27 Simulator runtime. It creates a disposable project and Simulator, injects mock catalog/device responses only into that copy, and runs model, transport and UI tests, including long-album scrolling and background Live Activity controls. It leaves logs and screenshots under the printed temporary directory, then removes the Simulator. No mock code is included in the normal app target.

Build the real app for Simulator with:

```sh
xcodebuild -project ios/WiiMTIDAL.xcodeproj -scheme WiiMTIDAL \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Physical-device checks remain necessary for the Local Network prompt, Bonjour discovery on the actual Wi-Fi, and audio playback on WiiM.
