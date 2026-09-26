import Foundation

enum AIProvider: String, CaseIterable {
    case codex, claude, grok
    var name: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude"; case .grok: return "Grok" }
    }
    var resource: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude"; case .grok: return "Grok" }
    }
}

final class ProviderSettings {
    private let defaults: UserDefaults
    // A persisted Grok preference is not proof that the current account still
    // provides a displayable quota. Revalidate once per app launch.
    private(set) var grokUsageVerified = false
    var onChange: (() -> Void)?
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var claudeShowRemaining: Bool {
        showRemaining(.claude)
    }
    func setClaudeShowRemaining(_ enabled: Bool) {
        setShowRemaining(enabled, for: .claude)
    }
    func showRemaining(_ provider: AIProvider) -> Bool {
        defaults.object(forKey: "provider.\(provider.rawValue).showRemaining") as? Bool ?? true
    }
    func setShowRemaining(_ enabled: Bool, for provider: AIProvider) {
        guard showRemaining(provider) != enabled else { return }
        defaults.set(enabled, forKey: "provider.\(provider.rawValue).showRemaining")
        onChange?()
    }
    func enabled(_ provider: AIProvider) -> Bool {
        // An unset provider starts enabled only for Codex; explicit choices persist.
        defaults.object(forKey: "provider.\(provider.rawValue).enabled") as? Bool ?? (provider == .codex)
    }
    func setEnabled(_ enabled: Bool, for provider: AIProvider) {
        guard self.enabled(provider) != enabled else { return }
        if provider == .grok && !enabled { grokUsageVerified = false }
        defaults.set(enabled, forKey: "provider.\(provider.rawValue).enabled")
        onChange?()
    }

    func setGrokUsageVerified(_ verified: Bool) {
        guard grokUsageVerified != verified else { return }
        grokUsageVerified = verified
        onChange?()
    }
}
