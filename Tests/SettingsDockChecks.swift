import AppKit

@main struct SettingsDockChecks {
    static func main() {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        let settings = delegate.testHookSettingsWindow
        let window = settings.window!
        let applyVisibility = settings.onVisibilityChanged
        var closeTransitions = 0
        settings.onVisibilityChanged = { visible in
            if !visible {
                precondition(!window.isVisible,
                             "Hide settings before withdrawing foreground activation and the Dock entry")
                closeTransitions += 1
            }
            applyVisibility?(visible)
        }
        defer {
            settings.close()
            app.setActivationPolicy(previousPolicy)
        }
        precondition(!window.isVisible && app.activationPolicy() == .accessory,
                     "Creating settings for background updates must not show the Dock icon")
        delegate.testHookRenderForMenu()
        let menu = delegate.testHookMenu!

        func assertOpen() {
            precondition(window.isVisible && app.activationPolicy() == .regular,
                         "Visible settings must use the regular app policy")
        }
        func assertClosed() {
            precondition(!window.isVisible && app.activationPolicy() == .accessory,
                         "Closing settings must immediately restore the menu-bar-only policy: visible=\(window.isVisible), policy=\(app.activationPolicy().rawValue), closes=\(closeTransitions), minimized=\(window.isMiniaturized), hidden=\(app.isHidden)")
            precondition(delegate.testHookMenu === menu,
                         "Dock transitions must retain the existing menu-bar menu")
        }
        func completeWindowTransition(_ name: Notification.Name, action: () -> Void) {
            var completed = false
            let observer = NotificationCenter.default.addObserver(forName: name, object: window,
                                                                   queue: .main) { _ in completed = true }
            defer { NotificationCenter.default.removeObserver(observer) }
            action()
            let deadline = Date().addingTimeInterval(3)
            while !completed && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(completed, "AppKit must complete \(name.rawValue) before the next user action")
        }

        settings.present()
        assertOpen()
        settings.present()
        assertOpen()
        completeWindowTransition(NSWindow.didMiniaturizeNotification) { window.miniaturize(nil) }
        precondition(app.activationPolicy() == .regular,
                     "Minimizing settings must not remove the Dock entry needed to restore it")
        completeWindowTransition(NSWindow.didDeminiaturizeNotification) { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        let closeButton = window.contentView!.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == L10n.text("닫기") }!
        closeButton.performClick(nil)
        assertClosed()

        settings.present()
        assertOpen()
        window.performClose(nil)
        assertClosed()
        settings.present()
        assertOpen()
        settings.close()
        assertClosed()
        precondition(closeTransitions == 3,
                     "Custom, native and programmatic closes must each withdraw the Dock entry")

        settings.present()
        completeWindowTransition(NSWindow.didMiniaturizeNotification) { window.miniaturize(nil) }
        settings.close()
        assertClosed()
        for _ in 0..<5 {
            settings.present()
            assertOpen()
            settings.close()
            assertClosed()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            assertClosed()
        }
        precondition(closeTransitions == 9)
        print("PASS: hide-before-Dock ordering, repeated opening, minimize/close, custom/native/programmatic close, retained menu")
    }
}
