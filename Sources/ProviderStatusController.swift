import AppKit

/// Owns one additional provider's status item and independent refresh lifecycle.
final class ProviderStatusController: NSObject, NSMenuDelegate {
    let provider: AIProvider
    private let settings: ProviderSettings
    private let claudeAvailability: () -> ClaudeAvailability.State
    private let grokAvailability: () -> GrokAvailability.State
    private let geminiAvailability: () -> GeminiAvailability.State
    private let fetchUsage: (AIProvider) throws -> QuotaSnapshot
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private let dashboard = NSMenuItem()
    private let activityItem = NSMenuItem()
    private var actions: [NSMenuItem] = []
    private var snapshot: QuotaSnapshot?
    private var snapshotAt: Date?
    private var snapshotRevision: Data?
    private var failure: String?
    private var fetching = false
    private var nextFetch = Date.distantPast
    private var throttledUntil = Date.distantPast
    private var overlayHeight: CGFloat?
    private var offline = false
    private var checking = false
    private var menuTracking = false
    private var previouslyEnabled = false
    private var activities: [ThreadActivity] = []
    private var activityConnected = false
    private var activityMonitoringStarted = false
    private var activityPolling = false
    private var activityTimer: Timer?
    private var completionTracker: CompletionTracker
    private var attentionTracker = AttentionTracker()
    private var readReceipts: ThreadActivityReadReceipts
    private let activityDefaults: UserDefaults
    private var acknowledgedReadTurns: [String: String] = [:]
    private var visibleReadCandidate: (id: String, turn: String, updatedAt: Double, since: Double)?
    private var selectedActivityAccount: String?
    private var iconUnavailable = false
    private var spinTimer: Timer?
    private var spinFrame = 0
    var onOpen: (() -> Void)?
    var onSettings: (() -> Void)?
    var onState: ((String) -> Void)?
    var onQuota: ((Quota?) -> Void)?
    var onVisibilityChange: (() -> Void)?
    var onCompletion: ((ThreadActivity) -> Void)?
    var onFailure: ((ThreadActivity) -> Void)?
    var onAttention: ((ThreadAttentionEvent) -> Void)?
    var onRead: ((ThreadActivity) -> Void)?
    var hasVisibleStatusItem: Bool { item?.isVisible ?? false }

