import Foundation
import Darwin

/// Orca-style /usage fallback. Only a slash command is sent; no model prompt or trust approval.
enum ClaudeCLIUsage {
    static var workingDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PlusCodex/usage-probe")
    }

    static func clean(_ output: String) -> String {
        output.replacingOccurrences(of: "\u{1B}\\][^\u{07}]*(?:\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    static func parse(_ output: String) -> Quota? {
        let lines = clean(output).components(separatedBy: .newlines)
        func heading(_ line: String) -> String? {
            let text = line.lowercased()
            if text.contains("current session") { return "5시간" }
            if text.range(of: "current\\s*week|weekly\\s*(limits?|usage|rate\\s*limits?)|7[- ]?day", options: .regularExpression) != nil {
                for model in ["Sonnet", "Opus", "Fable"] where text.contains(model.lowercased()) { return model + " 주간" }
                return "주간"
            }
            if text.trimmingCharacters(in: .whitespaces) == "fable" { return "Fable 주간" }
            return nil
        }
        let regex = try! NSRegularExpression(pattern: "(\\d{1,3}(?:\\.\\d+)?)\\s*%\\s*(used|consumed|left|remaining|available)", options: .caseInsensitive)
        var windows: [String: QuotaWindow] = [:]
        var order: [String] = []
        for (index, line) in lines.enumerated() {
            guard let label = heading(line) else { continue }
            var percent: Double?
            var reset: String?
            for offset in index..<min(index + 14, lines.count) {
                let row = lines[offset]
                if offset > index && heading(row) != nil { break }
                let ns = row as NSString
                if let match = regex.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)),
                   let value = Double(ns.substring(with: match.range(at: 1))), (0...100).contains(value) {
                    let kind = ns.substring(with: match.range(at: 2)).lowercased()
                    percent = ["used", "consumed"].contains(kind) ? value : 100 - value
                }
                if let range = row.range(of: "resets?\\s+", options: [.regularExpression, .caseInsensitive]) {
                    reset = String(row[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let percent {
                if windows[label] == nil { order.append(label) }
                windows[label] = QuotaWindow(usedPercent: percent, windowDurationMins: label == "5시간" ? 300 : 10080,
                    resetsAt: nil, customLabel: label, resetDescription: reset)
            }
        }
        let values = order.compactMap { windows[$0] }
        return values.isEmpty ? nil : ExternalUsageClient.quota(values)
    }

    static func blockingMessage(_ text: String) -> String? {
        let value = clean(text).lowercased()
        if value.range(of: "do you trust|trust the files|safety check|choose.*text style|select.*theme", options: .regularExpression) != nil {
            return L10n.text("Claude CLI 초기 설정·신뢰 확인이 필요합니다. 안내된 usage-probe 폴더에서 claude를 직접 실행해 확인하세요.")
        }
        if value.range(of: "not logged in|please log in|please login|select login method|sign in to", options: .regularExpression) != nil {
            return L10n.text("Claude CLI에서 로그인을 완료한 뒤 다시 조회하세요.")
        }
        return nil
    }

    static func fetch() throws -> Quota {
        guard let binary = CLIInstallation.executable(.claude) else {
            throw UsageFailure.message(L10n.text("Claude Code 실행 파일을 찾을 수 없습니다."))
        }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return try run(binary: binary, arguments: [], cwd: workingDirectory.path)
    }

    /// A private process group makes timeout cleanup independent of the user's existing Claude terminals.
    static func run(binary: String, arguments: [String], cwd: String, timeout: TimeInterval = 25) throws -> Quota {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw UsageFailure.message(L10n.text("Claude 조회 터미널을 열지 못했습니다.")) }
        defer { close(master); close(slave) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_adddup2(&actions, slave, fd) }
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = URL(fileURLWithPath: binary).deletingLastPathComponent().path
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        let argv = ([binary] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, binary, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard code == 0 else { throw UsageFailure.message(L10n.text("Claude CLI를 실행하지 못했습니다 (%d).", code)) }
        var reaped = false
        defer {
            // Do not signal a PID after waitpid has reaped it (it could be reused).
            if !reaped {
                kill(-pid, SIGTERM)
                usleep(100_000)
                kill(-pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        var sent = false, confirmed = false
        var data = Data()
        var lastChange = start
        var candidate: Quota?
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 100)
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(master, &buffer, buffer.count)
            let now = ProcessInfo.processInfo.systemUptime
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 1_048_576 else { throw UsageFailure.message(L10n.text("Claude CLI 출력이 너무 많아 조회를 중단했습니다.")) }
                lastChange = now
                let output = String(decoding: data, as: UTF8.self)
                if let message = blockingMessage(output) { throw UsageFailure.message(message) }
                if clean(output).lowercased().contains("rate limited") {
                    throw UsageFailure.throttled(Date().addingTimeInterval(900))
                }
                candidate = parse(output)
                if sent && !confirmed && clean(output).lowercased().contains("show plan usage limits") {
                    _ = "\r".withCString { write(master, $0, 1) }; confirmed = true
                }
            }
            if !sent && now - start >= 2 {
                _ = "/usage\r".withCString { write(master, $0, 7) }; sent = true
            }
            if let candidate, now - lastChange >= 1 { return candidate }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                reaped = true
                if let candidate { return candidate }
                throw UsageFailure.message(L10n.text("Claude CLI가 사용량을 표시하기 전에 종료되었습니다."))
            }
        }
        if let candidate { return candidate }
        throw UsageFailure.message(L10n.text("Claude /usage 조회 시간이 초과되었습니다. CLI에서 /usage가 표시되는지 확인하세요."))
    }
}
