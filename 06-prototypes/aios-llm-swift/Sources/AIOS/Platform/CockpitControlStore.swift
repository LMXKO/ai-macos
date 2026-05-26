import Foundation

struct CockpitCommand: Codable {
    let id: String
    let runID: String
    let command: String
    let feedback: String
    let createdAt: String
    let status: String

    var dictionary: [String: String] {
        [
            "id": id,
            "run_id": runID,
            "command": command,
            "feedback": feedback,
            "created_at": createdAt,
            "status": status
        ]
    }
}

struct CockpitControlStore {
    static var commandsURL: URL {
        EventStore.rootURL.appendingPathComponent("cockpit-commands.json")
    }

    @discardableResult
    static func record(runID: String, command: String, feedback: String = "") throws -> CockpitCommand {
        var commands = list()
        let commandID = "cockpit-\(UUID().uuidString)"
        let normalizedCommand = normalizeID(command)
        let status = try apply(runID: runID, command: normalizedCommand, feedback: feedback, commandID: commandID)
        let item = CockpitCommand(
            id: commandID,
            runID: runID,
            command: normalizedCommand,
            feedback: feedback,
            createdAt: isoDateString(Date()),
            status: status
        )
        commands.append(item)
        try write(commands)
        return item
    }

    static func list(runID: String? = nil) -> [CockpitCommand] {
        guard let data = try? Data(contentsOf: commandsURL),
              let commands = try? JSONDecoder().decode([CockpitCommand].self, from: data)
        else { return [] }
        return commands
            .filter { runID == nil || $0.runID == runID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func liveState(limit: Int = 20) -> [String: String] {
        let runs = Array(((try? EventStore.listRuns()) ?? []).prefix(max(1, limit))).map { run in
            [
                "id": run.id,
                "goal": run.goal,
                "status": run.status,
                "updated_at": run.updatedAt
            ]
        }
        let queue = TaskQueue.list().prefix(limit).map(\.dictionary)
        let daemon = LongRunDaemonStore.status().dictionary
        let graphs = TaskGraphStore.list().prefix(limit).map(\.dictionary)
        let commands = list().prefix(limit).map(\.dictionary)
        return [
            "schema": "aios.cockpit.live.v1",
            "runs": jsonStringValue(runs),
            "queue": jsonStringValue(Array(queue)),
            "daemon": jsonStringValue(daemon),
            "task_graphs": jsonStringValue(Array(graphs)),
            "commands": jsonStringValue(Array(commands)),
            "controls": "pause,resume,feedback,replan,branch,stop",
            "updated_at": isoDateString(Date())
        ]
    }

    private static func apply(runID: String, command: String, feedback: String, commandID: String) throws -> String {
        let summary = try EventStore.readSummary(runID: runID)
        var fields = [
            "command_id": commandID,
            "command": command,
            "feedback": feedback
        ]
        switch command {
        case "pause":
            try? TaskQueue.cancel(runID)
            try EventStore.markRun(runID: runID, status: "paused", event: "CockpitCommand", fields: fields)
            return "applied"
        case "resume":
            try TaskQueue.submitExisting(runID: runID, goal: summary.goal, notBefore: nil)
            try EventStore.markRun(runID: runID, status: "queued", event: "CockpitCommand", fields: fields)
            return "applied"
        case "stop", "cancel":
            try? TaskQueue.cancel(runID)
            try EventStore.markRun(runID: runID, status: "canceled", event: "CockpitCommand", fields: fields)
            return "applied"
        case "feedback":
            try EventStore.markRun(runID: runID, status: summary.status, event: "UserFeedback", fields: fields)
            return "applied"
        case "replan":
            let goal = feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary.goal : "\(summary.goal)\nUser feedback: \(feedback)"
            try TaskQueue.submitExisting(runID: runID, goal: goal, notBefore: nil)
            try EventStore.markRun(runID: runID, status: "queued", event: "CockpitCommand", fields: fields)
            return "applied"
        case "branch":
            let points = (try? TrajectoryProductStore.resumePoints(runID: runID)) ?? []
            let index = points.last?.eventIndex ?? 1
            let branch = try TrajectoryProductStore.branch(runID: runID, fromIndex: index, goal: feedback)
            fields["branch_run_id"] = branch["branch_run_id"] ?? ""
            try EventStore.markRun(runID: runID, status: summary.status, event: "CockpitCommand", fields: fields)
            return "applied"
        default:
            try EventStore.markRun(runID: runID, status: summary.status, event: "CockpitCommand", fields: fields)
            return "recorded"
        }
    }

    private static func write(_ commands: [CockpitCommand]) throws {
        try FileManager.default.createDirectory(at: commandsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(commands).write(to: commandsURL, options: [.atomic])
    }
}
