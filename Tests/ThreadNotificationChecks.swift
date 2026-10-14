import Foundation
import UserNotifications

@main struct ThreadNotificationChecks {
    static func main() throws {
        let suite = "PlusCodex.ThreadNotificationChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ThreadNotificationPreferences(defaults: defaults)
        func task(thread: String, turn: String?) -> ThreadActivity {
            ThreadActivity(id: thread, title: "작업", runtime: "active",
                latestTurn: turn.flatMap { ThreadTurnState(key: $0, value: [
                    "turnId": $0, "status": "inProgress", "turnStartedAtMs": 1000
                ]) }, unread: false, updatedAt: 1)
        }
        let first = task(thread: "one", turn: "first")
        let next = task(thread: "one", turn: "next")
        let other = task(thread: "two", turn: "first")
        defaults.set(["one"], forKey: "mutedThreadNotifications")
        precondition(preferences.enabled(first), "Legacy chat mutes must not mute a new task")
        preferences.setEnabled(false, for: first)
        precondition(!preferences.enabled(first) && preferences.enabled(next) && preferences.enabled(other),
                     "Muting a task must not mute the next turn or another chat")
        let restored = ThreadNotificationPreferences(defaults: defaults)
        precondition(!restored.enabled(first) && restored.enabled(next))
        var completedFirst = first
        completedFirst.runtime = "idle"
        completedFirst.unread = true
        completedFirst.updatedAt = 42
        completedFirst.latestTurn?.status = "completed"
        precondition(!restored.enabled(completedFirst), "Completion and refresh must retain the same task's mute")
        let originalNotificationScope = ThreadNotificationPreferences.scope(for: first)
        preferences.setEnabled(false, for: next)
        preferences.setEnabled(true, for: next)
        precondition(!preferences.enabled(scope: originalNotificationScope) && preferences.enabled(next),
                     "An old notification retry must use its original task's mute")
        preferences.setEnabled(true, for: first)
        precondition(preferences.enabled(first))
        let unknown = task(thread: "one", turn: nil)
        preferences.setEnabled(false, for: unknown)
        precondition(preferences.enabled(unknown) && preferences.enabled(next),
                     "Missing turn metadata must not create a chat-wide mute")

        let settings = NotificationSettings(defaults: defaults)
        let inherited = task(thread: "default", turn: "one")
        let inheritedNext = task(thread: "default", turn: "two")
        var defaultChanges = 0
        let observer = NotificationCenter.default.addObserver(forName: .threadNotificationPreferenceChanged,
                                                               object: nil, queue: nil) { notification in
            if notification.object == nil { defaultChanges += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.setEnabled(false, for: .completion)
        precondition(defaultChanges == 1, "A default change must immediately refresh menu task rows")
        settings.setEnabled(false, for: .completion)
        precondition(defaultChanges == 1, "An unchanged default must not refresh task rows again")
        precondition(!preferences.enabled(inherited) && !preferences.enabled(inheritedNext)
            && !preferences.enabled(other) && !preferences.enabled(unknown),
            "Unselected tasks and missing scopes inherit the disabled default")
        precondition(preferences.enabled(first) && preferences.enabled(next),
                     "Explicit ON choices remain on when the global default turns off")
        preferences.setEnabled(true, for: inherited)
        precondition(preferences.enabled(inherited) && !preferences.enabled(inheritedNext),
                     "Manual ON overrides the disabled default for only this turn")
        let originalScope = ThreadNotificationPreferences.scope(for: inherited)
        let restoredOverride = ThreadNotificationPreferences(defaults: defaults)
        precondition(restoredOverride.enabled(scope: originalScope)
            && !restoredOverride.enabled(inheritedNext), "Explicit ON persists after relaunch without leaking to a new turn")
        preferences.setEnabled(false, for: inherited)
        settings.setEnabled(true, for: .completion)
        precondition(!preferences.enabled(inherited) && preferences.enabled(inheritedNext),
                     "Explicit OFF remains off when the default turns on")
        preferences.setEnabled(true, for: other) // Store ON even when the default is already ON.
        settings.setEnabled(false, for: .completion)
        precondition(preferences.enabled(other) && !preferences.enabled(inheritedNext),
                     "An explicit choice matching the old default must survive a later default change")
        let choicesBeforeMissingTurn = defaults.dictionary(forKey: "turnNotificationOverrides.v2") as? [String: Bool]
        preferences.setEnabled(true, for: unknown)
        precondition(!preferences.enabled(unknown)
            && defaults.dictionary(forKey: "turnNotificationOverrides.v2") as? [String: Bool] == choicesBeforeMissingTurn,
            "A missing turn must neither override the default nor save a chat-wide choice")

        let legacy = task(thread: "legacy", turn: "muted")
        let legacyScope = ThreadNotificationPreferences.scope(for: legacy)!
        defaults.set([legacyScope], forKey: "mutedTurnNotifications.v1")
        settings.setEnabled(true, for: .completion)
        precondition(!restoredOverride.enabled(legacy), "Previously saved per-turn mutes must still be honored")
        preferences.setEnabled(true, for: legacy)
        precondition(restoredOverride.enabled(legacy), "An explicit ON may override a legacy mute")
        precondition(defaults.stringArray(forKey: "mutedTurnNotifications.v1") == [legacyScope],
                     "Legacy records must remain intact for rollback")
        let raw: [String: Any] = ["id": 42, "method": "item/commandExecution/requestApproval",
                                 "params": ["command": "echo test", "cwd": "/tmp"]]
        let request = ThreadActivityMonitor.pendingRequests(in: [raw]).first!
        precondition(request.kind == .approval)
        var completed = raw
        completed["completed"] = true
        precondition(ThreadActivityMonitor.pendingRequests(in: [completed]).isEmpty)
        checkReadCleanup()
        print("PASS: inherited task defaults, explicit ON/OFF persistence, new-turn isolation, legacy mutes, retry scopes, missing-turn guards")
    }

    private static func checkReadCleanup() {
        let now = Date(timeIntervalSince1970: 1000)
        let thread = UUID().uuidString
        let turn = "read-turn"
        var readTask = ThreadActivity(id: thread, title: "읽은 작업", runtime: "idle",
            latestTurn: ThreadTurnState(key: turn, value: ["turnId": turn, "status": "completed"]),
            unread: false, updatedAt: 999)
        let scope = ThreadNotificationPreferences.scope(for: readTask)!
        typealias Entry = ThreadNotificationReadCleanup.Entry
        let entries = [
            Entry(identifier: "completion", userInfo: ["threadID": thread, "notificationScope": scope], deliveredAt: now),
            Entry(identifier: "failure", userInfo: ["threadID": thread, "notificationScope": scope], deliveredAt: now),
            Entry(identifier: "attention", userInfo: ["threadID": thread, "notificationScope": scope], deliveredAt: now),
            Entry(identifier: "other", userInfo: ["threadID": "other", "notificationScope": scope], deliveredAt: now),
            Entry(identifier: "next-turn", userInfo: ["threadID": thread, "notificationScope": thread + ":next"], deliveredAt: now),
            Entry(identifier: "late", userInfo: ["threadID": thread, "notificationScope": scope], deliveredAt: now.addingTimeInterval(1)),
            Entry(identifier: "legacy", userInfo: ["threadID": thread], deliveredAt: now),
            Entry(identifier: "quota", userInfo: [:], deliveredAt: now)
        ]
        var queries = 0
        var fetched: (([Entry]) -> Void)?
        var removed: [String] = []
        let cleanup = ThreadNotificationReadCleanup(now: { now }, fetch: {
            queries += 1
            fetched = $0
        }, remove: { removed += $0 })
        func drain() {
            let deadline = Date().addingTimeInterval(0.05)
            while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: deadline) }
        }
        func request(_ scope: String) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.userInfo = ["threadID": thread, "notificationScope": scope]
            return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        }
        readTask.stateConfirmed = false
        cleanup.read(readTask)
        drain()
        precondition(queries == 0 && !cleanup.wasRead(request(scope)), "Unconfirmed states must not clear alerts")
        readTask.stateConfirmed = true
        cleanup.read(readTask)
        cleanup.read(readTask)
        drain()
        precondition(queries == 1, "Repeated read events must share one OS query")
        precondition(cleanup.wasRead(request(scope)) && !cleanup.wasRead(request(thread + ":next")),
                     "Late submission and retry suppression must not leak into the next turn")
        fetched!(entries)
        drain()
        precondition(Set(removed) == ["completion", "failure", "attention", "legacy"],
                     "Only the read task's existing alerts may be deleted")
        precondition(!ThreadNotificationReadCleanup.matches(entries[0], threadID: thread, scope: nil, readAt: now),
                     "A missing turn ID must not clear scoped alerts speculatively")
        var running = readTask
        running.runtime = "active"
        running.latestTurn = ThreadTurnState(key: "running", value: ["turnId": "running", "status": "inProgress"])
        cleanup.read(running)
        precondition(!cleanup.wasRead(request(ThreadNotificationPreferences.scope(for: running)!)),
                     "Reading a running task must not silence its eventual completion")
        drain()
        fetched!([])
        drain()
        print("PASS: task-read alert cleanup, batched queries, delayed delivery guards and new-turn isolation")
    }
}
