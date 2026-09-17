import AppKit
import Sparkle

/// Sparkle owns download, signature verification, installation and restart.
/// Only the short checking phase is reflected in the menu's existing loader.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    var onCheckingChanged: ((Bool) -> Void)?
    private(set) var isChecking = false
    private var timeout: Timer?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    func start() {
        do {
            try controller.updater.start()
            // Run immediately on launch, independent of Sparkle's periodic schedule.
            controller.updater.checkForUpdatesInBackground()
        } catch {
            finishChecking()
            NSLog("PlusCodex updater configuration: %@", error.localizedDescription)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        timeout?.invalidate()
        isChecking = true
        onCheckingChanged?(true)
        // A slow/offline update server must never block access to usage or quit.
        let timer = Timer(timeInterval: 15, repeats: false) { [weak self] _ in self?.finishChecking() }
        timeout = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { finishChecking() }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { finishChecking() }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        finishChecking()
        NSLog("PlusCodex update check: %@", error.localizedDescription)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishChecking()
    }

    private func finishChecking() {
        timeout?.invalidate()
        timeout = nil
        guard isChecking else { return }
        isChecking = false
        onCheckingChanged?(false)
    }
}
