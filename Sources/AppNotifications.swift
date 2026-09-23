import AppKit
import UserNotifications

final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]
    private let center = UNUserNotificationCenter.current()
    private let notificationSettings: NotificationSettings
    private var scheduled: [String: Double] = [:]
    private var accountKey: String?
    private var pendingUpdateBuilds = Set<String>()
    private var scheduledSoundName: String?
    private var scheduledSoundDuration: TimeInterval

    init(settings: NotificationSettings = NotificationSettings()) {
        notificationSettings = settings
        scheduledSoundName = settings.customSoundName
        scheduledSoundDuration = settings.soundDuration
        super.init()
        settings.onChange = { [weak self] in self?.notificationSettingsDidChange() }
    }

    func updateAvailable(version: String, build: String) {
        guard notificationSettings.isEnabled(.update) else { return }
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async {
                guard let self,
                      UserDefaults.standard.string(forKey: "notifiedUpdateBuild") != build,
                      self.pendingUpdateBuilds.insert(build).inserted else { return }
                let content = UNMutableNotificationContent()
                content.title = L10n.text("PlusCodex 새 업데이트")
                content.body = L10n.text("v%@ 버전을 사용할 수 있습니다. 업데이트 안내를 확인하세요.", version)
                content.sound = self.notificationSettings.sound
                content.userInfo = ["updateAvailable": true]
                // Persist only after successful submission; failures may retry on the next check.
                self.center.add(UNNotificationRequest(identifier: "update-\(build)", content: content, trigger: nil)) { error in
                    DispatchQueue.main.async {
                        self.pendingUpdateBuilds.remove(build)
                        if let error {
                            NSLog("PlusCodex update notification: %@", error.localizedDescription)
                        } else {
                            UserDefaults.standard.set(build, forKey: "notifiedUpdateBuild")
                        }
                    }
                }
            }
        }
    }
    private var alertTracker: QuotaAlertTracker = {
        guard let data = UserDefaults.standard.data(forKey: "quotaAlertState"),
              let value = try? JSONDecoder().decode(QuotaAlertTracker.self, from: data) else { return QuotaAlertTracker() }
        return value
    }()

    func checkThresholds(_ quota: Quota, account: CodexAccount?) {
        guard notificationSettings.isEnabled(.quota) else { return }
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let alerts = self.alertTracker.update(quota, account: account?.email, planType: account?.planType)
                self.saveAlertState()
                for alert in alerts {
                    let content = UNMutableNotificationContent()
                    content.title = alert.level == 2 ? L10n.text("Codex %@ 사용량 소진", alert.label) : L10n.text("Codex %@ 10% 남았습니다.", alert.label)
                    content.body = alert.level == 2
                        ? L10n.text("남은 사용량이 0%입니다. 초기화 시간을 확인하세요.")
                        : L10n.text("사용량이 얼마 남지 않았습니다. PlusCodex에서 현재 잔여량과 초기화 시간을 확인하세요.")
                    content.sound = self.notificationSettings.sound
                    self.center.add(UNNotificationRequest(identifier: "quota-\(UUID().uuidString)", content: content, trigger: nil)) { error in
                        if let error {
                            NSLog("PlusCodex quota notification: %@", error.localizedDescription)
                            DispatchQueue.main.async {
                                self.alertTracker.retry(alert)
                                self.saveAlertState()
                            }
                        }
                    }
                }
            }
        }
    }

    private func saveAlertState() {
        if let data = try? JSONEncoder().encode(alertTracker) {
            UserDefaults.standard.set(data, forKey: "quotaAlertState")
        }
    }

    func start() {
        center.delegate = self
        guard notificationSettings.anyEnabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("PlusCodex notification authorization: %@", error.localizedDescription) }
        }
    }

    func completed(_ activity: ThreadActivity) {
        guard notificationSettings.isEnabled(.completion) else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Codex 작업 완료")
        content.body = activity.title
        content.sound = notificationSettings.sound
        content.userInfo = ["threadID": activity.id]
        submit(UNNotificationRequest(identifier: "completion-\(activity.id)-\(UUID().uuidString)",
                                     content: content, trigger: nil))
    }

    func failed(_ activity: ThreadActivity) {
        guard notificationSettings.isEnabled(.failure) else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Codex 작업 실패")
        let title = activity.title.isEmpty ? L10n.text("Codex 채팅") : activity.title
        content.body = L10n.text("%@ 작업을 완료하지 못했습니다. 작업 내용을 확인하세요.", title)
        content.sound = notificationSettings.sound
        content.userInfo = ["threadID": activity.id]
        submit(UNNotificationRequest(identifier: "failure-\(activity.id)-\(UUID().uuidString)",
                                     content: content, trigger: nil))
    }

    func attentionNeeded(_ event: ThreadAttentionEvent) {
        let kind: NotificationKind
        let titleKey: String
        let bodyKey: String
        switch event.kind {
        case .approval:
            kind = .approval
            titleKey = "Codex 승인 필요"
            bodyKey = "%@ 작업에서 승인이 필요합니다."
        case .answer:
            kind = .answer
            titleKey = "Codex 답변 필요"
            bodyKey = "%@ 작업에서 답변을 기다리고 있습니다."
        case .mcp:
            kind = .mcp
            titleKey = "Codex MCP 확인 필요"
            bodyKey = "%@ 작업에서 MCP 서버의 입력 또는 확인이 필요합니다."
        case .appApproval:
            kind = .appApproval
            titleKey = "Codex 앱 승인 필요"
            bodyKey = "%@ 작업에서 연결된 앱의 작업 실행 승인이 필요합니다."
        }
        guard notificationSettings.isEnabled(kind) else { return }
        let activity = event.activity
        let content = UNMutableNotificationContent()
        content.title = L10n.text(titleKey)
        content.body = activity.title.isEmpty
            ? L10n.text(bodyKey, L10n.text("Codex 채팅"))
            : L10n.text(bodyKey, activity.title)
        content.sound = notificationSettings.sound
        content.userInfo = ["threadID": activity.id]
        submit(UNNotificationRequest(identifier: "attention-\(activity.id)-\(UUID().uuidString)",
                                     content: content, trigger: nil))
    }

    func scheduleResets(_ quota: Quota, account: CodexAccount?) {
        guard notificationSettings.isEnabled(.reset) else {
            center.removePendingNotificationRequests(withIdentifiers: ["reset-primary", "reset-secondary"])
            scheduled.removeAll()
            return
        }
        // Called on the main run loop after a successful authenticated snapshot.
        let key = account?.email
        if accountKey != key {
            center.removePendingNotificationRequests(withIdentifiers: ["reset-primary", "reset-secondary"])
            scheduled.removeAll()
            accountKey = key
        }
        for (name, window) in [("primary", quota.primary), ("secondary", quota.secondary)] {
            let id = "reset-\(name)"
            guard let window, let timestamp = window.resetsAt,
                  timestamp.isFinite, timestamp > Date().timeIntervalSince1970 else {
                // A past schedule may already have fired; never re-alert for past timestamps.
                center.removePendingNotificationRequests(withIdentifiers: [id])
                scheduled.removeValue(forKey: id)
                continue
            }
            guard scheduled[id] != timestamp else { continue }
            scheduled[id] = timestamp
            let content = UNMutableNotificationContent()
            content.title = L10n.text("Codex %@ 초기화 시간", window.displayLabel(planType: account?.planType, isPrimary: name == "primary"))
            content.body = L10n.text("사용량 초기화 예정 시간이 되었습니다. PlusCodex에서 남은 사용량을 확인하세요.")
            content.sound = notificationSettings.sound
            let interval = max(1, timestamp - Date().timeIntervalSince1970)
            center.add(UNNotificationRequest(identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))) { [weak self] error in
                if let error {
                    NSLog("PlusCodex reset notification failed: %@", error.localizedDescription)
                    DispatchQueue.main.async {
                        if self?.scheduled[id] == timestamp { self?.scheduled.removeValue(forKey: id) }
                    }
                }
            }
        }
    }

    private func notificationSettingsDidChange() {
        let soundChanged = scheduledSoundName != notificationSettings.customSoundName
            || scheduledSoundDuration != notificationSettings.soundDuration
        scheduledSoundName = notificationSettings.customSoundName
        scheduledSoundDuration = notificationSettings.soundDuration
        guard soundChanged || !notificationSettings.isEnabled(.reset) else { return }
        center.removePendingNotificationRequests(withIdentifiers: ["reset-primary", "reset-secondary"])
        scheduled.removeAll()
    }

    private func submit(_ request: UNNotificationRequest) {
        center.add(request) { error in
            if let error { NSLog("PlusCodex notification failed: %@", error.localizedDescription) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banners even when PlusCodex itself is frontmost; Codex being
        // frontmost never suppresses a notification from this app either.
        completionHandler(Self.foregroundPresentationOptions)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           response.notification.request.content.userInfo["updateAvailable"] as? Bool == true {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(string: "https://github.com/hyxx-su/PlusCodex/releases/latest")!)
            }
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let id = response.notification.request.content.userInfo["threadID"] as? String,
           UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/\(id)") {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
