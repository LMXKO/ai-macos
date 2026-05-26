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
            "waiting_graphs": waitingGraphs.joined(separator: ",")
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
            return LongRunDaemonState(id: "default", status: "idle", tickCount: 0, lastTickAt: "", queuedRuns: [], readyRuns: [], scheduledRuns: [], completedRuns: [], waitingGraphs: [])
        }
        return state
    }

    @discardableResult
    static func tick() throws -> LongRunDaemonState {
        let previous = status()
        let graphTicks = try TaskGraphStore.tick()
        let queue = TaskQueue.list()
        let ready = queue.filter(\.ready).map(\.id)
        let future = queue.filter { !$0.ready }.map(\.id)
        let runs = (try? EventStore.listRuns()) ?? []
        let scheduled = unique(graphTicks.flatMap(\.scheduled) + future)
        let completed = runs.filter { $0.status == "complete" }.prefix(50).map(\.id)
        let waiting = TaskGraphStore.list().filter { graph in
            graph.nodes.contains { $0.status == "waiting" || $0.status == "queued" || $0.status == "running" }
        }.map(\.id)
        let state = LongRunDaemonState(
            id: "default",
            status: waiting.isEmpty && scheduled.isEmpty && ready.isEmpty ? "idle" : "active",
            tickCount: previous.tickCount + 1,
            lastTickAt: isoDateString(Date()),
            queuedRuns: queue.map(\.id),
            readyRuns: ready,
            scheduledRuns: scheduled,
            completedRuns: Array(completed),
            waitingGraphs: waiting
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
}
