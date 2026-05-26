import Foundation

struct ShadowMemoryStore {
    static var url: URL {
        EventStore.memoryURL.appendingPathComponent("shadow-digests.jsonl")
    }

    @discardableResult
    static func capture(runID: String = "", goal: String = "", trigger: String = "manual", limit: Int = 20) throws -> [String: String] {
        let digest = EpisodeContextEngine.shadowDigest(limit: limit)
        let payload: [String: String] = [
            "schema": "aios.memory.shadow_capture.v1",
            "id": "shadow-\(UUID().uuidString)",
            "run_id": runID,
            "goal": goal,
            "trigger": trigger,
            "digest": jsonStringValue(digest),
            "created_at": isoDateString(Date())
        ]
        try append(payload)
        return payload
    }

    static func recent(limit: Int = 20) -> [[String: String]] {
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
        }.sorted { ($0["created_at"] ?? "") > ($1["created_at"] ?? "") }.prefix(max(1, limit)).map { $0 }
    }

    private static func append(_ payload: [String: String]) throws {
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
}
