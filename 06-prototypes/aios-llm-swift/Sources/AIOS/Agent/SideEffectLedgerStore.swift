import Foundation

struct SideEffectIntent: Codable, Hashable {
    let key: String
    let kind: String
    let app: String
    let target: String
    let value: String
    let tool: String
    let repeatPolicy: String

    var dictionary: [String: String] {
        [
            "key": key,
            "kind": kind,
            "app": app,
            "target": target,
            "value": value,
            "tool": tool,
            "repeat_policy": repeatPolicy
        ]
    }

    var requiresExactlyOnceGuard: Bool {
        repeatPolicy == "exactly_once_per_run"
    }
}

struct SideEffectLedgerRecord: Codable {
    let id: String
    let runID: String
    let key: String
    let kind: String
    let app: String
    let target: String
    let value: String
    let tool: String
    var status: String
    var evidence: String
    var error: String
    let createdAt: String
    var updatedAt: String

    var dictionary: [String: String] {
        [
            "id": id,
            "run_id": runID,
            "key": key,
            "kind": kind,
            "app": app,
            "target": target,
            "value": value,
            "tool": tool,
            "status": status,
            "evidence": evidence,
            "error": error,
            "created_at": createdAt,
            "updated_at": updatedAt
        ]
    }
}

struct SideEffectLedgerStore {
    static var url: URL {
        EventStore.rootURL.appendingPathComponent("side-effects.json")
    }

    static func intent(for call: ToolCall) -> SideEffectIntent? {
        switch call.name {
        case "wechat_send_text", "lark_send_text", "qq_send_text", "wechat_send_staged", "lark_send_staged", "qq_send_staged":
            let target = firstString(call.arguments, ["recipient", "chat", "name", "to"])
            let value = firstString(call.arguments, ["text", "path", "file_path", "attachment"])
            return makeIntent(
                kind: "external_message_sent",
                app: chatApp(for: call.name),
                target: target,
                value: value,
                tool: call.name,
                repeatPolicy: "exactly_once_per_run"
            )
        case "calendar_create_event":
            return makeIntent(
                kind: "calendar_event_created",
                app: "Calendar",
                target: firstString(call.arguments, ["calendar", "title"]),
                value: [
                    firstString(call.arguments, ["title"]),
                    firstString(call.arguments, ["start", "start_at", "start_time"]),
                    firstString(call.arguments, ["end", "end_at", "end_time"])
                ].filter { !$0.isEmpty }.joined(separator: "|"),
                tool: call.name,
                repeatPolicy: "exactly_once_per_run"
            )
        case "mail_compose_draft":
            return makeIntent(
                kind: "mail_draft_created",
                app: "Mail",
                target: firstString(call.arguments, ["to", "recipient", "subject"]),
                value: [
                    firstString(call.arguments, ["subject"]),
                    firstString(call.arguments, ["body", "content", "text"])
                ].filter { !$0.isEmpty }.joined(separator: "|"),
                tool: call.name,
                repeatPolicy: "exactly_once_per_run"
            )
        case "shortcuts_run":
            return makeIntent(
                kind: "shortcut_ran",
                app: "Shortcuts",
                target: firstString(call.arguments, ["name", "shortcut"]),
                value: firstString(call.arguments, ["input", "text", "value"]),
                tool: call.name,
                repeatPolicy: "exactly_once_per_run"
            )
        case "terminal_run_command":
            return makeIntent(
                kind: "shell_command_submitted",
                app: "Terminal",
                target: "",
                value: firstString(call.arguments, ["command"]),
                tool: call.name,
                repeatPolicy: "exactly_once_per_run"
            )
        case "textedit_save_as":
            return makeIntent(
                kind: "file_saved",
                app: "TextEdit",
                target: firstString(call.arguments, ["path"]),
                value: firstString(call.arguments, ["path"]),
                tool: call.name,
                repeatPolicy: "verified_once_per_run"
            )
        case "finder_create_folder":
            return makeIntent(
                kind: "folder_created",
                app: "Finder",
                target: firstString(call.arguments, ["path"]),
                value: firstString(call.arguments, ["path"]),
                tool: call.name,
                repeatPolicy: "verified_once_per_run"
            )
        case "libreoffice_export_pdf":
            return makeIntent(
                kind: "pdf_exported",
                app: "LibreOffice",
                target: firstString(call.arguments, ["path"]),
                value: [
                    firstString(call.arguments, ["path"]),
                    firstString(call.arguments, ["outdir", "output_dir"])
                ].filter { !$0.isEmpty }.joined(separator: "|"),
                tool: call.name,
                repeatPolicy: "verified_once_per_run"
            )
        default:
            return nil
        }
    }

