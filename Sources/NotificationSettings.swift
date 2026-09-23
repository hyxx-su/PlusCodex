import AVFoundation
import Foundation
import UserNotifications

enum NotificationKind: String, CaseIterable, Hashable {
    case completion
    case quota
    case reset
    case update
    case approval
    case answer
    case mcp
    case appApproval
    case failure

    var titleKey: String {
        switch self {
        case .completion: return "작업 완료"
        case .quota: return "사용량 부족"
        case .reset: return "사용량 초기화"
        case .update: return "업데이트"
        case .approval: return "승인 요청"
        case .answer: return "답변 요청"
        case .mcp: return "MCP 확인 요청"
        case .appApproval: return "앱 승인 요청"
        case .failure: return "작업 실패"
        }
    }

    var descriptionKey: String {
        switch self {
        case .completion: return "요청한 작업이 완료되면 알림을 받습니다."
        case .quota: return "사용량이 부족하거나 모두 소진되면 알림을 받습니다."
        case .reset: return "사용량이 초기화되면 알림을 받습니다."
        case .update: return "새로운 버전을 사용할 수 있을 때 알림을 받습니다."
        case .approval: return "작업을 계속하기 위해 승인이 필요할 때 알림을 받습니다."
        case .answer: return "Codex가 질문에 대한 답변을 기다릴 때 알림을 받습니다."
        case .mcp: return "MCP 서버에서 입력이나 확인이 필요할 때 알림을 받습니다."
        case .appApproval: return "연결된 앱의 작업 실행에 승인이 필요할 때 알림을 받습니다."
        case .failure: return "요청한 작업이 오류로 완료되지 못하면 알림을 받습니다."
        }
    }
}

struct SavedNotificationSound {
    let id: String
    let displayName: String
    let sourceName: String

    var displayTitle: String { Self.displayTitle(for: displayName) }

    static func displayTitle(for fileName: String) -> String {
        let title = (fileName as NSString).deletingPathExtension
        return title.isEmpty ? fileName : title
    }

    init(id: String = UUID().uuidString, displayName: String, sourceName: String) {
        self.id = id
        self.displayName = displayName
        self.sourceName = sourceName
    }

    init?(storedValue: [String: String]) {
        guard let id = storedValue["id"], UUID(uuidString: id) != nil,
              let displayName = storedValue["displayName"], !displayName.isEmpty,
              let sourceName = storedValue["sourceName"] else { return nil }
        self.init(id: id, displayName: displayName, sourceName: sourceName)
    }

    var storedValue: [String: String] {
        ["id": id, "displayName": displayName, "sourceName": sourceName]
    }
}

final class NotificationSettings {
    enum SoundError: Error {
        case unsupportedFormat
        case unreadable
        case invalidDuration
        case copyFailed
        case deleteFailed
    }

    static let minimumSoundDuration: TimeInterval = 1
    static let maximumSoundDuration: TimeInterval = 10
    static let defaultSoundDuration: TimeInterval = 5
    static let supportedSoundExtensions = ["mp3", "m4a", "aac", "aiff", "aif", "wav", "caf"]

    private let defaults: UserDefaults
    private let soundDirectoryOverride: URL?
    var onChange: (() -> Void)?

    private let customSoundNameKey = "notifications.sound.customName"
    private let customSoundSourceNameKey = "notifications.sound.sourceName"
    private let customSoundDisplayNameKey = "notifications.sound.displayName"
    private let customSoundSourceDurationKey = "notifications.sound.sourceDuration"
    private let soundDurationKey = "notifications.sound.duration"
    private let savedSoundsKey = "notifications.sound.savedSounds"
    private let selectedSavedSoundIDKey = "notifications.sound.selectedSavedID"
    private let managedSoundPrefix = "pluscodex-notification-"
    private let savedSoundPrefix = "pluscodex-notification-saved-"

    init(defaults: UserDefaults = .standard, soundDirectory: URL? = nil) {
        self.defaults = defaults
        soundDirectoryOverride = soundDirectory
        normalizePersistedSoundDuration()
        migrateLegacyCustomSound()
    }

    var savedSounds: [SavedNotificationSound] {
        let stored = defaults.array(forKey: savedSoundsKey) as? [[String: String]] ?? []
        return stored.compactMap(SavedNotificationSound.init(storedValue:)).filter {
            $0.sourceName.hasPrefix(savedSoundPrefix) && !$0.sourceName.contains("/")
        }
    }

