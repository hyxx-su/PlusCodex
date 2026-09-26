import AppKit

@main
struct ActivityChecks {
    static func main() {
        let id = "01a0aa9a-48f3-7971-bbf0-1af8c1985b3c"
        var activity = ThreadActivity(id: id, title: "작업", runtime: "active", unread: false, updatedAt: 0)
        precondition(activity.isVisible && activity.isRunning)
        precondition(activity.url?.absoluteString == "codex://threads/\(id)")
        activity.runtime = "idle"
        precondition(!activity.isVisible)
        activity.unread = true
        precondition(activity.isVisible && !activity.isRunning)
        let readEvent: [String: Any] = ["type": "broadcast", "method": "thread-read-state-changed",
            "version": 3, "params": ["hostId": "local", "conversationId": id, "hasUnreadTurn": false]]
        let read = ThreadActivityMonitor.readStateChange(from: readEvent)
        precondition(read?.id == id && read?.unread == false)
        activity.unread = read!.unread
        precondition(!activity.isVisible, "Completed tasks disappear when read")
        activity.runtime = "active"
        precondition(activity.isVisible, "Reading must not hide running tasks")
        var unsupported = readEvent
        unsupported["version"] = 99
        precondition(ThreadActivityMonitor.readStateChange(from: unsupported) == nil)
        activity.runtime = "unknown"
        precondition(!activity.isVisible)
        let invalid = ThreadActivity(id: "invalid/path", title: "", runtime: "idle", unread: true, updatedAt: 0)
        precondition(invalid.url == nil)

        var receipts = ThreadActivityReadReceipts()
        var completed = ThreadActivity(id: id, title: "완료", runtime: "idle", unread: true, updatedAt: 10)
        receipts.acknowledge(completed)
        precondition(receipts.visibleRows([completed]).isEmpty)
        precondition(receipts.visibleRows([completed]).isEmpty, "Stale unread snapshots must not restore opened results")
        completed.updatedAt = 11
        precondition(receipts.visibleRows([completed]).count == 1, "New results must reappear")
        receipts.acknowledge(completed)
        completed.runtime = "active"
        precondition(receipts.visibleRows([completed]).count == 1)
        receipts.acknowledge(completed)
        completed.runtime = "idle"
        precondition(receipts.visibleRows([completed]).count == 1, "Opening running tasks must not hide their completion")

        _ = NSApplication.shared
        let empty = ThreadActivityView(activities: [])
        precondition(empty.frame.height == 0 && empty.subviews.isEmpty)
        let populated = ThreadActivityView(activities: [activity])
        precondition(populated.frame.height == 42)
        precondition(populated.subviews.count == 1 && populated.subviews.first is NSScrollView)
        let row = ThreadActivityButton(activity: activity,
            frame: NSRect(x: 0, y: 0, width: 276, height: 34))
        row.testHookSetHovered(true)
        row.refreshHover()
        precondition(!row.testHookHovered, "Menu highlight changes must clear stale hover")
        row.testHookSetHovered(true)
        row.updateTrackingAreas()
        precondition(!row.testHookHovered, "Detached tracking areas must clear stale hover")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        row.testHookSetHovered(true)
        row.removeFromSuperview()
        precondition(!row.testHookHovered, "Detaching a menu row must clear stale hover")
        print("PASS: visibility, deep links, empty/list layout")

        if CommandLine.arguments.contains("--live") {
            var receivedRunning = false
            let monitor = ThreadActivityMonitor { rows, connected in
                if connected && rows.contains(where: \.isRunning) { receivedRunning = true }
            }
            monitor.start()
            let deadline = Date().addingTimeInterval(15)
            // Regression: callbacks must arrive without running the default loop mode.
            while !receivedRunning && Date() < deadline {
                _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.1))
            }
            precondition(receivedRunning, "No running task received in menu tracking mode")
            print("PASS: live running task delivered in menu tracking mode")
        }
    }
}
