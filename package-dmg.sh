#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

DESTINATION="${1:?Usage: bash package-dmg.sh /absolute/path/PlusCodex.dmg}"
if [[ -e "$DESTINATION" ]]; then
    echo "Destination already exists: $DESTINATION" >&2
    exit 1
fi
bash build.sh
codesign --verify --deep --strict build/PlusCodex.app
PACKAGE_STAGE=$(mktemp -d "$PWD/build/dmg.XXXXXX")
ditto build/PlusCodex.app "$PACKAGE_STAGE/PlusCodex.app"
ln -s /Applications "$PACKAGE_STAGE/Applications"
mkdir "$PACKAGE_STAGE/.background"
xcrun swift RenderDMG.swift "$PACKAGE_STAGE/.background/install.png"
if [[ ! -x build/dmg-tools/bin/python ]]; then
    python3 -m venv build/dmg-tools
fi
build/dmg-tools/bin/python -m pip install 'ds-store==1.3.3' 'mac-alias==2.2.3'
# mac_alias encodes the background reference as HFS+; match the volume format.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
hdiutil create -fs HFS+ -volname "PlusCodex $VERSION" -srcfolder "$PACKAGE_STAGE" -format UDRW "$PACKAGE_STAGE.dmg"
MOUNT_PATH=$(mktemp -d "$PWD/build/dmg-mount.XXXXXX")
hdiutil attach "$PACKAGE_STAGE.dmg" -nobrowse -mountpoint "$MOUNT_PATH"
trap 'hdiutil detach "$MOUNT_PATH" >/dev/null 2>&1 || true' EXIT
build/dmg-tools/bin/python LayoutDMG.py "$MOUNT_PATH"
hdiutil detach "$MOUNT_PATH"
trap - EXIT
hdiutil convert "$PACKAGE_STAGE.dmg" -format UDZO -o "$DESTINATION"
hdiutil verify "$DESTINATION"
