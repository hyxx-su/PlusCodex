import Foundation

enum AIProvider: String, CaseIterable {
    case codex, claude, grok
    var name: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude Code"; case .grok: return "Grok" }
    }
    var resource: String {
        switch self { case .codex: return "Codex"; case .claude: return "Claude"; case .grok: return "Grok" }
    }
}

final class ProviderSettings {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func enabled(_ provider: AIProvider) -> Bool {
        // Missing preferences also covers upgrading an existing Codex-only installation.
        defaults.object(forKey: "provider.\(provider.rawValue).enabled") as? Bool ?? true
    }
    func setEnabled(_ enabled: Bool, for provider: AIProvider) {
        guard self.enabled(provider) != enabled else { return }
        defaults.set(enabled, forKey: "provider.\(provider.rawValue).enabled")
        onChange?()
    }
}
