import Foundation

struct ReplayableSessionBundleStore {
    static var bundlesURL: URL {
        EventStore.trajectoriesURL.appendingPathComponent("replayable-bundles", isDirectory: true)
    }

    @MainActor
    static func export(runID: String, limit: Int = 400) throws -> URL {
        let manifest = try manifest(runID: runID, limit: limit)
        let url = bundlesURL.appendingPathComponent("\(runID)-bundle.json")
        try writeJSONObject(manifest, to: url)
        return url
    }

    @MainActor
    static func manifest(runID: String, limit: Int = 400) throws -> [String: String] {
        let summary = try EventStore.readSummary(runID: runID)
        let timeline = (try? SessionProtocolStore.timeline(runID: runID, limit: limit)) ?? []
        let trajectory = try TrajectoryStore.summarize(runID: runID, limit: limit)
        let product = try? TrajectoryProductStore.exportProduct(runID: runID, limit: limit)
        let session = try? SessionProtocolStore.export(runID: runID)
        let replay = try? TrajectoryReplayEngine.replay(runID: runID, dryRun: true)
        let resumePoints = (try? TrajectoryProductStore.resumePoints(runID: runID)) ?? []
        let lanes = [
            ["lane": "screen", "available": hasEvidence(trajectory, keys: ["screenshot_path", "image_path"]) ? "true" : "false", "description": "Screenshot/window/image refs for visual replay."],
            ["lane": "ax_tree", "available": hasEvidence(trajectory, keys: ["ax_tree", "snapshot_id", "locator_id"]) ? "true" : "false", "description": "Accessibility tree or locator snapshot refs."],
            ["lane": "dom", "available": hasEvidence(trajectory, keys: ["selector", "url", "tab_id"]) ? "true" : "false", "description": "Browser DOM/CDP refs."],
            ["lane": "action_result", "available": hasEvidence(trajectory, keys: ["tool", "success", "evidence"]) ? "true" : "false", "description": "Tool call result and evidence."],
            ["lane": "state_diff", "available": hasEvidence(trajectory, keys: ["status", "checkpoint", "updated_at"]) ? "true" : "false", "description": "Run status/checkpoint transitions."]
        ]
        return [
            "schema": "aios.trajectory.replayable_bundle.v1",
            "run_id": runID,
            "goal": summary.goal,
            "status": summary.status,
            "events_path": summary.eventsPath,
            "session_artifact": session?.path ?? "",
            "product_artifact": product?.path ?? "",
            "timeline": jsonStringValue(timeline.map(\.dictionary)),
            "trajectory": jsonStringValue(trajectory),
            "replay_plan": jsonStringValue(replay?.data ?? [:]),
            "resume_points": jsonStringValue(resumePoints.map(\.dictionary)),
            "artifact_lanes": jsonStringValue(lanes),
            "replay_contract": "timeline + raw events + screen/AX/DOM refs + action results + state diffs; can branch or clip into recipe from any resume point"
        ]
    }

    private static func hasEvidence(_ events: [[String: String]], keys: [String]) -> Bool {
        events.contains { event in
            keys.contains { key in !(event[key] ?? "").isEmpty }
        }
    }
}
