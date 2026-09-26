import AppKit

@main struct IssueReportChecks {
    static func main() {
        _ = NSApplication.shared
        precondition(IssueReportButton.issueURL.absoluteString
            == "https://github.com/hyxx-su/PlusCodex/issues/new")

        let offline = QuotaMenuView(quota: nil, updatedAt: nil, failure: nil,
                                    offline: true, preservedHeight: 300)
        let offlineLoader = offline.subviews.compactMap { $0 as? QuotaLoadingView }.first!
        let offlineLink = offlineLoader.subviews.compactMap { $0 as? IssueReportButton }.first!
        precondition(offlineLoader.bounds.contains(offlineLink.frame))
        precondition(offlineLink.focusRingType != .none)
        var opened: URL?
        offlineLink.openURL = { opened = $0 }
        offlineLink.performClick(nil)
        precondition(opened == IssueReportButton.issueURL)

        let missing = QuotaMenuView(quota: nil, updatedAt: nil, failure: nil,
                                    missingExecutable: true, preservedHeight: 300)
        precondition(missing.subviews.compactMap { $0 as? QuotaLoadingView }.first!
            .subviews.contains { $0 is IssueReportButton })
        let checking = QuotaMenuView(quota: nil, updatedAt: nil, failure: nil,
                                     checkingForUpdates: true)
        precondition(checking.subviews.compactMap { $0 as? QuotaLoadingView }.first!
            .subviews.allSatisfy { !($0 is IssueReportButton) })

        let failed = QuotaMenuView(quota: nil, updatedAt: nil, failure: "조회 실패")
        precondition(failed.bounds.height == 280)
        let failedLoader = failed.subviews.compactMap { $0 as? QuotaLoadingView }.first!
        precondition(failedLoader.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
            == ["사용량 조회 실패", "조회 실패"])
        let failedLink = failedLoader.subviews.compactMap { $0 as? IssueReportButton }.first!
        precondition(abs((failedLink.frame.minY - failedLoader.bounds.midY)
            - (offlineLink.frame.minY - offlineLoader.bounds.midY)) < 1,
            "A short failure should keep the offline screen's link spacing")
        precondition(failed.subviews.allSatisfy { !($0 is IssueReportButton) })
        let recovered = QuotaMenuView(quota: nil, updatedAt: nil, failure: nil)
        precondition(recovered.bounds.height == 124 && recovered.subviews.isEmpty)

        let window = QuotaWindow(usedPercent: 40, windowDurationMins: 300, resetsAt: nil)
        let stale = QuotaMenuView(quota: Quota(primary: window, secondary: nil),
                                  updatedAt: nil, failure: "일시적 오류", provider: .claude)
        precondition(stale.bounds.height == 280)
        precondition(stale.subviews.compactMap { $0 as? QuotaLoadingView }.count == 1)
        let longMessage = String(repeating: "인증 정보와 연결 상태를 확인해 주세요. ", count: 3)
        let longFailure = QuotaMenuView(quota: nil, updatedAt: nil, failure: longMessage,
                                        provider: .grok)
        let longLoader = longFailure.subviews.compactMap { $0 as? QuotaLoadingView }.first!
        let detail = longLoader.subviews.compactMap { $0 as? NSTextField }[1]
        let report = longLoader.subviews.compactMap { $0 as? IssueReportButton }.first!
        precondition(detail.maximumNumberOfLines == 4)
        precondition(detail.frame.height > 26)
        precondition(detail.cell?.wraps == true && detail.cell?.usesSingleLineMode == false)
        precondition(detail.frame.maxY < report.frame.minY)
        precondition(longLoader.bounds.contains(detail.frame) && longLoader.bounds.contains(report.frame))

        let offlineFailure = QuotaMenuView(quota: nil, updatedAt: nil,
                                           failure: "서버 오류", offline: true, preservedHeight: 300)
        precondition(offlineFailure.subviews.compactMap { $0 as? QuotaLoadingView }.first!
            .subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "네트워크 연결 없음")
        let missingFailure = QuotaMenuView(quota: nil, updatedAt: nil,
                                           failure: "실행 파일 없음", missingExecutable: true,
                                           preservedHeight: 300)
        precondition(missingFailure.subviews.compactMap { $0 as? QuotaLoadingView }.first!
            .subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "Codex를 찾을 수 없음")

        let duringUpdate = QuotaMenuView(quota: nil, updatedAt: nil, failure: "서버 오류",
                                         checkingForUpdates: true)
        precondition(duringUpdate.subviews.compactMap { $0 as? QuotaLoadingView }.first!
            .subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "사용량 조회 실패")
        precondition(ClaudeCLIUsage.blockingMessage("Do you trust the files in this folder?")?
            .contains("Claude CLI") == true)

        let delegate = AppDelegate()
        delegate.testHookSetQuota(Quota(primary: window, secondary: nil))
        delegate.testHookRenderForMenu()
        let normalItems = delegate.testHookMenu!.items.filter { !$0.isHidden }.count
        delegate.testHookSetFailure("Codex 연결이 종료되었습니다.")
        precondition(delegate.testHookDashboardView!.subviews.contains { $0 is QuotaLoadingView })
        precondition(delegate.testHookMenu!.items.filter { !$0.isHidden }.count == 1)
        delegate.testHookSetFailure(nil)
        precondition(delegate.testHookDashboardView!.subviews.allSatisfy { !($0 is QuotaLoadingView) })
        precondition(delegate.testHookMenu!.items.filter { !$0.isHidden }.count == normalItems)
        delegate.testHookSetMissingExecutable(true)
        precondition(delegate.testHookMenu!.items.filter { !$0.isHidden }.count == 1)
        let missingCodex = delegate.testHookDashboardView!.subviews.compactMap { $0 as? QuotaLoadingView }.first!
        precondition(missingCodex.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
            == "Codex를 찾을 수 없음")
        precondition(missingCodex.subviews.contains { $0 is IssueReportButton })
        delegate.testHookSetMissingExecutable(false)
        precondition(delegate.testHookMenu!.items.filter { !$0.isHidden }.count == normalItems)

        let defaultsSuite = "PlusCodex.IssueReportChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let settings = ProviderSettings(defaults: defaults)
        for provider in [AIProvider.claude, .grok] {
            let controller = ProviderStatusController(provider: provider, settings: settings)
            controller.testHookSetFailure("서버 오류")
            precondition(controller.testHookMenu.items.filter { !$0.isHidden }.count == 1)
            precondition(controller.testHookMenu.items[0].view!.subviews.contains { $0 is QuotaLoadingView })
            controller.testHookSetFailure(nil)
            precondition(controller.testHookMenu.items.filter { !$0.isHidden }.count > 1)
            precondition(controller.testHookMenu.items[0].view!.subviews.allSatisfy { !($0 is QuotaLoadingView) })
        }
        let claudeController = ProviderStatusController(provider: .claude, settings: settings)
        claudeController.testHookSetFailure("Claude Desktop에서 사용량을 확인하거나 CLI에 로그인해 주세요.")
        precondition(claudeController.testHookMenu.items.filter { !$0.isHidden }.count == 1)
        let claudeFailure = claudeController.testHookMenu.items[0].view as! QuotaMenuView
        precondition(claudeFailure.subviews.compactMap { $0 as? QuotaLoadingView }.count == 1)
        precondition(claudeFailure.subviews.compactMap { $0 as? QuotaLoadingView }.first!
            .subviews.contains { $0 is IssueReportButton })

        print("PASS: all provider failures use full error screens, readable details, reporting, and recovery")
        if CommandLine.arguments.contains("--preview-offline") {
            preview(offline)
        } else if CommandLine.arguments.contains("--preview-failure") {
            preview(QuotaMenuView(quota: nil, updatedAt: nil,
                                  failure: "사용량을 조회하지 못했습니다."))
        } else if CommandLine.arguments.contains("--preview-long-error") {
            preview(QuotaMenuView(quota: nil, updatedAt: nil,
                failure: "Claude Desktop에서 사용량을 확인하거나 CLI에 로그인해 주세요.",
                provider: .claude))
        }
    }

    private static func preview(_ panel: QuotaMenuView) {
        let window = NSWindow(contentRect: panel.bounds, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "PlusCodex Issue Report Preview"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = panel
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardOutput.write(Data("PREVIEW_WINDOW_ID=\(window.windowNumber)\n".utf8))
        NSApp.run()
    }
}
