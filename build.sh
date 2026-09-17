#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/PlusCodex.app"
bash prepare-sparkle.sh
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
ditto build/sparkle/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
    -F build/sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/*.swift -o "$APP/Contents/MacOS/PlusCodex"
ICONSET="$PWD/build/PlusCodex.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/PlusCodex.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" Resources/PlusCodex.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/PlusCodex.icns"
cp Resources/PlusCodex.png "$APP/Contents/Resources/PlusCodex.png"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Codex.svg "$APP/Contents/Resources/Codex.svg"
cp Resources/CodexBar-LICENSE "$APP/Contents/Resources/CodexBar-LICENSE"
cp build/sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"
codesign --force --sign - "$APP"
echo "$APP"
