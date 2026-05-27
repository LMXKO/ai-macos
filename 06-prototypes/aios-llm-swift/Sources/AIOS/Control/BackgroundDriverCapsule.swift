import Foundation

struct BackgroundDriverCapsuleStore {
    static let requestSchema = "aios.background.driver.request.v1"
    static let receiptSchema = "aios.background.driver.receipt.v1"

    static var receiptsURL: URL {
        EventStore.rootURL.appendingPathComponent("background-driver-receipts.jsonl")
    }

    static func contract() -> [String: String] {
        [
            "schema": "aios.background.driver.capsule.v1",
            "request_schema": requestSchema,
            "receipt_schema": receiptSchema,
            "verbs": "observe,ground,act,verify,wait",
            "target_contract": "app_name,bundle_id,surface,url,window_id,space_id",
            "action_contract": "action,query,selector,text,script,allow_foreground",
            "evidence_contract": "driver,status,receipt_id,pre_observation,post_observation,artifact_paths,stdout,stderr,error",
            "background_guarantee": "driver must report no_cursor/no_focus/no_space guarantees or explain fallback"
        ]
    }

    static func requestEnvelope(
        driver: [String: String],
        target: BackgroundControlTarget,
        action: BackgroundControlAction
    ) -> [String: Any] {
        [
            "schema": requestSchema,
            "request_id": "bgreq-\(UUID().uuidString)",
            "driver": driver["id"] ?? "",
            "target": target.dictionary,
            "action": action.dictionary.merging([
                "text": action.text,
                "query": action.query,
                "selector": action.selector,
                "script": action.script
            ]) { current, _ in current },
            "requirements": [
                "must_not_move_cursor": true,
                "must_not_steal_focus": true,
                "must_not_change_space": true,
                "must_return_observable_evidence": true
            ],
            "created_at": isoDateString(Date())
        ]
    }

    @discardableResult
    static func recordReceipt(
        driver: String,
        request: [String: Any],
        status: String,
        mode: String,
        result: ToolResult? = nil,
        stdout: String = "",
        stderr: String = "",
        error: String = ""
    ) -> [String: String] {
        let receipt: [String: String] = [
            "schema": receiptSchema,
            "receipt_id": "bgrec-\(UUID().uuidString)",
            "driver": driver,
            "request_id": string(request["request_id"]) ?? "",
            "status": status,
            "mode": mode,
            "request": jsonStringValue(request),
            "result": result?.jsonString ?? "",
            "stdout": truncateMiddle(stdout, maxCharacters: 4_000),
            "stderr": truncateMiddle(stderr, maxCharacters: 2_000),
            "error": error,
            "created_at": isoDateString(Date())
        ]
        try? append(receipt)
        return receipt
    }

    static func recent(limit: Int = 20) -> [[String: String]] {
        guard let text = try? String(contentsOf: receiptsURL, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return raw.compactMapValues { value -> String? in
                if let value = value as? String { return value }
                if let value = value as? NSNumber { return value.stringValue }
                return nil
            }
        }
        .suffix(max(1, limit))
        .reversed()
    }

    private static func append(_ receipt: [String: String]) throws {
        try FileManager.default.createDirectory(at: receiptsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = jsonStringValue(receipt) + "\n"
        if FileManager.default.fileExists(atPath: receiptsURL.path) {
            let handle = try FileHandle(forWritingTo: receiptsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: receiptsURL, atomically: true, encoding: .utf8)
        }
    }
}
