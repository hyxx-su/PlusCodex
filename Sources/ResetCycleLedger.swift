import Foundation

/// Accepted OS reservations are not proof of delivery. A deadline already
/// reached is consumed conservatively to avoid repeating a corrected cycle.
final class ResetCycleLedger {
    private struct Entry: Codable { let deadline: Double; let duration: Double }
    private let defaults: UserDefaults
    private let key = "resetCycleLedger.v1"
    private var entries: [String: Entry]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    private func identity(_ account: String, _ name: String) -> String {
        ThreadRecordScope.key(account) + ":" + name
    }
    func permits(account: String, name: String, deadline: Double, now: Double) -> Bool {
        guard let prior = entries[identity(account, name)], prior.deadline <= now else { return true }
        let tolerance = prior.duration <= 18000 ? 600 : max(3600, prior.duration * 0.1)
        return deadline - prior.deadline >= prior.duration - tolerance
    }
    func observeExisting(account: String, name: String, deadline: Double, duration: Double) {
        guard entries[identity(account, name)] == nil else { return }
        registered(account: account, name: name, deadline: deadline, duration: duration)
    }
    func registered(account: String, name: String, deadline: Double, duration: Double) {
        guard !account.isEmpty, deadline.isFinite, duration.isFinite, duration > 0 else { return }
        entries[identity(account, name)] = Entry(deadline: deadline, duration: duration)
        entries = entries.filter { $0.value.deadline > Date().timeIntervalSince1970 - 90 * 86400 }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
    func cancelFuture(account: String, name: String, deadline: Double, now: Double) {
        let id = identity(account, name)
        guard deadline > now, entries[id]?.deadline == deadline else { return }
        entries.removeValue(forKey: id)
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}
