import Foundation

struct BrowserAgentRuntime {
    static var cacheURL: URL {
        BrowserRuntimeStore.rootURL.appendingPathComponent("agent-observations.jsonl")
    }

    static func agentPlan(goal: String, url: String = "", extractionSchema: String = "") -> [String: String] {
        let runtime = BrowserRuntimeStore.plan(goal: goal, url: url)
        let selectorCache = BrowserSelectorCacheStore.list(query: goal, limit: 12).map(\.dictionary)
        return [
            "schema": "aios.browser.agent.plan.v1",
            "goal": goal,
            "url": url,
            "runtime": jsonStringValue(runtime),
            "selector_cache": jsonStringValue(selectorCache),
            "observe": "browser_cdp_observe produces an accessibility/DOM action map before every act.",
            "act": "browser_cdp_act uses selector cache first, then text/role query, then JS fallback.",
            "extract": extractionSchema.isEmpty ? "browser_cdp_extract returns structured text/links/forms." : extractionSchema,
            "wait": "browser_cdp_wait watches DOM text, selector, navigation, and network-idle style conditions.",
            "self_healing": "cache successful selectors by url+goal+action and retry changed pages through observe->act repair."
        ]
    }

    static func recordObservation(url: String, goal: String, observationJSON: String) throws -> [String: String] {
        let id = "browser-agent-\(UUID().uuidString)"
        let payload: [String: String] = [
            "schema": "aios.browser.agent.observation.v1",
            "id": id,
            "url": url,
            "goal": goal,
            "observation": observationJSON,
            "created_at": isoDateString(Date())
        ]
        try append(payload)
        return payload
    }

    static func snapshot(query: String = "", limit: Int = 20) -> [String: String] {
        let normalized = normalizeForSearch(query)
        let rows = readAll().filter { row in
            normalized.isEmpty || normalizeForSearch(row.values.joined(separator: " ")).contains(normalized)
        }.prefix(max(1, limit))
        return [
            "schema": "aios.browser.agent.snapshot.v1",
            "query": query,
            "observations": jsonStringValue(Array(rows)),
            "runtime": jsonStringValue(BrowserRuntimeStore.snapshot(sessionID: nil))
        ]
    }

    private static func append(_ row: [String: String]) throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = jsonStringValue(row) + "\n"
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            let handle = try FileHandle(forWritingTo: cacheURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: cacheURL, atomically: true, encoding: .utf8)
        }
    }

    private static func readAll() -> [[String: String]] {
        guard let text = try? String(contentsOf: cacheURL, encoding: .utf8) else { return [] }
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
