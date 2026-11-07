import AppKit

@main struct AppearanceSoundChecks {
    static func main() {
        _ = NSApplication.shared
        checkStatusBarRendering()
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
        let sustained = NotificationDelivery()
        for index in 0..<10_000 {
            let time = now.addingTimeInterval(Double(index) * 3)
            precondition(sustained.reserve(identifier: "notification-\(index)", start: time,
                                           duration: 2, now: time))
            precondition(sustained.testHookReservationMetadataCount == 1,
                         "Expired sound metadata must not accumulate without an OS snapshot refresh")
        }
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

private func checkStatusBarRendering() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let button = item.button!
    for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua,
                 .accessibilityHighContrastDarkAqua] {
        button.appearance = NSAppearance(named: name)
        for provider in AIProvider.allCases {
            let renderer = StatusBarImageRenderer(provider: provider)
            let title = NSAttributedString(string: " 36% | 4시간 58분", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor])
            renderer.configure(title: title, unavailable: false)
            button.setAccessibilityLabel(provider.name + " usage")
            renderer.display(on: button, frame: nil)
            let nativeWidth = button.bounds.width
            for frame in 0..<48 { renderer.display(on: button, frame: frame) }
            precondition(abs(button.bounds.width - nativeWidth) < 0.5,
                         "Preparing frames must preserve native menu-bar width")
            precondition(renderer.cachedFrameCount == 24 && renderer.bitmapBytes <= 8 * 1024 * 1024)
            let repeated = button.image
            renderer.display(on: button, frame: 47)
            precondition(button.image === repeated && button.image?.isTemplate == true)
            precondition(button.image!.representations.allSatisfy { $0 is NSBitmapImageRep })
            precondition(button.accessibilityLabel() == provider.name + " usage",
                         "Replacing the visual title must preserve spoken usage")
            renderer.configure(title: NSAttributedString(string: " 80%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]), unavailable: false)
            renderer.display(on: button, frame: 0)
            precondition(renderer.cachedFrameCount == 1 && button.image !== repeated,
                         "Usage changes must discard old frames")
            let oldAppearanceFrame = button.image
            // Some macOS versions normalize high-contrast status-bar overrides
            // to Aqua/Dark Aqua. Switch from the resolved appearance.
            let resolved = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            button.appearance = NSAppearance(named: resolved == .aqua ? .darkAqua : .aqua)
            renderer.display(on: button, frame: 0)
            precondition(button.image !== oldAppearanceFrame && renderer.cachedFrameCount == 1,
                         "Appearance changes must invalidate prepared frames")
            button.appearance = NSAppearance(named: name)
            renderer.display(on: button, frame: nil)
            precondition(renderer.cachedFrameCount == 0 && button.attributedTitle.string == " 80%")
            renderer.configure(title: NSAttributedString(string: ""), unavailable: true)
            renderer.display(on: button, frame: 0)
            precondition(renderer.cachedFrameCount == 0 && button.image?.isTemplate == false)
            renderer.configure(title: NSAttributedString(string: "😀 36%"), unavailable: false)
            renderer.display(on: button, frame: 0)
            precondition(renderer.cachedFrameCount == 0 && button.attributedTitle.string == "😀 36%")
            renderer.configure(title: NSAttributedString(string: String(repeating: "W", count: 80),
                attributes: [.font: NSFont.systemFont(ofSize: 48)]), unavailable: false)
            renderer.display(on: button, frame: 0)
            renderer.display(on: button, frame: 1)
            precondition(renderer.cachedFrameCount == 0 && button.attributedTitle.length == 80,
                         "Oversized frames must use the native display without truncation")
        }
    }
    print("PASS: bounded status frames, native widths, appearances, usage changes, accessibility and fallbacks")
}
