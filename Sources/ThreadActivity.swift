import Foundation
import AppKit
import Darwin
import SQLite3

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
    private var previous: [String: ThreadActivity] = [:]
    private var notifiedTurnIDs: [String: Set<String>] = [:]
    private let sessionStartedAtMs = Date().timeIntervalSince1970 * 1000

    mutating func update(_ rows: [ThreadActivity], connected: Bool) -> [ThreadTurnResult] {
        guard connected else { previous.removeAll(); return [] }
        var results: [ThreadTurnResult] = []
        for activity in rows {
            let prior = previous[activity.id]
            let becameIdle = prior?.runtime == "active" && activity.runtime == "idle"
            if let turn = activity.latestTurn {
                let observedRunningTurn = prior?.latestTurn?.id == turn.id
                    && prior?.latestTurn?.status == "inProgress"
                let firstObservedRecentTerminalTurn = prior?.latestTurn?.id != turn.id
                    && turn.startedAtMs >= sessionStartedAtMs
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
            } else if becameIdle {
                results.append(ThreadTurnResult(activity: activity, kind: .completed))
            }
            previous[activity.id] = activity
        }
        previous = previous.filter { id, _ in rows.contains(where: { $0.id == id }) }
        return results
    }
}

struct ThreadAttentionEvent {
    let activity: ThreadActivity
    let kind: ThreadAttentionKind
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
                        events.append(ThreadAttentionEvent(activity: activity, kind: request.kind))
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
    private var opened: [String: Double] = [:]
    private var pendingCompletions: [String: ThreadActivity] = [:]

    mutating func markCompleted(_ activity: ThreadActivity) {
        var completed = activity
        completed.runtime = "idle"
        completed.activeFlags = []
        completed.pendingRequests = []
        pendingCompletions[activity.id] = completed
        opened.removeValue(forKey: activity.id)
    }

    mutating func acknowledge(_ activity: ThreadActivity) {
        guard !activity.isRunning else { return }
        pendingCompletions.removeValue(forKey: activity.id)
        opened[activity.id] = activity.updatedAt
    }

    /// Acknowledge a completed row when Codex reports that it was read outside
    /// the PlusCodex menu. Keep the timestamp guard so a stale unread snapshot
    /// cannot immediately restore the row after the read-state event.
    mutating func acknowledgeExternally(_ activity: ThreadActivity) {
        acknowledge(activity)
    }

