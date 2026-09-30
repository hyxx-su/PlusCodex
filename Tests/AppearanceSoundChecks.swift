import AppKit

@main struct AppearanceSoundChecks {
    static func main() {
        _ = NSApplication.shared
        var lightIcon: NSImage?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            lightIcon = CodexStatusIcon.image(size: 18, offline: false)
            precondition(lightIcon != nil)
            precondition(lightIcon === CodexStatusIcon.image(size: 18, offline: false))
            precondition(lightIcon !== CodexStatusIcon.image(size: 18, offline: true))
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            precondition(lightIcon !== CodexStatusIcon.image(size: 18, offline: false))
        }
        let parent = NSView()
        let view = NSView()
        view.wantsLayer = true
        parent.addSubview(view)
        parent.appearance = NSAppearance(named: .aqua)
        view.setAdaptiveBackgroundColor(.controlBackgroundColor)
        view.setAdaptiveBorderColor(.separatorColor)
        let light = view.layer!.backgroundColor!
        for appearance in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
            parent.appearance = NSAppearance(named: appearance)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                precondition(view.layer!.backgroundColor == NSColor.controlBackgroundColor.cgColor)
                precondition(view.layer!.borderColor == NSColor.separatorColor.cgColor)
            }
        }
        precondition(light != view.layer!.backgroundColor)

        // Create translucent colors in Dark Mode, then reuse them in Light Mode.
        // This is how an already-open settings window survives a system change.
        var translucent: NSColor = .clear
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            translucent = NSColor.labelColor.adaptiveAlpha(0.35)
        }
        view.setAdaptiveBackgroundColor(translucent)
        view.setAdaptiveBorderColor(NSColor.labelColor.adaptiveAlpha(0.16))
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            parent.appearance = NSAppearance(named: appearance)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                precondition(translucent.cgColor == NSColor.labelColor.withAlphaComponent(0.35).cgColor)
                precondition(view.layer!.backgroundColor == translucent.cgColor)
                precondition(view.layer!.borderColor == NSColor.labelColor.withAlphaComponent(0.16).cgColor)
            }
        }

        let delivery = NotificationDelivery()
        let now = Date()
        let testDelivery = NotificationDelivery()
        precondition(testDelivery.reserve(identifier: "sound-test-old", start: now, duration: 15, now: now))
        testDelivery.cancel("sound-test-old")
        precondition(testDelivery.reserve(identifier: "sound-test-retry", start: now, duration: 15, now: now),
                     "Cancelling a test must allow an immediate retry")
        // A late completion for the cancelled test must not release the retry.
        testDelivery.cancel("sound-test-old")
        precondition(!testDelivery.reserve(identifier: "other", start: now, duration: 2, now: now),
                     "Late cleanup must preserve the active test's overlap protection")
        let reconciled = NotificationDelivery()
        precondition(reconciled.reserve(identifier: "cancelled", start: now.addingTimeInterval(60), duration: 15))
        reconciled.remember([], defaultDuration: 15, snapshotStartedAt: Date().addingTimeInterval(1))
        precondition(reconciled.reserve(identifier: "replacement", start: now.addingTimeInterval(60), duration: 15))
        let beforeAddition = Date().addingTimeInterval(-1)
        reconciled.remember([], defaultDuration: 15, snapshotStartedAt: beforeAddition)
        precondition(!reconciled.reserve(identifier: "overlap", start: now.addingTimeInterval(60), duration: 15),
                     "An old OS snapshot must not discard a newer reservation")
        let suite = "PlusCodex.sound-reservation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persisted = NotificationDelivery(defaults: defaults)
        precondition(persisted.reserve(identifier: "playing", start: now, duration: 15, now: now))
        let restored = NotificationDelivery(defaults: defaults)
        precondition(!restored.reserve(identifier: "new", start: now, duration: 2, now: now))
        restored.cancel("playing")
        precondition(NotificationDelivery(defaults: defaults).reserve(identifier: "new", start: now, duration: 2, now: now))
        precondition(delivery.reserve(identifier: "first", start: now, duration: 15, now: now))
        precondition(!delivery.reserve(identifier: "overlap", start: now.addingTimeInterval(10), duration: 2, now: now))
        precondition(delivery.reserve(identifier: "later", start: now.addingTimeInterval(16), duration: 2, now: now))
        delivery.cancel("later")
        precondition(delivery.reserve(identifier: "replacement", start: now.addingTimeInterval(16), duration: 2, now: now))
        precondition(delivery.reserve(identifier: "expired", start: now.addingTimeInterval(30), duration: 2, now: now.addingTimeInterval(30)))
        print("AppearanceSoundChecks passed")
    }
}
