import AppKit

/// Owns one additional provider's status item and independent refresh lifecycle.
final class ProviderStatusController: NSObject, NSMenuDelegate {
    let provider: AIProvider
    private let settings: ProviderSettings
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
    var onSettings: (() -> Void)?
    var onOpen: (() -> Void)?
    var onState: ((String) -> Void)?

    init(provider: AIProvider, settings: ProviderSettings) {
        self.provider = provider
        self.settings = settings
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(dashboard)
        let separator = NSMenuItem.separator()
        menu.addItem(separator)
        actions = [separator]
        for (title, selector, shortcut) in [
            ("지금 새로고침", #selector(refreshClicked), "r"),
            ("설정", #selector(settingsClicked), ","),
            ("PlusCodex 종료", #selector(quit), "q")
        ] {
            let row = NSMenuItem(title: title, action: selector, keyEquivalent: shortcut)
            row.target = self
            menu.addItem(row)
            actions.append(row)
        }
        render()
    }

    func synchronize() {
        if settings.enabled(provider), CLIInstallation.executable(provider) != nil {
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
            onState?(settings.enabled(provider) ? "미설치 · 메뉴바에서 숨김" : "메뉴바에서 꺼짐")
        }
    }

    func presentation(offline: Bool, checking: Bool) {
        let reconnected = self.offline && !offline
        self.offline = offline
        self.checking = checking
        render()
        if reconnected { refresh() }
    }

    func refresh() {
        guard settings.enabled(provider), CLIInstallation.executable(provider) != nil, !fetching, !offline else { return }
        guard Date() >= nextFetch else {
            if snapshot == nil && failure == nil { onState?("다음 사용량 조회 대기 중") }
            return
        }
        fetching = true
        onState?("사용량 확인 중")
        render()
        let provider = self.provider
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try ExternalUsageClient.fetch(provider) }
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { [weak self] in
                guard let self else { return }
                self.fetching = false
                guard self.settings.enabled(provider), CLIInstallation.executable(provider) != nil else { return }
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.failure = nil
                    self.nextFetch = Date().addingTimeInterval(provider == .claude ? 300 : 60)
                    self.onState?(snapshot.account?.email ?? "연결됨 · 사용량 조회 완료")
                case .failure(let error):
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
        let percent = snapshot?.quota.windows.first.map { " \($0.remaining)%" } ?? ""
        item?.button?.image = CodexStatusIcon.image(size: 18, offline: offline, provider: provider)
        item?.button?.imagePosition = offline || percent.isEmpty ? .imageOnly : .imageLeading
        item?.button?.attributedTitle = NSAttributedString(string: offline ? "" : percent, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
        item?.button?.setAccessibilityLabel(provider.name + (offline ? " 네트워크 연결 없음" : percent))
        let overlay = offline || checking
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
            preservedHeight: overlayHeight, provider: provider)
        actions.forEach { $0.isHidden = overlay }
    }

    @objc private func clicked() {
        guard let button = item?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let context = NSMenu()
            let disable = NSMenuItem(title: "\(provider.name) 끄기", action: #selector(disable), keyEquivalent: "")
            disable.target = self
            context.addItem(disable)
            context.popUpFollowingSystemAppearance(from: button)
        } else {
            menu.popUpFollowingSystemAppearance(from: button)
        }
    }
    func menuWillOpen(_ menu: NSMenu) { onOpen?(); refresh() }
    func dismissMenu() { menu.cancelTracking() }
    @objc private func disable() {
        // Remove the status item only after AppKit finishes tracking its context menu.
        DispatchQueue.main.async { self.settings.setEnabled(false, for: self.provider) }
    }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func refreshClicked() { refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    var testHookMenu: NSMenu { menu }
    func testHookPresentation(quota: Quota?, fetching: Bool, checking: Bool, offline: Bool) {
        snapshot = quota.map { QuotaSnapshot(quota: $0, account: nil) }
        self.fetching = fetching; self.checking = checking; self.offline = offline
        render()
    }
}
