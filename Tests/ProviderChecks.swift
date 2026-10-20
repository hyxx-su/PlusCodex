import AppKit

@main struct ProviderChecks {
    static func main() throws {
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--claude-availability-probe") {
            print("Claude availability: \(ClaudeAvailability.current())")
            return
        }
        if CommandLine.arguments.contains("--grok-availability-probe") {
            print("Grok availability: \(GrokAvailability.current())")
            return
        }
        if CommandLine.arguments.contains("--gemini-availability-probe") {
            print("Gemini availability: \(GeminiAvailability.current())")
            if let snapshot = try? ExternalUsageClient.fetch(.gemini) {
                print("Gemini account: \(snapshot.account?.email ?? "nil") (\(snapshot.account?.planType ?? "nil"))")
                for window in snapshot.quota.windows {
                    print("Gemini window: \(window.label) remaining=\(window.remaining)%")
                }
            }
            return
        }
        precondition(ClaudeAvailability.classify(desktopInstalled: false, cliInstalled: false,
                                                 subscriptionType: "free") == .notInstalled)
        precondition(ClaudeAvailability.classify(desktopInstalled: true, cliInstalled: false,
                                                 subscriptionType: nil) == .usageUnavailable)
        precondition(ClaudeAvailability.classify(desktopInstalled: true, cliInstalled: false,
                                                 subscriptionType: nil, desktopHasUsage: true) == .availableOrUnknown)
        precondition(ClaudeAvailability.classify(desktopInstalled: false, cliInstalled: true,
                                                 subscriptionType: "pro") == .availableOrUnknown)
        precondition(ClaudeAvailability.classify(desktopInstalled: false, cliInstalled: true,
                                                 subscriptionType: " Free ") == .confirmedFree)
        precondition(ClaudeAvailability.isConfirmedFree("free_tier"))
        precondition(ClaudeAvailability.classify(desktopInstalled: true, cliInstalled: true,
                                                 subscriptionType: "free") == .confirmedFree)
        precondition(ClaudeAvailability.classify(desktopInstalled: true, cliInstalled: true,
                                                 subscriptionType: "free", desktopHasUsage: true) == .availableOrUnknown,
                     "A Desktop account with usable quota must not inherit the CLI account's plan")
        precondition(ClaudeAvailability.classify(desktopInstalled: true, cliInstalled: false,
                                                 subscriptionType: nil) != .confirmedFree,
                     "Missing usage data must not be mistaken for a confirmed Free plan")
        precondition(ClaudeAvailability.State.notInstalled.actionURL?.absoluteString == "https://code.claude.com/docs/en/setup")
        precondition(ClaudeAvailability.State.confirmedFree.actionURL?.absoluteString == "https://claude.ai/upgrade")
        precondition(ClaudeAvailability.State.usageUnavailable.actionURL?.absoluteString == "https://claude.ai/login")
        precondition(GrokAvailability.classify(cliInstalled: false, authenticated: true) == .notInstalled)
        precondition(GrokAvailability.classify(cliInstalled: true, authenticated: false) == .notAuthenticated)
        precondition(GrokAvailability.classify(cliInstalled: true, authenticated: true) == .readyToCheck)
        precondition(GrokAvailability.State.notInstalled.actionURL?.absoluteString == "https://x.ai/build")
        let suite = "PlusCodex.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ProviderSettings(defaults: defaults)
        let initialGeneration = settings.generation(.claude)
        precondition(settings.enabled(.codex) && !settings.enabled(.claude) && !settings.enabled(.grok))
        var changes = 0
        settings.onChange = { changes += 1 }
        settings.setEnabled(true, for: .claude)
        settings.setEnabled(true, for: .claude)
        precondition(changes == 1 && settings.enabled(.codex) && !settings.enabled(.grok))
        precondition(ProviderSettings(defaults: defaults).enabled(.claude))
        settings.setEnabled(false, for: .claude)
        precondition(changes == 2)
        precondition(settings.generation(.claude) == initialGeneration + 2,
                     "An off/on transition must invalidate an in-flight request even if enabled again")
        precondition(!ProviderSettings(defaults: defaults).enabled(.claude))
        settings.setEnabled(true, for: .grok)
        precondition(changes == 3 && ProviderSettings(defaults: defaults).enabled(.grok))
        settings.setEnabled(false, for: .grok)
        precondition(changes == 4)

