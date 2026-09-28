import Foundation

enum CodexWakeSchedule {
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
        guard now >= due, let targetReset, now >= targetReset,
              let currentReset, currentReset.timeIntervalSince1970.isFinite,
              let fetchedAt, fetchedAt >= due, fetchedAt <= now else { return false }
        // A future timestamp may already describe the next cycle. It must not
        // cancel an overdue wake. The caller separately checks available quota.
        return true
    }

    static func revisedReset(now: Date, targetReset: Date?, currentReset: Date?) -> Date? {
        guard let currentReset else { return nil }
        guard let targetReset else { return currentReset }
        guard now < targetReset else { return nil }
        guard abs(currentReset.timeIntervalSince(targetReset)) > 1 else { return nil }
        return currentReset
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
        guard let cycle = prepareAttempt(quota: quota, offline: offline,
                                         quotaFetchedAt: quotaFetchedAt, now: now) else { return }

        let modelID = settings.modelID
        let effort = settings.effort
        let message = settings.message
        let previousThreadID = settings.threadID
        let accountIdentity = settings.accountIdentity
        // Reserve the slot before launching a worker. If the app crashes while
        // the request is in flight, a relaunch must not submit a duplicate.
        settings.nextAttemptAt = now.addingTimeInterval(CodexWakeSettings.interval)
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var submissionStarted = false
            var submitted = false
            var shouldRetry = false
            do {
                try CodexWakeClient.sendHello(modelID: modelID, effort: effort, message: message,
                                              previousThreadID: previousThreadID,
                                              shouldProceed: {
                                                  self?.settings.enabled == true && self?.settings.accountIdentity == accountIdentity
                                              },
                                              onThreadPrepared: {
                                                  if self?.settings.accountIdentity == accountIdentity {
                                                      self?.settings.recordThreadID($0)
                                                  }
                                              },
                                              onTurnSubmission: {
                                                  submitted = true
                                                  DispatchQueue.main.sync {
                                                      if self?.settings.accountIdentity == accountIdentity {
                                                          self?.settings.recordAttempt(at: Date(), cycleResetAt: cycle)
                                                      }
                                                  }
                                              },
                                              onTurnStartRequested: { submissionStarted = true },
                                              onModelResolved: {
                                                  if self?.settings.accountIdentity == accountIdentity {
                                                      self?.settings.select($0)
                                                  }
                                              })
            } catch CodexWakeError.cancelled {
                // The user switched the feature off before the turn was sent.
            } catch {
                NSLog("PlusCodex wake message failed: %@", error.localizedDescription)
                let definiteRejection = (error as? CodexWakeError)?.isDefiniteServerRejection == true
                // A timeout or disconnect after sending is ambiguous: retrying
                // could duplicate a turn the server already accepted.
                shouldRetry = !submitted && (!submissionStarted || definiteRejection)
            }
            DispatchQueue.main.async {
                if shouldRetry, self?.settings.enabled == true,
                   self?.settings.accountIdentity == accountIdentity {
                    // A known pre-submission failure used no model quota; retry
                    // later without repeatedly starting Codex every minute.
                    self?.settings.nextAttemptAt = Date().addingTimeInterval(15 * 60)
                }
                self?.inFlight = false
            }
        }
    }

    /// Planning is synchronous and transport-free. The cycle deadline and the
    /// retry/reservation date are independent, persisted values.
    func prepareAttempt(quota: Quota?, offline: Bool, quotaFetchedAt: Date?, now: Date) -> Date? {
        guard settings.enabled, !offline, let fetchedAt = quotaFetchedAt, fetchedAt <= now,
              let window = quota?.windows.first(where: { $0.windowDurationMins == 300 }),
              let seconds = window.resetsAt, seconds.isFinite else { return nil }
        let currentReset = Date(timeIntervalSince1970: seconds)
        // Older versions stored the next cycle only as a five-hour fallback
        // after success. Recover that pending cycle before reading a newer one.
        if settings.scheduledResetAt == nil, settings.completedResetAt == nil,
           settings.lastAttemptAt != nil, let legacyDue = settings.nextAttemptAt {
            settings.scheduledResetAt = legacyDue
        }
        if settings.scheduledResetAt == nil {
            guard currentReset > (settings.completedResetAt ?? .distantPast),
                  currentReset > (settings.lastAttemptAt ?? .distantPast),
                  currentReset.timeIntervalSince(now) > -CodexWakeSettings.interval else { return nil }
            settings.scheduledResetAt = currentReset
        } else if let revised = CodexWakeSchedule.revisedReset(
            now: now, targetReset: settings.scheduledResetAt, currentReset: currentReset) {
            settings.scheduledResetAt = revised
        }
        guard let cycle = settings.scheduledResetAt else { return nil }
        let due = max(cycle, settings.nextAttemptAt ?? .distantPast,
                      settings.lastAttemptAt?.addingTimeInterval(CodexWakeSettings.interval) ?? .distantPast)
        guard window.usedPercent.isFinite, window.usedPercent >= 0, window.usedPercent < 100,
              CodexWakeSchedule.shouldSubmit(now: now, due: due, targetReset: cycle,
                                             currentReset: currentReset, fetchedAt: fetchedAt) else { return nil }
        return cycle
    }
}
