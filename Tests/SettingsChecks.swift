import AppKit
import ServiceManagement

@main struct SettingsChecks {
    static func main() throws {
        _ = NSApplication.shared
        let suite = "PlusCodex.settings.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var status: SMAppService.Status = .notRegistered
        var registrations = 0, removals = 0
        let login = LoginLaunchController(defaults: defaults, readStatus: { status }, register: {
            registrations += 1; status = .enabled
        }, unregister: { removals += 1; status = .notRegistered })
        try login.applyInitialDefault()
        try login.applyInitialDefault()
        precondition(login.requested && registrations == 1)
        try login.setEnabled(false)
        try login.applyInitialDefault()
        precondition(!login.requested && removals == 1 && registrations == 1)
        status = .requiresApproval
        precondition(!login.requested && login.requiresApproval && login.message.contains("허용"))
        let settings = ProviderSettings(defaults: defaults)
        let wakeSettings = CodexWakeSettings(defaults: defaults)
        var openedDiscordURL: URL?
        let window = AISettingsWindow(settings: settings, wakeSettings: wakeSettings, login: login,
                                      claudeAvailability: { .availableOrUnknown },
                                      grokAvailability: { .readyToCheck },
                                      openDiscordURL: { openedDiscordURL = $0 })
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let root = window.window!.contentView!
        let discord = descendants(root).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "settings-discord" }!
        precondition(discord.title == "디스코드 커뮤니티" && discord.accessibilityLabel() == "디스코드 커뮤니티")
        precondition(discord.image?.size == NSSize(width: 12, height: 12))
        precondition(discord.frame.height <= 24 && discord.frame.midX == 105,
                     "Keep the Discord button small and centered in the sidebar")
        let footer = root.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Copyright 2026 hyxx-su" }!
        precondition(discord.frame.minY > footer.frame.maxY && discord.frame.maxX < 210,
                     "The Discord button must sit above the version/copyright footer")
        let discordPoint = discord.convert(NSPoint(x: discord.bounds.midX, y: discord.bounds.midY), to: nil)
        let discordHit = root.superview?.hitTest(discordPoint)
        precondition(discordHit === discord || discordHit?.isDescendant(of: discord) == true)
        discord.performClick(nil)
        precondition(openedDiscordURL?.absoluteString == "https://discord.gg/jR87pagNRG")
        try verifyDiscordLocalization(in: window, button: discord, settings: settings)
        precondition(descendants(root).allSatisfy { $0.toolTip == nil },
                     "Settings controls and footer links must not show hover tooltips")
        wakeSettings.lastFailure = "Wake failure detail"
        window.synchronize()
        precondition(descendants(root).allSatisfy { $0.toolTip == nil },
                     "A failed wake must not restore its old tooltip")
        let wakeDescription = descendants(root).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityHelp() == "Wake failure detail" }!
        wakeSettings.lastFailure = nil
        window.synchronize()
        precondition(wakeDescription.toolTip == nil && wakeDescription.accessibilityHelp()?.contains("사용량이 소모") == true,
                     "Recovery must restore accessible guidance without a hover tooltip")
        let toggles = descendants(window.window!.contentView!).compactMap { $0 as? NSSwitch }
        let providerToggles = toggles.filter { AIProvider(rawValue: $0.identifier?.rawValue ?? "") != nil }
        precondition(providerToggles.count == 3)
        let notificationToggles = toggles.filter {
            guard let raw = $0.identifier?.rawValue, raw.hasPrefix("notification-") else { return false }
            return NotificationKind(rawValue: String(raw.dropFirst("notification-".count))) != nil
        }
        precondition(notificationToggles.count == NotificationKind.allCases.count)
        let taskNotificationToggle = notificationToggles.first {
            $0.identifier?.rawValue == "notification-completion"
        }!
        precondition(taskNotificationToggle.accessibilityLabel() == "작업 알림")
        let settingsText = descendants(window.window!.contentView!).compactMap { $0 as? NSTextField }
        precondition(settingsText.contains { $0.stringValue == "작업 알림" })
        precondition(settingsText.contains { $0.stringValue == "새 작업의 완료 알림을 자동으로 활성화합니다." })
        precondition(descendants(window.window!.contentView!).compactMap { $0 as? NSButton }
            .contains { $0.accessibilityLabel() == "작업 알림" }, "Settings search must use the updated task-notification title")
        precondition(L10n.translation(NotificationKind.completion.titleKey, language: .english) == "Task notifications")
        precondition(L10n.translation(NotificationKind.completion.descriptionKey, language: .english)
            == "Automatically enable completion notifications for new tasks.")
        let expirySettings = NotificationSettings(defaults: defaults)
        let expiryWindow = AISettingsWindow(settings: settings, notificationSettings: expirySettings, login: login,
                                            claudeAvailability: { .availableOrUnknown },
                                            grokAvailability: { .readyToCheck })
        let expiryToggle = descendants(expiryWindow.window!.contentView!).compactMap { $0 as? NSSwitch }
            .first { $0.identifier?.rawValue == "notification-resetCreditExpiry" }!
        precondition(expiryToggle.state == .on && expiryToggle.accessibilityLabel() == "초기화권 만료")
        expiryToggle.state = .off
        _ = expiryToggle.sendAction(expiryToggle.action, to: expiryToggle.target)
        precondition(!expirySettings.isEnabled(.resetCreditExpiry), "The expiry setting must use the existing notification controls")
        let cleanupToggle = descendants(expiryWindow.window!.contentView!).compactMap { $0 as? NSSwitch }
            .first { $0.identifier?.rawValue == "notification-autoCleanup" }!
        precondition(cleanupToggle.state == .off && cleanupToggle.accessibilityLabel() == "알림 자동 정리")
        precondition(cleanupToggle.toolTip == nil && cleanupToggle.accessibilityHelp()?.contains("알림센터 기록") == true)
        precondition(descendants(expiryWindow.window!.contentView!).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "표시된 알림을 일정 시간이 지나면 자동으로 지웁니다." })
        cleanupToggle.state = .on
        _ = cleanupToggle.sendAction(cleanupToggle.action, to: cleanupToggle.target)
        precondition(expirySettings.autoCleanupEnabled && expirySettings.autoCleanupStartedAt != nil)
        let persistedSettings = NotificationSettings(defaults: defaults)
        precondition(persistedSettings.autoCleanupStartedAt == expirySettings.autoCleanupStartedAt)
        cleanupToggle.state = .off
        _ = cleanupToggle.sendAction(cleanupToggle.action, to: cleanupToggle.target)
        precondition(!expirySettings.autoCleanupEnabled && expirySettings.autoCleanupStartedAt == nil)
        precondition(descendants(expiryWindow.window!.contentView!).allSatisfy { $0.toolTip == nil },
                     "Toggling notification settings must not reintroduce hover tooltips")
        precondition(L10n.translation("알림 자동 정리", language: .english) == "Auto-clear notifications")
        if CommandLine.arguments.contains("--render-auto-cleanup") {
            let root = expiryWindow.window!.contentView!
            let navigation = descendants(root).compactMap { $0 as? NSButton }
                .first { $0.tag == 2 && $0.accessibilityLabel() == "알림" }!
            navigation.performClick(nil)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                cleanupToggle.state = appearance == .darkAqua ? .on : .off
                _ = cleanupToggle.sendAction(cleanupToggle.action, to: cleanupToggle.target)
                NSApp.appearance = NSAppearance(named: appearance)
                try snapshot(root, appearance: appearance,
                             path: "build/notification-auto-cleanup-\(appearance.rawValue).png")
            }
            cleanupToggle.state = .off
            _ = cleanupToggle.sendAction(cleanupToggle.action, to: cleanupToggle.target)
            NSApp.appearance = nil
        }
        let scrolls = descendants(window.window!.contentView!).compactMap { $0 as? NSScrollView }
        precondition(scrolls.contains { ($0.documentView?.frame.height ?? 0) > $0.frame.height },
                     "Additional notification options must remain scrollable")
        precondition(providerToggles.first { $0.identifier?.rawValue == "codex" }?.state == .on)
        precondition(providerToggles.first { $0.identifier?.rawValue == "claude" }?.state == .off)
        precondition(providerToggles.first { $0.identifier?.rawValue == "grok" }?.state == .off)
        precondition(toggles.first { $0.identifier?.rawValue == "launchAtLogin" }?.state == .off)
        precondition(window.window!.title == "설정")
        precondition(window.window!.contentView!.frame.size == NSSize(width: 680, height: 600))
        precondition(providerToggles.allSatisfy { $0.frame.width <= 54 })
        func verifyNotificationControls(in controller: AISettingsWindow, expectedCount: Int) {
            let root = controller.window!.contentView!
            let notificationNavigation = descendants(root).compactMap { $0 as? NSButton }
                .first { $0.tag == 2 && $0.accessibilityLabel() == "알림" }!
            notificationNavigation.performClick(nil)
            root.layoutSubtreeIfNeeded()
            let scroll = descendants(root).compactMap { $0 as? NSScrollView }
                .first { ($0.documentView?.frame.height ?? 0) > $0.frame.height }!
            let controls = descendants(scroll.documentView!).filter { view in
                guard !view.isHidden else { return false }
                return ["notification-permission", "notification-autoCleanup", "notification-completion"].contains(view.identifier?.rawValue ?? "")
                    || ["알림 소리", "재생 시간", "음량", "알림 테스트"].contains(view.accessibilityLabel() ?? "")
                        && (view is NSButton || view is NSSlider)
            }
            precondition(controls.count == expectedCount)
            let permissionCard = controls.first { $0.identifier?.rawValue == "notification-permission" }!.superview!
            let cleanupCard = controls.first { $0.identifier?.rawValue == "notification-autoCleanup" }!.superview!
            let optionsCard = controls.first { $0.identifier?.rawValue == "notification-completion" }!.superview!
            precondition(cleanupCard.frame.minY > permissionCard.frame.maxY)
            precondition(optionsCard.frame.minY > cleanupCard.frame.maxY,
                         "The cleanup card must sit between permission and notification-kind sections")
            for control in controls {
                // New sections extend the document beyond the viewport. Check
                // hit targets after bringing each control into the visible area.
                control.scrollToVisible(control.bounds)
                scroll.reflectScrolledClipView(scroll.contentView)
                root.layoutSubtreeIfNeeded()
                let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
                let hit = root.superview?.hitTest(point)
                precondition(hit === control || hit?.isDescendant(of: control) == true,
                             "\(control.accessibilityLabel() ?? "알림 컨트롤") click intercepted by \(String(describing: hit))")
            }
        }
        verifyNotificationControls(in: window, expectedCount: 5)
        let soundDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlusCodex-control-hit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: soundDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: soundDirectory) }
        try Data("fixture".utf8).write(to: soundDirectory.appendingPathComponent("selected.caf"))
        defaults.set("selected.caf", forKey: "notifications.sound.customName")
        let customSoundSettings = NotificationSettings(defaults: defaults, soundDirectory: soundDirectory)
        let expandedWindow = AISettingsWindow(settings: settings,
                                              notificationSettings: customSoundSettings, login: login,
                                              claudeAvailability: { .availableOrUnknown },
                                              grokAvailability: { .readyToCheck })
        verifyNotificationControls(in: expandedWindow, expectedCount: 7)
        precondition(descendants(expandedWindow.window!.contentView!).allSatisfy { $0.toolTip == nil })
        let volumeSlider = descendants(expandedWindow.window!.contentView!).compactMap { $0 as? NSSlider }
            .first { $0.accessibilityLabel() == "음량" }!
        precondition(volumeSlider.minValue == 0 && volumeSlider.maxValue == 200)
        precondition(volumeSlider.doubleValue == 100)
        precondition(volumeSlider.isContinuous, "Volume percentage must update during dragging")
        let claude = toggles.first { $0.identifier?.rawValue == "claude" }!
        claude.state = .on
        _ = claude.sendAction(claude.action, to: claude.target)
        precondition(settings.enabled(.claude))
        claude.state = .off
        _ = claude.sendAction(claude.action, to: claude.target)
        precondition(!settings.enabled(.claude))
        for provider in [AIProvider.claude, .grok] {
            settings.setEnabled(false, for: provider)
            let controller = ProviderStatusController(provider: provider, settings: settings)
            let settingsRow = controller.testHookMenu.items.first { $0.title == "설정" }
            precondition(settingsRow != nil && settingsRow?.image == nil)
            precondition(settingsRow?.keyEquivalent == ",")
            let previousView = controller.testHookMenu.items[0].view
            controller.menuWillOpen(controller.testHookMenu)
            controller.testHookPresentation(quota: nil, fetching: true, checking: false, offline: false)
            precondition(controller.testHookMenu.items[0].view === previousView,
                         "Tracking must keep the provider menu view stable")
            controller.menuDidClose(controller.testHookMenu)
            precondition((controller.testHookMenu.items[0].view as? QuotaMenuView)?.intro == true)
            let quota = Quota(primary: QuotaWindow(usedPercent: 45, windowDurationMins: 300, resetsAt: nil), secondary: nil)
            controller.testHookPresentation(quota: quota, fetching: false, checking: false, offline: false)
            let height = controller.testHookMenu.size.height
            for (offline, checking) in [(false, true), (true, true), (true, false), (false, false)] {
                controller.testHookPresentation(quota: quota, fetching: false, checking: checking, offline: offline)
                precondition(abs(controller.testHookMenu.size.height - height) < 1)
                precondition(controller.testHookMenu.items.filter { !$0.isHidden }.count == ((offline || checking) ? 1 : 4))
                let view = controller.testHookMenu.items[0].view!
                precondition(view.subviews.contains { $0 is QuotaLoadingView } == (offline || checking))
            }
        }
        print("PASS: login, native switches, notification hit targets, Discord footer, Claude/Grok loading and stable overlays")
    }

    private static func verifyDiscordLocalization(in controller: AISettingsWindow, button: NSButton,
                                                 settings: ProviderSettings) throws {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let appearance = NSApp.appearance
        let providers = [AIProvider.claude, .grok].map {
            ProviderStatusController(provider: $0, settings: settings,
                                     claudeAvailability: { .availableOrUnknown },
                                     grokAvailability: { .readyToCheck })
        }
        defer {
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            NSApp.appearance = appearance
            controller.window?.appearance = nil
            controller.reloadLocalization()
        }
        for language in AppLanguage.allCases {
            var localizedArguments = arguments
            localizedArguments["appLanguage"] = language.rawValue
            defaults.setVolatileDomain(localizedArguments, forName: UserDefaults.argumentDomain)
            controller.reloadLocalization()
            let title = L10n.translation("디스코드 커뮤니티", language: language)
            precondition(title == (language == .korean ? "디스코드 커뮤니티" : "Discord community"))
            precondition(button.title == title && button.accessibilityLabel() == title)
            precondition(button.toolTip == nil && button.image?.size == NSSize(width: 12, height: 12))
            let titleWidth = (title as NSString).size(withAttributes: [.font: button.font!]).width
            precondition(titleWidth + 12 < button.frame.width && button.frame.width <= 186,
                         "The localized community label and icon must fit inside the sidebar")
            precondition(button.frame.midX == 105 && button.frame.height == 24)
            for provider in providers {
                provider.reloadLocalization()
                let rows = provider.testHookMenu.items.filter { $0.action != nil }
                precondition(rows.map(\.title) == [L10n.text("설정"), L10n.text("PlusCodex 종료")],
                             "Provider menus must not restore Discord after a language change")
                precondition(rows.map(\.keyEquivalent) == [",", "q"])
            }
            if CommandLine.arguments.contains("--render-discord-footer") {
                for theme in [NSAppearance.Name.aqua, .darkAqua] {
                    NSApp.appearance = NSAppearance(named: theme)
                    try snapshot(controller.window!.contentView!, appearance: theme,
                                 path: "build/settings-discord-\(language.rawValue)-\(theme.rawValue).png")
                }
            }
        }
    }

    private static func snapshot(_ view: NSView, appearance: NSAppearance.Name, path: String) throws {
        view.window?.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor(calibratedWhite: appearance == .aqua ? 0.96 : 0.15, alpha: 1).setFill()
        view.bounds.fill()
        let content = NSImage(size: view.bounds.size)
        content.addRepresentation(bitmap)
        content.draw(in: view.bounds)
        image.unlockFocus()
        let opaque = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try opaque.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
