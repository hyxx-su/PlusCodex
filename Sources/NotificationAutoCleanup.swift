import Foundation
import UserNotifications

/// Cleans up delivered native notifications without changing OS sound playback
/// or pending requests. All mutable state is confined to the main thread.
final class NotificationAutoCleanup {
    struct Entry {
        let identifier: String
        let deliveredAt: Date
        let playbackDuration: TimeInterval

        init(identifier: String, deliveredAt: Date, playbackDuration: TimeInterval) {
            self.identifier = identifier
            self.deliveredAt = deliveredAt
            self.playbackDuration = playbackDuration
        }

        init?(_ notification: UNNotification) {
            // This metadata is attached by NotificationDelivery to every managed
            // immediate/scheduled notification, including overlapping silent ones.
            guard let duration = notification.request.content.userInfo["plusCodexSoundDuration"] as? NSNumber else {
                return nil
            }
            self.init(identifier: notification.request.identifier,
                      deliveredAt: notification.date, playbackDuration: duration.doubleValue)
        }
    }

    static let playbackGrace: TimeInterval = 0.5
    private let settings: NotificationSettings
    private let now: () -> Date
    private let readDelivered: (Date, @escaping ([Entry]) -> Void) -> Void
    private let removeDelivered: ([String]) -> Void
    private var timer: Timer?
    private var activeSince: Date?
    private var generation = 0
    private var queryInFlight = false

    init(settings: NotificationSettings, now: @escaping () -> Date = Date.init,
         readDelivered: ((Date, @escaping ([Entry]) -> Void) -> Void)? = nil,
         removeDelivered: (([String]) -> Void)? = nil) {
        self.settings = settings
        self.now = now
        self.readDelivered = readDelivered ?? { since, completion in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                // Do not allocate/retain projected entries for historical records
                // that are outside this activation, especially across main-queue delays.
                completion(notifications.compactMap { notification in
                    notification.date >= since ? Entry(notification) : nil
                })
            }
        }
        self.removeDelivered = removeDelivered ?? { identifiers in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    deinit { timer?.invalidate() }

    func synchronize() {
        precondition(Thread.isMainThread)
        let since = settings.autoCleanupStartedAt
        guard since != activeSince else { return }
        generation += 1
        activeSince = since
        timer?.invalidate()
        timer = nil
        guard since != nil else { return }

        // One timer and one OS query at a time avoid per-notification timers and
        // retained snapshots. Common modes also cover an open menu/settings panel.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.2
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    func poll() {
        precondition(Thread.isMainThread)
        guard let since = activeSince, !queryInFlight else { return }
        let queryGeneration = generation
        queryInFlight = true
        readDelivered(since) { [weak self] entries in
            DispatchQueue.main.async {
                guard let self else { return }
                self.queryInFlight = false
                // An OFF/ON change invalidates a query even if it returns late.
                guard self.generation == queryGeneration,
                      self.activeSince == since,
                      self.settings.autoCleanupStartedAt == since else { return }
                let identifiers = Self.expiredIdentifiers(in: entries, since: since, now: self.now())
                if !identifiers.isEmpty { self.removeDelivered(identifiers) }
            }
        }
    }

    static func expiredIdentifiers(in entries: [Entry], since: Date, now: Date) -> [String] {
        entries.compactMap { entry in
            guard !entry.identifier.isEmpty,
                  entry.playbackDuration.isFinite,
                  (NotificationSettings.minimumSoundDuration...NotificationSettings.maximumSoundDuration)
                    .contains(entry.playbackDuration),
                  entry.deliveredAt >= since,
                  now.timeIntervalSince(entry.deliveredAt) >= entry.playbackDuration + playbackGrace else {
                return nil
            }
            return entry.identifier
        }
    }
}
