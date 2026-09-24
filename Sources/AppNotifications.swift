import AppKit
import UserNotifications

final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]
    private static let resetNames = ["primary", "secondary"]

    private struct ResetTarget {
        let timestamp: Double
        let windowDuration: TimeInterval?
        let account: String
        let label: String
        let sound: String
    }

    private let center = UNUserNotificationCenter.current()
    private let notificationSettings: NotificationSettings
    private var lastResetSnapshot: (quota: Quota, account: CodexAccount?)?
    private var resetTargets: [String: ResetTarget] = [:]
    private var resetSyncInProgress = false
    private var resetSyncRequested = false
    private var pendingUpdateBuilds = Set<String>()
    var onUpdateNotificationOpened: (() -> Void)?

    init(settings: NotificationSettings = NotificationSettings()) {
        notificationSettings = settings
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
        // A disabled reset must not leave an old OS request active when the
        // first usage fetch is offline or fails after relaunch.
        if !notificationSettings.isEnabled(.reset) { cancelPendingResetsIfDisabled() }
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
        // Refresh, launch, sleep recovery and network recovery share this path.
        // The notification center, not process memory, is the source of truth.
        lastResetSnapshot = (quota, account)
        resetTargets.removeAll()
        if notificationSettings.isEnabled(.reset) {
            let sound = resetSoundSignature
            for (name, window) in [("primary", quota.primary), ("secondary", quota.secondary)] {
                guard let window, let timestamp = window.resetsAt, timestamp.isFinite else { continue }
                resetTargets["reset-\(name)"] = ResetTarget(
                    timestamp: timestamp,
                    windowDuration: window.windowDurationMins.map { TimeInterval($0) * 60 },
                    account: account?.email ?? "",
                    label: window.displayLabel(planType: account?.planType, isPrimary: name == "primary"),
                    sound: sound)
            }
        }
        reconcileResets()
    }

    private var resetSoundSignature: String {
        "\(notificationSettings.customSoundName ?? "default")|\(notificationSettings.soundDuration)|\(notificationSettings.soundVolume)"
    }

    static func resetRequestMatches(_ request: UNNotificationRequest?, timestamp: Double,
                                    account: String, label: String, sound: String) -> Bool {
        guard let request, request.trigger != nil else { return false }
        let info = request.content.userInfo
        return info["resetAt"] as? Double == timestamp
            && info["resetAccount"] as? String == account
            && info["resetLabel"] as? String == label
            && info["resetSound"] as? String == sound
    }

    static func resetIdentifier(name: String, timestamp: Double) -> String {
        "reset-\(name)-\(String(timestamp.bitPattern, radix: 16))"
    }

    private static func resetName(for identifier: String) -> String? {
        resetNames.first { identifier == "reset-\($0)" || identifier.hasPrefix("reset-\($0)-") }
    }

    static func isPreviousCycleDue(pendingAt: Double?, latestAt: Double, now: Double,
                                   windowDuration: TimeInterval?) -> Bool {
        guard let pendingAt, pendingAt <= now, latestAt > now,
              let windowDuration, windowDuration > 0 else { return false }
        let difference = latestAt - pendingAt
        // Preserve an overdue OS request only when the server has advanced to
        // the next cycle, not when it merely corrected this cycle. Monthly
        // calendar windows can vary by several days; shorter windows are strict.
        let tolerance = windowDuration <= 5 * 60 * 60 ? 10 * 60 : max(60 * 60, windowDuration * 0.1)
        return abs(difference - windowDuration) <= tolerance
    }

    private func reconcileResets() {
        guard !resetSyncInProgress else {
            resetSyncRequested = true
            return
        }
        resetSyncInProgress = true
        center.getPendingNotificationRequests { [weak self] requests in
            DispatchQueue.main.async {
                guard let self else { return }
                let pending = requests.filter { Self.resetName(for: $0.identifier) != nil }
                let pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
                let group = DispatchGroup()
                let now = Date().timeIntervalSince1970
                for request in pending {
                    guard let name = Self.resetName(for: request.identifier),
                          let target = self.resetTargets["reset-\(name)"] else {
                        self.center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                        continue
                    }
                    let targetID = Self.resetIdentifier(name: name, timestamp: target.timestamp)
                    if request.identifier == targetID, target.timestamp > now {
                        // The add below atomically replaces this ID if its content
                        // changed; removing it first would create a delivery gap.
                        continue
                    }
                    if request.identifier == targetID,
                       Self.resetRequestMatches(request, timestamp: target.timestamp,
                           account: target.account, label: target.label, sound: target.sound) {
                        continue
                    }
                    let pendingAt = request.content.userInfo["resetAt"] as? Double
                        ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?
                            .nextTriggerDate()?.timeIntervalSince1970
                    if Self.isPreviousCycleDue(pendingAt: pendingAt, latestAt: target.timestamp,
                        now: now, windowDuration: target.windowDuration),
                       request.content.userInfo["resetAccount"] as? String == target.account {
                        continue
                    }
                    self.center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                }
                for name in Self.resetNames {
                    guard let target = self.resetTargets["reset-\(name)"], target.timestamp > now else { continue }
                    let id = Self.resetIdentifier(name: name, timestamp: target.timestamp)
                    if Self.resetRequestMatches(pendingByID[id], timestamp: target.timestamp,
                        account: target.account, label: target.label, sound: target.sound) { continue }
                    let content = UNMutableNotificationContent()
                    content.title = L10n.text("Codex %@ 초기화 시간", target.label)
                    content.body = L10n.text("사용량 초기화 예정 시간이 되었습니다. PlusCodex에서 남은 사용량을 확인하세요.")
                    content.sound = self.notificationSettings.sound
                    content.userInfo = ["resetAt": target.timestamp, "resetAccount": target.account,
                                        "resetLabel": target.label, "resetSound": target.sound]
                    let interval = max(1, target.timestamp - Date().timeIntervalSince1970)
                    group.enter()
                    // A cycle-specific ID lets an overdue OS request survive while
                    // the next cycle is booked. The same ID replaces a stale copy.
                    self.center.add(UNNotificationRequest(identifier: id, content: content,
                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))) { error in
                        if let error { NSLog("PlusCodex reset notification failed: %@", error.localizedDescription) }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    self.resetSyncInProgress = false
                    if self.resetSyncRequested {
                        self.resetSyncRequested = false
                        self.reconcileResets()
                    }
                }
            }
        }
    }

    private func notificationSettingsDidChange() {
        if let snapshot = lastResetSnapshot {
            scheduleResets(snapshot.quota, account: snapshot.account)
        } else if !notificationSettings.isEnabled(.reset) {
            cancelPendingResetsIfDisabled()
        }
    }

    private func cancelPendingResetsIfDisabled() {
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self, !self.notificationSettings.isEnabled(.reset) else { return }
            let ids = requests.map(\.identifier).filter { Self.resetName(for: $0) != nil }
            self.center.removePendingNotificationRequests(withIdentifiers: ids)
        }
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
            DispatchQueue.main.async { [weak self] in self?.onUpdateNotificationOpened?() }
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let id = response.notification.request.content.userInfo["threadID"] as? String,
           UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/\(id)") {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
