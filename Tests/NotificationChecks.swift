import Foundation

@main struct NotificationChecks {
    static func main() {
        var tracker = CompletionTracker()
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

        precondition(AppNotifications.foregroundPresentationOptions.contains(.banner))
        precondition(AppNotifications.foregroundPresentationOptions.contains(.sound))
        print("PASS: completion, failure, interruption, request kinds, deduplication and foreground banners")
    }
}