    mutating func visibleRows(_ rows: [ThreadActivity]) -> [ThreadActivity] {
        for row in rows {
            if row.isRunning || row.updatedAt > (opened[row.id] ?? .infinity) {
                opened.removeValue(forKey: row.id)
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
    private static let maximumBufferedFrameSize = 32 * 1024 * 1024
    private static let maximumDiscardedFrameSize = 256 * 1024 * 1024
    private let queue = DispatchQueue(label: "local.codexquota.activity", qos: .utility)
    private let onUpdate: ([ThreadActivity], Bool) -> Void
    private var socketFD: Int32 = -1
    private var clientID = ""
    private var pending = Data()
    private var discardedFrameBytesRemaining = 0
    private var followed = Set<String>()
    private var activities: [String: ThreadActivity] = [:]
    private var owners: [String: String] = [:]
    private var revisions: [String: Int] = [:]
    private var lastPublished: [ThreadActivity] = []
    private var lastConnected = false
    private var completionTracker = CompletionTracker()
    private var attentionTracker = AttentionTracker()
    private var pendingReadActivities: [String: ThreadActivity] = [:]
    var onCompletion: ((ThreadActivity) -> Void)?
    var onFailure: ((ThreadActivity) -> Void)?
    var onAttention: ((ThreadAttentionEvent) -> Void)?
    var onRead: ((ThreadActivity) -> Void)?

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

    func start() { queue.async { self.run() } }

    private func run() {
        while true {
            do {
                try connect()
                try send(["type": "request", "requestId": UUID().uuidString,
                          "method": "initialize", "version": 0,
                          "params": ["clientType": "codex-quota"]])
                var refreshAt = Date.distantPast
                while true {
                    if !clientID.isEmpty && Date() >= refreshAt {
                        try refreshCandidates()
                        refreshAt = Date().addingTimeInterval(5)
                    }
                    var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
                    let result = poll(&descriptor, 1, 1000)
                    if result < 0 { throw ActivityError.connection }
                    if result == 0 {
                        if attentionTracker.hasPendingFallback { publish(connected: true) }
                        continue
                    }
                    var bytes = [UInt8](repeating: 0, count: 65536)
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
                        let frame = Data(pending.dropFirst(4).prefix(length))
                        pending.removeFirst(length + 4)
                        if let message = try JSONSerialization.jsonObject(with: frame) as? [String: Any] {
                            try handle(message)
                        }
                    }
                }
            } catch {
                if socketFD >= 0 { Darwin.close(socketFD) }
                socketFD = -1
                clientID = ""
                pending.removeAll()
                discardedFrameBytesRemaining = 0
                followed.removeAll()
                activities.removeAll()
                owners.removeAll()
                revisions.removeAll()
                pendingReadActivities.removeAll()
                publish(connected: false)
                Thread.sleep(forTimeInterval: 5)
            }
        }
    }

    private func connect() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock").path
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

    private func refreshCandidates() throws {
        var database: OpaquePointer?
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw ActivityError.connection
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        var statement: OpaquePointer?
        let sql = "SELECT id FROM threads WHERE archived = 0 ORDER BY recency_at_ms DESC LIMIT 100"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ActivityError.protocolMismatch }
        defer { sqlite3_finalize(statement) }
        var candidates = Set(activities.values.filter(\.isVisible).map(\.id))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                let id = String(cString: value)
                if UUID(uuidString: id) != nil { candidates.insert(id) }
            }
        }
        for id in followed.subtracting(candidates) {
            try follow(id, enabled: false)
            activities.removeValue(forKey: id)
            owners.removeValue(forKey: id)
            revisions.removeValue(forKey: id)
        }
        // Read broadcasts can be missed while the desktop changes owners/windows.
        // Refresh outstanding completed rows from the owner's authoritative snapshot.
        // Keep the previous state until it arrives; absence is not completion evidence.
        for id in candidates.intersection(followed) where activities[id]?.runtime == "idle" && activities[id]?.unread == true {
            try follow(id, enabled: false)
            try follow(id, enabled: true)
        }
        for id in candidates.subtracting(followed) { try follow(id, enabled: true) }
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
        if method == "client-status-changed", params["status"] as? String == "disconnected",
           let owner = params["clientId"] as? String {
            for id in Array(owners.keys) where owners[id] == owner {
                activities.removeValue(forKey: id)
                owners.removeValue(forKey: id)
                revisions.removeValue(forKey: id)
                followed.remove(id)
            }
            publish(connected: true)
            return
        }
        guard params["hostId"] as? String == "local" else { return }
        if let change = Self.readStateChange(from: message) {
            let wasUnread = activities[change.id]?.unread == true
            activities[change.id]?.unread = change.unread
            if wasUnread, !change.unread, let activity = activities[change.id] {
                pendingReadActivities[change.id] = activity
            }
            publish(connected: true)
            return
        }
        if method == "thread-archived", let id = params["conversationId"] as? String {
            activities.removeValue(forKey: id)
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
            let wasUnread = activities[id]?.unread == true
            let activity = ThreadActivity(id: id, title: state["title"] as? String ?? L10n.text("Codex 채팅"),
                runtime: status,
                activeFlags: runtime["activeFlags"] as? [String] ?? [],
                pendingRequests: Self.pendingRequests(in: state["requests"] as? [[String: Any]] ?? []),
                latestTurn: Self.latestTurn(in: state),
                unread: state["hasUnreadTurn"] as? Bool ?? false,
                updatedAt: state["updatedAt"] as? Double ?? 0)
            activities[id] = activity
            if wasUnread, !activity.unread { pendingReadActivities[id] = activity }
            owners[id] = owner
            revisions[id] = revision
        } else if change["type"] as? String == "patches", owners[id] == owner {
            guard let base = change["baseRevision"] as? Int, revisions[id] == base else {
                activities.removeValue(forKey: id)
                try follow(id, enabled: false)
                try follow(id, enabled: true)
                publish(connected: true)
                return
            }
            var refreshPendingRequests = false
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
                    let wasUnread = activities[id]?.unread == true
                    let unread = value as? Bool ?? false
                    activities[id]?.unread = unread
                    if wasUnread, !unread, let activity = activities[id] {
                        pendingReadActivities[id] = activity
                    }
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
            revisions[id] = revision
            if refreshPendingRequests {
                try follow(id, enabled: false)
                try follow(id, enabled: true)
                return
            }
        }
        publish(connected: true)
    }

    private func publish(connected: Bool) {
        let results = completionTracker.update(Array(activities.values), connected: connected)
        if !results.isEmpty {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                for result in results {
                    switch result.kind {
                    case .completed: self.onCompletion?(result.activity)
                    case .failed: self.onFailure?(result.activity)
                    }
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        let attentionEvents = attentionTracker.update(Array(activities.values), connected: connected)
        if !attentionEvents.isEmpty {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                for event in attentionEvents { self.onAttention?(event) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        let readActivities = Array(pendingReadActivities.values)
        pendingReadActivities.removeAll()
        if !readActivities.isEmpty {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                for activity in readActivities { self.onRead?(activity) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        let rows = activities.values.filter(\.isVisible).sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        guard rows != lastPublished || connected != lastConnected else { return }
        lastPublished = rows
        lastConnected = connected
        // Menu tracking uses a separate run-loop mode; deliver updates there as well.
        RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { self.onUpdate(rows, connected) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private enum ActivityError: Error { case connection, protocolMismatch }
}
