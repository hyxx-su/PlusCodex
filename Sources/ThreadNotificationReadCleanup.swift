import Foundation
import UserNotifications

/// Read acknowledgement is separate from timed cleanup and only affects task alerts.
/// Called on the main queue, like AppNotifications' other lifecycle operations.
final class ThreadNotificationReadCleanup {
    struct Entry {
        let identifier: String
        let userInfo: [AnyHashable: Any]
        let deliveredAt: Date
    }

    private let fetch: (@escaping ([Entry]) -> Void) -> Void
    private let remove: ([String]) -> Void
    private let now: () -> Date
    private var readScopes: [String: Date] = [:]
    private struct ReadTarget {
        let threadID: String
        let scope: String?
        let readAt: Date
    }
    private var pendingReads: [String: ReadTarget] = [:]
    private var queryScheduled = false

    init(now: @escaping () -> Date = Date.init,
         fetch: ((@escaping ([Entry]) -> Void) -> Void)? = nil,
         remove: (([String]) -> Void)? = nil) {
        self.now = now
        self.fetch = fetch ?? { completion in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                completion(notifications.map {
                    Entry(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo,
                          deliveredAt: $0.date)
                })
            }
        }
        self.remove = remove ?? {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0)
        }
    }

    func read(_ activity: ThreadActivity) {
        guard activity.stateConfirmed else { return }
        let readAt = now()
        let scope = ThreadNotificationPreferences.scope(for: activity)
        // Reading an active task must not suppress its eventual completion or a
        // later approval request. Only terminal turns are safe to acknowledge.
        if activity.runtime == "idle", !activity.isRunning, let scope {
            readScopes[scope] = readAt
            if readScopes.count > 512,
               let oldest = readScopes.min(by: { $0.value < $1.value })?.key {
                readScopes.removeValue(forKey: oldest)
            }
        }
        pendingReads[scope ?? activity.id] = ReadTarget(threadID: activity.id, scope: scope, readAt: readAt)
        scheduleQuery()
    }

    private func scheduleQuery() {
        guard !queryScheduled, !pendingReads.isEmpty else { return }
        queryScheduled = true
        // Initial snapshots can acknowledge many chats at once; query the OS
        // once per batch instead of once for every read-state event.
        DispatchQueue.main.async { [weak self] in self?.fetchPending() }
    }

    private func fetchPending() {
        let targets = Array(pendingReads.values)
        pendingReads.removeAll()
        fetch { [weak self] entries in
            DispatchQueue.main.async {
                guard let self else { return }
                let ids = entries.filter {
                    entry in targets.contains {
                        Self.matches(entry, threadID: $0.threadID, scope: $0.scope, readAt: $0.readAt)
                    }
                }.map(\.identifier)
                if !ids.isEmpty { self.remove(ids) }
                self.queryScheduled = false
                self.scheduleQuery()
            }
        }
    }

    func wasRead(_ request: UNNotificationRequest) -> Bool {
        guard let scope = request.content.userInfo["notificationScope"] as? String else { return false }
        return readScopes[scope] != nil
    }

    static func matches(_ entry: Entry, threadID: String, scope: String?, readAt: Date) -> Bool {
        guard entry.userInfo["threadID"] as? String == threadID,
              entry.deliveredAt <= readAt else { return false }
        if let entryScope = entry.userInfo["notificationScope"] as? String {
            // Without a stable turn ID, never delete a scoped alert speculatively.
            return scope == entryScope
        }
        // Pre-existing alerts without turn metadata may be removed by thread,
        // but never alerts delivered after the read acknowledgement.
        return true
    }
}
