import AppKit

@main
struct UsageDisplayChecks {
    static func main() {
        let suite = "PlusCodex.UsageDisplayChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ProviderSettings(defaults: defaults)
        assert(settings.claudeShowRemaining)
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.setClaudeShowRemaining(false)
        settings.setClaudeShowRemaining(false)
        assert(changes == 1)
        assert(!ProviderSettings(defaults: defaults).claudeShowRemaining)
        assert(settings.showRemaining(.codex) && settings.showRemaining(.grok))
        settings.setShowRemaining(false, for: .codex)
        assert(!settings.showRemaining(.codex) && settings.showRemaining(.grok))
        settings.setShowRemaining(false, for: .grok)
        settings.setShowRemaining(true, for: .claude)
        let restored = ProviderSettings(defaults: defaults)
        assert(restored.showRemaining(.claude))
        assert(!restored.showRemaining(.codex) && !restored.showRemaining(.grok))
        for used in [0.0, 45, 69, 100, 110, -1, 36.8] {
            let window = QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: nil)
            assert(window.displayPercent(showRemaining: true) == window.remaining)
            assert(window.displayPercent(showRemaining: false) == Int(max(0, min(100, used)).rounded(.down)))
            assert(window.usedPercent == used)
        }
        _ = NSApplication.shared
        let quota = Quota(primary: QuotaWindow(usedPercent: 45, windowDurationMins: 300, resetsAt: nil), secondary: nil)
        let remaining = QuotaMenuView(quota: quota, updatedAt: nil, failure: nil, provider: .claude)
        let used = QuotaMenuView(quota: quota, updatedAt: nil, failure: nil, provider: .claude, showRemaining: false)
        assert(remaining.accessibilityLabel()?.contains("55%") == true)
        assert(used.accessibilityLabel()?.contains("45%") == true)
        assert(used.accessibilityLabel()?.contains("사용됨") == true)
        print("PASS: display inversion, persistence, bounds, accessibility, unchanged raw usage")
    }
}
