import AppKit
import CoreGraphics
import Foundation

struct VisualGrounding {
    static let version = "visual-grounding-v2"

    static var schema: [[String: String]] {
        [
            ["field": "id", "meaning": "Stable candidate id within the current grounding result."],
            ["field": "kind", "meaning": "text, accessibility, rectangle, icon, color_region, layout_region, or sidecar."],
            ["field": "label", "meaning": "Human-readable semantic label or visible text."],
            ["field": "source", "meaning": "vision_ocr, ax_tree, vision_rectangle, color_saliency, layout_prior, or vision_sidecar."],
            ["field": "x,y,width,height,center_x,center_y", "meaning": "Coordinate box in the captured image/window/screen coordinate space."],
            ["field": "score", "meaning": "0-1 ranking score for the query/action."],
            ["field": "confidence", "meaning": "Detector confidence when available."],
            ["field": "affordance", "meaning": "button, text_input, link, toggle, menu, readable_text, layout_region, status_region, or visual_region."],
            ["field": "action_types", "meaning": "Comma-separated actions that can plausibly use this candidate, e.g. click,type,verify,observe."],
            ["field": "state", "meaning": "Optional visual state inferred from color/role, e.g. primary, success, warning, danger, disabled."],
            ["field": "dominant_color", "meaning": "Optional #RRGGBB color used for state or saliency inference."]
        ]
    }

    static var actionSchema: [[String: String]] {
        [
            ["field": "action", "meaning": "click, type, verify, observe, drag, or hover."],
            ["field": "candidate_id", "meaning": "Selected candidate id."],
            ["field": "channel", "meaning": "visual_grounding; execution may require foreground coordinates."],
            ["field": "requires_foreground", "meaning": "true for coordinate actions, false for verify/observe planning."],
            ["field": "x,y", "meaning": "Action point, usually candidate center."],
            ["field": "text", "meaning": "Text to type when action=type."],
            ["field": "reason", "meaning": "Why this candidate was selected."]
        ]
    }

    static func groundingPrompt(query: String, localCandidates: [[String: String]], maxResults: Int) -> String {
        """
        You are the visual grounding module for a macOS computer-use agent.
        Return only compact JSON: {"candidates":[...]} using this schema:
        \(jsonStringValue(schema))
        Task/query: \(query.isEmpty ? "(no explicit query)" : query)
        Local candidates: \(jsonStringValue(Array(localCandidates.prefix(maxResults))))
        Add or rerank candidates for icons, canvas controls, image buttons, layout areas, state colors, charts, or non-text UI. Preserve coordinates when possible.
        """
    }

    static func enrich(_ candidate: [String: String], query: String, fallbackKind: String? = nil, fallbackSource: String? = nil) -> [String: String] {
        var item = candidate
        let kind = item["kind"] ?? fallbackKind ?? "visual_region"
        let source = item["source"] ?? fallbackSource ?? "local"
        let label = firstNonEmpty([item["label"], item["text"], item["role"], kind])
        item["kind"] = kind
        item["source"] = source
        item["label"] = label
        item["grounding_version"] = version
        item["modality"] = modality(for: kind, source: source)
        item["affordance"] = item["affordance"] ?? affordance(for: item)
        item["action_types"] = item["action_types"] ?? actionTypes(for: item).joined(separator: ",")
        if item["score"] == nil {
            item["score"] = score(label: label, query: query, candidate: item)
        }
        if item["state"] == nil, let color = item["dominant_color"] {
            item["state"] = stateSemantic(forHexColor: color)
        }
        if item["center_x"] == nil || item["center_y"] == nil {
            if let x = double(item["x"]), let y = double(item["y"]), let width = double(item["width"]), let height = double(item["height"]) {
                item["center_x"] = "\(Int(x + width / 2))"
                item["center_y"] = "\(Int(y + height / 2))"
            }
        }
        return item
    }

    static func rank(_ candidates: [[String: String]], query: String, limit: Int) -> [[String: String]] {
        let normalizedQuery = normalizeForSearch(query)
        let enriched = candidates.map { enrich($0, query: query) }
        let filtered = enriched.filter { candidate in
            guard !normalizedQuery.isEmpty else { return true }
            let haystack = normalizeForSearch([
                candidate["label"],
                candidate["text"],
                candidate["role"],
                candidate["kind"],
                candidate["affordance"],
                candidate["state"]
            ].compactMap { $0 }.joined(separator: " "))
            return haystack.contains(normalizedQuery) ||
                normalizedQuery.split(separator: " ").contains(where: { haystack.contains($0) }) ||
                candidate["source"] == "color_saliency" ||
                candidate["source"] == "layout_prior" ||
                candidate["source"] == "vision_rectangle"
        }
        return Array(filtered.sorted { lhs, rhs in
            let lhsScore = Double(lhs["score"] ?? "0") ?? 0
            let rhsScore = Double(rhs["score"] ?? "0") ?? 0
            if lhsScore == rhsScore { return (lhs["id"] ?? "") < (rhs["id"] ?? "") }
            return lhsScore > rhsScore
        }.prefix(max(1, limit)))
    }