    static func duplicateDecision(for intent: SideEffectIntent, runID: String) -> PolicyDecision {
        let existing = records(runID: runID, key: intent.key)
        let blockingStatuses = intent.requiresExactlyOnceGuard ? ["submitted", "verified"] : ["verified"]
        guard let prior = existing.last(where: { blockingStatuses.contains($0.status) }) else {
            return PolicyDecision(allowed: true, reason: "No duplicate side effect found.")
        }
        return PolicyDecision(
            allowed: false,
            reason: "Duplicate \(intent.kind) blocked for this run: \(prior.id) is \(prior.status). Verify existing result or ask the user before retrying."
        )
    }

    @discardableResult
    static func recordSubmitted(intent: SideEffectIntent, runID: String) throws -> SideEffectLedgerRecord {
        let now = isoDateString(Date())
        let record = SideEffectLedgerRecord(
            id: "sidefx-\(normalizeID(intent.kind))-\(UUID().uuidString.prefix(8))",
            runID: runID,
            key: intent.key,
            kind: intent.kind,
            app: intent.app,
            target: intent.target,
            value: intent.value,
            tool: intent.tool,
            status: "submitted",
            evidence: "",
            error: "",
            createdAt: now,
            updatedAt: now
        )
        try upsert(record)
        return record
    }

    static func recordResult(intent: SideEffectIntent, runID: String, result: ToolResult) throws {
        var record: SideEffectLedgerRecord
        if let existing = records(runID: runID, key: intent.key).last {
            record = existing
        } else {
            record = try recordSubmitted(intent: intent, runID: runID)
        }
        record.status = result.success && isVerified(result: result, kind: intent.kind) ? "verified" : (result.success ? "submitted" : "failed")
        record.evidence = result.evidence
        record.error = result.error ?? ""
        record.updatedAt = isoDateString(Date())
        try upsert(record)
    }

    static func records(runID: String? = nil, key: String? = nil, limit: Int = 200) -> [SideEffectLedgerRecord] {
        let rows = readAll().filter { record in
            (runID == nil || record.runID == runID) &&
                (key == nil || record.key == key)
        }
        return Array(rows.suffix(max(1, limit)))
    }

    static func clearAllForTesting() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func readAll() -> [SideEffectLedgerRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([SideEffectLedgerRecord].self, from: data)
        else { return [] }
        return records
    }

    private static func upsert(_ record: SideEffectLedgerRecord) throws {
        var rows = readAll()
        if let index = rows.firstIndex(where: { $0.id == record.id }) {
            rows[index] = record
        } else {
            rows.append(record)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: url, options: [.atomic])
    }

    private static func makeIntent(
        kind: String,
        app: String,
        target: String,
        value: String,
        tool: String,
        repeatPolicy: String
    ) -> SideEffectIntent {
        let normalizedParts = [kind, app, target, value, tool].map {
            normalizeForSearch($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return SideEffectIntent(
            key: normalizedParts.joined(separator: "|"),
            kind: kind,
            app: app,
            target: target,
            value: value,
            tool: tool,
            repeatPolicy: repeatPolicy
        )
    }

    private static func firstString(_ args: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let value = string(args[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func chatApp(for tool: String) -> String {
        if tool.hasPrefix("wechat_") { return "WeChat" }
        if tool.hasPrefix("lark_") { return "Lark" }
        if tool.hasPrefix("qq_") { return "QQ" }
        return ""
    }

    private static func isVerified(result: ToolResult, kind: String) -> Bool {
        if MaterialEffectVerificationPolicy.explicitlyVerified(result) == true { return true }
        switch kind {
        case "external_message_sent":
            return result.data["verified_recipient"] == "true" && result.data["verified_message"] == "true"
        case "calendar_event_created":
            return result.success && (result.data["verified"] == "true" || result.data["event_id"] != nil)
        default:
            return result.success
        }
    }
}
