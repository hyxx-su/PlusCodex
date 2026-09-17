import AppKit

/// Integration check: the first menu opening shows a tiny, caption-free, centered
/// logo intro for ~2 seconds, once per launch; the dashboard never embeds a loader.
@main
struct IntroChecks {
    static func main() {
        _ = NSApplication.shared
        introWindowBoundaries()
        panelComposition()
        launchSequence()
        print("PASS: intro shows once per launch, ~2s, logo-only, centered")
    }

    /// The intro window is exactly the first ~2 seconds after the first opening.
    static func introWindowBoundaries() {
        let open = Date()
        let deadline = open.addingTimeInterval(2)
        func visible(_ now: Date) -> Bool { QuotaMenuView.introVisible(until: deadline, now: now) }
        precondition(visible(open), "intro must be visible at open")
        precondition(visible(open.addingTimeInterval(1.999)), "intro must be visible just before 2s")
        precondition(!visible(open.addingTimeInterval(2.001)), "intro must end at 2s")
        precondition(!QuotaMenuView.introVisible(until: nil, now: open), "no deadline means no intro")
    }

    /// Intro panels embed exactly one centered, caption-free loading view.
    static func panelComposition() {
        let intro = QuotaMenuView(quota: nil, account: nil, updatedAt: nil, failure: nil, intro: true)
        let loaders = intro.subviews.compactMap { $0 as? QuotaLoadingView }
        precondition(loaders.count == 1, "intro panel subviews: \(intro.subviews.count)")
        precondition(loaders[0].captionHidden, "intro loader must hide its caption")
        precondition(loaders[0].logoPoint == CGPoint(x: intro.bounds.midX, y: intro.bounds.midY),
                     "intro logo off-center: \(loaders[0].logoPoint)")

        // After the intro expires with no data yet, the dashboard must appear
        // (cards render placeholders); it must not keep showing a loader panel.
        let pending = QuotaMenuView(quota: nil, account: nil, updatedAt: nil, failure: nil, intro: false)
        precondition(pending.subviews.isEmpty,
                     "expired intro with no data still embeds a loader: \(pending.subviews)")

        let loaded = QuotaMenuView(quota: Quota(primary: QuotaWindow(usedPercent: 81,
            windowDurationMins: 300, resetsAt: nil), secondary: nil),
            account: nil, updatedAt: nil, failure: nil, intro: false)
        precondition(loaded.subviews.isEmpty, "loaded dashboard embeds: \(loaded.subviews)")
    }

    /// One launch: first open has the intro, later opens do not.
    static func launchSequence() {
        let delegate = AppDelegate()
        let menu = NSMenu()

        // The intro window starts at launch; simulate the launch moment.
        delegate.testHookStartLaunchClock()
        delegate.testHookAdvanceIntroClock(30)
        precondition(!delegate.testHookIsIntroVisible, "intro must not run before first open")
        // Opening the menu immediately shows only the logo panel: no refresh/quit rows.
        delegate.testHookMenuWillOpen(menu)
        delegate.testHookRenderForMenu()
        guard delegate.testHookIsIntroVisible else { fatalError("open during window must show the intro") }
        guard delegate.testHookMenuItemCount == 1 else {
            fatalError("intro menu must contain only the logo panel, got \(delegate.testHookMenuItemCount) items")
        }
        let first = delegate.testHookDashboardView?.subviews.compactMap { $0 as? QuotaLoadingView } ?? []
        guard first.count == 1, first[0].captionHidden else {
            fatalError("first open tree: \(delegate.testHookDashboardView?.subviews ?? [])")
        }
        delegate.testHookSetActivities([ThreadActivity(id: UUID().uuidString, title: "실행 중",
            runtime: "active", unread: false, updatedAt: 0)])
        precondition(delegate.testHookMenuItemCount == 1, "activity updates must not uncover intro")

        // Run only the mode used by an open menu; expiry must redraw without closing it.
        let timeout = Date().addingTimeInterval(3)
        while delegate.testHookMenuItemCount == 1 && Date() < timeout {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        precondition(delegate.testHookMenuItemCount >= 4, "timer must restore menu during tracking")
        let stablePanel = delegate.testHookDashboardView
        let stableActivity = delegate.testHookMenu?.items[1].view
        delegate.testHookSetQuota(Quota(primary: QuotaWindow(usedPercent: 20,
            windowDurationMins: 300, resetsAt: nil), secondary: nil))
        delegate.testHookRenderForMenu()
        precondition(delegate.testHookDashboardView === stablePanel, "usage refresh must reuse the dashboard")
        precondition(delegate.testHookMenu?.items[1].view === stableActivity, "usage refresh must preserve chat rows")

        // Opening after the window has passed shows the dashboard and native actions.
        delegate.testHookAdvanceIntroClock(2.5)
        guard !delegate.testHookIsIntroVisible else { fatalError("intro must end after 2s") }
        delegate.testHookMenuWillOpen(menu)
        delegate.testHookRenderForMenu()
        precondition(delegate.testHookDashboardView === stablePanel, "reopening must preserve the dashboard")
        guard delegate.testHookMenuItemCount >= 3 else {
            fatalError("dashboard menu must restore refresh/quit items, got \(delegate.testHookMenuItemCount)")
        }
        let second = delegate.testHookDashboardView?.subviews.compactMap { $0 as? QuotaLoadingView } ?? []
        guard second.isEmpty else {
            // After the intro expires the dashboard shows immediately, even without data.
            fatalError("second open must show the dashboard, not a loader: \(second)")
        }
    }
}
