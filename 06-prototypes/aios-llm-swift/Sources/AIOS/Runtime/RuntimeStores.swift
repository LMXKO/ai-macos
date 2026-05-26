import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Security
import ScriptingBridge
import SQLite3
import SwiftUI
import Vision

struct EventStore {
    struct RunSummary {
        let id: String
        let goal: String
        let createdAt: String
        let updatedAt: String
        let status: String
        let eventsPath: String
    }

    let runID: String
    let goal: String
    let dir: URL
    let eventsURL: URL
    let summaryURL: URL

    static var rootURL: URL {
        let override = ProcessInfo.processInfo.environment["AIOS_STATE_DIR"]
        let raw = override?.expandingTildeInPath ?? "\(NSHomeDirectory())/Library/Application Support/AIOS"
        return URL(fileURLWithPath: raw)
    }

    static var queueURL: URL {
        rootURL.appendingPathComponent("queue", isDirectory: true)
    }

    static var runsURL: URL {
        rootURL.appendingPathComponent("runs", isDirectory: true)
    }

    static var snapshotsURL: URL {
        rootURL.appendingPathComponent("snapshots", isDirectory: true)
    }

    static var recipesURL: URL {
        rootURL.appendingPathComponent("recipes", isDirectory: true)
    }

    static var evalsURL: URL {
        rootURL.appendingPathComponent("evals", isDirectory: true)
    }

    static var learningURL: URL {
        rootURL.appendingPathComponent("learning", isDirectory: true)
    }

    static var approvalsURL: URL {
        rootURL.appendingPathComponent("approvals", isDirectory: true)
    }

    static var memoryURL: URL {
        rootURL.appendingPathComponent("memory", isDirectory: true)
    }

    static var episodesURL: URL {
        rootURL.appendingPathComponent("episodes", isDirectory: true)
    }

    static var contextGraphURL: URL {
        rootURL.appendingPathComponent("context-graph", isDirectory: true)
    }

    static var appSkillsURL: URL {
        rootURL.appendingPathComponent("app-skills", isDirectory: true)
    }

    static var trajectoriesURL: URL {
        rootURL.appendingPathComponent("trajectories", isDirectory: true)
    }

    static var auditURL: URL {
        rootURL.appendingPathComponent("audit.jsonl")
    }

    var checkpointURL: URL {
        dir.appendingPathComponent("checkpoint.json")
    }

    static func start(goal: String, runID: String = UUID().uuidString) throws -> EventStore {
        let dir = runsURL.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EventStore(
            runID: runID,
            goal: goal,
            dir: dir,
            eventsURL: dir.appendingPathComponent("events.jsonl"),
            summaryURL: dir.appendingPathComponent("summary.json")
        )
        try store.updateStatus("running")
        try store.append("RunStarted", [
            "run_id": runID,
            "goal": goal
        ])
        return store
    }

    static func createQueued(goal: String, runID: String) throws -> EventStore {
        let dir = runsURL.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EventStore(
            runID: runID,
            goal: goal,
            dir: dir,
            eventsURL: dir.appendingPathComponent("events.jsonl"),
            summaryURL: dir.appendingPathComponent("summary.json")
        )
        try store.updateStatus("queued")
        try store.append("QueueSubmitted", [
            "run_id": runID,
            "goal": goal
        ])
        return store
    }

    func append(_ event: String, _ fields: [String: String]) throws {
        var payload = fields
        payload["event"] = event
        payload["run_id"] = runID
        payload["time"] = isoDateString(Date())
        let line = jsonLine(payload) + "\n"
        if FileManager.default.fileExists(atPath: eventsURL.path) {
            let handle = try FileHandle(forWritingTo: eventsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: eventsURL, atomically: true, encoding: .utf8)
        }
    }

    func updateStatus(_ status: String) throws {
        let existing: [String: Any]? = {
            guard let data = try? Data(contentsOf: summaryURL),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return raw
        }()
        let existingCreatedAt = string(existing?["created_at"])
        let existingStatus = string(existing?["status"]) ?? ""
        let parkedStatuses: Set<String> = ["paused", "scheduled"]
        let finalStatus = parkedStatuses.contains(existingStatus) && status == "incomplete" ? existingStatus : status
        let now = isoDateString(Date())
        let summary: [String: String] = [
            "id": runID,
            "goal": goal,
            "created_at": existingCreatedAt ?? now,
            "updated_at": now,
            "status": finalStatus,
            "events_path": eventsURL.path
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: summaryURL)
        try? SQLiteRunIndex.upsert(RunSummary(
            id: runID,
            goal: goal,
            createdAt: existingCreatedAt ?? now,
            updatedAt: now,
            status: finalStatus,
            eventsPath: eventsURL.path
        ))
    }

