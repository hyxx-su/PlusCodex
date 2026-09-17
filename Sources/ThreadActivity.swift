import Foundation
import AppKit
import Darwin
import SQLite3

struct ThreadActivity: Equatable {
    let id: String
    var title: String
    var runtime: String
    var unread: Bool
    var updatedAt: Double

    var isRunning: Bool { runtime == "active" }
    var isVisible: Bool { isRunning || (runtime == "idle" && unread) }
    var url: URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
}

/// Only explicit active-to-idle transitions count; disappearing rows are not completion.
struct CompletionTracker {
    private var previous: [String: String] = [:]

    mutating func update(_ rows: [ThreadActivity], connected: Bool) -> [ThreadActivity] {
        guard connected else { previous.removeAll(); return [] }
        let completed = rows.filter { previous[$0.id] == "active" && $0.runtime == "idle" }
        previous = Dictionary(rows.map { ($0.id, $0.runtime) }, uniquingKeysWith: { _, last in last })
        return completed
    }
}

/// Session-local acknowledgement of completed results opened from this menu.
struct ThreadActivityReadReceipts {
    private var opened: [String: Double] = [:]

    mutating func acknowledge(_ activity: ThreadActivity) {
        guard !activity.isRunning else { return }
        opened[activity.id] = activity.updatedAt
    }

    mutating func visibleRows(_ rows: [ThreadActivity]) -> [ThreadActivity] {
        for row in rows where row.isRunning || row.updatedAt > (opened[row.id] ?? .infinity) {
            opened.removeValue(forKey: row.id)
        }
        return rows.filter { $0.isVisible && (opened[$0.id] == nil || $0.isRunning) }
    }
}

/// Read-only adapter for the installed desktop app's versioned local IPC protocol.
/// No tokens, message bodies, or read-state changes are persisted by this app.
final class ThreadActivityMonitor {
    private let queue = DispatchQueue(label: "local.codexquota.activity", qos: .utility)
    private let onUpdate: ([ThreadActivity], Bool) -> Void
    private var socketFD: Int32 = -1
    private var clientID = ""
    private var pending = Data()
    private var followed = Set<String>()
    private var activities: [String: ThreadActivity] = [:]
    private var owners: [String: String] = [:]
    private var revisions: [String: Int] = [:]
    private var lastPublished: [ThreadActivity] = []
    private var lastConnected = false
    private var completionTracker = CompletionTracker()
    var onCompletion: ((ThreadActivity) -> Void)?

    init(onUpdate: @escaping ([ThreadActivity], Bool) -> Void) { self.onUpdate = onUpdate }

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
                    if result == 0 { continue }
                    var bytes = [UInt8](repeating: 0, count: 65536)
                    let count = Darwin.read(socketFD, &bytes, bytes.count)
                    guard count > 0 else { throw ActivityError.connection }
                    pending.append(contentsOf: bytes.prefix(count))
                    while pending.count >= 4 {
                        let length = pending.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                        guard length > 0, length <= 32 * 1024 * 1024 else { throw ActivityError.protocolMismatch }
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
                followed.removeAll()
                activities.removeAll()
                owners.removeAll()
                revisions.removeAll()
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
            activities[change.id]?.unread = change.unread
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
            activities[id] = ThreadActivity(id: id, title: state["title"] as? String ?? "Codex 채팅",
                runtime: status, unread: state["hasUnreadTurn"] as? Bool ?? false,
                updatedAt: state["updatedAt"] as? Double ?? 0)
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
            for patch in change["patches"] as? [[String: Any]] ?? [] {
                guard let path = patch["path"] as? [Any], let key = path.first as? String else { continue }
                let value = patch["value"]
                if key == "title", path.count == 1, let title = value as? String { activities[id]?.title = title }
                if key == "hasUnreadTurn", path.count == 1 { activities[id]?.unread = value as? Bool ?? false }
                if key == "updatedAt", path.count == 1, let timestamp = value as? Double { activities[id]?.updatedAt = timestamp }
                if key == "threadRuntimeStatus" {
                    if path.count == 1 { activities[id]?.runtime = (value as? [String: Any])?["type"] as? String ?? "unknown" }
                    else if path.count == 2, path[1] as? String == "type" { activities[id]?.runtime = value as? String ?? "unknown" }
                }
            }
            revisions[id] = revision
        }
        publish(connected: true)
    }

    private func publish(connected: Bool) {
        let completed = completionTracker.update(Array(activities.values), connected: connected)
        if !completed.isEmpty {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                for activity in completed { self.onCompletion?(activity) }
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
