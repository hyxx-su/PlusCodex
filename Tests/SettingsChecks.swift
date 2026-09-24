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
        let window = AISettingsWindow(settings: settings, login: login)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let toggles = descendants(window.window!.contentView!).compactMap { $0 as? NSSwitch }
        let providerToggles = toggles.filter { AIProvider(rawValue: $0.identifier?.rawValue ?? "") != nil }
        precondition(providerToggles.count == 3)
        let notificationToggles = toggles.filter {
            guard let raw = $0.identifier?.rawValue, raw.hasPrefix("notification-") else { return false }
            return NotificationKind(rawValue: String(raw.dropFirst("notification-".count))) != nil
        }
        precondition(notificationToggles.count == NotificationKind.allCases.count)
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
                return ["notification-permission", "notification-completion"].contains(view.identifier?.rawValue ?? "")
                    || ["알림 소리", "재생 시간", "음량", "알림 테스트"].contains(view.accessibilityLabel() ?? "")
                        && (view is NSButton || view is NSSlider)
            }
            precondition(controls.count == expectedCount)
            for control in controls {
                let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
                let hit = root.superview?.hitTest(point)
                precondition(hit === control || hit?.isDescendant(of: control) == true,
                             "\(control.accessibilityLabel() ?? "알림 컨트롤") click intercepted by \(String(describing: hit))")
            }
        }
        verifyNotificationControls(in: window, expectedCount: 4)
        let soundDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlusCodex-control-hit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: soundDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: soundDirectory) }
        try Data("fixture".utf8).write(to: soundDirectory.appendingPathComponent("selected.caf"))
        defaults.set("selected.caf", forKey: "notifications.sound.customName")
        let customSoundSettings = NotificationSettings(defaults: defaults, soundDirectory: soundDirectory)
        let expandedWindow = AISettingsWindow(settings: settings,
                                              notificationSettings: customSoundSettings, login: login)
        verifyNotificationControls(in: expandedWindow, expectedCount: 6)
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
            var opens = 0
            controller.onOpen = { opens += 1 }
            controller.menuWillOpen(controller.testHookMenu)
            precondition(opens == 1)
            controller.testHookPresentation(quota: nil, fetching: true, checking: false, offline: false)
            precondition((controller.testHookMenu.items[0].view as? QuotaMenuView)?.intro == true)
            let quota = Quota(primary: QuotaWindow(usedPercent: 45, windowDurationMins: 300, resetsAt: nil), secondary: nil)
            controller.testHookPresentation(quota: quota, fetching: false, checking: false, offline: false)
            let height = controller.testHookMenu.size.height
            for (offline, checking) in [(false, true), (true, true), (true, false), (false, false)] {
                controller.testHookPresentation(quota: quota, fetching: false, checking: checking, offline: offline)
                precondition(abs(controller.testHookMenu.size.height - height) < 1)
                precondition(controller.testHookMenu.items.filter { !$0.isHidden }.count == ((offline || checking) ? 1 : 5))
                let view = controller.testHookMenu.items[0].view!
                precondition(view.subviews.contains { $0 is QuotaLoadingView } == (offline || checking))
            }
        }
        print("PASS: login, native switches, notification hit targets, Claude/Grok loading and stable overlays")
    }
}
