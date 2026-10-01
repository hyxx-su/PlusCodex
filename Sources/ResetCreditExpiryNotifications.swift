import Foundation
import CryptoKit
import UserNotifications

struct ResetCreditExpiryTarget: Equatable {
    static let prefix = "reset-credit-expiry-"
    let identifier: String
    let accountScope: String
    let creditID: String
    let expiresAt: Double
    let reminderAt: Double

    init?(credit: RateLimitResetCredit, accountScope: String, now: Date, calendar: Calendar) {
        guard !credit.id.isEmpty, !accountScope.isEmpty, credit.status == "available",
              credit.resetType == "codexRateLimits", let expiry = credit.expiresAt,
              expiry.isFinite, expiry > now.timeIntervalSince1970,
              expiry < Date.distantFuture.timeIntervalSince1970 else { return nil }
        let expiration = Date(timeIntervalSince1970: expiry)
        // A calendar day, rather than 24 hours, keeps 9 AM stable across DST.
        guard let previousDay = calendar.date(byAdding: .day, value: -1,
                                             to: calendar.startOfDay(for: expiration)),
              let reminder = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: previousDay) else { return nil }
        self.accountScope = accountScope
        creditID = credit.id
        expiresAt = expiry
        reminderAt = reminder.timeIntervalSince1970
        let digest = SHA256.hash(data: Data((accountScope + "\0" + credit.id).utf8))
            .map { String(format: "%02x", $0) }.joined()
        // A corrected expiry must not create a second reminder for the same credit.
        identifier = Self.prefix + digest
    }

    func matches(_ request: UNNotificationRequest, sound: String) -> Bool {
        let info = request.content.userInfo
        return request.identifier == identifier && request.trigger != nil
            && info["expiryAccount"] as? String == accountScope
            && info["expiryCreditID"] as? String == creditID
            && info["expiryAt"] as? Double == expiresAt
            && info["expiryReminderAt"] as? Double == reminderAt
            && info["expirySound"] as? String == sound
    }
}

/// Persist accepted OS reservations, not an assumption that submission succeeded.
/// Once their deadline passes, retain a conservative receipt even if the user
/// dismissed the banner. Reopening the app must not repeat that credit's reminder.
final class ResetCreditExpiryLedger {
    private struct Entry: Codable, Equatable {
        let fireAt: Double
        let expiresAt: Double
    }
    private let defaults: UserDefaults
    private let key = "resetCreditExpiryLedger.v1"
    private var entries: [String: Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode([String: Entry].self, from: $0)
        } ?? [:]
    }

    func permits(_ id: String, now: Date) -> Bool {
        entries[id].map { $0.fireAt > now.timeIntervalSince1970 } ?? true
    }

    func registered(_ id: String, fireAt: Double, expiresAt: Double, now: Date) {
        guard fireAt.isFinite, expiresAt.isFinite, permits(id, now: now) else { return }
        let entry = Entry(fireAt: fireAt, expiresAt: expiresAt)
        guard entries[id] != entry else { return }
        entries[id] = entry
        entries = entries.filter { $0.value.expiresAt > now.timeIntervalSince1970 - 90 * 86400 }
        save()
    }

    func observe(_ request: UNNotificationRequest, now: Date) {
        guard entries[request.identifier] == nil,
              let fireAt = request.content.userInfo["expiryFireAt"] as? Double,
              let expiry = request.content.userInfo["expiryAt"] as? Double else { return }
        registered(request.identifier, fireAt: fireAt, expiresAt: expiry, now: now)
    }

    func cancelFuture(_ id: String, now: Date) {
        guard let entry = entries[id], entry.fireAt > now.timeIntervalSince1970 else { return }
        entries.removeValue(forKey: id)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}