    var selectedSavedSoundID: String? {
        guard customSoundName != nil,
              let id = defaults.string(forKey: selectedSavedSoundIDKey),
              savedSounds.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var soundVolume: Double {
        let value = (defaults.object(forKey: "notifications.sound.volume") as? NSNumber)?.doubleValue ?? 1
        return value.isFinite ? min(1, max(0, value)) : 1
    }

    var previewURL: URL? { customSoundName.flatMap { soundFileURL(named: $0) } }

    var maximumSelectableSoundDuration: Int {
        guard let playbackName = defaults.string(forKey: customSoundNameKey),
              customSoundName != nil else {
            return Int(Self.maximumSoundDuration)
        }

        let storedSourceDuration = (defaults.object(forKey: customSoundSourceDurationKey) as? NSNumber)?.doubleValue
        let sourceDuration = storedSourceDuration.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        } ?? measuredDuration(for: defaults.string(forKey: customSoundSourceNameKey) ?? playbackName)
            ?? measuredDuration(for: playbackName)
        guard let sourceDuration else { return Int(Self.minimumSoundDuration) }
        return Self.maximumSelectableSeconds(for: sourceDuration)
    }

    func setSoundVolume(_ volume: Double) throws {
        guard volume.isFinite, (0...1).contains(volume) else { throw SoundError.invalidDuration }
        try setCustomSoundDuration(soundDuration, volume: volume)
    }

    func isEnabled(_ kind: NotificationKind) -> Bool {
        defaults.object(forKey: key(for: kind)) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool, for kind: NotificationKind) {
        guard isEnabled(kind) != enabled else { return }
        defaults.set(enabled, forKey: key(for: kind))
        onChange?()
    }

    var anyEnabled: Bool {
        NotificationKind.allCases.contains { isEnabled($0) }
    }

    var customSoundName: String? {
        guard let name = defaults.string(forKey: customSoundNameKey),
              !name.isEmpty,
              soundFileExists(name) else { return nil }
        return name
    }

    var customSoundDisplayName: String? {
        guard customSoundName != nil else { return nil }
        return defaults.string(forKey: customSoundDisplayNameKey)
    }

    var soundDuration: TimeInterval {
        guard let stored = defaults.object(forKey: soundDurationKey) as? NSNumber else {
            return Self.defaultSoundDuration
        }
        guard stored.doubleValue.isFinite else { return Self.defaultSoundDuration }
        return min(max(stored.doubleValue, Self.minimumSoundDuration),
                   TimeInterval(maximumSelectableSoundDuration))
    }

    var sound: UNNotificationSound {
        guard let name = customSoundName else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }

    func setCustomSound(from sourceURL: URL) throws {
        let extensionName = sourceURL.pathExtension.lowercased()
        guard Self.supportedSoundExtensions.contains(extensionName) else {
            throw SoundError.unsupportedFormat
        }
        let savedName = "\(savedSoundPrefix)\(UUID().uuidString).\(extensionName)"
        do {
            try writeManagedData(Data(contentsOf: sourceURL), named: savedName)
            guard let savedURL = soundFileURL(named: savedName) else { throw SoundError.copyFailed }
            try activateCustomSound(from: savedURL, displayName: sourceURL.lastPathComponent)
        } catch {
            removeManagedSound(named: savedName)
            throw error
        }

        let saved = SavedNotificationSound(displayName: sourceURL.lastPathComponent,
                                           sourceName: savedName)
        saveSavedSounds(savedSounds + [saved])
        defaults.set(saved.id, forKey: selectedSavedSoundIDKey)
    }

    func selectSavedSound(id: String) throws {
        guard let saved = savedSounds.first(where: { $0.id == id }),
              let sourceURL = soundFileURL(named: saved.sourceName) else {
            throw SoundError.unreadable
        }
        guard selectedSavedSoundID != id else { return }
        try activateCustomSound(from: sourceURL, displayName: saved.displayName)
        defaults.set(id, forKey: selectedSavedSoundIDKey)
    }

    func deleteSavedSound(id: String) throws {
        guard let saved = savedSounds.first(where: { $0.id == id }) else {
            throw SoundError.unreadable
        }
        do {
            for directory in soundDirectories {
                let url = directory.appendingPathComponent(saved.sourceName)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            throw SoundError.deleteFailed
        }
        if selectedSavedSoundID == id { clearCustomSound() }
        saveSavedSounds(savedSounds.filter { $0.id != id })
    }

    private func activateCustomSound(from sourceURL: URL, displayName: String) throws {
        let extensionName = sourceURL.pathExtension.lowercased()
        guard Self.supportedSoundExtensions.contains(extensionName) else {
            throw SoundError.unsupportedFormat
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw SoundError.unreadable
        }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0, audioFile.length > 0 else {
            throw SoundError.unreadable
        }
        let sourceDuration = Double(audioFile.length) / sampleRate
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            throw SoundError.unreadable
        }
        let maximumDuration = Self.maximumSelectableSeconds(for: sourceDuration)
        let newSoundDuration = min(Self.defaultSoundDuration, TimeInterval(maximumDuration))

        let sourceName = "\(managedSoundPrefix)source-\(UUID().uuidString).\(extensionName)"
        let playbackName = "\(managedSoundPrefix)playback-\(UUID().uuidString).caf"
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw SoundError.unreadable
        }

