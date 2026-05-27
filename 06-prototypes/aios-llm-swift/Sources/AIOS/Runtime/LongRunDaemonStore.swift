import Foundation

struct LongRunDaemonState: Codable {
    let id: String
    let status: String
    let tickCount: Int
    let lastTickAt: String
    let queuedRuns: [String]
    let readyRuns: [String]
    let scheduledRuns: [String]
    let completedRuns: [String]
    let waitingGraphs: [String]
    let runningRuns: [String]?
    let pausedRuns: [String]?
    let failedRuns: [String]?
    let residentSessions: [String]?
    let residentTicks: [String]?
    let routineJobs: [String]?
    let routineFires: [String]?
    let nextWakeAt: String?

    var dictionary: [String: String] {
        [
            "id": id,
            "status": status,
            "tick_count": "\(tickCount)",
            "last_tick_at": lastTickAt,
            "queued_runs": queuedRuns.joined(separator: ","),
            "ready_runs": readyRuns.joined(separator: ","),
            "scheduled_runs": scheduledRuns.joined(separator: ","),
            "completed_runs": completedRuns.joined(separator: ","),
            "waiting_graphs": waitingGraphs.joined(separator: ","),
            "running_runs": (runningRuns ?? []).joined(separator: ","),
            "paused_runs": (pausedRuns ?? []).joined(separator: ","),
            "failed_runs": (failedRuns ?? []).joined(separator: ","),
            "resident_sessions": (residentSessions ?? []).joined(separator: ","),
            "resident_ticks": (residentTicks ?? []).joined(separator: ","),
            "routine_jobs": (routineJobs ?? []).joined(separator: ","),
            "routine_fires": (routineFires ?? []).joined(separator: ","),
            "next_wake_at": nextWakeAt ?? ""
        ]
    }
}

struct LongRunDaemonStore {
    static var stateURL: URL {
        EventStore.rootURL.appendingPathComponent("long-run-daemon.json")
    }

    static func status() -> LongRunDaemonState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(LongRunDaemonState.self, from: data)
        else {
            return LongRunDaemonState(id: "default", status: "idle", tickCount: 0, lastTickAt: "", queuedRuns: [], readyRuns: [], scheduledRuns: [], completedRuns: [], waitingGraphs: [], runningRuns: [], pausedRuns: [], failedRuns: [], residentSessions: [], residentTicks: [], routineJobs: [], routineFires: [], nextWakeAt: nil)
        }
        return state
    }

    @discardableResult
    static func tick() throws -> LongRunDaemonState {
        let previous = status()
        let residentTicks = (try? ResidentAgentStore.tickDueSessions()) ?? []
        let routineFires = (try? RoutineStore.tick()) ?? []
        let graphTicks = try TaskGraphStore.tick()
        let queue = TaskQueue.list()
        let ready = queue.filter(\.ready).map(\.id)
        let future = queue.filter { !$0.ready }.map(\.id)
        let runs = (try? EventStore.listRuns()) ?? []
        let scheduled = unique(graphTicks.flatMap(\.scheduled) + future)
        let running = runs.filter { $0.status == "running" }.prefix(50).map(\.id)
        let paused = runs.filter { $0.status == "paused" || $0.status == "scheduled" }.prefix(50).map(\.id)
        let failed = runs.filter { $0.status == "failed" || $0.status == "incomplete" }.prefix(50).map(\.id)
        let completed = runs.filter { $0.status == "complete" }.prefix(50).map(\.id)
        let waiting = TaskGraphStore.list().filter { graph in
            graph.nodes.contains { $0.status == "waiting" || $0.status == "queued" || $0.status == "running" }
        }.map(\.id)
        let residentStatus = ResidentAgentStore.status(limit: 50)
        let residentIDs = parseResidentSessionIDs(residentStatus["sessions"] ?? "[]")
        let routines = RoutineStore.list().filter(\.enabled)
        let wakeCandidates = queue.compactMap(\.notBefore).filter { value in
            guard let date = isoDate(from: value) else { return false }
            return date > Date()
        } + parseResidentNextWakeValues(residentStatus["sessions"] ?? "[]") + RoutineStore.nextWakeValues()
        let sortedWakeCandidates = wakeCandidates.sorted()
        let state = LongRunDaemonState(
            id: "default",
            status: waiting.isEmpty && scheduled.isEmpty && ready.isEmpty && running.isEmpty && residentIDs.isEmpty && routines.isEmpty ? "idle" : "active",
            tickCount: previous.tickCount + 1,
            lastTickAt: isoDateString(Date()),
            queuedRuns: queue.map(\.id),
            readyRuns: ready,
            scheduledRuns: scheduled,
            completedRuns: Array(completed),
            waitingGraphs: waiting,
            runningRuns: Array(running),
            pausedRuns: Array(paused),
            failedRuns: Array(failed),
            residentSessions: residentIDs,
            residentTicks: residentTicks.compactMap { row in
                guard let raw = row["session"], let data = raw.data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return row["status"] }
                return string(decoded["id"]) ?? row["status"]
            },
            routineJobs: routines.map(\.id),
            routineFires: routineFires.map(\.runID),
            nextWakeAt: sortedWakeCandidates.first
        )
        try write(state)
        return state
    }

    static func schedule(goal: String, afterSeconds: Double = 0) throws -> [String: String] {
        let notBefore = isoDateString(Date().addingTimeInterval(max(0, afterSeconds)))
        let runID = try TaskQueue.submit(goal: goal, notBefore: notBefore)
        return ["run_id": runID, "goal": goal, "not_before": notBefore, "status": "queued"]
    }

    private static func write(_ state: LongRunDaemonState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: [.atomic])
    }

    private static func parseResidentSessionIDs(_ sessionsJSON: String) -> [String] {
        guard let data = sessionsJSON.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            let status = string(row["status"]) ?? ""
            guard status != "complete", status != "canceled" else { return nil }
            return string(row["id"])
        }
    }

    private static func parseResidentNextWakeValues(_ sessionsJSON: String) -> [String] {
        guard let data = sessionsJSON.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let value = string(row["next_wake_at"]),
                  !value.isEmpty,
                  let date = isoDate(from: value),
                  date > Date()
            else { return nil }
            return value
        }
    }
}
