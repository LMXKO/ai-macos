import Foundation

struct BrowserAgentContractStore {
    static func contract(goal: String, url: String = "", extractionSchema: String = "") -> [String: String] {
        let plan = BrowserAgentRuntime.agentPlan(goal: goal, url: url, extractionSchema: extractionSchema)
        let selectorCache = BrowserSelectorCacheStore.list(query: [goal, url].joined(separator: " "), limit: 20).map(\.dictionary)
        return [
            "schema": "aios.browser.agent.contract.v1",
            "goal": goal,
            "url": url,
            "plan": jsonStringValue(plan),
            "selector_cache": jsonStringValue(selectorCache),
            "observe_contract": "return action candidates with selector, text, role, bounds when available, frame path, and stable cache key",
            "act_contract": "resolve cached selector -> fresh observe -> self-heal selector -> execute CDP action -> observe after",
            "extract_contract": extractionSchema.isEmpty ? "return typed payload plus raw text, links, forms, tables, and provenance" : extractionSchema,
            "wait_contract": "support selector/text/url/expression/network-idle; store wait result as observation for later replay",
            "iframe_policy": "same-origin iframes are included through CDP JS; cross-origin frames require browser extension or page-level target attachment",
            "session_policy": "bind work to durable browser_runtime_session with profile_dir, endpoint, url, selector cache, download path, and auth-preserving user data dir",
            "validation_policy": "when schema is supplied, extract must include schema label, field provenance, missing fields, and validation status"
        ]
    }

    static func validateExtraction(payloadJSON: String, schemaJSON: String = "") -> [String: String] {
        let payload = parseValue(payloadJSON)
        let schema = parseValue(schemaJSON)
        let missing = requiredFields(schema: schema).filter { field in
            guard let object = payload as? [String: Any] else { return true }
            return object[field] == nil
        }
        return [
            "schema": "aios.browser.agent.extraction_validation.v1",
            "valid": missing.isEmpty ? "true" : "false",
            "missing_fields": missing.joined(separator: ","),
            "payload_type": payload.map { "\($0)" }.map { _ in typeName(payload) } ?? "invalid_json",
            "schema_type": schema.map { "\($0)" }.map { _ in typeName(schema) } ?? "none",
            "provenance_required": "true"
        ]
    }

    private static func parseValue(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func requiredFields(schema: Any?) -> [String] {
        guard let object = schema as? [String: Any] else { return [] }
        if let required = object["required"] as? [String] { return required }
        if let required = object["required"] as? [Any] { return required.compactMap { $0 as? String } }
        if let fields = object["fields"] as? [String] { return fields }
        return []
    }

    private static func typeName(_ value: Any?) -> String {
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        if value is String { return "string" }
        if value is NSNumber { return "number" }
        return "unknown"
    }
}
