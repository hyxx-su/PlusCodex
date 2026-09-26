import AppKit
import Network

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private var fallbackItem: NSStatusItem?
    private var timer: Timer?
    private var fetching = false
    private var refreshPending = false
    private var refreshGeneration = 0
    private var codexAuthRevision = CodexAuthRevision.current()
    private var quota: Quota?
    private var account: CodexAccount?
    private var updatedAt: Date?
    private var failure: String?
    private var codexExecutableMissing = false
    private var activityMonitor: ThreadActivityMonitor?
    private var activities: [ThreadActivity] = []
    private var activityItem: NSMenuItem?
    private var dashboardItem: NSMenuItem?
    private var refreshItem: NSMenuItem?
    private var quitItem: NSMenuItem?
    private var separatorItem: NSMenuItem?
    private var builtItems: StatusMenuBuilder.Items?
    private var readReceipts = ThreadActivityReadReceipts()
    private let notificationSettings = NotificationSettings()
    private lazy var notifications = AppNotifications(settings: notificationSettings)
    private let updater = AppUpdater()
    private var checkingForUpdates = false
    private var menuTracking = false
    private let networkMonitor = NWPathMonitor()
    private var offline = false
    private var stateScreenHeight: CGFloat?
    private let providerSettings = ProviderSettings()
    private let wakeSettings = CodexWakeSettings()
    private lazy var wakeScheduler = CodexWakeScheduler(settings: wakeSettings)
    private lazy var settingsWindow: AISettingsWindow = {
        let controller = AISettingsWindow(settings: providerSettings,
                                          notificationSettings: notificationSettings,
                                          wakeSettings: wakeSettings)
        controller.onWakeSettingsChanged = { [weak self] in
            guard let self else { return }
            self.wakeScheduler.tick(quota: self.quota, offline: self.offline)
        }
        return controller
    }()
    private var extraProviders: [ProviderStatusController] = []
    private var settingsItem: NSMenuItem?
    private lazy var statusWindow: StatusWindow = {
        let controller = StatusWindow()
        controller.onRefresh = { [weak self] in self?.refresh() }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange),
                                               name: .plusCodexLanguageDidChange, object: nil)
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.codexquota.menubar")
        if duplicates.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        extraProviders = [AIProvider.claude, .grok].map { provider in
            let controller = ProviderStatusController(provider: provider, settings: providerSettings)
            controller.onSettings = { [weak self] in self?.openSettings() }
            controller.onState = { [weak self] in self?.settingsWindow.update(provider, status: $0) }
            controller.onVisibilityChange = { [weak self] in
                DispatchQueue.main.async { self?.updateFallbackItem() }
            }
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
        updater.onUpdateAvailable = { [weak self] version, build in
            self?.notifications.updateAvailable(version: version, build: build)
        }
        notifications.onUpdateNotificationOpened = { [weak self] in
            self?.updater.openUpdateFromNotification()
        }
        updater.onWillPresentUpdate = { [weak self] in
            self?.builtItems?.menu.cancelTracking()
            self?.extraProviders.forEach { $0.dismissMenu() }
        }
        notifications.start()
        do { try LoginLaunchController().applyInitialDefault() }
        catch { NSLog("PlusCodex login item: %@", error.localizedDescription) }
        updater.start()
        activityMonitor = ThreadActivityMonitor { [weak self] activities, _ in
            guard let self else { return }
            self.activities = activities
            self.updateActivityView()
        }
        activityMonitor?.onCompletion = { [weak self] activity in self?.notifications.completed(activity) }
        activityMonitor?.onFailure = { [weak self] activity in self?.notifications.failed(activity) }
        activityMonitor?.onAttention = { [weak self] event in self?.notifications.attentionNeeded(event) }
        activityMonitor?.start()
        timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkCodexLoginChange()
            self?.requestRefresh(retryWhenBusy: false)
            self?.extraProviders.forEach { $0.synchronize() }
            if let self { self.wakeScheduler.tick(quota: self.quota, offline: self.offline) }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeFromSleep),
                                                         name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(codexApplicationActivated(_:)),
                                                         name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func codexApplicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.openai.codex" else { return }
        // The auth file may be written just after Codex regains focus from a browser sign-in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkCodexLoginChange()
        }
    }

    private func checkCodexLoginChange() {
        let revision = CodexAuthRevision.current()
        guard revision != codexAuthRevision else { return }
        codexAuthRevision = revision
        quota = nil
        account = nil
        updatedAt = nil
        failure = nil
        render()
        if providerSettings.enabled(.codex) { requestRefresh(retryWhenBusy: true) }
    }

    @objc private func wokeFromSleep() {
        refresh()
        wakeScheduler.tick(quota: quota, offline: offline)
    }

    @objc private func refresh() { requestRefresh(retryWhenBusy: true) }

    private func requestRefresh(retryWhenBusy: Bool) {
        guard providerSettings.enabled(.codex), !offline else { return }
        if fetching {
            if retryWhenBusy { refreshPending = true }
            return
        }
        let requestRevision = CodexAuthRevision.current()
        codexAuthRevision = requestRevision
        refreshGeneration += 1
        let generation = refreshGeneration
        fetching = true
        statusWindow.update(quota: quota, fetching: true, failure: nil)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try QuotaClient.fetchSnapshot { quota in
                RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                    guard self.refreshGeneration == generation,
                          CodexAuthRevision.current() == requestRevision,
                          self.providerSettings.enabled(.codex) else { return }
                    self.quota = quota
                    self.updatedAt = Date()
                    self.failure = nil
                    self.codexExecutableMissing = false
                    self.render()
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            } }
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                self.fetching = false
                let authChanged = CodexAuthRevision.current() != requestRevision
                if authChanged {
                    self.codexAuthRevision = CodexAuthRevision.current()
                    self.quota = nil
                    self.account = nil
                    self.updatedAt = nil
                    self.failure = nil
                    self.refreshPending = true
                } else if self.providerSettings.enabled(.codex) {
                    switch result {
                case .success(let snapshot):
                    self.notifications.scheduleResets(snapshot.quota, account: snapshot.account)
                    self.notifications.checkThresholds(snapshot.quota, account: snapshot.account)
                    self.quota = snapshot.quota
                    self.account = snapshot.account
                    let refreshedAt = Date()
                    self.updatedAt = refreshedAt
                    self.failure = nil
                    self.codexExecutableMissing = false
                    self.settingsWindow.update(.codex, status: snapshot.account?.email ?? L10n.text("연결됨 · 사용량 조회 완료"))
                    self.wakeScheduler.tick(quota: self.quota, offline: self.offline,
                                            quotaFetchedAt: refreshedAt, now: refreshedAt)
                case .failure(let error):
                    self.failure = error.localizedDescription
                    self.codexExecutableMissing = (error as? QuotaError)?.isMissingExecutable == true
                    self.settingsWindow.update(.codex, status: error.localizedDescription)
                    }
                }
                self.render()
                if self.refreshPending && self.providerSettings.enabled(.codex) && !self.offline {
                    self.refreshPending = false
                    self.requestRefresh(retryWhenBusy: false)
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func render() {
        // Replacing or hiding menu items while AppKit is tracking the popup can dismiss it.
        guard !menuTracking else { return }
        statusWindow.update(quota: quota, fetching: fetching, failure: failure)
        let primary = quota?.primary ?? quota?.secondary
        let valid = failure == nil
        let unavailable = offline || codexExecutableMissing || failure != nil
        let percent = unavailable ? ""
            : valid ? primary.map { "\($0.displayPercent(showRemaining: providerSettings.showRemaining(.codex)))%" } ?? (quota == nil ? "…" : "—") : "--%"
        if let button = item?.button {
            button.image = CodexStatusIcon.image(size: 18, offline: unavailable)
            button.imagePosition = unavailable ? .imageOnly : .imageLeading
            button.attributedTitle = NSAttributedString(string: unavailable ? "" : " " + percent, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: unavailable ? 9 : 11, weight: .medium),
                .foregroundColor: unavailable ? NSColor.systemGray : NSColor.labelColor
            ])
            let unavailableTitle = L10n.text(offline ? "네트워크 연결 없음"
                : codexExecutableMissing ? "Codex를 찾을 수 없음" : "사용량 조회 실패")
            button.setAccessibilityLabel(unavailable ? unavailableTitle : L10n.text("Codex 남은 사용량 ") + percent)
            button.toolTip = unavailable ? unavailableTitle : L10n.text("Codex · %@ 잔여 %@", primary?.displayLabel(planType: account?.planType, isPrimary: quota?.primary != nil) ?? L10n.text("사용 한도"), percent)
        }
        // Measure AppKit's native row heights before hiding them; the status panel
        // then occupies exactly the same menu content area, including action rows.
        let intro = false
        let oldPanel = dashboardItem?.view as? QuotaMenuView
        let stateScreen = (offline || codexExecutableMissing || failure != nil || checkingForUpdates)
            && builtItems != nil
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
           panel.checkingForUpdates == checkingForUpdates, panel.offline == offline,
           panel.missingExecutable == codexExecutableMissing,
           panel.failure == failure,
           panel.showRemaining == providerSettings.showRemaining(.codex) {
            panel.update(quota: quota, account: account, updatedAt: updatedAt, failure: failure)
            return
        }
        let panel = QuotaMenuView(quota: quota, account: account, updatedAt: updatedAt,
                                  failure: failure, intro: intro, checkingForUpdates: stateScreen && checkingForUpdates,
                                  offline: stateScreen && offline,
                                  missingExecutable: stateScreen && codexExecutableMissing,
                                  preservedHeight: stateScreenHeight,
                                  showRemaining: providerSettings.showRemaining(.codex))
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
        if offline || codexExecutableMissing || failure != nil || checkingForUpdates { render() }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        checkCodexLoginChange()
        extraProviders.forEach { $0.synchronize() }
        settingsWindow.present()
    }

    @objc private func languageDidChange() {
        refreshItem?.title = L10n.text("지금 새로고침")
        quitItem?.title = L10n.text("PlusCodex 종료")
        settingsItem?.title = L10n.text("설정")
        extraProviders.forEach { $0.reloadLocalization() }
        updateFallbackItem()
        settingsWindow.reloadLocalization()
        statusWindow.reloadLocalization()
        updateActivityView()
        render()
    }

    private func synchronizeProviders() {
        if providerSettings.enabled(.codex) {
            if item == nil {
                item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item?.autosaveName = "CodexQuota"
                item?.button?.target = self
                item?.button?.action = #selector(statusClicked)
                item?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                refresh()
            }
            render()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            settingsWindow.update(.codex, status: L10n.text("메뉴바에서 꺼짐"))
        }
        extraProviders.forEach { $0.synchronize() }
        settingsWindow.synchronize()
        updateFallbackItem()
    }

    static func needsFallbackStatusItem(codexVisible: Bool, providerVisibility: [Bool]) -> Bool {
        !codexVisible && !providerVisibility.contains(true)
    }

    private func updateFallbackItem() {
        let needsFallback = Self.needsFallbackStatusItem(
            codexVisible: item?.isVisible ?? false,
            providerVisibility: extraProviders.map(\.hasVisibleStatusItem))
        if needsFallback {
            if fallbackItem == nil {
                let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                status.autosaveName = "PlusCodex.fallback"
                status.button?.image = CodexStatusIcon.plusCodexImage(size: 18)
                status.button?.imagePosition = .imageOnly
                status.button?.target = self
                status.button?.action = #selector(openSettings)
                fallbackItem = status
            }
            let title = L10n.text("PlusCodex 설정")
            fallbackItem?.button?.toolTip = title
            fallbackItem?.button?.setAccessibilityLabel(title)
        } else if let fallbackItem {
            NSStatusBar.system.removeStatusItem(fallbackItem)
            self.fallbackItem = nil
        }
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
        menuTracking = true
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        render()
        updateActivityView()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        (activityItem?.view as? ThreadActivityView)?.refreshHover()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Notification clicks also reopen the app. Settings must only open from the menu,
        // otherwise they steal focus before the notification delegate opens the Codex thread.
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
        guard !menuTracking else { return }
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
    func testHookSetMissingExecutable(_ value: Bool) {
        codexExecutableMissing = value
        render()
    }
    func testHookSetFailure(_ value: String?) {
        failure = value
        render()
    }
}
