import Foundation

struct VisualGroundingQualityStore {
    static var feedbackURL: URL {
        EventStore.rootURL.appendingPathComponent("vision-grounding-feedback.jsonl")
    }

    static var calibrationURL: URL {
        EventStore.rootURL.appendingPathComponent("vision-grounding-calibration.jsonl")
    }

    static func modelRegistry() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let localCommand = env["AIOS_LOCAL_GROUNDER_COMMAND"] ?? ""
        let localModel = env["AIOS_LOCAL_GROUNDER_MODEL"] ?? env["AIOS_GUI_GROUNDER_MODEL"] ?? ""
        let profiles: [[String: String]] = [
            [
                "id": "local_gui_grounder",
                "role": "primary_grounder",
                "available": localCommand.isEmpty ? "false" : "true",
                "model": localModel,
                "command": localCommand,
                "best_for": "desktop screenshots, canvas, icons, image buttons, charts"
            ],
            [
                "id": "openai_compatible_vlm",
                "role": "semantic_reranker",
                "available": VisionSidecar.isConfigured ? "true" : "false",
                "model": env["AIOS_VISION_MODEL"] ?? "",
                "endpoint": env["AIOS_VISION_BASE_URL"] ?? "",
                "best_for": "complex UI descriptions, ambiguous icon semantics, state/color questions"
            ],
            [
                "id": "builtin_ui_heuristics",
                "role": "always_on_fallback",
                "available": "true",
                "model": "Vision OCR + AX + rectangles + color saliency + layout priors",
                "endpoint": "in_process",
                "best_for": "text, rough layout, status colors, accessibility-backed controls"
            ]
        ]
        return [
            "schema": "aios.visual.grounding.model_registry.v1",
            "profiles": jsonStringValue(profiles),
            "calibration_count": "\(readJSONL(calibrationURL).count)",
            "feedback_count": "\(readJSONL(feedbackURL).count)",
            "selection_policy": "local GUI grounder -> VLM rerank -> builtin OCR/AX/layout fallback -> cache -> feedback-weighted rerank -> verification anchors"
        ]
    }

    @discardableResult
    static func calibrate(args: [String: Any]) throws -> [String: String] {
        let imagePath = string(args["image_path"]) ?? ""
        let observedWidth = double(args["observed_width"]) ?? 0
        let observedHeight = double(args["observed_height"]) ?? 0
        let nativeWidth = double(args["native_width"]) ?? observedWidth
        let nativeHeight = double(args["native_height"]) ?? observedHeight
        let xScale = observedWidth > 0 ? nativeWidth / observedWidth : 1
        let yScale = observedHeight > 0 ? nativeHeight / observedHeight : 1
        let payload: [String: String] = [
            "schema": "aios.visual.grounding.calibration.v1",
            "id": "vgcal-\(UUID().uuidString)",
            "image_path": imagePath,
            "surface": string(args["surface"]) ?? "",
            "observed_width": String(format: "%.2f", observedWidth),
            "observed_height": String(format: "%.2f", observedHeight),
            "native_width": String(format: "%.2f", nativeWidth),
            "native_height": String(format: "%.2f", nativeHeight),
            "x_scale": String(format: "%.6f", xScale),
            "y_scale": String(format: "%.6f", yScale),
            "notes": string(args["notes"]) ?? "",
            "created_at": isoDateString(Date())
        ]
        try appendJSONL(payload, to: calibrationURL)
        return payload
    }

    @discardableResult
    static func feedback(args: [String: Any]) throws -> [String: String] {
        let success = bool(args["success"]) ?? false
        let payload: [String: String] = [
            "schema": "aios.visual.grounding.feedback.v1",
            "id": "vgfb-\(UUID().uuidString)",
            "candidate_id": string(args["candidate_id"]) ?? "",
            "query": string(args["query"]) ?? "",
            "surface": string(args["surface"]) ?? "",
            "image_path": string(args["image_path"]) ?? "",
            "success": success ? "true" : "false",
            "reason": string(args["reason"]) ?? "",
            "confidence_delta": success ? "0.06" : "-0.10",
            "created_at": isoDateString(Date())
        ]
        try appendJSONL(payload, to: feedbackURL)
        return payload
    }

    static func policy(surface: String = "", query: String = "") -> [String: String] {
        let registry = modelRegistry()
        let text = normalizeForSearch([surface, query].joined(separator: " "))
        let needsModel = text.contains("canvas") || text.contains("figma") || text.contains("blender") ||
            text.contains("icon") || text.contains("chart") || text.contains("image") || text.contains("图")
        let calibrations = readJSONL(calibrationURL).prefix(5).map { $0 }
        let feedback = readJSONL(feedbackURL).prefix(10).map { $0 }
        return [
            "schema": "aios.visual.grounding.policy.v1",
            "surface": surface,
            "query": query,
            "needs_multimodal_model": needsModel ? "true" : "false",
            "registry": jsonStringValue(registry),
            "recent_calibrations": jsonStringValue(Array(calibrations)),
            "recent_feedback": jsonStringValue(Array(feedback)),
            "candidate_pipeline": "capture -> local candidates -> model candidates -> calibration transform -> feedback rerank -> action plan -> post-action verify"
        ]
    }

    private static func appendJSONL(_ payload: [String: String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = jsonStringValue(payload) + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func readJSONL(_ url: URL) -> [[String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8), !data.isEmpty,
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return raw.compactMapValues { value in
                if let text = value as? String { return text }
                if let number = value as? NSNumber { return number.stringValue }
                return nil
            }
        }.sorted { ($0["created_at"] ?? "") > ($1["created_at"] ?? "") }
    }
}