        settings.setEnabled(true, for: .claude)
        let claudeController = ProviderStatusController(provider: .claude, settings: settings,
            claudeAvailability: { .availableOrUnknown })
        claudeController.presentation(offline: true, checking: false)
        claudeController.synchronize()
        precondition(claudeController.testHookHasStatusItem)
        settings.setEnabled(false, for: .claude)
        claudeController.synchronize()
        precondition(!claudeController.testHookHasStatusItem)

        settings.setEnabled(true, for: .grok)
        let missingGrok = ProviderStatusController(provider: .grok, settings: settings,
            grokAvailability: { .notInstalled })
        var grokGuidance: String?
        missingGrok.onState = { grokGuidance = $0 }
        missingGrok.synchronize()
        precondition(!settings.enabled(.grok) && !missingGrok.testHookHasStatusItem)
        precondition(grokGuidance == "미설치")
        settings.setEnabled(true, for: .grok)
        let readyGrok = ProviderStatusController(provider: .grok, settings: settings,
            grokAvailability: { .readyToCheck })
        readyGrok.presentation(offline: true, checking: false)
        readyGrok.synchronize()
        precondition(!readyGrok.testHookHasStatusItem && !settings.grokUsageVerified,
                     "Grok must remain hidden until a usage response is verified")
        settings.setGrokUsageVerified(true)
        readyGrok.synchronize()
        precondition(readyGrok.testHookHasStatusItem)
        settings.setEnabled(false, for: .grok)
        readyGrok.synchronize()
        precondition(!readyGrok.testHookHasStatusItem && !settings.grokUsageVerified)

