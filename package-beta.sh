#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
VERSION="1.0.4-beta.3"
OUTPUT="${1:-$HOME/Downloads/PlusCodex-${VERSION}-arm64.zip}"
if [[ -e "$OUTPUT" ]]; then
    echo "이미 존재하는 파일입니다. 다른 출력 경로를 지정하세요: $OUTPUT" >&2
    exit 1
fi
bash build.sh
STAGE=$(mktemp -d /tmp/pluscodex-beta.XXXXXX)
ditto build/PlusCodex.app "$STAGE/PlusCodex.app"
PLIST="$STAGE/PlusCodex.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 5" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :PlusCodexBeta bool true" "$PLIST"
cp BETA_TESTING.md "$STAGE/BETA_TESTING.md"
codesign --force --sign - "$STAGE/PlusCodex.app"
codesign --verify --deep --strict "$STAGE/PlusCodex.app"
ditto -c -k --sequesterRsrc "$STAGE" "$OUTPUT"
echo "베타 ZIP: $OUTPUT"
echo "검증용 임시 폴더: $STAGE"
