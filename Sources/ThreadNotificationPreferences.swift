import Foundation

final class ThreadNotificationPreferences {
    static let shared = ThreadNotificationPreferences()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func enabled(_ id: String) -> Bool {
        !(defaults.stringArray(forKey: "mutedThreadNotifications") ?? []).contains(id)
    }
    func setEnabled(_ enabled: Bool, for id: String) {
        var muted = Set(defaults.stringArray(forKey: "mutedThreadNotifications") ?? [])
        if enabled { muted.remove(id) } else { muted.insert(id) }
        defaults.set(muted.sorted(), forKey: "mutedThreadNotifications")
        NotificationCenter.default.post(name: .threadNotificationPreferenceChanged, object: id)
    }
}
extension Notification.Name {
    static let threadNotificationPreferenceChanged = Notification.Name("threadNotificationPreferenceChanged")
}
