import AppKit
import UserNotifications

final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]
    private static let resetNames = ["primary", "secondary"]

    private struct ResetTarget: Equatable {
        let timestamp: Double
        let windowDuration: TimeInterval?
        let usedPercent: Double
        let plan: String
        let account: String
        let label: String
        let sound: String
        let observedAt: Date
        let confirmedAt: Double?
    }

    private let center = UNUserNotificationCenter.current()
    private let notificationSettings: NotificationSettings
    private lazy var autoCleanup = NotificationAutoCleanup(settings: notificationSettings)
    private let readCleanup = ThreadNotificationReadCleanup()
    private let threadPreferences: ThreadNotificationPreferences
    private let resetCreditExpiry: ResetCreditExpiryNotifications
    private var resetTargets: [String: ResetTarget] = [:]
    private(set) var resetSyncInProgress = false
    private let cycleLedger: ResetCycleLedger
    private let resetClock: () -> Date
    private let readPendingResets: (@escaping ([UNNotificationRequest]) -> Void) -> Void
    private let readResetAuthorization: (@escaping (Bool) -> Void) -> Void
    private let addReset: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
    private let removeReset: ([String]) -> Void
    private var resetSyncRequested = false
    private var pendingUpdateBuilds = Set<String>()
    var onUpdateNotificationOpened: (() -> Void)?
    var isAttentionRequestCurrent: ((String, String?) -> Bool)?

    init(settings: NotificationSettings = NotificationSettings(),
         threadPreferences: ThreadNotificationPreferences = .shared,
         resetDefaults: UserDefaults = .standard,
         resetClock: @escaping () -> Date = Date.init,
         readPendingResets: ((@escaping ([UNNotificationRequest]) -> Void) -> Void)? = nil,
         readResetAuthorization: ((@escaping (Bool) -> Void) -> Void)? = nil,
         addReset: ((UNNotificationRequest, @escaping (Error?) -> Void) -> Void)? = nil,
         removeReset: (([String]) -> Void)? = nil) {
        notificationSettings = settings
        self.threadPreferences = threadPreferences
        resetCreditExpiry = ResetCreditExpiryNotifications(settings: settings)
        cycleLedger = ResetCycleLedger(defaults: resetDefaults)
        self.resetClock = resetClock
        self.readPendingResets = readPendingResets ?? { completion in
            UNUserNotificationCenter.current().getPendingNotificationRequests(completionHandler: completion)
        }
        self.readResetAuthorization = readResetAuthorization ?? { completion in
            UNUserNotificationCenter.current().getNotificationSettings {
                completion($0.authorizationStatus == .authorized || $0.authorizationStatus == .provisional)
            }
        }
        self.addReset = addReset ?? { request, completion in
            NotificationDelivery.shared.add(request, duration: settings.notificationPlaybackDuration, completion: completion)
        }
        self.removeReset = removeReset ?? { ids in
            ids.forEach { NotificationDelivery.shared.cancel($0) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
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
                NotificationDelivery.shared.add(UNNotificationRequest(identifier: "update-\(build)", content: content, trigger: nil), duration: self.notificationSettings.notificationPlaybackDuration) { error in
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
                    NotificationIconProvider.apply(to: content, provider: .codex)
                    content.title = alert.level == 2 ? L10n.text("Codex %@ 사용량 소진", alert.label) : L10n.text("Codex %@ 10% 남았습니다.", alert.label)
                    content.body = alert.level == 2
                        ? L10n.text("남은 사용량이 0%입니다. 초기화 시간을 확인하세요.")
                        : L10n.text("사용량이 얼마 남지 않았습니다. PlusCodex에서 현재 잔여량과 초기화 시간을 확인하세요.")
                    content.sound = self.notificationSettings.sound
                    NotificationDelivery.shared.add(UNNotificationRequest(identifier: "quota-\(UUID().uuidString)", content: content, trigger: nil), duration: self.notificationSettings.notificationPlaybackDuration) { error in
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

    func start(requestAuthorization: Bool = true) {
        center.delegate = self
        autoCleanup.synchronize()
        resetCreditExpiry.start()
        // Cancel legacy timers even when the first fetch fails or the app is offline.
        reconcileResets()
        guard requestAuthorization,
              notificationSettings.anyEnabled || threadPreferences.hasEnabledOverrides else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("PlusCodex notification authorization: %@", error.localizedDescription) }
        }
    }

    private func threadUserInfo(_ activity: ThreadActivity) -> [String: Any] {
        var info: [String: Any] = ["threadID": activity.id]
        if let urlString = activity.url?.absoluteString { info["threadURL"] = urlString }
        // Retries must check the original task, even after this chat starts a new turn.
        if let scope = ThreadNotificationPreferences.scope(for: activity) { info["notificationScope"] = scope }
        return info
    }

    func threadRead(_ activity: ThreadActivity) {
        readCleanup.read(activity)
    }

    func isThreadNotificationEnabled(_ kind: NotificationKind, scope: String?) -> Bool {
        guard threadPreferences.enabled(scope: scope) else { return false }
        // Completion is the task default, not a master kill switch. Other
        // notification kinds still require their independently enabled setting.
        return kind == .completion || notificationSettings.isEnabled(kind)
    }

    func completed(_ activity: ThreadActivity) {
        guard activity.id != CodexWakeSettings().threadID else { return }
        guard isThreadNotificationEnabled(.completion, scope: ThreadNotificationPreferences.scope(for: activity)) else { return }
        let content = UNMutableNotificationContent()
        NotificationIconProvider.apply(to: content, provider: activity.provider)
        content.title = L10n.text(activity.provider == .gemini ? "Gemini 작업 완료" : "Codex 작업 완료")
        content.body = activity.title
        content.sound = notificationSettings.sound
        content.userInfo = threadUserInfo(activity)
        submit(UNNotificationRequest(identifier: "completion-\(activity.id)-\(UUID().uuidString)",
                                     content: content, trigger: nil))
    }

    func failed(_ activity: ThreadActivity) {
        guard isThreadNotificationEnabled(.failure, scope: ThreadNotificationPreferences.scope(for: activity)) else { return }
        let content = UNMutableNotificationContent()
        NotificationIconProvider.apply(to: content, provider: activity.provider)
        content.title = L10n.text(activity.provider == .gemini ? "Gemini 작업 실패" : "Codex 작업 실패")
        let fallbackChat = L10n.text(activity.provider == .gemini ? "Gemini 채팅" : "Codex 채팅")
        let title = activity.title.isEmpty ? fallbackChat : activity.title
        content.body = L10n.text("%@ 작업을 완료하지 못했습니다. 작업 내용을 확인하세요.", title)
        content.sound = notificationSettings.sound
        content.userInfo = threadUserInfo(activity)
        submit(UNNotificationRequest(identifier: "failure-\(activity.id)-\(UUID().uuidString)",
                                     content: content, trigger: nil))
    }

    func attentionNeeded(_ event: ThreadAttentionEvent) {
        let isGemini = event.activity.provider == .gemini
        let kind: NotificationKind
        let titleKey: String
        let bodyKey: String
        switch event.kind {
        case .approval:
            kind = .approval
            titleKey = isGemini ? "Gemini 승인 필요" : "Codex 승인 필요"
            bodyKey = "%@ 작업에서 승인이 필요합니다."
        case .answer:
            kind = .answer
            titleKey = isGemini ? "Gemini 답변 필요" : "Codex 답변 필요"
            bodyKey = "%@ 작업에서 답변을 기다리고 있습니다."
        case .mcp:
            kind = .mcp
            titleKey = isGemini ? "Gemini MCP 확인 필요" : "Codex MCP 확인 필요"
            bodyKey = "%@ 작업에서 MCP 서버의 입력 또는 확인이 필요합니다."
        case .appApproval:
            kind = .appApproval
            titleKey = isGemini ? "Gemini 앱 승인 필요" : "Codex 앱 승인 필요"
            bodyKey = "%@ 작업에서 연결된 앱의 작업 실행 승인이 필요합니다."
        }
        guard isThreadNotificationEnabled(kind, scope: ThreadNotificationPreferences.scope(for: event.activity)) else { return }
        let activity = event.activity
        let content = UNMutableNotificationContent()
        NotificationIconProvider.apply(to: content, provider: activity.provider)
        content.title = L10n.text(titleKey)
        let fallbackChat = L10n.text(isGemini ? "Gemini 채팅" : "Codex 채팅")
        content.body = activity.title.isEmpty
            ? L10n.text(bodyKey, fallbackChat)
            : L10n.text(bodyKey, activity.title)
        content.sound = notificationSettings.sound
        content.userInfo = threadUserInfo(activity)
        content.userInfo["notificationKind"] = kind.rawValue
        if let identity = event.requestIdentity { content.userInfo["requestIdentity"] = identity }
        submit(UNNotificationRequest(identifier: "attention-\(activity.id)-\(UUID().uuidString)",
                                     content: content, trigger: nil))
    }

    func scheduleResets(_ quota: Quota, account: CodexAccount?, requestStartedAt: Date? = nil) {
        let observedAt = requestStartedAt ?? resetClock()
        let age = resetClock().timeIntervalSince(observedAt)
        // A slow or out-of-order response must not replace a newer baseline.
        guard age.isFinite, age >= 0, age <= 60,
              resetTargets.values.allSatisfy({ observedAt >= $0.observedAt }) else { return }
        let quota = quota.effectiveQuota(account: account)
        let plan = quota.resolvedPlan(fallback: account?.planType)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let previous = resetTargets
        resetTargets.removeAll()
        if notificationSettings.isEnabled(.reset),
           let email = account?.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            let accountScope = email.lowercased()
            for (name, window) in [("primary", quota.primary), ("secondary", quota.secondary)] {
                guard let window, let timestamp = window.resetsAt, timestamp.isFinite,
                      window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                      timestamp > 0, timestamp < Date.distantFuture.timeIntervalSince1970,
                      let minutes = window.windowDurationMins, minutes > 0 else { continue }
                let duration = TimeInterval(minutes) * 60
                let prior = previous[name]
                var confirmedAt: Double?
                if let prior, prior.account == accountScope, prior.windowDuration == duration, prior.plan == plan {
                    // A request spanning the boundary cannot validate the reset.
                    // Keep its original deadline so the next post-boundary fetch can.
                    if observedAt.timeIntervalSince1970 < prior.timestamp,
                       Self.isPreviousCycleDue(pendingAt: prior.timestamp, latestAt: timestamp,
                                               now: resetClock().timeIntervalSince1970,
                                               windowDuration: duration) {
                        resetTargets[name] = prior
                        continue
                    }
                    if prior.timestamp == timestamp {
                        // A failed submission can retry only after another successful fetch.
                        confirmedAt = prior.confirmedAt
                    } else if (window.usedPercent < prior.usedPercent || (prior.usedPercent == 0 && window.usedPercent == 0)),
                              Self.isPreviousCycleDue(pendingAt: prior.timestamp, latestAt: timestamp,
                                                       now: observedAt.timeIntervalSince1970,
                                                       windowDuration: duration) {
                        confirmedAt = prior.timestamp
                    }
                }
                // A date correction or plan change alone is not evidence of a reset.
                // Nonempty usage must fall as well; an unused window stays at zero.
                resetTargets[name] = ResetTarget(timestamp: timestamp, windowDuration: duration,
                    usedPercent: window.usedPercent, plan: plan,
                    account: accountScope,
                    label: window.displayLabel(planType: quota.resolvedPlan(fallback: account?.planType),
                                               isPrimary: name == "primary"),
                    sound: resetSoundSignature, observedAt: observedAt, confirmedAt: confirmedAt)
            }
        }
        reconcileResets()
    }

    func invalidateResetAccount() {
        resetTargets.removeAll()
        invalidateResetCreditExpiry()
        reconcileResets()
    }

    func scheduleResetCreditExpiry(_ summary: RateLimitResetCreditsSummary?, account: CodexAccount?,
                                   requestStartedAt: Date? = nil) {
        resetCreditExpiry.update(summary, account: account?.email, requestStartedAt: requestStartedAt)
    }

    func invalidateResetCreditExpiry() {
        resetCreditExpiry.invalidateAccount()
    }

    private var resetSoundSignature: String {
        "\(notificationSettings.customSoundName ?? "default")|\(notificationSettings.soundDuration)|\(notificationSettings.soundVolume)"
    }

    static func resetIdentifier(name: String, timestamp: Double) -> String {
        "reset-\(name)-\(String(timestamp.bitPattern, radix: 16))"
    }

    private static func resetName(for identifier: String) -> String? {
        resetNames.first { identifier == "reset-\($0)" || identifier.hasPrefix("reset-\($0)-") }
    }

    static func isPreviousCycleDue(pendingAt: Double?, latestAt: Double, now: Double,
                                   windowDuration: TimeInterval?) -> Bool {
        guard let pendingAt, pendingAt.isFinite, latestAt.isFinite, now.isFinite,
              pendingAt <= now, now - pendingAt <= 300, latestAt > now,
              let windowDuration, windowDuration.isFinite, windowDuration > 0 else { return false }
        // Require a freshly observed cycle advance, not just the local clock
        // passing a cached deadline. Never catch up hours-old reset banners.
        let tolerance = windowDuration >= 28 * 86400 ? 3 * 86400.0 : min(600, windowDuration * 0.1)
        return abs((latestAt - pendingAt) - windowDuration) <= tolerance
    }

    private func resetIsCurrent(_ target: ResetTarget, name: String, now: Date) -> Bool {
        guard notificationSettings.isEnabled(.reset),
              let current = resetTargets[name], current.account == target.account,
              current.timestamp == target.timestamp, current.confirmedAt == target.confirmedAt,
              let deadline = target.confirmedAt,
              current.observedAt.timeIntervalSince1970 >= deadline,
              now.timeIntervalSince(current.observedAt) >= 0,
              now.timeIntervalSince(current.observedAt) <= 60,
              now.timeIntervalSince1970 - deadline <= 300 else { return false }
        return true
    }

    private func reconcileResets() {
        guard !resetSyncInProgress else { resetSyncRequested = true; return }
        resetSyncInProgress = true
        readPendingResets { [weak self] requests in
            DispatchQueue.main.async {
                guard let self else { return }
                // Never leave an unvalidated future request in macOS, including
                // requests created by an older build. Immediate submissions are not timers.
                for request in requests where Self.resetName(for: request.identifier) != nil && request.trigger != nil {
                    if let name = Self.resetName(for: request.identifier),
                       let account = request.content.userInfo["resetAccount"] as? String,
                       let deadline = request.content.userInfo["resetAt"] as? Double {
                        self.cycleLedger.cancelFuture(account: account, name: name, deadline: deadline,
                                                       now: self.resetClock().timeIntervalSince1970)
                    }
                    self.removeReset([request.identifier])
                }
                let now = self.resetClock()
                guard self.resetTargets.contains(where: { name, target in
                    guard let deadline = target.confirmedAt else { return false }
                    return self.resetIsCurrent(target, name: name, now: now)
                        && self.cycleLedger.permits(account: target.account, name: name,
                                                    deadline: deadline, now: now.timeIntervalSince1970)
                }) else {
                    self.sendValidatedResets(authorized: false)
                    return
                }
                self.readResetAuthorization { [weak self] authorized in
                    DispatchQueue.main.async {
                        self?.sendValidatedResets(authorized: authorized)
                    }
                }
            }
        }
    }

    private func sendValidatedResets(authorized: Bool) {
        let group = DispatchGroup()
        let now = resetClock()
        if authorized {
            for name in Self.resetNames {
                guard let target = resetTargets[name], resetIsCurrent(target, name: name, now: now),
                      let deadline = target.confirmedAt, let duration = target.windowDuration,
                      cycleLedger.permits(account: target.account, name: name, deadline: deadline,
                                          now: now.timeIntervalSince1970) else { continue }
                let id = Self.resetIdentifier(name: name + "-" + ThreadRecordScope.key(target.account), timestamp: deadline)
                let content = UNMutableNotificationContent()
                NotificationIconProvider.apply(to: content, provider: .codex)
                content.title = L10n.text("Codex %@ 초기화 시간", target.label)
                content.body = L10n.text("사용량 초기화 예정 시간이 되었습니다. PlusCodex에서 남은 사용량을 확인하세요.")
                content.sound = notificationSettings.sound
                content.userInfo = ["resetAt": deadline, "resetAccount": target.account,
                                    "resetLabel": target.label, "resetSound": target.sound]
                group.enter()
                addReset(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
                    DispatchQueue.main.async {
                        if let self {
                            if let error {
                                NSLog("PlusCodex reset notification failed: %@", error.localizedDescription)
                            } else {
                                self.cycleLedger.registered(account: target.account, name: name,
                                                            deadline: deadline, duration: duration)
                                if !self.resetIsCurrent(target, name: name, now: self.resetClock()) {
                                    self.removeReset([id])
                                }
                            }
                        }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.resetSyncInProgress = false
            if self.resetSyncRequested {
                self.resetSyncRequested = false
                self.reconcileResets()
            }
        }
    }

    private func notificationSettingsDidChange() {
        autoCleanup.synchronize()
        resetCreditExpiry.settingsDidChange()
        // Cached quota must not become fresh evidence when a setting changes.
        resetTargets.removeAll()
        reconcileResets()
    }

    private func submit(_ request: UNNotificationRequest, attempt: Int = 0) {
        guard !readCleanup.wasRead(request) else { return }
        NotificationDelivery.shared.add(request, duration: notificationSettings.notificationPlaybackDuration) { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // An OS submission can finish after the task has already been read.
                if self.readCleanup.wasRead(request) {
                    self.center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    self.center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    NotificationDelivery.shared.cancel(request.identifier)
                    return
                }
                guard let error else { return }
                NSLog("PlusCodex notification failed: %@", error.localizedDescription)
                guard attempt < 2 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double((attempt + 1) * 5)) { [weak self] in
                    guard let self else { return }
                    let kind: NotificationKind = request.identifier.hasPrefix("completion-") ? .completion
                        : request.identifier.hasPrefix("failure-") ? .failure
                        : NotificationKind(rawValue: request.content.userInfo["notificationKind"] as? String ?? "") ?? .approval
                    guard self.isThreadNotificationEnabled(kind,
                        scope: request.content.userInfo["notificationScope"] as? String) else { return }
                    if request.identifier.hasPrefix("attention-") {
                        guard let id = request.content.userInfo["threadID"] as? String,
                              self.isAttentionRequestCurrent?(id, request.content.userInfo["requestIdentity"] as? String) == true else { return }
                    }
                    self.submit(request, attempt: attempt + 1)
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banners even when PlusCodex itself is frontmost; Codex being
        // frontmost never suppresses a notification from this app either.
        DispatchQueue.main.async { [weak self] in
            completionHandler(self?.readCleanup.wasRead(notification.request) == true
                ? [] : Self.foregroundPresentationOptions)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           response.notification.request.content.userInfo["updateAvailable"] as? Bool == true {
            DispatchQueue.main.async { [weak self] in self?.onUpdateNotificationOpened?() }
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let userInfo = response.notification.request.content.userInfo
            if let urlString = userInfo["threadURL"] as? String, let url = URL(string: urlString) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            } else if let id = userInfo["threadID"] as? String,
                      UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/\(id)") {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
        }
        completionHandler()
    }
}
