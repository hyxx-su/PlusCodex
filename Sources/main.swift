import Foundation
import AppKit

LanguageSettings().configureFrameworkLanguage()

if CommandLine.arguments.contains("--probe") {
    do {
        let quota = try QuotaClient.fetch()
        for window in [quota.primary, quota.secondary].compactMap({ $0 }) {
            print("\(window.label): \(window.remaining)% remaining")
        }
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