    static func listRuns() throws -> [RunSummary] {
        if let indexed = try? SQLiteRunIndex.list(), !indexed.isEmpty {
            return indexed
        }
        guard FileManager.default.fileExists(atPath: runsURL.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        let runs = dirs.compactMap { dir -> RunSummary? in
            let summaryURL = dir.appendingPathComponent("summary.json")
            guard let data = try? Data(contentsOf: summaryURL),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return RunSummary(
                id: string(raw["id"]) ?? dir.lastPathComponent,
                goal: string(raw["goal"]) ?? "",
                createdAt: string(raw["created_at"]) ?? "",
                updatedAt: string(raw["updated_at"]) ?? "",
                status: string(raw["status"]) ?? "",
                eventsPath: string(raw["events_path"]) ?? ""
            )
        }
        try? SQLiteRunIndex.rebuild(from: runs)
        return runs.sorted { $0.createdAt > $1.createdAt }
    }

    static func readSummary(runID: String) throws -> RunSummary {
        let dir = runsURL.appendingPathComponent(runID, isDirectory: true)
        let summaryURL = dir.appendingPathComponent("summary.json")
        let data = try Data(contentsOf: summaryURL)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeError("Invalid summary JSON for \(runID)")
        }
        return RunSummary(
            id: string(raw["id"]) ?? runID,
            goal: string(raw["goal"]) ?? "",
            createdAt: string(raw["created_at"]) ?? "",
            updatedAt: string(raw["updated_at"]) ?? "",
            status: string(raw["status"]) ?? "",
            eventsPath: string(raw["events_path"]) ?? ""
        )
    }

    static func readEventsText(runID: String) throws -> String {
        let url = runsURL.appendingPathComponent(runID, isDirectory: true).appendingPathComponent("events.jsonl")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func saveCheckpoint(_ checkpoint: AgentCheckpoint) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checkpoint).write(to: checkpointURL, options: [.atomic])
    }

    func loadCheckpoint() -> AgentCheckpoint? {
        guard FileManager.default.fileExists(atPath: checkpointURL.path),
              let data = try? Data(contentsOf: checkpointURL)
        else { return nil }
        return try? JSONDecoder().decode(AgentCheckpoint.self, from: data)
    }

    func clearCheckpoint() {
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return }
        try? FileManager.default.removeItem(at: checkpointURL)
    }

    static func markRun(runID: String, status: String, event: String, fields: [String: String]) throws {
        let summary = try readSummary(runID: runID)
        let store = EventStore(
            runID: runID,
            goal: summary.goal,
            dir: runsURL.appendingPathComponent(runID, isDirectory: true),
            eventsURL: runsURL.appendingPathComponent(runID, isDirectory: true).appendingPathComponent("events.jsonl"),
            summaryURL: runsURL.appendingPathComponent(runID, isDirectory: true).appendingPathComponent("summary.json")
        )
        try store.append(event, fields)
        try store.updateStatus(status)
    }
}

struct AgentCheckpoint: Codable {
    let version: Int
    let goal: String
    var plan: TaskPlan
    var round: Int
    var executedActionCount: Int
    var submittedExternalSends: [String]
    var verificationState: CompletionContractState
    var finished: Bool
    var updatedAt: String

    init(
        goal: String,
        plan: TaskPlan,
        round: Int,
        executedActionCount: Int,
        submittedExternalSends: [String],
        verificationState: CompletionContractState,
        finished: Bool = false
    ) {
        self.version = 1
        self.goal = goal
        self.plan = plan
        self.round = round
        self.executedActionCount = executedActionCount
        self.submittedExternalSends = submittedExternalSends.sorted()
        self.verificationState = verificationState
        self.finished = finished
        self.updatedAt = isoDateString(Date())
    }
}

struct SQLiteRunIndex {
    static var url: URL {
        EventStore.rootURL.appendingPathComponent("runs.sqlite")
    }

    static func upsert(_ summary: EventStore.RunSummary) throws {
        try withDatabase { db in
            try prepareSchema(db)
            let sql = """
            INSERT INTO runs(id, goal, status, created_at, updated_at, events_path)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              goal=excluded.goal,
              status=excluded.status,
              created_at=excluded.created_at,
              updated_at=excluded.updated_at,
              events_path=excluded.events_path
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RuntimeError(sqliteError(db))
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, summary.id)
            bindText(statement, 2, summary.goal)
            bindText(statement, 3, summary.status)
            bindText(statement, 4, summary.createdAt)
            bindText(statement, 5, summary.updatedAt)
            bindText(statement, 6, summary.eventsPath)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RuntimeError(sqliteError(db))
            }
        }
    }

    static func list(limit: Int = 500) throws -> [EventStore.RunSummary] {
        try withDatabase { db in
            try prepareSchema(db)
            let sql = """
            SELECT id, goal, created_at, updated_at, status, events_path
            FROM runs
            ORDER BY created_at DESC
            LIMIT ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RuntimeError(sqliteError(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [EventStore.RunSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(EventStore.RunSummary(
                    id: columnText(statement, 0),
                    goal: columnText(statement, 1),
                    createdAt: columnText(statement, 2),
                    updatedAt: columnText(statement, 3),
                    status: columnText(statement, 4),
                    eventsPath: columnText(statement, 5)
                ))
            }
            return rows
        }
    }

    static func rebuild(from summaries: [EventStore.RunSummary]) throws {
        guard !summaries.isEmpty else { return }
        try withDatabase { db in
            try prepareSchema(db)
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw RuntimeError(sqliteError(db))
            }
            do {
                for summary in summaries {
                    try upsert(summary, in: db)
                }
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw RuntimeError(sqliteError(db))
                }
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    private static func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: EventStore.rootURL, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw RuntimeError(sqliteError(db))
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static func prepareSchema(_ db: OpaquePointer?) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS runs(
          id TEXT PRIMARY KEY,
          goal TEXT NOT NULL,
          status TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          events_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_runs_created_at ON runs(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw RuntimeError(sqliteError(db))
        }
    }

    private static func upsert(_ summary: EventStore.RunSummary, in db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO runs(id, goal, status, created_at, updated_at, events_path)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          goal=excluded.goal,
          status=excluded.status,
          created_at=excluded.created_at,
          updated_at=excluded.updated_at,
          events_path=excluded.events_path
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RuntimeError(sqliteError(db))
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, summary.id)
        bindText(statement, 2, summary.goal)
        bindText(statement, 3, summary.status)
        bindText(statement, 4, summary.createdAt)
        bindText(statement, 5, summary.updatedAt)
        bindText(statement, 6, summary.eventsPath)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RuntimeError(sqliteError(db))
        }
    }

    private static func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor())
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private static func sqliteError(_ db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else { return "sqlite error" }
        return String(cString: message)
    }
}