    static func actionPlan(
        candidates: [[String: String]],
        query: String,
        action: String,
        text: String? = nil,
        candidateID: String? = nil
    ) -> [String: String]? {
        let normalizedAction = normalizeForSearch(action.isEmpty ? "click" : action)
        let selected = candidates.first { candidate in
            if let candidateID, !candidateID.isEmpty {
                return candidate["id"] == candidateID
            }
            let actionTypes = Set((candidate["action_types"] ?? "").split(separator: ",").map { String($0) })
            return actionTypes.contains(normalizedAction) || normalizedAction == "observe" || normalizedAction == "verify"
        } ?? candidates.first
        guard let selected else { return nil }
        var plan: [String: String] = [
            "action": normalizedAction,
            "candidate_id": selected["id"] ?? "",
            "candidate": jsonStringValue(selected),
            "channel": "visual_grounding",
            "requires_foreground": ["click", "type", "drag", "hover"].contains(normalizedAction) ? "true" : "false",
            "reason": reason(for: selected, query: query, action: normalizedAction)
        ]
        if let x = selected["center_x"], let y = selected["center_y"] {
            plan["x"] = x
            plan["y"] = y
        }
        if let text, !text.isEmpty {
            plan["text"] = text
        }
        return plan
    }

    static func sidecarCandidates(from answer: String) -> [[String: String]] {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippets = jsonSnippets(in: trimmed)
        for snippet in snippets {
            guard let data = snippet.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            if let dict = object as? [String: Any], let candidates = dict["candidates"] as? [[String: Any]] {
                return candidates.enumerated().map { index, raw in
                    coerce(raw, fallbackID: "M\(index + 1)")
                }
            }
            if let candidates = object as? [[String: Any]] {
                return candidates.enumerated().map { index, raw in
                    coerce(raw, fallbackID: "M\(index + 1)")
                }
            }
        }
        return []
    }

    static func layoutCandidates(bounds: CGRect, imagePath: String) -> [[String: String]] {
        let width = max(1, bounds.width)
        let height = max(1, bounds.height)
        let top = min(72, height * 0.12)
        let left = min(280, width * 0.26)
        let bottom = min(64, height * 0.12)
        let regions: [(String, String, CGRect, String)] = [
            ("L1", "title or tab bar", CGRect(x: bounds.minX, y: bounds.minY, width: width, height: top), "menu"),
            ("L2", "left sidebar or navigation", CGRect(x: bounds.minX, y: bounds.minY + top, width: left, height: max(1, height - top - bottom)), "layout_region"),
            ("L3", "main content canvas", CGRect(x: bounds.minX + left, y: bounds.minY + top, width: max(1, width - left), height: max(1, height - top - bottom)), "layout_region"),
            ("L4", "bottom status or action bar", CGRect(x: bounds.minX, y: bounds.maxY - bottom, width: width, height: bottom), "status_region")
        ]
        return regions.map { id, label, rect, affordance in
            [
                "id": id,
                "kind": "layout_region",
                "source": "layout_prior",
                "label": label,
                "x": "\(Int(rect.minX))",
                "y": "\(Int(rect.minY))",
                "width": "\(Int(rect.width))",
                "height": "\(Int(rect.height))",
                "center_x": "\(Int(rect.midX))",
                "center_y": "\(Int(rect.midY))",
                "image_path": imagePath,
                "affordance": affordance,
                "action_types": "observe,verify",
                "confidence": "0.500"
            ]
        }
    }

    private static func modality(for kind: String, source: String) -> String {
        if source.contains("ax") { return "accessibility" }
        if kind == "text" { return "ocr_text" }
        if kind.contains("color") { return "color" }
        if kind.contains("layout") { return "layout" }
        return "vision"
    }

