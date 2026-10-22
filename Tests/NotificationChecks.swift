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
        checkValidatedResetNotifications()

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
        for provider in AIProvider.allCases {
            let iconURL = NotificationIconProvider.iconURL(for: provider)
            precondition(iconURL != nil, "Official colorful notification icon must exist for \(provider)")
            let testContent = UNMutableNotificationContent()
            NotificationIconProvider.apply(to: testContent, provider: provider)
            precondition(!testContent.attachments.isEmpty, "Notification attachment must be configured for \(provider)")
        }

        print("PASS: completion, failure, interruption, foreground banners, task overrides, kind gates, retry scopes, and provider icons")
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

private func checkValidatedResetNotifications() {
    let deadline = Date().timeIntervalSince1970 + 120
    let account = CodexAccount(email: "reset-a@example.com", planType: "plus")
    func quota(_ at: Double, minutes: Int = 300, used: Double? = nil, plan: String? = nil) -> Quota {
        Quota(primary: QuotaWindow(usedPercent: used ?? (at <= deadline ? 80 : 10),
                                  windowDurationMins: minutes, resetsAt: at), secondary: nil, planType: plan)
    }
    func waitUntil(_ condition: () -> Bool) {
        let limit = Date().addingTimeInterval(3)
        while !condition() && Date() < limit {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        precondition(condition(), "Reset reconciliation timed out")
    }
    func isolated(_ test: (ResetNotificationFixture, AppNotifications, NotificationSettings) -> Void) {
        let suite = "PlusCodex.validated-reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotificationSettings(defaults: defaults)
        let fixture = ResetNotificationFixture(now: Date(timeIntervalSince1970: deadline - 60))
        // Seed the old build's accepted future reservation before loading the ledger.
        ResetCycleLedger(defaults: defaults).registered(account: account.email!, name: "primary",
                                                       deadline: deadline, duration: 18000)
        let legacyContent = UNMutableNotificationContent()
        legacyContent.userInfo = ["resetAccount": account.email!, "resetAt": deadline]
        fixture.pending["reset-primary"] = UNNotificationRequest(identifier: "reset-primary", content: legacyContent,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false))
        let notifications = AppNotifications(settings: settings,
            threadPreferences: ThreadNotificationPreferences(defaults: defaults), resetDefaults: defaults,
            resetClock: { fixture.now },
            readPendingResets: { $0(Array(fixture.pending.values)) },
            readResetAuthorization: { completion in
                fixture.authorizationReads += 1
                if fixture.holdAuthorization { fixture.authorization = completion }
                else { completion(fixture.authorized) }
            },
            addReset: { fixture.add($0, completion: $1) },
            removeReset: { ids in ids.forEach { fixture.pending.removeValue(forKey: $0) } })
        test(fixture, notifications, settings)
    }
    func drain(_ notifications: AppNotifications) { waitUntil { !notifications.resetSyncInProgress } }

    precondition(AppNotifications.isPreviousCycleDue(pendingAt: deadline, latestAt: deadline + 18000,
        now: deadline + 1, windowDuration: 18000))
    precondition(AppNotifications.isPreviousCycleDue(pendingAt: deadline, latestAt: deadline + 604800,
        now: deadline + 1, windowDuration: 604800))
    precondition(AppNotifications.isPreviousCycleDue(pendingAt: deadline, latestAt: deadline + 28 * 86400,
        now: deadline + 1, windowDuration: 30 * 86400))
    for (latest, now) in [(deadline, deadline + 1), (deadline + 900, deadline + 1),
                          (deadline + 18000, deadline - 1), (deadline + 18000, deadline + 301),
                          (Double.nan, deadline + 1)] {
        precondition(!AppNotifications.isPreviousCycleDue(pendingAt: deadline, latestAt: latest,
            now: now, windowDuration: 18000), "Stale or corrected deadlines are not confirmed cycles")
    }

    isolated { fixture, notifications, _ in
        let content = UNMutableNotificationContent()
        for id in ["reset-secondary-obsolete", "completion-unrelated"] {
            fixture.pending[id] = UNNotificationRequest(identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false))
        }
        notifications.scheduleResets(quota(deadline), account: account)
        drain(notifications)
        precondition(fixture.additions == 0 && fixture.pending.count == 1,
                     "Cancel legacy reset timers, preserve unrelated notifications, never book future resets")
        precondition(fixture.authorizationReads == 0, "No permission IPC without a due candidate")
        fixture.now = Date(timeIntervalSince1970: deadline + 1)
        notifications.scheduleResets(quota(deadline), account: account)
        drain(notifications)
        precondition(fixture.additions == 0, "Clock passing a stale server deadline is not a reset")
        notifications.scheduleResets(quota(deadline + 18000), account: account)
        drain(notifications)
        precondition(fixture.additions == 1)
        let request = fixture.pending.values.first { $0.identifier.hasPrefix("reset-") }!
        precondition(request.trigger == nil && request.content.userInfo["resetAt"] as? Double == deadline)
        for _ in 0..<10 { notifications.scheduleResets(quota(deadline + 18000), account: account) }
        drain(notifications)
        precondition(fixture.additions == 1, "Repeated polling must not duplicate a confirmed reset")
        precondition(fixture.authorizationReads == 1, "Consumed reminders do not re-read permission every poll")
    }

    for used in [80.0, 90, -.infinity, .infinity, .nan, -1, 101] {
        isolated { fixture, notifications, _ in
            notifications.scheduleResets(quota(deadline), account: account)
            drain(notifications)
            fixture.now = Date(timeIntervalSince1970: deadline + 1)
            notifications.scheduleResets(quota(deadline + 18000, used: used), account: account)
            drain(notifications)
            precondition(fixture.additions == 0, "Dates alone must not confirm unchanged, increased or invalid usage")
        }
    }

    isolated { fixture, notifications, _ in
        notifications.scheduleResets(quota(deadline, used: 0), account: account)
        drain(notifications)
        fixture.now = Date(timeIntervalSince1970: deadline + 1)
        notifications.scheduleResets(quota(deadline + 18000, used: 0), account: account)
        drain(notifications)
        precondition(fixture.additions == 1, "An entirely unused window can still roll over")
    }

    isolated { fixture, notifications, _ in
        notifications.scheduleResets(quota(deadline), account: account)
        drain(notifications)
        fixture.now = Date(timeIntervalSince1970: deadline + 1)
        notifications.scheduleResets(quota(deadline + 18000, plan: "free"), account: account)
        drain(notifications)
        precondition(fixture.additions == 0, "A changed plan is not a natural reset, even if usage falls")
    }

    isolated { fixture, notifications, _ in
        notifications.scheduleResets(quota(deadline), account: account)
        drain(notifications)
        fixture.now = Date(timeIntervalSince1970: deadline - 10)
        notifications.scheduleResets(quota(deadline + 900), account: account)
        drain(notifications)
        notifications.scheduleResets(quota(deadline), account: account,
                                     requestStartedAt: Date(timeIntervalSince1970: deadline - 20))
        drain(notifications)
        fixture.now = Date(timeIntervalSince1970: deadline + 1)
        notifications.scheduleResets(quota(deadline + 18000), account: account)
        drain(notifications)
        precondition(fixture.additions == 0, "An older response must not undo a newer deadline correction")
    }

    for offset in [-61.0, 1, .nan] {
        isolated { fixture, notifications, _ in
            notifications.scheduleResets(quota(deadline), account: account)
            drain(notifications)
            notifications.scheduleResets(quota(deadline + 900), account: account,
                                         requestStartedAt: fixture.now.addingTimeInterval(offset))
            drain(notifications)
            fixture.now = Date(timeIntervalSince1970: deadline + 1)
            notifications.scheduleResets(quota(deadline + 18000), account: account)
            drain(notifications)
            precondition(fixture.additions == 1, "Stale, future or invalid timestamps cannot poison the baseline")
        }
    }

    for change in 0..<7 {
        isolated { fixture, notifications, settings in
            notifications.scheduleResets(quota(deadline), account: account)
            drain(notifications)
            fixture.now = Date(timeIntervalSince1970: deadline + 1)
            switch change {
            case 0:
                notifications.scheduleResets(quota(deadline + 900), account: account)
            case 1:
                fixture.now = Date(timeIntervalSince1970: deadline + 301)
                notifications.scheduleResets(quota(deadline + 18000), account: account)
            case 2:
                notifications.scheduleResets(quota(deadline + 18000), account: CodexAccount(email: "other@example.com", planType: "plus"))
            case 3:
                notifications.scheduleResets(quota(deadline + 18000, minutes: 10080), account: account)
            case 4:
                notifications.invalidateResetAccount()
                notifications.scheduleResets(quota(deadline + 18000), account: account)
            case 5:
                settings.setEnabled(false, for: .reset)
                notifications.scheduleResets(quota(deadline + 18000), account: account)
            default:
                notifications.scheduleResets(quota(deadline + 18000), account: account,
                                             requestStartedAt: Date(timeIntervalSince1970: deadline - 1))
            }
            drain(notifications)
            precondition(fixture.additions == 0, "No reset reminder for invalid evidence (case \(change))")
            if change == 6 {
                notifications.scheduleResets(quota(deadline + 18000), account: account)
                drain(notifications)
                precondition(fixture.additions == 1, "The next post-boundary fetch can still confirm the reset")
            }
        }
    }

    isolated { fixture, notifications, _ in
        notifications.scheduleResets(quota(deadline), account: account)
        drain(notifications)
        fixture.now = Date(timeIntervalSince1970: deadline + 1)
        fixture.failNext = true
        notifications.scheduleResets(quota(deadline + 18000), account: account)
        drain(notifications)
        precondition(fixture.additions == 1 && fixture.pending.isEmpty)
        notifications.scheduleResets(quota(deadline + 18000), account: account)
        drain(notifications)
        precondition(fixture.additions == 2 && fixture.pending.count == 1,
                     "Failed submissions retry only with another fresh fetch")
    }

    for change in 0..<4 {
        isolated { fixture, notifications, settings in
            notifications.scheduleResets(quota(deadline), account: account)
            drain(notifications)
            fixture.now = Date(timeIntervalSince1970: deadline + 1)
            fixture.holdAuthorization = true
            notifications.scheduleResets(quota(deadline + 18000), account: account)
            waitUntil { fixture.authorization != nil }
            if change == 0 { fixture.now = fixture.now.addingTimeInterval(61) }
            if change == 1 { notifications.invalidateResetAccount() }
            if change == 2 { settings.setEnabled(false, for: .reset) }
            fixture.holdAuthorization = false
            let completion = fixture.authorization!
            fixture.authorization = nil
            completion(change != 3)
            drain(notifications)
            precondition(fixture.additions == 0, "Check freshness, account, settings and authorization immediately before send")
        }
    }

    isolated { fixture, notifications, _ in
        notifications.scheduleResets(quota(deadline), account: account)
        drain(notifications)
        fixture.now = Date(timeIntervalSince1970: deadline + 1)
        fixture.holdAdditions = true
        notifications.scheduleResets(quota(deadline + 18000), account: account)
        waitUntil { fixture.held != nil }
        notifications.invalidateResetAccount()
        let (request, completion) = fixture.held!
        fixture.pending[request.identifier] = request
        fixture.held = nil
        fixture.holdAdditions = false
        completion(nil)
        drain(notifications)
        precondition(fixture.pending.isEmpty, "Account invalidation also removes an in-flight immediate submission")
    }
}

private final class ResetNotificationFixture {
    var now: Date
    var pending: [String: UNNotificationRequest] = [:]
    var additions = 0
    var authorized = true
    var authorizationReads = 0
    var failNext = false
    var holdAuthorization = false
    var authorization: ((Bool) -> Void)?
    var holdAdditions = false
    var held: (UNNotificationRequest, (Error?) -> Void)?
    init(now: Date) { self.now = now }
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        additions += 1
        if holdAdditions { held = (request, completion) }
        else if failNext {
            failNext = false
            completion(NSError(domain: "reset-fixture", code: 1))
        } else {
            pending[request.identifier] = request
            completion(nil)
        }
    }
}
