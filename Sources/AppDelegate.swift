import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private var timer: Timer?
    private var fetching = false
    private var quota: Quota?
    private var account: CodexAccount?
    private var updatedAt: Date?
    private var failure: String?
    private var activityMonitor: ThreadActivityMonitor?
    private var activities: [ThreadActivity] = []
    private var activityItem: NSMenuItem?
    private var dashboardItem: NSMenuItem?
    private var refreshItem: NSMenuItem?
    private var quitItem: NSMenuItem?
    private var separatorItem: NSMenuItem?
    private var builtItems: StatusMenuBuilder.Items?
    private var readReceipts = ThreadActivityReadReceipts()
    private lazy var notifications = AppNotifications()
    private let updater = AppUpdater()
    private var checkingForUpdates = false
    private var updateItem: NSMenuItem?
    // Start the intro only when the user first opens the menu in this process.
    private var hasOpenedMenu = false
    private var introTimer: Timer?
    private var introUntil: Date?
    private lazy var statusWindow: StatusWindow = {
        let controller = StatusWindow()
        controller.onRefresh = { [weak self] in self?.refresh() }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.codexquota.menubar")
        if duplicates.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.autosaveName = "CodexQuota"
        item?.isVisible = true
        if let url = Bundle.main.url(forResource: "Codex", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            item?.button?.image = image
        }
        item?.button?.imagePosition = .imageLeading
        item?.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        render()
        updater.onCheckingChanged = { [weak self] checking in
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                self?.checkingForUpdates = checking
                self?.render()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        updater.start()
        notifications.start()
        refresh()
        activityMonitor = ThreadActivityMonitor { [weak self] activities, _ in
            guard let self else { return }
            self.activities = activities
            self.updateActivityView()
        }
        activityMonitor?.onCompletion = { [weak self] activity in self?.notifications.completed(activity) }
        activityMonitor?.start()
        timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func refresh() {
        guard !fetching else { return }
        fetching = true
        statusWindow.update(quota: quota, fetching: true, failure: nil)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try QuotaClient.fetchSnapshot { quota in
                RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                    self.quota = quota
                    self.updatedAt = Date()
                    self.failure = nil
                    self.render()
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            } }
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                self.fetching = false
                switch result {
                case .success(let snapshot):
                    self.notifications.scheduleResets(snapshot.quota, account: snapshot.account)
                    self.notifications.checkThresholds(snapshot.quota, account: snapshot.account)
                    self.quota = snapshot.quota
                    self.account = snapshot.account
                    self.updatedAt = Date()
                    self.failure = nil
                case .failure(let error):
                    self.account = nil
                    self.failure = error.localizedDescription
                }
                self.render()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func render() {
        statusWindow.update(quota: quota, fetching: fetching, failure: failure)
        let primary = quota?.primary ?? quota?.secondary
        let valid = failure == nil
        let percent = valid ? primary.map { "\($0.remaining)%" } ?? (quota == nil ? "…" : "—") : "--%"
        if let button = item?.button {
            button.title = " " + percent
            button.setAccessibilityLabel("Codex 남은 사용량 " + percent)
            button.toolTip = "Codex · \(primary?.label ?? "사용 한도") 잔여 \(percent)"
        }
        // Menu structure stays minimal during the 2 second intro: logo panel only.
        let intro = isIntroVisible
        updateItem?.isHidden = intro
        if let panel = dashboardItem?.view as? QuotaMenuView, panel.intro == intro,
           panel.checkingForUpdates == checkingForUpdates {
            panel.update(quota: quota, account: account, updatedAt: updatedAt, failure: failure)
            return
        }
        let panel = QuotaMenuView(quota: quota, account: account, updatedAt: updatedAt,
                                  failure: failure, intro: intro, checkingForUpdates: checkingForUpdates)
        if let dashboardItem, let built = builtItems {
            dashboardItem.view = panel
            StatusMenuBuilder.apply(intro: intro, activity: built.activity,
                                    separator: built.separator, refresh: built.refresh, quit: built.quit)
            updateActivityView()
            NSLog("PlusCodex render[intro=%d] visible=%d dashboard=%d activity=%d sep=%d refresh=%d quit=%d",
                  intro ? 1 : 0, testHookMenuItemCount,
                  built.dashboard.isHidden ? 1 : 0, built.activity.isHidden ? 1 : 0,
                  built.separator.isHidden ? 1 : 0, built.refresh.isHidden ? 1 : 0,
                  built.quit.isHidden ? 1 : 0)
            return
        }
        let built = StatusMenuBuilder.make(intro: intro, dashboardView: panel, delegate: self,
                                           target: self, refreshAction: #selector(refresh),
                                           quitAction: #selector(quitApp))
        builtItems = built
        let update = NSMenuItem(title: "업데이트 확인…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        update.isHidden = intro
        built.menu.insertItem(update, at: built.menu.items.count - 1)
        updateItem = update
        dashboardItem = built.dashboard
        activityItem = built.activity
        refreshItem = built.refresh
        quitItem = built.quit
        separatorItem = built.separator
        updateActivityView()
        item?.menu = built.menu
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    /// Reopening the menu never restarts the first-open deadline.
    private var isIntroVisible: Bool {
        if checkingForUpdates { return true }
        guard let until = introUntil else { return false }
        return Date() < until
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !hasOpenedMenu {
            hasOpenedMenu = true
            introUntil = Date().addingTimeInterval(2)
            let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
                self?.introUntil = nil
                self?.render()
            }
            introTimer = timer
            // Native menus run in event-tracking mode, not just the default mode.
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        render()
        refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The menu bar icon and its menu cover recovery; no diagnostic window needed.
        item?.isVisible = true
        refresh()
        return false
    }

    // MARK: Test hooks (no production behavior change)
    func testHookStartLaunchClock() {
        introTimer?.invalidate()
        hasOpenedMenu = false
        introUntil = nil
    }
    func testHookSetActivities(_ value: [ThreadActivity]) {
        activities = value
        updateActivityView()
    }
    func testHookMenuWillOpen(_ menu: NSMenu) { menuWillOpen(menu) }
    func testHookRenderForMenu() { render() }
    func testHookAdvanceIntroClock(_ seconds: TimeInterval) {
        introUntil = introUntil.map { $0.addingTimeInterval(-seconds) }
    }
    var testHookIsIntroVisible: Bool { isIntroVisible }
    var testHookDashboardView: NSView? { dashboardItem?.view }
    var testHookMenu: NSMenu? { builtItems?.menu }
    var testHookMenuItemCount: Int {
        guard let built = builtItems else { return 0 }
        return [built.dashboard, built.activity, built.separator, built.refresh, built.quit]
            .filter { !$0.isHidden }.count
    }
    func testHookSetQuota(_ value: Quota?) { quota = value }

    private func updateActivityView() {
        let visible = readReceipts.visibleRows(activities)
        activityItem?.view = ThreadActivityView(activities: visible) { [weak self] opened in
            guard let self else { return }
            self.readReceipts.acknowledge(opened)
            self.updateActivityView()
        }
        activityItem?.isHidden = isIntroVisible || visible.isEmpty
    }
}
