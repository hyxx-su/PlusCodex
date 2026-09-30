import Foundation

@main struct CodexWakeAccountChecks {
    static func main() {
        let suite = "PlusCodex.WakeAccountChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set("A", forKey: "codexWake.account")
        defaults.set(base, forKey: "codexWake.lastAttemptAt")
        let settings = CodexWakeSettings(defaults: defaults)
        settings.setEnabled(true)
        precondition(settings.lastAttemptAt == base, "Migrate the legacy account")
        settings.selectAccount("B")
        precondition(settings.lastAttemptAt == nil)
        let scheduler = CodexWakeScheduler(settings: settings)
        func sample(_ seconds: Double, used: Double = 0, weekly: Double = 10) -> Date? {
            let now = base.addingTimeInterval(seconds)
            let quota = Quota(primary: QuotaWindow(usedPercent: used, windowDurationMins: 300,
                resetsAt: now.addingTimeInterval(18000).timeIntervalSince1970),
                secondary: QuotaWindow(usedPercent: weekly, windowDurationMins: 10080,
                resetsAt: now.addingTimeInterval(604800).timeIntervalSince1970))
            return scheduler.prepareAttempt(quota: quota, offline: false, quotaFetchedAt: now, now: now)
        }
        precondition(sample(0) == nil)
        precondition(sample(10) == nil)
        precondition(sample(60, weekly: 100) == nil)
        precondition(sample(120) != nil, "An unused account must not wait five hours")
        settings.nextAttemptAt = base.addingTimeInterval(18000)
        settings.selectAccount("A")
        precondition(settings.lastAttemptAt == base)
        settings.recordResult(account: "B", completedAt: base.addingTimeInterval(120),
                              cycle: base, failure: nil, retryAt: nil)
        precondition(settings.lastAttemptAt == base, "B completion must not overwrite A")
        settings.selectAccount("B")
        precondition(settings.lastAttemptAt == base.addingTimeInterval(120))
        precondition(sample(180) == nil && sample(240) == nil)
        let restored = CodexWakeSettings(defaults: defaults)
        precondition(restored.lastAttemptAt == settings.lastAttemptAt)
        restored.selectAccount("C")
        restored.nextAttemptAt = base.addingTimeInterval(18000)
        restored.setEnabled(false)
        restored.setEnabled(true)
        precondition(restored.nextAttemptAt == base.addingTimeInterval(18000))
        restored.selectAccount("A")
        precondition(restored.lastAttemptAt == base)
        restored.selectAccount("C")
        precondition(restored.nextAttemptAt == base.addingTimeInterval(18000))
        settings.selectAccount("D")
        precondition(sample(300, used: 25) == nil)
        precondition(sample(360) == nil && sample(420) == nil,
                     "An observed active cycle must wait for its actual deadline")
        settings.selectAccount("E")
        precondition(sample(500) == nil)
        precondition(sample(800) == nil, "An old empty sample cannot bootstrap a new send")
        settings.nextAttemptAt = base.addingTimeInterval(20000)
        precondition(sample(860) == nil, "Ambiguous reservations block bootstrap")
        print("PASS: legacy migration, unused account bootstrap, account round trips, late completion ownership, relaunch and ambiguous reservation")
    }
}
