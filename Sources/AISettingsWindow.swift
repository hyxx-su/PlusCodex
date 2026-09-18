import AppKit
import ServiceManagement
import UserNotifications

final class AISettingsWindow: NSWindowController, NSWindowDelegate {
    private let settings: ProviderSettings
    private let login: LoginLaunchController
    private var toggles: [AIProvider: NSSwitch] = [:]
    private var statuses: [AIProvider: NSTextField] = [:]
    private let loginToggle = NSSwitch()
    private let loginStatus = NSTextField(labelWithString: "")
    private let notificationStatus = NSTextField(labelWithString: "알림 허용 상태를 확인하세요.")

    init(settings: ProviderSettings, login: LoginLaunchController = LoginLaunchController()) {
        self.settings = settings; self.login = login
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "설정"; window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        window.delegate = self
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 420))
        window.contentView = root
        func label(_ text: String, _ frame: NSRect, _ size: CGFloat, bold: Bool = false) {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            field.frame = frame; root.addSubview(field)
        }
        label("AI 표시", NSRect(x: 36, y: 377, width: 368, height: 20), 13, bold: true)
        func card(_ frame: NSRect) {
            let box = NSBox(frame: frame)
            box.boxType = .custom; box.borderWidth = 0; box.cornerRadius = 12
            box.fillColor = .labelColor.withAlphaComponent(0.035); root.addSubview(box)
        }
        func placeSwitch(_ toggle: NSSwitch, centerY: CGFloat) {
            toggle.controlSize = .mini
            toggle.sizeToFit()
            toggle.setFrameOrigin(NSPoint(x: 404 - toggle.frame.width,
                                          y: centerY - toggle.frame.height / 2))
        }
        card(NSRect(x: 24, y: 202, width: 392, height: 156))
        for (index, provider) in AIProvider.allCases.enumerated() {
            let y = CGFloat(306 - index * 52)
            let icon = NSImageView(frame: NSRect(x: 36, y: y + 16, width: 20, height: 20))
            icon.image = CodexStatusIcon.image(size: 20, offline: false, provider: provider); root.addSubview(icon)
            label(provider.name, NSRect(x: 66, y: y + 27, width: 280, height: 18), 13)
            let status = NSTextField(labelWithString: settings.enabled(provider) ? "연결 확인 중" : "메뉴바에서 꺼짐")
            status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor
            status.lineBreakMode = .byTruncatingTail
            status.frame = NSRect(x: 66, y: y + 9, width: 280, height: 16)
            root.addSubview(status); statuses[provider] = status
            let toggle = NSSwitch()
            placeSwitch(toggle, centerY: y + 26)
            toggle.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
            toggle.target = self; toggle.action = #selector(toggled(_:))
            toggle.setAccessibilityLabel("\(provider.name) 메뉴바에 표시")
            root.addSubview(toggle); toggles[provider] = toggle
            if index < 2 {
                let line = NSBox(frame: NSRect(x: 36, y: y, width: 368, height: 1))
                line.boxType = .separator; root.addSubview(line)
            }
        }
        label("자동 실행", NSRect(x: 36, y: 165, width: 368, height: 20), 13, bold: true)
        card(NSRect(x: 24, y: 100, width: 392, height: 54))
        label("로그인 시 PlusCodex 자동 실행", NSRect(x: 36, y: 128, width: 310, height: 18), 13)
        loginStatus.font = .systemFont(ofSize: 10); loginStatus.textColor = .secondaryLabelColor
        loginStatus.frame = NSRect(x: 36, y: 110, width: 310, height: 16)
        loginStatus.lineBreakMode = .byTruncatingTail; root.addSubview(loginStatus)
        placeSwitch(loginToggle, centerY: 127)
        loginToggle.identifier = NSUserInterfaceItemIdentifier("launchAtLogin")
        loginToggle.target = self; loginToggle.action = #selector(toggleLogin(_:))
        loginToggle.setAccessibilityLabel("로그인 시 PlusCodex 자동 실행"); root.addSubview(loginToggle)
        label("알림", NSRect(x: 36, y: 64, width: 100, height: 20), 13, bold: true)
        card(NSRect(x: 24, y: 16, width: 392, height: 40))
        notificationStatus.font = .systemFont(ofSize: 11); notificationStatus.textColor = .secondaryLabelColor
        notificationStatus.lineBreakMode = .byTruncatingTail
        notificationStatus.frame = NSRect(x: 36, y: 27, width: 256, height: 18); root.addSubview(notificationStatus)
        let notify = NSButton(title: "알림 설정", target: self, action: #selector(openNotifications))
        notify.bezelStyle = .rounded; notify.controlSize = .small
        notify.frame = NSRect(x: 302, y: 23, width: 104, height: 26)
        root.addSubview(notify)
        synchronize()
    }
    required init?(coder: NSCoder) { nil }
    func present() {
        synchronize(); refreshNotifications(); NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) { synchronize(); refreshNotifications() }
    func synchronize() {
        for provider in AIProvider.allCases {
            toggles[provider]?.state = settings.enabled(provider) ? .on : .off
            statuses[provider]?.alphaValue = settings.enabled(provider) ? 1 : 0.5
        }
        loginToggle.state = login.requested ? .on : .off
        loginStatus.stringValue = login.message
    }
    func update(_ provider: AIProvider, status: String) { statuses[provider]?.stringValue = status }
    private func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] state in
            DispatchQueue.main.async {
                self?.notificationStatus.stringValue = state.authorizationStatus == .authorized
                    ? "알림 허용됨" : "알림을 허용하면 완료·사용량을 알려드려요."
            }
        }
    }
    @objc private func openNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] state in
            if state.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in self?.refreshNotifications() }
            } else {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
        }
    }
    @objc private func toggled(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let provider = AIProvider(rawValue: raw) else { return }
        settings.setEnabled(sender.state == .on, for: provider); synchronize()
    }
    @objc private func toggleLogin(_ sender: NSSwitch) {
        do {
            try login.setEnabled(sender.state == .on); synchronize()
            if login.requested && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            synchronize()
            let alert = NSAlert(); alert.messageText = "자동 실행 설정을 변경하지 못했습니다."
            alert.informativeText = "응용 프로그램 폴더에 설치했는지 확인하세요.\n" + error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
    }
}
