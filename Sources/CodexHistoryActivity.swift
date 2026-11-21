import Foundation
import SQLite3

/// Newer desktops no longer expose the legacy thread-stream socket. Their
/// paginated history stores lifecycle metadata separately from conversation bodies.
/// Only the activity monitor's serial queue calls this read-only fallback.
enum CodexHistoryActivity {
    struct Snapshot {
        var activities: [ThreadActivity]
        var readIDs: Set<String>
        var archivedIDs: Set<String>
        var previousTurns: [ThreadActivity] = []
        var previousReadIDs: Set<String> = []
    }

    enum ReadError: Error { case unavailable, unsupportedSchema }

    static func read(home: URL, desktopLaunchedAt: Date, principal: CodexActivityPrincipal,
                     retainingIDs: Set<String> = [], observedTurns: [String: ThreadTurnState] = [:],
                     legacyNotBefore: Date? = nil,
                     now: Date = Date()) throws -> Snapshot {
        let state = try open(home.appendingPathComponent("state_5.sqlite"))
        defer { sqlite3_close(state) }
        let history = try open(home.appendingPathComponent("thread_history_1.sqlite"))
        defer { sqlite3_close(history) }
        // A transaction in each database prevents a single poll from mixing
        // revisions within that file. Cross-file reads are matched by turn ID.
        guard sqlite3_exec(state, "BEGIN", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(history, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ReadError.unavailable }
        defer {
            sqlite3_exec(state, "ROLLBACK", nil, nil, nil)
            sqlite3_exec(history, "ROLLBACK", nil, nil, nil)
        }
        let candidates = try prepare(state, """
            SELECT id FROM threads WHERE archived = 0 AND source = 'vscode'
              AND history_mode = 'paginated'
              AND ((creator_user_id = ? AND creator_account_id = ?)
                   OR (creator_user_id IS NULL AND creator_account_id IS NULL))
              ORDER BY recency_at_ms DESC LIMIT 100
            """)
        defer { sqlite3_finalize(candidates) }
        bindValue(principal.userID, to: candidates, index: 1)
        bindValue(principal.accountID, to: candidates, index: 2)
        var ids = retainingIDs
        while try step(candidates) {
            if let id = string(candidates, 0), UUID(uuidString: id) != nil { ids.insert(id) }
        }
        let thread = try prepare(state, """
            SELECT COALESCE(NULLIF(t.name, ''), t.title), t.archived, t.source,
                   t.history_mode, t.updated_at, r.first_unread_turn, r.last_published_turn,
                   t.creator_user_id, t.creator_account_id
            FROM threads t LEFT JOIN thread_read_receipts r ON r.thread_id = t.id WHERE t.id = ?
            """)
        defer { sqlite3_finalize(thread) }
        let turn = try prepare(history, """
            SELECT turn_id, status, started_at, completed_at FROM thread_turns
            WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 1
            """)
        defer { sqlite3_finalize(turn) }
        let priorTurn = try prepare(history, """
            SELECT status, started_at, completed_at FROM thread_turns WHERE thread_id = ? AND turn_id = ?
            """)
        defer { sqlite3_finalize(priorTurn) }
        var result = Snapshot(activities: [], readIDs: [], archivedIDs: [])
        for id in ids {
            bind(id, to: thread)
            guard try step(thread) else { continue }
            let ownerUser = string(thread, 7), ownerAccount = string(thread, 8)
            let legacy = ownerUser == nil && ownerAccount == nil
            guard legacy || (ownerUser == principal.userID && ownerAccount == principal.accountID) else { continue }
            if sqlite3_column_int(thread, 1) != 0 {
                result.archivedIDs.insert(id)
                continue
            }
            guard string(thread, 2) == "vscode", string(thread, 3) == "paginated" else { continue }
            bind(id, to: turn)
            guard try step(turn), let turnID = string(turn, 0),
                  let status = string(turn, 1),
                  ["inProgress", "completed", "failed", "interrupted"].contains(status),
                  sqlite3_column_type(turn, 2) != SQLITE_NULL else { continue }
            let started = sqlite3_column_double(turn, 2)
            let completed = sqlite3_column_type(turn, 3) == SQLITE_NULL ? nil : sqlite3_column_double(turn, 3)
            guard started > 0, started <= now.timeIntervalSince1970 + 5 else { continue }
            let active = status == "inProgress"
            // Older desktop chats have no creator columns populated. Restrict
            // those shared local records to this desktop/account observation
            // session; never infer ownership from email, title, or plan.
            if legacy && started < (legacyNotBefore ?? desktopLaunchedAt).timeIntervalSince1970 - 5 { continue }
            if let observed = observedTurns[id], observed.id != turnID, observed.status == "inProgress" {
                bind(id, to: priorTurn)
                bindValue(observed.id, to: priorTurn, index: 2)
                if try step(priorTurn), let priorStatus = string(priorTurn, 0),
                   ["completed", "failed", "interrupted"].contains(priorStatus) {
                    let wasRead = string(thread, 6) == observed.id && string(thread, 5) == nil
                    if wasRead { result.previousReadIDs.insert(id) }
                    let ended = sqlite3_column_type(priorTurn, 2) == SQLITE_NULL
                        ? now.timeIntervalSince1970 : sqlite3_column_double(priorTurn, 2)
                    result.previousTurns.append(ThreadActivity(id: id,
                        title: string(thread, 0) ?? L10n.text("Codex 채팅"), runtime: "idle",
                        latestTurn: ThreadTurnState(key: observed.id, id: observed.id, status: priorStatus,
                            startedAtMs: observed.startedAtMs),
                        unread: priorStatus == "completed" && !wasRead, updatedAt: ended))
                }
            }
            // An abandoned inProgress row is not proof of a live task after a
            // desktop restart. A time limit never converts it into completion.
            if active && started < desktopLaunchedAt.timeIntervalSince1970 - 5 { continue }
            let read = !active && string(thread, 6) == turnID && string(thread, 5) == nil
            if read { result.readIDs.insert(id) }
            let updated = sqlite3_column_double(thread, 4)
            var row = ThreadActivity(id: id, title: string(thread, 0) ?? L10n.text("Codex 채팅"),
                runtime: active ? "active" : "idle",
                latestTurn: ThreadTurnState(key: turnID, id: turnID, status: status, startedAtMs: started * 1000),
                unread: !active && status == "completed" && string(thread, 6) == turnID && string(thread, 5) != nil,
                updatedAt: max(started, completed ?? updated))
            // History cannot prove liveness during a long gap. Keep the row as
            // unconfirmed instead of spinning forever or sending a false finish.
            row.stateConfirmed = !active || now.timeIntervalSince1970 - updated <= 120
            result.activities.append(row)
        }
        return result
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw ReadError.unavailable
        }
        sqlite3_busy_timeout(db, 100)
        return db
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw ReadError.unsupportedSchema
        }
        return statement
    }

    private static func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw ReadError.unavailable
        }
    }

    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private static func bind(_ id: String, to statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bindValue(id, to: statement, index: 1)
    }

    private static func bindValue(_ value: String, to statement: OpaquePointer, index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
}
