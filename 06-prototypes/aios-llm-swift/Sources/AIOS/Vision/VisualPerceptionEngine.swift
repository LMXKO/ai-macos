import Foundation

struct VisualPerceptionEngine {
    static var cacheURL: URL {
        EventStore.rootURL.appendingPathComponent("vision-ui-maps", isDirectory: true)
    }

    static func strategy(surface: String = "", query: String = "") -> [String: String] {
        let text = normalizeForSearch([surface, query].joined(separator: " "))
        let needsVLM = text.contains("canvas") || text.contains("figma") || text.contains("image") || text.contains("icon") || text.contains("chart") || text.contains("图")
        return [
            "schema": "aios.visual.perception.strategy.v1",
            "local_layers": "ocr,ax,rectangles,color_saliency,layout_prior,ui_map_cache",
            "sidecar_layer": VisionSidecar.isConfigured ? "configured" : "not_configured",
            "needs_multimodal_grounder": needsVLM ? "true" : "false",
            "recommended_tool": needsVLM ? "visual_analyze + visual_ground_action" : "visual_candidates",
            "output_contract": "candidate schema + action schema + verification anchors"
        ]
    }

    static func cacheUIMap(imagePath: String, query: String, candidatesJSON: String) throws -> URL {
        let id = "uimap-\(normalizeID((imagePath as NSString).lastPathComponent))-\(UUID().uuidString.prefix(8))"
        let candidates = parseJSONValue(candidatesJSON) ?? candidatesJSON
        let payload: [String: Any] = [
            "schema": "aios.visual.ui_map.v1",
            "id": id,
            "image_path": imagePath,
            "query": query,
            "candidates": candidates,
            "candidate_count": candidateCount(candidates),
            "created_at": isoDateString(Date())
        ]
        let url = cacheURL.appendingPathComponent("\(id).json")
        try writeJSONObject(payload, to: url)
        return url
    }

    static func recent(limit: Int = 10) -> [[String: String]] {
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let urls = try? FileManager.default.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
            .prefix(max(1, limit))
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return raw.reduce(into: [String: String]()) { result, pair in
                    if let value = pair.value as? String {
                        result[pair.key] = value
                    } else if let value = pair.value as? NSNumber {
                        result[pair.key] = value.stringValue
                    } else if JSONSerialization.isValidJSONObject(pair.value) {
                        result[pair.key] = jsonStringValue(pair.value)
                    }
                }
            }
    }

    private static func parseJSONValue(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func candidateCount(_ value: Any) -> Int {
        if let array = value as? [Any] { return array.count }
        if let object = value as? [String: Any], let candidates = object["candidates"] as? [Any] { return candidates.count }
        return 0
    }
}