        let temporaryPlaybackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(playbackName)
        defer { try? FileManager.default.removeItem(at: temporaryPlaybackURL) }

        do {
            try writeTrimmedSound(from: sourceURL,
                                  to: temporaryPlaybackURL,
                                  duration: newSoundDuration, volume: soundVolume)
            let playbackData = try Data(contentsOf: temporaryPlaybackURL)
            try writeManagedData(data, named: sourceName)
            try writeManagedData(playbackData, named: playbackName)
        } catch {
            removeManagedSound(named: sourceName)
            removeManagedSound(named: playbackName)
            throw SoundError.copyFailed
        }

        let previousNames = Set([defaults.string(forKey: customSoundNameKey),
                                 defaults.string(forKey: customSoundSourceNameKey)].compactMap { $0 })
        for previousName in previousNames {
            removeManagedSound(named: previousName)
        }
        defaults.set(sourceName, forKey: customSoundSourceNameKey)
        defaults.set(playbackName, forKey: customSoundNameKey)
        defaults.set(displayName, forKey: customSoundDisplayNameKey)
        defaults.set(sourceDuration, forKey: customSoundSourceDurationKey)
        defaults.set(newSoundDuration, forKey: soundDurationKey)
        onChange?()
    }

    func setCustomSoundDuration(_ duration: TimeInterval, volume: Double? = nil) throws {
        guard duration.isFinite,
              duration >= Self.minimumSoundDuration,
              duration <= TimeInterval(maximumSelectableSoundDuration) else {
            throw SoundError.invalidDuration
        }
        let normalizedDuration = duration.rounded()

        guard let playbackName = defaults.string(forKey: customSoundNameKey),
              customSoundName != nil else {
            defaults.set(normalizedDuration, forKey: soundDurationKey)
            if let volume { defaults.set(volume, forKey: "notifications.sound.volume") }
            onChange?()
            return
        }

        let sourceName = defaults.string(forKey: customSoundSourceNameKey)
            .flatMap { soundFileURL(named: $0) == nil ? nil : $0 } ?? playbackName
        guard let sourceURL = soundFileURL(named: sourceName) else {
            throw SoundError.unreadable
        }
        let extensionName = (sourceName as NSString).pathExtension.lowercased()
        guard !extensionName.isEmpty else { throw SoundError.unreadable }

        let newPlaybackName = "\(managedSoundPrefix)playback-\(UUID().uuidString).caf"
        let temporaryPlaybackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(newPlaybackName)
        defer { try? FileManager.default.removeItem(at: temporaryPlaybackURL) }

        do {
            try writeTrimmedSound(from: sourceURL,
                                  to: temporaryPlaybackURL,
                                  duration: normalizedDuration, volume: volume ?? soundVolume)
            let playbackData = try Data(contentsOf: temporaryPlaybackURL)
            try writeManagedData(playbackData, named: newPlaybackName)
        } catch {
            removeManagedSound(named: newPlaybackName)
            throw SoundError.copyFailed
        }

        if defaults.string(forKey: customSoundSourceNameKey) == nil {
            defaults.set(sourceName, forKey: customSoundSourceNameKey)
        }
        defaults.set(newPlaybackName, forKey: customSoundNameKey)
        defaults.set(normalizedDuration, forKey: soundDurationKey)
        if let volume { defaults.set(volume, forKey: "notifications.sound.volume") }
        if playbackName != sourceName {
            removeManagedSound(named: playbackName)
        }
        onChange?()
    }

    func clearCustomSound() {
        let names = Set([defaults.string(forKey: customSoundNameKey),
                         defaults.string(forKey: customSoundSourceNameKey)].compactMap { $0 })
        for name in names {
            removeManagedSound(named: name)
        }
        defaults.removeObject(forKey: customSoundNameKey)
        defaults.removeObject(forKey: customSoundSourceNameKey)
        defaults.removeObject(forKey: customSoundDisplayNameKey)
        defaults.removeObject(forKey: customSoundSourceDurationKey)
        defaults.removeObject(forKey: selectedSavedSoundIDKey)
        onChange?()
    }

    private func saveSavedSounds(_ sounds: [SavedNotificationSound]) {
        defaults.set(sounds.map(\.storedValue), forKey: savedSoundsKey)
    }

    private func migrateLegacyCustomSound() {
        guard customSoundName != nil, selectedSavedSoundID == nil else { return }
        guard let sourceName = defaults.string(forKey: customSoundSourceNameKey)
                ?? customSoundName,
              let sourceURL = soundFileURL(named: sourceName) else { return }
        let savedName = "\(savedSoundPrefix)\(UUID().uuidString).\(sourceURL.pathExtension.lowercased())"
        do {
            try writeManagedData(Data(contentsOf: sourceURL), named: savedName)
            let displayName = defaults.string(forKey: customSoundDisplayNameKey)
                ?? sourceURL.lastPathComponent
            let saved = SavedNotificationSound(displayName: displayName, sourceName: savedName)
            saveSavedSounds(savedSounds + [saved])
            defaults.set(saved.id, forKey: selectedSavedSoundIDKey)
        } catch {
            removeManagedSound(named: savedName)
            NSLog("PlusCodex sound library migration failed: %@", error.localizedDescription)
        }
    }

    private func normalizePersistedSoundDuration() {
        guard customSoundName != nil,
              let stored = defaults.object(forKey: soundDurationKey) as? NSNumber else { return }
        let storedDuration = stored.doubleValue.isFinite
            ? stored.doubleValue
            : Self.defaultSoundDuration
        let normalizedDuration = min(max(storedDuration, Self.minimumSoundDuration),
                                     TimeInterval(maximumSelectableSoundDuration))
        guard normalizedDuration != storedDuration else { return }
        try? setCustomSoundDuration(normalizedDuration)
    }

    private func measuredDuration(for name: String) -> TimeInterval? {
        guard let url = soundFileURL(named: name),
              let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, audioFile.length > 0 else { return nil }
        let duration = Double(audioFile.length) / sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    private static func maximumSelectableSeconds(for duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return Int(minimumSoundDuration) }
        let cappedDuration = min(duration, maximumSoundDuration)
        return max(Int(minimumSoundDuration), Int(cappedDuration.rounded(.down)))
    }

    private func writeManagedData(_ data: Data, named name: String) throws {
        for directory in soundDirectories {
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    private func writeTrimmedSound(from sourceURL: URL,
                                   to destinationURL: URL,
                                   duration: TimeInterval, volume: Double) throws {
        let input = try AVAudioFile(forReading: sourceURL)
        let sampleRate = input.processingFormat.sampleRate
        guard sampleRate > 0, input.length > 0 else {
            throw SoundError.unreadable
        }

        let requestedFrames = AVAudioFramePosition((duration * sampleRate).rounded(.down))
        let framesToWrite = min(input.length, requestedFrames)
        guard framesToWrite > 0 else { throw SoundError.unreadable }

        try? FileManager.default.removeItem(at: destinationURL)
        // PCM CAF keeps notification playback independent of the source codec.
        let output = try AVAudioFile(forWriting: destinationURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: input.processingFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        let bufferCapacity = AVAudioFrameCount(min(Int64(4096), Int64(framesToWrite)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                            frameCapacity: bufferCapacity) else {
            throw SoundError.copyFailed
        }

        var remainingFrames = framesToWrite
        while remainingFrames > 0 {
            let frameCount = AVAudioFrameCount(min(Int64(buffer.frameCapacity),
                                                   Int64(remainingFrames)))
            try input.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) {
                        channels[channel][frame] *= Float(volume)
                    }
                }
            }
            try output.write(from: buffer)
            remainingFrames -= AVAudioFramePosition(buffer.frameLength)
        }
        guard remainingFrames == 0 else { throw SoundError.copyFailed }
    }

    private var soundDirectories: [URL] {
        if let soundDirectoryOverride { return [soundDirectoryOverride] }
        var directories: [URL] = []
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        directories.append(library.appendingPathComponent("Sounds", isDirectory: true))

        // Keep a bundle-specific container copy as well. This is the location
        // UserNotifications searches for sandboxed applications, while the
        // user Library/Sounds copy covers the current unsigned distribution.
        if let bundleID = Bundle.main.bundleIdentifier {
            let container = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers", isDirectory: true)
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("Data/Library/Sounds", isDirectory: true)
            directories.append(container)
        }
        var unique: [URL] = []
        for directory in directories where !unique.contains(directory) {
            unique.append(directory)
        }
        return unique
    }

    private func soundFileExists(_ name: String) -> Bool {
        soundFileURL(named: name) != nil
    }

    private func soundFileURL(named name: String) -> URL? {
        for directory in soundDirectories {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func removeManagedSound(named name: String) {
        guard name.hasPrefix(managedSoundPrefix) else { return }
        for directory in soundDirectories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func key(for kind: NotificationKind) -> String {
        "notifications.\(kind.rawValue).enabled"
    }
}
