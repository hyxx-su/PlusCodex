import AppKit

@main struct NotificationAutoCleanupChecks {
    static func main() {
        _ = NSApplication.shared
        let suite = "PlusCodex.auto-cleanup.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotificationSettings(defaults: defaults)
        let base = Date(timeIntervalSince1970: 1_000_000)
        var clock = base
        typealias Entry = NotificationAutoCleanup.Entry
        var entries = [
            Entry(identifier: "history", deliveredAt: base.addingTimeInterval(-10), playbackDuration: 2),
            Entry(identifier: "fresh", deliveredAt: base.addingTimeInterval(1), playbackDuration: 5),
            Entry(identifier: "scheduled-late", deliveredAt: base.addingTimeInterval(10), playbackDuration: 15)
        ]
        var queries = 0
        var removed: [String] = []
        var deferred = false
        var pending: (([Entry]) -> Void)?
        var cleanup: NotificationAutoCleanup? = NotificationAutoCleanup(settings: settings, now: { clock },
            readDelivered: { since, completion in
                precondition(since == settings.autoCleanupStartedAt)
                queries += 1
                if deferred { pending = completion }
                else { completion(entries) }
            }, removeDelivered: { identifiers in
                removed += identifiers
                entries.removeAll { identifiers.contains($0.identifier) }
            })
        settings.onChange = { [weak service = cleanup] in service?.synchronize() }

        func drain() {
            let deadline = Date().addingTimeInterval(0.03)
            while Date() < deadline { RunLoop.main.run(until: deadline) }
        }
        func poll(at seconds: TimeInterval) {
            clock = base.addingTimeInterval(seconds)
            cleanup!.poll()
            drain()
        }

        precondition(!settings.autoCleanupEnabled && settings.autoCleanupStartedAt == nil)
        cleanup!.synchronize()
        cleanup!.poll()
        precondition(queries == 0, "OFF must not run an OS cleanup query")
        settings.setAutoCleanupEnabled(true, now: base)
        drain()
        precondition(removed.isEmpty)
        precondition(settings.autoCleanupStartedAt == base)
        precondition(NotificationSettings(defaults: defaults).autoCleanupStartedAt == base,
                     "Activation time must survive relaunch")
        settings.setAutoCleanupEnabled(true, now: base.addingTimeInterval(100))
        precondition(settings.autoCleanupStartedAt == base, "An unchanged toggle must not reset the cutoff")
        poll(at: 6.49)
        precondition(removed.isEmpty, "Playback and its grace period must finish before removal")
        poll(at: 6.5)
        precondition(removed == ["fresh"])
        poll(at: 25.49)
        precondition(removed == ["fresh"], "Use actual delivery time, not the scheduled trigger time")
        poll(at: 25.5)
        precondition(removed == ["fresh", "scheduled-late"])
        precondition(entries.map(\.identifier) == ["history"], "Existing history must never be swept")

        deferred = true
        cleanup!.poll()
        let queryCount = queries
        for _ in 0..<100 { cleanup!.poll() }
        precondition(queries == queryCount, "Only one OS query may be in flight")
        settings.setAutoCleanupEnabled(false)
        let oldQuery = pending!
        pending = nil
        oldQuery([Entry(identifier: "cancelled", deliveredAt: base, playbackDuration: 1)])
        drain()
        precondition(!removed.contains("cancelled"), "A late response after OFF must not delete anything")
        cleanup!.poll()
        precondition(queries == queryCount)
        precondition(NotificationSettings(defaults: defaults).autoCleanupStartedAt == nil)

        clock = base.addingTimeInterval(100)
        settings.setAutoCleanupEnabled(true, now: base.addingTimeInterval(30))
        let staleGeneration = pending!
        pending = nil
        settings.setAutoCleanupEnabled(false)
        settings.setAutoCleanupEnabled(true, now: base.addingTimeInterval(31))
        staleGeneration([Entry(identifier: "stale-generation", deliveredAt: base.addingTimeInterval(32),
                               playbackDuration: 2)])
        drain()
        precondition(!removed.contains("stale-generation"), "OFF/ON must invalidate the old query generation")
        entries += [
            Entry(identifier: "while-off", deliveredAt: base.addingTimeInterval(30), playbackDuration: 2),
            Entry(identifier: "after-on", deliveredAt: base.addingTimeInterval(32), playbackDuration: 2)
        ]
        deferred = false
        cleanup!.poll()
        drain()
        precondition(removed.last == "after-on" && !removed.contains("while-off"))

        let invalid = [Double.nan, Double.infinity, -1, 0, 16].enumerated().map { index, duration in
            Entry(identifier: "invalid-\(index)", deliveredAt: base, playbackDuration: duration)
        }
        precondition(NotificationAutoCleanup.expiredIdentifiers(in: invalid, since: base,
            now: base.addingTimeInterval(100)).isEmpty, "Malformed duration metadata must not cause early deletion")
        for duration in [1.0, 2, 5, 15] {
            let entry = Entry(identifier: "duration", deliveredAt: base, playbackDuration: duration)
            precondition(NotificationAutoCleanup.expiredIdentifiers(in: [entry], since: base,
                now: base.addingTimeInterval(duration + 0.49)).isEmpty)
            precondition(NotificationAutoCleanup.expiredIdentifiers(in: [entry], since: base,
                now: base.addingTimeInterval(duration + 0.5)) == ["duration"])
        }

        let beforeTimer = queries
        let timerDeadline = Date().addingTimeInterval(1.4)
        while queries == beforeTimer && Date() < timerDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        precondition(queries > beforeTimer, "Enabled cleanup must poll without a foreground-delivery callback")
        drain()
        settings.setAutoCleanupEnabled(false)
        let stoppedQueryCount = queries
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        precondition(queries == stoppedQueryCount, "OFF must invalidate the repeating timer")
        settings.setAutoCleanupEnabled(true, now: clock)
        drain()
        weak var releasedService: NotificationAutoCleanup?
        releasedService = cleanup
        cleanup = nil
        precondition(releasedService == nil, "The repeating timer must not retain the cleanup service")
        print("PASS: auto-cleanup defaults, persistence, duration, history, delayed delivery, OFF/ON races, single query, timer teardown")
    }
}
