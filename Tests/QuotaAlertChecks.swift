import Foundation

@main struct QuotaAlertChecks {
    static func main() throws {
        var tracker = QuotaAlertTracker()
        var now = Date(timeIntervalSince1970: 500)
        func quota(_ used: Double, reset: Double? = 1000, weekly: Double? = nil) -> Quota {
            Quota(primary: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset),
                  secondary: weekly.map { QuotaWindow(usedPercent: $0, windowDurationMins: 10080, resetsAt: 2000) })
        }
        precondition(tracker.update(quota(89.9), account: "a", now: now).isEmpty)
        precondition(tracker.update(quota(90), account: "a", now: now).map(\.level) == [1])
        precondition(tracker.update(quota(90, reset: 1001), account: "a", now: now).isEmpty, "Deadline correction is not reset")
        precondition(tracker.update(quota(91, reset: 999), account: "a", now: now).isEmpty, "Old deadline must not rearm")
        precondition(tracker.update(quota(91, reset: 5000), account: "a", now: now).isEmpty, "Future metadata alone is not reset")
        precondition(tracker.update(quota(89.9), account: "a", now: now).isEmpty)
        precondition(tracker.update(quota(90), account: "a", now: now).isEmpty, "Threshold jitter must not repeat")
        precondition(tracker.update(quota(90), account: nil, now: now).isEmpty, "Missing identity is not another account")
        precondition(tracker.update(quota(90), account: " A ", now: now).isEmpty, "Normalize account identity")
        precondition(tracker.update(quota(99.9), account: "a", now: now).isEmpty)
        precondition(tracker.update(quota(100), account: "a", now: now).map(\.level) == [2])
        precondition(tracker.update(quota(100, reset: nil), account: "a", now: now).isEmpty)
        let saved = try JSONEncoder().encode(tracker)
        tracker = try JSONDecoder().decode(QuotaAlertTracker.self, from: saved)
        precondition(tracker.update(quota(100), account: "a", now: now).isEmpty, "Relaunch must not repeat")
        precondition(tracker.update(quota(100), account: "b", now: now).map(\.level) == [2])
        precondition(tracker.update(quota(100, weekly: 90), account: "a", now: now).map(\.label) == ["주간"])
        now = Date(timeIntervalSince1970: 1100)
        precondition(tracker.update(quota(90, reset: 3000), account: "a", now: now).map(\.level) == [1], "Elapsed deadline + next cycle")
        precondition(tracker.update(quota(0, reset: 3000), account: "a", now: now).isEmpty)
        precondition(tracker.update(quota(90, reset: 3000), account: "a", now: now).isEmpty, "One recovery sample is not reset")
        _ = tracker.update(quota(0, reset: 3000), account: "a", now: now)
        _ = tracker.update(quota(1, reset: 3000), account: "a", now: now)
        let retry = tracker.update(quota(90, reset: 3000), account: "a", now: now)
        precondition(retry.count == 1, "Sustained recovery allows manual resets")
        tracker.retry(retry[0])
        precondition(tracker.update(quota(90, reset: 3000), account: "a", now: now).count == 1)
        let legacy = Data(#"{"states":{"local-codex:primary":{"reset":3000,"level":1}}}"#.utf8)
        var migrated = try JSONDecoder().decode(QuotaAlertTracker.self, from: legacy)
        precondition(migrated.update(quota(91, reset: 3000), account: "a", now: now).isEmpty, "Keep v1.0.0 history")
        precondition(tracker.update(Quota(primary: nil, secondary: nil), account: "a", now: now).isEmpty)
        precondition(tracker.update(quota(.nan), account: "a", now: now).isEmpty)
        print("PASS: thresholds, timestamp drift, jitter, identity failure, persistence, migration, reset, recovery, retry")
    }
}
