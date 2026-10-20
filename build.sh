#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/PlusCodex.app"
# TCC remembers the signing requirement, so local rebuilds should keep a certificate identity.
# CI has no signing credentials. Explicit '-' remains available for an intentional ad-hoc build.
APP_SIGN_IDENTITY="${PLUSCODEX_SIGN_IDENTITY:-}"
if [[ -z "$APP_SIGN_IDENTITY" ]]; then
    if [[ -n "${CI:-}" ]]; then
        APP_SIGN_IDENTITY="-"
    else
        APP_DEVELOPMENT_IDENTITIES=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2 }')
        case "$APP_DEVELOPMENT_IDENTITIES" in
            *$'\n'*)
                echo 'Multiple Apple Development identities found. Set PLUSCODEX_SIGN_IDENTITY explicitly.' >&2
                exit 2
                ;;
            "")
                APP_SIGN_IDENTITY="-"
                echo 'No Apple Development identity found. Using ad-hoc signing; privacy permissions may need reauthorization after rebuilds.' >&2
                ;;
            *) APP_SIGN_IDENTITY="$APP_DEVELOPMENT_IDENTITIES" ;;
        esac
    fi
fi
bash prepare-sparkle.sh
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
ditto build/sparkle/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
    -F build/sparkle -framework Sparkle -framework AVFoundation \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
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
cp Resources/Discord.png "$APP/Contents/Resources/Discord.png"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/PatchNotes.json "$APP/Contents/Resources/PatchNotes.json"
cp Resources/PatchNotesBanner.png "$APP/Contents/Resources/PatchNotesBanner.png"
ditto Resources/ko.lproj "$APP/Contents/Resources/ko.lproj"
ditto Resources/en.lproj "$APP/Contents/Resources/en.lproj"
cp Resources/Codex.svg "$APP/Contents/Resources/Codex.svg"
cp Resources/Claude.svg Resources/Grok.svg Resources/Gemini.svg Resources/Orca-LICENSE "$APP/Contents/Resources/"
cp Resources/Notification*.png "$APP/Contents/Resources/"
cp Resources/CodexBar-LICENSE "$APP/Contents/Resources/CodexBar-LICENSE"
cp build/sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"
codesign --force --sign "$APP_SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
