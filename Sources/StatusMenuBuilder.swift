import AppKit

/// Builds the status-bar menu. During the 2 second launch intro only the logo
/// panel is visible; chat rows and the native actions remain but are hidden.
enum StatusMenuBuilder {
    static func discordIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Discord", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 12, height: 12)
        image.isTemplate = false
        return image
    }

    static func configureDiscord(_ item: NSMenuItem) {
        item.title = L10n.text("디스코드")
        guard let image = discordIcon() else { return }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -1, width: 12, height: 12)
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: "  " + item.title,
                                        attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        item.image = nil
        item.attributedTitle = title
    }

    struct Items {
        let menu: NSMenu
        let dashboard: NSMenuItem
        let activity: NSMenuItem
        let separator: NSMenuItem
        let discord: NSMenuItem
        let quit: NSMenuItem
    }

    static func make(intro: Bool,
                     dashboardView: NSView,
                     delegate: NSMenuDelegate?,
                     target: AnyObject?,
                     discordAction: Selector,
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

        let discord = NSMenuItem(title: L10n.text("디스코드"), action: discordAction, keyEquivalent: "")
        discord.target = target
        configureDiscord(discord)
        menu.addItem(discord)

        let quit = NSMenuItem(title: L10n.text("PlusCodex 종료"), action: quitAction, keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)

        apply(intro: intro, activity: activity, separator: separator, discord: discord, quit: quit)
        return Items(menu: menu, dashboard: dashboard, activity: activity,
                     separator: separator, discord: discord, quit: quit)
    }

    /// The intro covers the whole panel: only the logo item stays visible.
    /// Every hidden row is set explicitly so ending the intro restores all rows.
    static func apply(intro: Bool, activity: NSMenuItem?, separator: NSMenuItem?,
                      discord: NSMenuItem?, quit: NSMenuItem?) {
        activity?.isHidden = intro
        discord?.isHidden = intro
        quit?.isHidden = intro
        separator?.isHidden = intro
    }
}
