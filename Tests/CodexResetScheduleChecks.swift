import Foundation

@main struct CodexResetScheduleChecks {
    static func main() {
        let suite = "PlusCodex.ResetScheduleChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let due = base.addingTimeInterval(600)
        let account = CodexAccount(email: "schedule-test@example.invalid", planType: "plus")
        func quota(_ date: Date, used: Double = 20) -> Quota {
            Quota(primary: QuotaWindow(usedPercent: used, windowDurationMins: 300,
                                       resetsAt: date.timeIntervalSince1970), secondary: nil)
        }
        let schedule = CodexResetSchedule(defaults: defaults)
        _ = schedule.update(quota(due), account: account, now: base)
        let wake = CodexWakeSettings(defaults: defaults)
        wake.setEnabled(true)
        wake.selectAccount(account.email!)
        let scheduler = CodexWakeScheduler(settings: wake)
        _ = scheduler.prepareAttempt(quota: quota(due), offline: false, quotaFetchedAt: base, now: base)
        for minute in 1...9 {
            let now = base.addingTimeInterval(Double(minute) * 60)
            let stable = schedule.update(quota(due.addingTimeInterval(Double(minute) * 60)),
                                         account: account, now: now)
            precondition(stable.primary?.resetsAt == due.timeIntervalSince1970,
                         "A deadline that moves with every read must not move the cycle")
            _ = scheduler.prepareAttempt(quota: stable, offline: false, quotaFetchedAt: now, now: now)
            precondition(wake.scheduledResetAt == due)
        }
        let next = due.addingTimeInterval(5 * 60 * 60)
        let nextQuota = schedule.update(quota(next), account: account, now: due)
        precondition(nextQuota.primary?.resetsAt == next.timeIntervalSince1970,
                     "Notifications must be able to book the next cycle")
        precondition(scheduler.prepareAttempt(quota: nextQuota, offline: false,
            quotaFetchedAt: due, now: due) == due, "The unprocessed wake still belongs to the old cycle")

        let retry = due.addingTimeInterval(15 * 60)
        wake.nextAttemptAt = retry
        let restarted = CodexWakeScheduler(settings: CodexWakeSettings(defaults: defaults))
        precondition(restarted.prepareAttempt(quota: nextQuota, offline: false,
            quotaFetchedAt: due.addingTimeInterval(60), now: due.addingTimeInterval(60)) == nil)
        precondition(wake.nextAttemptAt == retry && wake.scheduledResetAt == due,
                     "A fresh read or relaunch cannot overwrite the retry deadline")
        precondition(restarted.prepareAttempt(quota: nextQuota, offline: false,
            quotaFetchedAt: retry, now: retry) == due)
        precondition(restarted.prepareAttempt(quota: quota(next, used: 100), offline: false,
            quotaFetchedAt: retry, now: retry) == nil, "Exhausted quota must not submit a wake")
        precondition(restarted.prepareAttempt(quota: nextQuota, offline: true,
            quotaFetchedAt: retry, now: retry) == nil)
        precondition(restarted.prepareAttempt(quota: nextQuota, offline: false,
            quotaFetchedAt: due, now: retry) == nil, "A stale read cannot satisfy a retry")
        wake.recordAttempt(at: retry, cycleResetAt: due)
        precondition(wake.completedResetAt == due && wake.nextAttemptAt == nil)
        precondition(restarted.prepareAttempt(quota: quota(due), offline: false,
            quotaFetchedAt: retry, now: retry) == nil, "A completed cycle cannot be sent twice")

        // Stable corrections are accepted before the deadline, including after restart.
        let other = CodexAccount(email: "correction-test@example.invalid", planType: "plus")
        _ = schedule.update(quota(due), account: other, now: base)
        let corrected = due.addingTimeInterval(1800)
        let first = schedule.update(quota(corrected), account: other, now: base.addingTimeInterval(60))
        precondition(first.primary?.resetsAt == due.timeIntervalSince1970)
        let restoredSchedule = CodexResetSchedule(defaults: defaults)
        let second = restoredSchedule.update(quota(corrected), account: other,
                                             now: base.addingTimeInterval(120))
        precondition(second.primary?.resetsAt == corrected.timeIntervalSince1970)
        let earlier = base.addingTimeInterval(300)
        _ = restoredSchedule.update(quota(earlier), account: other, now: base.addingTimeInterval(180))
        let advanced = restoredSchedule.update(quota(earlier), account: other,
                                               now: base.addingTimeInterval(240))
        precondition(advanced.primary?.resetsAt == earlier.timeIntervalSince1970)
        restoredSchedule.invalidateAccount()
        precondition(restoredSchedule.resolvedAccount == nil)
        wake.selectAccount(other.email!)
        precondition(wake.scheduledResetAt == nil && wake.nextAttemptAt == nil && wake.lastAttemptAt == nil)
        // Preserve a legacy post-success fallback even if the server already
        // reports the following cycle when the app resumes.
        wake.recordAttempt(at: due.addingTimeInterval(-CodexWakeSettings.interval))
        precondition(wake.completedResetAt == nil && wake.nextAttemptAt == due)
        precondition(restarted.prepareAttempt(quota: quota(next), offline: false,
            quotaFetchedAt: due, now: due) == due)
        precondition(wake.scheduledResetAt == due)
        print("PASS: moving deadlines, stable corrections, shared cycles, retry isolation, relaunch and duplicate guards")
    }
}
