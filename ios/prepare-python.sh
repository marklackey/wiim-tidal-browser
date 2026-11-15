#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

runtime_version=3.14-b14
runtime_url="https://github.com/beeware/Python-Apple-support/releases/download/$runtime_version/Python-3.14-iOS-support.b14.tar.gz"
runtime_digest=703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee
build_python=${PYTHON:-python3}
runtime_dir=.python
mkdir -p "$runtime_dir"
work=$(mktemp -d "$runtime_dir/setup.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [[ ! -f "$runtime_dir/Python.xcframework/build/utils.sh" ]] ||
   [[ ! -f "$runtime_dir/runtime-version" ]] ||
   [[ $(cat "$runtime_dir/runtime-version") != "$runtime_version" ]]; then
    curl --fail --location --retry 2 --silent --show-error "$runtime_url" -o "$work/python.tar.gz"
    printf '%s  %s\n' "$runtime_digest" "$work/python.tar.gz" | shasum -a 256 -c -
    tar -xzf "$work/python.tar.gz" -C "$work" Python.xcframework
    rm -rf "$runtime_dir/Python.xcframework"
    mv "$work/Python.xcframework" "$runtime_dir/"
    printf '%s\n' "$runtime_version" > "$runtime_dir/runtime-version"
fi

if [[ ! -d "$runtime_dir/packages/tidalapi" ]] || ! cmp -s requirements.txt "$runtime_dir/installed-requirements.txt"; then
    # charset-normalizer also ships an optional native accelerator. Build its pure Python form.
    CHARSET_NORMALIZER_USE_MYPYC=0 "$build_python" -m pip install --target "$work/packages" \
        --no-compile --no-binary charset-normalizer -r requirements.txt
    native_file=$(find "$work/packages" -type f \( -name '*.so' -o -name '*.dylib' \) -print -quit)
    if [[ -n "$native_file" ]]; then
        echo "Unexpected native binary in the iOS Python dependencies: $native_file" >&2
        exit 1
    fi
    rm -rf "$runtime_dir/packages"
    mv "$work/packages" "$runtime_dir/"
    cp requirements.txt "$runtime_dir/installed-requirements.txt"
fi
