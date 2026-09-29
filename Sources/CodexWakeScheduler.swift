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
        // A repeatedly revised forecast must not keep postponing a pending
        // wake. Earlier deadlines are useful; later ones belong to a future
        // cycle until this reservation has actually been processed.
        guard currentReset.timeIntervalSince(targetReset) < -1 else { return nil }
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
        let authRevision = CodexAuthRevision.current()
        // Reserve the slot before launching a worker. If the app crashes while
        // the request is in flight, a relaunch must not submit a duplicate.
        settings.nextAttemptAt = now.addingTimeInterval(CodexWakeSettings.interval)
        inFlight = true
        NSLog("PlusCodex wake started: scheduled=%.0f observed=%.0f",
              cycle.timeIntervalSince1970, now.timeIntervalSince1970)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var submissionStarted = false
            var submitted = false
            var shouldRetry = false
            var failureMessage: String?
            do {
                try CodexWakeClient.sendHello(modelID: modelID, effort: effort, message: message,
                                              previousThreadID: previousThreadID,
                                              shouldProceed: {
                                                  guard CodexAuthRevision.current() == authRevision else { return false }
                                                  return DispatchQueue.main.sync {
                                                      self?.settings.enabled == true && self?.settings.accountIdentity == accountIdentity
                                                  }
                                              },
                                              onThreadPrepared: {
                                                  let id = $0
                                                  DispatchQueue.main.sync {
                                                      if CodexAuthRevision.current() == authRevision,
                                                         self?.settings.accountIdentity == accountIdentity {
                                                          self?.settings.recordThreadID(id)
                                                      }
                                                  }
                                              },
                                              onTurnCompletedSuccessfully: {
                                                  submitted = true
                                                  NSLog("PlusCodex wake completed: scheduled=%.0f", cycle.timeIntervalSince1970)
                                                  DispatchQueue.main.sync {
                                                      if CodexAuthRevision.current() == authRevision,
                                                         self?.settings.accountIdentity == accountIdentity {
                                                          self?.settings.recordAttempt(at: Date(), cycleResetAt: cycle)
                                                      }
                                                  }
                                              },
                                              onTurnStartRequested: { submissionStarted = true },
                                              onModelResolved: {
                                                  let model = $0
                                                  DispatchQueue.main.sync {
                                                      if CodexAuthRevision.current() == authRevision,
                                                         self?.settings.accountIdentity == accountIdentity {
                                                          self?.settings.select(model)
                                                      }
                                                  }
                                              })
            } catch CodexWakeError.cancelled {
                // The user switched the feature off before the turn was sent.
            } catch {
                failureMessage = error.localizedDescription
                NSLog("PlusCodex wake message failed: %@", error.localizedDescription)
                let definiteRejection = (error as? CodexWakeError)?.isDefiniteServerRejection == true
                // A timeout or disconnect after sending is ambiguous: retrying
                // could duplicate a turn the server already accepted.
                shouldRetry = !submitted && (!submissionStarted || definiteRejection)
            }
            DispatchQueue.main.async {
                if CodexAuthRevision.current() == authRevision,
                   self?.settings.accountIdentity == accountIdentity {
                    self?.settings.lastFailure = failureMessage
                }
                if shouldRetry, self?.settings.enabled == true,
                   CodexAuthRevision.current() == authRevision,
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
        guard settings.enabled, !offline,
              quotaFetchedAt.map({ $0 <= now }) ?? true,
              let window = quota?.windows.first(where: { $0.windowDurationMins == 300 }),
              window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
              let seconds = window.resetsAt, seconds.isFinite else { return nil }
        let currentReset = Date(timeIntervalSince1970: seconds)
        let previous = settings.observation
        if let fetchedAt = quotaFetchedAt {
            guard now.timeIntervalSince(fetchedAt) <= 120,
                  previous.map({ fetchedAt.timeIntervalSince($0.fetchedAt) >= 30 }) ?? true else { return nil }
            settings.observation = .init(fetchedAt: fetchedAt, resetAt: currentReset,
                                         usedPercent: window.usedPercent)
        }
        // Recover the next deadline even if the Mac shut down immediately after
        // success, before another usage read could book it. A missed interval
        // results in one catch-up attempt, not a replay of every missed cycle.
        if settings.scheduledResetAt == nil, let lastAttempt = settings.lastAttemptAt {
            if settings.completedResetAt == nil, let legacyDue = settings.nextAttemptAt {
                settings.scheduledResetAt = legacyDue
            } else {
                // Prefer the observed active window after a successful send.
                // A local five-hour fallback only preserves recovery when no
                // active window has yet been observed (e.g. immediate shutdown).
                settings.scheduledResetAt = quotaFetchedAt != nil && window.usedPercent > 0 && currentReset > now
                    ? currentReset : lastAttempt.addingTimeInterval(CodexWakeSettings.interval)
            }
        }
        if settings.scheduledResetAt == nil {
            guard currentReset > (settings.completedResetAt ?? .distantPast),
                  currentReset > (settings.lastAttemptAt ?? .distantPast),
                  currentReset.timeIntervalSince(now) > -CodexWakeSettings.interval else { return nil }
            settings.scheduledResetAt = currentReset
        } else if currentReset > (settings.completedResetAt ?? .distantPast),
                  currentReset > (settings.lastAttemptAt ?? .distantPast),
                  let revised = CodexWakeSchedule.revisedReset(
            now: now, targetReset: settings.scheduledResetAt, currentReset: currentReset) {
            settings.scheduledResetAt = revised
        }
        guard let cycle = settings.scheduledResetAt else { return nil }
        let due = max(cycle, settings.nextAttemptAt ?? .distantPast,
                      settings.lastAttemptAt?.addingTimeInterval(CodexWakeSettings.interval) ?? .distantPast)
        // A newer, stable deadline with usage means another client may have
        // already started the next cycle. Do not spend quota waking it again.
        // Keep retry/in-flight reservations intact even when adopting that cycle.
        if let fetchedAt = quotaFetchedAt, let previous,
           previous.fetchedAt >= cycle, fetchedAt.timeIntervalSince(previous.fetchedAt) >= 30,
           previous.usedPercent > 0, window.usedPercent > 0,
           currentReset > now, currentReset > cycle,
           abs(currentReset.timeIntervalSince(previous.resetAt)) <= 1 {
            settings.scheduledResetAt = currentReset
            return nil
        }
        // Zero can be rounded or temporarily stale. Require two separate fresh
        // reads after the deadline, with a future reset, rather than treating
        // any available balance as proof that the previous cycle ended.
        guard CodexWakeSchedule.shouldSubmit(now: now, due: due, targetReset: cycle,
                                             currentReset: currentReset, fetchedAt: quotaFetchedAt) else { return nil }
        guard let fetchedAt = quotaFetchedAt, let previous,
              previous.fetchedAt >= due,
              fetchedAt.timeIntervalSince(previous.fetchedAt) >= 30,
              previous.usedPercent == 0, window.usedPercent == 0,
              previous.resetAt > previous.fetchedAt, currentReset > now else { return nil }
        guard quota?.windows.allSatisfy({
            $0.usedPercent.isFinite && $0.usedPercent >= 0 && $0.usedPercent < 100
        }) == true else { return nil }
        return cycle
    }
}