    private static func affordance(for candidate: [String: String]) -> String {
        let text = normalizeForSearch([
            candidate["label"],
            candidate["text"],
            candidate["role"],
            candidate["kind"]
        ].compactMap { $0 }.joined(separator: " "))
        if text.contains("textfield") || text.contains("text field") || text.contains("searchfield") || text.contains("输入") || text.contains("搜索") {
            return "text_input"
        }
        if text.contains("checkbox") || text.contains("switch") || text.contains("toggle") || text.contains("勾选") {
            return "toggle"
        }
        if text.contains("link") || text.contains("链接") {
            return "link"
        }
        if text.contains("button") || text.contains("submit") || text.contains("send") || text.contains("save") ||
            text.contains("发送") || text.contains("保存") || text.contains("确定") || text.contains("提交") || text.contains("继续") || text.contains("完成") {
            return "button"
        }
        if text.contains("menu") || text.contains("toolbar") || text.contains("tab") || text.contains("菜单") {
            return "menu"
        }
        if text.contains("layout") || text.contains("sidebar") || text.contains("canvas") || text.contains("content") {
            return "layout_region"
        }
        if text.contains("status") || text.contains("warning") || text.contains("error") || text.contains("状态") {
            return "status_region"
        }
        if candidate["kind"] == "text" { return "readable_text" }
        return "visual_region"
    }

    private static func actionTypes(for candidate: [String: String]) -> [String] {
        switch candidate["affordance"] ?? affordance(for: candidate) {
        case "text_input":
            return ["click", "type", "verify", "observe"]
        case "button", "link", "toggle", "menu":
            return ["click", "verify", "observe"]
        case "readable_text", "status_region", "layout_region":
            return ["verify", "observe"]
        default:
            return ["click", "verify", "observe"]
        }
    }

    private static func score(label: String, query: String, candidate: [String: String]) -> String {
        let query = normalizeForSearch(query)
        var value = Double(candidate["confidence"] ?? "") ?? 0.48
        switch candidate["source"] {
        case "vision_ocr":
            value += 0.12
        case "ax_tree":
            value += 0.18
        case "vision_sidecar":
            value += 0.22
        case "color_saliency":
            value += 0.04
        default:
            break
        }
        guard !query.isEmpty else {
            return String(format: "%.2f", min(0.98, value))
        }
        let haystack = normalizeForSearch([
            label,
            candidate["role"],
            candidate["affordance"],
            candidate["state"],
            candidate["kind"]
        ].compactMap { $0 }.joined(separator: " "))
        if haystack.contains(query) { value += 0.35 }
        let hits = query.split(separator: " ").filter { haystack.contains($0) }.count
        value += min(0.24, Double(hits) * 0.08)
        return String(format: "%.2f", min(0.99, max(0.05, value)))
    }

    private static func stateSemantic(forHexColor hex: String) -> String {
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6, let raw = Int(normalized, radix: 16) else { return "" }
        let r = Double((raw >> 16) & 0xff) / 255
        let g = Double((raw >> 8) & 0xff) / 255
        let b = Double(raw & 0xff) / 255
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let saturation = maxValue == 0 ? 0 : (maxValue - minValue) / maxValue
        if saturation < 0.10 && maxValue < 0.45 { return "disabled_or_dark" }
        if saturation < 0.10 { return "neutral" }
        if r > 0.65 && g < 0.45 { return "danger" }
        if b == maxValue && b - r > 0.12 { return "primary" }
        if g > 0.55 && r < 0.55 { return "success" }
        if r > 0.65 && g > 0.45 { return "warning" }
        return "accent"
    }

    private static func reason(for candidate: [String: String], query: String, action: String) -> String {
        let label = firstNonEmpty([candidate["label"], candidate["text"], candidate["kind"]])
        let affordance = candidate["affordance"] ?? "visual_region"
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Selected \(label) because it supports \(action) as \(affordance)."
        }
        return "Selected \(label) for query '\(query)' because it supports \(action) as \(affordance)."
    }

    private static func firstNonEmpty(_ values: [String?]) -> String {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
    }

    private static func coerce(_ raw: [String: Any], fallbackID: String) -> [String: String] {
        var output: [String: String] = ["id": string(raw["id"]) ?? fallbackID, "source": "vision_sidecar", "kind": string(raw["kind"]) ?? "sidecar"]
        for (key, value) in raw {
            if let text = value as? String {
                output[key] = text
            } else if let number = value as? NSNumber {
                output[key] = number.stringValue
            } else if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) {
                output[key] = text
            }
        }
        return output
    }

    private static func jsonSnippets(in text: String) -> [String] {
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return [text]
        }
        var snippets: [String] = []
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            snippets.append(String(text[start...end]))
        }
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            snippets.append(String(text[start...end]))
        }
        return snippets
    }
}
