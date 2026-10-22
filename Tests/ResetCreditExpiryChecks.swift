import Foundation
import UserNotifications

private final class ExpiryNotificationCenterFixture {
    var now: Date
    var pending: [String: UNNotificationRequest] = [:]
    var additions = 0
    var authorized = true
    var failNext = false
    var holdAdditions = false
    var held: [(UNNotificationRequest, (Error?) -> Void)] = []
    var requestsRead = 0
    var authorizationReads = 0
    var holdAuthorization = false
    var authorization: ((Bool) -> Void)?

    init(now: Date) { self.now = now }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        additions += 1
        if holdAdditions {
            held.append((request, completion))
        } else if failNext {
            failNext = false
            completion(NSError(domain: "expiry-fixture", code: 1))
        } else {
            pending[request.identifier] = request
            completion(nil)
        }
    }

    func release() {
        holdAdditions = false
        let completions = held
        held.removeAll()
        for (request, completion) in completions {
            pending[request.identifier] = request
            completion(nil)
        }
    }

    func scheduler(settings: NotificationSettings, defaults: UserDefaults, calendar: Calendar) -> ResetCreditExpiryNotifications {
        ResetCreditExpiryNotifications(settings: settings, defaults: defaults, clock: { self.now },
            calendar: { calendar }, readPending: { completion in
                self.requestsRead += 1
                completion(Array(self.pending.values))
            }, readAuthorization: { completion in
                self.authorizationReads += 1
                if self.holdAuthorization { self.authorization = completion }
                else { completion(self.authorized) }
            }, add: { self.add($0, completion: $1) },
            remove: { ids in ids.forEach { self.pending.removeValue(forKey: $0) } })
    }
}

