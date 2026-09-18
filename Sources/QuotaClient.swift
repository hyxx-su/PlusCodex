import Foundation
import Darwin

struct QuotaWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var customLabel: String? = nil
    var resetDescription: String? = nil
    var remaining: Int { Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) }
    var label: String {
        if let customLabel { return customLabel }
        guard let minutes = windowDurationMins else { return "사용 한도" }
        if minutes == 10080 { return "주간" }
        if minutes == 43200 { return "1개월" }
        return minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes)분"
    }

    /// Plan-specific presentation only; never changes server reset dates or quota math.
    func displayLabel(planType: String?, isPrimary: Bool) -> String {
        guard isPrimary else { return label }
        let plan = planType?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if plan == "free" { return "1개월" }
        if plan == "pro" || plan.hasPrefix("pro_") || plan.hasPrefix("pro-") { return "주간" }
        return label
    }
}

struct Quota: Decodable {
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    var additional: [QuotaWindow]? = nil
    var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } + (additional ?? []) }
}

struct QuotaResponse: Decodable {
    let rateLimits: Quota?
    let rateLimitsByLimitId: [String: Quota]?
    var codex: Quota? {
        if let buckets = rateLimitsByLimitId, !buckets.isEmpty { return buckets["codex"] }
        return rateLimits
    }
}

struct CodexAccount: Decodable {
    let email: String?
    let planType: String?
}

private struct AccountResponse: Decodable {
    let account: CodexAccount?
}

struct QuotaSnapshot {
    let quota: Quota
    let account: CodexAccount?
}

enum QuotaError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

/// Uses the installed Codex's login; never reads or copies authentication tokens.
final class QuotaClient {
    static func fetch() throws -> Quota {
        try fetchSnapshot().quota
    }

    static func fetchSnapshot(onQuota: ((Quota) -> Void)? = nil) throws -> QuotaSnapshot {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw QuotaError.unavailable("Codex 실행 파일을 찾을 수 없습니다.")
        }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let stopDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var pending = Data()
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func response(_ id: Int, timeout: TimeInterval = 20) throws -> Data {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["id"] as? Int == id else { continue }
                    if object["error"] != nil {
                        throw QuotaError.unavailable("조회 실패 — Codex의 로그인 상태를 확인하세요.")
                    }
                    guard let result = object["result"] else { continue }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 100)
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 { pending.append(contentsOf: bytes.prefix(count)) }
                else if count == 0 { throw QuotaError.unavailable("Codex 연결이 종료되었습니다.") }
                else if errno != EAGAIN && errno != EINTR {
                    throw QuotaError.unavailable("Codex 응답을 읽을 수 없습니다.")
                }
                if pending.count > 4_000_000 { throw QuotaError.unavailable("Codex 응답이 너무 큽니다.") }
            }
            throw QuotaError.unavailable("조회 시간 초과 — 60초 후 재시도합니다.")
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_quota", "version": "1.0"]]])
        _ = try response(1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read"])
        let result = try JSONDecoder().decode(QuotaResponse.self, from: response(2))
        // A successful response without windows is not evidence of a 5-hour limit
        // (nor of unlimited usage). Still fetch the account and show an empty state.
        let quota = result.codex ?? Quota(primary: nil, secondary: nil)
        // Publish usable limits before optional identity lookup or process cleanup.
        onQuota?(quota)
        // Account details are optional; a failed identity lookup must not hide valid usage.
        let account: CodexAccount?
        do {
            try send(["id": 3, "method": "account/read", "params": ["refreshToken": false]])
            account = try JSONDecoder().decode(AccountResponse.self, from: response(3, timeout: 3)).account
        } catch {
            account = nil
        }
        return QuotaSnapshot(quota: quota, account: account)
    }
}
