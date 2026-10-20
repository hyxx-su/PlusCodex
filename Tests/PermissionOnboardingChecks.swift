import AppKit
import UserNotifications

@main struct PermissionOnboardingChecks {
    static func main() {
        _ = NSApplication.shared
        let suite = "PlusCodex.PermissionOnboardingChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        typealias Guide = PermissionOnboarding
        func pending(revision: String = "1|1.2.0|22", notifications: Bool = true,
                     status: UNAuthorizationStatus = .notDetermined, gemini: Bool = false,
                     accessibility: Bool = false) -> [Guide.Permission] {
            Guide.pending(defaults: defaults, revision: revision, notificationsNeeded: notifications,
                          notificationStatus: status, geminiEnabled: gemini, accessibilityGranted: accessibility)
        }
        precondition(pending() == [.notifications], "Fresh Codex-only installs need no Accessibility access")
        precondition(pending(gemini: true) == [.notifications, .accessibility])
        precondition(pending(status: .authorized, gemini: true, accessibility: true).isEmpty)
        precondition(pending(status: .provisional, gemini: true, accessibility: true).isEmpty)
        precondition(pending(notifications: false).isEmpty, "Disabled features must not demand permissions")
        precondition(pending(status: .denied) == [.notifications], "Denied notifications need settings guidance")
        Guide.recordShown([.notifications], defaults: defaults, revision: "1|1.2.0|22")
        precondition(pending().isEmpty, "Skipping must not nag again on the same build")
        precondition(pending(gemini: true) == [.accessibility], "Enabling Gemini later still explains its permission")
        Guide.recordShown([.accessibility], defaults: defaults, revision: "1|1.2.0|22")
        precondition(pending(gemini: true).isEmpty)
        precondition(pending(revision: "1|1.2.1|23", gemini: true) == [.notifications, .accessibility],
                     "An update should explain permissions that are still missing")
        precondition(pending(revision: "1|1.2.1|23", status: .authorized, gemini: true,
                             accessibility: true).isEmpty, "Updates must not ask again for granted permissions")
        let guide = Guide(defaults: defaults, notificationsNeeded: { true }, geminiEnabled: { true })
        for permissions: [Guide.Permission] in [[.notifications], [.accessibility], [.notifications, .accessibility]] {
            guide.testHookBuildWindow(permissions)
            let content = guide.window!.contentView!
            let buttons = content.subviews.compactMap { $0 as? NSButton }
            precondition(buttons.count == permissions.count + 2, "Every guide needs skip and continue controls")
            precondition(content.subviews.allSatisfy { content.bounds.contains($0.frame) })
            for label in content.subviews.compactMap({ $0 as? NSTextField }) where !label.stringValue.isEmpty {
                let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 1000))
                precondition(needed.height <= label.frame.height + 1, "Clipped guide label: \(label.stringValue)")
            }
        }
        print("PASS: first install, update, already-granted permissions, disabled features, skip persistence, later Gemini enablement and guide layout")
    }
}
