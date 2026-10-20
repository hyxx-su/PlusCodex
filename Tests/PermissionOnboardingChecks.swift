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
        var accessibilityRequests = 0
        var settingsOpened: [URL] = []
        let guide = Guide(defaults: defaults, notificationsNeeded: { true }, geminiEnabled: { true },
            requestAccessibilityPermission: { accessibilityRequests += 1 },
            openSystemSettings: { settingsOpened.append($0); return true })
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
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for language in AppLanguage.allCases {
            var localizedArguments = arguments
            localizedArguments["appLanguage"] = language.rawValue
            UserDefaults.standard.setVolatileDomain(localizedArguments, forName: UserDefaults.argumentDomain)
            guide.testHookBuildWindow([.accessibility])
            let button = guide.window!.contentView!.subviews.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "permission-guide-accessibility" }!
            precondition(button.title == L10n.text("손쉬운 사용 권한 요청"))
            precondition(button.cell!.cellSize.width <= button.frame.width, "Permission request label must fit")
            let previousRequests = accessibilityRequests
            // Dispatch the action directly: a live OS grant may disable the button on the test machine.
            precondition(NSApp.sendAction(button.action!, to: button.target, from: button))
            precondition(accessibilityRequests == previousRequests + 1 && settingsOpened.isEmpty,
                         "Request native consent once; never also open System Settings behind its warning")
        }
        print("PASS: Accessibility action requests native consent only, no duplicate Settings launch, localized button labels fit")
        print("PASS: first install, update, already-granted permissions, disabled features, skip persistence, later Gemini enablement and guide layout")
    }
}
