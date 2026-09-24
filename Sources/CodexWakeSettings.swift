import Foundation

struct CodexWakeModel: Decodable, Equatable {
    struct ReasoningEffort: Decodable, Equatable {
        let reasoningEffort: String
    }

    let id: String
    let model: String?
    let displayName: String
    let defaultReasoningEffort: String?
    let supportedReasoningEfforts: [ReasoningEffort]
    let hidden: Bool?

    var modelName: String { model ?? id }

    var wakeEffort: String? {
        supportedReasoningEfforts.contains(where: { $0.reasoningEffort == "low" }) ? "low" : nil
    }

    static func availableForWake(_ models: [CodexWakeModel], account: CodexWakeAccount) -> [CodexWakeModel] {
        models.filter { model in
            model.hidden != true && model.wakeEffort != nil
                && (!account.lunaOnly || model.id == "gpt-6-luna")
        }
    }
}

struct CodexWakeAccount: Equatable {
    let type: String
    let planType: String?

    var lunaOnly: Bool {
        guard type == "chatgpt" else { return false }
        let plan = planType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // Free and Go currently receive Luna on desktop. An unknown ChatGPT
        // plan must not expose paid-only models from a stale catalog.
        return plan.isEmpty || plan == "unknown" || plan == "free" || plan == "go"
    }
}

/// Persists only user choices and the minimum scheduling state needed to avoid
/// resending a wake message after relaunch or a sleep/wake cycle.
final class CodexWakeSettings {
    static let interval: TimeInterval = 5 * 60 * 60

    private enum Key {
        static let enabled = "codexWake.enabled"
        static let modelID = "codexWake.modelID"
        static let modelName = "codexWake.modelName"
        static let displayName = "codexWake.displayName"
        static let effort = "codexWake.effort"
        static let message = "codexWake.message"
        static let wakeUpDefaultApplied = "codexWake.wakeUpDefaultApplied"
        static let threadID = "codexWake.threadID"
        static let lastAttemptAt = "codexWake.lastAttemptAt"
        static let nextAttemptAt = "codexWake.nextAttemptAt"
        static let scheduledResetAt = "codexWake.scheduledResetAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if !defaults.bool(forKey: Key.wakeUpDefaultApplied) {
            // Older builds saved their initial "안녕" value even when the user
            // only closed Settings. Treat that legacy value as the old default.
            if defaults.string(forKey: Key.message) == "안녕" {
                defaults.removeObject(forKey: Key.message)
            }
            defaults.set(true, forKey: Key.wakeUpDefaultApplied)
        }
    }

    var enabled: Bool { defaults.bool(forKey: Key.enabled) }
    var modelID: String { defaults.string(forKey: Key.modelID) ?? "gpt-6-luna" }
    var modelName: String { defaults.string(forKey: Key.modelName) ?? "gpt-6-luna" }
    var displayName: String { defaults.string(forKey: Key.displayName) ?? "GPT-6 Luna" }
    var message: String {
        let saved = defaults.string(forKey: Key.message)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.flatMap { $0.isEmpty ? nil : $0 } ?? "Wake up"
    }
    // Ignore a previously saved Medium/High choice from older builds.
    var effort: String { "low" }
    var threadID: String? { defaults.string(forKey: Key.threadID) }
    var lastAttemptAt: Date? { defaults.object(forKey: Key.lastAttemptAt) as? Date }
    var nextAttemptAt: Date? {
        get { defaults.object(forKey: Key.nextAttemptAt) as? Date }
        set { defaults.set(newValue, forKey: Key.nextAttemptAt) }
    }
    var scheduledResetAt: Date? {
        get { defaults.object(forKey: Key.scheduledResetAt) as? Date }
        set { defaults.set(newValue, forKey: Key.scheduledResetAt) }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        defaults.set(value, forKey: Key.enabled)
        // Re-evaluate the current five-hour window when re-enabled, but retain
        // the last attempt so switching off and on cannot send twice at once.
        nextAttemptAt = nil
        scheduledResetAt = nil
    }

    @discardableResult
    func setMessage(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return false }
        defaults.set(trimmed, forKey: Key.message)
        return true
    }

    func select(_ model: CodexWakeModel) {
        guard let effort = model.wakeEffort else { return }
        defaults.set(model.id, forKey: Key.modelID)
        defaults.set(model.modelName, forKey: Key.modelName)
        defaults.set(model.displayName, forKey: Key.displayName)
        defaults.set(effort, forKey: Key.effort)
    }

    func recordAttempt(at date: Date) {
        defaults.set(date, forKey: Key.lastAttemptAt)
        nextAttemptAt = date.addingTimeInterval(Self.interval)
        scheduledResetAt = nil
    }

    func recordThreadID(_ value: String) { defaults.set(value, forKey: Key.threadID) }
}
