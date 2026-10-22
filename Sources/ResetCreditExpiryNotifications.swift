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

}

/// Persist successful submissions so relaunching cannot repeat a credit's reminder.
/// Legacy reservations whose deadline passed remain conservatively consumed;
/// cancelling a future legacy reservation releases it for fresh validation.
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
    private var fetchedAt: Date?
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
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func start() {
        // Old OS timers cannot validate redeemed credits while the app is closed.
        invalidateAccount()
    }

    func update(_ summary: RateLimitResetCreditsSummary?, account: String?, requestStartedAt: Date? = nil) {
        let observedAt = requestStartedAt ?? clock()
        let age = clock().timeIntervalSince(observedAt)
        guard age.isFinite, age >= 0, age <= 60,
              fetchedAt.map({ observedAt >= $0 }) ?? true else { return }
        credits.removeAll()
        fetchedAt = observedAt
        guard let account = account?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty else {
            invalidateAccount()
            return
        }
        accountScope = ThreadRecordScope.key(account)
        // Missing/capped rows are not proof of redemption, but neither are they
        // permission to send. Only credits explicitly present in this fetch qualify.
        if let summary, summary.availableCount > 0, let rows = summary.credits {
            // Conflicting duplicate IDs must not become valid just because the
            // available row happened to be last in the server response.
            let groups = Dictionary(grouping: rows, by: \.id)
            let availableRows = groups.values.filter { $0.contains { $0.status == "available" } }.count
            if availableRows <= summary.availableCount {
                for (id, rows) in groups where rows.count == 1 { credits[id] = rows[0] }
            }
        }
        reconcile()
    }

    func invalidateAccount() {
        accountScope = nil
        credits.removeAll()
        fetchedAt = nil
        reconcile()
    }

    func settingsDidChange() {
        // Re-enabling a setting is not a fresh server check.
        fetchedAt = nil
        reconcile()
    }

    private func targets(now: Date) -> [String: ResetCreditExpiryTarget] {
        guard settings.isEnabled(.resetCreditExpiry), let scope = accountScope,
              let fetchedAt, now.timeIntervalSince(fetchedAt) >= 0,
              now.timeIntervalSince(fetchedAt) <= 60 else { return [:] }
        var result: [String: ResetCreditExpiryTarget] = [:]
        let currentCalendar = calendar()
        for credit in credits.values {
            guard let target = ResetCreditExpiryTarget(credit: credit, accountScope: scope, now: now,
                                                       calendar: currentCalendar),
                  target.reminderAt <= fetchedAt.timeIntervalSince1970,
                  target.expiresAt > now.timeIntervalSince1970 + 1 else { continue }
            result[target.identifier] = target
        }
        return result
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
                let now = self.clock()
                for request in requests where request.identifier.hasPrefix(ResetCreditExpiryTarget.prefix) && request.trigger != nil {
                    self.ledger.observe(request, now: now)
                    self.cancel(request.identifier, now: now)
                }
                guard self.targets(now: now).values.contains(where: { self.ledger.permits($0.identifier, now: now) }) else {
                    self.reconcile(authorized: false)
                    return
                }
                self.readAuthorization { [weak self] authorized in
                    DispatchQueue.main.async {
                        self?.reconcile(authorized: authorized)
                    }
                }
            }
        }
    }

    private func reconcile(authorized: Bool) {
        let now = clock()
        let desired = targets(now: now)
        let group = DispatchGroup()
        if authorized {
            for target in desired.values.sorted(by: { $0.identifier < $1.identifier }) {
                guard ledger.permits(target.identifier, now: now) else { continue }
                let fireAt = now.timeIntervalSince1970
                let content = UNMutableNotificationContent()
                NotificationIconProvider.apply(to: content, provider: .codex)
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
                group.enter()
                add(UNNotificationRequest(identifier: target.identifier, content: content, trigger: nil)) { [weak self] error in
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
