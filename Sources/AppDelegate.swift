import AppKit
import Network

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem?
    private var fallbackItem: NSStatusItem?
    private var timer: Timer?
    private var fetching = false
    private var refreshPending = false
    private var completionRefreshTimer: Timer?
    private var lastRefreshStartedAt = Date.distantPast
    private var refreshGeneration = 0
    private var codexAuthRevision = CodexAuthRevision.current()
    private var quota: Quota?
    private var schedulingQuota: Quota?
    private let resetSchedule = CodexResetSchedule()
    private var account: CodexAccount?
    private var updatedAt: Date?
    private var failure: String?
    private var codexExecutableMissing = false
    private var activityMonitor: ThreadActivityMonitor?
    private var activities: [ThreadActivity] = []
    private var activityConnected = false
    private var activityCompatibilityIssue = false
    private var activityItem: NSMenuItem?
    private var dashboardItem: NSMenuItem?
    private var discordItem: NSMenuItem?
    private var quitItem: NSMenuItem?
    private var separatorItem: NSMenuItem?
    private var builtItems: StatusMenuBuilder.Items?
    private var readReceipts = ThreadActivityReadReceipts()
    private var recordAccount: String?
    private func selectRecordAccount(_ identity: String?) {
        guard recordAccount != identity else { return }
        recordAccount = identity
        readReceipts = identity.map { ThreadActivityReadReceipts(defaults: .standard, account: $0) } ?? ThreadActivityReadReceipts()
        activityMonitor?.selectAccount(identity)
    }
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
        NotificationCenter.default.addObserver(self, selector: #selector(threadNotificationChanged),
            name: .threadNotificationPreferenceChanged, object: nil)
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
                guard let self else { return }
                let wasChecking = self.checkingForUpdates
                self.checkingForUpdates = checking
                self.extraProviders.forEach { $0.presentation(offline: self.offline, checking: checking) }
                if !self.menuTracking || wasChecking != checking {
                    self.render(allowingTrackedUpdateTransition: self.menuTracking)
                }
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
        activityMonitor = ThreadActivityMonitor { [weak self] activities, connected in
            guard let self else { return }
            self.activities = activities
            self.activityConnected = connected
            self.updateActivityView()
        }
        activityMonitor?.onCompletion = { [weak self] activity in
            guard let self else { return }
            self.scheduleCompletionRefresh()
            // Automatic wake is maintenance work; do not pin its success as
            // an unread user task or generate a completion notification.
            guard activity.id != self.wakeSettings.threadID else { return }
            self.readReceipts.markCompleted(activity)
            self.notifications.completed(activity)
            self.updateActivityView()
        }
        activityMonitor?.onRead = { [weak self] activity in
            guard let self else { return }
            self.readReceipts.acknowledgeExternally(activity)
            self.updateActivityView()
        }
        activityMonitor?.onFailure = { [weak self] activity in self?.notifications.failed(activity) }
        activityMonitor?.onArchive = { [weak self] id in
            self?.readReceipts.forget(id)
            self?.activities.removeAll { $0.id == id }
            self?.updateActivityView()
        }
        activityMonitor?.onAttention = { [weak self] event in self?.notifications.attentionNeeded(event) }
        activityMonitor?.onCompatibilityChanged = { [weak self] incompatible in
            guard let self, self.activityCompatibilityIssue != incompatible else { return }
            self.activityCompatibilityIssue = incompatible
            self.updateActivityView()
        }
        notifications.isAttentionRequestCurrent = { [weak self] id, identity in
            guard let self, self.activityConnected,
                  let activity = self.activities.first(where: { $0.id == id }), activity.stateConfirmed else { return false }
            if let identity { return activity.pendingRequests.contains { $0.identity == identity } }
            return activity.isWaitingForApproval
        }
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
        notifications.invalidateResetAccount()
        selectRecordAccount(nil)
        schedulingQuota = nil
        resetSchedule.invalidateAccount()
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

    private func scheduleCompletionRefresh() {
        // Batch simultaneous completions without delaying indefinitely under load.
        guard completionRefreshTimer == nil else { return }
        let delay = max(2, 10 - Date().timeIntervalSince(lastRefreshStartedAt))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.completionRefreshTimer = nil
            self?.requestRefresh(retryWhenBusy: true)
        }
        completionRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func requestRefresh(retryWhenBusy: Bool) {
        guard providerSettings.enabled(.codex), !offline else { return }
        if fetching {
            if retryWhenBusy { refreshPending = true }
            return
        }
        let requestRevision = CodexAuthRevision.current()
        lastRefreshStartedAt = Date()
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
                    self.notifications.invalidateResetAccount()
                    self.selectRecordAccount(nil)
                    self.codexAuthRevision = CodexAuthRevision.current()
                    self.schedulingQuota = nil
                    self.resetSchedule.invalidateAccount()
                    self.quota = nil
                    self.account = nil
                    self.updatedAt = nil
                    self.failure = nil
                    self.refreshPending = true
                } else if self.providerSettings.enabled(.codex) {
                    switch result {
                case .success(let snapshot):
                    self.notifications.checkThresholds(snapshot.quota, account: snapshot.account)
                    self.notifications.scheduleResetCreditExpiry(snapshot.rateLimitResetCredits,
                                                                  account: snapshot.account)
                    self.quota = snapshot.quota
                    self.account = snapshot.account
                    let refreshedAt = Date()
                    let scheduledQuota = self.resetSchedule.update(snapshot.quota, account: snapshot.account,
                                                                   now: refreshedAt)
                    self.schedulingQuota = self.resetSchedule.resolvedAccount == nil ? nil : scheduledQuota
                    self.updatedAt = refreshedAt
                    self.failure = nil
                    self.codexExecutableMissing = false
                    self.settingsWindow.update(.codex, status: snapshot.account?.email ?? L10n.text("연결됨 · 사용량 조회 완료"))
                    if let identity = self.resetSchedule.resolvedAccount {
                        self.selectRecordAccount(identity)
                        self.wakeSettings.selectAccount(identity)
                        self.notifications.scheduleResets(scheduledQuota,
                            account: CodexAccount(email: identity, planType: snapshot.account?.planType))
                        self.wakeScheduler.tick(quota: snapshot.quota, offline: self.offline,
                                                quotaFetchedAt: refreshedAt, now: refreshedAt)
                    }
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

    private func render(allowingTrackedUpdateTransition: Bool = false) {
        statusWindow.update(quota: quota, fetching: fetching, failure: failure)
        let primary = quota?.primary ?? quota?.secondary
        let showingPreviousUsage = failure != nil
            && QuotaMenuView.canShowPreviousUsage(quota, updatedAt: updatedAt)
        let failureScreen = failure != nil && !showingPreviousUsage
        let unavailable = offline || codexExecutableMissing || failureScreen
        let percent = unavailable ? ""
            : primary.map { "\($0.displayPercent(showRemaining: providerSettings.showRemaining(.codex)))%" } ?? (quota == nil ? "…" : "—")
        if let button = item?.button {
            button.image = CodexStatusIcon.image(size: 18, offline: unavailable)
            button.imagePosition = unavailable ? .imageOnly : .imageLeading
            button.attributedTitle = NSAttributedString(string: unavailable ? "" : " " + percent, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: unavailable ? 9 : 11, weight: .medium),
                .foregroundColor: unavailable ? NSColor.systemGray : NSColor.labelColor
            ])
            let unavailableTitle = L10n.text(offline ? "네트워크 연결 없음"
                : codexExecutableMissing ? "Codex를 찾을 수 없음" : "사용량 조회 실패")
            let usageAccessibility = L10n.text("Codex 남은 사용량 ") + percent
            button.setAccessibilityLabel(unavailable ? unavailableTitle
                : showingPreviousUsage ? L10n.text("이전 조회") + " · " + usageAccessibility : usageAccessibility)
            let usageTitle = L10n.text("Codex · %@ 잔여 %@", primary?.displayLabel(planType: account?.planType, isPrimary: quota?.primary != nil) ?? L10n.text("사용 한도"), percent)
            button.toolTip = unavailable ? unavailableTitle
                : showingPreviousUsage ? L10n.text("이전 조회") + " · " + usageTitle : usageTitle
        }
        // While tracking, mutate existing content only. Native menu restructuring
        // is deferred to close; update-check transitions keep their existing path.
        if menuTracking && !allowingTrackedUpdateTransition {
            if let panel = dashboardItem?.view as? QuotaMenuView {
                panel.update(quota: quota, account: account, updatedAt: updatedAt,
                             failure: failure)
            }
            updateActivityView()
            return
        }
        // Measure AppKit's native row heights before hiding them; the status panel
        // then occupies exactly the same menu content area, including action rows.
        let intro = false
        let oldPanel = dashboardItem?.view as? QuotaMenuView
        let stateScreen = (offline || codexExecutableMissing || failureScreen || checkingForUpdates)
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
           panel.showsFailureScreen == failureScreen,
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
                                    separator: built.separator, discord: built.discord, quit: built.quit)
            updateActivityView()
            return
        }
        let built = StatusMenuBuilder.make(intro: intro, dashboardView: panel, delegate: self,
                                           target: self, discordAction: #selector(openDiscord),
                                           quitAction: #selector(quitApp))
        builtItems = built
        let settings = NSMenuItem(title: L10n.text("설정"), action: #selector(openSettings), keyEquivalent: ",")
        settings.image = nil
        settings.target = self
        built.menu.insertItem(settings, at: built.menu.items.count - 1)
        settingsItem = settings
        dashboardItem = built.dashboard
        activityItem = built.activity
        discordItem = built.discord
        quitItem = built.quit
        separatorItem = built.separator
        updateActivityView()
        if offline || codexExecutableMissing || failure != nil || checkingForUpdates { render() }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openDiscord() {
        NSWorkspace.shared.open(URL(string: "https://discord.gg/jR87pagNRG")!)
    }

    @objc private func openSettings() {
        checkCodexLoginChange()
        extraProviders.forEach { $0.synchronize() }
        settingsWindow.present()
    }

    @objc private func languageDidChange() {
        if let discordItem { StatusMenuBuilder.configureDiscord(discordItem) }
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
        } else {
            notifications.invalidateResetCreditExpiry()
            if let item {
                NSStatusBar.system.removeStatusItem(item)
                self.item = nil
                settingsWindow.update(.codex, status: L10n.text("메뉴바에서 꺼짐"))
            }
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
            // Prepare the existing full-size checking screen before AppKit starts menu tracking.
            if !offline { updater.checkOnMenuOpen() }
            checkingForUpdates = updater.isChecking
            render()
            builtItems?.menu.popUpFollowingSystemAppearance(from: button)
        }
    }

    @objc private func disableCodex() {
        DispatchQueue.main.async { self.providerSettings.setEnabled(false, for: .codex) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkingForUpdates = updater.isChecking
        render()
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
    func testHookSetActivities(_ value: [ThreadActivity], connected: Bool = true) {
        activities = value
        activityConnected = connected
        updateActivityView()
    }
    func testHookMenuWillOpen(_ menu: NSMenu) { menuWillOpen(menu) }
    func testHookRenderForMenu() { render() }
    var testHookDashboardView: NSView? { dashboardItem?.view }
    var testHookMenu: NSMenu? { builtItems?.menu }
    var testHookMenuItemCount: Int {
        guard let built = builtItems else { return 0 }
        return [built.dashboard, built.activity, built.separator, built.discord, built.quit]
            .filter { !$0.isHidden }.count
    }
    func testHookSetQuota(_ value: Quota?) { quota = value }
    func testHookSetMenuTracking(_ value: Bool) { menuTracking = value }
    func testHookSetUpdatedAt(_ value: Date?) { updatedAt = value }

    private func updateActivityView() {
        if stateScreenHeight != nil {
            if !menuTracking, activityItem?.isHidden == false { activityItem?.isHidden = true }
            return
        }
        let visible = readReceipts.visibleRows(activities)
        if let view = activityItem?.view as? ThreadActivityView {
            view.update(activities: visible, preserveHeight: menuTracking, connected: activityConnected,
                        incompatible: activityCompatibilityIssue)
        } else if !menuTracking {
            activityItem?.view = ThreadActivityView(activities: visible) { [weak self] opened in
                guard let self else { return }
                self.readReceipts.acknowledge(opened)
                self.updateActivityView()
            }
            (activityItem?.view as? ThreadActivityView)?.update(activities: visible, connected: activityConnected,
                                                             incompatible: activityCompatibilityIssue)
        }
        let rowView = activityItem?.view
        let alpha: CGFloat = activityConnected ? 1 : 0.55
        if rowView?.alphaValue != alpha { rowView?.alphaValue = alpha }
        let toolTip = activityConnected ? nil : L10n.text("작업 상태 연결 복구 중 · 마지막 확인 정보")
        if rowView?.toolTip != toolTip { rowView?.toolTip = toolTip }
        if !menuTracking, activityItem?.isHidden == true { activityItem?.isHidden = false }
    }

    func applicationWillTerminate(_ notification: Notification) { networkMonitor.cancel() }
    @objc private func threadNotificationChanged() { updateActivityView() }

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
