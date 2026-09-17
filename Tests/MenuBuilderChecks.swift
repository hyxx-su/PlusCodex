import AppKit

/// Standalone check of the intro menu construction: builds the menu twice from
/// StatusMenuBuilder (intro active vs expired) and asserts exact titles and
/// visibility. No app binary, no logs — deterministic, direct calls only.
@main
struct MenuBuilderChecks {
    static func main() {
        let target = MenuTarget()
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 336, height: 310))

        // During the 2 second launch intro: only the logo panel is visible.
        let intro = StatusMenuBuilder.make(intro: true, dashboardView: panel, delegate: nil,
                                           target: target, refreshAction: #selector(MenuTarget.refresh),
                                           quitAction: #selector(MenuTarget.quit))
        assertVisible(intro, duringIntro: true)

        // After the window passes: every row becomes visible again.
        StatusMenuBuilder.apply(intro: false, activity: intro.activity, separator: intro.separator,
                                refresh: intro.refresh, quit: intro.quit)
        assertVisible(intro, duringIntro: false)
        print("PASS: intro menu shows only the logo panel; dashboard restores all rows")
    }

    static func assertVisible(_ items: StatusMenuBuilder.Items, duringIntro: Bool) {
        let expected: [(String, Bool)] = [
            ("dashboard", false), ("activity", duringIntro), ("separator", duringIntro),
            ("refresh", duringIntro), ("quit", duringIntro)
        ]
        let actual: [(String, NSMenuItem)] = [
            ("dashboard", items.dashboard), ("activity", items.activity),
            ("separator", items.separator), ("refresh", items.refresh), ("quit", items.quit)
        ]
        for (index, pair) in zip(expected, actual).enumerated() {
            precondition(pair.0.0 == pair.1.0, "case \(index) mismatch: \(pair.0.0) vs \(pair.1.0)")
            let hidden = pair.1.1.isHidden
            precondition(hidden == pair.1.1.isHidden, "inconsistent hidden state")
            let shouldHide = pair.0.1
            precondition(hidden == shouldHide,
                         "\(pair.1.0): hidden=\(hidden), expected hidden=\(shouldHide)")
        }
        // Action rows keep their titles and shortcuts; view/separator rows may carry
        // a default "NSMenuItem" title that is never drawn, so only actions are checked.
        let titled = items.menu.items.filter { $0.title == "지금 새로고침" || $0.title == "시스템 종료" }
        precondition(titled.map { $0.title } == ["지금 새로고침", "시스템 종료"], "titles: \(items.menu.items.map { $0.title })")
        let shortcuts = items.menu.items.filter { $0.keyEquivalent == "r" || $0.keyEquivalent == "q" }
        precondition(shortcuts.count == 2, "shortcuts: \(items.menu.items.map { $0.keyEquivalent })")
    }
}

/// Selector target standing in for the app delegate.
final class MenuTarget: NSObject {
    @objc func refresh() {}
    @objc func quit() {}
}
