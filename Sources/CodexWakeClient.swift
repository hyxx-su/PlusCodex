import Foundation
import Darwin

enum CodexWakeError: LocalizedError {
    case unavailable
    case disconnected
    case timedOut
    case invalidResponse
    case modelUnavailable
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.text("Codex 실행 파일을 찾을 수 없습니다.")
        case .disconnected: return L10n.text("Codex 연결이 종료되었습니다.")
        case .timedOut: return L10n.text("Codex 응답 시간이 초과되었습니다.")
        case .invalidResponse: return L10n.text("Codex 응답을 확인할 수 없습니다.")
        case .modelUnavailable: return L10n.text("선택한 Codex 모델을 사용할 수 없습니다.")
        case .failed(let message): return message
        case .cancelled: return L10n.text("Codex 깨우기가 꺼졌습니다.")
        }
    }
}

private struct CodexWakeModelPage: Decodable {
    let data: [CodexWakeModel]
    let nextCursor: String?
}

/// Talks to the installed Codex App Server using the existing ChatGPT login.
/// It never reads or stores authentication tokens.
final class CodexWakeClient {
    static func availableModels() throws -> [CodexWakeModel] {
        try AppServerSession().models()
    }

    /// Never fall back to a new chat when a saved chat cannot be resumed.
    /// The caller can retry that same chat after its active writer is gone.
    static func prepareThread(previousThreadID: String?, resume: (String) throws -> String,
                              start: () throws -> String) throws -> String {
        if let previousThreadID { return try resume(previousThreadID) }
        return try start()
    }

    static func turnStartParams(threadID: String, modelName: String,
                                effort: String, message: String) -> [String: Any] {
        [
            "threadId": threadID,
            "input": [["type": "text", "text": message]],
            "cwd": "/private/tmp",
            "approvalPolicy": "never",
            "sandboxPolicy": ["type": "readOnly"],
            "model": modelName,
            "effort": effort,
            // A reused chat may have Fast enabled elsewhere. This override
            // keeps the wake message on standard speed without changing the
            // user's persisted speed setting for that chat.
            "serviceTierForTurn": "default"
        ]
    }

    static func sendHello(modelID: String, effort: String, message: String,
                          previousThreadID: String?,
                          shouldProceed: () -> Bool,
                          onThreadPrepared: (String) -> Void,
                          onTurnSubmission: () -> Void,
                          onModelResolved: (CodexWakeModel) -> Void = { _ in }) throws {
        let server = try AppServerSession()
        guard effort == "low" else { throw CodexWakeError.modelUnavailable }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexWakeError.invalidResponse
        }
        let models = try server.models()
        guard let selected = models.first(where: { $0.id == modelID })
                ?? models.first(where: { $0.id == "gpt-6-luna" }) else {
            throw CodexWakeError.modelUnavailable
        }
        guard shouldProceed() else { throw CodexWakeError.cancelled }
        if selected.id != modelID { onModelResolved(selected) }

        let threadID = try prepareThread(previousThreadID: previousThreadID, resume: { id in
            let resumed = try server.request("thread/resume", params: ["threadId": id])
            guard let thread = resumed["thread"] as? [String: Any],
                  let resumedID = thread["id"] as? String else { throw CodexWakeError.invalidResponse }
            return resumedID
        }, start: {
            let started = try server.request("thread/start", params: [
                "model": selected.modelName,
                "cwd": "/private/tmp",
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "serviceTier": "default",
                "serviceName": "pluscodex_wake"
            ])
            guard let thread = started["thread"] as? [String: Any],
                  let id = thread["id"] as? String else { throw CodexWakeError.invalidResponse }
            // Naming is cosmetic; an older App Server must not prevent the
            // requested wake message from being sent.
            _ = try? server.request("thread/name/set", params: [
                "threadId": id, "name": L10n.text("Codex 깨우기")
            ], timeout: 3)
            return id
        })
        onThreadPrepared(threadID)
        guard shouldProceed() else { throw CodexWakeError.cancelled }

        onTurnSubmission()
        let result = try server.request("turn/start", params: turnStartParams(
            threadID: threadID, modelName: selected.modelName, effort: effort, message: message))
        guard let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else { throw CodexWakeError.invalidResponse }
        try server.waitForTurn(turnID)
    }
}

private final class AppServerSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var pending = Data()
    private var notifications: [[String: Any]] = []
    private var nextID = 1
    private var started = false
    private var stopped = false

    init() throws {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CodexWakeError.unavailable
        }
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        started = true
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        do {
            _ = try request("initialize", params: [
                "clientInfo": ["name": "pluscodex_wake", "title": "PlusCodex Wake", "version": "1.0"]
            ])
            try send(["method": "initialized"])
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        if started {
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }

    func models() throws -> [CodexWakeModel] {
        let accountResult = try request("account/read", params: ["refreshToken": false])
        guard let accountData = accountResult["account"] as? [String: Any],
              let accountType = accountData["type"] as? String else {
            throw CodexWakeError.unavailable
        }
        let account = CodexWakeAccount(type: accountType,
                                       planType: accountData["planType"] as? String)
        var models: [CodexWakeModel] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try request("model/list", params: params)
            let data = try JSONSerialization.data(withJSONObject: result)
            let page = try JSONDecoder().decode(CodexWakeModelPage.self, from: data)
            models.append(contentsOf: CodexWakeModel.availableForWake(page.data, account: account))
            cursor = page.nextCursor
        } while cursor != nil && models.count < 500
        return models
    }

    func request(_ method: String, params: [String: Any], timeout: TimeInterval = 20) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = try readMessage(until: deadline)
            guard let responseID = message["id"] as? Int else {
                if message["method"] != nil { notifications.append(message) }
                continue
            }
            guard responseID == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw CodexWakeError.failed(error["message"] as? String ?? "Codex 요청이 실패했습니다.")
            }
            guard let result = message["result"] as? [String: Any] else {
                throw CodexWakeError.invalidResponse
            }
            return result
        }
        throw CodexWakeError.timedOut
    }

    func waitForTurn(_ turnID: String) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let message = notifications.isEmpty ? try readMessage(until: deadline) : notifications.removeFirst()
            guard message["method"] as? String == "turn/completed",
                  let params = message["params"] as? [String: Any],
                  let turn = params["turn"] as? [String: Any],
                  turn["id"] as? String == turnID else { continue }
            if turn["status"] as? String == "completed" { return }
            throw CodexWakeError.failed(L10n.text("Codex 깨우기 작업을 완료하지 못했습니다."))
        }
        throw CodexWakeError.timedOut
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage(until deadline: Date) throws -> [String: Any] {
        let descriptor = output.fileHandleForReading.fileDescriptor
        while Date() < deadline {
            if let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    return object
                }
                continue
            }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&pollDescriptor, 1, 100)
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { pending.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { throw CodexWakeError.disconnected }
            else if errno != EAGAIN && errno != EINTR { throw CodexWakeError.disconnected }
            if pending.count > 4_000_000 { throw CodexWakeError.invalidResponse }
        }
        throw CodexWakeError.timedOut
    }
}
