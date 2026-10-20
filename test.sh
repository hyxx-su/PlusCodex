#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Keep the default suite and CI shards on the same allowlist. Live-account checks stay opt-in.
TEST_NAMES=(ReliabilityChecks AppearanceSoundChecks CLIInstallationChecks QuotaTests QuotaAlertChecks QuotaLayoutChecks IssueReportChecks NotificationChecks NotificationAutoCleanupChecks ResetCreditExpiryChecks NotificationSoundChecks MenuBuilderChecks IntroChecks PermissionOnboardingChecks ActivityChecks ActivityIPCChecks LiveMenuChecks ThreadNotificationChecks UpdateLoadingChecks UpdaterChecks ProviderChecks GeminiActivityChecks ClaudeFallbackChecks SettingsChecks SettingsTextEditingChecks SettingsDockChecks BackgroundKeychainChecks PresentationChecks CodexWakeChecks CodexWakeBridgeChecks CodexWakeAccountChecks UsageDisplayChecks MenuBarFormatChecks StatusWindowChecks CompactSettingsChecks PatchNotesChecks)
SELECTED_TESTS=("${TEST_NAMES[@]}")
if [[ $# -gt 0 ]]; then
    SELECTED_TESTS=("$@")
    for selected in "${SELECTED_TESTS[@]}"; do
        found=false
        for allowed in "${TEST_NAMES[@]}"; do
            [[ "$selected" != "$allowed" ]] || found=true
        done
        if [[ "$found" != true ]]; then
            echo "Unknown or live-account test: $selected" >&2
            exit 2
        fi
    done
fi
bash prepare-sparkle.sh
SOURCES=()
for file in Sources/*.swift; do
    [[ "$file" == Sources/main.swift ]] || SOURCES+=("$file")
done
# QuotaStartupChecks requires a real authenticated account and is intentionally opt-in.
for name in "${SELECTED_TESTS[@]}"; do
    TEST_APP="$PWD/build/$name.app"
    mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources"
    cp Info.plist "$TEST_APP/Contents/Info.plist"
    cp Resources/PatchNotes.json "$TEST_APP/Contents/Resources/PatchNotes.json"
    cp Resources/PatchNotesBanner.png "$TEST_APP/Contents/Resources/PatchNotesBanner.png"
    ditto Resources/ko.lproj "$TEST_APP/Contents/Resources/ko.lproj"
    ditto Resources/en.lproj "$TEST_APP/Contents/Resources/en.lproj"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.pluscodex.tests.$name" "$TEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $name" "$TEST_APP/Contents/Info.plist"
    cp Resources/Codex.svg "$TEST_APP/Contents/Resources/"
    cp Resources/Discord.png "$TEST_APP/Contents/Resources/"
    cp Resources/Claude.svg Resources/Grok.svg Resources/Gemini.svg "$TEST_APP/Contents/Resources/"
    cp Resources/Notification*.png "$TEST_APP/Contents/Resources/"
    xcrun swiftc -swift-version 5 -F build/sparkle -framework Sparkle -framework AVFoundation \
        -Xlinker -rpath -Xlinker "$PWD/build/sparkle" \
        "${SOURCES[@]}" "Tests/$name.swift" -o "$TEST_APP/Contents/MacOS/$name"
    codesign --force --sign - "$TEST_APP"
    "$TEST_APP/Contents/MacOS/$name" -appLanguage ko -AppleLanguages '(ko)'
done
