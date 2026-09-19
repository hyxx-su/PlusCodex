import AppKit

@main
struct CompactSettingsChecks {
    static func main() {
        _ = NSApplication.shared
        let suite = "PlusCodex.CompactSettingsChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let login = LoginLaunchController(defaults: defaults, readStatus: { .enabled },
                                           register: {}, unregister: {})
        let controller = AISettingsWindow(settings: ProviderSettings(defaults: defaults),
                                          login: login, language: LanguageSettings(defaults: defaults))
        let root = controller.window!.contentView!
        assert(root.frame.size == NSSize(width: 680, height: 600))
        let pages = root.subviews.filter { $0.frame.width == 469 }
        assert(pages.count == 3)
        for page in pages {
            assert(page.frame.height == 600)
            for view in page.subviews {
                assert(page.bounds.contains(view.frame), "Out of bounds: \(view.frame)")
            }
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let switches = pages.flatMap(descendants).compactMap { $0 as? NSSwitch }
        let providers = switches.filter { AIProvider(rawValue: $0.identifier?.rawValue ?? "") != nil }
        assert(providers.count == 3 && providers.allSatisfy { $0.state == .on })
        assert(switches.allSatisfy { $0.frame.width <= 54 })
        assert(pages.filter { !$0.isHidden }.count == 1)
        print("PASS: compact window, page bounds, switches, initial navigation")
    }
}
