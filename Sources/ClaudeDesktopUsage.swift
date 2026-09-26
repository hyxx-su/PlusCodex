import AppKit

/// Reads Claude Desktop's local usage snapshot without accessing its session or OAuth tokens.
/// The snapshot is an undocumented cache, so absence, schema changes, and stale data
/// must fall through to the existing Claude Code routes rather than inventing limits.
enum ClaudeDesktopUsage {
    private struct History: Decodable {
        let version: Int
        let samples: [Sample]
    }

    private struct Sample: Decodable {
        let t: Double
        let org: String?
        let u: [String: Double]
    }

    private static let maximumAge: TimeInterval = 20 * 60

    static func fetch() -> QuotaSnapshot? {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.anthropic.claudefordesktop" && !$0.isTerminated
        }) else { return nil }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return parse(data, now: Date())
    }

    static func parse(_ data: Data, now: Date) -> QuotaSnapshot? {
        guard let history = try? JSONDecoder().decode(History.self, from: data), history.version == 2 else { return nil }
        let nowMilliseconds = now.timeIntervalSince1970 * 1000
        guard let sample = history.samples.filter({ sample in
            guard let org = sample.org, !org.isEmpty, sample.t.isFinite else { return false }
            let age = (nowMilliseconds - sample.t) / 1000
            return age >= -60 && age <= maximumAge
        }).max(by: { $0.t < $1.t }) else { return nil }

        let buckets: [(String, String, Int)] = [
            ("fh", "5시간", 300),
            ("sd", "주간", 10080),
            ("so", "Opus 주간", 10080),
            ("sn", "Sonnet 주간", 10080)
        ]
        let windows = buckets.compactMap { key, label, minutes -> QuotaWindow? in
            guard let used = sample.u[key], used.isFinite, (0...100).contains(used) else { return nil }
            return QuotaWindow(usedPercent: used, windowDurationMins: minutes,
                               resetsAt: nil, customLabel: label)
        }
        guard sample.u.isEmpty || !windows.isEmpty else { return nil }
        // Claude Free currently records an empty utilization map. An empty
        // snapshot means the Desktop account is active, but provides no percentage.
        return QuotaSnapshot(quota: ExternalUsageClient.quota(windows), account: nil)
    }
}
