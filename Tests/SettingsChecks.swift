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
        precondition(providerToggles.count == 3 && providerToggles.allSatisfy { $0.state == .on })
        precondition(toggles.first { $0.identifier?.rawValue == "launchAtLogin" }?.state == .off)
        precondition(window.window!.title == "설정")
        precondition(window.window!.contentView!.frame.size == NSSize(width: 680, height: 600))
        precondition(providerToggles.allSatisfy { $0.frame.width <= 54 })
        let claude = toggles.first { $0.identifier?.rawValue == "claude" }!
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
        print("PASS: login default once, opt-out persistence, approval state, native switches, Claude/Grok loading, update callback and stable full overlays")
    }
}