        precondition(ExternalUsageClient.number(true) == nil)
        precondition(ExternalUsageClient.number("nan") == nil)
        precondition(ExternalUsageClient.number(Double.infinity) == nil)
        precondition(ExternalUsageClient.timestamp(1_800_000_000_000) == 1_800_000_000)
        precondition(ExternalUsageClient.timestamp("2026-09-18T00:00:00.000Z") != nil)
        let claude = try ExternalUsageClient.parseClaude([
            "five_hour": ["utilization": 25], "seven_day": ["utilization": 50],
            "seven_day_sonnet": ["utilization": 75], "seven_day_opus": NSNull()])
        precondition(claude.windows.map(\.remaining) == [75, 50, 25])
        precondition(claude.windows.map(\.label) == ["5시간", "주간", "Sonnet 주간"])
        settings.setEnabled(true, for: .claude)
        let emptyController = ProviderStatusController(provider: .claude, settings: settings,
            claudeAvailability: { .availableOrUnknown })
        var visibilityChanges = 0
        emptyController.onVisibilityChange = { visibilityChanges += 1 }
        emptyController.testHookPresentation(quota: Quota(primary: nil, secondary: nil),
                                              fetching: false, checking: false, offline: false)
        emptyController.synchronize()
        precondition(emptyController.testHookHasStatusItem && !emptyController.testHookStatusItemVisible,
                     "An empty Desktop usage cache must not leave a menu bar icon")
        let hiddenChangeCount = visibilityChanges
        emptyController.testHookPresentation(quota: claude, fetching: false,
                                              checking: false, offline: false)
        precondition(emptyController.testHookStatusItemVisible)
        precondition(visibilityChanges == hiddenChangeCount + 1)
        settings.setEnabled(false, for: .claude)
        emptyController.synchronize()
        precondition(visibilityChanges == hiddenChangeCount + 2)
        let scoped = try ExternalUsageClient.parseClaude(["limits": [
            ["kind": "weekly_scoped", "percent": 12, "scope": ["model": ["display_name": "Opus"]]]]])
        precondition(scoped.primary?.label == "Opus 주간")
        do { _ = try ExternalUsageClient.parseClaude([:]); preconditionFailure("Missing is not zero") }
        catch is UsageFailure {}
        precondition(ExternalUsageClient.parseGrok([:]) == nil)
        precondition(ExternalUsageClient.parseGrok(["creditUsagePercent": NSNull()]) == nil)
        let weekly = ExternalUsageClient.parseGrok(["config": ["creditUsagePercent": 30,
            "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY"]]])!
        precondition(weekly.primary?.label == "주간" && weekly.primary?.remaining == 70)
        let monthly = ExternalUsageClient.parseGrok(["used": ["val": "20"], "monthlyLimit": ["val": "100"]])!
        precondition(monthly.primary?.label == "1개월" && monthly.primary?.remaining == 80)
        precondition(GrokAvailability.hasDisplayableUsage(QuotaSnapshot(quota: weekly,
            account: CodexAccount(email: nil, planType: "SuperGrok"))))
        precondition(!GrokAvailability.hasDisplayableUsage(QuotaSnapshot(quota: weekly,
            account: CodexAccount(email: nil, planType: "free"))))
        precondition(!GrokAvailability.hasDisplayableUsage(QuotaSnapshot(quota: weekly,
            account: CodexAccount(email: nil, planType: "free_tier"))))
        precondition(!GrokAvailability.hasDisplayableUsage(QuotaSnapshot(
            quota: Quota(primary: nil, secondary: nil), account: nil)))
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            precondition(condition(), "Grok usage validation did not finish")
        }
        let validationDefaultsSuite = "PlusCodex.GrokValidation.\(UUID().uuidString)"
        let validationDefaults = UserDefaults(suiteName: validationDefaultsSuite)!
        defer { validationDefaults.removePersistentDomain(forName: validationDefaultsSuite) }
        let validationSettings = ProviderSettings(defaults: validationDefaults)
        let paidSnapshot = QuotaSnapshot(quota: weekly,
            account: CodexAccount(email: nil, planType: "SuperGrok"))
        validationSettings.setEnabled(true, for: .grok)
        let paidController = ProviderStatusController(provider: .grok, settings: validationSettings,
            grokAvailability: { .readyToCheck }, fetchUsage: { _ in paidSnapshot })
        paidController.synchronize()
        precondition(!paidController.testHookHasStatusItem)
        waitFor { validationSettings.grokUsageVerified }
        paidController.synchronize()
        precondition(paidController.testHookStatusItemVisible)
        validationSettings.setEnabled(false, for: .grok)
        paidController.synchronize()

        validationSettings.setEnabled(true, for: .grok)
        let freeController = ProviderStatusController(provider: .grok, settings: validationSettings,
            grokAvailability: { .readyToCheck }, fetchUsage: { _ in
                QuotaSnapshot(quota: weekly, account: CodexAccount(email: nil, planType: "free"))
            })
        freeController.synchronize()
        waitFor { !validationSettings.enabled(.grok) }
        precondition(!validationSettings.grokUsageVerified && !freeController.testHookHasStatusItem)

        validationSettings.setEnabled(true, for: .grok)
        let emptyUsageController = ProviderStatusController(provider: .grok, settings: validationSettings,
            grokAvailability: { .readyToCheck }, fetchUsage: { _ in
                throw UsageFailure.subscriptionUsageUnavailable
            })
        emptyUsageController.synchronize()
        waitFor { !validationSettings.enabled(.grok) }
        precondition(!emptyUsageController.testHookHasStatusItem)

        validationSettings.setEnabled(true, for: .grok)
        var throttledFetches = 0
        var throttleReported = false
        let throttledController = ProviderStatusController(provider: .grok, settings: validationSettings,
            grokAvailability: { .readyToCheck }, fetchUsage: { _ in
                throttledFetches += 1
                throw UsageFailure.throttled(Date().addingTimeInterval(60))
            })
        throttledController.onState = { throttleReported = $0 == UsageFailure.throttled(Date()).localizedDescription }
        throttledController.synchronize()
        waitFor { throttleReported }
        precondition(validationSettings.enabled(.grok), "A transient throttle must not disable the provider")
        validationSettings.setEnabled(false, for: .grok)
        validationSettings.setEnabled(true, for: .grok)
        throttledController.synchronize()
        precondition(throttledFetches == 1, "Retry-After must not be bypassed by toggling")
        validationSettings.setEnabled(false, for: .grok)

        validationSettings.setEnabled(true, for: .gemini)
        var geminiFetches = 0
        let toggleController = ProviderStatusController(provider: .gemini, settings: validationSettings,
            geminiAvailability: { .readyToCheck }, geminiAccessibilityGranted: { true }, fetchUsage: { _ in
                geminiFetches += 1
                return QuotaSnapshot(quota: weekly, account: CodexAccount(email: "user@example.com", planType: "Pro"))
            })
        toggleController.synchronize()
        waitFor { geminiFetches == 1 }
        validationSettings.setEnabled(false, for: .gemini)
        toggleController.synchronize()
        validationSettings.setEnabled(true, for: .gemini)
        toggleController.synchronize()
        waitFor { geminiFetches == 2 }
        precondition(toggleController.testHookActivityItem.isHidden,
                     "Gemini menu must hide the activity item when there are no active or unread tasks")
        let parsedTrajectories = ExternalUsageClient.parseAntigravityTrajectories([
            "trajectorySummaries": [
                "a2ae409d-dd14-4a11-a5bf-b4679c2cbe54": [
                    "summary": "Gemini task in progress",
                    "status": "CASCADE_RUN_STATUS_RUNNING",
                    "notFullyIdle": true,
                    "lastModifiedTime": "2026-10-19T01:20:00Z",
                    "lastUserInputTime": "2026-10-19T01:19:00Z",
                    "lastUserInputStepIndex": 12,
                    "trajectoryType": "CORTEX_TRAJECTORY_TYPE_CASCADE",
                    "annotations": [
                        "title": "진행 중인 Gemini 작업",
                        "lastUserViewTime": "2026-10-19T01:19:30Z",
                        "archived": false
                    ],
                    "trajectoryMetadata": [
                        "parentConversationId": "",
                        "isBattleModeFork": false
                    ]
                ],
                "b2ae409d-dd14-4a11-a5bf-b4679c2cbe54": [
                    "summary": "Subagent task",
                    "status": "CASCADE_RUN_STATUS_RUNNING",
                    "notFullyIdle": true,
                    "lastModifiedTime": "2026-10-19T01:20:00Z",
                    "trajectoryMetadata": [
                        "parentConversationId": "a2ae409d-dd14-4a11-a5bf-b4679c2cbe54"
                    ]
                ]
            ]
        ])
        precondition(parsedTrajectories.activities.count == 1,
                     "Subagent trajectories must be excluded from the top-level Gemini task list")
        let geminiTask = parsedTrajectories.activities[0]
        precondition(geminiTask.provider == .gemini)
        precondition(geminiTask.isRunning)
        precondition(geminiTask.title == "진행 중인 Gemini 작업")
        precondition(geminiTask.url?.absoluteString == "antigravity://conversations/a2ae409d-dd14-4a11-a5bf-b4679c2cbe54")
        precondition(AppDelegate.shouldSpinStatusIcon(
            activities: [geminiTask], connected: true, wakeThreadID: nil, unavailable: false, reduceMotion: false))
        toggleController.testHookSetActivities([geminiTask], connected: true)
        precondition(!toggleController.testHookActivityItem.isHidden
            && toggleController.testHookActivityItem.view is ThreadActivityView,
            "Active Gemini task must be shown in the Gemini menu")
        toggleController.testHookSetActivities([], connected: true)
        precondition(toggleController.testHookActivityItem.isHidden,
                     "Clearing Gemini tasks must hide the activity item again")
        validationSettings.setEnabled(false, for: .gemini)
        toggleController.synchronize()
        precondition(ExternalUsageClient.parseGrok(["used": ["val": 1], "monthlyLimit": ["val": 0]]) == nil)
        precondition(ExternalUsageClient.parseGrok(["used": ["val": 1e300], "monthlyLimit": ["val": 1e-300]])?.primary?.remaining == 0)
        precondition(ExternalUsageClient.grokSession(["https://unknown.example": ["key": "test"]]) == nil)
        precondition(ExternalUsageClient.grokSession(["https://auth.x.ai": ["key": "test", "expires_at": 1000]]) == nil)
        precondition(ExternalUsageClient.grokSession(["https://auth.x.ai": ["key": "test", "expires_at": 9_000_000_000]]) != nil)
        for provider in AIProvider.allCases {
            precondition(CodexStatusIcon.image(size: 18, offline: false, provider: provider) != nil)
            precondition(CodexStatusIcon.spinningImage(size: 18, frame: 3, provider: provider) != nil)
        }
        precondition(CodexStatusIcon.plusCodexImage(size: 18)?.isTemplate == true)
        precondition(CodexStatusIcon.plusCodexImage(size: 18)?.size == NSSize(width: 18, height: 18))
        precondition(AppDelegate.needsFallbackStatusItem(codexVisible: false, providerVisibility: []))
        precondition(AppDelegate.needsFallbackStatusItem(codexVisible: false, providerVisibility: [false, false]))
        precondition(!AppDelegate.needsFallbackStatusItem(codexVisible: true, providerVisibility: [false, false]))
        precondition(!AppDelegate.needsFallbackStatusItem(codexVisible: false, providerVisibility: [true, false]))
        let panel = QuotaMenuView(quota: claude, updatedAt: nil, failure: nil, provider: .claude)
        precondition(panel.accessibilityLabel()!.contains("Claude"))
        precondition(panel.accessibilityLabel()!.contains("Sonnet 주간"))
        precondition(panel.accessibilityLabel()!.contains("5시간"))
        let window = AISettingsWindow(settings: settings)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let checks = descendants(window.window!.contentView!).compactMap { $0 as? NSSwitch }
            .filter { AIProvider(rawValue: $0.identifier?.rawValue ?? "") != nil }
        precondition(checks.count == 4)
        precondition(checks.first { $0.identifier?.rawValue == "codex" }?.state == .on)
        precondition(checks.first { $0.identifier?.rawValue == "claude" }?.state == .off)
        precondition(checks.first { $0.identifier?.rawValue == "grok" }?.state == .off)
        precondition(checks.first { $0.identifier?.rawValue == "gemini" }?.state == .off)

        precondition(GeminiAvailability.classify(installed: false, authenticated: true) == .notInstalled)
        precondition(GeminiAvailability.classify(installed: true, authenticated: false) == .notAuthenticated)
        precondition(GeminiAvailability.classify(installed: true, authenticated: true) == .readyToCheck)
        precondition(GeminiAvailability.State.notInstalled.actionURL?.absoluteString == "https://antigravity.google")
        precondition(GeminiAvailability.State.notAuthenticated.guidance == "로그인 필요")

        let antigravitySummary = ExternalUsageClient.parseAntigravitySummary([
            "response": [
                "groups": [
                    [
                        "displayName": "Gemini Models",
                        "buckets": [
                            ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.8, "resetTime": "2026-10-25T18:28:50Z"],
                            ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.9, "resetTime": "2026-10-18T23:28:50Z"]
                        ]
                    ],
                    [
                        "displayName": "Gemini 4 Argon",
                        "buckets": [
                            ["bucketId": "gemini-argon-wtu-weekly", "window": "weekly", "remainingFraction": 0.75, "resetTime": "2026-10-25T16:56:50Z"]
                        ]
                    ]
                ]
            ]
        ], userStatus: [
            "userStatus": [
                "email": "user@example.com",
                "planStatus": ["planInfo": ["planName": "Pro"]]
            ]
        ])!
        precondition(antigravitySummary.account?.email == "user@example.com")
        precondition(antigravitySummary.account?.planType == "Pro")
        precondition(antigravitySummary.quota.primary?.label == "5시간" && antigravitySummary.quota.primary?.remaining == 90)
        precondition(antigravitySummary.quota.secondary?.label == "주간" && antigravitySummary.quota.secondary?.remaining == 80)
        precondition(antigravitySummary.quota.additional?.first?.label == "Argon 주간" && antigravitySummary.quota.additional?.first?.remaining == 75)

        let geminiCLISnapshot = ExternalUsageClient.parseGeminiCLIQuota([
            "buckets": [
                ["modelId": "gemini-2.5-pro", "remainingFraction": 0.65, "resetTime": "2026-10-19T18:00:00Z"],
                ["modelId": "gemini-2.5-flash", "remainingFraction": 0.92, "resetTime": "2026-10-19T18:00:00Z"],
                ["modelId": "gemini-2.5-flash-lite", "remainingFraction": 1.0, "resetTime": "2026-10-19T18:00:00Z"]
            ]
        ], account: CodexAccount(email: "cli@example.com", planType: "Paid"))!
        precondition(geminiCLISnapshot.account?.email == "cli@example.com")
        precondition(geminiCLISnapshot.quota.primary?.label == "Pro" && geminiCLISnapshot.quota.primary?.remaining == 65)
        precondition(geminiCLISnapshot.quota.secondary?.label == "Flash" && geminiCLISnapshot.quota.secondary?.remaining == 92)
        precondition(geminiCLISnapshot.quota.additional?.first?.label == "Flash Lite" && geminiCLISnapshot.quota.additional?.first?.remaining == 100)

        let gatingSuite = "PlusCodex.ClaudeAvailabilityChecks.\(UUID().uuidString)"
        let gatingDefaults = UserDefaults(suiteName: gatingSuite)!
        defer { gatingDefaults.removePersistentDomain(forName: gatingSuite) }
        let gatingSettings = ProviderSettings(defaults: gatingDefaults)
        var availability = ClaudeAvailability.State.notInstalled
        var openedURLs: [URL] = []
        let gatingWindow = AISettingsWindow(settings: gatingSettings,
            claudeAvailability: { availability }, openClaudeURL: { openedURLs.append($0) })
        precondition(descendants(gatingWindow.window!.contentView!).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "미설치" })
        let claudeToggle = descendants(gatingWindow.window!.contentView!).compactMap { $0 as? NSSwitch }
            .first { $0.identifier?.rawValue == "claude" }!
        claudeToggle.performClick(nil)
        precondition(!gatingSettings.enabled(.claude) && claudeToggle.state == .off)
        precondition(openedURLs.last == ClaudeAvailability.State.notInstalled.actionURL)
        availability = .confirmedFree
        gatingWindow.synchronize()
        precondition(descendants(gatingWindow.window!.contentView!).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "플랜 필요" })
        claudeToggle.performClick(nil)
        precondition(!gatingSettings.enabled(.claude) && claudeToggle.state == .off)
        precondition(openedURLs.last == ClaudeAvailability.State.confirmedFree.actionURL)
        availability = .usageUnavailable
        gatingWindow.synchronize()
        claudeToggle.performClick(nil)
        precondition(!gatingSettings.enabled(.claude) && claudeToggle.state == .off)
        availability = .availableOrUnknown
        gatingWindow.synchronize()
        claudeToggle.performClick(nil)
        precondition(gatingSettings.enabled(.claude) && claudeToggle.state == .on)
        availability = .notInstalled
        var guidance: String?
        let gatedController = ProviderStatusController(provider: .claude, settings: gatingSettings,
            claudeAvailability: { availability })
        gatedController.onState = { guidance = $0 }
        gatedController.synchronize()
        precondition(!gatingSettings.enabled(.claude) && !gatedController.testHookHasStatusItem)
        precondition(guidance == "미설치")
        gatingSettings.setEnabled(true, for: .claude)
        availability = .confirmedFree
        gatedController.synchronize()
        precondition(!gatingSettings.enabled(.claude) && guidance == "플랜 필요")
        precondition(ClaudeAvailability.State.usageUnavailable.guidance == "확인 불가")
        precondition(GrokAvailability.State.notAuthenticated.guidance == "로그인 필요")
        var grokAvailability = GrokAvailability.State.notInstalled
        var openedGrokURLs: [URL] = []
        let grokWindow = AISettingsWindow(settings: gatingSettings,
            claudeAvailability: { .availableOrUnknown },
            grokAvailability: { grokAvailability }, openGrokURL: { openedGrokURLs.append($0) },
            geminiAvailability: { .readyToCheck })
        let grokToggle = descendants(grokWindow.window!.contentView!).compactMap { $0 as? NSSwitch }
            .first { $0.identifier?.rawValue == "grok" }!
        grokToggle.performClick(nil)
        precondition(!gatingSettings.enabled(.grok) && grokToggle.state == .off)
        precondition(openedGrokURLs.last == GrokAvailability.State.notInstalled.actionURL)
        grokAvailability = .notAuthenticated
        grokWindow.synchronize()
        grokToggle.performClick(nil)
        precondition(!gatingSettings.enabled(.grok) && grokToggle.state == .off)
        precondition(openedGrokURLs.last == GrokAvailability.State.notAuthenticated.actionURL)
        grokAvailability = .readyToCheck
        grokWindow.synchronize()
        grokToggle.performClick(nil)
        precondition(gatingSettings.enabled(.grok) && grokToggle.state == .off)
        gatingSettings.setGrokUsageVerified(true)
        grokWindow.synchronize()
        precondition(grokToggle.state == .on)
        if let path = ProcessInfo.processInfo.environment["PLUSCODEX_PREVIEW"] {
            window.window!.appearance = NSAppearance(named: .aqua)
            let view = window.window!.contentView!
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            view.bounds.fill()
            let content = NSImage(size: view.bounds.size)
            content.addRepresentation(bitmap)
            content.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1)
            image.unlockFocus()
            let opaque = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try opaque.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        print("PASS: provider defaults, persistence, independent settings, usage parsing, missing/invalid data, expiry, logos, settings UI")
    }
}
