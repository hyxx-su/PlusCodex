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
        precondition(tracker.update([row], connected: true).count == 1, "Notify even when the open chat is already read")
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
        print("PASS: completion, duplicates, read chats, reconnection, removal, subsequent turns")
    }
}
