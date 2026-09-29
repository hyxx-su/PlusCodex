import Foundation

final class ThreadNotificationPreferences {
    static let shared = ThreadNotificationPreferences()
    private let defaults: UserDefaults
    private let storageKey = "mutedTurnNotifications.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func scope(for activity: ThreadActivity) -> String? {
        guard let turnID = activity.latestTurn?.id, !turnID.isEmpty else { return nil }
        return "\(activity.id):\(turnID)"
    }

    func enabled(_ activity: ThreadActivity) -> Bool { enabled(scope: Self.scope(for: activity)) }

    func enabled(scope: String?) -> Bool {
        guard let scope else { return true }
        return !(defaults.stringArray(forKey: storageKey) ?? []).contains(scope)
    }

    func setEnabled(_ enabled: Bool, for activity: ThreadActivity) {
        // A chat-wide fallback would leak a mute into the next task. Wait for
        // a stable turn ID instead; old chat-wide preferences are not inherited.
        guard let scope = Self.scope(for: activity) else { return }
        var muted = Set(defaults.stringArray(forKey: storageKey) ?? [])
        if enabled { muted.remove(scope) } else { muted.insert(scope) }
        defaults.set(muted.sorted(), forKey: storageKey)
        NotificationCenter.default.post(name: .threadNotificationPreferenceChanged, object: activity.id)
    }
}
extension Notification.Name {
    static let threadNotificationPreferenceChanged = Notification.Name("threadNotificationPreferenceChanged")
}
