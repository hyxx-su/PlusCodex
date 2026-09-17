import Foundation

/// Persist only alert delivery state, never credentials or chat contents.
/// Each account/window/reset cycle has independent 10% and exhausted alerts.
struct QuotaAlertTracker: Codable {
    struct State: Codable {
        var reset: Double?
        var level: Int
        var recoverySamples: Int?
    }
    struct Alert {
        let key: String
        let reset: Double?
        let level: Int
        let previousLevel: Int
        let label: String
    }
    private var states: [String: State] = [:]

    mutating func update(_ quota: Quota, account: String?, now: Date = Date(), planType: String? = nil) -> [Alert] {
        // An optional account/read timeout is not a new account. Defer until identified.
        guard let account = account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !account.isEmpty else { return [] }
        var alerts: [Alert] = []
        for (name, window) in [("primary", quota.primary), ("secondary", quota.secondary)] {
            guard let window, window.usedPercent.isFinite else { continue }
            let key = account + ":" + name
            let reset = window.resetsAt.flatMap { $0.isFinite ? $0 : nil }
            // Carry forward v1.0.0's anonymous state instead of alerting again on login recovery.
            let legacy = states.removeValue(forKey: "local-codex:" + name)
            var state = states[key] ?? legacy ?? State(reset: reset, level: 0)
            // The deadline is anchored for this cycle. Small corrections before it expires
            // do not prove a reset, nor does an old/cached timestamp moving backwards.
            if let reset, let previous = state.reset,
               now.timeIntervalSince1970 >= previous,
               reset > now.timeIntervalSince1970, reset - previous > 60 {
                state = State(reset: reset, level: 0)
            }
            if state.reset == nil { state.reset = reset }
            // Manual quota resets need sustained substantial recovery, not 89.9/90 jitter.
            if state.level > 0 && window.usedPercent <= 80 {
                state.recoverySamples = (state.recoverySamples ?? 0) + 1
                if state.recoverySamples! >= 2 {
                    state = State(reset: reset, level: 0)
                }
            } else {
                state.recoverySamples = 0
            }
            // Use the actual quota, not the rounded menu percentage: 99.1% used is not exhausted.
            let level = window.usedPercent >= 100 ? 2 : (window.usedPercent >= 90 ? 1 : 0)
            if level > state.level {
                alerts.append(Alert(key: key, reset: state.reset, level: level,
                                    previousLevel: state.level,
                                    label: window.displayLabel(planType: planType, isPrimary: name == "primary")))
                state.level = level
            }
            states[key] = state
        }
        return alerts
    }

    mutating func retry(_ alert: Alert) {
        guard var state = states[alert.key], state.reset == alert.reset,
              state.level == alert.level else { return }
        state.level = alert.previousLevel
        states[alert.key] = state
    }
}
