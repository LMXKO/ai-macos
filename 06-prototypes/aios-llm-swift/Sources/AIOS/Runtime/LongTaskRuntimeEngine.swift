import Foundation

struct LongTaskRuntimeEngine {
    static func state(runID: String? = nil, limit: Int = 20) -> [String: String] {
        let daemon = LongRunDaemonStore.status().dictionary
        let queue = TaskQueue.list().prefix(limit).map(\.dictionary)
        let graphs = TaskGraphStore.list().prefix(limit).map(\.dictionary)
        let commands = CockpitControlStore.list(runID: runID).prefix(limit).map(\.dictionary)
        var runPayload = ""
        if let runID, let summary = try? EventStore.readSummary(runID: runID) {
            let runDir = EventStore.runsURL.appendingPathComponent(runID, isDirectory: true)
            let store = EventStore(runID: runID, goal: summary.goal, dir: runDir, eventsURL: URL(fileURLWithPath: summary.eventsPath), summaryURL: runDir.appendingPathComponent("summary.json"))
            let checkpoint = store.loadCheckpoint().flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            runPayload = jsonStringValue([
                "id": summary.id,
                "goal": summary.goal,
                "status": summary.status,
                "updated_at": summary.updatedAt,
                "checkpoint": checkpoint ?? [:]
            ])
        }
        return [
            "schema": "aios.long_task.runtime_state.v1",
            "run": runPayload,
            "daemon": jsonStringValue(daemon),
            "queue": jsonStringValue(Array(queue)),
            "task_graphs": jsonStringValue(Array(graphs)),
            "commands": jsonStringValue(Array(commands)),
            "state_machine": "queued -> scheduled -> running -> waiting|paused|complete|failed|canceled; user feedback can replan/branch/resume"
        ]
    }

    static func watch(goal: String, condition: String, value: String, title: String = "") throws -> [String: String] {
        let now = isoDateString(Date())
        let node = DurableTaskNode(
            id: "W1",
            title: title.isEmpty ? "Watch condition" : title,
            goal: goal,
            status: "waiting",
            dependsOn: [],
            runID: nil,
            waitCondition: condition,
            waitValue: value,
            notBefore: nil,
            attempts: 0,
            updatedAt: now
        )
        let graph = try TaskGraphStore.create(title: title.isEmpty ? goal : title, goal: goal, nodes: [node])
        return [
            "schema": "aios.long_task.watch.v1",
            "graph_id": graph.id,
            "condition": condition,
            "value": value,
            "status": graph.status,
            "graph": jsonStringValue(graph.dictionary)
        ]
    }

    static func interrupt(runID: String, instruction: String, mode: String = "replan") throws -> [String: String] {
        let command = mode.isEmpty ? "replan" : mode
        let item = try CockpitControlStore.record(runID: runID, command: command, feedback: instruction)
        return [
            "schema": "aios.long_task.interrupt.v1",
            "run_id": runID,
            "command": command,
            "status": item.status,
            "command_id": item.id,
            "feedback": instruction
        ]
    }
}
