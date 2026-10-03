import Foundation
import UserNotifications

@main struct NotificationChecks {
    static func main() {
        var tracker = CompletionTracker()
        var reconnectTracker = CompletionTracker()
        var longTask = ThreadActivity(id: "long", title: "Long task", runtime: "active", unread: false, updatedAt: 1)
        longTask.latestTurn = ThreadTurnState(key: "long", value: ["turnId": "long", "status": "inProgress", "turnStartedAtMs": 1])
        precondition(reconnectTracker.update([longTask], connected: true).isEmpty)
        let suite = "PlusCodex.completion-relaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var persisted = CompletionTracker(defaults: defaults)
        precondition(persisted.update([longTask], connected: true).isEmpty)
        precondition(reconnectTracker.update([], connected: false).isEmpty)
        precondition(reconnectTracker.update([], connected: true, retainingIDs: ["long"]).isEmpty)
        longTask.runtime = "idle"
        longTask.latestTurn?.status = "completed"
        longTask.unread = true
        var relaunched = CompletionTracker(defaults: defaults)
        precondition(relaunched.update([longTask], connected: true).count == 1)
        var relaunchedAgain = CompletionTracker(defaults: defaults)
        precondition(relaunchedAgain.update([longTask], connected: true).isEmpty,
                     "The same completed turn must not notify after relaunch")
        precondition(reconnectTracker.update([longTask], connected: true).count == 1)
        precondition(reconnectTracker.update([longTask], connected: true).isEmpty)
        let recentStart = Date().addingTimeInterval(1)
        var missed = ThreadActivity(id: "missed", title: "Late snapshot", runtime: "idle",
                                   unread: false, updatedAt: recentStart.timeIntervalSince1970)
        missed.latestTurn = ThreadTurnState(key: "missed", value: [
            "turnId": "missed", "status": "completed",
            "turnStartedAtMs": recentStart.timeIntervalSince1970 * 1000
        ])
        precondition(tracker.update([missed], connected: true,
            now: recentStart.addingTimeInterval(3600)).isEmpty,
            "A first snapshot of an hour-old completion must not notify")
        var recentTracker = CompletionTracker()
        precondition(recentTracker.update([missed], connected: true,
            now: recentStart.addingTimeInterval(20)).count == 1,
            "Recently started short turns may notify even if running was missed")
        let id = UUID().uuidString
        var row = ThreadActivity(id: id, title: "작업", runtime: "idle", unread: true, updatedAt: 0)
        precondition(tracker.update([row], connected: true).isEmpty, "Do not notify historic completions")
        row.runtime = "active"
        precondition(tracker.update([row], connected: true).isEmpty)
        row.runtime = "idle"
        row.unread = false
        let firstResult = tracker.update([row], connected: true)
        precondition(firstResult.count == 1, "Notify even when the open chat is already read")
        if case .completed = firstResult[0].kind {} else { preconditionFailure("Expected completion") }
        precondition(tracker.update([row], connected: true).isEmpty, "No duplicate delivery")
        row.runtime = "active"
        _ = tracker.update([row], connected: true)
        _ = tracker.update([], connected: false)
        row.runtime = "idle"
        precondition(tracker.update([row], connected: true).isEmpty, "Reconnect is not completion evidence")
        row.runtime = "active"
        _ = tracker.update([row], connected: true)
        precondition(tracker.update([], connected: true).isEmpty, "Archiving/removal must not notify")
        row.runtime = "idle"
        precondition(tracker.update([row], connected: true).isEmpty)
        row.runtime = "active"
        _ = tracker.update([row], connected: true)
        row.runtime = "idle"
        precondition(tracker.update([row], connected: true).count == 1, "New turn may notify again")
        let turnID = UUID().uuidString
        var failed = ThreadActivity(id: UUID().uuidString, title: "실패", runtime: "active",
                                    unread: false, updatedAt: 1)
        failed.latestTurn = ThreadTurnState(key: "turn:\(turnID)", value: [
            "turnId": turnID, "status": "inProgress", "turnStartedAtMs": 1000
        ])
        precondition(tracker.update([failed], connected: true).isEmpty)
        failed.latestTurn?.status = "failed"
        let failureResult = tracker.update([failed], connected: true)
        precondition(failureResult.count == 1)
        if case .failed = failureResult[0].kind {} else { preconditionFailure("Expected failure") }
        failed.runtime = "idle"
        precondition(tracker.update([failed], connected: true).isEmpty, "Failure must not also notify completion")

        let interruptedID = UUID().uuidString
        failed.runtime = "active"
        failed.latestTurn = ThreadTurnState(key: "turn:\(interruptedID)", value: [
            "turnId": interruptedID, "status": "inProgress", "turnStartedAtMs": 2000
        ])
        precondition(tracker.update([failed], connected: true).isEmpty)
        failed.latestTurn?.status = "interrupted"
        failed.runtime = "idle"
        precondition(tracker.update([failed], connected: true).isEmpty, "User interruption is not a failure")

        let requestRows: [[String: Any]] = [
            ["id": 1, "method": "item/commandExecution/requestApproval"],
            ["id": 2, "method": "tool/requestUserInput", "params": ["questions": [
                ["options": [["label": "Yes"], ["label": "No"]]]
            ]]],
            ["id": 3, "method": "mcpServer/elicitation/request"],
            ["id": 4, "method": "tool/requestUserInput", "params": ["questions": [
                ["options": [["label": "Accept"], ["label": "Decline"]]]
            ]]],
            ["id": 5, "method": "item/fileChange/requestApproval", "completed": true]
        ]
        let pending = ThreadActivityMonitor.pendingRequests(in: requestRows)
        precondition(pending.count == 4)
        precondition(pending.contains(PendingThreadRequest(identity: "item/commandExecution/requestApproval:1", kind: .approval)))
        precondition(pending.contains(PendingThreadRequest(identity: "tool/requestUserInput:2", kind: .answer)))
        precondition(pending.contains(PendingThreadRequest(identity: "mcpServer/elicitation/request:3", kind: .mcp)))
        precondition(pending.contains(PendingThreadRequest(identity: "tool/requestUserInput:4", kind: .appApproval)))

        let state: [String: Any] = ["turnHistory": ["history": ["entitiesByKey": [
            "old": ["turnId": "old", "status": "completed", "turnStartedAtMs": 1000],
            "new": ["turnId": "new", "status": "failed", "turnStartedAtMs": 2000]
        ]]]]
        precondition(ThreadActivityMonitor.latestTurn(in: state)?.id == "new")
        var patchActivity = ThreadActivity(id: UUID().uuidString, title: "패치", runtime: "active",
                                           unread: false, updatedAt: 0)
        ThreadActivityMonitor.applyTurnPatch([
            "path": ["turnHistory", "history", "entitiesByKey", "new"],
            "value": ["turnId": "new", "status": "inProgress", "turnStartedAtMs": 2000]
        ], to: &patchActivity)
        ThreadActivityMonitor.applyTurnPatch([
            "path": ["turnHistory", "history", "entitiesByKey", "new", "status"],
            "value": "failed"
        ], to: &patchActivity)
        precondition(patchActivity.latestTurn?.status == "failed")

        var attention = AttentionTracker()
        var waiting = ThreadActivity(id: UUID().uuidString, title: "요청", runtime: "active",
                                     unread: false, updatedAt: 0)
        waiting.pendingRequests = pending
        let events = attention.update([waiting], connected: true, now: 0)
        precondition(events.count == 4)
        precondition(Set(events.compactMap(\.requestIdentity)) == Set(pending.map(\.identity)),
                     "Retry validation must retain the exact pending request identities")
        precondition(attention.update([waiting], connected: true, now: 1).isEmpty)
        precondition(attention.update([], connected: false, now: 2).isEmpty)
        precondition(attention.update([waiting], connected: true, now: 3).isEmpty,
                     "Reconnect must not repeat pending requests")
        waiting.pendingRequests.removeAll()
        waiting.activeFlags = ["waitingOnApproval"]
        precondition(attention.update([waiting], connected: true, now: 4).isEmpty)
        waiting.activeFlags.removeAll()
        _ = attention.update([waiting], connected: true, now: 4.1)
        waiting.activeFlags = ["waitingOnApproval"]
        precondition(attention.update([waiting], connected: true, now: 5).isEmpty)
        precondition(attention.update([waiting], connected: true, now: 5.6).count == 1,
                     "An approval flag without a request list still notifies")
        checkPendingInputCompletion()

        precondition(AppNotifications.foregroundPresentationOptions.contains(.banner))
        precondition(AppNotifications.foregroundPresentationOptions.contains(.sound))
        let resetContent = UNMutableNotificationContent()
        resetContent.userInfo = ["resetAt": 1_800_000_000.0, "resetAccount": "first@example.com",
                                 "resetLabel": "5시간", "resetSound": "default|5.0|1.0"]
        let pendingReset = UNNotificationRequest(identifier: AppNotifications.resetIdentifier(
            name: "primary", timestamp: 1_800_000_000), content: resetContent,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false))
        precondition(AppNotifications.resetIdentifier(name: "primary", timestamp: 1_800_000_000)
            != AppNotifications.resetIdentifier(name: "primary", timestamp: 1_800_018_000),
            "Different reset cycles must have independent pending IDs")
        precondition(AppNotifications.isPreviousCycleDue(pendingAt: 1_800_000_000,
            latestAt: 1_800_018_000, now: 1_800_000_001, windowDuration: 5 * 60 * 60),
            "A still-pending due notification must survive the next-cycle booking")
        precondition(!AppNotifications.isPreviousCycleDue(pendingAt: 1_800_000_000,
            latestAt: 1_800_000_900, now: 1_800_000_001, windowDuration: 5 * 60 * 60),
            "A corrected deadline must cancel the obsolete request")
        precondition(AppNotifications.isPreviousCycleDue(pendingAt: 1_800_000_000,
            latestAt: 1_800_604_800, now: 1_800_000_001, windowDuration: 7 * 24 * 60 * 60),
            "A weekly reset must preserve the previous due notification")
        precondition(AppNotifications.isPreviousCycleDue(pendingAt: 1_800_000_000,
            latestAt: 1_802_419_200, now: 1_800_000_001, windowDuration: 30 * 24 * 60 * 60),
            "Calendar months shorter than 30 days must still be recognised")
        precondition(AppNotifications.resetRequestMatches(pendingReset, timestamp: 1_800_000_000,
            account: "first@example.com", label: "5시간", sound: "default|5.0|1.0"))
        precondition(!AppNotifications.resetRequestMatches(pendingReset, timestamp: 1_800_000_060,
            account: "first@example.com", label: "5시간", sound: "default|5.0|1.0"),
            "A changed reset time must replace the pending notification")
        precondition(!AppNotifications.resetRequestMatches(pendingReset, timestamp: 1_800_000_000,
            account: "second@example.com", label: "5시간", sound: "default|5.0|1.0"),
            "An account switch must replace the pending notification")
        precondition(!AppNotifications.resetRequestMatches(pendingReset, timestamp: 1_800_000_000,
            account: "first@example.com", label: "5시간", sound: "custom|5.0|1.0"),
            "A sound change must update the pending notification")

