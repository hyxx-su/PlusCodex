import Foundation
import UserNotifications

/// Reserve one OS sound at a time without bypassing macOS notification/Focus
/// preferences. Overlapping notifications still deliver their banner and text.
final class NotificationDelivery {
    static let shared = NotificationDelivery(defaults: .standard)
    private let lock = NSLock()
    private var sounds: [String: DateInterval] = [:]
    private var modifiedAt: [String: Date] = [:]
    private let defaults: UserDefaults?
    private let stateKey = "notificationSoundReservations.v1"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: stateKey),
           let saved = try? JSONDecoder().decode([String: DateInterval].self, from: data) {
            sounds = saved.filter { $0.value.end > Date() }
        }
    }

    private func save() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(sounds) { defaults.set(data, forKey: stateKey) }
    }

    func reserve(identifier: String, start: Date, duration: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock()
        defer { save(); lock.unlock() }
        sounds = sounds.filter { $0.value.end > now && $0.key != identifier }
        // Immediate notifications may run without a pending-request refresh.
        // Retire their metadata here as well so unique IDs cannot accumulate.
        modifiedAt = modifiedAt.filter { sounds[$0.key] != nil }
        let interval = DateInterval(start: start, duration: max(1, duration) + 0.5)
        guard !sounds.values.contains(where: { $0.start < interval.end && interval.start < $0.end }) else {
            return false
        }
        sounds[identifier] = interval
        modifiedAt[identifier] = Date()
        return true
    }

    func cancel(_ identifier: String) {
        lock.lock()
        sounds.removeValue(forKey: identifier)
        modifiedAt.removeValue(forKey: identifier)
        save()
        lock.unlock()
    }

    var testHookReservationMetadataCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return modifiedAt.count
    }

    func remember(_ requests: [UNNotificationRequest], defaultDuration: TimeInterval,
                  snapshotStartedAt: Date = Date()) {
        lock.lock()
        defer { save(); lock.unlock() }
        let now = Date()
        let ids = Set(requests.map(\.identifier))
        // Keep potentially playing sounds and additions newer than the OS query.
        // Only stale future reservations absent from the full snapshot are removed.
        sounds = sounds.filter { id, interval in
            interval.end > now && (interval.start <= now || ids.contains(id)
                || (modifiedAt[id] ?? .distantPast) >= snapshotStartedAt)
        }
        modifiedAt = modifiedAt.filter { sounds[$0.key] != nil }
        for request in requests where request.content.sound != nil {
            guard (modifiedAt[request.identifier] ?? .distantPast) < snapshotStartedAt else { continue }
            guard let start = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                ?? (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { continue }
            let duration = request.content.userInfo["plusCodexSoundDuration"] as? Double ?? defaultDuration
            sounds[request.identifier] = DateInterval(start: start, duration: max(1, duration) + 0.5)
        }
    }

    func add(_ request: UNNotificationRequest, duration: TimeInterval,
             completion: @escaping (Error?) -> Void) {
        let content = request.content.mutableCopy() as! UNMutableNotificationContent
        content.userInfo["plusCodexSoundDuration"] = duration
        let start = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            ?? (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? Date()
        if content.sound != nil,
           !reserve(identifier: request.identifier, start: start, duration: duration) {
            content.sound = nil
        }
        let prepared = UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger)
        UNUserNotificationCenter.current().add(prepared) { [weak self] error in
            if error != nil { self?.cancel(request.identifier) }
            completion(error)
        }
    }
}
