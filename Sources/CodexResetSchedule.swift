import Foundation

/// Stabilizes the five-hour deadline once per completed usage read, before it
/// reaches either notifications or wake scheduling. UI usage stays unmodified.
final class CodexResetSchedule {
    private struct State: Codable, Equatable {
        var anchor: Double
        var candidate: Double?
        var candidateSince: Double?
        var lastObservedAt: Double
    }

    private let defaults: UserDefaults
    private let key = "codexResetSchedule.v1"
    private var states: [String: State]
    private(set) var resolvedAccount: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        states = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode([String: State].self, from: $0)
        } ?? [:]
    }

    func invalidateAccount() {
        resolvedAccount = nil
    }

    func update(_ quota: Quota, account: CodexAccount?, now: Date = Date()) -> Quota {
        if let email = account?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !email.isEmpty {
            resolvedAccount = email
        }
        guard let identity = resolvedAccount else { return quota }
        let quota = quota.effectiveQuota(account: account)
        // A confirmed removal must not resurrect an old anchor on a later downgrade.
        var needsPersistence = false
        if !quota.windows.contains(where: { $0.windowDurationMins == 300 }) {
            needsPersistence = states.removeValue(forKey: identity + ":300") != nil
        }
        func stabilize(_ window: QuotaWindow?) -> QuotaWindow? {
            guard var window, window.windowDurationMins == 300,
                  let reported = window.resetsAt, reported.isFinite else { return window }
            let stateKey = identity + ":300"
            let time = now.timeIntervalSince1970
            var state = states[stateKey] ?? State(anchor: reported, lastObservedAt: time - 1)
            let previousState = states[stateKey]
            let previous = state.anchor
            if time > state.lastObservedAt {
                if time >= state.anchor && reported > time && reported - state.anchor >= 5 * 60 * 60 - 10 * 60 {
                    // The wake scheduler retains its own overdue, unprocessed
                    // cycle. Notifications can book the next full cycle here.
                    state.anchor = reported
                    state.candidate = nil
                    state.candidateSince = nil
                } else if abs(reported - state.anchor) <= 1 {
                    state.candidate = nil
                    state.candidateSince = nil
                } else if let candidate = state.candidate,
                          abs(candidate - reported) <= 1,
                          let since = state.candidateSince, time - since >= 30 {
                    // A sliding value that changes on every read never passes
                    // this confirmation. This is a stability heuristic, not
                    // proof of a server-side reset.
                    state.anchor = reported
                    state.candidate = nil
                    state.candidateSince = nil
                } else if state.candidate.map({ abs($0 - reported) > 1 }) ?? true {
                    state.candidate = reported
                    state.candidateSince = time
                }
                state.lastObservedAt = time
            }
            states[stateKey] = state
            // Poll timestamps alone do not change a reservation. Persist only
            // deadline/candidate transitions; preserve monotonic checks in RAM.
            if previousState?.anchor != state.anchor || previousState?.candidate != state.candidate
                || previousState?.candidateSince != state.candidateSince {
                needsPersistence = true
            }
            window = QuotaWindow(usedPercent: window.usedPercent,
                                 windowDurationMins: window.windowDurationMins,
                                 resetsAt: state.anchor, customLabel: window.customLabel,
                                 resetDescription: window.resetDescription)
            if previous != state.anchor || abs(reported - state.anchor) > 1 {
                NSLog("PlusCodex reset schedule observed=%.0f reported=%.0f previous=%.0f effective=%.0f",
                      time, reported, previous, state.anchor)
            }
            return window
        }
        let result = Quota(primary: stabilize(quota.primary), secondary: stabilize(quota.secondary),
                           additional: quota.additional?.compactMap { stabilize($0) }, planType: quota.planType)
        if needsPersistence, let data = try? JSONEncoder().encode(states) { defaults.set(data, forKey: key) }
        return result
    }
}
