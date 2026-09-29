#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ARCHIVE="$PWD/build/Sparkle-2.10.0.tar.xz"
mkdir -p build/sparkle
# Never unpack a framework while another build is preparing it.
if ! mkdir build/.sparkle-prepare-lock 2>/dev/null; then
    echo 'Sparkle preparation is already running. Retry after it finishes.' >&2
    exit 1
fi
trap 'rmdir build/.sparkle-prepare-lock' EXIT
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 2 --proto '=https' \
        https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
        -o "$ARCHIVE"
fi
EXPECTED=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo 'Sparkle checksum mismatch' >&2; exit 1; }
if [[ -x build/sparkle/bin/generate_appcast && -d build/sparkle/Sparkle.framework ]] \
    && codesign --verify --deep --strict build/sparkle/Sparkle.framework 2>/dev/null; then
    exit 0
fi
tar -xf "$ARCHIVE" -C build/sparkle
