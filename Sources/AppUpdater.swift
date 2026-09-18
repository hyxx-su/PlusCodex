import AppKit
import Sparkle

/// Sparkle owns download, signature verification, installation and restart.
/// Only the short checking phase is reflected in the menu's existing loader.
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var onCheckingChanged: ((Bool) -> Void)?
    var onUpdateAvailable: ((String, String) -> Void)?
    var onWillPresentUpdate: (() -> Void)?
    private(set) var updateAwaitingChoice = false
    private(set) var isChecking = false
    private var timeout: Timer?
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    func start() {
        // Beta builds stay on the tester's version until a separate beta feed exists.
        guard Bundle.main.object(forInfoDictionaryKey: "PlusCodexBeta") as? Bool != true else { return }
        do {
            // SUAllowsAutomaticUpdates=false also overrides old persisted silent-install
            // preferences. Checks remain automatic; installation requires a choice.
            try controller.updater.start()
            started = true
            // Run immediately on launch, independent of Sparkle's periodic schedule.
            controller.updater.checkForUpdatesInBackground()
        } catch {
            finishChecking()
            NSLog("PlusCodex updater configuration: %@", error.localizedDescription)
        }
    }

    func checkOnMenuOpen() {
        if updateAwaitingChoice {
            presentUpdateInFocus()
            return
        }
        guard started, !controller.updater.sessionInProgress,
              controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // The standard dialog is retained, but explicitly focused for this dockless app.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updateAwaitingChoice = true
        if !handleShowingUpdate { presentUpdateInFocus() }
    }

    private func presentUpdateInFocus() {
        onWillPresentUpdate?()
        // Leave menu tracking and Sparkle's delegate callback before re-entering its UI.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.updateAwaitingChoice else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.controller.checkForUpdates(nil)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateAwaitingChoice = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateAwaitingChoice = false
        finishChecking()
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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        finishChecking()
        onUpdateAvailable?(item.displayVersionString, item.versionString)
    }
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
