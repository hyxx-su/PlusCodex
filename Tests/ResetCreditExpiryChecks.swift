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
            }, readAuthorization: { $0(self.authorized) }, add: { self.add($0, completion: $1) },
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
            precondition(settings.isEnabled(.resetCreditExpiry), "Expiry reminders default to enabled")
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            scheduler.update(summary([credit()]), account: "Account-A@Example.com")
            drain(scheduler)
            precondition(center.additions == 1 && center.pending.count == 1)
            let request = center.pending[target.identifier]!
            precondition(request.content.sound != nil)
            precondition(request.content.userInfo["expiryFireAt"] as? Double == reminder.timeIntervalSince1970)
            precondition(request.content.userInfo["notificationKind"] as? String == "resetCreditExpiry")
            let saved = defaults.data(forKey: "resetCreditExpiryLedger.v1")
            for _ in 0..<25 { scheduler.update(summary([credit()]), account: "account-a@example.com") }
            drain(scheduler)
            precondition(center.additions == 1, "Polling must not replace an unchanged reservation")
            precondition(defaults.data(forKey: "resetCreditExpiryLedger.v1") == saved, "Polling must not rewrite receipts")
            scheduler.update(summary([credit(expiry: revised.expiresAt)]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 2 && center.pending.count == 1)
            precondition(center.pending[target.identifier]?.content.userInfo["expiryAt"] as? Double == revised.expiresAt)
            scheduler.update(summary([], count: 0), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.pending.isEmpty, "Using the last credit cancels its reminder")
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 3, "A cancelled future reservation may be booked again")
        }

        isolated { defaults, settings, center in
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            center.now = reminder.addingTimeInterval(5)
            center.pending.removeAll() // Simulate delivery followed by dismissing the banner.
            let relaunched = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            relaunched.update(summary([credit()]), account: "account-a@example.com")
            drain(relaunched)
            precondition(center.additions == 1, "Relaunch must not repeat a dismissed reminder")
            relaunched.update(summary([credit(expiry: revised.expiresAt)]), account: "account-a@example.com")
            drain(relaunched)
            precondition(center.additions == 1, "An expiry correction must not repeat an already due reminder")
            relaunched.update(summary([credit()]), account: "account-b@example.com")
            drain(relaunched)
            precondition(center.additions == 2 && center.pending.count == 1, "Receipts are account-scoped")
            precondition(center.pending[otherAccount.identifier]?.content.userInfo["expiryFireAt"] as? Double
                == center.now.timeIntervalSince1970 + 1, "Late discovery catches up once before expiry")
            center.now = expiry
            relaunched.update(summary([credit()]), account: "account-b@example.com")
            drain(relaunched)
            precondition(center.pending.isEmpty, "An expired credit must not notify")
        }

        isolated { defaults, settings, center in
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            center.now = reminder.addingTimeInterval(5)
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 1 && center.pending.count == 1,
                         "Sleep recovery preserves the already-due OS request instead of adding a second one")
            center.now = expiry
            scheduler.update(RateLimitResetCreditsSummary(availableCount: 1, credits: nil), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.pending.isEmpty, "Unknown detail rows must not keep expired reminders alive")
            center.now = expiry.addingTimeInterval(-0.5)
            let nearExpiry = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            nearExpiry.update(summary([credit("last-second")]), account: "account-a@example.com")
            drain(nearExpiry)
            precondition(center.additions == 1, "A late reminder must not be scheduled to arrive after expiry")
        }

        isolated { defaults, settings, center in
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            scheduler.update(summary([credit()]), account: nil)
            precondition(!scheduler.synchronizing && center.additions == 0, "Unknown identity must not receive another account's metadata")
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            scheduler.update(nil, account: "account-a@example.com")
            drain(scheduler)
            scheduler.update(RateLimitResetCreditsSummary(availableCount: 1, credits: nil), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.pending.count == 1 && center.additions == 1, "Missing details are not redemption evidence")
            let relaunched = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            relaunched.update(RateLimitResetCreditsSummary(availableCount: 1, credits: nil), account: "account-a@example.com")
            drain(relaunched)
            precondition(center.pending.count == 1, "Relaunch preserves a same-account OS reservation when details are unknown")
            relaunched.update(nil, account: "account-b@example.com")
            drain(relaunched)
            precondition(center.pending.isEmpty, "Account changes cancel old reminders even when new details are unknown")
            relaunched.update(summary([credit()]), account: "account-b@example.com")
            drain(relaunched)
            settings.setEnabled(false, for: .resetCreditExpiry)
            relaunched.settingsDidChange()
            drain(relaunched)
            precondition(center.pending.isEmpty)
            settings.setEnabled(true, for: .resetCreditExpiry)
            relaunched.settingsDidChange()
            drain(relaunched)
            precondition(center.pending.count == 1, "Re-enabling restores only the current account's future reminder")
            relaunched.invalidateAccount()
            drain(relaunched)
            precondition(center.pending.isEmpty)
        }

        isolated { defaults, settings, center in
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            scheduler.update(summary([credit(), credit("credit-2")]), account: "account-a@example.com")
            drain(scheduler)
            scheduler.update(summary([credit("credit-2")], count: 2), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.pending.count == 2, "Capped detail rows must not cancel omitted credits")
            scheduler.update(summary([credit(status: "redeemed"), credit("credit-2")], count: 1), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.pending.count == 1 && center.pending[target.identifier] == nil)
            scheduler.update(summary([credit("credit-2", expiry: nil)], count: 1), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.pending.isEmpty, "A credit whose expiry was removed must not keep an old deadline")
        }

        isolated { defaults, settings, center in
            let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            center.authorized = false
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 0 && defaults.data(forKey: "resetCreditExpiryLedger.v1") == nil)
            center.authorized = true
            center.failNext = true
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.pending.isEmpty && defaults.data(forKey: "resetCreditExpiryLedger.v1") == nil)
            scheduler.update(summary([credit()]), account: "account-a@example.com")
            drain(scheduler)
            precondition(center.additions == 2 && center.pending.count == 1, "Submission failure retries on the next successful fetch")
            settings.setEnabled(false, for: .resetCreditExpiry)
            let relaunched = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
            relaunched.start()
            drain(relaunched)
            precondition(center.pending.isEmpty, "Disabled reminders are cancelled at launch before fetching usage")
        }

        for change in 0..<3 {
            isolated { defaults, settings, center in
                let scheduler = center.scheduler(settings: settings, defaults: defaults, calendar: calendar)
                center.holdAdditions = true
                scheduler.update(summary([credit()]), account: "account-a@example.com")
                waitUntil { center.held.count == 1 }
                if change == 0 {
                    scheduler.update(summary([], count: 0), account: "account-a@example.com")
                } else if change == 1 {
                    scheduler.update(nil, account: "account-b@example.com")
                } else {
                    settings.setEnabled(false, for: .resetCreditExpiry)
                    scheduler.settingsDidChange()
                }
                center.release()
                drain(scheduler)
                precondition(center.pending.isEmpty, "An in-flight add must not resurrect cancelled, old-account or disabled reminders")
            }
        }
        print("PASS: reset-credit expiry dates, DST, decoding compatibility, receipts, redemption, accounts, settings, retries and in-flight cancellation")
    }
}
