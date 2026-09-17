import Foundation

@main struct QuotaAlertChecks {
    static func main() throws {
        var tracker = QuotaAlertTracker()
        func quota(_ used: Double, reset: Double? = 1000, weekly: Double? = nil) -> Quota {
            Quota(primary: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset),
                  secondary: weekly.map { QuotaWindow(usedPercent: $0, windowDurationMins: 10080, resetsAt: 2000) })
        }
        precondition(tracker.update(quota(89.9), account: "a").isEmpty)
        precondition(tracker.update(quota(90), account: "a").map(\.level) == [1])
        precondition(tracker.update(quota(99.9), account: "a").isEmpty, "Rounding must not trigger exhaustion")
        precondition(tracker.update(quota(100), account: "a").map(\.level) == [2])
        precondition(tracker.update(quota(100), account: "a").isEmpty)
        let saved = try JSONEncoder().encode(tracker)
        tracker = try JSONDecoder().decode(QuotaAlertTracker.self, from: saved)
        precondition(tracker.update(quota(100), account: "a").isEmpty, "Relaunch must not repeat")
        precondition(tracker.update(quota(100), account: "b").map(\.level) == [2], "First seen exhausted sends only 0%")
        precondition(tracker.update(quota(100, weekly: 90), account: "a").map(\.label) == ["주간"])
        precondition(tracker.update(quota(100, reset: 3000), account: "a").map(\.level) == [2], "New cycle")
        precondition(tracker.update(quota(0, reset: 3000), account: "a").isEmpty)
        let retry = tracker.update(quota(90, reset: 3000), account: "a")
        precondition(retry.count == 1)
        tracker.retry(retry[0])
        precondition(tracker.update(quota(90, reset: 3000), account: "a").count == 1, "Retry rejected delivery")
        precondition(tracker.update(Quota(primary: nil, secondary: nil), account: "a").isEmpty)
        precondition(tracker.update(quota(.nan), account: "a").isEmpty)
        print("PASS: 10%, 0%, exact thresholds, duplicates, persistence, accounts, windows, reset, retry")
    }
}
