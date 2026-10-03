import AppKit

@main
struct ActivityChecks {
    static func main() {
        precondition(ThreadRecoveryPolicy.shouldRefreshReadState(runtime: "idle", unread: true,
            awaitingSnapshot: false, recoveryDue: false))
        precondition(!ThreadRecoveryPolicy.shouldRefreshReadState(runtime: "idle", unread: false,
            awaitingSnapshot: false, recoveryDue: true))
        precondition(!ThreadRecoveryPolicy.shouldRefreshReadState(runtime: "active", unread: true,
            awaitingSnapshot: false, recoveryDue: true))
        precondition(!ThreadRecoveryPolicy.shouldRefreshReadState(runtime: "idle", unread: true,
            awaitingSnapshot: true, recoveryDue: false))
        precondition(ThreadRecoveryPolicy.shouldRefreshReadState(runtime: nil, unread: nil,
            awaitingSnapshot: true, recoveryDue: true))
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
        let otherID = UUID().uuidString
        let followed: Set<String> = [id, otherID]
        let reset: [String: Any] = ["type": "broadcast", "method": "ipc-connection-reset",
                                    "version": 1, "params": [:]]
        precondition(ThreadActivityMonitor.refollowIDs(for: reset, followed: followed,
                                                       clientID: "local-client") == followed.sorted())
        let requested: [String: Any] = ["type": "broadcast", "method": "thread-stream-following-status-requested",
                                        "version": 1, "sourceClientId": "owner",
                                        "params": ["hostId": "local", "conversationId": id]]
        precondition(ThreadActivityMonitor.refollowIDs(for: requested, followed: followed,
                                                       clientID: "local-client") == [id])
        var invalidRequest = requested
        invalidRequest["sourceClientId"] = "local-client"
        precondition(ThreadActivityMonitor.refollowIDs(for: invalidRequest, followed: followed,
                                                       clientID: "local-client").isEmpty)
        invalidRequest = requested
        invalidRequest["version"] = 2
        precondition(ThreadActivityMonitor.refollowIDs(for: invalidRequest, followed: followed,
                                                       clientID: "local-client").isEmpty)
        invalidRequest = requested
        invalidRequest["params"] = ["hostId": "remote", "conversationId": id]
        precondition(ThreadActivityMonitor.refollowIDs(for: invalidRequest, followed: followed,
                                                       clientID: "local-client").isEmpty)
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

        var externallyCompleted = ThreadActivity(id: id, title: "외부에서 완료 확인", runtime: "idle",
                                                  unread: true, updatedAt: 20)
        receipts.markCompleted(externallyCompleted)
        precondition(receipts.visibleRows([externallyCompleted]).count == 1)
        receipts.acknowledgeExternally(externallyCompleted)
        precondition(receipts.visibleRows([externallyCompleted]).isEmpty,
                     "Codex에서 읽은 완료 작업은 메뉴바에서 사라져야 합니다")
        receipts.markCompleted(externallyCompleted)
        precondition(receipts.visibleRows([externallyCompleted]).isEmpty,
                     "A delayed completion must not restore an acknowledged result")
        externallyCompleted.unread = false
        receipts.acknowledgeExternally(externallyCompleted)
        precondition(receipts.visibleRows([externallyCompleted]).isEmpty,
                     "Repeated read receipts must remain effective")
        externallyCompleted.unread = true
        externallyCompleted.updatedAt = 21
        precondition(receipts.visibleRows([externallyCompleted]).count == 1,
                     "새로 갱신된 완료 작업은 다시 표시되어야 합니다")

        _ = NSApplication.shared
        var turnReceipts = ThreadActivityReadReceipts()
        var readTurn = externallyCompleted
        readTurn.latestTurn = ThreadTurnState(key: "read", value: ["turnId": "read", "status": "completed"])
        let receiptSuite = "PlusCodex.receipts.\(UUID().uuidString)"
        let receiptDefaults = UserDefaults(suiteName: receiptSuite)!
        defer { receiptDefaults.removePersistentDomain(forName: receiptSuite) }
        var persisted = ThreadActivityReadReceipts(defaults: receiptDefaults)
        persisted.acknowledge(readTurn)
        var restored = ThreadActivityReadReceipts(defaults: receiptDefaults)
        precondition(restored.visibleRows([readTurn]).isEmpty, "Read turns must stay hidden after relaunch")
        restored.forget(readTurn.id)
        var forgotten = ThreadActivityReadReceipts(defaults: receiptDefaults)
        precondition(forgotten.visibleRows([readTurn]).count == 1)
        var uncertain = readTurn
        uncertain.stateConfirmed = false
        forgotten.acknowledge(uncertain)
        precondition(forgotten.visibleRows([uncertain]).count == 1,
                     "Unconfirmed state must not be treated as read completion")
        precondition(uncertain.statusLabel == L10n.text("작업 상태 확인 불가"))
        turnReceipts.acknowledge(readTurn)
        readTurn.updatedAt += 100
        turnReceipts.markCompleted(readTurn)
        precondition(turnReceipts.visibleRows([readTurn]).isEmpty)
        turnReceipts.forget(readTurn.id)
        turnReceipts.markCompleted(readTurn)
        turnReceipts.forget(readTurn.id)
        precondition(turnReceipts.visibleRows([]).isEmpty)
        let empty = ThreadActivityView(activities: [])
        precondition(empty.frame.height == 0 && empty.subviews.first is NSScrollView)
        let populated = ThreadActivityView(activities: [activity])
        precondition(populated.frame.height == 42)
        precondition(populated.subviews.first is NSScrollView)
        empty.update(activities: [], connected: false)
        precondition(empty.frame.height == 0,
                     "An empty list must not reserve a connection recovery banner")
        precondition(empty.subviews.compactMap { $0 as? NSTextField }.allSatisfy(\.isHidden))
        empty.update(activities: [], preserveHeight: true, connected: false, incompatible: true)
        precondition(empty.frame.height == 0,
                     "Even an incompatible connection must not expand an empty task section")
        empty.update(activities: [], connected: true)
        precondition(empty.frame.height == 0)
        populated.update(activities: [uncertain], connected: true)
        precondition(populated.frame.height == 64,
                     "Per-task snapshot recovery must stay visible on a healthy connection")
        precondition(populated.subviews.compactMap { $0 as? NSTextField }.contains { !$0.isHidden })
        populated.update(activities: [], preserveHeight: true, connected: false)
        precondition(populated.frame.height == 0,
                     "Removing the last recovering task must also remove its banner immediately")
        populated.update(activities: [activity], connected: false)
        precondition(populated.frame.height == 64, "A disconnected nonempty list still warns")
        populated.update(activities: [activity], connected: true)
        precondition(populated.frame.height == 42)
        let scroll = populated.subviews.first as! NSScrollView
        let originalRow = scroll.documentView!.subviews.first!
        activity.runtime = "idle"
        activity.unread = true
        populated.update(activities: [activity], preserveHeight: true)
        precondition(scroll.documentView!.subviews.first === originalRow,
                     "Completion must update the existing row")
        precondition((originalRow as! ThreadActivityButton).accessibilityLabel()?.contains("완료") == true)
        populated.update(activities: [], preserveHeight: true)
        precondition(populated.frame.height == 0 && scroll.documentView!.subviews.isEmpty)
        populated.update(activities: [activity], preserveHeight: true)
        precondition(scroll.documentView!.subviews.count == 1 && populated.frame.height == 42)
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
