import Foundation

struct ResidentAgentSession: Codable {
    var id: String
    var goal: String
    var status: String
    var route: [String]
    var currentRole: String
    var tickCount: Int
    var taskGraphID: String
    var nextWakeAt: String
    var lastRunID: String?
    var cadenceSeconds: Int?
    var contextPack: String
    var createdAt: String
    var updatedAt: String

    var dictionary: [String: String] {
        [
            "id": id,
            "goal": goal,
            "status": status,
            "route": route.joined(separator: ","),
            "current_role": currentRole,
            "tick_count": "\(tickCount)",
            "task_graph_id": taskGraphID,
            "next_wake_at": nextWakeAt,
            "last_run_id": lastRunID ?? "",
            "cadence_seconds": "\(cadenceSeconds ?? 60)",
            "context_pack": contextPack,
            "created_at": createdAt,
            "updated_at": updatedAt
        ]
    }
}

struct ResidentAgentObservationStore {
    static var url: URL {
        EventStore.rootURL.appendingPathComponent("resident-agent-observations.jsonl")
    }

    static func append(_ row: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = jsonStringValue(row) + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func recent(sessionID: String? = nil, limit: Int = 20) -> [[String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let row = raw.compactMapValues { value -> String? in
                if let value = value as? String { return value }
                if let value = value as? NSNumber { return value.stringValue }
                return nil
            }
            if let sessionID, !sessionID.isEmpty, row["session_id"] != sessionID {
                return nil
            }
            return row
        }
        .suffix(max(1, limit))
        .reversed()
    }
}

struct ResidentAgentStore {
    static var url: URL {
        EventStore.rootURL.appendingPathComponent("resident-agent-sessions.json")
    }

    static func plan(goal: String, app: String = "", surface: String = "", wakeAfterSeconds: Int = 0) throws -> [String: String] {
        let route = AgentRoleSystem.plan(goal: goal, app: app, surface: surface).compactMap { $0["id"] }
        let graph = try TaskGraphStore.create(
            title: "Resident: \(goal)",
            goal: goal,
            nodes: [
                DurableTaskNode(
                    id: "R1",
                    title: "Resident agent tick",
                    goal: goal,
                    status: wakeAfterSeconds > 0 ? "waiting" : "queued",
                    dependsOn: [],
                    runID: nil,
                    waitCondition: wakeAfterSeconds > 0 ? "time" : nil,
                    waitValue: wakeAfterSeconds > 0 ? isoDateString(Date().addingTimeInterval(TimeInterval(wakeAfterSeconds))) : nil,
                    notBefore: wakeAfterSeconds > 0 ? isoDateString(Date().addingTimeInterval(TimeInterval(wakeAfterSeconds))) : nil,
                    attempts: 0,
                    updatedAt: isoDateString(Date())
                )
            ]
        )
        let now = isoDateString(Date())
        let session = ResidentAgentSession(
            id: "resident-\(normalizeID(goal))-\(UUID().uuidString.prefix(8))",
            goal: goal,
            status: wakeAfterSeconds > 0 ? "waiting" : "active",
            route: route,
            currentRole: route.first ?? "planner",
            tickCount: 0,
            taskGraphID: graph.id,
            nextWakeAt: wakeAfterSeconds > 0 ? isoDateString(Date().addingTimeInterval(TimeInterval(wakeAfterSeconds))) : "",
            lastRunID: nil,
            cadenceSeconds: max(15, wakeAfterSeconds > 0 ? wakeAfterSeconds : 60),
            contextPack: jsonStringValue(MemoryIndexStore.contextPack(query: goal, limit: 8)),
            createdAt: now,
            updatedAt: now
        )
        try upsert(session)
        return [
            "schema": "aios.resident_agent.plan.v1",
            "session": jsonStringValue(session.dictionary),
            "task_graph": jsonStringValue(graph.dictionary),
            "runtime_contract": "durable session + task graph + daemon ticks + cockpit interrupts + memory context pack; each tick observes state, advances one role, schedules ready graph nodes, and records a durable observation"
        ]
    }

