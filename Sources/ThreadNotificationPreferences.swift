import Foundation

final class ThreadNotificationPreferences {
    static let shared = ThreadNotificationPreferences()
    private let defaults: UserDefaults
    private let storageKey = "mutedTurnNotifications.v1"
    private let overridesKey = "turnNotificationOverrides.v2"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func scope(for activity: ThreadActivity) -> String? {
        guard let turnID = activity.latestTurn?.id, !turnID.isEmpty else { return nil }
        return "\(activity.id):\(turnID)"
    }

    func enabled(_ activity: ThreadActivity) -> Bool { enabled(scope: Self.scope(for: activity)) }

    func enabled(scope: String?) -> Bool {
        if let scope {
            if let selected = overrides[scope] { return selected }
            // Preserve pre-existing per-turn mutes without converting them to
            // chat-wide preferences or inferring an explicit ON from absence.
            if (defaults.stringArray(forKey: storageKey) ?? []).contains(scope) { return false }
        }
        return NotificationSettings.isEnabled(.completion, defaults: defaults)
    }

    private var overrides: [String: Bool] {
        defaults.dictionary(forKey: overridesKey) as? [String: Bool] ?? [:]
    }

    var hasEnabledOverrides: Bool { overrides.values.contains(true) }

    func setEnabled(_ enabled: Bool, for activity: ThreadActivity) {
        // A chat-wide fallback would leak a mute into the next task. Wait for
        // a stable turn ID instead; old chat-wide preferences are not inherited.
        guard let scope = Self.scope(for: activity) else { return }
        var selected = overrides
        guard selected[scope] != enabled else { return }
        // Store the user's choice even when it currently matches the default.
        // Keeping this in one dictionary prevents contradictory ON/OFF records.
        selected[scope] = enabled
        defaults.set(selected, forKey: overridesKey)
        NotificationCenter.default.post(name: .threadNotificationPreferenceChanged, object: activity.id)
    }
}
extension Notification.Name {
    static let threadNotificationPreferenceChanged = Notification.Name("threadNotificationPreferenceChanged")
}
