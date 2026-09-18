import AppKit

@main struct ProviderChecks {
    static func main() throws {
        _ = NSApplication.shared
        let suite = "PlusCodex.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ProviderSettings(defaults: defaults)
        precondition(AIProvider.allCases.allSatisfy(settings.enabled))
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.setEnabled(false, for: .claude)
        settings.setEnabled(false, for: .claude)
        precondition(changes == 1 && settings.enabled(.codex) && settings.enabled(.grok))
        precondition(!ProviderSettings(defaults: defaults).enabled(.claude))
        settings.setEnabled(true, for: .claude)
        precondition(changes == 2)

        precondition(ExternalUsageClient.number(true) == nil)
        precondition(ExternalUsageClient.number("nan") == nil)
        precondition(ExternalUsageClient.number(Double.infinity) == nil)
        precondition(ExternalUsageClient.timestamp(1_800_000_000_000) == 1_800_000_000)
        precondition(ExternalUsageClient.timestamp("2026-09-18T00:00:00.000Z") != nil)
        let claude = try ExternalUsageClient.parseClaude([
            "five_hour": ["utilization": 25], "seven_day": ["utilization": 50],
            "seven_day_sonnet": ["utilization": 75], "seven_day_opus": NSNull()])
        precondition(claude.windows.map(\.remaining) == [75, 50, 25])
        precondition(claude.windows.map(\.label) == ["5시간", "주간", "Sonnet 주간"])
        let scoped = try ExternalUsageClient.parseClaude(["limits": [
            ["kind": "weekly_scoped", "percent": 12, "scope": ["model": ["display_name": "Opus"]]]]])
        precondition(scoped.primary?.label == "Opus 주간")
        do { _ = try ExternalUsageClient.parseClaude([:]); preconditionFailure("Missing is not zero") }
        catch is UsageFailure {}
        precondition(ExternalUsageClient.parseGrok([:]) == nil)
        precondition(ExternalUsageClient.parseGrok(["creditUsagePercent": NSNull()]) == nil)
        let weekly = ExternalUsageClient.parseGrok(["config": ["creditUsagePercent": 30,
            "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY"]]])!
        precondition(weekly.primary?.label == "주간" && weekly.primary?.remaining == 70)
        let monthly = ExternalUsageClient.parseGrok(["used": ["val": "20"], "monthlyLimit": ["val": "100"]])!
        precondition(monthly.primary?.label == "1개월" && monthly.primary?.remaining == 80)
        precondition(ExternalUsageClient.parseGrok(["used": ["val": 1], "monthlyLimit": ["val": 0]]) == nil)
        precondition(ExternalUsageClient.parseGrok(["used": ["val": 1e300], "monthlyLimit": ["val": 1e-300]])?.primary?.remaining == 0)
        precondition(ExternalUsageClient.grokSession(["https://unknown.example": ["key": "test"]]) == nil)
        precondition(ExternalUsageClient.grokSession(["https://auth.x.ai": ["key": "test", "expires_at": 1000]]) == nil)
        precondition(ExternalUsageClient.grokSession(["https://auth.x.ai": ["key": "test", "expires_at": 9_000_000_000]]) != nil)
        for provider in AIProvider.allCases {
            precondition(CodexStatusIcon.image(size: 18, offline: false, provider: provider) != nil)
        }
        let panel = QuotaMenuView(quota: claude, updatedAt: nil, failure: nil, provider: .claude)
        precondition(panel.accessibilityLabel()!.contains("Claude Code"))
        precondition(panel.accessibilityLabel()!.contains("Sonnet 주간"))
        precondition(panel.accessibilityLabel()!.contains("5시간"))
        let window = AISettingsWindow(settings: settings)
        let checks = window.window!.contentView!.subviews.compactMap { $0 as? NSSwitch }
            .filter { $0.identifier?.rawValue != "launchAtLogin" }
        precondition(checks.count == 3 && checks.allSatisfy { $0.state == .on })
        if let path = ProcessInfo.processInfo.environment["PLUSCODEX_PREVIEW"] {
            window.window!.appearance = NSAppearance(named: .aqua)
            let view = window.window!.contentView!
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            view.bounds.fill()
            let content = NSImage(size: view.bounds.size)
            content.addRepresentation(bitmap)
            content.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1)
            image.unlockFocus()
            let opaque = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try opaque.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        print("PASS: provider defaults, persistence, independent settings, usage parsing, missing/invalid data, expiry, logos, settings UI")
    }
}
