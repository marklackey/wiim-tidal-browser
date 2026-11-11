#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo "Run this script on a Mac."; exit 1; }
build_python="${PYTHON:-python3}"
version="$("$build_python" -m wiim_tidal --version)"
architecture="$(uname -m)"
mkdir -p dist
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PYINSTALLER_CONFIG_DIR="$work/cache"

export CLANG_MODULE_CACHE_PATH="$work/module-cache"
xcrun swiftc -O -emit-library -module-name WiiMLauncher scripts/macos-launcher.swift \
  -o "$work/libWiiMLauncher.dylib"
xcrun swiftc -O scripts/macos-icon.swift -o "$work/create-icon"
"$work/create-icon" "$work/WiiMTidal.iconset"
/usr/bin/iconutil -c icns "$work/WiiMTidal.iconset" -o "$work/WiiMTidal.icns"
signing=()
if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
  signing=(--codesign-identity "$MACOS_SIGN_IDENTITY")
fi
"$build_python" -m PyInstaller --noconfirm --onedir --windowed --name "WiiM TIDAL" \
  --osx-bundle-identifier org.wiimtidal.browser --icon "$work/WiiMTidal.icns" \
  --add-binary "$work/libWiiMLauncher.dylib:." \
  --collect-data wiim_tidal --distpath "$work/dist" --workpath "$work/work" \
  --specpath "$work" ${signing[@]+"${signing[@]}"} scripts/macos-entry.py
app="$work/dist/WiiM TIDAL.app"
"$build_python" scripts/bundle-licenses.py "$app/Contents/Resources/Licenses"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSLocalNetworkUsageDescription string Find and control your WiiM on the local network.' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist" ||
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $version" "$app/Contents/Info.plist"
if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$MACOS_SIGN_IDENTITY" "$app"
else
  /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/WiiM TIDAL" --version
archive="WiiM-TIDAL-$version-macos-$architecture.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$work/$archive"
mv -f "$work/$archive" "dist/$archive"
echo "Created dist/WiiM-TIDAL-$version-macos-$architecture.zip"