/// Owns only earned-reset expiry reminders. Quota resets and wake scheduling
/// remain independent. State and callbacks are serialized on the main queue.
final class ResetCreditExpiryNotifications {
    private let settings: NotificationSettings
    private let ledger: ResetCreditExpiryLedger
    private let readPending: (@escaping ([UNNotificationRequest]) -> Void) -> Void
    private let readAuthorization: (@escaping (Bool) -> Void) -> Void
    private let add: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
    private let remove: ([String]) -> Void
    private let clock: () -> Date
    private let calendar: () -> Calendar
    private var accountScope: String?
    private var credits: [String: RateLimitResetCredit] = [:]
    private var observedCreditIDs = Set<String>()
    private var preserveUnlisted = false
    private var hasSnapshot = false
    private var syncRequested = false
    private(set) var synchronizing = false

    init(settings: NotificationSettings, defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { Calendar.current },
         readPending: ((@escaping ([UNNotificationRequest]) -> Void) -> Void)? = nil,
         readAuthorization: ((@escaping (Bool) -> Void) -> Void)? = nil,
         add: ((UNNotificationRequest, @escaping (Error?) -> Void) -> Void)? = nil,
         remove: (([String]) -> Void)? = nil) {
        self.settings = settings
        ledger = ResetCreditExpiryLedger(defaults: defaults)
        self.clock = clock
        self.calendar = calendar
        self.readPending = readPending ?? { completion in
            let startedAt = Date()
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                NotificationDelivery.shared.remember(requests,
                    defaultDuration: settings.notificationPlaybackDuration, snapshotStartedAt: startedAt)
                completion(requests)
            }
        }
        self.readAuthorization = readAuthorization ?? { completion in
            UNUserNotificationCenter.current().getNotificationSettings { value in
                completion(value.authorizationStatus == .authorized || value.authorizationStatus == .provisional)
            }
        }
        self.add = add ?? { request, completion in
            NotificationDelivery.shared.add(request, duration: settings.notificationPlaybackDuration,
                                            completion: completion)
        }
        self.remove = remove ?? { ids in
            ids.forEach { NotificationDelivery.shared.cancel($0) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func start() {
        if !settings.isEnabled(.resetCreditExpiry) { invalidateAccount() }
    }

    func update(_ summary: RateLimitResetCreditsSummary?, account: String?) {
        guard let account = account?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty else { return }
        let scope = ThreadRecordScope.key(account)
        if accountScope != scope {
            credits.removeAll()
            observedCreditIDs.removeAll()
            preserveUnlisted = true
            accountScope = scope
        }
        hasSnapshot = true
        if let summary {
            if summary.availableCount <= 0 {
                credits.removeAll()
                observedCreditIDs.removeAll()
                preserveUnlisted = false
            } else if let rows = summary.credits {
                // A capped list is not proof that an omitted credit was redeemed.
                preserveUnlisted = summary.availableCount > rows.filter { $0.status == "available" }.count
                if !preserveUnlisted { credits.removeAll() }
                observedCreditIDs = Set(rows.map(\.id))
                for credit in rows {
                    if credit.status == "available", credit.resetType == "codexRateLimits" {
                        credits[credit.id] = credit
                    } else {
                        credits.removeValue(forKey: credit.id)
                    }
                }
            } else {
                preserveUnlisted = true
            }
        }
        let now = clock().timeIntervalSince1970
        // Partial detail responses can persist for a long time; never retain
        // expired reward rows indefinitely while preserving omitted live ones.
        credits = credits.filter {
            guard let expiry = $0.value.expiresAt, expiry.isFinite else { return false }
            return expiry > now && expiry < Date.distantFuture.timeIntervalSince1970
        }
        reconcile()
    }

    func invalidateAccount() {
        accountScope = nil
        credits.removeAll()
        observedCreditIDs.removeAll()
        preserveUnlisted = false
        hasSnapshot = true
        reconcile()
    }

    func settingsDidChange() {
        if hasSnapshot || !settings.isEnabled(.resetCreditExpiry) { reconcile() }
    }

    private func targets(now: Date) -> [String: ResetCreditExpiryTarget] {
        guard settings.isEnabled(.resetCreditExpiry), let scope = accountScope else { return [:] }
        var result: [String: ResetCreditExpiryTarget] = [:]
        for credit in credits.values {
            guard let target = ResetCreditExpiryTarget(credit: credit, accountScope: scope, now: now,
                                                       calendar: calendar()) else { continue }
            result[target.identifier] = target
        }
        return result
    }

    private func preservesUnknown(_ request: UNNotificationRequest, now: Date) -> Bool {
        let info = request.content.userInfo
        guard settings.isEnabled(.resetCreditExpiry), preserveUnlisted,
              info["expiryAccount"] as? String == accountScope,
              let id = info["expiryCreditID"] as? String, !observedCreditIDs.contains(id),
              let expiry = info["expiryAt"] as? Double, expiry > now.timeIntervalSince1970 else { return false }
        return true
    }

    private func cancel(_ id: String, now: Date) {
        remove([id])
        ledger.cancelFuture(id, now: now)
    }

    private var soundSignature: String {
        "\(settings.customSoundName ?? "default")|\(settings.soundDuration)|\(settings.soundVolume)"
    }

    private func reconcile() {
        guard !synchronizing else { syncRequested = true; return }
        synchronizing = true
        readPending { [weak self] requests in
            DispatchQueue.main.async {
                guard let self else { return }
                self.readAuthorization { [weak self] authorized in
                    DispatchQueue.main.async {
                        self?.reconcile(requests: requests, authorized: authorized)
                    }
                }
            }
        }
    }

    private func reconcile(requests: [UNNotificationRequest], authorized: Bool) {
        let now = clock()
        let desired = targets(now: now)
        var matching = Set<String>()
        for request in requests where request.identifier.hasPrefix(ResetCreditExpiryTarget.prefix) {
            ledger.observe(request, now: now)
            guard let target = desired[request.identifier] else {
                if !preservesUnknown(request, now: now) { cancel(request.identifier, now: now) }
                continue
            }
            if target.matches(request, sound: soundSignature) || !ledger.permits(target.identifier, now: now) {
                matching.insert(target.identifier)
            }
        }
        let group = DispatchGroup()
        if authorized {
            for target in desired.values.sorted(by: { $0.identifier < $1.identifier }) {
                guard !matching.contains(target.identifier), ledger.permits(target.identifier, now: now) else { continue }
                let fireAt = max(target.reminderAt, now.timeIntervalSince1970 + 1)
                // Do not submit a catch-up reminder which would arrive after expiry.
                guard fireAt < target.expiresAt else { continue }
                let content = UNMutableNotificationContent()
                content.title = L10n.text("Codex 초기화권 만료 예정")
                let formatter = DateFormatter()
                formatter.locale = L10n.locale
                formatter.timeZone = calendar().timeZone
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                content.body = L10n.text("초기화권이 %@에 만료됩니다. Codex에서 만료 전에 사용하세요.",
                                        formatter.string(from: Date(timeIntervalSince1970: target.expiresAt)))
                content.sound = settings.sound
                content.userInfo = ["notificationKind": NotificationKind.resetCreditExpiry.rawValue,
                    "expiryAccount": target.accountScope, "expiryCreditID": target.creditID,
                    "expiryAt": target.expiresAt, "expiryReminderAt": target.reminderAt,
                    "expiryFireAt": fireAt, "expirySound": soundSignature]
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, fireAt - clock().timeIntervalSince1970), repeats: false)
                group.enter()
                add(UNNotificationRequest(identifier: target.identifier, content: content, trigger: trigger)) { [weak self] error in
                    DispatchQueue.main.async {
                        if let self {
                            if let error {
                                NSLog("PlusCodex reset credit reminder failed: %@", error.localizedDescription)
                            } else {
                                let completedAt = self.clock()
                                self.ledger.registered(target.identifier, fireAt: fireAt,
                                                       expiresAt: target.expiresAt, now: completedAt)
                                // An account/settings change during add must not resurrect its old request.
                                if self.targets(now: completedAt)[target.identifier] != target {
                                    self.cancel(target.identifier, now: completedAt)
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
            self.synchronizing = false
            if self.syncRequested {
                self.syncRequested = false
                self.reconcile()
            }
        }
    }
}
