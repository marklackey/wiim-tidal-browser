#!/bin/bash
set -eo pipefail

framework=.python/Python.xcframework
cd "$PROJECT_DIR"
if [[ ! -f "$framework/build/utils.sh" || ! -d .python/packages/tidalapi ]]; then
    echo "error: Run bash ios/prepare-python.sh from the repository root before building for iPhone." >&2
    exit 1
fi

# Unsigned builds still need a local identity for the standard library extension frameworks.
export EXPANDED_CODE_SIGN_IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:--}
export CODESIGNING_FOLDER_PATH=${CODESIGNING_FOLDER_PATH:-"$TARGET_BUILD_DIR/$WRAPPER_NAME"}
app_sources="$CODESIGNING_FOLDER_PATH/catalog"
packages="$CODESIGNING_FOLDER_PATH/catalog-packages"
mkdir -p "$app_sources/wiim_tidal" "$packages"
rsync -rt --delete --exclude '__pycache__/' .python/packages/ "$packages/"
cp catalog_bridge.py "$app_sources/"
for module in __init__ adapters catalog config tidal discovery; do
    cp "../src/wiim_tidal/$module.py" "$app_sources/wiim_tidal/"
done

source "$framework/build/utils.sh"
install_python "$framework" catalog-packages
