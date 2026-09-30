import Foundation
import AppKit
import Darwin
import SQLite3
import CryptoKit

enum ThreadRecordScope {
    static func key(_ account: String) -> String {
        SHA256.hash(data: Data(account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum ThreadRecoveryPolicy {
    static func shouldRefreshReadState(runtime: String?, unread: Bool?, awaitingSnapshot: Bool,
                                       recoveryDue: Bool) -> Bool {
        if awaitingSnapshot { return recoveryDue }
        return runtime == "idle" && unread == true
    }

    static func shouldRetain(waitingSince: Date?, now: Date) -> Bool {
        waitingSince.map { now.timeIntervalSince($0) < 300 } ?? true
    }
}

enum ThreadAttentionKind: Hashable {
    case approval
    case answer
    case mcp
    case appApproval
}

struct PendingThreadRequest: Hashable {
    let identity: String
    let kind: ThreadAttentionKind
}

struct ThreadTurnState: Equatable {
    let key: String
    let id: String
    var status: String
    let startedAtMs: Double

    init?(key: String, value: Any) {
        guard let value = value as? [String: Any],
              let id = value["turnId"] as? String,
              let status = value["status"] as? String else { return nil }
        self.key = key
        self.id = id
        self.status = status
        startedAtMs = (value["turnStartedAtMs"] as? NSNumber)?.doubleValue ?? 0
    }
}

struct ThreadActivity: Equatable {
    let id: String
    var title: String
    var runtime: String
    var activeFlags: [String] = []
    var pendingRequests: Set<PendingThreadRequest> = []
    var latestTurn: ThreadTurnState?
    var unread: Bool
    var updatedAt: Double
    var stateConfirmed = true
    var statusLabel: String {
        !stateConfirmed ? L10n.text("작업 상태 확인 불가")
            : isRunning ? L10n.text("작업 중") : L10n.text("완료 · 미확인")
    }

    private static func normalizedRuntime(_ runtime: String) -> String {
        runtime
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    static func isApprovalWaitingRuntime(_ runtime: String) -> Bool {
        let normalized = normalizedRuntime(runtime)
        return normalized == "waitingonapproval"
            || normalized == "waitingforapproval"
            || normalized == "waitingonpermission"
            || normalized == "waitingforpermission"
            || normalized == "awaitingapproval"
    }

    var isWaitingForApproval: Bool {
        Self.isApprovalWaitingRuntime(runtime)
            || activeFlags.contains(where: Self.isApprovalWaitingRuntime)
            || pendingRequests.contains(where: { $0.kind == .approval || $0.kind == .appApproval })
    }
    var isRunning: Bool { runtime == "active" || isWaitingForApproval || !pendingRequests.isEmpty }
    var isVisible: Bool { isRunning || (runtime == "idle" && unread) }
    var url: URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
}

struct ThreadTurnResult {
    enum Kind { case completed, failed }
    let activity: ThreadActivity
    let kind: Kind
}

/// A terminal turn status distinguishes failures from successful completion.
/// For older snapshots without turn history, keep the existing active-to-idle fallback.
struct CompletionTracker {
    private struct TurnRecord: Codable {
        let thread: String
        let turn: String
        let running: Bool
        let notified: Bool
        let savedAt: Date
    }
    private let defaults: UserDefaults?
    private var savedTurns: [String: TurnRecord] = [:]
    private let storageKey: String
    private var previous: [String: ThreadActivity] = [:]
    private var notifiedTurnIDs: [String: Set<String>] = [:]
    private let sessionStartedAtMs = Date().timeIntervalSince1970 * 1000

    init(defaults: UserDefaults? = nil, account: String = "test-local") {
        self.defaults = defaults
        storageKey = "threadCompletionTurns.v2." + ThreadRecordScope.key(account)
        if let data = defaults?.data(forKey: storageKey),
           let records = try? JSONDecoder().decode([String: TurnRecord].self, from: data) {
            savedTurns = records.filter { Date().timeIntervalSince($0.value.savedAt) < 30 * 86400 }
            for record in savedTurns.values where record.notified {
                notifiedTurnIDs[record.thread, default: []].insert(record.turn)
            }
        }
    }

    mutating func update(_ rows: [ThreadActivity], connected: Bool, now: Date = Date(), retainingIDs: Set<String> = []) -> [ThreadTurnResult] {
        guard connected else {
            // Only identified turns can be reconciled safely across a gap.
            previous = previous.filter { $0.value.latestTurn != nil }
            return []
        }
        var results: [ThreadTurnResult] = []
        for activity in rows {
            let prior = previous[activity.id]
            let becameIdle = prior?.runtime == "active" && activity.runtime == "idle"
            if let turn = activity.latestTurn {
                let observedRunningTurn = prior?.latestTurn?.id == turn.id
                    && prior?.latestTurn?.status == "inProgress"
                    || (activity.unread && savedTurns[activity.id + ":" + turn.id]?.running == true)
                let firstObservedRecentTerminalTurn = prior?.latestTurn?.id != turn.id
                    && turn.startedAtMs >= sessionStartedAtMs
                    && turn.startedAtMs <= now.timeIntervalSince1970 * 1000
                    && now.timeIntervalSince1970 * 1000 - turn.startedAtMs <= 120_000
                    && ["completed", "failed", "interrupted"].contains(turn.status)
                if (observedRunningTurn || becameIdle || firstObservedRecentTerminalTurn)
                    && !notifiedTurnIDs[activity.id, default: []].contains(turn.id) {
                    switch turn.status {
                    case "completed":
                        results.append(ThreadTurnResult(activity: activity, kind: .completed))
                        notifiedTurnIDs[activity.id, default: []].insert(turn.id)
                    case "failed":
                        results.append(ThreadTurnResult(activity: activity, kind: .failed))
                        notifiedTurnIDs[activity.id, default: []].insert(turn.id)
                    case "interrupted":
                        notifiedTurnIDs[activity.id, default: []].insert(turn.id)
                    default: break
                    }
                }
                let key = activity.id + ":" + turn.id
                let running = turn.status == "inProgress"
                let notified = notifiedTurnIDs[activity.id, default: []].contains(turn.id)
                if savedTurns[key]?.running != running || savedTurns[key]?.notified != notified {
                    savedTurns[key] = TurnRecord(thread: activity.id, turn: turn.id, running: running,
                                                 notified: notified, savedAt: now)
                }
            } else if becameIdle {
                results.append(ThreadTurnResult(activity: activity, kind: .completed))
            }
            previous[activity.id] = activity
        }
        previous = previous.filter { id, _ in retainingIDs.contains(id) || rows.contains(where: { $0.id == id }) }
        savedTurns = savedTurns.filter { now.timeIntervalSince($0.value.savedAt) < 30 * 86400 }
        if let defaults, let data = try? JSONEncoder().encode(savedTurns) {
            if defaults.data(forKey: storageKey) != data { defaults.set(data, forKey: storageKey) }
        }
        return results
    }
}

struct ThreadAttentionEvent {
    let activity: ThreadActivity
    let kind: ThreadAttentionKind
    var requestIdentity: String? = nil
}

/// Request IDs prevent repeat alerts, including after an IPC reconnect. Give an
/// approval flag a brief chance to acquire its request identity before falling
/// back to a generic approval notification.
struct AttentionTracker {
    private struct State {
        var waitingForApproval = false
        var fallbackDeadline: TimeInterval?
        var unidentifiedFallback = false
        var notifiedIDs: Set<String> = []
    }
    private var previous: [String: State] = [:]
    var hasPendingFallback: Bool { previous.values.contains { $0.fallbackDeadline != nil } }

    mutating func update(_ rows: [ThreadActivity], connected: Bool,
                         now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> [ThreadAttentionEvent] {
        guard connected else { return [] }
        var events: [ThreadAttentionEvent] = []
        for activity in rows {
            var state = previous[activity.id] ?? State()
            if !activity.pendingRequests.isEmpty {
                let newRequests = activity.pendingRequests
                    .filter { !state.notifiedIDs.contains($0.identity) }
                    .sorted { $0.identity < $1.identity }
                var matchedFallback = false
                for request in newRequests {
                    if state.unidentifiedFallback && !matchedFallback {
                        matchedFallback = true
                    } else {
                        events.append(ThreadAttentionEvent(activity: activity, kind: request.kind, requestIdentity: request.identity))
                    }
                    state.notifiedIDs.insert(request.identity)
                }
                state.unidentifiedFallback = false
                state.fallbackDeadline = nil
                state.waitingForApproval = activity.isWaitingForApproval
            } else if activity.isWaitingForApproval {
                if !state.waitingForApproval {
                    state.fallbackDeadline = now + 0.5
                }
                if let deadline = state.fallbackDeadline, now >= deadline {
                    events.append(ThreadAttentionEvent(activity: activity, kind: .approval))
                    state.fallbackDeadline = nil
                    state.unidentifiedFallback = true
                }
                state.waitingForApproval = true
            } else {
                state.waitingForApproval = false
                state.fallbackDeadline = nil
                state.unidentifiedFallback = false
            }
            previous[activity.id] = state
        }
        return events
    }
}

/// Keep completed rows visible even when Codex's unread flag disagrees with what
/// the user has actually opened. Opening a completed row acknowledges it.
struct ThreadActivityReadReceipts {
    private struct Receipt: Codable {
        let turn: String
        let updatedAt: Double
        let savedAt: Date
    }
    private let defaults: UserDefaults?
    private var receipts: [String: Receipt] = [:]
    private let storageKey: String
    private var opened: [String: Double] = [:]
    private var openedTurns: [String: String] = [:]
    private var pendingCompletions: [String: ThreadActivity] = [:]

    init(defaults: UserDefaults? = nil, account: String = "test-local") {
        self.defaults = defaults
        storageKey = "threadReadReceipts.v2." + ThreadRecordScope.key(account)
        if let data = defaults?.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: Receipt].self, from: data) {
            receipts = saved.filter { Date().timeIntervalSince($0.value.savedAt) < 30 * 86400 }
            opened = receipts.mapValues(\.updatedAt)
            openedTurns = receipts.mapValues(\.turn)
        }
    }

    private mutating func persist() {
        receipts = receipts.filter { Date().timeIntervalSince($0.value.savedAt) < 30 * 86400 }
        if let data = try? JSONEncoder().encode(receipts) { defaults?.set(data, forKey: storageKey) }
    }

    mutating func markCompleted(_ activity: ThreadActivity) {
        if let turn = activity.latestTurn?.id, openedTurns[activity.id] == turn { return }
        // A delayed completion must not undo an explicit acknowledgement.
        guard activity.updatedAt > (opened[activity.id] ?? -.infinity) else { return }
        var completed = activity
        completed.runtime = "idle"
        completed.activeFlags = []
        completed.pendingRequests = []
        pendingCompletions[activity.id] = completed
        opened.removeValue(forKey: activity.id)
    }

    mutating func acknowledge(_ activity: ThreadActivity) {
        guard activity.stateConfirmed, !activity.isRunning else { return }
        pendingCompletions.removeValue(forKey: activity.id)
        opened[activity.id] = activity.updatedAt
        openedTurns[activity.id] = activity.latestTurn?.id
        if let turn = activity.latestTurn?.id {
            receipts[activity.id] = Receipt(turn: turn, updatedAt: activity.updatedAt, savedAt: Date())
            persist()
        }
    }

    mutating func forget(_ id: String) {
        opened.removeValue(forKey: id)
        openedTurns.removeValue(forKey: id)
        pendingCompletions.removeValue(forKey: id)
        receipts.removeValue(forKey: id)
        persist()
    }

    /// Acknowledge a completed row when Codex reports that it was read outside
    /// the PlusCodex menu. Keep the timestamp guard so a stale unread snapshot
    /// cannot immediately restore the row after the read-state event.
    mutating func acknowledgeExternally(_ activity: ThreadActivity) {
        acknowledge(activity)
    }

    mutating func visibleRows(_ rows: [ThreadActivity]) -> [ThreadActivity] {
        for row in rows {
            if !row.stateConfirmed { pendingCompletions.removeValue(forKey: row.id) }
            let sameReadTurn = row.latestTurn.map { openedTurns[row.id] == $0.id } ?? false
            if !sameReadTurn && (row.isRunning || row.updatedAt > (opened[row.id] ?? .infinity)) {
                opened.removeValue(forKey: row.id)
                openedTurns.removeValue(forKey: row.id)
                if receipts.removeValue(forKey: row.id) != nil { persist() }
            }
            guard row.isRunning, let pending = pendingCompletions[row.id] else { continue }
            let pendingTurnID = pending.latestTurn?.id
            if pendingTurnID == nil || row.latestTurn?.id != pendingTurnID {
                pendingCompletions.removeValue(forKey: row.id)
            }
        }

        var merged = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for (id, activity) in pendingCompletions where merged[id] == nil {
            merged[id] = activity
        }
        return merged.values
            .filter { $0.isVisible || pendingCompletions[$0.id] != nil }
            .filter { opened[$0.id] == nil || $0.isRunning }
            .sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
    }
}

/// Read-only adapter for the installed desktop app's versioned local IPC protocol.
/// No tokens, message bodies, or read-state changes are persisted by this app.
final class ThreadActivityMonitor {
    // Long-running threads can carry large tool outputs in their first snapshot.
    // Keep a hard limit, but do not discard ordinary large conversations before
    // their small runtime-status fields can be read.
    private static let maximumBufferedFrameSize = 128 * 1024 * 1024
    private static let maximumDiscardedFrameSize = 256 * 1024 * 1024
    private let queue = DispatchQueue(label: "local.codexquota.activity", qos: .utility)
    private let onUpdate: ([ThreadActivity], Bool) -> Void
    private var socketFD: Int32 = -1
    private var clientID = ""
    private var pending = Data()
    private var snapshotRequests: [String: Date] = [:]
    private var candidateDatabase: OpaquePointer?
    private var candidateDatabaseIdentity: String?
    private var discardedFrameBytesRemaining = 0
    private var followed = Set<String>()
    private var activities: [String: ThreadActivity] = [:]
    private var owners: [String: String] = [:]
    private var revisions: [String: Int] = [:]
    private var lastPublished: [ThreadActivity] = []
    private var lastConnected = false
    private var completionTracker = CompletionTracker()
    private let accountLock = NSLock()
    private var requestedAccount: String?
    private var activeAccount: String?
    private var awaitingSince: [String: Date] = [:]
    func selectAccount(_ account: String?) {
        accountLock.lock()
        requestedAccount = account
        accountLock.unlock()
    }
    private func accountIsCurrent(_ account: String?) -> Bool {
        accountLock.lock()
        defer { accountLock.unlock() }
        return requestedAccount == account
    }

    private func synchronizeAccount() {
        accountLock.lock()
        let account = requestedAccount
        accountLock.unlock()
        guard account != activeAccount else { return }
        activeAccount = account
        completionTracker = account.map { CompletionTracker(defaults: .standard, account: $0) } ?? CompletionTracker()
        attentionTracker = AttentionTracker()
        awaitingSnapshots.formUnion(activities.keys)
        followed.removeAll()
        pendingReadActivities.removeAll()
        snapshotRequests.removeAll()
    }
    private var attentionTracker = AttentionTracker()
    private var pendingReadActivities: [String: ThreadActivity] = [:]
    private var awaitingSnapshots = Set<String>()
    private var lastReadRefresh = Date.distantPast
    var onArchive: ((String) -> Void)?
    var onCompletion: ((ThreadActivity) -> Void)?
    var onFailure: ((ThreadActivity) -> Void)?
    var onAttention: ((ThreadAttentionEvent) -> Void)?
    var onRead: ((ThreadActivity) -> Void)?
    var onCompatibilityChanged: ((Bool) -> Void)?

    init(onUpdate: @escaping ([ThreadActivity], Bool) -> Void) { self.onUpdate = onUpdate }

    /// Retain only request identities and kinds; request bodies stay in Codex.
    static func pendingRequests(in requests: [[String: Any]]) -> Set<PendingThreadRequest> {
        Set(requests.compactMap { request in
            guard let method = request["method"] as? String,
                  request["completed"] as? Bool != true,
                  let id = request["id"] else { return nil }
            let kind: ThreadAttentionKind
            switch method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                 "item/permissions/requestApproval": kind = .approval
            case "mcpServer/elicitation/request": kind = .mcp
            case "tool/requestUserInput", "item/tool/requestUserInput":
                kind = isAppApproval(request) ? .appApproval : .answer
            default: return nil
            }
            return PendingThreadRequest(identity: "\(method):\(id)", kind: kind)
        })
    }

    private static func isAppApproval(_ request: [String: Any]) -> Bool {
        // Connector approval and ordinary questions share requestUserInput.
        // Prefer app metadata, then recognize the approval-specific choices.
        let params = request["params"] as? [String: Any] ?? [:]
        if ["appContext", "connectorId", "pluginId", "mcpToolCall", "appName"].contains(where: {
            request[$0] != nil || params[$0] != nil
        }) { return true }
        let questions = params["questions"] as? [[String: Any]]
            ?? request["questions"] as? [[String: Any]] ?? []
        let labels = Set(questions.flatMap { $0["options"] as? [[String: Any]] ?? [] }
            .compactMap { $0["label"] as? String }
            .map { $0.replacingOccurrences(of: " ", with: "").lowercased() })
        let accepts: Set<String> = ["accept", "allow", "allowonce", "approve", "한번만허용", "허용", "승인"]
        let declines: Set<String> = ["decline", "deny", "reject", "거부"]
        return !labels.isDisjoint(with: accepts) && !labels.isDisjoint(with: declines)
    }

    static func latestTurn(in state: [String: Any]) -> ThreadTurnState? {
        guard let history = state["turnHistory"] as? [String: Any],
              let payload = history["history"] as? [String: Any],
              let entities = payload["entitiesByKey"] as? [String: Any] else { return nil }
        return latestTurn(inEntities: entities)
    }

    private static func latestTurn(inEntities entities: [String: Any]) -> ThreadTurnState? {
        entities.compactMap { ThreadTurnState(key: $0.key, value: $0.value) }
            .max { lhs, rhs in
                lhs.startedAtMs == rhs.startedAtMs
                    ? lhs.key < rhs.key : lhs.startedAtMs < rhs.startedAtMs
            }
    }

    static func applyTurnPatch(_ patch: [String: Any], to activity: inout ThreadActivity) {
        guard let path = patch["path"] as? [Any],
              path.first as? String == "turnHistory" else { return }
        let value = patch["value"]
        if path.count == 1 {
            activity.latestTurn = value.flatMap { latestTurn(in: ["turnHistory": $0]) }
        } else if path.count == 3,
                  path[1] as? String == "history", path[2] as? String == "entitiesByKey",
                  let entities = value as? [String: Any] {
            activity.latestTurn = latestTurn(inEntities: entities)
        } else if path.count >= 4,
                  path[1] as? String == "history", path[2] as? String == "entitiesByKey",
                  let key = path[3] as? String {
            if path.count == 4, let value, let turn = ThreadTurnState(key: key, value: value),
               turn.startedAtMs >= (activity.latestTurn?.startedAtMs ?? 0) {
                activity.latestTurn = turn
            } else if path.count == 5, activity.latestTurn?.key == key,
                      path[4] as? String == "status", let status = value as? String {
                activity.latestTurn?.status = status
            }
        }
    }

    static func readStateChange(from message: [String: Any]) -> (id: String, unread: Bool)? {
        guard message["type"] as? String == "broadcast",
              message["method"] as? String == "thread-read-state-changed",
              message["version"] as? Int == 3,
              let params = message["params"] as? [String: Any],
              params["hostId"] as? String == "local",
              let id = params["conversationId"] as? String,
              let unread = params["hasUnreadTurn"] as? Bool else { return nil }
        return (id, unread)
    }

    static func refollowIDs(for message: [String: Any], followed: Set<String>, clientID: String) -> [String] {
        guard message["type"] as? String == "broadcast",
              message["version"] as? Int == 1 else { return [] }
        switch message["method"] as? String {
        case "ipc-connection-reset":
            return followed.sorted()
        case "thread-stream-following-status-requested":
            guard let params = message["params"] as? [String: Any],
                  params["hostId"] as? String == "local",
                  let id = params["conversationId"] as? String,
                  followed.contains(id),
                  let requester = message["sourceClientId"] as? String,
                  requester != clientID else { return [] }
            return [id]
        default:
            return []
        }
    }

    func start() { queue.async { self.run() } }

    private func run() {
        while true {
            do {
                try connect()
                try send(["type": "request", "requestId": UUID().uuidString,
                          "method": "initialize", "version": 0,
                          "params": ["clientType": "codex-quota"]])
                var refreshAt = Date.distantPast
                let initializationDeadline = Date().addingTimeInterval(10)
                var bytes = [UInt8](repeating: 0, count: 65536)
                while true {
                    try autoreleasepool {
                    synchronizeAccount()
                    if clientID.isEmpty && Date() >= initializationDeadline { throw ActivityError.connection }
                    if !clientID.isEmpty && Date() >= refreshAt {
                        try refreshCandidates()
                        publish(connected: true)
                        refreshAt = Date().addingTimeInterval(5)
                    }
                    var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
                    let result = poll(&descriptor, 1, 1000)
                    if result < 0 { throw ActivityError.connection }
                    if result == 0 {
                        if attentionTracker.hasPendingFallback { publish(connected: true) }
                        return
                    }
                    let count = Darwin.read(socketFD, &bytes, bytes.count)
                    guard count > 0 else { throw ActivityError.connection }
                    pending.append(contentsOf: bytes.prefix(count))
                    while true {
                        if discardedFrameBytesRemaining > 0 {
                            let discarded = min(discardedFrameBytesRemaining, pending.count)
                            pending.removeFirst(discarded)
                            discardedFrameBytesRemaining -= discarded
                            if discardedFrameBytesRemaining > 0 { break }
                            continue
                        }
                        guard pending.count >= 4 else { break }
                        let length = pending.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                        guard length > 0 else { throw ActivityError.protocolMismatch }
                        if length > Self.maximumBufferedFrameSize {
                            guard length <= Self.maximumDiscardedFrameSize else {
                                throw ActivityError.protocolMismatch
                            }
                            pending.removeFirst(4)
                            discardedFrameBytesRemaining = length
                            NSLog("PlusCodex activity monitor skipped oversized IPC frame (%lld bytes)", Int64(length))
                            continue
                        }
                        guard pending.count >= length + 4 else { break }
                        try autoreleasepool {
                            let frame = Data(pending.dropFirst(4).prefix(length))
                            pending.removeFirst(length + 4)
                            if pending.isEmpty { pending = Data() }
                            try handle(ActivityIPCDecoder.decode(frame))
                        }
                    }
                    }
                }
            } catch {
                if let candidateDatabase { sqlite3_close(candidateDatabase) }
                candidateDatabase = nil
                candidateDatabaseIdentity = nil
                if socketFD >= 0 { Darwin.close(socketFD) }
                socketFD = -1
                clientID = ""
                pending.removeAll()
                discardedFrameBytesRemaining = 0
                followed.removeAll()
                awaitingSnapshots = Set(activities.keys)
                owners.removeAll()
                revisions.removeAll()
                pendingReadActivities.removeAll()
                snapshotRequests.removeAll()
                publish(connected: false)
                if case ActivityError.protocolMismatch = error {
                    RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { self.onCompatibilityChanged?(true) }
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                    NSLog("PlusCodex activity monitor: unsupported IPC protocol or database schema; retrying in 60 seconds")
                    Thread.sleep(forTimeInterval: 60)
                } else {
                    Thread.sleep(forTimeInterval: 5)
                }
            }
        }
    }

    private func connect() throws {
        let path = Self.codexHome.appendingPathComponent("ipc/ipc.sock").path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFSOCK else { throw ActivityError.connection }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw ActivityError.connection }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                path.withCString { source in _ = strlcpy(destination, source, capacity) }
            }
        }
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ActivityError.connection }
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ActivityError.connection }
    }

    private func send(_ object: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: object)
        var length = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(socketFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw ActivityError.connection }
                offset += count
            }
        }
    }

    private func follow(_ id: String, enabled: Bool) throws {
        try send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                  "sourceClientId": clientID,
                  "params": ["conversationId": id, "hostId": "local", "following": enabled]])
    }

    /// A revision gap can affect every arriving patch until its snapshot arrives.
    /// Send only one recovery request in that interval, not one full history per patch.
    private func requestSnapshot(_ id: String, now: Date = Date()) throws {
        if let requested = snapshotRequests[id], now.timeIntervalSince(requested) < 30 { return }
        try follow(id, enabled: false)
        try follow(id, enabled: true)
        snapshotRequests[id] = now
    }

    private static var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private func refreshCandidates() throws {
        let path = Self.codexHome.appendingPathComponent("state_5.sqlite").path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { throw ActivityError.connection }
        let identity = "\(device):\(inode)"
        // Reuse the read-only connection, but reopen if the desktop replaces
        // its database. Statements are finalized each poll, releasing WAL reads.
        if candidateDatabaseIdentity != identity {
            if let candidateDatabase { sqlite3_close(candidateDatabase) }
            candidateDatabase = nil
            candidateDatabaseIdentity = nil
        }
        if candidateDatabase == nil {
            guard sqlite3_open_v2(path, &candidateDatabase, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                throw ActivityError.connection
            }
            candidateDatabaseIdentity = identity
            sqlite3_busy_timeout(candidateDatabase, 500)
        }
        let database = candidateDatabase
        var statement: OpaquePointer?
        let sql = "SELECT id FROM threads WHERE archived = 0 ORDER BY recency_at_ms DESC LIMIT 100"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ActivityError.protocolMismatch }
        defer { sqlite3_finalize(statement) }
        var candidates = Set(activities.values.filter(\.isVisible).map(\.id))
        var recentIDs = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                let id = String(cString: value)
                if UUID(uuidString: id) != nil { candidates.insert(id); recentIDs.insert(id) }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ActivityError.connection }
        // The top-100 query cannot prove that an older row was archived.
        // Resolve each retained row by ID before removing it.
        var retained: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT archived FROM threads WHERE id = ?", -1, &retained, nil) == SQLITE_OK else {
            throw ActivityError.protocolMismatch
        }
        defer { sqlite3_finalize(retained) }
        for id in activities.keys.filter({ !recentIDs.contains($0) }) {
            sqlite3_reset(retained)
            sqlite3_clear_bindings(retained)
            let outcome = id.withCString { pointer -> Int32 in
                sqlite3_bind_text(retained, 1, pointer, -1, nil)
                return sqlite3_step(retained)
            }
            guard outcome == SQLITE_ROW || outcome == SQLITE_DONE else { throw ActivityError.connection }
            if outcome == SQLITE_DONE || sqlite3_column_int(retained, 0) != 0 {
                candidates.remove(id)
                activities.removeValue(forKey: id)
                awaitingSnapshots.remove(id)
                RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { self.onArchive?(id) }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
        }
        for id in followed.subtracting(candidates) {
            try follow(id, enabled: false)
            activities.removeValue(forKey: id)
            awaitingSnapshots.remove(id)
            owners.removeValue(forKey: id)
            revisions.removeValue(forKey: id)
        }
        // Read broadcasts can be missed while the desktop changes owners/windows.
        // Refresh outstanding completed rows from the owner's authoritative snapshot.
        // Keep the previous state until it arrives; absence is not completion evidence.
        let now = Date()
        snapshotRequests = snapshotRequests.filter { candidates.contains($0.key) }
        let recoveryDue = now.timeIntervalSince(lastReadRefresh) >= 30
        // Completed unread rows use the existing five-second refresh. Unknown
        // states retain the slower recovery cadence to avoid repeated retries.
        for id in candidates.intersection(followed) where ThreadRecoveryPolicy.shouldRefreshReadState(
            runtime: activities[id]?.runtime, unread: activities[id]?.unread,
            awaitingSnapshot: awaitingSnapshots.contains(id), recoveryDue: recoveryDue) {
            // Do not request another full history while one is outstanding.
            // Read broadcasts still apply immediately; a lost response retries.
            try requestSnapshot(id, now: now)
        }
        if recoveryDue { lastReadRefresh = now }
        for id in candidates.subtracting(followed) {
            try follow(id, enabled: true)
            snapshotRequests[id] = now
        }
        followed = candidates
    }

    private func handle(_ message: [String: Any]) throws {
        let type = message["type"] as? String
        let method = message["method"] as? String
        if type == "client-discovery-request", let requestID = message["requestId"] as? String {
            try send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]])
            return
        }
        if type == "response", method == "initialize",
           let result = message["result"] as? [String: Any], let id = result["clientId"] as? String {
            clientID = id
            publish(connected: true)
            return
        }
        guard type == "broadcast", let params = message["params"] as? [String: Any] else { return }
        // An owner may lose its follower list without closing our socket. Codex
        // asks followers to reannounce after reconnect; missing that request
        // leaves an active thread invisible until another full subscription.
        for id in Self.refollowIDs(for: message, followed: followed, clientID: clientID) {
            try follow(id, enabled: true)
        }
        if method == "ipc-connection-reset" || method == "thread-stream-following-status-requested" { return }
        if method == "client-status-changed", params["status"] as? String == "disconnected",
           let owner = params["clientId"] as? String {
            for id in Array(owners.keys) where owners[id] == owner {
                awaitingSnapshots.insert(id)
                owners.removeValue(forKey: id)
                revisions.removeValue(forKey: id)
                followed.remove(id)
            }
            publish(connected: true)
            return
        }
        guard params["hostId"] as? String == "local" else { return }
        if let change = Self.readStateChange(from: message) {
            activities[change.id]?.unread = change.unread
            if !change.unread, let activity = activities[change.id] {
                pendingReadActivities[change.id] = activity
            }
            publish(connected: true)
            return
        }
        if method == "thread-archived", let id = params["conversationId"] as? String {
            activities.removeValue(forKey: id)
            awaitingSnapshots.remove(id)
            followed.remove(id)
            owners.removeValue(forKey: id)
            revisions.removeValue(forKey: id)
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { self.onArchive?(id) }
            publish(connected: true)
            return
        }
        guard method == "thread-stream-state-changed" else { return }
        guard message["version"] as? Int == 11 else { throw ActivityError.protocolMismatch }
        guard let id = params["conversationId"] as? String, followed.contains(id),
              let change = params["change"] as? [String: Any],
              let revision = change["revision"] as? Int,
              let owner = message["sourceClientId"] as? String else { return }
        if change["type"] as? String == "snapshot",
           let state = change["conversationState"] as? [String: Any],
           let runtime = state["threadRuntimeStatus"] as? [String: Any], let status = runtime["type"] as? String {
            let activity = ThreadActivity(id: id, title: state["title"] as? String ?? L10n.text("Codex 채팅"),
                runtime: status,
                activeFlags: runtime["activeFlags"] as? [String] ?? [],
                pendingRequests: Self.pendingRequests(in: state["requests"] as? [[String: Any]] ?? []),
                latestTurn: Self.latestTurn(in: state),
                unread: state["hasUnreadTurn"] as? Bool ?? false,
                updatedAt: state["updatedAt"] as? Double ?? 0)
            activities[id] = activity
            snapshotRequests.removeValue(forKey: id)
            awaitingSnapshots.remove(id)
            if state["hasUnreadTurn"] as? Bool == false, !activity.isRunning {
                pendingReadActivities[id] = activity
            }
            owners[id] = owner
            revisions[id] = revision
        } else if change["type"] as? String == "patches", owners[id] == owner {
            guard let base = change["baseRevision"] as? Int, revisions[id] == base else {
                awaitingSnapshots.insert(id)
                try requestSnapshot(id)
                publish(connected: true)
                return
            }
            var refreshPendingRequests = false
            var explicitlyRead = false
            for patch in change["patches"] as? [[String: Any]] ?? [] {
                guard let path = patch["path"] as? [Any], let key = path.first as? String else { continue }
                let value = patch["value"]
                if key == "requests" {
                    if path.count == 1 {
                        activities[id]?.pendingRequests = Self.pendingRequests(in: value as? [[String: Any]] ?? [])
                    } else {
                        // Fetch the authoritative list after indexed/nested patches rather than retaining request bodies.
                        refreshPendingRequests = true
                    }
                }
                if key == "turnHistory", var activity = activities[id] {
                    Self.applyTurnPatch(patch, to: &activity)
                    activities[id] = activity
                }
                if key == "title", path.count == 1, let title = value as? String { activities[id]?.title = title }
                if key == "hasUnreadTurn", path.count == 1 {
                    guard let unread = value as? Bool else { continue }
                    activities[id]?.unread = unread
                    explicitlyRead = !unread
                }
                if key == "updatedAt", path.count == 1, let timestamp = value as? Double { activities[id]?.updatedAt = timestamp }
                if key == "activeFlags" {
                    if path.count == 1 {
                        activities[id]?.activeFlags = value as? [String] ?? []
                    } else if path.count >= 2 {
                        var flags = activities[id]?.activeFlags ?? []
                        let operation = (patch["op"] as? String ?? patch["type"] as? String ?? "replace").lowercased()
                        let index: Int? = {
                            if let index = path[1] as? Int { return index }
                            if let index = path[1] as? String { return index == "-" ? flags.count : Int(index) }
                            return nil
                        }()
                        if operation == "remove" {
                            if let index, flags.indices.contains(index) { flags.remove(at: index) }
                        } else if let flag = value as? String, let index {
                            if operation == "add", (0...flags.count).contains(index) { flags.insert(flag, at: index) }
                            else if flags.indices.contains(index) { flags[index] = flag }
                            else if index == flags.count { flags.append(flag) }
                        }
                        activities[id]?.activeFlags = flags
                    }
                }
                if key == "threadRuntimeStatus" {
                    if path.count == 1, let payload = value as? [String: Any] {
                        activities[id]?.runtime = payload["type"] as? String ?? "unknown"
                        activities[id]?.activeFlags = payload["activeFlags"] as? [String] ?? []
                    } else if path.count == 2, path[1] as? String == "type" {
                        activities[id]?.runtime = value as? String ?? "unknown"
                    } else if path.count == 2, path[1] as? String == "activeFlags" {
                        activities[id]?.activeFlags = value as? [String] ?? []
                    } else if path.count >= 3, path[1] as? String == "activeFlags" {
                        var flags = activities[id]?.activeFlags ?? []
                        let operation = (patch["op"] as? String ?? patch["type"] as? String ?? "replace").lowercased()
                        let index: Int? = {
                            if let index = path[2] as? Int { return index }
                            if let index = path[2] as? String { return index == "-" ? flags.count : Int(index) }
                            return nil
                        }()
                        if operation == "remove" {
                            if let index, flags.indices.contains(index) { flags.remove(at: index) }
                        } else if let flag = value as? String, let index {
                            if operation == "add", (0...flags.count).contains(index) { flags.insert(flag, at: index) }
                            else if flags.indices.contains(index) { flags[index] = flag }
                            else if index == flags.count { flags.append(flag) }
                        }
                        activities[id]?.activeFlags = flags
                    }
                }
            }
            // Resolve after all patches so runtime and timestamp are current,
            // even when the read flag precedes the idle transition.
            if explicitlyRead, let activity = activities[id] {
                pendingReadActivities[id] = activity
            }
            revisions[id] = revision
            if refreshPendingRequests {
                try requestSnapshot(id)
                return
            }
        }
        publish(connected: true)
    }

    private func publish(connected: Bool) {
        synchronizeAccount()
        let account = activeAccount
        let now = Date()
        awaitingSince = awaitingSince.filter { awaitingSnapshots.contains($0.key) }
        for id in awaitingSnapshots where awaitingSince[id] == nil { awaitingSince[id] = now }
        if connected {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { self.onCompatibilityChanged?(false) }
        }
        let confirmed = activities.values.filter { !awaitingSnapshots.contains($0.id) }
        let results = completionTracker.update(confirmed, connected: connected, retainingIDs: awaitingSnapshots)
        if !results.isEmpty {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                guard self.accountIsCurrent(account) else { return }
                for result in results {
                    switch result.kind {
                    case .completed: self.onCompletion?(result.activity)
                    case .failed: self.onFailure?(result.activity)
                    }
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        let attentionEvents = attentionTracker.update(confirmed, connected: connected)
        if !attentionEvents.isEmpty {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                guard self.accountIsCurrent(account) else { return }
                for event in attentionEvents { self.onAttention?(event) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        let readActivities = Array(pendingReadActivities.values)
        pendingReadActivities.removeAll()
        if !readActivities.isEmpty {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                guard self.accountIsCurrent(account) else { return }
                for activity in readActivities { self.onRead?(activity) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        let rows = activities.values.filter {
            $0.isVisible && ThreadRecoveryPolicy.shouldRetain(waitingSince: awaitingSince[$0.id], now: now)
        }.map { activity -> ThreadActivity in
            var row = activity
            row.stateConfirmed = connected && !awaitingSnapshots.contains(row.id)
            return row
        }.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        let connected = connected && (awaitingSnapshots.isEmpty || !rows.isEmpty)
        guard rows != lastPublished || connected != lastConnected else { return }
        lastPublished = rows
        lastConnected = connected
        // Menu tracking uses a separate run-loop mode; deliver updates there as well.
        RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
            guard self.accountIsCurrent(account) else { return }
            self.onUpdate(rows, connected)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private enum ActivityError: Error { case connection, protocolMismatch }
}
