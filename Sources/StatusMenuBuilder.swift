import AppKit

/// Builds the status-bar menu. During the 2 second launch intro only the logo
/// panel is visible; chat rows and the native actions remain but are hidden.
enum StatusMenuBuilder {
    struct Items {
        let menu: NSMenu
        let dashboard: NSMenuItem
        let activity: NSMenuItem
        let separator: NSMenuItem
        let refresh: NSMenuItem
        let quit: NSMenuItem
    }

    static func make(intro: Bool,
                     dashboardView: NSView,
                     delegate: NSMenuDelegate?,
                     target: AnyObject?,
                     refreshAction: Selector,
                     quitAction: Selector) -> Items {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = delegate

        let dashboard = NSMenuItem()
        dashboard.view = dashboardView
        menu.addItem(dashboard)

        let activity = NSMenuItem()
        menu.addItem(activity)

        let separator = NSMenuItem.separator()
        menu.addItem(separator)

        let refresh = NSMenuItem(title: "지금 새로고침", action: refreshAction, keyEquivalent: "r")
        refresh.target = target
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "시스템 종료", action: quitAction, keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)

        apply(intro: intro, activity: activity, separator: separator, refresh: refresh, quit: quit)
        return Items(menu: menu, dashboard: dashboard, activity: activity,
                     separator: separator, refresh: refresh, quit: quit)
    }

    /// The intro covers the whole panel: only the logo item stays visible.
    /// Every hidden row is set explicitly so ending the intro restores all rows.
    static func apply(intro: Bool, activity: NSMenuItem?, separator: NSMenuItem?,
                      refresh: NSMenuItem?, quit: NSMenuItem?) {
        activity?.isHidden = intro
        refresh?.isHidden = intro
        quit?.isHidden = intro
        separator?.isHidden = intro
    }
}
