import Foundation

struct TrajectoryEvidenceStore {
    static func capture(runID: String, stepID: String, call: ToolCall, result: ToolResult) throws -> [String: String] {
        let id = "evidence-\(UUID().uuidString)"
        let dir = EventStore.trajectoriesURL
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let lanes = evidenceLanes(call: call, result: result)
        let payload: [String: Any] = [
            "schema": "aios.trajectory.evidence.v1",
            "id": id,
            "run_id": runID,
            "step_id": stepID,
            "tool": call.name,
            "arguments": call.arguments,
            "success": result.success,
            "evidence": result.evidence,
            "error": result.error ?? "",
            "result": result.data,
            "lanes": lanes,
            "created_at": isoDateString(Date())
        ]
        let url = dir.appendingPathComponent("\(id).json")
        try writeJSONObject(payload, to: url)
        return [
            "evidence_id": id,
            "path": url.path,
            "tool": call.name,
            "lanes": lanes.map { $0["lane"] ?? "" }.joined(separator: ","),
            "screen_path": lanes.first { $0["lane"] == "screen" }?["path"] ?? "",
            "dom_available": lanes.contains { $0["lane"] == "dom" } ? "true" : "false",
            "ax_available": lanes.contains { $0["lane"] == "ax_tree" } ? "true" : "false"
        ]
    }

    private static func evidenceLanes(call: ToolCall, result: ToolResult) -> [[String: String]] {
        var lanes: [[String: String]] = []
        if let path = firstNonEmpty(result.data, keys: ["image_path", "path", "screenshot", "screenshot_path"]) {
            lanes.append(["lane": "screen", "path": path, "source": call.name])
        }
        if call.name.hasPrefix("browser_") || call.name.hasPrefix("chrome_") {
            lanes.append([
                "lane": "dom",
                "url": result.data["url"] ?? "",
                "tab_id": result.data["tab_id"] ?? "",
                "result": truncateMiddle(result.data["result"] ?? result.data["tabs"] ?? "", maxCharacters: 4_000)
            ])
        }
        if call.name.hasPrefix("aios_") || call.name.hasPrefix("snapshot_") {
            let axPayload = firstNonEmpty(result.data, keys: ["locators", "elements", "tree", "ax"]) ?? ""
            if !axPayload.isEmpty {
                lanes.append(["lane": "ax_tree", "payload": truncateMiddle(axPayload, maxCharacters: 4_000)])
            }
        }
        lanes.append([
            "lane": "action_result",
            "success": result.success ? "true" : "false",
            "evidence": truncateMiddle(result.evidence, maxCharacters: 1_000),
            "error": result.error ?? ""
        ])
        return lanes
    }

    private static func firstNonEmpty(_ data: [String: String], keys: [String]) -> String? {
        keys.compactMap { data[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}
