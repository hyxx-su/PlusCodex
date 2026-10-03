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
        let actionRows = menu.items.filter { $0.action != nil }
        precondition(actionRows.map(\.title) == ["설정", "PlusCodex 종료"] && menu.items.count == 5,
                     "Only Settings and Quit must remain after removing Discord: \(actionRows.map(\.title))")
        precondition(actionRows.map(\.keyEquivalent) == [",", "q"],
                     "Removing Discord must retain Settings and Quit shortcuts")
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func assertNoTooltips() {
            precondition(menu.items.allSatisfy { $0.toolTip == nil })
            precondition(menu.items.compactMap(\.view).flatMap(descendants).allSatisfy { $0.toolTip == nil },
                         "Menu content and controls must not show hover tooltips")
        }
        assertNoTooltips()
        let height = list.frame.height
        precondition(height == 0, "No task must reserve no visible area")
        let emptyMenuHeight = menu.size.height
        delegate.testHookSetActivities([], connected: false)
        precondition(list.frame.height == 0 && menu.size.height == emptyMenuHeight,
                     "An empty recovering connection must not add a banner or menu space")
        delegate.testHookSetActivities([], connected: true)
        delegate.testHookSetMenuTracking(true)
        delegate.testHookSetQuota(quota(40))
        delegate.testHookRenderForMenu()
        precondition(delegate.testHookDashboardView === panel)
        precondition(panel.accessibilityLabel()!.contains("60%"))
        let weekly = QuotaWindow(usedPercent: 20, windowDurationMins: 10080, resetsAt: nil)
        let plus = Quota(primary: quota(40).primary, secondary: weekly, planType: "plus")
        var pro = plus
        pro.planType = "pro_20x"
        delegate.testHookSetQuota(plus)
        delegate.testHookRenderForMenu()
        let expanded = menu.size.height
        precondition(panel.bounds.height == 242)
        delegate.testHookSetQuota(pro)
        delegate.testHookRenderForMenu()
        precondition(delegate.testHookDashboardView === panel && delegate.testHookMenu === menu)
        precondition(panel.bounds.height == 150 && menu.size.height == expanded - 92,
                     "An open menu must shrink when the five-hour limit disappears")
        precondition(!panel.accessibilityLabel()!.contains("5시간") && panel.accessibilityLabel()!.contains("주간"))
        precondition(panel.testHookDisplayedPercents == [80], "Do not animate a removed five-hour bar into the weekly bar")
        delegate.testHookSetQuota(plus)
        delegate.testHookRenderForMenu()
        precondition(menu.size.height == expanded && panel.accessibilityLabel()!.contains("5시간"))
        delegate.testHookSetQuota(quota(40))
        delegate.testHookRenderForMenu()
        var task = ThreadActivity(id: UUID().uuidString, title: "실시간 작업", runtime: "active", unread: false, updatedAt: 1)
        delegate.testHookSetActivities([task])
        assertNoTooltips()
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

        task.unread = true
        let otherTask = ThreadActivity(id: UUID().uuidString, title: "남은 작업", runtime: "active",
                                       unread: false, updatedAt: 2)
        delegate.testHookSetMenuTracking(false)
        delegate.testHookSetActivities([task, otherTask])
        delegate.testHookSetMenuTracking(true)
        let twoTaskHeight = menu.size.height
        let retainedRow = scroll.documentView!.subviews.compactMap { $0 as? ThreadActivityButton }
            .first { $0.accessibilityLabel()?.contains("실시간 작업") == true }!
        let bell = retainedRow.subviews.compactMap { $0 as? NSButton }.first!
        let bellImage = bell.image
        task.updatedAt = 3
        delegate.testHookSetActivities([task, otherTask])
        precondition(retainedRow.superview === scroll.documentView && bell.image === bellImage,
                     "Timestamp-only refresh must retain the row and bell image")
        precondition(menu.size.height == twoTaskHeight)
        task.unread = false
        delegate.testHookSetActivities([task, otherTask])
        precondition(list.frame.height == 42 && menu.size.height == twoTaskHeight - 34,
                     "Reading one of two tasks must shrink the open menu by one row")
        delegate.testHookSetActivities([])
        precondition(menu.size.height == emptyMenuHeight)
        var recovering = otherTask
        recovering.stateConfirmed = false
        delegate.testHookSetActivities([recovering], connected: true)
        assertNoTooltips()
        precondition(list.frame.height == 64, "A recovering row must retain its status banner")
        delegate.testHookSetActivities([], connected: false)
        assertNoTooltips()
        precondition(list.frame.height == 0 && menu.size.height == emptyMenuHeight,
                     "Removing the last recovering row must shrink the open menu immediately")
        delegate.testHookSetActivities([], connected: true)

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

        // The signed test app owns its own defaults domain; preserve it while
        // exercising the same shared preferences used by production menu rows.
        let defaults = UserDefaults.standard
        let preferenceKeys = ["notifications.completion.enabled", "mutedTurnNotifications.v1", "turnNotificationOverrides.v2"]
        let saved = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        defer {
            for key in preferenceKeys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let settings = NotificationSettings(defaults: defaults)
        settings.setEnabled(true, for: .completion)
        func scopedTask(_ title: String) -> ThreadActivity {
            let turn = UUID().uuidString
            return ThreadActivity(id: UUID().uuidString, title: title, runtime: "active",
                latestTurn: ThreadTurnState(key: turn, value: ["turnId": turn, "status": "inProgress"]),
                unread: false, updatedAt: 1)
        }
        let explicitOn = scopedTask("직접 켠 작업")
        let inherited = scopedTask("기본값 작업")
        ThreadNotificationPreferences.shared.setEnabled(true, for: explicitOn)
        let taskView = ThreadActivityView(activities: [explicitOn, inherited])
        let taskScroll = taskView.subviews.first as! NSScrollView
        let taskRows = taskScroll.documentView!.subviews.compactMap { $0 as? ThreadActivityButton }
        let explicitRow = taskRows.first { $0.accessibilityLabel()?.contains(explicitOn.title) == true }!
        let inheritedRow = taskRows.first { $0.accessibilityLabel()?.contains(inherited.title) == true }!
        let explicitBell = explicitRow.subviews.compactMap { $0 as? NSButton }.first!
        let inheritedBell = inheritedRow.subviews.compactMap { $0 as? NSButton }.first!
        let explicitIcon = explicitBell.image
        let preferenceObserver = NotificationCenter.default.addObserver(forName: .threadNotificationPreferenceChanged,
                                                                          object: nil, queue: nil) { _ in
            taskView.update(activities: [explicitOn, inherited], preserveHeight: true)
        }
        defer { NotificationCenter.default.removeObserver(preferenceObserver) }
        settings.setEnabled(false, for: .completion)
        precondition(inheritedBell.state == .off && explicitBell.state == .on,
                     "Changing the default must immediately mute only unselected menu rows")
        precondition(taskScroll.documentView!.subviews.contains { $0 === inheritedRow }
            && explicitBell.image === explicitIcon, "Default changes must update existing rows without rebuilding them")
        inheritedBell.performClick(nil)
        precondition(inheritedBell.state == .on && ThreadNotificationPreferences.shared.enabled(inherited),
                     "The actual menu bell must enable a task despite the disabled default")
        precondition(inheritedBell.toolTip == nil && inheritedBell.accessibilityHelp()?.contains("클릭하여 끄기") == true,
                     "Bell state help must remain accessible without a hover popup")
        explicitBell.performClick(nil)
        precondition(explicitBell.toolTip == nil && explicitBell.accessibilityHelp()?.contains("클릭하여 켜기") == true)
        settings.setEnabled(true, for: .completion)
        precondition(explicitBell.state == .off && inheritedBell.state == .on,
                     "Explicit OFF and ON must survive changing the default")
        settings.setEnabled(false, for: .completion)
        var nextTurn = inherited
        nextTurn.latestTurn = ThreadTurnState(key: "next", value: ["turnId": UUID().uuidString, "status": "inProgress"])
        taskView.update(activities: [explicitOn, nextTurn], preserveHeight: true)
        precondition(inheritedBell.state == .off && inheritedRow.superview === taskScroll.documentView,
                     "A new turn must inherit OFF while retaining the same menu row")
        print("PASS: open-menu identity, live quota, task status, animation, task defaults and manual bell overrides")
    }
}
