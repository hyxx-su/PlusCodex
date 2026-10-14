import Foundation

/// Opt-in integration check against an isolated IPC fixture, never the user's desktop.
@main
struct ActivityRecoveryChecks {
    static func main() {
        guard let home = ProcessInfo.processInfo.environment["CODEX_HOME"],
              URL(fileURLWithPath: home).lastPathComponent.hasPrefix("pluscodex-activity-recovery.") else {
            fatalError("Run only with the isolated activity recovery fixture")
        }
        let id = "00000000-0000-4000-8000-000000000001"
        var sawRunning = false
        var sawCompleted = false
        var sawRead = false
        let monitor = ThreadActivityMonitor { rows, connected in
            guard connected else { return }
            if rows.contains(where: { $0.id == id && $0.isRunning && $0.stateConfirmed }) {
                sawRunning = true
            }
            if rows.contains(where: { $0.id == id && !$0.isRunning && $0.unread && $0.stateConfirmed }) {
                precondition(sawRunning, "Recovery must restore the running task before completion")
                sawCompleted = true
            }
            if sawCompleted && rows.isEmpty { sawRead = true }
        }
        monitor.start()
        let deadline = Date().addingTimeInterval(45)
        while !sawRead && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        precondition(sawRunning && sawCompleted && sawRead,
                     "Lost initial snapshots must recover running, unread completion and read removal")
        print("PASS: lost initial snapshot recovery, running task, unread completion and read removal")
    }
}