@main struct ResetCreditExpiryChecks {
    static func main() {
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let start = date("2026-10-01T00:00:00Z")
        let expiry = date("2026-10-05T06:00:00Z")
        let reminder = date("2026-10-04T00:00:00Z")
        func credit(_ id: String = "credit-1", expiry: Double? = expiry.timeIntervalSince1970,
                    status: String = "available", type: String = "codexRateLimits") -> RateLimitResetCredit {
            RateLimitResetCredit(id: id, resetType: type, status: status, expiresAt: expiry)
        }
        func summary(_ rows: [RateLimitResetCredit], count: Int? = nil) -> RateLimitResetCreditsSummary {
            RateLimitResetCreditsSummary(availableCount: count ?? rows.count, credits: rows)
        }
        func waitUntil(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            precondition(condition(), "Asynchronous expiry reconciliation did not finish")
        }
        func drain(_ scheduler: ResetCreditExpiryNotifications) { waitUntil { !scheduler.synchronizing } }
        func isolated(_ test: (UserDefaults, NotificationSettings, ExpiryNotificationCenterFixture) -> Void) {
            let suite = "PlusCodex.reset-credit-expiry.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = NotificationSettings(defaults: defaults)
            test(defaults, settings, ExpiryNotificationCenterFixture(now: start))
        }

        let scope = ThreadRecordScope.key("account-a@example.com")
        let target = ResetCreditExpiryTarget(credit: credit(), accountScope: scope, now: start, calendar: calendar)!
        precondition(target.reminderAt == reminder.timeIntervalSince1970)
        let midnight = ResetCreditExpiryTarget(credit: credit(expiry: date("2026-10-04T15:00:00Z").timeIntervalSince1970),
                                               accountScope: scope, now: start, calendar: calendar)!
        precondition(midnight.reminderAt == reminder.timeIntervalSince1970, "A midnight expiry still uses the previous date")
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dst = ResetCreditExpiryTarget(credit: credit(expiry: date("2026-11-01T17:00:00Z").timeIntervalSince1970),
                                         accountScope: scope, now: start, calendar: pacific)!
        precondition(dst.reminderAt == date("2026-10-31T16:00:00Z").timeIntervalSince1970,
                     "DST must not shift the local 9 AM reminder")
        for invalid in [credit(expiry: nil), credit(expiry: .nan), credit(expiry: .infinity),
                        credit(expiry: start.timeIntervalSince1970), credit(status: "redeemed"),
                        credit(status: "redeeming"), credit(status: "unknown"), credit(type: "unknown"), credit("")] {
            precondition(ResetCreditExpiryTarget(credit: invalid, accountScope: scope, now: start, calendar: calendar) == nil)
        }
        let revised = ResetCreditExpiryTarget(credit: credit(expiry: expiry.addingTimeInterval(86400).timeIntervalSince1970),
                                             accountScope: scope, now: start, calendar: calendar)!
        precondition(revised.identifier == target.identifier)
        let otherAccount = ResetCreditExpiryTarget(credit: credit(), accountScope: ThreadRecordScope.key("account-b@example.com"),
                                                  now: start, calendar: calendar)!
        precondition(otherAccount.identifier != target.identifier)
        precondition(ResetCreditExpiryTarget(credit: credit("CREDIT-1"), accountScope: scope, now: start, calendar: calendar)!
            .identifier != target.identifier, "Opaque credit IDs are case-sensitive")

        isolated { defaults, settings, center in
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 0, "Future expiry reminders must not be booked with macOS")
            precondition(center.authorizationReads == 0, "Future reminders need no permission IPC")
            center.now = reminder.addingTimeInterval(5)
            scheduler.settingsDidChange()
            drain(scheduler)
            precondition(center.additions == 0, "Changing settings cannot validate cached credits")
            scheduler.update(summary([credit()]), account: "Account-A@Example.com")
            drain(scheduler)
            precondition(center.additions == 1)
            let request = center.pending[target.identifier]!
            precondition(request.trigger == nil && request.content.sound != nil)
            precondition(request.content.userInfo["expiryFireAt"] as? Double == center.now.timeIntervalSince1970)
            precondition(request.content.userInfo["notificationKind"] as? String == "resetCreditExpiry")
            let saved = defaults.data(forKey: "resetCreditExpiryLedger.v1")
            for _ in 0..<25 { scheduler.update(summary([credit()]), account: "account-a@example.com") }
            drain(scheduler)
            precondition(center.additions == 1 && defaults.data(forKey: "resetCreditExpiryLedger.v1") == saved)
            precondition(center.authorizationReads == 1, "A consumed credit must not re-read permission")
            center.pending.removeAll()
            let relaunched = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            relaunched.update(summary([credit()]), account: "account-a@example.com")
            drain(relaunched)
            precondition(center.additions == 1, "Relaunch must not repeat an accepted immediate reminder")
            relaunched.update(summary([credit()]), account: "account-b@example.com")
            drain(relaunched)
            precondition(center.additions == 2 && center.pending[otherAccount.identifier] != nil)
        }