    static func tick(sessionID: String? = nil, evidence: String = "") throws -> [String: String] {
        var sessions = readAll()
        guard let index = selectedIndex(sessionID: sessionID, sessions: sessions) else {
            return [
                "schema": "aios.resident_agent.tick.v1",
                "status": "idle",
                "reason": "no resident agent session found"
            ]
        }
        var session = sessions[index]
        if !session.nextWakeAt.isEmpty, let wake = isoDate(from: session.nextWakeAt), wake > Date() {
            return [
                "schema": "aios.resident_agent.tick.v1",
                "session": jsonStringValue(session.dictionary),
                "status": "waiting",
                "next_wake_at": session.nextWakeAt
            ]
        }
        let route = session.route.isEmpty ? ["planner", "executor", "verifier", "memory_curator", "runtime_operator"] : session.route
        let currentIndex = route.firstIndex(of: session.currentRole) ?? 0
        let nextRole = route.indices.contains(currentIndex + 1) ? route[currentIndex + 1] : route.first ?? "planner"
        let graphTicks = (try? TaskGraphStore.tick(graphID: session.taskGraphID)) ?? []
        let graph = try? TaskGraphStore.read(session.taskGraphID)
        let graphRuns = graph?.nodes.compactMap(\.runID) ?? []
        let selectedRunID = latestActiveRunID(preferred: session.lastRunID, graphRuns: graphRuns, goal: session.goal)
        let commands = selectedRunID.map { CockpitControlStore.list(runID: $0).prefix(5).map(\.dictionary) } ?? []
        let daemon = LongRunDaemonStore.status().dictionary
        let queue = TaskQueue.list().prefix(12).map(\.dictionary)
        let contextPack = MemoryIndexStore.contextPack(query: session.goal, limit: 8)
        let packet = try AgentRoleSystem.recordHandoff(
            goal: session.goal,
            fromRole: session.currentRole,
            toRole: nextRole,
            reason: evidence.isEmpty ? "resident agent tick \(session.tickCount + 1)" : evidence,
            context: [
                "session_id": session.id,
                "task_graph_id": session.taskGraphID,
                "last_run_id": selectedRunID ?? ""
            ]
        )
        session.tickCount += 1
        session.currentRole = nextRole
        session.lastRunID = selectedRunID
        session.status = graph?.status == "complete" ? "complete" : graph?.status == "failed" ? "blocked" : "active"
        let cadence = max(15, session.cadenceSeconds ?? 60)
        session.nextWakeAt = session.status == "complete" ? "" : isoDateString(Date().addingTimeInterval(TimeInterval(cadence)))
        session.contextPack = jsonStringValue(contextPack)
        session.updatedAt = isoDateString(Date())
        sessions[index] = session
        try writeAll(sessions)
        let observation: [String: String] = [
            "schema": "aios.resident_agent.observation.v1",
            "session_id": session.id,
            "goal": session.goal,
            "status": session.status,
            "tick_count": "\(session.tickCount)",
            "current_role": session.currentRole,
            "last_run_id": selectedRunID ?? "",
            "task_graph_id": session.taskGraphID,
            "graph_status": graph?.status ?? "",
            "graph_ticks": jsonStringValue(graphTicks.map(\.dictionary)),
            "commands": jsonStringValue(commands),
            "queue": jsonStringValue(Array(queue)),
            "daemon": jsonStringValue(daemon),
            "context_pack": jsonStringValue(contextPack),
            "handoff": jsonStringValue(packet.dictionary),
            "created_at": isoDateString(Date())
        ]
        try? ResidentAgentObservationStore.append(observation)
        return [
            "schema": "aios.resident_agent.tick.v1",
            "session": jsonStringValue(session.dictionary),
            "handoff": jsonStringValue(packet.dictionary),
            "graph_ticks": jsonStringValue(graphTicks.map(\.dictionary)),
            "observation": jsonStringValue(observation),
            "status": "advanced"
        ]
    }

    static func status(limit: Int = 20) -> [String: String] {
        let sessions = readAll().sorted { $0.updatedAt > $1.updatedAt }.prefix(max(1, limit))
        return [
            "schema": "aios.resident_agent.status.v1",
            "sessions": jsonStringValue(sessions.map(\.dictionary)),
            "observations": jsonStringValue(ResidentAgentObservationStore.recent(limit: limit)),
            "daemon": jsonStringValue(LongRunDaemonStore.status().dictionary),
            "state_machine": "active -> waiting -> tick -> handoff -> execute/verify/memory/runtime -> requeue or complete"
        ]
    }

    @discardableResult
    static func tickDueSessions(limit: Int = 6) throws -> [[String: String]] {
        let due = readAll().filter { session in
            guard session.status != "complete", session.status != "canceled" else { return false }
            guard !session.nextWakeAt.isEmpty, let wake = isoDate(from: session.nextWakeAt) else { return true }
            return wake <= Date()
        }
        .sorted { $0.updatedAt < $1.updatedAt }
        .prefix(max(1, limit))
        var results: [[String: String]] = []
        for session in due {
            results.append(try tick(sessionID: session.id, evidence: "daemon due resident tick"))
        }
        return results
    }

    private static func selectedIndex(sessionID: String?, sessions: [ResidentAgentSession]) -> Int? {
        if let sessionID, !sessionID.isEmpty {
            return sessions.firstIndex { $0.id == sessionID }
        }
        return sessions.enumerated()
            .filter { $0.element.status != "complete" && $0.element.status != "canceled" }
            .sorted { $0.element.updatedAt > $1.element.updatedAt }
            .first?.offset
    }

    private static func upsert(_ session: ResidentAgentSession) throws {
        var sessions = readAll()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        try writeAll(sessions)
    }

    private static func readAll() -> [ResidentAgentSession] {
        guard let data = try? Data(contentsOf: url),
              let sessions = try? JSONDecoder().decode([ResidentAgentSession].self, from: data)
        else { return [] }
        return sessions
    }

    private static func writeAll(_ sessions: [ResidentAgentSession]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sessions).write(to: url, options: [.atomic])
    }

    private static func latestActiveRunID(preferred: String?, graphRuns: [String], goal: String) -> String? {
        let candidates = unique(([preferred].compactMap { $0 }) + graphRuns)
        let summaries = candidates.compactMap { runID -> EventStore.RunSummary? in
            try? EventStore.readSummary(runID: runID)
        }
        if let active = summaries.first(where: { ["queued", "scheduled", "running", "paused", "incomplete"].contains($0.status) }) {
            return active.id
        }
        if let latest = summaries.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            return latest.id
        }
        let normalizedGoal = normalizeForSearch(goal)
        return ((try? EventStore.listRuns()) ?? [])
            .filter { run in
                let normalizedRunGoal = normalizeForSearch(run.goal)
                return normalizedRunGoal.contains(normalizedGoal) || normalizedGoal.contains(normalizedRunGoal)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?.id
    }
}
