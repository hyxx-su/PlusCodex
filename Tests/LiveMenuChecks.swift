import AppKit

@main struct LiveMenuChecks {
    static func main() {
        _ = NSApplication.shared
        func quota(_ used: Double) -> Quota {
            Quota(primary: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: nil), secondary: nil)
        }
        let delegate = AppDelegate()
        delegate.testHookSetActivities([], connected: true)
        delegate.testHookSetQuota(quota(10))
        delegate.testHookRenderForMenu()
        let menu = delegate.testHookMenu!
        let panel = delegate.testHookDashboardView as! QuotaMenuView
        let list = menu.items.compactMap { $0.view as? ThreadActivityView }.first!
        let height = list.frame.height
        precondition(height == 0, "No task must reserve no visible area")
        let emptyMenuHeight = menu.size.height
        delegate.testHookSetMenuTracking(true)
        delegate.testHookSetQuota(quota(40))
        delegate.testHookRenderForMenu()
        precondition(delegate.testHookDashboardView === panel)
        precondition(panel.accessibilityLabel()!.contains("60%"))
        var task = ThreadActivity(id: UUID().uuidString, title: "실시간 작업", runtime: "active", unread: false, updatedAt: 1)
        delegate.testHookSetActivities([task])
        precondition(list.frame.height == 42 && menu.size.height > emptyMenuHeight,
                     "A new task must expand the existing menu content")
        let scroll = list.subviews.first as! NSScrollView
        let row = scroll.documentView!.subviews.first!
        task.runtime = "idle"
        task.unread = true
        delegate.testHookSetActivities([task])
        precondition(scroll.documentView!.subviews.first === row)
        task.unread = false
        delegate.testHookSetActivities([task])
        precondition(scroll.documentView!.subviews.isEmpty)
        precondition(list.frame.height == height && delegate.testHookMenu === menu)
        precondition(menu.size.height == emptyMenuHeight, "Reading the last task must restore the empty menu height")

        let window = NSWindow(contentRect: panel.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel
        panel.update(quota: quota(70), account: nil, updatedAt: Date(), failure: nil)
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
        }
        precondition(panel.testHookDisplayedPercents == [30], "Animation must finish in menu tracking mode")
        panel.update(quota: quota(80), account: nil, updatedAt: Date(), failure: nil)
        panel.update(quota: quota(5), account: CodexAccount(email: "new@example.invalid", planType: "plus"),
                     updatedAt: Date(), failure: nil)
        precondition(panel.testHookDisplayedPercents == [95], "Account switch must cancel old-account animation")
        print("PASS: open-menu identity, live quota, task start/completion/read, tracking-mode animation, account switch")
    }
}
