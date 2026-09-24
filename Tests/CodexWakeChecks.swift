import AppKit

@main struct CodexWakeChecks {
    static func main() {
        _ = NSApplication.shared
        let suite = "PlusCodex.CodexWakeChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let wake = CodexWakeSettings(defaults: defaults)
        precondition(!wake.enabled)
        precondition(wake.modelID == "gpt-6-luna" && wake.effort == "low")
        precondition(wake.displayName == "GPT-6 Luna")
        precondition(wake.message == "Wake up")
        let legacySuite = "\(suite).legacy"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set("안녕", forKey: "codexWake.message")
        let legacyWake = CodexWakeSettings(defaults: legacyDefaults)
        precondition(legacyWake.message == "Wake up")
        precondition(legacyWake.setMessage("안녕") && legacyWake.message == "안녕")
        precondition(CodexWakeSettings(defaults: legacyDefaults).message == "안녕")
        precondition(wake.setMessage("  깨워줘  ") && wake.message == "깨워줘")
        precondition(!wake.setMessage(" \n ") && wake.message == "깨워줘")
        precondition(!wake.setMessage(String(repeating: "a", count: 501)) && wake.message == "깨워줘")

        let luna = CodexWakeModel(id: "gpt-6-luna", model: "gpt-6-luna",
                                  displayName: "GPT-6 Luna", defaultReasoningEffort: "high",
                                  supportedReasoningEfforts: [
                                    .init(reasoningEffort: "low"), .init(reasoningEffort: "high")
                                  ], hidden: false)
        precondition(luna.wakeEffort == "low", "Luna must keep the requested Light default")
        let sol = CodexWakeModel(id: "gpt-6-sol", model: "gpt-6-sol",
                                 displayName: "GPT-6 Sol", defaultReasoningEffort: "medium",
                                 supportedReasoningEfforts: [
                                    .init(reasoningEffort: "low"), .init(reasoningEffort: "medium")
                                 ], hidden: false)
        let mediumOnly = CodexWakeModel(id: "medium-only", model: "medium-only",
                                        displayName: "Medium Only", defaultReasoningEffort: "medium",
                                        supportedReasoningEfforts: [.init(reasoningEffort: "medium")],
                                        hidden: false)
        let hidden = CodexWakeModel(id: "hidden", model: "hidden",
                                    displayName: "Hidden", defaultReasoningEffort: "low",
                                    supportedReasoningEfforts: [.init(reasoningEffort: "low")],
                                    hidden: true)
        precondition(sol.wakeEffort == "low" && mediumOnly.wakeEffort == nil)
        let catalog = [sol, mediumOnly, luna, hidden]
        for plan in ["free", "go", "unknown"] {
            let visible = CodexWakeModel.availableForWake(catalog,
                account: CodexWakeAccount(type: "chatgpt", planType: plan))
            precondition(visible.map(\.id) == ["gpt-6-luna"])
        }
        let plusModels = CodexWakeModel.availableForWake(catalog,
            account: CodexWakeAccount(type: "chatgpt", planType: "plus"))
        precondition(plusModels.map(\.id) == ["gpt-6-sol", "gpt-6-luna"])
        let keyModels = CodexWakeModel.availableForWake(catalog,
            account: CodexWakeAccount(type: "apiKey", planType: nil))
        precondition(keyModels == plusModels)
        wake.select(sol)
        precondition(wake.modelID == "gpt-6-sol" && wake.effort == "low")
        defaults.set("medium", forKey: "codexWake.effort")
        precondition(wake.effort == "low", "A saved older effort must not enable Medium")
        wake.select(luna)
        precondition(wake.modelID == "gpt-6-luna" && wake.effort == "low")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveHourWindow = Quota(primary: QuotaWindow(usedPercent: 20,
                                                       windowDurationMins: 300,
                                                       resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970),
                                   secondary: nil)
        precondition(CodexWakeSchedule.initialDate(now: now, lastAttemptAt: nil,
                                                   quota: fiveHourWindow) == now.addingTimeInterval(3600))
        precondition(CodexWakeSchedule.initialDate(now: now, lastAttemptAt: nil, quota: nil) == now)
        precondition(CodexWakeSchedule.initialDate(now: now,
                                                   lastAttemptAt: now.addingTimeInterval(-1800),
                                                   quota: fiveHourWindow) == now.addingTimeInterval(16200))
        let distantReset = Quota(primary: QuotaWindow(usedPercent: 20,
            windowDurationMins: 300, resetsAt: now.addingTimeInterval(6 * 60 * 60).timeIntervalSince1970),
            secondary: nil)
        precondition(CodexWakeSchedule.resetDate(now: now, lastAttemptAt: nil, quota: distantReset)
            == now.addingTimeInterval(6 * 60 * 60),
            "A corrected five-hour deadline must not be discarded for being over five hours away")
        let due = now.addingTimeInterval(3600)
        let staleReset = due
        let advancedReset = due.addingTimeInterval(CodexWakeSettings.interval)
        let correctedReset = due.addingTimeInterval(30 * 60)
        let earlierReset = due.addingTimeInterval(-20 * 60)
        let largeCorrection = due.addingTimeInterval(3 * 60 * 60)
        precondition(CodexWakeSchedule.revisedReset(now: now, targetReset: staleReset,
            currentReset: correctedReset) == correctedReset)
        precondition(CodexWakeSchedule.revisedReset(now: now, targetReset: staleReset,
            currentReset: earlierReset) == earlierReset)
        precondition(CodexWakeSchedule.revisedReset(now: due, targetReset: staleReset,
            currentReset: correctedReset) == correctedReset,
            "A later same-cycle correction must not wake at the old deadline")
        precondition(CodexWakeSchedule.revisedReset(now: due, targetReset: staleReset,
            currentReset: largeCorrection) == largeCorrection,
            "A large correction smaller than a full cycle is not a reset")
        precondition(CodexWakeSchedule.revisedReset(now: due, targetReset: staleReset,
            currentReset: advancedReset) == nil,
            "A full-window advance after the deadline confirms the next cycle")
        precondition(!CodexWakeSchedule.shouldSubmit(now: due, due: due,
            targetReset: staleReset, currentReset: advancedReset, fetchedAt: now))
        precondition(!CodexWakeSchedule.shouldSubmit(now: due, due: due,
            targetReset: staleReset, currentReset: correctedReset, fetchedAt: due))
        precondition(!CodexWakeSchedule.shouldSubmit(now: due, due: due,
            targetReset: staleReset, currentReset: largeCorrection, fetchedAt: due))
        precondition(!CodexWakeSchedule.shouldSubmit(now: due.addingTimeInterval(30), due: due,
            targetReset: staleReset, currentReset: staleReset, fetchedAt: due.addingTimeInterval(30)))
        precondition(CodexWakeSchedule.shouldSubmit(now: due, due: due,
            targetReset: staleReset, currentReset: advancedReset, fetchedAt: due))
        precondition(CodexWakeSchedule.shouldSubmit(now: due.addingTimeInterval(120), due: due,
            targetReset: staleReset, currentReset: staleReset,
            fetchedAt: due.addingTimeInterval(120)))
        precondition(!CodexWakeSchedule.shouldSubmit(now: due.addingTimeInterval(120), due: due,
            targetReset: staleReset, currentReset: staleReset, fetchedAt: nil))
        precondition(CodexWakeSchedule.shouldSubmit(now: due, due: due,
            targetReset: nil, currentReset: nil, fetchedAt: due))
        wake.setEnabled(true)
        wake.scheduledResetAt = due
        wake.nextAttemptAt = due
        let scheduler = CodexWakeScheduler(settings: wake)
        let correctedQuota = Quota(primary: QuotaWindow(usedPercent: 20,
            windowDurationMins: 300, resetsAt: correctedReset.timeIntervalSince1970), secondary: nil)
        scheduler.tick(quota: correctedQuota, offline: false, quotaFetchedAt: due, now: due)
        precondition(wake.scheduledResetAt == correctedReset && wake.nextAttemptAt == correctedReset,
            "A fresh quota read must move the persisted wake deadline")
        let restartedWake = CodexWakeSettings(defaults: defaults)
        let restartedScheduler = CodexWakeScheduler(settings: restartedWake)
        let earlierQuota = Quota(primary: QuotaWindow(usedPercent: 20,
            windowDurationMins: 300, resetsAt: earlierReset.timeIntervalSince1970), secondary: nil)
        restartedScheduler.tick(quota: earlierQuota, offline: false,
            quotaFetchedAt: now.addingTimeInterval(60), now: now.addingTimeInterval(60))
        precondition(restartedWake.scheduledResetAt == earlierReset && restartedWake.nextAttemptAt == earlierReset,
            "Relaunch must not preserve an outdated wake deadline")
        wake.setEnabled(false)
        wake.setEnabled(true)
        wake.recordAttempt(at: now)
        let fallbackDue = now.addingTimeInterval(CodexWakeSettings.interval)
        let nextCycleQuota = Quota(primary: QuotaWindow(usedPercent: 0,
            windowDurationMins: 300,
            resetsAt: fallbackDue.addingTimeInterval(CodexWakeSettings.interval).timeIntervalSince1970),
            secondary: nil)
        // At the fallback deadline the server may already expose the next
        // window; this is a confirmed rollover, not a reason to wait 5h more.
        precondition(CodexWakeSchedule.revisedReset(now: fallbackDue, targetReset: wake.nextAttemptAt,
            currentReset: CodexWakeSchedule.resetDate(now: fallbackDue, lastAttemptAt: wake.lastAttemptAt,
                quota: nextCycleQuota)) == nil)
        precondition(CodexWakeSchedule.shouldSubmit(now: fallbackDue, due: fallbackDue,
            targetReset: wake.nextAttemptAt,
            currentReset: CodexWakeSchedule.resetDate(now: fallbackDue, lastAttemptAt: wake.lastAttemptAt,
                quota: nextCycleQuota), fetchedAt: fallbackDue))
        wake.setEnabled(false)
        wake.setEnabled(true)
        wake.scheduledResetAt = due
        wake.recordAttempt(at: now)
        precondition(wake.nextAttemptAt == now.addingTimeInterval(CodexWakeSettings.interval))
        precondition(wake.scheduledResetAt == nil)
        wake.setEnabled(false)
        wake.setEnabled(true)
        precondition(wake.nextAttemptAt == nil && wake.lastAttemptAt == now)
        precondition(CodexWakeSchedule.initialDate(now: now.addingTimeInterval(60),
                                                   lastAttemptAt: wake.lastAttemptAt,
                                                   quota: nil) == now.addingTimeInterval(CodexWakeSettings.interval))
        wake.setEnabled(false)

        var createdReplacement = false
        let reusedID = try! CodexWakeClient.prepareThread(previousThreadID: "saved-task",
            resume: { $0 }, start: { createdReplacement = true; return "replacement" })
        precondition(reusedID == "saved-task" && !createdReplacement)
        do {
            _ = try CodexWakeClient.prepareThread(previousThreadID: "busy-task",
                resume: { _ in throw CodexWakeError.failed("active writer") },
                start: { createdReplacement = true; return "replacement" })
            preconditionFailure("A busy saved task must not create another task")
        } catch {
            precondition(!createdReplacement)
        }
        let firstID = try! CodexWakeClient.prepareThread(previousThreadID: nil,
            resume: { _ in preconditionFailure("A missing ID cannot be resumed") },
            start: { "first-task" })
        precondition(firstID == "first-task")
        let turnParams = CodexWakeClient.turnStartParams(threadID: "saved-task",
                                                          modelName: "gpt-6-luna", effort: "low",
                                                          message: wake.message)
        precondition(turnParams["serviceTierForTurn"] as? String == "default",
                     "Wake turns must not inherit Fast mode")
        precondition(turnParams["effort"] as? String == "low")
        precondition(((turnParams["input"] as? [[String: String]])?.first)?["text"] == "깨워줘")

        let login = LoginLaunchController(defaults: defaults, readStatus: { .notRegistered },
                                          register: {}, unregister: {})
        let controller = AISettingsWindow(settings: ProviderSettings(defaults: defaults),
                                          notificationSettings: NotificationSettings(defaults: defaults),
                                          wakeSettings: wake, login: login,
                                          language: LanguageSettings(defaults: defaults))
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let views = descendants(controller.window!.contentView!)
        let wakeToggle = views.compactMap { $0 as? NSSwitch }
            .first { $0.identifier?.rawValue == "codexWakeEnabled" }!
        let modelPicker = views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "codexWakeModel" }!
        let messageField = views.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "codexWakeMessage" }!
        precondition(wakeToggle.state == .off)
        precondition(wakeToggle.superview === modelPicker.superview &&
                     modelPicker.superview === messageField.superview)
        let card = wakeToggle.superview!
        precondition(abs(card.frame.height - 234) < 1)
        precondition(abs(modelPicker.frame.maxX - (card.bounds.width - 16)) < 1)
        let titles = card.subviews.compactMap { $0 as? NSTextField }
        let title = titles.first { $0.stringValue == "깨우기 모델" }!
        let description = titles.first { $0.stringValue == "Codex를 깨울 때 사용할 모델을 선택합니다." }!
        precondition(abs(title.frame.minY - description.frame.minY - 18) < 1)
        precondition(titles.contains { $0.stringValue == "사용량이 초기화될 때마다 Codex를 자동으로 깨웁니다." })
        precondition(messageField.stringValue == "깨워줘")
        messageField.stringValue = "  반가워  "
        _ = messageField.sendAction(messageField.action, to: messageField.target)
        precondition(wake.message == "반가워" && messageField.stringValue == "반가워")
        wakeToggle.state = .on
        _ = wakeToggle.sendAction(wakeToggle.action, to: wakeToggle.target)
        precondition(wake.enabled)
        wakeToggle.state = .off
        _ = wakeToggle.sendAction(wakeToggle.action, to: wakeToggle.target)
        precondition(!wake.enabled)

        if ProcessInfo.processInfo.environment["PLUSCODEX_LIVE_MODEL_LIST_TEST"] == "1" {
            do {
                let models = try CodexWakeClient.availableModels()
                precondition(models.allSatisfy { $0.wakeEffort == "low" })
                print("PASS: account model list contains only Light options: \(models.map(\.id).joined(separator: ", "))")
            } catch {
                fatalError("Live Codex model list test failed: \(error)")
            }
        }
        if ProcessInfo.processInfo.environment["PLUSCODEX_LIVE_WAKE_TEST"] == "1" {
            do {
                let models = try CodexWakeClient.availableModels()
                precondition(models.contains { $0.id == "gpt-6-luna" && $0.wakeEffort == "low" })
                var preparedThreadID: String?
                var submitted = false
                try CodexWakeClient.sendHello(
                    modelID: "gpt-6-luna", effort: "low", message: wake.message,
                    previousThreadID: ProcessInfo.processInfo.environment["PLUSCODEX_WAKE_TEST_THREAD_ID"],
                    shouldProceed: { true },
                    onThreadPrepared: { preparedThreadID = $0 },
                    onTurnSubmission: { submitted = true })
                precondition(preparedThreadID != nil && submitted)
                print("PASS: live Codex wake turn completed in \(preparedThreadID!)")
            } catch {
                fatalError("Live Codex wake test failed: \(error)")
            }
        }

        print("PASS: wake reset confirmation, editable message, plan-filtered Light models, standard speed, single-chat reuse, General layout")
    }
}
