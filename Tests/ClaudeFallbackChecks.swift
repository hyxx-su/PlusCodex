import Foundation
import Darwin

@main struct ClaudeFallbackChecks {
    static func main() throws {
        if CommandLine.arguments.contains("--desktop-probe") {
            let snapshot = ClaudeDesktopUsage.fetch()
            print("Desktop cache readable: \(snapshot != nil), usage windows: \(snapshot?.quota.windows.count ?? 0)")
            return
        }
        if CommandLine.arguments.contains("--fixture") {
            precondition(isatty(0) == 1 && isatty(1) == 1)
            guard readLine() == "/usage" else { exit(2) }
            print("Current session\n25% used\nResets 6pm (Asia/Seoul)\nCurrent week (all models)\n60% left")
            fflush(stdout)
            sleep(10)
            return
        }
        if CommandLine.arguments.contains("--blocked") {
            print("Do you trust the files in this folder?"); fflush(stdout); sleep(10); return
        }
        if CommandLine.arguments.contains("--hang") { sleep(10); return }
        let raw = "\u{1b}[32mCurrent session\u{1b}[0m\n25.5% used\nResets 6pm (Asia/Seoul)\nCurrent week (all models)\n20% remaining\nCurrent week (Sonnet)\n90% used"
        let quota = ClaudeCLIUsage.parse(raw)!
        precondition(quota.windows.map(\.remaining) == [74, 20, 10])
        precondition(quota.primary?.resetDescription == "6pm (Asia/Seoul)")
        precondition(ClaudeCLIUsage.parse("Current session\nCurrent week\n25% used")?.primary?.label == "주간")
        precondition(ClaudeCLIUsage.parse("Current session\n101% used") == nil)
        precondition(ClaudeCLIUsage.parse("Total cost $0.5\nUsage: 300 input") == nil)
        precondition(ClaudeCLIUsage.blockingMessage("Safety check") != nil)
        precondition(ClaudeCLIUsage.blockingMessage("Not logged in") != nil)
        let snapshot = QuotaSnapshot(quota: quota, account: nil)
        var oauthCalls = 0, cliCalls = 0
        _ = try ExternalUsageClient.recoveringClaude(oauth: {
            oauthCalls += 1
            if oauthCalls == 1 { throw UsageFailure.authentication }
            return snapshot
        }, cli: { cliCalls += 1; return quota })
        precondition(oauthCalls == 2 && cliCalls == 1)
        for failure in [UsageFailure.throttled(Date()), .missingScope] {
            cliCalls = 0
            do {
                _ = try ExternalUsageClient.recoveringClaude(oauth: { throw failure }, cli: { cliCalls += 1; return quota })
                preconditionFailure("Terminal errors must propagate")
            } catch is UsageFailure {}
            precondition(cliCalls == 0)
        }
        let fallback = try ExternalUsageClient.recoveringClaude(oauth: { throw UsageFailure.credentialsUnavailable }, cli: { quota })
        precondition(fallback.quota.windows.count == 3)
        cliCalls = 0
        let desktopFallback = try ExternalUsageClient.recoveringClaude(
            oauth: { throw UsageFailure.credentialsUnavailable },
            cli: { cliCalls += 1; throw UsageFailure.credentialsUnavailable },
            desktop: { snapshot })
        precondition(desktopFallback.quota.windows.count == 3 && cliCalls == 0)
        let scopeFallback = try ExternalUsageClient.recoveringClaude(
            oauth: { throw UsageFailure.missingScope },
            cli: { preconditionFailure("A missing OAuth scope must not invoke the CLI") },
            desktop: { snapshot })
        precondition(scopeFallback.quota.windows.count == 3)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func history(_ timestamp: Double, _ usage: [String: Double], org: String? = "current") -> Data {
            let sample: [String: Any] = ["t": timestamp, "org": org.map { $0 as Any } ?? NSNull(), "u": usage]
            return try! JSONSerialization.data(withJSONObject: ["version": 2, "samples": [sample]])
        }
        let current = history(now.timeIntervalSince1970 * 1000 - 300_000,
                              ["fh": 25.5, "sd": 60, "so": 5])
        let cached = ClaudeDesktopUsage.parse(current, now: now)!
        precondition(cached.quota.windows.map(\.remaining) == [74, 40, 95])
        precondition(cached.quota.windows.allSatisfy { $0.resetsAt == nil })
        let free = ClaudeDesktopUsage.parse(history(now.timeIntervalSince1970 * 1000, [:]), now: now)!
        precondition(free.quota.windows.isEmpty)
        precondition(ClaudeDesktopUsage.parse(history(now.timeIntervalSince1970 * 1000 - 21 * 60_000,
            ["fh": 25]), now: now) == nil)
        precondition(ClaudeDesktopUsage.parse(history(now.timeIntervalSince1970 * 1000,
            ["fh": 110]), now: now) == nil)
        precondition(ClaudeDesktopUsage.parse(history(now.timeIntervalSince1970 * 1000,
            ["unknown": 25]), now: now) == nil)
        precondition(ClaudeDesktopUsage.parse(Data("{\"version\":3,\"samples\":[]}".utf8), now: now) == nil)
        oauthCalls = 0
        do {
            _ = try ExternalUsageClient.recoveringClaude(oauth: { oauthCalls += 1; throw UsageFailure.authentication },
                cli: { throw UsageFailure.throttled(Date()) })
            preconditionFailure("CLI throttle must not retry OAuth")
        } catch is UsageFailure {}
        precondition(oauthCalls == 1)
        precondition(CLIInstallation.findExecutable(name: "sh", directories: ["/bin"]) == "/bin/sh")
        precondition(CLIInstallation.findExecutable(name: "grok", directories: ["/nonexistent-pluscodex-test"]) == nil)
        precondition(CLIInstallation.findExecutable(name: "tmp", directories: ["/private"]) == nil)
        precondition(CLIInstallation.findExecutable(name: "sh", directories: ["."]) == nil)
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let cwd = FileManager.default.temporaryDirectory.path
        let live = try ClaudeCLIUsage.run(binary: binary, arguments: ["--fixture"], cwd: cwd, timeout: 7)
        precondition(live.primary?.remaining == 75 && live.secondary?.remaining == 60)
        for (mode, timeout) in [("--blocked", 3.0), ("--hang", 0.4)] {
            let start = Date()
            do {
                _ = try ClaudeCLIUsage.run(binary: binary, arguments: [mode], cwd: cwd, timeout: timeout)
                preconditionFailure("Expected bounded failure")
            } catch is UsageFailure {}
            precondition(Date().timeIntervalSince(start) < timeout + 2)
        }
        print("PASS: Claude OAuth/Desktop/CLI fallback, free and stale desktop caches, no throttle bypass, CLI PTY parsing and timeout cleanup")
    }
}
