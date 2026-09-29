import Foundation

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
        let raw: [String: Any] = ["id": 42, "method": "item/commandExecution/requestApproval",
                                 "params": ["command": "echo test", "cwd": "/tmp"]]
        let request = ThreadActivityMonitor.pendingRequests(in: [raw]).first!
        precondition(request.kind == .approval)
        var completed = raw
        completed["completed"] = true
        precondition(ThreadActivityMonitor.pendingRequests(in: [completed]).isEmpty)
        print("PASS: new-turn default on, per-turn mute persistence, legacy migration, retry isolation, missing-turn guard, approval classification")
    }
}
