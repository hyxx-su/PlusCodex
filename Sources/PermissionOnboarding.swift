import AppKit
import UserNotifications

/// Explains missing permissions before opening system-owned consent controls.
final class PermissionOnboarding: NSWindowController {
    enum Permission: String, CaseIterable {
        case notifications, accessibility
    }

    private let defaults: UserDefaults
    private let revision: String
    private let notificationsNeeded: () -> Bool
    private let geminiEnabled: () -> Bool
    private let requestAccessibilityPermission: () -> Void
    private let openSystemSettings: (URL) -> Bool
    private var checking = false
    private var shownPermissions: [Permission] = []
    private var statusLabels: [Permission: NSTextField] = [:]
    private var buttons: [Permission: NSButton] = [:]
    private var notificationStatus: UNAuthorizationStatus = .notDetermined
    private var notificationRequestFailed = false

    init(defaults: UserDefaults = .standard,
         notificationsNeeded: @escaping () -> Bool,
         geminiEnabled: @escaping () -> Bool,
         requestAccessibilityPermission: @escaping () -> Void = { AntigravityConversationReader.requestPermission() },
         openSystemSettings: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.notificationsNeeded = notificationsNeeded
        self.geminiEnabled = geminiEnabled
        self.requestAccessibilityPermission = requestAccessibilityPermission
        self.openSystemSettings = openSystemSettings
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        revision = "1|\(version)|\(build)"
        super.init(window: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatus),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func notificationGranted(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    static func pending(defaults: UserDefaults, revision: String, notificationsNeeded: Bool,
                        notificationStatus: UNAuthorizationStatus, geminiEnabled: Bool,
                        accessibilityGranted: Bool) -> [Permission] {
        Permission.allCases.filter { permission in
            let needed = permission == .notifications
                ? notificationsNeeded && !notificationGranted(notificationStatus)
                : geminiEnabled && !accessibilityGranted
            return needed && defaults.string(forKey: "permissionGuide.shown.\(permission.rawValue)") != revision
        }
    }

    static func recordShown(_ permissions: [Permission], defaults: UserDefaults, revision: String) {
        // Store acknowledgement of this guide, never a substitute for OS permission state.
        for permission in permissions {
            defaults.set(revision, forKey: "permissionGuide.shown.\(permission.rawValue)")
        }
    }

    func checkIfNeeded() {
        guard !checking, window?.isVisible != true else { return }
        checking = true
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                // Do not cover another consent sheet or modal dialog.
                guard NSApp.modalWindow == nil, NSApp.windows.allSatisfy({ $0.attachedSheet == nil }) else { return }
                let pending = Self.pending(defaults: self.defaults, revision: self.revision,
                    notificationsNeeded: self.notificationsNeeded(), notificationStatus: settings.authorizationStatus,
                    geminiEnabled: self.geminiEnabled(), accessibilityGranted: AntigravityConversationReader.hasPermission)
                guard !pending.isEmpty else { return }
                self.notificationStatus = settings.authorizationStatus
                self.buildWindow(permissions: pending)
                Self.recordShown(pending, defaults: self.defaults, revision: self.revision)
                NSApp.activate(ignoringOtherApps: true)
                self.showWindow(nil)
                self.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func buildWindow(permissions: [Permission]) {
        shownPermissions = permissions
        statusLabels.removeAll()
        buttons.removeAll()
        let height = CGFloat(permissions.count * 132 + 185)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L10n.text("PlusCodex 권한 안내")
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel
        guard let content = panel.contentView else { return }
        func label(_ key: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                   size: CGFloat = 12, bold: Bool = false, secondary: Bool = false) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: L10n.text(key))
            label.frame = NSRect(x: x, y: y, width: width, height: height)
            label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            label.textColor = secondary ? .secondaryLabelColor : .labelColor
            content.addSubview(label)
            return label
        }
        _ = label("필요한 기능을 켜 주세요", x: 24, y: height - 44, width: 472, height: 28, size: 20, bold: true)
        _ = label("설치 또는 업데이트 후, 아직 허용되지 않은 권한을 안내합니다. 원하는 기능만 설정하고 계속 사용할 수 있습니다.",
                  x: 24, y: height - 96, width: 472, height: 44, secondary: true)
        for (index, permission) in permissions.enumerated() {
            let top = height - 116 - CGFloat(index * 132)
            let isNotification = permission == .notifications
            _ = label(isNotification ? "알림 · 작업 결과 받기" : "손쉬운 사용 · Gemini 자동 읽음",
                      x: 24, y: top - 20, width: 472, height: 20, size: 14, bold: true)
            _ = label(isNotification
                ? "작업 완료·승인 요청·사용량 알림을 받으려면 알림을 허용해 주세요."
                : "Antigravity에서 보고 있는 채팅 주소만 확인해 완료 항목과 알림을 정리합니다. 대화 본문은 읽거나 저장하지 않습니다.",
                x: 24, y: top - 66, width: 472, height: 40, secondary: true)
            let state = label("", x: 24, y: top - 106, width: 278, height: 34, secondary: true)
            statusLabels[permission] = state
            let button = NSButton(title: L10n.text(isNotification ? "알림 허용" : "손쉬운 사용 권한 요청"),
                                  target: self, action: #selector(configurePermission(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            button.frame = NSRect(x: 306, y: top - 105, width: 190, height: 32)
            button.identifier = NSUserInterfaceItemIdentifier("permission-guide-\(permission.rawValue)")
            buttons[permission] = button
            content.addSubview(button)
        }
        let later = NSButton(title: L10n.text("나중에 설정"), target: self, action: #selector(dismissGuide))
        later.bezelStyle = .rounded
        later.keyEquivalent = "\u{1b}"
        later.frame = NSRect(x: 24, y: 18, width: 128, height: 32)
        content.addSubview(later)
        let done = NSButton(title: L10n.text("계속 사용하기"), target: self, action: #selector(dismissGuide))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 356, y: 18, width: 140, height: 32)
        content.addSubview(done)
        updateStatuses()
    }

    @objc private func dismissGuide() { close() }

    @objc private func refreshStatus() {
        guard window?.isVisible == true else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationStatus = settings.authorizationStatus
                self.updateStatuses()
            }
        }
    }

    private func updateStatuses() {
        for permission in shownPermissions {
            let granted = permission == .notifications
                ? Self.notificationGranted(notificationStatus) : AntigravityConversationReader.hasPermission
            statusLabels[permission]?.stringValue = L10n.text(granted ? "허용됨" : "설정 후 이 창으로 돌아오면 상태가 갱신됩니다.")
            buttons[permission]?.isEnabled = !granted
            if permission == .notifications {
                buttons[permission]?.title = L10n.text(notificationStatus == .notDetermined && !notificationRequestFailed ? "알림 허용" : "알림 설정 열기")
                if notificationRequestFailed && !granted {
                    statusLabels[permission]?.stringValue = L10n.text("권한 요청에 실패했습니다. 시스템 설정에서 확인해 주세요.")
                }
            }
        }
    }

    @objc private func configurePermission(_ sender: NSButton) {
        guard shownPermissions.indices.contains(sender.tag) else { return }
        switch shownPermissions[sender.tag] {
        case .notifications:
            if notificationStatus == .notDetermined && !notificationRequestFailed {
                sender.isEnabled = false
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
                    DispatchQueue.main.async {
                        self?.notificationRequestFailed = error != nil
                        self?.refreshStatus()
                    }
                }
            } else {
                let bundleID = Bundle.main.bundleIdentifier ?? "local.codexquota.menubar"
                openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
            }
        case .accessibility:
            // Do not open Settings behind the system-owned consent warning.
            requestAccessibilityPermission()
        }
    }

    private func openSettings(_ address: String) {
        guard let url = URL(string: address), openSystemSettings(url) else {
            let alert = NSAlert()
            alert.messageText = L10n.text("시스템 설정에서 PlusCodex 권한을 확인해 주세요.")
            alert.runModal()
            return
        }
    }

    func testHookBuildWindow(_ permissions: [Permission]) { buildWindow(permissions: permissions) }
}
