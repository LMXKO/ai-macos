import Foundation

struct VisualGrounderRuntime {
    static func profiles() -> [[String: String]] {
        let env = ProcessInfo.processInfo.environment
        return [
            [
                "id": "openai_compatible_sidecar",
                "title": "OpenAI-compatible VLM sidecar",
                "available": VisionSidecar.isConfigured ? "true" : "false",
                "model": env["AIOS_VISION_MODEL"] ?? "",
                "endpoint": env["AIOS_VISION_BASE_URL"] ?? "",
                "best_for": "icons,canvas,charts,image_buttons,complex_layouts",
                "contract": "visual_analyze returns compact candidate JSON with coordinates and verification anchors"
            ],
            [
                "id": "local_showui_or_uitars",
                "title": "Local GUI grounding model adapter",
                "available": configuredLocalGrounder().isEmpty ? "false" : "true",
                "model": configuredLocalGrounder(),
                "endpoint": "local process or HTTP adapter",
                "best_for": "coordinate grounding,desktop screenshots,non_text_controls",
                "contract": "adapter receives screenshot/query and returns VisualGrounding.schema candidates"
            ],
            [
                "id": "builtin_heuristic_grounder",
                "title": "Built-in OCR/AX/shape/color/layout grounder",
                "available": "true",
                "model": "vision_ocr+ax+rectangles+color_saliency+layout_prior",
                "endpoint": "in-process",
                "best_for": "text controls,AX controls,rough layout,status colors",
                "contract": "always available fallback, lower semantic depth than a VLM"
            ]
        ]
    }

    static func sessionPlan(args: [String: Any]) -> [String: String] {
        let surface = string(args["surface"]) ?? ""
        let query = string(args["query"]) ?? ""
        let imagePath = string(args["image_path"]) ?? ""
        let strategy = VisualPerceptionEngine.strategy(surface: surface, query: query)
        let primary = profiles().first { $0["available"] == "true" } ?? profiles().last ?? [:]
        return [
            "schema": "aios.visual.grounder.session.v1",
            "query": query,
            "surface": surface,
            "image_path": imagePath,
            "strategy": jsonStringValue(strategy),
            "selected_profile": jsonStringValue(primary),
            "candidate_schema": jsonStringValue(VisualGrounding.schema),
            "action_schema": jsonStringValue(VisualGrounding.actionSchema),
            "pipeline": "capture -> OCR/AX/shape/color/layout -> VLM rerank when available -> UI map cache -> action plan -> verification anchors",
            "cache_key": normalizeID([surface, query, (imagePath as NSString).lastPathComponent].joined(separator: "-")),
            "verification_anchors": "candidate_id,visible_label,state,dominant_color,bounds,post_action_observation"
        ]
    }

    static func queryUIMaps(query: String, limit: Int = 10) -> [String: String] {
        let maps = VisualPerceptionEngine.recent(limit: max(1, limit * 3))
        let normalized = normalizeForSearch(query)
        let scored = maps.compactMap { map -> ([String: String], Int)? in
            let haystack = normalizeForSearch(map.values.joined(separator: " "))
            let score = normalized.isEmpty || haystack.contains(normalized) ? 10 :
                normalized.split(separator: " ").filter { haystack.contains($0) }.count
            guard score > 0 else { return nil }
            return (map, score)
        }
        let selected = scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return (lhs.0["created_at"] ?? "") > (rhs.0["created_at"] ?? "") }
                return lhs.1 > rhs.1
            }
            .prefix(max(1, limit))
            .map(\.0)
        return [
            "schema": "aios.visual.ui_map.query.v1",
            "query": query,
            "matches": jsonStringValue(selected),
            "match_count": "\(selected.count)"
        ]
    }

    private static func configuredLocalGrounder() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["AIOS_LOCAL_GROUNDER_MODEL"] ?? env["AIOS_GUI_GROUNDER_MODEL"] ?? ""
    }
}
