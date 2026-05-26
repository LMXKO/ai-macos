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
            "context_pack": contextPack,
            "created_at": createdAt,
            "updated_at": updatedAt
        ]
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
            contextPack: jsonStringValue(MemoryIndexStore.contextPack(query: goal, limit: 8)),
            createdAt: now,
            updatedAt: now
        )
        try upsert(session)
        return [
            "schema": "aios.resident_agent.plan.v1",
            "session": jsonStringValue(session.dictionary),
            "task_graph": jsonStringValue(graph.dictionary),
            "runtime_contract": "durable session + task graph + daemon ticks + cockpit interrupts + memory context pack; each tick advances one role and may requeue itself"
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
        let packet = try AgentRoleSystem.recordHandoff(
            goal: session.goal,
            fromRole: session.currentRole,
            toRole: nextRole,
            reason: evidence.isEmpty ? "resident agent tick \(session.tickCount + 1)" : evidence,
            context: [
                "session_id": session.id,
                "task_graph_id": session.taskGraphID
            ]
        )
        session.tickCount += 1
        session.currentRole = nextRole
        session.status = "active"
        session.contextPack = jsonStringValue(MemoryIndexStore.contextPack(query: session.goal, limit: 8))
        session.updatedAt = isoDateString(Date())
        sessions[index] = session
        try writeAll(sessions)
        _ = try? TaskGraphStore.tick(graphID: session.taskGraphID)
        return [
            "schema": "aios.resident_agent.tick.v1",
            "session": jsonStringValue(session.dictionary),
            "handoff": jsonStringValue(packet.dictionary),
            "status": "advanced"
        ]
    }

    static func status(limit: Int = 20) -> [String: String] {
        let sessions = readAll().sorted { $0.updatedAt > $1.updatedAt }.prefix(max(1, limit))
        return [
            "schema": "aios.resident_agent.status.v1",
            "sessions": jsonStringValue(sessions.map(\.dictionary)),
            "daemon": jsonStringValue(LongRunDaemonStore.status().dictionary),
            "state_machine": "active -> waiting -> tick -> handoff -> execute/verify/memory/runtime -> requeue or complete"
        ]
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
}
