# macOS launcher and release ZIP

## Launcher and permissions

- Use `scripts/macos-entry.py` for the bundled entry point and `scripts/macos-launcher.swift` for the menu bar, reopen and permission UI. The PyInstaller process hosts both the Waitress server and the Swift launcher. This keeps WiiM network access under the bundle's app identity. The server binds to `127.0.0.1`, normally using the first free port in 8765–8774.
- Keep the bundle identifier `org.wiimtidal.browser` and its `NSLocalNetworkUsageDescription` when changing packaging. **Local Network Access → Request Access** in the menu bar triggers the system permission flow through a UDP connect. If the user denied it earlier, enable the app under **System Settings → Privacy & Security → Local Network** and try discovery again. Manual private IPv4 setup helps distinguish multicast discovery issues from reachability or permission issues.

## Build and inspect

- `scripts/build-macos.sh` builds on the target Mac architecture with Xcode Command Line Tools, Python and PyInstaller. Use an interpreter with the app installed and pass `PYTHON` if needed. Check that `pyproject.toml` and `src/wiim_tidal/__init__.py` agree for a version bump. The script reads the release version from `python -m wiim_tidal --version`.
- By default the script signs ad hoc. `MACOS_SIGN_IDENTITY` selects a Developer ID Application identity and the hardened runtime. The script verifies the signature and runs the bundled `--version` before making a ZIP. Notarization and stapling are separate release steps. Check the signature and ticket on the specific artifact.
- To package the final app, preserve bundle symlinks and suppress macOS metadata sidecars using `/usr/bin/ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$archive"`. The local 0.1.7 arm64 release ZIP had 180 `._*` AppleDouble entries before clean repackaging and none afterward. Check `zipinfo -1` for both `._*` path components and a `__MACOSX/` wrapper since either form can carry sidecars.
- When verifying a distribution ZIP, extract a fresh copy with `ditto -x -k`, run `codesign --verify --deep --strict` on the extracted app and run its bundled `--version`. For a notarized release, validate the ticket on the extracted app with `xcrun stapler validate` and check Gatekeeper assessment with `spctl --assess --type execute --verbose`.
- The clean 0.1.7 arm64 ZIP passed strict signature verification after extraction outside the sandbox. If the sandbox reports `invalid signature` for a Developer ID build, repeat the check outside the sandbox on the same extracted artifact before rebuilding.
