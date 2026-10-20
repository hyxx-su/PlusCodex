import AppKit

@main struct GeminiActivityChecks {
    static let id = "a2ae409d-dd14-4a11-a5bf-b4679c2cbe54"

    static func snapshot(input: Double = 1000, modified: Double = 1010, viewed: Double = 1001,
                         running: Bool = false, step: Int = 0, reason: String = "",
                         waiting: Bool = false, unread: Bool = false) -> (activities: [ThreadActivity], viewedAt: [String: Double]) {
        ExternalUsageClient.parseAntigravityTrajectories(["trajectorySummaries": [id: [
            "summary": "Fixture task", "status": running ? "CASCADE_RUN_STATUS_RUNNING" : "CASCADE_RUN_STATUS_IDLE",
            "trajectoryId": "stable-trajectory", "lastUserInputTime": input,
            "lastModifiedTime": modified, "lastUserInputStepIndex": step,
            "latestExecutorTerminationReason": reason,
            "annotations": ["lastUserViewTime": viewed, "markedAsUnread": unread],
            "waitingSteps": waiting ? [["stepIndex": 4, "step": ["requestedInteraction": ["askQuestion": [:]]]]] : []
        ]]])
    }

    static func main() {
        _ = NSApplication.shared
        let suite = "PlusCodex.GeminiActivityChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ProviderSettings(defaults: defaults)
        settings.setEnabled(false, for: .gemini)
        let controller = ProviderStatusController(provider: .gemini, settings: settings,
            activityDefaults: defaults)
        var completed: [ThreadActivity] = [], failed: [ThreadActivity] = [], read: [ThreadActivity] = []
        var attention: [ThreadAttentionEvent] = []
        controller.onCompletion = { completed.append($0) }
        controller.onFailure = { failed.append($0) }
        controller.onRead = { read.append($0) }
        controller.onAttention = { attention.append($0) }
        func apply(_ value: (activities: [ThreadActivity], viewedAt: [String: Double]), connected: Bool = true) {
            controller.testHookApplyActivities(value.activities, viewedAt: value.viewedAt, connected: connected)
        }
        apply(snapshot(modified: 1000, viewed: 1000, running: true))
        let terminal = snapshot(viewed: 1010)
        apply(terminal)
        precondition(completed.count == 1 && read.isEmpty,
                     "Completion must emit before an already-open result is acknowledged")
        precondition(!controller.testHookActivityItem.isHidden)
        apply(terminal)
        precondition(read.count == 1 && controller.testHookActivityItem.isHidden,
                     "Equal view/completion timestamps must clear the row without another view update")
        apply(terminal)
        precondition(completed.count == 1 && read.count == 1, "No duplicate alerts or cleanup")
        let next = snapshot(input: 1020, modified: 1021, viewed: 1010, running: true)
        precondition(next.activities[0].latestTurn?.id != terminal.activities[0].latestTurn?.id,
                     "Reused step zero must still identify a new user turn")
        let laterRunning = snapshot(input: 1020, modified: 1025, viewed: 1010, running: true)
        precondition(next.activities[0].latestTurn?.id == laterRunning.activities[0].latestTurn?.id,
                     "Progress timestamps must not change task notification identity")
        apply(next)
        let second = snapshot(input: 1020, modified: 1030, viewed: 1010)
        apply(second)
        precondition(completed.count == 2 && !controller.testHookActivityItem.isHidden,
                     "The next task must notify despite an identical step index")
        apply(snapshot(input: 1020, modified: 1030, viewed: 1030.2))
        precondition(read.count == 2 && controller.testHookActivityItem.isHidden,
                     "Reading within one second of completion must clear the row")
        apply(snapshot(input: 1040, modified: 1041, viewed: 1030, running: true))
        apply(snapshot(input: 1040, modified: 1042, viewed: 1030, waiting: true))
        precondition(attention.count == 1 && completed.count == 2,
                     "Question/approval waits must not be mistaken for completion")
        apply(snapshot(input: 1040, modified: 1042, viewed: 1030, waiting: true))
        precondition(attention.count == 1)
        apply(snapshot(input: 1040, modified: 1050, viewed: 1030, reason: "EXECUTOR_TERMINATION_REASON_ERROR"))
        precondition(failed.count == 1 && completed.count == 2, "Failures need a separate callback")
        apply(snapshot(input: 1060, modified: 1061, viewed: 1050, running: true))
        apply(snapshot(input: 1060, modified: 1070, viewed: 1050, reason: "EXECUTOR_TERMINATION_REASON_CANCEL"))
        precondition(failed.count == 1 && completed.count == 2, "Cancellation is not success/failure")
        let firstRead = ProviderStatusController(provider: .gemini, settings: settings, activityDefaults: defaults)
        var initialReads = 0
        firstRead.onRead = { _ in initialReads += 1 }
        firstRead.testHookApplyActivities(terminal.activities, viewedAt: terminal.viewedAt)
        precondition(initialReads == 1 && firstRead.testHookActivityItem.isHidden,
                     "A read first snapshot should also clean old notifications")
        let unread = snapshot(input: 1100, modified: 1110, viewed: 1120, unread: true)
        firstRead.testHookApplyActivities(unread.activities, viewedAt: unread.viewedAt)
        precondition(initialReads == 1 && !firstRead.testHookActivityItem.isHidden,
                     "Explicit unread overrides a later view timestamp")
        let preferences = ThreadNotificationPreferences(defaults: defaults)
        preferences.setEnabled(false, for: terminal.activities[0])
        precondition(!preferences.enabled(terminal.activities[0]) && preferences.enabled(next.activities[0]),
                     "A mute/read marker must not leak into the next task")
        let parse = AntigravityConversationReader.conversationID(from:)
        precondition(parse("http://127.0.0.1:62399/c/\(id)?section=outside-of-project") == id)
        precondition(parse("localhost:62399/c/\(id.uppercased())") == id)
        for address in ["https://example.com/c/\(id)", "http://127.0.0.1.evil.test/c/\(id)",
                        "http://user@localhost/c/\(id)", "http://localhost/c/not-a-uuid",
                        "http://localhost/projects/\(id)", "http://localhost/c/\(id)/other",
                        "http://localhost/?next=/c/\(id)", "file:///c/\(id)"] {
            precondition(parse(address) == nil, "Only the verified local conversation route may acknowledge a chat")
        }
        // Isolate the AX fallback cases from receipt state in the preceding tests.
        let axSuite = suite + ".foreground"
        let axDefaults = UserDefaults(suiteName: axSuite)!
        defer { axDefaults.removePersistentDomain(forName: axSuite) }
        let ax = ProviderStatusController(provider: .gemini, settings: settings, activityDefaults: axDefaults)
        var axReads = 0, axCompletions = 0
        ax.onRead = { _ in axReads += 1 }
        ax.onCompletion = { _ in axCompletions += 1 }
        func applyVisible(input: Double = 2000, modified: Double = 2010, running: Bool = false,
                          visible: String? = id, time: Double, connected: Bool = true) {
            let value = snapshot(input: input, modified: modified, viewed: 1990, running: running)
            ax.testHookApplyActivities(value.activities, viewedAt: value.viewedAt, connected: connected,
                                      visibleConversationID: visible, observedAt: time)
        }
        applyVisible(running: true, time: 0)
        applyVisible(time: 2)
        precondition(axCompletions == 1 && axReads == 0, "A fresh completion still submits first")
        applyVisible(time: 2.1)
        precondition(axReads == 0, "Repeated immediate menu refreshes are not evidence of reading")
        applyVisible(time: 4)
        precondition(axReads == 1 && ax.testHookActivityItem.isHidden,
                     "An open chat must clear despite Antigravity's stale view timestamp")
        applyVisible(time: 6)
        precondition(axReads == 1 && axCompletions == 1)
        applyVisible(input: 2020, modified: 2021, running: true, time: 8)
        applyVisible(input: 2020, modified: 2030, visible: UUID().uuidString, time: 10)
        applyVisible(input: 2020, modified: 2030, visible: nil, time: 12)
        precondition(axReads == 1 && axCompletions == 2 && !ax.testHookActivityItem.isHidden,
                     "Another chat, absent permission, or another foreground app must not clear the result")
        applyVisible(input: 2020, modified: 2030, time: 14)
        applyVisible(input: 2020, modified: 2030, visible: nil, time: 16)
        applyVisible(input: 2020, modified: 2030, time: 18)
        precondition(axReads == 1, "Switching away resets the reading observation")
        applyVisible(input: 2020, modified: 2030, time: 20, connected: false)
        applyVisible(input: 2020, modified: 2030, time: 22)
        precondition(axReads == 1, "Disconnection resets the observation")
        applyVisible(input: 2020, modified: 2030, time: 40)
        precondition(axReads == 1, "A stale observation after sleep cannot acknowledge a result")
        applyVisible(input: 2020, modified: 2031, time: 42)
        precondition(axReads == 1, "A changed result needs a new observation")
        applyVisible(input: 2020, modified: 2031, time: 44)
        precondition(axReads == 2 && ax.testHookActivityItem.isHidden)
        precondition(ax.testHookContextMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == [L10n.text("%@ 끄기", "Gemini"), L10n.text("PlusCodex 종료")],
            "Accessibility setup belongs to Gemini activation, not its context menu")
        print("PASS: foreground URL validation, stale-view cleanup, reading dwell, other-chat isolation, permission fallback, reconnect/sleep guards and new-turn notifications")
        print("PASS: Gemini completion/failure/attention callbacks, same-step new turns, stable task identity, external reads, no duplicate alerts, initial cleanup and explicit unread")
    }
}
