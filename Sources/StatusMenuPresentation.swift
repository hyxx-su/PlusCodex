import AppKit

extension NSStatusBarButton {
    func configureMenuTracking(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        // Open on press so AppKit owns the subsequent drag/release menu tracking.
        // A release must not dispatch another status-button action.
        sendAction(on: [.leftMouseDown, .rightMouseDown])
    }
}

extension NSMenu {
    /// A status button inherits the wallpaper-driven menu-bar appearance, which can
    /// be dark even in Light Mode. Present in screen coordinates so AppKit does
    /// not inherit the status-bar window's appearance. The icon remains unchanged.
    func popUpFollowingSystemAppearance(from button: NSView) {
        guard let window = button.window else { return }
        let origin = button.convert(NSPoint(x: 0, y: button.bounds.minY), to: nil)
        let screenPoint = window.convertPoint(toScreen: origin)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            popUp(positioning: nil, at: screenPoint, in: nil)
        }
    }
}
