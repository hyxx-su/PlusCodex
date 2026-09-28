import Foundation

@main struct ThreadNotificationChecks {
    static func main() throws {
        let suite = "PlusCodex.ThreadNotificationChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ThreadNotificationPreferences(defaults: defaults)
        precondition(preferences.enabled("one"))
        preferences.setEnabled(false, for: "one")
        precondition(!preferences.enabled("one") && preferences.enabled("two"))
        precondition(!ThreadNotificationPreferences(defaults: defaults).enabled("one"))
        preferences.setEnabled(true, for: "one")
        precondition(preferences.enabled("one"))
        let raw: [String: Any] = ["id": 42, "method": "item/commandExecution/requestApproval",
                                 "params": ["command": "echo test", "cwd": "/tmp"]]
        let request = ThreadActivityMonitor.pendingRequests(in: [raw]).first!
        precondition(request.kind == .approval)
        var completed = raw
        completed["completed"] = true
        precondition(ThreadActivityMonitor.pendingRequests(in: [completed]).isEmpty)
        print("PASS: thread mute isolation and persistence, approval notification classification, completed-request exclusion")
    }
}
