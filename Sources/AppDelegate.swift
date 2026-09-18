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
    private let providerSettings = ProviderSettings()
    private lazy var settingsWindow = AISettingsWindow(settings: providerSettings)
    private var extraProviders: [ProviderStatusController] = []
    private var settingsItem: NSMenuItem?
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
        extraProviders = [AIProvider.claude, .grok].map { provider in
            let controller = ProviderStatusController(provider: provider, settings: providerSettings)
            controller.onSettings = { [weak self] in self?.openSettings() }
            controller.onOpen = { [weak self] in
                guard let self, !self.offline else { return }
                self.updater.checkOnMenuOpen()
            }
            controller.onState = { [weak self] in self?.settingsWindow.update(provider, status: $0) }
            return controller
        }
        providerSettings.onChange = { [weak self] in self?.synchronizeProviders() }
        synchronizeProviders()
        render()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let disconnected = path.status != .satisfied
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                guard let self, self.offline != disconnected else { return }
                self.offline = disconnected
                self.extraProviders.forEach { $0.presentation(offline: disconnected, checking: self.checkingForUpdates) }
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
                if let self { self.extraProviders.forEach { $0.presentation(offline: self.offline, checking: checking) } }
                self?.render()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        notifications.start()
        do { try LoginLaunchController().applyInitialDefault() }
        catch { NSLog("PlusCodex login item: %@", error.localizedDescription) }
        updater.onUpdateAvailable = { [weak self] version, build in
            self?.notifications.updateAvailable(version: version, build: build)
        }
        updater.onWillPresentUpdate = { [weak self] in
            self?.builtItems?.menu.cancelTracking()
            self?.extraProviders.forEach { $0.dismissMenu() }
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
        timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.extraProviders.forEach { $0.synchronize() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func refresh() {
        guard providerSettings.enabled(.codex), !fetching, !offline else { return }
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
                    self.settingsWindow.update(.codex, status: snapshot.account?.email ?? L10n.text("연결됨 · 사용량 조회 완료"))
                case .failure(let error):
                    self.failure = error.localizedDescription
                    self.settingsWindow.update(.codex, status: error.localizedDescription)
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
            button.setAccessibilityLabel(offline ? L10n.text("네트워크 연결 없음") : L10n.text("Codex 남은 사용량 ") + percent)
            button.toolTip = offline ? L10n.text("네트워크 연결 없음") : L10n.text("Codex · %@ 잔여 %@", primary?.displayLabel(planType: account?.planType, isPrimary: quota?.primary != nil) ?? L10n.text("사용 한도"), percent)
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
        settingsItem?.isHidden = stateScreen
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
        let settings = NSMenuItem(title: L10n.text("설정"), action: #selector(openSettings), keyEquivalent: ",")
        settings.image = nil
        settings.target = self
        built.menu.insertItem(settings, at: built.menu.items.count - 1)
        settingsItem = settings
        dashboardItem = built.dashboard
        activityItem = built.activity
        refreshItem = built.refresh
        quitItem = built.quit
        separatorItem = built.separator
        updateActivityView()
        if offline || checkingForUpdates { render() }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        extraProviders.forEach { $0.synchronize() }
        settingsWindow.present()
    }

    private func synchronizeProviders() {
        if providerSettings.enabled(.codex) {
            if item == nil {
                item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item?.autosaveName = "CodexQuota"
                item?.button?.target = self
                item?.button?.action = #selector(statusClicked)
                item?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            render()
            refresh()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            settingsWindow.update(.codex, status: L10n.text("메뉴바에서 꺼짐"))
        }
        extraProviders.forEach { $0.synchronize() }
        settingsWindow.synchronize()
        if AIProvider.allCases.allSatisfy({ !providerSettings.enabled($0) }) { openSettings() }
    }

    @objc private func statusClicked() {
        guard let button = item?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let context = NSMenu()
            let disable = NSMenuItem(title: L10n.text("Codex 끄기"), action: #selector(disableCodex), keyEquivalent: "")
            disable.target = self
            context.addItem(disable)
            context.popUpFollowingSystemAppearance(from: button)
        } else {
            builtItems?.menu.popUpFollowingSystemAppearance(from: button)
        }
    }

    @objc private func disableCodex() {
        DispatchQueue.main.async { self.providerSettings.setEnabled(false, for: .codex) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !offline { updater.checkOnMenuOpen() }
        render()
        refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The menu bar icon and its menu cover recovery; no diagnostic window needed.
        openSettings()
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
