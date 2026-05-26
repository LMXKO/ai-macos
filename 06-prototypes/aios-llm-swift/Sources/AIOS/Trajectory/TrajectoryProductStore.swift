import Foundation

struct TrajectoryResumePoint: Codable {
    let id: String
    let runID: String
    let eventIndex: Int
    let tool: String
    let reason: String
    let createdAt: String

    var dictionary: [String: String] {
        [
            "id": id,
            "run_id": runID,
            "event_index": "\(eventIndex)",
            "tool": tool,
            "reason": reason,
            "created_at": createdAt
        ]
    }
}

struct TrajectoryProductStore {
    static var productsURL: URL {
        EventStore.trajectoriesURL.appendingPathComponent("products", isDirectory: true)
    }

    @MainActor
    static func exportProduct(runID: String, limit: Int = 400) throws -> URL {
        let summary = try EventStore.readSummary(runID: runID)
        let events = try TrajectoryStore.summarize(runID: runID, limit: limit)
        let timeline = (try? SessionProtocolStore.timeline(runID: runID, limit: limit)) ?? []
        let replay = try? TrajectoryReplayEngine.replay(runID: runID, dryRun: true)
        let resumePoints = try resumePoints(runID: runID)
        let payload: [String: Any] = [
            "schema": "aios.trajectory.product.v1",
            "run_id": runID,
            "goal": summary.goal,
            "status": summary.status,
            "events_path": summary.eventsPath,
            "timeline": timeline.map(\.dictionary),
            "trajectory": events,
            "replay_plan": replay?.data ?? [:],
            "resume_points": resumePoints.map(\.dictionary),
            "exported_at": isoDateString(Date())
        ]
        let url = productsURL.appendingPathComponent("\(runID).json")
        try writeJSONObject(payload, to: url)
        return url
    }

    static func resumePoints(runID: String) throws -> [TrajectoryResumePoint] {
        let events = try TrajectoryStore.summarize(runID: runID, limit: 1_000)
        var points: [TrajectoryResumePoint] = []
        for event in events {
            let eventName = event["event"] ?? ""
            if eventName == "AppAction" || eventName == "Observation" || eventName == "Recovery" || eventName == "StepQueue" {
                let index = int(event["index"]) ?? (points.count + 1)
                points.append(TrajectoryResumePoint(
                    id: "resume-\(runID)-\(index)",
                    runID: runID,
                    eventIndex: index,
                    tool: event["tool"] ?? event["step_id"] ?? eventName,
                    reason: reason(for: event),
                    createdAt: event["time"] ?? isoDateString(Date())
                ))
            }
        }
        return points
    }

    static func branch(runID: String, fromIndex: Int, goal: String) throws -> [String: String] {
        let parent = try EventStore.readSummary(runID: runID)
        let branchID = "branch-\(String(runID.prefix(8)))-\(fromIndex)-\(UUID().uuidString.prefix(8))"
        let store = try EventStore.createQueued(goal: goal.isEmpty ? parent.goal : goal, runID: branchID)
        try store.append("TrajectoryBranch", [
            "parent_run_id": runID,
            "from_event_index": "\(fromIndex)",
            "parent_goal": parent.goal
        ])
        return [
            "branch_run_id": branchID,
            "parent_run_id": runID,
            "from_event_index": "\(fromIndex)",
            "goal": goal.isEmpty ? parent.goal : goal,
            "status": "queued"
        ]
    }

    private static func reason(for event: [String: String]) -> String {
        if event["event"] == "Recovery" { return "Recovery point after failure or blocked action." }
        if event["event"] == "StepQueue" { return "Start of a durable task step." }
        if event["success"] == "false" { return "Observation failed; useful branch point." }
        return "Executable or observable state boundary."
    }
}
