import Foundation

enum CodexWakeSchedule {
    static let confirmationGrace: TimeInterval = 2 * 60

    static func resetDate(now: Date, lastAttemptAt: Date?, quota: Quota?) -> Date? {
        guard let window = quota?.windows.first(where: { $0.windowDurationMins == 300 }),
              let seconds = window.resetsAt, seconds.isFinite else { return nil }
        let reset = Date(timeIntervalSince1970: seconds)
        guard reset > (lastAttemptAt ?? .distantPast),
              reset.timeIntervalSince(now) > -CodexWakeSettings.interval else { return nil }
        return reset
    }

    static func initialDate(now: Date, lastAttemptAt: Date?, quota: Quota?) -> Date {
        let earliest = max(now, lastAttemptAt?.addingTimeInterval(CodexWakeSettings.interval) ?? now)
        guard let reset = resetDate(now: now, lastAttemptAt: lastAttemptAt, quota: quota) else { return earliest }
        return max(earliest, reset)
    }

    static func shouldSubmit(now: Date, due: Date, targetReset: Date?,
                             currentReset: Date?, fetchedAt: Date?) -> Bool {
        guard now >= due, let fetchedAt, fetchedAt >= due, fetchedAt <= now else { return false }
        guard let targetReset else { return true }
        if let currentReset, currentReset > targetReset,
           !isNextCycle(currentReset, after: targetReset) {
            // A forward correction is not evidence of a completed cycle.
            return false
        }
        let confirmed = currentReset.map { isNextCycle($0, after: targetReset) } ?? false
        // An unchanged reset timestamp is inconclusive, not proof that the
        // account has not reset: the server may update it only after a turn.
        return confirmed || now.timeIntervalSince(due) >= confirmationGrace
    }

    static func revisedReset(now: Date, targetReset: Date?, currentReset: Date?) -> Date? {
        guard let currentReset else { return nil }
        guard let targetReset else { return currentReset }
        guard abs(currentReset.timeIntervalSince(targetReset)) > 1 else { return nil }
        // A full five-hour jump after the due time denotes the next cycle;
        // other changes correct the current cycle's deadline.
        if now < targetReset || !isNextCycle(currentReset, after: targetReset) {
            return currentReset
        }
        return nil
    }

    private static func isNextCycle(_ currentReset: Date, after targetReset: Date) -> Bool {
        abs(currentReset.timeIntervalSince(targetReset) - CodexWakeSettings.interval) <= 10 * 60
    }
}

/// All entry points run on the main thread. The potentially slow Codex process
/// runs on a worker queue, while a persisted attempt time prevents duplicates.
final class CodexWakeScheduler {
    private let settings: CodexWakeSettings
    private var inFlight = false

    init(settings: CodexWakeSettings) { self.settings = settings }

    /// `quotaFetchedAt` is supplied only by a completed rate-limit read. Timer
    /// ticks may plan a wake, but must never submit using cached usage data.
    func tick(quota: Quota?, offline: Bool, quotaFetchedAt: Date? = nil, now: Date = Date()) {
        guard settings.enabled, !offline, !inFlight else { return }
        if settings.nextAttemptAt == nil {
            settings.scheduledResetAt = CodexWakeSchedule.resetDate(
                now: now, lastAttemptAt: settings.lastAttemptAt, quota: quota)
            settings.nextAttemptAt = CodexWakeSchedule.initialDate(
                now: now, lastAttemptAt: settings.lastAttemptAt, quota: quota)
        }
        // Only a completed usage read may correct a persisted reset deadline.
        // Timer ticks use cached quota solely to plan the initial attempt.
        let currentReset: Date? = quotaFetchedAt.flatMap { fetchedAt in
            guard fetchedAt <= now else { return nil }
            return CodexWakeSchedule.resetDate(now: now, lastAttemptAt: settings.lastAttemptAt, quota: quota)
        }
        // After a prior wake, the persisted five-hour fallback is also a
        // cycle deadline. A fresh reset date one full cycle beyond it means
        // this cycle elapsed; it must not postpone the pending wake.
        let targetReset = settings.scheduledResetAt
            ?? (settings.lastAttemptAt != nil ? settings.nextAttemptAt : nil)
        if let revised = CodexWakeSchedule.revisedReset(
            now: now, targetReset: targetReset, currentReset: currentReset),
           settings.nextAttemptAt != nil {
            settings.scheduledResetAt = revised
            let earliest = settings.lastAttemptAt?.addingTimeInterval(CodexWakeSettings.interval) ?? .distantPast
            settings.nextAttemptAt = max(revised, earliest)
        }
        guard let due = settings.nextAttemptAt, now >= due else { return }
        guard let fetchedAt = quotaFetchedAt, fetchedAt >= due, fetchedAt <= now else { return }
        let confirmedTarget = settings.scheduledResetAt
            ?? (settings.lastAttemptAt != nil ? settings.nextAttemptAt : nil)
        guard CodexWakeSchedule.shouldSubmit(now: now, due: due,
                                             targetReset: confirmedTarget,
                                             currentReset: currentReset,
                                             fetchedAt: fetchedAt) else { return }

        let modelID = settings.modelID
        let effort = settings.effort
        let message = settings.message
        let previousThreadID = settings.threadID
        // Reserve the slot before launching a worker. If the app crashes while
        // the request is in flight, a relaunch must not submit a duplicate.
        settings.nextAttemptAt = now.addingTimeInterval(CodexWakeSettings.interval)
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var submitted = false
            var shouldRetry = false
            do {
                try CodexWakeClient.sendHello(modelID: modelID, effort: effort, message: message,
                                              previousThreadID: previousThreadID,
                                              shouldProceed: { self?.settings.enabled == true },
                                              onThreadPrepared: { self?.settings.recordThreadID($0) },
                                              onTurnSubmission: {
                                                  submitted = true
                                                  DispatchQueue.main.sync {
                                                      self?.settings.recordAttempt(at: Date())
                                                  }
                                              },
                                              onModelResolved: { self?.settings.select($0) })
            } catch CodexWakeError.cancelled {
                // The user switched the feature off before the turn was sent.
            } catch {
                NSLog("PlusCodex wake message failed: %@", error.localizedDescription)
                shouldRetry = !submitted
            }
            DispatchQueue.main.async {
                if shouldRetry, self?.settings.enabled == true {
                    // A known pre-submission failure used no model quota; retry
                    // later without repeatedly starting Codex every minute.
                    self?.settings.nextAttemptAt = Date().addingTimeInterval(15 * 60)
                }
                self?.inFlight = false
            }
        }
    }
}