        isolated { defaults, settings, center in
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            center.now = reminder.addingTimeInterval(5)
            for missing in [nil, RateLimitResetCreditsSummary(availableCount: 1, credits: nil),
                            summary([], count: 0), summary([credit(status: "redeemed")]),
                            summary([credit(status: "redeeming")]), summary([credit(expiry: nil)]),
                            summary([credit(expiry: revised.expiresAt)])] {
                scheduler.update(missing, account: "account-a@example.com")
                drain(scheduler)
                precondition(center.additions == 0, "Unverified, redeemed or postponed credits must not notify")
            }
            scheduler.update(summary([credit()]), account: nil)
            drain(scheduler)
            precondition(center.additions == 0, "Unknown identity cannot reuse prior credit data")
            scheduler.update(summary([credit()]), account: "account-a@example.com", requestStartedAt: reminder.addingTimeInterval(-1))
            drain(scheduler)
            precondition(center.additions == 0, "A fetch started before the reminder is not a due-time check")
            scheduler.update(summary([credit()]), account: "account-a@example.com", requestStartedAt: center.now.addingTimeInterval(-61))
            drain(scheduler)
            precondition(center.additions == 0, "Delayed responses are not fresh evidence")
            center.now = expiry.addingTimeInterval(-0.5)
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            center.now = expiry
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 0, "Expired or imminently expiring credits must not notify")
        }

        isolated { defaults, settings, center in
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            scheduler.update(summary([credit(), credit("credit-2")]), account: "account-a@example.com")
            drain(scheduler)
            center.now = reminder.addingTimeInterval(5)
            scheduler.update(summary([credit("credit-2")], count: 2), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 1 && center.pending[target.identifier] == nil,
                         "A capped list may notify only explicitly confirmed credits")
        }

        isolated { defaults, settings, center in
            let content = UNMutableNotificationContent()
            content.userInfo = ["expiryAccount": scope, "expiryCreditID": "credit-1",
                                "expiryFireAt": reminder.timeIntervalSince1970,
                                "expiryAt": expiry.timeIntervalSince1970]
            center.pending[target.identifier] = UNNotificationRequest(identifier: target.identifier,
                content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false))
            let unrelated = UNNotificationRequest(identifier: "completion-unrelated", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false))
            center.pending[unrelated.identifier] = unrelated
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            scheduler.start()
            drain(scheduler)
            precondition(center.pending.count == 1 && center.pending[unrelated.identifier] != nil,
                         "Launch removes legacy credit timers even before an offline fetch")
            center.now = reminder.addingTimeInterval(5)
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 1, "Cancelling a future reservation must not consume the reminder")
        }

        isolated { defaults, settings, center in
            center.now = reminder.addingTimeInterval(5)
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            center.authorized = false
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 0)
            center.authorized = true
            center.failNext = true
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.pending.isEmpty && defaults.data(forKey: "resetCreditExpiryLedger.v1") == nil)
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 2 && center.pending.count == 1)
        }

        for rows in [[credit(status: "redeemed"), credit()], [credit(), credit(status: "redeemed")],
                     [credit(), credit()], [credit(), credit("credit-2")]] {
            isolated { defaults, settings, center in
                center.now = reminder.addingTimeInterval(5)
                let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
                scheduler.update(summary(rows, count: 1), account: "account-a@example.com")
                drain(scheduler)
                precondition(center.additions == 0 && center.authorizationReads == 0,
                             "Duplicate IDs or a contradictory available count must not notify")
            }
        }

        for offset in [-1.0, -61, 1, .nan] {
            isolated { defaults, settings, center in
                center.now = reminder.addingTimeInterval(5)
                let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
                scheduler.update(summary([], count: 0), account: "account-a@example.com")
                drain(scheduler)
                scheduler.update(summary([credit()]), account: "account-a@example.com",
                                 requestStartedAt: center.now.addingTimeInterval(offset))
                drain(scheduler)
                precondition(center.additions == 0, "An old or invalid response cannot resurrect a redeemed credit")
            }
        }

        for change in 0..<3 {
            isolated { defaults, settings, center in
                center.now = reminder.addingTimeInterval(5)
                center.holdAuthorization = true
                let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
                scheduler.update(summary([credit()]), account: "account-a@example.com")
                waitUntil { center.authorization != nil }
                if change == 0 { center.now = center.now.addingTimeInterval(61) }
                if change == 1 { scheduler.update(nil, account: "account-a@example.com") }
                if change == 2 { center.now = expiry }
                center.holdAuthorization = false
                let completion = center.authorization!
                center.authorization = nil
                completion(true)
                drain(scheduler)
                precondition(center.additions == 0, "Recheck freshness and expiry immediately before submission")
            }
        }

        for change in 0..<4 {
            isolated { defaults, settings, center in
                center.now = reminder.addingTimeInterval(5)
                let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
                center.holdAdditions = true
                scheduler.update(summary([credit()]), account: "account-a@example.com")
                waitUntil { center.held.count == 1 }
                if change == 0 {
                    scheduler.update(summary([], count: 0), account: "account-a@example.com")
                } else if change == 1 {
                    scheduler.update(nil, account: "account-b@example.com")
                } else if change == 2 {
                    settings.setEnabled(false, for: .resetCreditExpiry)
                    scheduler.settingsDidChange()
                } else {
                    scheduler.invalidateAccount()
                }
                center.release()
                drain(scheduler)
                precondition(center.pending.isEmpty, "An in-flight add must not resurrect invalid reminders")
            }
        }
        print("PASS: fresh credit validation, no future timers, partial responses, expiry, accounts, settings, retries and cancellation")
    }
}
