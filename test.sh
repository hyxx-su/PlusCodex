#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash prepare-sparkle.sh
SOURCES=()
for file in Sources/*.swift; do
    [[ "$file" == Sources/main.swift ]] || SOURCES+=("$file")
done
for name in QuotaTests QuotaAlertChecks QuotaLayoutChecks NotificationChecks NotificationSoundChecks MenuBuilderChecks IntroChecks UpdateLoadingChecks UpdaterChecks ProviderChecks ClaudeFallbackChecks SettingsChecks BackgroundKeychainChecks PresentationChecks CodexWakeChecks; do
    TEST_APP="$PWD/build/$name.app"
    mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources"
    cp Info.plist "$TEST_APP/Contents/Info.plist"
    ditto Resources/ko.lproj "$TEST_APP/Contents/Resources/ko.lproj"
    ditto Resources/en.lproj "$TEST_APP/Contents/Resources/en.lproj"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.pluscodex.tests.$name" "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $name" "$TEST_APP/Contents/Info.plist"
    cp Resources/Codex.svg "$TEST_APP/Contents/Resources/"
    cp Resources/Claude.svg Resources/Grok.svg "$TEST_APP/Contents/Resources/"
    xcrun swiftc -swift-version 5 -F build/sparkle -framework Sparkle -framework AVFoundation \
        -Xlinker -rpath -Xlinker "$PWD/build/sparkle" \
        "${SOURCES[@]}" "Tests/$name.swift" -o "$TEST_APP/Contents/MacOS/$name"
    codesign --force --sign - "$TEST_APP"
    "$TEST_APP/Contents/MacOS/$name" -appLanguage ko -AppleLanguages '(ko)'
done
