import Foundation

/// Persist only alert delivery state, never credentials or chat contents.
/// Each account/window/reset cycle has independent 10% and exhausted alerts.
struct QuotaAlertTracker: Codable {
    struct State: Codable {
        var reset: Double?
        var level: Int
    }
    struct Alert {
        let key: String
        let reset: Double?
        let level: Int
        let previousLevel: Int
        let label: String
    }
    private var states: [String: State] = [:]

    mutating func update(_ quota: Quota, account: String) -> [Alert] {
        var alerts: [Alert] = []
        for (name, window) in [("primary", quota.primary), ("secondary", quota.secondary)] {
            guard let window, window.usedPercent.isFinite else { continue }
            let key = account + ":" + name
            let reset = window.resetsAt.flatMap { $0.isFinite ? $0 : nil }
            var state = states[key] ?? State(reset: reset, level: 0)
            if let reset, let previous = state.reset, reset != previous {
                state = State(reset: reset, level: 0)
            }
            if reset != nil { state.reset = reset }
            // Use the actual quota, not the rounded menu percentage: 99.1% used is not exhausted.
            let level = window.usedPercent >= 100 ? 2 : (window.usedPercent >= 90 ? 1 : 0)
            if level == 0 { state.level = 0 }
            if level > state.level {
                alerts.append(Alert(key: key, reset: state.reset, level: level,
                                    previousLevel: state.level, label: window.label))
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
