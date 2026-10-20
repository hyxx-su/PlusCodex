import AppKit
import CoreGraphics

enum StatusMenuPresentation {
    private static let buttons = NSHashTable<NSStatusBarButton>.weakObjects()
    private(set) static var reopenedWithRightClick = false

    static var isRightClick: Bool {
        reopenedWithRightClick || NSApp.currentEvent?.type == .rightMouseDown
    }

    static func register(_ button: NSStatusBarButton) {
        buttons.add(button)
    }

    static func unregister(_ item: NSStatusItem?) {
        item?.button?.target = nil
        item?.button?.action = nil
        if let button = item?.button { buttons.remove(button) }
    }

    static func targetStatusButton(at screenPoint: NSPoint, excluding current: NSView) -> NSStatusBarButton? {
        for candidate in buttons.allObjects {
            guard candidate !== current,
                  candidate.target != nil,
                  !candidate.isHidden,
                  let window = candidate.window else { continue }
            let buttonRect = window.convertToScreen(candidate.convert(candidate.bounds, to: nil))
            let hitRect = buttonRect.union(window.frame)
            if hitRect.contains(screenPoint) {
                return candidate
            }
        }
        return nil
    }

    static func scheduleActivation(_ button: NSStatusBarButton, rightClick: Bool) {
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            activateWhenMouseReleased(button, rightClick: rightClick)
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    static func activateWhenMouseReleased(_ button: NSStatusBarButton, rightClick: Bool, attemptsLeft: Int = 20) {
        if NSEvent.pressedMouseButtons != 0 && attemptsLeft > 0 {
            let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
                activateWhenMouseReleased(button, rightClick: rightClick, attemptsLeft: attemptsLeft - 1)
            }
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        guard let action = button.action, button.target != nil, !button.isHidden else { return }
        reopenedWithRightClick = rightClick
        defer { reopenedWithRightClick = false }
        _ = NSApp.sendAction(action, to: button.target, from: button)
    }
}

extension NSStatusBarButton {
    func configureMenuTracking(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        // Open on press so AppKit owns the subsequent drag/release menu tracking.
        // A release must not dispatch another status-button action.
        sendAction(on: [.leftMouseDown, .rightMouseDown])
        StatusMenuPresentation.register(self)
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
        let startedAt = ProcessInfo.processInfo.systemUptime
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            popUp(positioning: nil, at: screenPoint, in: nil)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let leftAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let rightAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown)
        let clickAge = min(leftAge, rightAge)
        if clickAge < elapsed && clickAge < 0.6,
           let nextButton = StatusMenuPresentation.targetStatusButton(at: NSEvent.mouseLocation, excluding: button) {
            let rightClick = rightAge < leftAge
            StatusMenuPresentation.scheduleActivation(nextButton, rightClick: rightClick)
        }
    }
}
