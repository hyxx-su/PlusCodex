import AppKit
import UserNotifications

final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var scheduled: [String: Double] = [:]
    private var accountKey: String?
    private var alertTracker: QuotaAlertTracker = {
        guard let data = UserDefaults.standard.data(forKey: "quotaAlertState"),
              let value = try? JSONDecoder().decode(QuotaAlertTracker.self, from: data) else { return QuotaAlertTracker() }
        return value
    }()

    func checkThresholds(_ quota: Quota, account: CodexAccount?) {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let alerts = self.alertTracker.update(quota, account: account?.email, planType: account?.planType)
                self.saveAlertState()
                for alert in alerts {
                    let content = UNMutableNotificationContent()
                    content.title = alert.level == 2 ? "Codex \(alert.label) 사용량 소진" : "Codex \(alert.label) 10% 남았습니다."
                    content.body = alert.level == 2
                        ? "남은 사용량이 0%입니다. 초기화 시간을 확인하세요."
                        : "사용량이 얼마 남지 않았습니다. PlusCodex에서 현재 잔여량과 초기화 시간을 확인하세요."
                    content.sound = .default
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
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("PlusCodex notification authorization: %@", error.localizedDescription) }
        }
    }

    func completed(_ activity: ThreadActivity) {
        let content = UNMutableNotificationContent()
        content.title = "Codex 작업 완료"
        content.body = activity.title
        content.sound = .default
        content.userInfo = ["threadID": activity.id]
        submit(UNNotificationRequest(identifier: "completion-\(activity.id)-\(UUID().uuidString)",
                                     content: content, trigger: nil))
    }

    func scheduleResets(_ quota: Quota, account: CodexAccount?) {
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
            content.title = "Codex \(window.displayLabel(planType: account?.planType, isPrimary: name == "primary")) 초기화 시간"
            content.body = "사용량 초기화 예정 시간이 되었습니다. PlusCodex에서 남은 사용량을 확인하세요."
            content.sound = .default
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

    private func submit(_ request: UNNotificationRequest) {
        center.add(request) { error in
            if let error { NSLog("PlusCodex notification failed: %@", error.localizedDescription) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let id = response.notification.request.content.userInfo["threadID"] as? String,
           UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/\(id)") {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
