import AppKit

/// Standalone check of the intro menu construction: builds the menu twice from
/// StatusMenuBuilder (intro active vs expired) and asserts exact titles and
/// visibility. No app binary, no logs — deterministic, direct calls only.
@main
struct MenuBuilderChecks {
    static func main() {
        _ = NSApplication.shared
        let target = MenuTarget()
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 336, height: 310))

        // During the 2 second launch intro: only the logo panel is visible.
        let intro = StatusMenuBuilder.make(intro: true, dashboardView: panel, delegate: nil,
                                           target: target, quitAction: #selector(MenuTarget.quit))
        assertVisible(intro, duringIntro: true)

        // After the window passes: every row becomes visible again.
        StatusMenuBuilder.apply(intro: false, activity: intro.activity, separator: intro.separator,
                                quit: intro.quit)
        assertVisible(intro, duringIntro: false)
        assertContextMenus()
        print("PASS: intro menu shows only the logo panel; dashboard restores all rows")
        print("PASS: Codex/Claude/Grok context menus expose separate hide/quit actions in Korean and English")
    }

    static func assertContextMenus() {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let suite = "PlusCodex.tests.contextMenus.\(UUID().uuidString)"
        let providerDefaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            providerDefaults.removePersistentDomain(forName: suite)
        }
        let settings = ProviderSettings(defaults: providerDefaults)
        let delegate = AppDelegate()
        let providers = [AIProvider.claude, .grok].map {
            ProviderStatusController(provider: $0, settings: settings,
                                     claudeAvailability: { .availableOrUnknown },
                                     grokAvailability: { .readyToCheck })
        }
        let target = MenuTarget()
        for language in AppLanguage.allCases {
            var localizedArguments = arguments
            localizedArguments["appLanguage"] = language.rawValue
            defaults.setVolatileDomain(localizedArguments, forName: UserDefaults.argumentDomain)
            assertContextMenu(delegate.testHookContextMenu, disableTitle: L10n.text("Codex 끄기"),
                              target: delegate, disableAction: NSSelectorFromString("disableCodex"),
                              quitAction: NSSelectorFromString("quitApp"))
            for controller in providers {
                assertContextMenu(controller.testHookContextMenu,
                                  disableTitle: L10n.text("%@ 끄기", controller.provider.name),
                                  target: controller, disableAction: NSSelectorFromString("disable"),
                                  quitAction: NSSelectorFromString("quit"))
            }
            let context = StatusMenuBuilder.makeContextMenu(disableTitle: L10n.text("Codex 끄기"),
                target: target, disableAction: #selector(MenuTarget.disable), quitAction: #selector(MenuTarget.quit))
            assertContextMenu(context, disableTitle: L10n.text("Codex 끄기"), target: target,
                              disableAction: #selector(MenuTarget.disable), quitAction: #selector(MenuTarget.quit))
            let previousDisables = target.disables
            let previousQuits = target.quits
            precondition(NSApp.sendAction(context.items[0].action!, to: context.items[0].target,
                                          from: context.items[0]))
            precondition(target.disables == previousDisables + 1 && target.quits == previousQuits,
                         "Hiding a provider must not quit PlusCodex")
            precondition(NSApp.sendAction(context.items[2].action!, to: context.items[2].target,
                                          from: context.items[2]))
            precondition(target.disables == previousDisables + 1 && target.quits == previousQuits + 1,
                         "Quit PlusCodex must use its independent quit action")
        }
    }

    static func assertContextMenu(_ menu: NSMenu, disableTitle: String, target: NSObject,
                                  disableAction: Selector, quitAction: Selector) {
        precondition(menu.items.count == 3 && menu.items[1].isSeparatorItem,
                     "Separate provider hiding from quitting the whole app")
        let disable = menu.items[0], quit = menu.items[2]
        precondition(disable.title == disableTitle && disable.keyEquivalent.isEmpty)
        precondition(quit.title == (L10n.language == .korean ? "PlusCodex 종료" : "Quit PlusCodex"))
        precondition(quit.keyEquivalent == "q" && quit.keyEquivalentModifierMask == .command)
        precondition(disable.action == disableAction && quit.action == quitAction)
        precondition(disable.target === target && quit.target === target)
        precondition(target.responds(to: disableAction) && target.responds(to: quitAction))
    }

    static func assertVisible(_ items: StatusMenuBuilder.Items, duringIntro: Bool) {
        let expected: [(String, Bool)] = [
            ("dashboard", false), ("activity", duringIntro), ("separator", duringIntro),
            ("quit", duringIntro)
        ]
        let actual: [(String, NSMenuItem)] = [
            ("dashboard", items.dashboard), ("activity", items.activity),
            ("separator", items.separator), ("quit", items.quit)
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
        let titled = items.menu.items.filter { $0.action != nil }
        precondition(titled == [items.quit] && items.menu.items.count == 4,
                     "The builder must not create a Discord menu row")
        precondition(items.quit.title == "PlusCodex 종료" && items.quit.keyEquivalent == "q")
        let shortcuts = items.menu.items.filter { $0.keyEquivalent == "r" || $0.keyEquivalent == "q" }
        precondition(shortcuts.count == 1, "shortcuts: \(items.menu.items.map { $0.keyEquivalent })")
        precondition(items.quit.action == #selector(MenuTarget.quit))
        precondition(!items.menu.items.contains { $0.title == "지금 새로고침" || $0.keyEquivalent == "r" })
    }
}

/// Selector target standing in for the app delegate.
final class MenuTarget: NSObject {
    var disables = 0
    var quits = 0
    @objc func disable() { disables += 1 }
    @objc func quit() { quits += 1 }
}
