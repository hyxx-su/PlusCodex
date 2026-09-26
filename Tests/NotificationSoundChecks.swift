import AVFoundation
import Foundation

@main struct NotificationSoundChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "NotificationSoundChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = NotificationSettings(defaults: defaults, soundDirectory: directory.appendingPathComponent("sounds"))
        precondition(settings.soundVolume == 1, "Default notification gain must remain 100%")
        precondition(settings.soundDuration == 5, "Default playback duration must remain five seconds")
        precondition(settings.maximumSelectableSoundDuration == 15)
        let source = directory.appendingPathComponent("long.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        func makeSource() throws {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            for channel in 0..<2 {
                for frame in 0..<44100 {
                    buffer.floatChannelData![channel][frame] = channel == 0 ? 0.5 : -0.75
                }
            }
            for _ in 0..<35 { try file.write(from: buffer) }
        }
        func check(_ seconds: Double, _ amplitude: Float) throws {
            let file = try AVAudioFile(forReading: settings.previewURL!)
            precondition(abs(Double(file.length) / file.processingFormat.sampleRate - seconds) < 0.001)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
            try file.read(into: buffer, frameCount: 1024)
            precondition(abs(buffer.floatChannelData![0][100] - amplitude) < 0.001)
        }
        try makeSource()
        try settings.setCustomSound(from: source)
        precondition(settings.savedSounds.count == 1)
        let firstSavedID = settings.savedSounds[0].id
        precondition(settings.selectedSavedSoundID == firstSavedID)
        precondition(settings.maximumSelectableSoundDuration == 15)
        try check(5, 0.5)
        try settings.setCustomSoundDuration(1)
        try check(1, 0.5)
        try settings.setCustomSoundDuration(2)
        try check(2, 0.5)
        try settings.setCustomSoundDuration(10)
        try check(10, 0.5)
        try settings.setCustomSoundDuration(15)
        try check(15, 0.5)
        precondition(NotificationSettings(defaults: defaults,
            soundDirectory: directory.appendingPathComponent("sounds")).soundDuration == 15)
        try settings.setSoundVolume(0.4)
        try check(15, 0.2)
        try settings.setCustomSoundDuration(9)
        try check(9, 0.2)
        try settings.setSoundVolume(1)
        try check(9, 0.5)
        try settings.setSoundVolume(2)
        try check(9, 1)
        precondition(NotificationSettings(defaults: defaults,
            soundDirectory: directory.appendingPathComponent("sounds")).soundVolume == 2)
        let boosted = try AVAudioFile(forReading: settings.previewURL!)
        let boostedBuffer = AVAudioPCMBuffer(pcmFormat: boosted.processingFormat, frameCapacity: 1024)!
        try boosted.read(into: boostedBuffer, frameCount: 1024)
        precondition(abs(boostedBuffer.floatChannelData![1][100] + 1) < 0.001,
                     "Boosted negative samples must be clamped before 16-bit conversion")
        for invalid in [-0.1, 2.1, Double.nan] {
            do {
                try settings.setSoundVolume(invalid)
                preconditionFailure("Invalid volume accepted")
            } catch NotificationSettings.SoundError.invalidDuration { }
        }
        do {
            try settings.setCustomSoundDuration(9, volume: 3)
            preconditionFailure("Invalid gain accepted by duration update")
        } catch NotificationSettings.SoundError.invalidDuration { }
        try settings.setSoundVolume(0)
        try check(9, 0)
        for duration in [0.0, 16, Double.nan] {
            do {
                try settings.setCustomSoundDuration(duration)
                preconditionFailure("Invalid duration accepted")
            } catch NotificationSettings.SoundError.invalidDuration { }
        }
        precondition(NotificationSettings(defaults: defaults, soundDirectory: directory.appendingPathComponent("sounds")).soundDuration == 9)
        try settings.setCustomSound(from: source)
        precondition(settings.savedSounds.count == 2 && settings.soundDuration == 5,
                     "Adding a sound resets playback duration")
        try check(5, 0)
        try settings.selectSavedSound(id: firstSavedID)
        precondition(settings.selectedSavedSoundID == firstSavedID && settings.soundDuration == 5)
        try settings.setSoundVolume(1)
        try check(5, 0.5)
        for path in CommandLine.arguments.dropFirst() where
            NotificationSettings.supportedSoundExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
            && FileManager.default.fileExists(atPath: path) {
            try settings.setCustomSound(from: URL(fileURLWithPath: path))
            let file = try AVAudioFile(forReading: settings.previewURL!)
            precondition(abs(Double(file.length) / file.processingFormat.sampleRate - 5) < 0.001)
        }
        let shortSource = directory.appendingPathComponent("short.wav")
        do {
            let file = try AVAudioFile(forWriting: shortSource, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100
            for channel in 0..<2 {
                for frame in 0..<44100 {
                    buffer.floatChannelData![channel][frame] = channel == 0 ? 0.5 : -0.75
                }
            }
            for _ in 0..<9 { try file.write(from: buffer) }
            buffer.frameLength = 22050
            try file.write(from: buffer)
        }
        try settings.setCustomSound(from: shortSource)
        precondition(settings.maximumSelectableSoundDuration == 9,
                     "A 9.5-second source must not offer ten seconds")
        precondition(settings.soundDuration == 5, "Adding a short source retains the five-second default")
        try settings.setCustomSoundDuration(9)
        try check(9, 0.5)
        do {
            try settings.setCustomSoundDuration(10)
            preconditionFailure("Duration longer than the short source was accepted")
        } catch NotificationSettings.SoundError.invalidDuration { }
        settings.clearCustomSound()
        precondition(settings.previewURL == nil)
        for sound in settings.savedSounds { try settings.deleteSavedSound(id: sound.id) }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("sounds").path)
        precondition(remaining.isEmpty)
        print("PASS: saved sounds, duration 1/2/5/9/10/15 and short-source limit, volume 0/40/100/200%, clipping, persistence, cleanup")
    }
}
