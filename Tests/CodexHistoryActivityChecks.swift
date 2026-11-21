import AppKit
import SQLite3

@main
struct CodexHistoryActivityChecks {
    static func main() throws {
        if CommandLine.arguments.contains("--live-history") {
            guard let launch = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                .first?.launchDate else { fatalError("Desktop is not running") }
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            guard let principal = try QuotaClient.fetchSnapshot().activityPrincipal else {
                fatalError("Account metadata unavailable")
            }
            let start = Date()
            var snapshot: CodexHistoryActivity.Snapshot?
            for _ in 0..<20 { snapshot = try CodexHistoryActivity.read(home: home, desktopLaunchedAt: launch, principal: principal) }
            let rows = snapshot!.activities
            print("LIVE: samples=20 meanMs=\(Date().timeIntervalSince(start) * 1000 / 20) running=\(rows.filter { $0.isRunning && $0.stateConfirmed }.count) unconfirmed=\(rows.filter { !$0.stateConfirmed }.count) unread=\(rows.filter(\.unread).count) read=\(snapshot!.readIDs.count)")
            return
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("pluscodex-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let state = fixture.appendingPathComponent("state_5.sqlite")
        let history = fixture.appendingPathComponent("thread_history_1.sqlite")
        let id = "00000000-0000-4000-8000-000000000001"
        let other = "00000000-0000-4000-8000-000000000002"
        let now = Date()
        let seconds = Int(now.timeIntervalSince1970)
        let launch = now.addingTimeInterval(-60)
        let principal = CodexActivityPrincipal(userID: "fixture-user", accountID: "fixture-account")
        try execute(state, """
            CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, archived INTEGER,
                source TEXT, history_mode TEXT, updated_at INTEGER, recency_at_ms INTEGER,
                creator_user_id TEXT, creator_account_id TEXT);
            CREATE TABLE thread_read_receipts (thread_id TEXT PRIMARY KEY, first_unread_turn TEXT, last_published_turn TEXT);
            INSERT INTO threads VALUES ('\(id)', 'Fixture', 'Title', 0, 'vscode', 'paginated', \(seconds), \(seconds * 1000), 'fixture-user', 'fixture-account');
            INSERT INTO threads VALUES ('\(other)', 'Subagent', 'Title', 0, '{"subagent":{}}', 'paginated', \(seconds), \(seconds * 1000), 'fixture-user', 'fixture-account');
            INSERT INTO thread_read_receipts VALUES ('\(id)', NULL, 'old-turn');
            """)
        try execute(history, """
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, status TEXT, started_at INTEGER,
                completed_at INTEGER, rollout_ordinal INTEGER, PRIMARY KEY(thread_id, turn_id));
            CREATE INDEX idx_thread_turns_page ON thread_turns(thread_id, rollout_ordinal);
            INSERT INTO thread_turns VALUES ('\(id)', 'old-turn', 'inProgress', \(seconds - 6000), NULL, 1);
            INSERT INTO thread_turns VALUES ('\(id)', 'current-turn', 'inProgress', \(seconds - 10), NULL, 2);
            INSERT INTO thread_turns VALUES ('\(other)', 'subagent-turn', 'inProgress', \(seconds - 10), NULL, 1);
            """)
        func read(observedTurns: [String: ThreadTurnState] = [:]) throws -> CodexHistoryActivity.Snapshot {
            try CodexHistoryActivity.read(home: fixture, desktopLaunchedAt: launch, principal: principal,
                                          retainingIDs: [id, other], observedTurns: observedTurns, now: now)
        }
        var snapshot = try read()
        precondition(snapshot.activities.count == 1)
        precondition(snapshot.activities[0].isRunning && snapshot.activities[0].stateConfirmed)
        precondition(snapshot.activities[0].latestTurn?.id == "current-turn")
        precondition(snapshot.activities[0].latestTurn?.startedAtMs == Double(seconds - 10) * 1000)
        precondition(snapshot.readIDs.isEmpty, "A previous turn's receipt is not current read evidence")

        var completions = 0, failures = 0, reads = 0, archived = 0
        var visible: [ThreadActivity] = []
        let monitor = ThreadActivityMonitor { rows, connected in
            precondition(connected)
            visible = rows
        }
        monitor.onCompletion = { _ in completions += 1 }
        monitor.onFailure = { _ in failures += 1 }
        monitor.onRead = { _ in reads += 1 }
        monitor.onArchive = { _ in archived += 1 }
        func apply(_ snapshot: CodexHistoryActivity.Snapshot) {
            monitor.testHookHistorySnapshot(snapshot)
            let deadline = Date().addingTimeInterval(0.03)
            while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: deadline) }
        }
        apply(snapshot)
        precondition(visible.first?.isRunning == true && completions == 0)
        try execute(history, "UPDATE thread_turns SET status='completed' WHERE turn_id='current-turn';")
        snapshot = try read()
        precondition(!snapshot.activities[0].isRunning, "Completed rows may lack completed_at")
        precondition(snapshot.readIDs.isEmpty && !snapshot.activities[0].unread,
                     "Mismatched read pointers are unknown, not affirmative unread evidence")
        apply(snapshot)
        apply(snapshot)
        precondition(completions == 1 && reads == 0 && visible.first?.unread == true,
                     "An observed completion must survive delayed read publication and notify once")
        try execute(state, "UPDATE thread_read_receipts SET first_unread_turn='current-turn', last_published_turn='current-turn';")
        snapshot = try read()
        precondition(snapshot.activities[0].unread)
        apply(snapshot)
        try execute(state, "UPDATE thread_read_receipts SET first_unread_turn=NULL;")
        snapshot = try read()
        precondition(snapshot.readIDs == [id])
        apply(snapshot)
        apply(snapshot)
        precondition(reads == 1 && visible.isEmpty && completions == 1)

        try execute(history, "INSERT INTO thread_turns VALUES ('\(id)', 'interrupted-turn', 'inProgress', \(seconds - 5), NULL, 3);")
        apply(try read())
        try execute(history, "UPDATE thread_turns SET status='interrupted' WHERE turn_id='interrupted-turn';")
        apply(try read())
        precondition(completions == 1 && failures == 0 && reads == 1 && visible.isEmpty)
        try execute(history, "INSERT INTO thread_turns VALUES ('\(id)', 'failed-turn', 'inProgress', \(seconds - 3), NULL, 4);")
        apply(try read())
        try execute(history, "UPDATE thread_turns SET status='failed' WHERE turn_id='failed-turn';")
        apply(try read())
        apply(try read())
        precondition(failures == 1 && completions == 1)
        try execute(history, "UPDATE thread_turns SET status='inProgress', started_at=\(seconds - 300) WHERE turn_id='failed-turn';")
        snapshot = try read()
        precondition(snapshot.activities.isEmpty, "Pre-restart inProgress rows must not be revived")
        try execute(history, "UPDATE thread_turns SET started_at=\(seconds - 3) WHERE turn_id='failed-turn';")
        try execute(state, "UPDATE threads SET updated_at=\(seconds - 180) WHERE id='\(id)';")
        snapshot = try read()
        precondition(snapshot.activities[0].isRunning && !snapshot.activities[0].stateConfirmed)
        apply(snapshot)
        precondition(visible.first?.stateConfirmed == false && completions == 1)
        try execute(state, "UPDATE threads SET archived=1 WHERE id='\(id)';")
        snapshot = try read()
        precondition(snapshot.activities.isEmpty && snapshot.archivedIDs == [id])
        apply(snapshot)
        precondition(archived == 1)

        try execute(state, "UPDATE threads SET archived=0, updated_at=\(seconds) WHERE id='\(id)';")
        try execute(history, "INSERT INTO thread_turns VALUES ('\(id)', 'fast-turn', 'inProgress', \(seconds - 2), NULL, 5);")
        snapshot = try read()
        apply(snapshot)
        let observed = snapshot.activities[0].latestTurn!
        try execute(history, """
            UPDATE thread_turns SET status='completed' WHERE turn_id='fast-turn';
            INSERT INTO thread_turns VALUES ('\(id)', 'next-turn', 'inProgress', \(seconds - 1), NULL, 6);
            """)
        snapshot = try read(observedTurns: [id: observed])
        precondition(snapshot.previousTurns.count == 1 && snapshot.previousTurns[0].latestTurn?.id == "fast-turn")
        apply(snapshot)
        precondition(completions == 2 && visible.first?.latestTurn?.id == "next-turn" && visible.first?.isRunning == true,
                     "A new turn between polls must not hide the previously observed completion")
        try execute(state, "UPDATE threads SET creator_account_id='other-account' WHERE id='\(id)';")
        snapshot = try read()
        precondition(snapshot.activities.isEmpty && snapshot.archivedIDs.isEmpty,
                     "Even retained IDs must not expose another account")
        try execute(state, "UPDATE threads SET archived=1 WHERE id='\(id)';")
        snapshot = try read()
        precondition(snapshot.archivedIDs.isEmpty, "Another account's archive must not clear local records")
        try execute(state, "UPDATE threads SET archived=0, creator_user_id=NULL, creator_account_id=NULL WHERE id='\(id)';")
        snapshot = try read()
        precondition(snapshot.activities.count == 1, "Recent shared legacy chats remain discoverable")
        let switched = try CodexHistoryActivity.read(home: fixture, desktopLaunchedAt: launch, principal: principal,
            legacyNotBefore: now.addingTimeInterval(60), now: now)
        precondition(switched.activities.isEmpty, "An account switch must not revive earlier shared legacy work")

        let decoded = try JSONDecoder().decode(AccountResponse.self, from: Data("""
            {"account":{"email":"fixture@example.invalid","planType":"plus"},"userId":"fixture-user",
             "workspaceRouting":{"chatgptAccountId":"fixture-account"}}
            """.utf8))
        precondition(decoded.activityPrincipal == principal)
        let legacyAccount = try JSONDecoder().decode(AccountResponse.self, from: Data("{\"account\":null}".utf8))
        precondition(legacyAccount.activityPrincipal == nil)

        // An A -> B -> A change still invalidates callbacks queued in A's old
        // generation. Use no account string so tests never persist preferences.
        var deliveries = 0
        let isolated = ThreadActivityMonitor { _, _ in deliveries += 1 }
        isolated.testHookHistorySnapshot(snapshot)
        isolated.selectAccount(nil, principal: principal)
        isolated.selectAccount(nil)
        let deadline = Date().addingTimeInterval(0.03)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: deadline) }
        precondition(deliveries == 0)
        isolated.testHookHistorySnapshot(snapshot)
        let nextDeadline = Date().addingTimeInterval(0.03)
        while Date() < nextDeadline { _ = RunLoop.main.run(mode: .default, before: nextDeadline) }
        precondition(deliveries == 1, "A new account generation must publish even an identical snapshot")
        isolated.selectAccount(nil, principal: principal)
        isolated.testHookDisconnected()
        let disconnectedDeadline = Date().addingTimeInterval(0.03)
        while Date() < disconnectedDeadline { _ = RunLoop.main.run(mode: .default, before: disconnectedDeadline) }
        precondition(deliveries == 2, "An empty disconnected generation must clear the previous account's UI")

        // File replacement must be picked up on the next poll, and an absent or
        // incompatible database must fail closed without creating any files.
        try FileManager.default.removeItem(at: history)
        do { _ = try read(); preconditionFailure("Missing history must fail") } catch { }
        precondition(!FileManager.default.fileExists(atPath: history.path))
        try execute(history, "CREATE TABLE different_schema (id TEXT);")
        do { _ = try read(); preconditionFailure("Unknown schema must fail") } catch { }
        print("PASS: history lifecycle, read matching, fast turns, dedupe, interruption, failures, stale state, subagents, account isolation, legacy discovery and schema failure")
    }

    private static func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}