    init(provider: AIProvider, settings: ProviderSettings,
         claudeAvailability: @escaping () -> ClaudeAvailability.State = { ClaudeAvailability.current() },
         grokAvailability: @escaping () -> GrokAvailability.State = { GrokAvailability.current() },
         geminiAvailability: @escaping () -> GeminiAvailability.State = { GeminiAvailability.current() },
         fetchUsage: @escaping (AIProvider) throws -> QuotaSnapshot = ExternalUsageClient.fetch,
         activityDefaults: UserDefaults = .standard) {
        self.provider = provider
        self.settings = settings
        self.claudeAvailability = claudeAvailability
        self.grokAvailability = grokAvailability
        self.geminiAvailability = geminiAvailability
        self.fetchUsage = fetchUsage
        self.activityDefaults = activityDefaults
        completionTracker = CompletionTracker(defaults: activityDefaults, account: "gemini:local")
        readReceipts = ThreadActivityReadReceipts(defaults: activityDefaults, account: "gemini:local")
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(threadNotificationChanged),
            name: .threadNotificationPreferenceChanged, object: nil)
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(dashboard)
        activityItem.isHidden = true
        menu.addItem(activityItem)
        let separator = NSMenuItem.separator()
        menu.addItem(separator)
        actions = [separator]
        for (title, selector, shortcut) in [
            (L10n.text("설정"), #selector(settingsClicked), ","),
            (L10n.text("PlusCodex 종료"), #selector(quit), "q")
        ] {
            let row = NSMenuItem(title: title, action: selector, keyEquivalent: shortcut)
            row.target = self
            menu.addItem(row)
            actions.append(row)
        }
        render()
    }

    func startActivityMonitoring() {
        guard provider == .gemini else { return }
        activityMonitoringStarted = true
        updateActivityMonitoring()
    }

    func isAttentionRequestCurrent(id: String, identity: String?) -> Bool {
        guard activityConnected,
              let activity = activities.first(where: { $0.id == id }),
              activity.stateConfirmed else { return false }
        if let identity { return activity.pendingRequests.contains { $0.identity == identity } }
        return activity.isWaitingForApproval
    }

    private func selectActivityAccount(_ email: String?) {
        guard provider == .gemini else { return }
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = "gemini:" + ((trimmed?.isEmpty == false ? trimmed : nil) ?? "local")
        guard selectedActivityAccount != resolved else { return }
        selectedActivityAccount = resolved
        completionTracker = CompletionTracker(defaults: activityDefaults, account: resolved)
        readReceipts = ThreadActivityReadReceipts(defaults: activityDefaults, account: resolved)
        acknowledgedReadTurns.removeAll()
        visibleReadCandidate = nil
    }

    private func updateActivityMonitoring() {
        guard provider == .gemini else { return }
        if activityMonitoringStarted && settings.enabled(.gemini) {
            if activityTimer == nil {
                let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                    self?.pollActivities()
                }
                activityTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .eventTracking)
            }
            pollActivities()
        } else {
            visibleReadCandidate = nil
            activityTimer?.invalidate()
            activityTimer = nil
            activityPolling = false
            if !activities.isEmpty || activityConnected {
                activities = []
                activityConnected = false
                acknowledgedReadTurns.removeAll()
                updateActivityView()
            }
        }
    }

    private func pollActivities() {
        guard activityMonitoringStarted, provider == .gemini, settings.enabled(.gemini), !activityPolling else { return }
        let antigravityRunning = AntigravityConversationReader.bundleIDs.contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        guard antigravityRunning else {
            visibleReadCandidate = nil
            if activityConnected || !activities.isEmpty {
                activities = []
                activityConnected = false
                acknowledgedReadTurns.removeAll()
                updateActivityView()
            }
            return
        }
        activityPolling = true
        let foregroundPID = AntigravityConversationReader.foregroundPID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fetched = ExternalUsageClient.fetchAntigravityTrajectories()
            let visibleID = foregroundPID.flatMap { AntigravityConversationReader.currentConversationID(pid: $0) }
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
                guard let self else { return }
                self.activityPolling = false
                guard self.activityMonitoringStarted, self.settings.enabled(.gemini) else { return }
                if let fetched {
                    let stillVisible = foregroundPID != nil
                        && AntigravityConversationReader.foregroundPID == foregroundPID
                    self.applyPolledActivities(fetched.activities, viewedAt: fetched.viewedAt, connected: true,
                        visibleConversationID: stillVisible ? visibleID : nil)
                } else if self.activityConnected {
                    self.visibleReadCandidate = nil
                    self.activityConnected = false
                    self.updateActivityView()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func applyPolledActivities(_ rows: [ThreadActivity], viewedAt: [String: Double], connected: Bool,
                                      visibleConversationID: String? = nil,
                                      observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        let previousCandidate = visibleReadCandidate
        visibleReadCandidate = nil
        var foregroundReadID: String?
        if connected, let visibleConversationID,
           let row = rows.first(where: { $0.id.caseInsensitiveCompare(visibleConversationID) == .orderedSame }),
           row.stateConfirmed, !row.isRunning, let turn = row.latestTurn?.id {
            let sameResult = previousCandidate.map {
                $0.id == row.id && $0.turn == turn && $0.updatedAt == row.updatedAt
                    && observedAt >= $0.since && observedAt - $0.since <= 6
            } ?? false
            if sameResult, let previousCandidate, observedAt - previousCandidate.since >= 1 {
                foregroundReadID = row.id
            }
            visibleReadCandidate = (row.id, turn, row.updatedAt,
                                    sameResult ? previousCandidate!.since : observedAt)
        }
        let previousIDs = Set(activities.map(\.id))
        let currentIDs = Set(rows.map(\.id))
        for removedID in previousIDs.subtracting(currentIDs) {
            readReceipts.forget(removedID)
            acknowledgedReadTurns.removeValue(forKey: removedID)
        }
        let turnResults = completionTracker.update(rows, connected: connected)
        let attentionEvents = attentionTracker.update(rows, connected: connected)
        activities = rows
        activityConnected = connected
        var completedAny = false
        for result in turnResults {
            switch result.kind {
            case .completed:
                completedAny = true
                readReceipts.markCompleted(result.activity)
                onCompletion?(result.activity)
            case .failed:
                completedAny = true
                onFailure?(result.activity)
            }
        }
        for event in attentionEvents {
            onAttention?(event)
        }
        let justFinished = Set(turnResults.map { $0.activity.id })
        for activity in rows {
            let timestampRead = !activity.unread
                && viewedAt[activity.id].map { $0 + 0.05 >= activity.updatedAt } == true
            guard connected, activity.stateConfirmed, !activity.isRunning,
                  timestampRead || foregroundReadID == activity.id,
                  !justFinished.contains(activity.id) else { continue }
            let identity = activity.latestTurn?.id ?? String(activity.updatedAt)
            guard acknowledgedReadTurns[activity.id] != identity else { continue }
            // Let a fresh completion submit first. The next poll can acknowledge
            // an already-open result without requiring another view-time change.
            acknowledgedReadTurns[activity.id] = identity
            readReceipts.acknowledgeExternally(activity)
            onRead?(activity)
        }
        updateActivityView()
        if completedAny {
            nextFetch = throttledUntil
            refresh()
        }
    }

    func synchronize() {
        let wasVisible = hasVisibleStatusItem
        defer {
            updateActivityMonitoring()
            updateStatusSpinner()
            if wasVisible != hasVisibleStatusItem { onVisibilityChange?() }
        }
        let enabled = settings.enabled(provider)
        // An explicit retry may clear an expired delay, but must not bypass
        // a server-provided Retry-After window.
        if enabled && !previouslyEnabled { nextFetch = throttledUntil }
        previouslyEnabled = enabled
        if provider == .claude {
            let availability = claudeAvailability()
            if availability != .availableOrUnknown {
                if settings.enabled(provider) { settings.setEnabled(false, for: provider) }
                if let item {
                    StatusMenuPresentation.unregister(item)
                    NSStatusBar.system.removeStatusItem(item)
                }
                item = nil
                snapshot = nil
                failure = nil
                onState?(L10n.text(availability.guidance ?? "메뉴바에서 꺼짐"))
                return
            }
        }
        if provider == .grok, let guidance = grokAvailability().guidance {
            if enabled { settings.setEnabled(false, for: provider) }
            if let item {
                StatusMenuPresentation.unregister(item)
                NSStatusBar.system.removeStatusItem(item)
            }
            item = nil
            snapshot = nil
            failure = nil
            onState?(L10n.text(guidance))
            return
        }
        if provider == .gemini, let guidance = geminiAvailability().guidance {
            if enabled { settings.setEnabled(false, for: provider) }
            if let item {
                StatusMenuPresentation.unregister(item)
                NSStatusBar.system.removeStatusItem(item)
            }
            item = nil
            snapshot = nil
            failure = nil
            onState?(L10n.text(guidance))
            return
        }
        if settings.enabled(provider) {
            if provider == .grok && !settings.grokUsageVerified {
                if let item {
                    StatusMenuPresentation.unregister(item)
                    NSStatusBar.system.removeStatusItem(item)
                }
                item = nil
                refresh()
                return
            }
            if item == nil {
                let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                status.autosaveName = "PlusCodex.\(provider.rawValue)"
                status.button?.configureMenuTracking(target: self, action: #selector(clicked))
                item = status
            }
            refresh()
            render()
        } else {
            if let item {
                StatusMenuPresentation.unregister(item)
                NSStatusBar.system.removeStatusItem(item)
            }
            self.item = nil
            snapshot = nil
            snapshotAt = nil
            failure = nil
            nextFetch = throttledUntil
            onState?(L10n.text("메뉴바에서 꺼짐"))
        }
    }

    func reloadLocalization() {
        guard actions.count >= 3 else { return }
        actions[1].title = L10n.text("설정")
        actions[2].title = L10n.text("PlusCodex 종료")
        updateActivityView()
        // Recompute the current status text as well; otherwise a status
        // emitted before the language change can remain in the old language.
        synchronize()
    }

    func presentation(offline: Bool, checking: Bool) {
        let reconnected = self.offline && !offline
        let wasChecking = self.checking
        self.offline = offline
        self.checking = checking
        render(allowingTrackedUpdateTransition: menuTracking && wasChecking != checking)
        if reconnected {
            nextFetch = throttledUntil
            refresh()
        }
    }

    func refresh() {
        guard settings.enabled(provider), !fetching, !offline else { return }
        guard Date() >= nextFetch else {
            if snapshot == nil && failure == nil { onState?(L10n.text("다음 사용량 조회 대기 중")) }
            return
        }
        fetching = true
        onState?(L10n.text("사용량 확인 중"))
        render()
        let provider = self.provider
        let fetchUsage = self.fetchUsage
        let generation = settings.generation(provider)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let revision = ExternalUsageClient.authenticationRevision(provider)
            let result = Result { try fetchUsage(provider) }
            let unchanged = revision == ExternalUsageClient.authenticationRevision(provider)
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
                guard let self else { return }
                self.fetching = false
                guard self.settings.enabled(provider) else { return }
                guard unchanged, self.settings.generation(provider) == generation else {
                    self.snapshot = nil
                    self.failure = nil
                    self.nextFetch = self.throttledUntil
                    self.refresh()
                    return
                }
                switch result {
                case .success(let snapshot):
                    if provider == .grok {
                        guard self.grokAvailability() == .readyToCheck else {
                            self.settings.setEnabled(false, for: provider)
                            self.onState?(L10n.text("Grok에 로그인하세요."))
                            return
                        }
                        guard GrokAvailability.hasDisplayableUsage(snapshot) else {
                            self.settings.setEnabled(false, for: provider)
                            self.onState?(L10n.text("이 계정에서 사용량 퍼센트를 제공하지 않습니다."))
                            return
                        }
                    }
                    self.selectActivityAccount(snapshot.account?.email)
                    self.snapshot = snapshot
                    self.onQuota?(snapshot.quota)
                    self.snapshotAt = Date()
                    self.snapshotRevision = revision
                    self.failure = nil
                    self.nextFetch = Date().addingTimeInterval(provider == .claude ? 300 : 60)
                    if provider == .grok { self.settings.setGrokUsageVerified(true) }
                    self.onState?(snapshot.quota.windows.isEmpty && provider == .claude
                        ? L10n.text("Claude Desktop 연결됨 · 사용량 수치 미제공")
                        : snapshot.account?.email ?? L10n.text("연결됨 · 사용량 조회 완료"))
                case .failure(let error):
                    if case UsageFailure.throttled(let date) = error { self.throttledUntil = date }
                    let noSubscriptionUsage = (error as? UsageFailure).map {
                        if case .subscriptionUsageUnavailable = $0 { return true }
                        return false
                    } ?? false
                    if provider == .grok && noSubscriptionUsage {
                        if case UsageFailure.throttled(let date) = error { self.nextFetch = date }
                        self.settings.setEnabled(false, for: provider)
                        self.onState?(error.localizedDescription)
                        return
                    }
                    self.failure = error.localizedDescription
                    let invalidCredentials: Bool
                    switch error as? UsageFailure {
                    case .authentication?, .credentialsUnavailable?, .missingScope?, .subscriptionUsageUnavailable?:
                        invalidCredentials = true
                    default: invalidCredentials = false
                    }
                    // Only a confirmed unchanged credential revision may retain old usage.
                    if invalidCredentials || revision == nil || revision != self.snapshotRevision
                        || !QuotaMenuView.canShowPreviousUsage(self.snapshot?.quota, updatedAt: self.snapshotAt) {
                        self.snapshot = nil
                        self.onQuota?(nil)
                        self.snapshotAt = nil
                    }
                    if case UsageFailure.throttled(let date) = error { self.nextFetch = date }
                    else { self.nextFetch = Date().addingTimeInterval(provider == .claude ? 300 : 60) }
                    self.onState?(error.localizedDescription)
                }
                self.render()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func render(allowingTrackedUpdateTransition: Bool = false) {
        // Claude Desktop can be connected without providing a usage percentage.
        // Keep that state in Settings, but do not occupy the menu bar with an empty item.
        if provider == .claude {
            let wasVisible = hasVisibleStatusItem
            let visible = failure != nil || offline || snapshot?.quota.windows.isEmpty == false
            item?.isVisible = visible
            item?.button?.isHidden = !visible
            if wasVisible != hasVisibleStatusItem { onVisibilityChange?() }
        }
        let showRemaining = settings.showRemaining(provider)
        let formatted = MenuBarFormat.render(settings.menuBarFormat(provider), quota: snapshot?.quota,
                                             showRemaining: showRemaining)
        let percent = formatted.isEmpty ? "" : " " + formatted
        let showingPreviousUsage = failure != nil
            && QuotaMenuView.canShowPreviousUsage(snapshot?.quota, updatedAt: snapshotAt)
        let unavailable = offline || (failure != nil && !showingPreviousUsage)
        iconUnavailable = unavailable
        updateStatusSpinner()
        item?.button?.image = providerStatusImage()
        item?.button?.imagePosition = unavailable || percent.isEmpty ? .imageOnly : .imageLeading
        item?.button?.attributedTitle = NSAttributedString(string: unavailable ? "" : percent, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
        let unavailableTitle = L10n.text(offline ? "네트워크 연결 없음" : "사용량 조회 실패")
        let usageAccessibility = provider.name + percent
        item?.button?.setAccessibilityLabel(unavailable ? provider.name + " " + unavailableTitle
            : showingPreviousUsage ? L10n.text("이전 조회") + " · " + usageAccessibility : usageAccessibility)
        // Keep the existing menu view stable until AppKit ends popup tracking.
        let finishedIntro = menuTracking && (dashboard.view as? QuotaMenuView)?.intro == true && !fetching
        if menuTracking && !allowingTrackedUpdateTransition && !finishedIntro {
            if let panel = dashboard.view as? QuotaMenuView {
                panel.update(quota: snapshot?.quota, account: snapshot?.account,
                             updatedAt: snapshotAt, failure: failure, preserveHeight: true)
            }
            updateActivityView()
            return
        }
        let overlay = unavailable || checking
        if overlay, overlayHeight == nil, let view = dashboard.view {
            let probe = NSMenu()
            let row = NSMenuItem()
            row.view = NSView(frame: view.frame)
            probe.addItem(row)
            overlayHeight = menu.size.height - (probe.size.height - view.frame.height)
        }
        if !overlay { overlayHeight = nil }
        dashboard.view = QuotaMenuView(quota: snapshot?.quota, account: snapshot?.account,
            updatedAt: snapshotAt, failure: failure, intro: fetching && snapshot == nil && !overlay,
            checkingForUpdates: checking, offline: offline,
            preservedHeight: overlayHeight, provider: provider, showRemaining: showRemaining)
        actions.forEach { $0.isHidden = overlay }
        updateActivityView()
    }

    private func updateActivityView() {
        updateStatusSpinner()
        let showingPreviousUsage = failure != nil
            && QuotaMenuView.canShowPreviousUsage(snapshot?.quota, updatedAt: snapshotAt)
        let unavailable = offline || (failure != nil && !showingPreviousUsage)
        let overlay = unavailable || checking
        if overlay {
            if !activityItem.isHidden { activityItem.isHidden = true }
            return
        }
        let visible = readReceipts.visibleRows(activities)
        if visible.isEmpty {
            if let view = activityItem.view as? ThreadActivityView {
                view.update(activities: [], preserveHeight: menuTracking, connected: activityConnected, incompatible: false)
            }
            if !activityItem.isHidden { activityItem.isHidden = true }
            return
        }
        if let view = activityItem.view as? ThreadActivityView {
            view.update(activities: visible, preserveHeight: menuTracking, connected: activityConnected, incompatible: false)
        } else {
            activityItem.view = ThreadActivityView(activities: visible) { [weak self] opened in
                guard let self else { return }
                self.readReceipts.acknowledge(opened)
                self.onRead?(opened)
                self.updateActivityView()
            }
            (activityItem.view as? ThreadActivityView)?.update(activities: visible, connected: activityConnected, incompatible: false)
        }
        let rowView = activityItem.view
        let alpha: CGFloat = activityConnected ? 1 : 0.55
        if rowView?.alphaValue != alpha { rowView?.alphaValue = alpha }
        if activityItem.isHidden { activityItem.isHidden = false }
    }

    private var statusIconSpinning: Bool {
        AppDelegate.shouldSpinStatusIcon(
            activities: activities,
            connected: activityConnected,
            wakeThreadID: nil,
            unavailable: iconUnavailable,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func providerStatusImage() -> NSImage? {
        spinTimer != nil && !iconUnavailable
            ? CodexStatusIcon.spinningImage(size: 18, frame: spinFrame, provider: provider)
            : CodexStatusIcon.image(size: 18, offline: iconUnavailable, provider: provider)
    }

    private func updateStatusSpinner() {
        let spinning = item != nil && statusIconSpinning
        if spinning, spinTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 16, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.spinFrame = (self.spinFrame + 1) % CodexStatusIcon.spinFrameCount
                self.item?.button?.image = self.providerStatusImage()
            }
            spinTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        } else if !spinning, let timer = spinTimer {
            timer.invalidate()
            spinTimer = nil
            spinFrame = 0
            item?.button?.image = providerStatusImage()
        }
    }

    @objc private func threadNotificationChanged() { updateActivityView() }

    @objc private func clicked() {
        guard let button = item?.button else { return }
        if StatusMenuPresentation.isRightClick {
            contextMenu().popUpFollowingSystemAppearance(from: button)
        } else {
            // Prepare the existing full-size checking screen before AppKit starts menu tracking.
            onOpen?()
            render()
            menu.popUpFollowingSystemAppearance(from: button)
        }
    }
    private func contextMenu() -> NSMenu {
        let result = StatusMenuBuilder.makeContextMenu(disableTitle: L10n.text("%@ 끄기", provider.name), target: self,
                                           disableAction: #selector(disable), quitAction: #selector(quit))
        if provider == .gemini {
            let permission = NSMenuItem(title: L10n.text("채팅 읽음 감지 설정…"),
                                       action: #selector(configureConversationReading), keyEquivalent: "")
            permission.target = self
            result.insertItem(permission, at: 0)
        }
        return result
    }
    @objc private func configureConversationReading() {
        let alert = NSAlert()
        alert.messageText = L10n.text("Antigravity 채팅 읽음 감지")
        alert.informativeText = L10n.text("손쉬운 사용 권한을 허용하면 현재 보고 있는 Antigravity 채팅 주소만 확인하여 완료 항목과 알림을 정리합니다. 대화 본문은 읽거나 저장하지 않습니다. 권한이 없어도 메뉴 클릭과 기존 읽음 시각으로 정리합니다.")
        alert.addButton(withTitle: L10n.text("손쉬운 사용 설정 열기"))
        alert.addButton(withTitle: L10n.text("취소"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AntigravityConversationReader.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuTracking = true
        refresh()
        pollActivities()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        render()
        updateActivityView()
    }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        (activityItem.view as? ThreadActivityView)?.refreshHover()
    }
    func dismissMenu() { menu.cancelTracking() }
    @objc private func disable() {
        // Remove the status item only after AppKit finishes tracking its context menu.
        DispatchQueue.main.async { self.settings.setEnabled(false, for: self.provider) }
    }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func quit() { NSApp.terminate(nil) }

    var testHookMenu: NSMenu { menu }
    var testHookContextMenu: NSMenu { contextMenu() }
    var testHookHasStatusItem: Bool { item != nil }
    var testHookStatusItemVisible: Bool { hasVisibleStatusItem }
    var testHookActivityItem: NSMenuItem { activityItem }
    func testHookSetActivities(_ value: [ThreadActivity], connected: Bool = true) {
        activities = value
        activityConnected = connected
        updateActivityView()
    }
    func testHookApplyActivities(_ value: [ThreadActivity], viewedAt: [String: Double] = [:], connected: Bool = true,
                                 visibleConversationID: String? = nil,
                                 observedAt: Double = ProcessInfo.processInfo.systemUptime) {
        applyPolledActivities(value, viewedAt: viewedAt, connected: connected,
                              visibleConversationID: visibleConversationID, observedAt: observedAt)
    }
    func testHookPresentation(quota: Quota?, fetching: Bool, checking: Bool, offline: Bool) {
        snapshot = quota.map { QuotaSnapshot(quota: $0, account: nil) }
        self.fetching = fetching; self.checking = checking; self.offline = offline
        render()
    }
    func testHookSetFailure(_ value: String?) {
        failure = value
        render()
    }
}
