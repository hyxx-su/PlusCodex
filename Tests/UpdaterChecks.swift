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
        try updater.updater(wrapper.updater, mayPerform: .updatesInBackground)
        let deadline = Date().addingTimeInterval(17)
        while updater.isChecking && Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        precondition(!updater.isChecking, "Offline check must not trap the user inside loading")
        print("PASS: latest version, network error, event-tracking timeout")
    }
}
