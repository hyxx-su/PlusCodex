import Foundation
import Darwin

/// One short-lived, local-only connection. Never takes over a desktop writer.
final class CodexWakeDesktopBridge {
    private var fd: Int32 = -1
    private var pending = Data()
    private var clientID = ""

    init() throws {
        do {
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            let path = URL(fileURLWithPath: home).appendingPathComponent("ipc/ipc.sock").path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFSOCK else { throw CodexWakeError.unavailable }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < capacity else { throw CodexWakeError.unavailable }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    path.withCString { _ = strlcpy(destination, $0, capacity) }
                }
            }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CodexWakeError.unavailable }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw CodexWakeError.disconnected }
            let response = try request("initialize", version: 0, params: ["clientType": "codex-quota"])
            guard let result = response["result"] as? [String: Any],
                  let id = result["clientId"] as? String else { throw CodexWakeError.invalidResponse }
            clientID = id
        } catch {
            if fd >= 0 { Darwin.close(fd); fd = -1 }
            throw error
        }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func startTurn(threadID: String, params: [String: Any], shouldProceed: () -> Bool,
                   onSubmission: () -> Void) throws -> String {
        let owner = try idleOwner(threadID: threadID)
        guard shouldProceed() else { throw CodexWakeError.cancelled }
        let payload = Self.turnPayload(threadID: threadID, params: params)
        // From this point any transport error is ambiguous. Do not fall back to
        // another server or classify an owner error as proof of non-delivery.
        onSubmission()
        let response = try request("thread-follower-start-turn", version: 2,
                                   params: payload, target: owner, timeout: 30)
        return try Self.acceptedTurnID(response, owner: owner)
    }

    static func turnPayload(threadID: String, params: [String: Any]) -> [String: Any] {
        var request = params
        request["clientUserMessageId"] = UUID().uuidString
        return ["conversationId": threadID,
                "turnStart": ["request": request, "context": ["inheritThreadSettings": false]]]
    }

    static func acceptedTurnID(_ response: [String: Any], owner: String) throws -> String {
        if response["resultType"] as? String == "error" {
            throw CodexWakeError.desktopResponse(response["error"] as? String ?? "unknown error")
        }
        guard response["resultType"] as? String == "success",
              response["handledByClientId"] as? String == owner,
              let result = response["result"] as? [String: Any],
              let started = result["result"] as? [String: Any],
              let turn = started["turn"] as? [String: Any],
              let id = turn["id"] as? String, !id.isEmpty else { throw CodexWakeError.invalidResponse }
        return id
    }

    // Also used by the opt-in diagnostic: discover/follow only, without sending a turn.
    func idleOwner(threadID: String) throws -> String {
        let response = try request("thread-owner-discovery", version: 1,
            params: ["hostId": "local", "conversationId": threadID])
        guard response["resultType"] as? String == "success",
              let owner = response["handledByClientId"] as? String else { throw CodexWakeError.unavailable }
        try follow(threadID, enabled: true)
        defer { try? follow(threadID, enabled: false) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let message = try read(until: deadline)
            guard message["type"] as? String == "broadcast",
                  message["method"] as? String == "thread-stream-state-changed",
                  message["sourceClientId"] as? String == owner,
                  let params = message["params"] as? [String: Any],
                  params["conversationId"] as? String == threadID else { continue }
            guard message["version"] as? Int == 11 else { throw CodexWakeError.invalidResponse }
            guard let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
                  let state = change["conversationState"] as? [String: Any] else { continue }
            guard Self.isIdle(state) else { throw CodexWakeError.failed("Codex wake chat is busy") }
            return owner
        }
        throw CodexWakeError.timedOut
    }

    static func isIdle(_ state: [String: Any]) -> Bool {
        guard let runtime = state["threadRuntimeStatus"] as? [String: Any],
              runtime["type"] as? String == "idle" else { return false }
        return !(state["requests"] as? [[String: Any]] ?? []).contains { $0["completed"] as? Bool != true }
    }

    private func follow(_ id: String, enabled: Bool) throws {
        try send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                  "sourceClientId": clientID,
                  "params": ["conversationId": id, "hostId": "local", "following": enabled]])
    }

    private func request(_ method: String, version: Int, params: [String: Any],
                         target: String? = nil, timeout: TimeInterval = 5) throws -> [String: Any] {
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "method": method,
            "version": version, "params": params, "timeoutMs": Int(timeout * 1000)]
        if !clientID.isEmpty { message["sourceClientId"] = clientID }
        if let target { message["targetClientId"] = target }
        try send(message)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try read(until: deadline)
            if response["type"] as? String == "response", response["requestId"] as? String == id { return response }
        }
        throw CodexWakeError.timedOut
    }

    private func send(_ message: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CodexWakeError.disconnected }
                offset += count
            }
        }
    }

    private func read(until deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            if pending.count >= 4 {
                let size = pending.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                guard size > 0, size <= 64 * 1024 * 1024 else { throw CodexWakeError.invalidResponse }
                if pending.count >= size + 4 {
                    let body = Data(pending.dropFirst(4).prefix(size))
                    pending.removeFirst(size + 4)
                    guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                        throw CodexWakeError.invalidResponse
                    }
                    return value
                }
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw CodexWakeError.disconnected }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexWakeError.disconnected }
            pending.append(contentsOf: bytes.prefix(count))
        }
        throw CodexWakeError.timedOut
    }
}