        for kind in NotificationKind.allCases {
            defaults.set(false, forKey: "notifications.\(kind.rawValue).enabled")
        }
        let settings = NotificationSettings(defaults: defaults)
        let preferences = ThreadNotificationPreferences(defaults: defaults)
        let notifications = AppNotifications(settings: settings, threadPreferences: preferences)
        let scope = ThreadNotificationPreferences.scope(for: longTask)!
        precondition(!notifications.isThreadNotificationEnabled(.completion, scope: scope))
        preferences.setEnabled(true, for: longTask)
        precondition(!settings.anyEnabled && preferences.hasEnabledOverrides)
        precondition(notifications.isThreadNotificationEnabled(.completion, scope: scope),
                     "An explicitly enabled task must notify even when every global kind is off")
        for kind in [NotificationKind.failure, .approval, .answer, .mcp, .appApproval] {
            precondition(!notifications.isThreadNotificationEnabled(kind, scope: scope),
                         "Explicit task ON must not bypass the independent \(kind.rawValue) setting")
            defaults.set(true, forKey: "notifications.\(kind.rawValue).enabled")
            precondition(notifications.isThreadNotificationEnabled(kind, scope: scope))
        }
        var newerTask = longTask
        newerTask.latestTurn = ThreadTurnState(key: "newer", value: ["turnId": "newer", "status": "inProgress"])
        precondition(!notifications.isThreadNotificationEnabled(.completion,
            scope: ThreadNotificationPreferences.scope(for: newerTask)), "New turns inherit the current default")
        preferences.setEnabled(false, for: newerTask)
        precondition(notifications.isThreadNotificationEnabled(.completion, scope: scope),
                     "Retries must evaluate the original scope, not the newest turn's mute")
        preferences.setEnabled(false, for: longTask)
        defaults.set(true, forKey: "notifications.completion.enabled")
        for kind in [NotificationKind.completion, .failure, .approval, .answer, .mcp, .appApproval] {
            precondition(!notifications.isThreadNotificationEnabled(kind, scope: scope),
                         "Explicit task OFF must suppress both first delivery and retry")
        }
        precondition(notifications.isThreadNotificationEnabled(.completion, scope: nil),
                     "Missing scopes use the global default without inventing an override")
        print("PASS: completion, failure, interruption, foreground banners, task overrides, kind gates and retry scopes")
    }

    private static func checkPendingInputCompletion() {
        for kind in [ThreadAttentionKind.approval, .appApproval, .answer, .mcp] {
            var completion = CompletionTracker()
            var attention = AttentionTracker()
            var row = ThreadActivity(id: UUID().uuidString, title: "입력 대기", runtime: "active",
                                     unread: false, updatedAt: 1)
            precondition(completion.update([row], connected: true).isEmpty)
            row.runtime = "idle"
            row.pendingRequests = [PendingThreadRequest(identity: "request", kind: kind)]
            precondition(completion.update([row], connected: true).isEmpty,
                         "An idle runtime with pending \(kind) must not also notify completion")
            precondition(attention.update([row], connected: true, now: 0).count == 1)
            precondition(completion.update([row], connected: true).isEmpty)
            row.pendingRequests.removeAll()
            row.runtime = "active"
            precondition(completion.update([row], connected: true).isEmpty,
                         "Resolving input must not complete a still-running task")
            row.runtime = "idle"
            precondition(completion.update([row], connected: true).count == 1)
            precondition(completion.update([row], connected: true).isEmpty)
        }

        for runtime in ["waitingOnApproval", "waitingForPermission"] {
            var completion = CompletionTracker()
            var row = ThreadActivity(id: UUID().uuidString, title: "승인 상태", runtime: "active",
                                     unread: false, updatedAt: 1)
            _ = completion.update([row], connected: true)
            row.runtime = runtime
            precondition(completion.update([row], connected: true).isEmpty)
            row.runtime = "idle"
            row.activeFlags = [runtime]
            precondition(completion.update([row], connected: true).isEmpty,
                         "Approval flags must take precedence over an idle runtime")
            row.activeFlags.removeAll()
            precondition(completion.update([row], connected: true).count == 1)
            precondition(completion.update([row], connected: true).isEmpty)
        }

        // A terminal patch may precede request removal, even in an already-read chat.
        for terminal in ["completed", "failed", "interrupted"] {
            var completion = CompletionTracker()
            var row = ThreadActivity(id: UUID().uuidString, title: "터미널 패치", runtime: "active",
                                     latestTurn: ThreadTurnState(key: "turn", value: [
                                        "turnId": "turn", "status": "inProgress", "turnStartedAtMs": 1
                                     ]), unread: false, updatedAt: 1)
            precondition(completion.update([row], connected: true).isEmpty)
            row.runtime = "idle"
            row.latestTurn?.status = terminal
            row.pendingRequests = [PendingThreadRequest(identity: "approval", kind: .approval)]
            precondition(completion.update([row], connected: true).isEmpty)
            precondition(completion.update([row], connected: true).isEmpty,
                         "Repeated terminal snapshots must remain deferred while approval is pending")
            precondition(completion.update([], connected: false).isEmpty)
            row.pendingRequests.removeAll()
            let results = completion.update([row], connected: true)
            if terminal == "interrupted" {
                precondition(results.isEmpty, "Cancelling approval is not successful completion")
            } else {
                precondition(results.count == 1,
                             "A resolved terminal result must not be lost for an already-read chat")
                switch results[0].kind {
                case .completed: precondition(terminal == "completed")
                case .failed: precondition(terminal == "failed")
                }
            }
            precondition(completion.update([row], connected: true).isEmpty)
        }

        var completion = CompletionTracker()
        var row = ThreadActivity(id: UUID().uuidString, title: "상태 패치 순서", runtime: "active",
                                 latestTurn: ThreadTurnState(key: "turn", value: [
                                    "turnId": "turn", "status": "inProgress", "turnStartedAtMs": 1
                                 ]), unread: false, updatedAt: 1)
        _ = completion.update([row], connected: true)
        row.latestTurn?.status = "completed"
        precondition(completion.update([row], connected: true).isEmpty,
                     "A completed history patch must wait for the runtime to stop")
        row.runtime = "idle"
        precondition(completion.update([row], connected: true).count == 1)
        precondition(completion.update([row], connected: true).isEmpty)

        var recentCompletion = CompletionTracker()
        let start = Date().addingTimeInterval(1)
        row.latestTurn = ThreadTurnState(key: "recent", value: ["turnId": "recent", "status": "completed",
            "turnStartedAtMs": start.timeIntervalSince1970 * 1000])
        row.pendingRequests = [PendingThreadRequest(identity: "app-approval", kind: .appApproval)]
        precondition(recentCompletion.update([row], connected: true, now: start).isEmpty)
        row.pendingRequests.removeAll()
        precondition(recentCompletion.update([row], connected: true, now: start.addingTimeInterval(1)).count == 1,
                     "A recent terminal snapshot must defer, not discard, its completion")
        precondition(recentCompletion.update([row], connected: true, now: start.addingTimeInterval(2)).isEmpty)
    }
}