struct TaskQueueItem {
    let id: String
    let goal: String
    let notBefore: String?
    let createdAt: String
    let url: URL

    var ready: Bool {
        guard let notBefore, let date = isoDate(from: notBefore) else { return true }
        return date <= Date()
    }

    var dictionary: [String: String] {
        [
            "id": id,
            "goal": goal,
            "not_before": notBefore ?? "",
            "created_at": createdAt,
            "ready": ready ? "true" : "false",
            "path": url.path
        ]
    }
}

struct TaskQueue {
    static func submit(goal: String, notBefore: String? = nil) throws -> String {
        try FileManager.default.createDirectory(at: EventStore.queueURL, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try write(id: id, goal: goal, notBefore: notBefore)
        let store = try EventStore.createQueued(goal: goal, runID: id)
        if let notBefore {
            try? store.updateStatus("scheduled")
            try? store.append("RunScheduled", ["not_before": notBefore])
        }
        return id
    }

    static func submitExisting(runID: String, goal: String, notBefore: String? = nil) throws {
        try FileManager.default.createDirectory(at: EventStore.queueURL, withIntermediateDirectories: true)
        try write(id: runID, goal: goal, notBefore: notBefore)
        var fields: [String: String] = [:]
        if let notBefore { fields["not_before"] = notBefore }
        try? EventStore.markRun(runID: runID, status: notBefore == nil ? "queued" : "scheduled", event: "RunResumeQueued", fields: fields)
    }

    private static func write(id: String, goal: String, notBefore: String?) throws {
        let url = EventStore.queueURL.appendingPathComponent("\(id).json")
        var item: [String: String] = [
            "id": id,
            "goal": goal,
            "created_at": isoDateString(Date())
        ]
        if let notBefore {
            item["not_before"] = notBefore
        }
        let data = try JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    static func list() -> [TaskQueueItem] {
        guard FileManager.default.fileExists(atPath: EventStore.queueURL.path),
              let urls = try? FileManager.default.contentsOfDirectory(at: EventStore.queueURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let goal = string(raw["goal"])
                else { return nil }
                return TaskQueueItem(
                    id: string(raw["id"]) ?? url.deletingPathExtension().lastPathComponent,
                    goal: goal,
                    notBefore: string(raw["not_before"]),
                    createdAt: string(raw["created_at"]) ?? "",
                    url: url
                )
            }
    }

    static func next() throws -> (id: String, goal: String, url: URL)? {
        guard FileManager.default.fileExists(atPath: EventStore.queueURL.path) else { return nil }
        let urls = try FileManager.default.contentsOfDirectory(at: EventStore.queueURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let goal = string(raw["goal"])
            else { continue }
            if let notBefore = string(raw["not_before"]),
               let date = isoDate(from: notBefore),
               date > Date() {
                continue
            }
            return (string(raw["id"]) ?? url.deletingPathExtension().lastPathComponent, goal, url)
        }
        return nil
    }

    static func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    static func cancel(_ id: String) throws {
        let url = EventStore.queueURL.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

struct AuditLog {
    static func append(action: String, fields: [String: String]) {
        do {
            try FileManager.default.createDirectory(at: EventStore.rootURL, withIntermediateDirectories: true)
            var payload = fields
            payload["action"] = action
            payload["time"] = isoDateString(Date())
            let line = jsonLine(payload) + "\n"
            if FileManager.default.fileExists(atPath: EventStore.auditURL.path) {
                let handle = try FileHandle(forWritingTo: EventStore.auditURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: EventStore.auditURL, atomically: true, encoding: .utf8)
            }
        } catch {
            fputs("audit failed: \(error.localizedDescription)\n", stderr)
        }
    }

    static func readText(limit: Int = 200) -> String {
        guard let text = try? String(contentsOf: EventStore.auditURL, encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.suffix(limit).joined(separator: "\n")
    }
}
