import AppKit
import ServiceManagement
import UserNotifications

final class AISettingsWindow: NSWindowController, NSWindowDelegate {
    private let settings: ProviderSettings
    private let login: LoginLaunchController
    private let language: LanguageSettings
    private let languagePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var toggles: [AIProvider: NSSwitch] = [:]
    private var statuses: [AIProvider: NSTextField] = [:]
    private let loginToggle = NSSwitch()
    private let loginStatus = NSTextField(labelWithString: "")
    private let notificationStatus = NSTextField(labelWithString: L10n.text("알림 허용 상태를 확인하세요."))

    init(settings: ProviderSettings, login: LoginLaunchController = LoginLaunchController(),
         language: LanguageSettings = LanguageSettings()) {
        self.settings = settings; self.login = login; self.language = language
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("설정"); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        window.delegate = self
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 520))
        window.contentView = root
        func label(_ text: String, _ frame: NSRect, _ size: CGFloat, bold: Bool = false) {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            field.frame = frame; root.addSubview(field)
        }
        label(L10n.text("AI 표시"), NSRect(x: 36, y: 377, width: 368, height: 20), 13, bold: true)
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
            let status = NSTextField(labelWithString: settings.enabled(provider) ? L10n.text("연결 확인 중") : L10n.text("메뉴바에서 꺼짐"))
            status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor
            status.lineBreakMode = .byTruncatingTail
            status.frame = NSRect(x: 66, y: y + 9, width: 280, height: 16)
            root.addSubview(status); statuses[provider] = status
            let toggle = NSSwitch()
            placeSwitch(toggle, centerY: y + 26)
            toggle.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
            toggle.target = self; toggle.action = #selector(toggled(_:))
            toggle.setAccessibilityLabel(L10n.text("%@ 메뉴바에 표시", provider.name))
            root.addSubview(toggle); toggles[provider] = toggle
            if index < 2 {
                let line = NSBox(frame: NSRect(x: 36, y: y, width: 368, height: 1))
                line.boxType = .separator; root.addSubview(line)
            }
        }
        label(L10n.text("자동 실행"), NSRect(x: 36, y: 165, width: 368, height: 20), 13, bold: true)
        card(NSRect(x: 24, y: 100, width: 392, height: 54))
        label(L10n.text("로그인 시 PlusCodex 자동 실행"), NSRect(x: 36, y: 128, width: 310, height: 18), 13)
        loginStatus.font = .systemFont(ofSize: 10); loginStatus.textColor = .secondaryLabelColor
        loginStatus.frame = NSRect(x: 36, y: 110, width: 310, height: 16)
        loginStatus.lineBreakMode = .byTruncatingTail; root.addSubview(loginStatus)
        placeSwitch(loginToggle, centerY: 127)
        loginToggle.identifier = NSUserInterfaceItemIdentifier("launchAtLogin")
        loginToggle.target = self; loginToggle.action = #selector(toggleLogin(_:))
        loginToggle.setAccessibilityLabel(L10n.text("로그인 시 PlusCodex 자동 실행")); root.addSubview(loginToggle)
        label(L10n.text("알림"), NSRect(x: 36, y: 64, width: 100, height: 20), 13, bold: true)
        card(NSRect(x: 24, y: 16, width: 392, height: 40))
        notificationStatus.font = .systemFont(ofSize: 11); notificationStatus.textColor = .secondaryLabelColor
        notificationStatus.lineBreakMode = .byTruncatingTail
        notificationStatus.frame = NSRect(x: 36, y: 27, width: 256, height: 18); root.addSubview(notificationStatus)
        let notify = NSButton(title: L10n.text("알림 설정"), target: self, action: #selector(openNotifications))
        notify.bezelStyle = .rounded; notify.controlSize = .small
        notify.frame = NSRect(x: 270, y: 23, width: 136, height: 26)
        notificationStatus.frame.size.width = 224
        root.addSubview(notify)
        // Preserve the existing compact sections; append the language row below them.
        for view in root.subviews { view.frame.origin.y += 100 }
        label(L10n.text("언어"), NSRect(x: 36, y: 78, width: 368, height: 20), 13, bold: true)
        card(NSRect(x: 24, y: 16, width: 392, height: 52))
        let languageHint = NSTextField(wrappingLabelWithString: L10n.text("앱을 다시 실행하면 적용됩니다."))
        languageHint.font = .systemFont(ofSize: 11)
        languageHint.textColor = .secondaryLabelColor
        languageHint.frame = NSRect(x: 36, y: 25, width: 188, height: 32)
        root.addSubview(languageHint)
        languagePicker.addItems(withTitles: ["한국어 (기본값)", "English"])
        languagePicker.controlSize = .small
        languagePicker.frame = NSRect(x: 238, y: 29, width: 166, height: 26)
        languagePicker.identifier = NSUserInterfaceItemIdentifier("appLanguage")
        languagePicker.setAccessibilityLabel(L10n.text("언어"))
        languagePicker.target = self; languagePicker.action = #selector(changeLanguage(_:))
        root.addSubview(languagePicker)
        synchronize()
    }
    required init?(coder: NSCoder) { nil }
    func present() {
        synchronize(); refreshNotifications(); NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) { synchronize(); refreshNotifications() }
    func synchronize() {
        languagePicker.selectItem(at: language.selected == .korean ? 0 : 1)
        for provider in AIProvider.allCases {
            toggles[provider]?.state = settings.enabled(provider) ? .on : .off
            statuses[provider]?.alphaValue = settings.enabled(provider) ? 1 : 0.5
        }
        loginToggle.state = login.requested ? .on : .off
        loginStatus.stringValue = login.message
    }
    func update(_ provider: AIProvider, status: String) { statuses[provider]?.stringValue = status }
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        language.select(sender.indexOfSelectedItem == 1 ? .english : .korean)
    }
    private func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] state in
            DispatchQueue.main.async {
                self?.notificationStatus.stringValue = state.authorizationStatus == .authorized
                    ? L10n.text("알림 허용됨") : L10n.text("알림을 허용하면 완료·사용량을 알려드려요.")
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
            let alert = NSAlert(); alert.messageText = L10n.text("자동 실행 설정을 변경하지 못했습니다.")
            alert.informativeText = L10n.text("응용 프로그램 폴더에 설치했는지 확인하세요.\n") + error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
    }
}
