import AppKit
import Network

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
    private let networkMonitor = NWPathMonitor()
    private var offline = false
    private var stateScreenHeight: CGFloat?
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
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let disconnected = path.status != .satisfied
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                guard let self, self.offline != disconnected else { return }
                self.offline = disconnected
                self.render()
                if !disconnected {
                    self.refresh()
                    self.updater.checkOnMenuOpen()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        networkMonitor.start(queue: DispatchQueue(label: "PlusCodex.network"))
        updater.onCheckingChanged = { [weak self] checking in
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                self?.checkingForUpdates = checking
                self?.render()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        notifications.start()
        updater.onUpdateAvailable = { [weak self] version, build in
            self?.notifications.updateAvailable(version: version, build: build)
        }
        updater.start()
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
        guard !fetching, !offline else { return }
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
        let percent = offline ? ""
            : valid ? primary.map { "\($0.remaining)%" } ?? (quota == nil ? "…" : "—") : "--%"
        if let button = item?.button {
            button.image = CodexStatusIcon.image(size: 18, offline: offline)
            button.imagePosition = offline ? .imageOnly : .imageLeading
            button.attributedTitle = NSAttributedString(string: offline ? "" : " " + percent, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: offline ? 9 : 11, weight: .medium),
                .foregroundColor: offline ? NSColor.systemGray : NSColor.labelColor
            ])
            button.setAccessibilityLabel(offline ? "네트워크 연결 없음" : "Codex 남은 사용량 " + percent)
            button.toolTip = offline ? "네트워크 연결 없음" : "Codex · \(primary?.displayLabel(planType: account?.planType, isPrimary: quota?.primary != nil) ?? "사용 한도") 잔여 \(percent)"
        }
        // Measure AppKit's native row heights before hiding them; the status panel
        // then occupies exactly the same menu content area, including action rows.
        let intro = false
        let oldPanel = dashboardItem?.view as? QuotaMenuView
        let stateScreen = (offline || checkingForUpdates) && builtItems != nil
        if stateScreen, stateScreenHeight == nil, let built = builtItems, let oldPanel {
            let probe = NSMenu()
            let row = NSMenuItem()
            row.view = NSView(frame: oldPanel.frame)
            probe.addItem(row)
            let padding = probe.size.height - oldPanel.frame.height
            stateScreenHeight = built.menu.size.height - padding
        }
        if !stateScreen { stateScreenHeight = nil }
        if let panel = dashboardItem?.view as? QuotaMenuView, panel.intro == intro,
           panel.checkingForUpdates == checkingForUpdates, panel.offline == offline {
            panel.update(quota: quota, account: account, updatedAt: updatedAt, failure: failure)
            return
        }
        let panel = QuotaMenuView(quota: quota, account: account, updatedAt: updatedAt,
                                  failure: failure, intro: intro, checkingForUpdates: stateScreen && checkingForUpdates,
                                  offline: stateScreen && offline, preservedHeight: stateScreenHeight)
        if let dashboardItem, let built = builtItems {
            dashboardItem.view = panel
            StatusMenuBuilder.apply(intro: stateScreen, activity: built.activity,
                                    separator: built.separator, refresh: built.refresh, quit: built.quit)
            updateActivityView()
            return
        }
        let built = StatusMenuBuilder.make(intro: intro, dashboardView: panel, delegate: self,
                                           target: self, refreshAction: #selector(refresh),
                                           quitAction: #selector(quitApp))
        builtItems = built
        dashboardItem = built.dashboard
        activityItem = built.activity
        refreshItem = built.refresh
        quitItem = built.quit
        separatorItem = built.separator
        updateActivityView()
        item?.menu = built.menu
        if offline || checkingForUpdates { render() }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func menuWillOpen(_ menu: NSMenu) {
        if !offline { updater.checkOnMenuOpen() }
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
    func testHookSetActivities(_ value: [ThreadActivity]) {
        activities = value
        updateActivityView()
    }
    func testHookMenuWillOpen(_ menu: NSMenu) { menuWillOpen(menu) }
    func testHookRenderForMenu() { render() }
    var testHookDashboardView: NSView? { dashboardItem?.view }
    var testHookMenu: NSMenu? { builtItems?.menu }
    var testHookMenuItemCount: Int {
        guard let built = builtItems else { return 0 }
        return [built.dashboard, built.activity, built.separator, built.refresh, built.quit]
            .filter { !$0.isHidden }.count
    }
    func testHookSetQuota(_ value: Quota?) { quota = value }

    private func updateActivityView() {
        if stateScreenHeight != nil {
            activityItem?.isHidden = true
            return
        }
        let visible = readReceipts.visibleRows(activities)
        activityItem?.view = ThreadActivityView(activities: visible) { [weak self] opened in
            guard let self else { return }
            self.readReceipts.acknowledge(opened)
            self.updateActivityView()
        }
        activityItem?.isHidden = visible.isEmpty
    }

    func applicationWillTerminate(_ notification: Notification) { networkMonitor.cancel() }

    func testHookSetPresentation(offline: Bool, checking: Bool) {
        self.offline = offline
        checkingForUpdates = checking
        render()
    }
}
