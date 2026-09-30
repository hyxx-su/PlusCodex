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

    struct Observation: Codable {
        let fetchedAt: Date
        let resetAt: Date
        let usedPercent: Double
    }

    var hasObservedUsage: Bool {
        get { defaults.bool(forKey: scoped("codexWake.hasObservedUsage")) }
        set { defaults.set(newValue, forKey: scoped("codexWake.hasObservedUsage")) }
    }

    var observation: Observation? {
        get {
            defaults.data(forKey: scoped("codexWake.observation.v1")).flatMap {
                try? JSONDecoder().decode(Observation.self, from: $0)
            }
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) },
                         forKey: scoped("codexWake.observation.v1"))
        }
    }

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
        static let account = "codexWake.account"
        static let completedResetAt = "codexWake.completedResetAt"
    }

    private let defaults: UserDefaults

    // Keep each account's ledger in its own namespace; chat history and user
    // preferences remain shared. Base64 avoids ambiguous separator keys.
    private func scoped(_ key: String, account: String? = nil) -> String {
        guard let identity = account ?? accountIdentity else { return key }
        return "codexWake.accounts.v2." + Data(identity.utf8).base64EncodedString() + "." + key
    }

    private static let ledgerKeys = [Key.lastAttemptAt, Key.completedResetAt,
        Key.nextAttemptAt, Key.scheduledResetAt, "codexWake.lastFailure", "codexWake.observation.v1"]

    func recordResult(account: String?, completedAt: Date?, cycle: Date,
                      failure: String?, retryAt: Date?) {
        guard let account else { return }
        defaults.set(failure, forKey: scoped("codexWake.lastFailure", account: account))
        if let completedAt {
            defaults.set(completedAt, forKey: scoped(Key.lastAttemptAt, account: account))
            defaults.set(cycle, forKey: scoped(Key.completedResetAt, account: account))
            for key in [Key.nextAttemptAt, Key.scheduledResetAt, "codexWake.observation.v1"] {
                defaults.removeObject(forKey: scoped(key, account: account))
            }
        } else if let retryAt {
            defaults.set(retryAt, forKey: scoped(Key.nextAttemptAt, account: account))
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let account = accountIdentity,
           !defaults.bool(forKey: scoped("migrated", account: account)) {
            for key in Self.ledgerKeys {
                if let value = defaults.object(forKey: key) {
                    defaults.set(value, forKey: scoped(key, account: account))
                }
            }
            defaults.set(true, forKey: scoped("migrated", account: account))
            if let observation, observation.usedPercent > 0 { hasObservedUsage = true }
        }
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
    var lastFailure: String? {
        get { defaults.string(forKey: scoped("codexWake.lastFailure")) }
        set { defaults.set(newValue, forKey: scoped("codexWake.lastFailure")) }
    }
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
    var lastAttemptAt: Date? { defaults.object(forKey: scoped(Key.lastAttemptAt)) as? Date }
    var completedResetAt: Date? { defaults.object(forKey: scoped(Key.completedResetAt)) as? Date }
    var accountIdentity: String? { defaults.string(forKey: Key.account) }
    var nextAttemptAt: Date? {
        get { defaults.object(forKey: scoped(Key.nextAttemptAt)) as? Date }
        set { defaults.set(newValue, forKey: scoped(Key.nextAttemptAt)) }
    }
    var scheduledResetAt: Date? {
        get { defaults.object(forKey: scoped(Key.scheduledResetAt)) as? Date }
        set { defaults.set(newValue, forKey: scoped(Key.scheduledResetAt)) }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        defaults.set(value, forKey: Key.enabled)
        lastFailure = nil
        observation = nil
        // Do not erase a possible in-flight reservation by toggling the feature.
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

    func selectAccount(_ identity: String) {
        defaults.set(identity, forKey: Key.account)
        defaults.set(true, forKey: scoped("migrated"))
    }

    func recordAttempt(at date: Date, cycleResetAt: Date? = nil) {
        lastFailure = nil
        observation = nil
        defaults.set(date, forKey: scoped(Key.lastAttemptAt))
        if let cycleResetAt { defaults.set(cycleResetAt, forKey: scoped(Key.completedResetAt)) }
        nextAttemptAt = cycleResetAt == nil ? date.addingTimeInterval(Self.interval) : nil
        scheduledResetAt = nil
    }

    func recordThreadID(_ value: String) { defaults.set(value, forKey: Key.threadID) }
}
