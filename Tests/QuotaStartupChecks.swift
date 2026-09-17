import Foundation

/// Live check: requires an installed, authenticated Codex CLI; prints no account data.
@main
struct QuotaStartupChecks {
    static func main() throws {
        let start = Date()
        var delivered = false
        var earlyRemaining: Int?
        let snapshot = try QuotaClient.fetchSnapshot { quota in
            precondition(!delivered, "Deliver usage exactly once")
            delivered = true
            earlyRemaining = (quota.primary ?? quota.secondary)?.remaining
            print(String(format: "Usage delivered before account completion: %.2fs", Date().timeIntervalSince(start)))
        }
        precondition(delivered)
        precondition(earlyRemaining == (snapshot.quota.primary ?? snapshot.quota.secondary)?.remaining)
        print(String(format: "PASS: snapshot completed after early usage delivery: %.2fs", Date().timeIntervalSince(start)))
    }
}
