import AppKit
import Sparkle

@main struct UpdaterChecks {
    static func main() throws {
        _ = NSApplication.shared
        let wrapper = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = AppUpdater()
        var transitions: [Bool] = []
        updater.onCheckingChanged = { transitions.append($0) }
        try updater.updater(wrapper.updater, mayPerform: .updatesInBackground)
        precondition(updater.isChecking)
        updater.updaterDidNotFindUpdate(wrapper.updater)
        precondition(!updater.isChecking)
        try updater.updater(wrapper.updater, mayPerform: .updatesInBackground)
        updater.updater(wrapper.updater, didAbortWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        precondition(!updater.isChecking)
        precondition(transitions == [true, false, true, false])
        var discovered: [(String, String)] = []
        updater.onUpdateAvailable = { discovered.append(($0, $1)) }
        // Only version metadata is used; this fixture does not perform a network check.
        let update = SUAppcastItem(dictionary: ["enclosure": [
            "url": "https://github.com/hyxx-su/PlusCodex/releases/download/v1.0.3/PlusCodex-1.0.3.zip",
            "sparkle:version": "4", "sparkle:shortVersionString": "1.0.3"
        ]])!
        try updater.updater(wrapper.updater, mayPerform: .updatesInBackground)
        updater.updater(wrapper.updater, didFindValidUpdate: update)
        precondition(!updater.isChecking)
        precondition(discovered.count == 1 && discovered[0].0 == "1.0.3" && discovered[0].1 == "4")
        updater.updaterDidNotFindUpdate(wrapper.updater)
        precondition(discovered.count == 1, "No new-version notification when already current")
        try updater.updater(wrapper.updater, mayPerform: .updatesInBackground)
        let deadline = Date().addingTimeInterval(17)
        while updater.isChecking && Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        precondition(!updater.isChecking, "Offline check must not trap the user inside loading")
        print("PASS: update discovery callback, latest version, network error, event-tracking timeout")
    }
}
