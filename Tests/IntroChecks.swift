import AppKit

/// Status screens cover every row while retaining the native menu's total height.
@main struct IntroChecks {
    static func main() {
        _ = NSApplication.shared
        for count in 0...2 {
            let delegate = AppDelegate()
            let window = QuotaWindow(usedPercent: 3, windowDurationMins: 300, resetsAt: nil)
            delegate.testHookSetQuota(Quota(primary: count > 0 ? window : nil, secondary: count > 1 ? window : nil))
            delegate.testHookRenderForMenu()
            delegate.testHookSetActivities([ThreadActivity(id: UUID().uuidString, title: "작업",
                runtime: "active", unread: false, updatedAt: 0)])
            let height = delegate.testHookDashboardView!.frame.height
            let menuHeight = delegate.testHookMenu!.size.height
            let visible = delegate.testHookMenu!.items.filter { !$0.isHidden }.count
            precondition(!delegate.testHookMenu!.items.contains { $0.title == "업데이트 확인…" },
                         "Automatic updates must not need a manual menu item")
            for (offline, checking) in [(false, true), (true, true), (true, false), (false, false)] {
                delegate.testHookSetPresentation(offline: offline, checking: checking)
                let panel = delegate.testHookDashboardView!
                let stateScreen = offline || checking
                precondition(abs(delegate.testHookMenu!.size.height - menuHeight) < 1,
                             "Full menu height changed")
                precondition(stateScreen ? panel.frame.height > height : panel.frame.height == height)
                precondition(delegate.testHookMenu!.items.filter { !$0.isHidden }.count == (stateScreen ? 1 : visible))
                precondition(delegate.testHookMenu!.items.filter { ["지금 새로고침", "시스템 종료"].contains($0.title) }.allSatisfy { $0.isHidden == stateScreen })
                let loader = panel.subviews.compactMap { $0 as? QuotaLoadingView }.first
                precondition((loader != nil) == (offline || checking))
                if let loader {
                    let labels = loader.subviews.compactMap { $0 as? NSTextField }
                    precondition(labels.first?.stringValue == (offline ? "네트워크 연결 없음" : "업데이트 확인 중"))
                    precondition(labels.allSatisfy { loader.bounds.contains($0.frame) })
                }
            }
        }
        precondition(CodexStatusIcon.image(size: 18, offline: true)?.isTemplate == false)
        precondition(CodexStatusIcon.image(size: 18, offline: false)?.isTemplate == true)
        precondition(CodexStatusIcon.image(size: 18, offline: true)?.size == NSSize(width: 18, height: 18))
        precondition(CodexStatusIcon.image(size: 18, offline: false)?.size == NSSize(width: 18, height: 18))
        print("PASS: full menu overlay, stable total height, hidden actions, recovery, equal icon sizes")
    }
}
