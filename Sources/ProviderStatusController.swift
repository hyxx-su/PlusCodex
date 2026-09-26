import AppKit

/// Owns one additional provider's status item and independent refresh lifecycle.
final class ProviderStatusController: NSObject, NSMenuDelegate {
    let provider: AIProvider
    private let settings: ProviderSettings
    private let claudeAvailability: () -> ClaudeAvailability.State
    private let grokAvailability: () -> GrokAvailability.State
    private let fetchUsage: (AIProvider) throws -> QuotaSnapshot
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private let dashboard = NSMenuItem()
    private var actions: [NSMenuItem] = []
    private var snapshot: QuotaSnapshot?
    private var failure: String?
    private var fetching = false
    private var nextFetch = Date.distantPast
    private var overlayHeight: CGFloat?
    private var offline = false
    private var checking = false
    private var menuTracking = false
    private var previouslyEnabled = false
    var onSettings: (() -> Void)?
    var onState: ((String) -> Void)?
    var onVisibilityChange: (() -> Void)?
    var hasVisibleStatusItem: Bool { item?.isVisible ?? false }

    init(provider: AIProvider, settings: ProviderSettings,
         claudeAvailability: @escaping () -> ClaudeAvailability.State = { ClaudeAvailability.current() },
         grokAvailability: @escaping () -> GrokAvailability.State = { GrokAvailability.current() },
         fetchUsage: @escaping (AIProvider) throws -> QuotaSnapshot = ExternalUsageClient.fetch) {
        self.provider = provider
        self.settings = settings
        self.claudeAvailability = claudeAvailability
        self.grokAvailability = grokAvailability
        self.fetchUsage = fetchUsage
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(dashboard)
        let separator = NSMenuItem.separator()
        menu.addItem(separator)
        actions = [separator]
        for (title, selector, shortcut) in [
            (L10n.text("지금 새로고침"), #selector(refreshClicked), "r"),
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

    func synchronize() {
        let wasVisible = hasVisibleStatusItem
        defer {
            if wasVisible != hasVisibleStatusItem { onVisibilityChange?() }
        }
        let enabled = settings.enabled(provider)
        // An explicit retry may clear an expired delay, but must not bypass
        // a server-provided Retry-After window.
        if enabled && !previouslyEnabled && nextFetch <= Date() { nextFetch = .distantPast }
        previouslyEnabled = enabled
        if provider == .claude {
            let availability = claudeAvailability()
            if availability != .availableOrUnknown {
                if settings.enabled(provider) { settings.setEnabled(false, for: provider) }
                if let item { NSStatusBar.system.removeStatusItem(item) }
                item = nil
                snapshot = nil
                failure = nil
                onState?(L10n.text(availability.guidance ?? "메뉴바에서 꺼짐"))
                return
            }
        }
        if provider == .grok, let guidance = grokAvailability().guidance {
            if enabled { settings.setEnabled(false, for: provider) }
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            snapshot = nil
            failure = nil
            onState?(L10n.text(guidance))
            return
        }
        if settings.enabled(provider) {
            if provider == .grok && !settings.grokUsageVerified {
                if let item { NSStatusBar.system.removeStatusItem(item) }
                item = nil
                refresh()
                return
            }
            if item == nil {
                let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                status.autosaveName = "PlusCodex.\(provider.rawValue)"
                status.button?.target = self
                status.button?.action = #selector(clicked)
                status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item = status
            }
            render()
            refresh()
        } else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            self.item = nil
            snapshot = nil
            failure = nil
            onState?(L10n.text("메뉴바에서 꺼짐"))
        }
    }

    func reloadLocalization() {
        guard actions.count >= 4 else { return }
        actions[1].title = L10n.text("지금 새로고침")
        actions[2].title = L10n.text("설정")
        actions[3].title = L10n.text("PlusCodex 종료")
        // Recompute the current status text as well; otherwise a status
        // emitted before the language change can remain in the old language.
        synchronize()
    }

    func presentation(offline: Bool, checking: Bool) {
        let reconnected = self.offline && !offline
        self.offline = offline
        self.checking = checking
        render()
        if reconnected { refresh() }
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try fetchUsage(provider) }
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
                guard let self else { return }
                self.fetching = false
                guard self.settings.enabled(provider) else { return }
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
                    self.snapshot = snapshot
                    self.failure = nil
                    self.nextFetch = Date().addingTimeInterval(provider == .claude ? 300 : 60)
                    if provider == .grok { self.settings.setGrokUsageVerified(true) }
                    self.onState?(snapshot.quota.windows.isEmpty && provider == .claude
                        ? L10n.text("Claude Desktop 연결됨 · 사용량 수치 미제공")
                        : snapshot.account?.email ?? L10n.text("연결됨 · 사용량 조회 완료"))
                case .failure(let error):
                    let noSubscriptionUsage = (error as? UsageFailure).map {
                        if case .subscriptionUsageUnavailable = $0 { return true }
                        return false
                    } ?? false
                    if provider == .grok && (!self.settings.grokUsageVerified || noSubscriptionUsage) {
                        if case UsageFailure.throttled(let date) = error { self.nextFetch = date }
                        self.settings.setEnabled(false, for: provider)
                        self.onState?(error.localizedDescription)
                        return
                    }
                    self.failure = error.localizedDescription
                    // Never retain a previous account's percentage after auth errors.
                    self.snapshot = nil
                    if case UsageFailure.throttled(let date) = error { self.nextFetch = date }
                    else { self.nextFetch = Date().addingTimeInterval(provider == .claude ? 300 : 60) }
                    self.onState?(error.localizedDescription)
                }
                self.render()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func render() {
        // Keep the existing menu view stable until AppKit ends popup tracking.
        guard !menuTracking else { return }
        // Claude Desktop can be connected without providing a usage percentage.
        // Keep that state in Settings, but do not occupy the menu bar with an empty item.
        if provider == .claude {
            let wasVisible = hasVisibleStatusItem
            item?.isVisible = failure != nil || offline || snapshot?.quota.windows.isEmpty == false
            if wasVisible != hasVisibleStatusItem { onVisibilityChange?() }
        }
        let showRemaining = settings.showRemaining(provider)
        let percent = snapshot?.quota.windows.first.map { " \($0.displayPercent(showRemaining: showRemaining))%" } ?? ""
        let unavailable = offline || failure != nil
        item?.button?.image = CodexStatusIcon.image(size: 18, offline: unavailable, provider: provider)
        item?.button?.imagePosition = unavailable || percent.isEmpty ? .imageOnly : .imageLeading
        item?.button?.attributedTitle = NSAttributedString(string: unavailable ? "" : percent, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
        item?.button?.setAccessibilityLabel(provider.name + " "
            + (offline ? L10n.text("네트워크 연결 없음")
               : failure != nil ? L10n.text("사용량 조회 실패") : percent))
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
            updatedAt: nil, failure: failure, intro: fetching && snapshot == nil && !overlay,
            checkingForUpdates: checking, offline: offline,
            preservedHeight: overlayHeight, provider: provider, showRemaining: showRemaining)
        actions.forEach { $0.isHidden = overlay }
    }

    @objc private func clicked() {
        guard let button = item?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let context = NSMenu()
            let disable = NSMenuItem(title: L10n.text("%@ 끄기", provider.name), action: #selector(disable), keyEquivalent: "")
            disable.target = self
            context.addItem(disable)
            context.popUpFollowingSystemAppearance(from: button)
        } else {
            menu.popUpFollowingSystemAppearance(from: button)
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuTracking = true
        refresh()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        render()
    }
    func dismissMenu() { menu.cancelTracking() }
    @objc private func disable() {
        // Remove the status item only after AppKit finishes tracking its context menu.
        DispatchQueue.main.async { self.settings.setEnabled(false, for: self.provider) }
    }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func refreshClicked() { refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    var testHookMenu: NSMenu { menu }
    var testHookHasStatusItem: Bool { item != nil }
    var testHookStatusItemVisible: Bool { hasVisibleStatusItem }
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
