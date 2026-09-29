import Foundation
import AVFoundation

@main struct ReliabilityChecks {
    static func main() throws {
        let suite = "PlusCodex.reliability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var row = ThreadActivity(id: UUID().uuidString, title: "Private title", runtime: "idle", unread: true, updatedAt: 100)
        row.latestTurn = ThreadTurnState(key: "t", value: ["turnId": "t", "status": "completed"])
        var a = ThreadActivityReadReceipts(defaults: defaults, account: "a@example.com")
        a.acknowledge(row)
        var b = ThreadActivityReadReceipts(defaults: defaults, account: "b@example.com")
        precondition(b.visibleRows([row]).count == 1)
        var restored = ThreadActivityReadReceipts(defaults: defaults, account: " A@example.com ")
        precondition(restored.visibleRows([row]).isEmpty)
        row.runtime = "active"; row.latestTurn?.status = "inProgress"
        var tracker = CompletionTracker(defaults: defaults, account: "a")
        _ = tracker.update([row], connected: true)
        row.runtime = "idle"; row.latestTurn?.status = "completed"
        var other = CompletionTracker(defaults: defaults, account: "b")
        precondition(other.update([row], connected: true).isEmpty)
        var same = CompletionTracker(defaults: defaults, account: "a")
        precondition(same.update([row], connected: true).count == 1)
        let now = Date().timeIntervalSince1970
        let instant = Date()
        precondition(ThreadRecoveryPolicy.shouldRetain(waitingSince: instant.addingTimeInterval(-299), now: instant))
        precondition(!ThreadRecoveryPolicy.shouldRetain(waitingSince: instant.addingTimeInterval(-300), now: instant))
        precondition(ThreadRecoveryPolicy.shouldRetain(waitingSince: nil, now: instant), "Fresh snapshots restore visibility")
        let ledger = ResetCycleLedger(defaults: defaults)
        ledger.registered(account: "a", name: "primary", deadline: now - 10, duration: 18000)
        let reloaded = ResetCycleLedger(defaults: defaults)
        precondition(!reloaded.permits(account: "a", name: "primary", deadline: now + 60, now: now))
        precondition(reloaded.permits(account: "b", name: "primary", deadline: now + 60, now: now))
        precondition(reloaded.permits(account: "a", name: "primary", deadline: now + 18000, now: now))
        reloaded.registered(account: "cancel", name: "primary", deadline: now + 60, duration: 18000)
        reloaded.cancelFuture(account: "cancel", name: "primary", deadline: now + 60, now: now)
        precondition(ResetCycleLedger(defaults: defaults).permits(account: "cancel", name: "primary", deadline: now + 120, now: now + 61))
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let source = directory.appendingPathComponent("source.caf")
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            for channel in 0..<2 {
                for frame in 0..<44100 { buffer.floatChannelData![channel][frame] = 0.2 }
            }
            for _ in 0..<15 { try file.write(from: buffer) }
        }
        let sound = NotificationSettings(defaults: defaults, soundDirectory: directory.appendingPathComponent("sounds"))
        try sound.setCustomSound(from: source)
        var results: [Bool] = []
        let started = Date()
        sound.updateSoundAsync(duration: 15, volume: 0.5) { result in results.append(try! result.get()) }
        sound.updateSoundAsync(volume: 1.5) { result in results.append(try! result.get()) }
        let submissionMs = Date().timeIntervalSince(started) * 1000
        let deadline = Date().addingTimeInterval(15)
        while results.count < 2 && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        precondition(results == [false, true], "Only the latest conversion may commit")
        precondition(sound.soundDuration == 15 && sound.soundVolume == 1.5)
        let file = try AVAudioFile(forReading: sound.previewURL!)
        precondition(abs(Double(file.length) / file.processingFormat.sampleRate - 15) < 0.01)
        var cancelled = false
        sound.updateSoundAsync(volume: 0.5) { result in
            precondition(try! result.get() == false)
            cancelled = true
        }
        sound.clearCustomSound()
        let cancellationDeadline = Date().addingTimeInterval(15)
        while !cancelled && Date() < cancellationDeadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        precondition(cancelled && sound.previewURL == nil)
        print("PASS: account isolation, ledger relaunch, latest audio conversion; submission \(submissionMs)ms")
    }
}
