#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
DESTINATION="${1:?Usage: bash package-release.sh /absolute/path/new-release-directory}"
[[ "$DESTINATION" = /* && ! -e "$DESTINATION" ]] || { echo 'Use a new absolute output directory' >&2; exit 1; }
mkdir -p "$DESTINATION"
bash package-dmg.sh "$DESTINATION/PlusCodex-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent build/PlusCodex.app "$DESTINATION/PlusCodex-$VERSION.zip"
# A ZIP without Finder extras is used for Sparkle; DMG remains the manual installer.
APPCAST_STAGE=$(mktemp -d "$PWD/build/appcast.XXXXXX")
cp "$DESTINATION/PlusCodex-$VERSION.zip" "$APPCAST_STAGE/"
cp RELEASE_NOTES.md "$APPCAST_STAGE/PlusCodex-$VERSION.md"
build/sparkle/bin/generate_appcast --account PlusCodex --maximum-deltas 0 \
    --embed-release-notes \
    --download-url-prefix "https://github.com/hyxx-su/PlusCodex/releases/download/v$VERSION/" \
    --link https://github.com/hyxx-su/PlusCodex "$APPCAST_STAGE"
cp "$APPCAST_STAGE/appcast.xml" "$DESTINATION/appcast.xml"
xcrun swift VerifyRelease.swift "$DESTINATION"
echo "Release artifacts: $DESTINATION"
