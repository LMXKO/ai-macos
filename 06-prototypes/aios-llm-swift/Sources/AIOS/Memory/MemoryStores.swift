import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Security
import ScriptingBridge
import SQLite3
import SwiftUI
import Vision

struct MemoryEntry: Codable {
    let id: String
    let kind: String
    let scope: String
    let app: String
    let key: String
    let value: String
    let confidence: Double
    let createdAt: String
    let updatedAt: String
    let sourceRunID: String
    let sourceTool: String

    var dictionary: [String: String] {
        [
            "id": id,
            "kind": kind,
            "scope": scope,
            "app": app,
            "key": key,
            "value": value,
            "confidence": String(format: "%.2f", confidence),
            "created_at": createdAt,
            "updated_at": updatedAt,
            "source_run_id": sourceRunID,
            "source_tool": sourceTool
        ]
    }
}

struct MemoryStore {
    static var url: URL {
        EventStore.memoryURL.appendingPathComponent("memory.jsonl")
    }

    @discardableResult
    static func remember(
        kind: String,
        scope: String,
        app: String,
        key: String,
        value: String,
        confidence: Double = 0.8,
        sourceRunID: String? = nil,
        sourceTool: String? = nil
    ) throws -> MemoryEntry {
        guard let safeKey = sanitized(key), let safeValue = sanitized(value) else {
            throw RuntimeError("Memory entry rejected because it is empty or sensitive.")
        }
        let safeKind = sanitizedIdentifier(kind, fallback: "note")
        let safeScope = sanitizedIdentifier(scope, fallback: "global")
        let safeApp = sanitized(app) ?? ""
        let safeTool = sanitized(sourceTool ?? "") ?? ""
        let safeRun = sanitized(sourceRunID ?? "") ?? ""
        let now = isoDateString(Date())
        var entries = readAll()
        let existingIndex = entries.firstIndex { existing in
            existing.kind == safeKind &&
            existing.scope == safeScope &&
            existing.app == safeApp &&
            existing.key.caseInsensitiveCompare(safeKey) == .orderedSame
        }
        let existing = existingIndex.map { entries[$0] }
        let entry = MemoryEntry(
            id: existing?.id ?? "M\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))",
            kind: safeKind,
            scope: safeScope,
            app: safeApp,
            key: safeKey,
            value: safeValue,
            confidence: min(1.0, max(0.0, confidence)),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            sourceRunID: safeRun,
            sourceTool: safeTool
        )
        if let existingIndex {
            entries[existingIndex] = entry
        } else {
            entries.append(entry)
        }
        if entries.count > 1_000 {
            entries = Array(entries.sorted { $0.updatedAt < $1.updatedAt }.suffix(1_000))
        }
        try writeAll(entries)
        return entry
    }

    static func recall(query: String, limit: Int = 8, kind: String? = nil, app: String? = nil) -> [MemoryEntry] {
        let normalizedQuery = normalized(query)
        let tokens = Set(memoryTokens(from: normalizedQuery))
        let safeLimit = min(50, max(1, limit))
        let kindFilter = kind.flatMap { sanitizedIdentifier($0, fallback: "") }.flatMap { $0.isEmpty ? nil : $0 }
        let appFilter = app.flatMap { sanitized($0)?.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        let filtered = readAll().filter { entry in
            if let kindFilter, entry.kind != kindFilter { return false }
            if let appFilter, !entry.app.lowercased().contains(appFilter) { return false }
            return true
        }
        if normalizedQuery.isEmpty {
            return Array(filtered.sorted { $0.updatedAt > $1.updatedAt }.prefix(safeLimit))
        }
        let scored = filtered.compactMap { entry -> (entry: MemoryEntry, score: Int)? in
            let haystack = normalized([entry.kind, entry.scope, entry.app, entry.key, entry.value].joined(separator: " "))
            var score = 0
            if haystack.contains(normalizedQuery) { score += 8 }
            for token in tokens where token.count >= 2 && haystack.contains(token) {
                score += 2
            }
            if !entry.app.isEmpty && normalizedQuery.contains(normalized(entry.app)) { score += 2 }
            guard score > 0 else { return nil }
            return (entry, score)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.entry.confidence != rhs.entry.confidence { return lhs.entry.confidence > rhs.entry.confidence }
                return lhs.entry.updatedAt > rhs.entry.updatedAt
            }
            .prefix(safeLimit)
            .map(\.entry)
    }

    static func recent(limit: Int = 10) -> [MemoryEntry] {
        Array(readAll().sorted { $0.updatedAt > $1.updatedAt }.prefix(min(50, max(1, limit))))
    }

    static func contextText(for goal: String, limit: Int = 6) -> String {
        let entries = recall(query: goal, limit: limit)
        guard !entries.isEmpty else {
            return "No relevant durable memory yet."
        }
        return entries.map { entry in
            let app = entry.app.isEmpty ? "" : " app=\(entry.app)"
            return "- [\(entry.kind)]\(app) \(entry.key): \(entry.value)"
        }.joined(separator: "\n")
    }

    @discardableResult
    static func rememberToolResult(call: ToolCall, result: ToolResult, runID: String?) -> [MemoryEntry] {
        guard result.success else { return [] }
        var entries: [MemoryEntry] = []
        func add(kind: String, scope: String, app: String, key: String, value: String, confidence: Double = 0.65) {
            if let entry = try? remember(
                kind: kind,
                scope: scope,
                app: app,
                key: key,
                value: value,
                confidence: confidence,
                sourceRunID: runID,
                sourceTool: call.name
            ) {
                entries.append(entry)
            }
        }

        let app = string(call.arguments["app_name"]) ??
            string(call.arguments["bundle_id"]) ??
            result.data["app"] ??
            result.data["bundle_id"] ??
            appName(from: call.name)
        let query = string(call.arguments["query"]) ??
            string(call.arguments["locator_id"]) ??
            string(call.arguments["role"]) ??
            ""

        if call.name == "recipe_execute", let recipeID = string(call.arguments["id"]) {
            add(
                kind: "recipe_success",
                scope: "workflow",
                app: app,
                key: recipeID,
                value: "Recipe executed successfully. Prefer recipe_suggest/recipe_execute before manual replay for similar goals.",
                confidence: 0.85
            )
        }

        if call.name.hasPrefix("aios_background_") {
            let key = [call.name, app, query].filter { !$0.isEmpty }.joined(separator: " ")
            add(
                kind: "non_intrusive_locator",
                scope: "automation",
                app: app,
                key: key.isEmpty ? call.name : key,
                value: "Semantic background AX action succeeded; prefer this before foreground coordinate fallback.",
                confidence: 0.8
            )
        } else if ["aios_click", "aios_type", "aios_find", "aios_read", "aios_wait"].contains(call.name), !query.isEmpty {
            let key = [call.name, app, query].filter { !$0.isEmpty }.joined(separator: " ")
            add(
                kind: "locator_hint",
                scope: "automation",
                app: app,
                key: key,
                value: "Locator path worked for this app/task context.",
                confidence: 0.7
            )
        }

        if call.name.hasPrefix("visual_") {
            let key = [call.name, app, query].filter { !$0.isEmpty }.joined(separator: " ")
            add(
                kind: "visual_hint",
                scope: "fallback",
                app: app,
                key: key.isEmpty ? call.name : key,
                value: "Visual OCR fallback succeeded; use when AX locators are missing or stale.",
                confidence: 0.65
            )
        }

        if let effect = result.data["effect"] {
            let target = result.data["target"] ??
                result.data["recipient"] ??
                result.data["chat"] ??
                result.data["title"] ??
                result.data["path"] ??
                result.data["url"] ??
                call.name
            add(
                kind: "verified_effect",
                scope: "completion",
                app: app,
                key: "\(effect) \(target)",
                value: "Verified effect via \(call.name): \(result.evidence)",
                confidence: bool(result.data["verified"]) == true ? 0.9 : 0.7
            )
        }

        return entries
    }

    static func readAll() -> [MemoryEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(MemoryEntry.self, from: data)
        }
    }

    private static func writeAll(_ entries: [MemoryEntry]) throws {
        try FileManager.default.createDirectory(at: EventStore.memoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try entries.map { entry -> String in
            let data = try encoder.encode(entry)
            return String(data: data, encoding: .utf8) ?? ""
        }.filter { !$0.isEmpty }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func sanitizedIdentifier(_ value: String, fallback: String) -> String {
        let cleaned = value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_\\-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(48))
    }

    private static func sanitized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !containsSensitiveText(trimmed) else { return nil }
        let compact = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return truncateMiddle(compact, maxCharacters: 700)
    }

    private static func containsSensitiveText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let terms = [
            "password",
            "passcode",
            "credential",
            "secret",
            "private key",
            "api_key",
            "apikey",
            "access_token",
            "refresh_token",
            "bearer ",
            "密码",
            "口令",
            "密钥",
            "令牌",
            "银行卡",
            "支付"
        ]
        if terms.contains(where: { lowered.contains($0) }) {
            return true
        }
        let patterns = [
            #"sk-[A-Za-z0-9_\-]{16,}"#,
            #"AKIA[0-9A-Z]{16}"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"(token|secret|password|api[_-]?key)\s*[:=]\s*['"]?[^'"\s]{8,}"#
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private static func memoryTokens(from text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return text.components(separatedBy: separators).flatMap { raw -> [String] in
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return [] }
            if term.count <= 10 { return [term] }
            let domainTerms = ["wechat", "微信", "lark", "飞书", "qq", "calendar", "日历", "finder", "pdf", "recipe", "visual", "ocr"]
            return [term] + domainTerms.filter { term.contains($0) }
        }
    }

    private static func appName(from toolName: String) -> String {
        if toolName.hasPrefix("wechat_") { return "WeChat" }
        if toolName.hasPrefix("lark_") { return "Lark" }
        if toolName.hasPrefix("qq_") { return "QQ" }
        if toolName.hasPrefix("safari_") { return "Safari" }
        if toolName.hasPrefix("chrome_") { return "Chrome" }
        if toolName.hasPrefix("calendar_") { return "Calendar" }
        if toolName.hasPrefix("reminders_") { return "Reminders" }
        if toolName.hasPrefix("notes_") { return "Notes" }
        if toolName.hasPrefix("mail_") { return "Mail" }
        if toolName.hasPrefix("textedit_") { return "TextEdit" }
        if toolName.hasPrefix("finder_") { return "Finder" }
        return ""
    }
}

struct Episode: Codable {
    let id: String
    let runID: String
    let goal: String
    let outcome: String
    let startedAt: String
    let endedAt: String
    let steps: [String]
    let tools: [String]
    let apps: [String]
    let recipes: [String]
    let memoryKeys: [String]
    let summary: String

    var dictionary: [String: String] {
        [
            "id": id,
            "run_id": runID,
            "goal": goal,
            "outcome": outcome,
            "started_at": startedAt,
            "ended_at": endedAt,
            "steps": steps.joined(separator: ","),
            "tools": tools.joined(separator: ","),
            "apps": apps.joined(separator: ","),
            "recipes": recipes.joined(separator: ","),
            "memory_keys": memoryKeys.joined(separator: ","),
            "summary": summary
        ]
    }
}

struct EpisodeStore {
    static var url: URL {
        EventStore.episodesURL.appendingPathComponent("episodes.jsonl")
    }

    @discardableResult
    static func record(runID: String, goal: String, plan: TaskPlan, outcome: String, eventsText: String) -> Episode {
        let events = parseEvents(eventsText)
        let tools = unique(events.compactMap { $0["tool"] })
        let recipes = unique(events.compactMap { event in
            event["recipe_id"] ?? (event["tool"] == "recipe_execute" ? event["arguments"] : nil)
        }.map { truncateMiddle($0, maxCharacters: 80) })
        let apps = unique(events.flatMap { event -> [String] in
            [
                event["app"],
                event["target_app"],
                event["bundle_id"],
                event["target_bundle_id"]
            ].compactMap { $0 }.filter { !$0.isEmpty }
        })
        let memoryKeys = unique(events.compactMap { event in
            event["event"] == "MemoryRemembered" ? event["key"] : nil
        })
        let started = events.first?["time"] ?? isoDateString(Date())
        let ended = events.last?["time"] ?? isoDateString(Date())
        let stepLines = plan.steps.map { "\($0.id):\($0.status.rawValue):\($0.title)" }
        let summary = "\(outcome): \(goal) | steps=\(plan.steps.count) tools=\(tools.prefix(8).joined(separator: ","))"
        let episode = Episode(
            id: "EP-\(runID)",
            runID: runID,
            goal: goal,
            outcome: outcome,
            startedAt: started,
            endedAt: ended,
            steps: stepLines,
            tools: tools,
            apps: apps,
            recipes: recipes,
            memoryKeys: memoryKeys,
            summary: summary
        )
        try? append(episode)
        ContextGraphStore.ingest(episode: episode)
        return episode
    }

    static func list(limit: Int = 20) -> [Episode] {
        Array(readAll().sorted { $0.endedAt > $1.endedAt }.prefix(min(100, max(1, limit))))
    }

    static func recall(query: String, limit: Int = 8) -> [Episode] {
        let normalizedQuery = normalizeForSearch(query)
        guard !normalizedQuery.isEmpty else { return list(limit: limit) }
        let tokens = Set(normalizedQuery.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty })
        let scored = readAll().compactMap { episode -> (Episode, Int)? in
            let haystack = normalizeForSearch([episode.goal, episode.summary, episode.tools.joined(separator: " "), episode.apps.joined(separator: " ")].joined(separator: " "))
            var score = haystack.contains(normalizedQuery) ? 8 : 0
            for token in tokens where token.count >= 2 && haystack.contains(token) {
                score += 2
            }
            guard score > 0 else { return nil }
            return (episode, score)
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.endedAt > $1.0.endedAt
        }.prefix(min(50, max(1, limit))).map(\.0)
    }

    private static func append(_ episode: Episode) throws {
        try FileManager.default.createDirectory(at: EventStore.episodesURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(episode)
        let line = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func readAll() -> [Episode] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = line.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode(Episode.self, from: data)
        }
    }

    static func parseEvents(_ text: String) -> [[String: String]] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return raw.reduce(into: [String: String]()) { result, pair in
                if let value = pair.value as? String {
                    result[pair.key] = value
                } else if let value = pair.value as? NSNumber {
                    result[pair.key] = value.stringValue
                }
            }
        }
    }
}

struct ContextNode: Codable {
    let id: String
    let kind: String
    let label: String
    let attributes: [String: String]
    let updatedAt: String
}

struct ContextEdge: Codable {
    let from: String
    let to: String
    let relation: String
    let weight: Double
    let updatedAt: String
}

struct ContextGraphStore {
    static var nodesURL: URL {
        EventStore.contextGraphURL.appendingPathComponent("nodes.json")
    }

    static var edgesURL: URL {
        EventStore.contextGraphURL.appendingPathComponent("edges.json")
    }

    static func ingest(episode: Episode) {
        let now = isoDateString(Date())
        var nodes = readNodes()
        var edges = readEdges()
        upsertNode(&nodes, ContextNode(id: "episode:\(episode.id)", kind: "episode", label: episode.goal, attributes: episode.dictionary, updatedAt: now))
        for app in episode.apps {
            let appID = "app:\(normalizeID(app))"
            upsertNode(&nodes, ContextNode(id: appID, kind: "app", label: app, attributes: ["name": app], updatedAt: now))
            upsertEdge(&edges, ContextEdge(from: "episode:\(episode.id)", to: appID, relation: "used_app", weight: 1, updatedAt: now))
        }
        for tool in episode.tools {
            let toolID = "tool:\(normalizeID(tool))"
            upsertNode(&nodes, ContextNode(id: toolID, kind: "tool", label: tool, attributes: ["name": tool], updatedAt: now))
            upsertEdge(&edges, ContextEdge(from: "episode:\(episode.id)", to: toolID, relation: "used_tool", weight: 1, updatedAt: now))
        }
        for recipe in episode.recipes {
            let recipeID = "recipe:\(normalizeID(recipe))"
            upsertNode(&nodes, ContextNode(id: recipeID, kind: "recipe", label: recipe, attributes: ["id": recipe], updatedAt: now))
            upsertEdge(&edges, ContextEdge(from: "episode:\(episode.id)", to: recipeID, relation: "used_recipe", weight: 1, updatedAt: now))
        }
        try? write(nodes: nodes, edges: edges)
    }

    static func query(_ text: String, limit: Int = 20) -> (nodes: [ContextNode], edges: [ContextEdge]) {
        let normalizedQuery = normalizeForSearch(text)
        let nodes = readNodes()
        let matched = nodes.filter { node in
            normalizedQuery.isEmpty ||
            normalizeForSearch([node.id, node.kind, node.label, node.attributes.values.joined(separator: " ")].joined(separator: " ")).contains(normalizedQuery)
        }.prefix(min(100, max(1, limit)))
        let ids = Set(matched.map(\.id))
        let edges = readEdges().filter { ids.contains($0.from) || ids.contains($0.to) }.prefix(min(200, max(1, limit * 3)))
        return (Array(matched), Array(edges))
    }

    static func ingest(
        fromKind: String,
        fromLabel: String,
        toKind: String,
        toLabel: String,
        relation: String,
        weight: Double = 1,
        attributes: [String: String] = [:]
    ) {
        let now = isoDateString(Date())
        var nodes = readNodes()
        var edges = readEdges()
        let fromID = "\(normalizeID(fromKind)):\(normalizeID(fromLabel))"
        let toID = "\(normalizeID(toKind)):\(normalizeID(toLabel))"
        upsertNode(&nodes, ContextNode(id: fromID, kind: fromKind, label: fromLabel, attributes: attributes, updatedAt: now))
        upsertNode(&nodes, ContextNode(id: toID, kind: toKind, label: toLabel, attributes: attributes, updatedAt: now))
        upsertEdge(&edges, ContextEdge(from: fromID, to: toID, relation: relation, weight: weight, updatedAt: now))
        try? write(nodes: nodes, edges: edges)
    }

    private static func readNodes() -> [ContextNode] {
        guard let data = try? Data(contentsOf: nodesURL),
              let nodes = try? JSONDecoder().decode([ContextNode].self, from: data)
        else { return [] }
        return nodes
    }

    private static func readEdges() -> [ContextEdge] {
        guard let data = try? Data(contentsOf: edgesURL),
              let edges = try? JSONDecoder().decode([ContextEdge].self, from: data)
        else { return [] }
        return edges
    }

    private static func write(nodes: [ContextNode], edges: [ContextEdge]) throws {
        try FileManager.default.createDirectory(at: EventStore.contextGraphURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(nodes).write(to: nodesURL, options: [.atomic])
        try encoder.encode(edges).write(to: edgesURL, options: [.atomic])
    }

    private static func upsertNode(_ nodes: inout [ContextNode], _ node: ContextNode) {
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index] = node
        } else {
            nodes.append(node)
        }
    }

    private static func upsertEdge(_ edges: inout [ContextEdge], _ edge: ContextEdge) {
        if let index = edges.firstIndex(where: { $0.from == edge.from && $0.to == edge.to && $0.relation == edge.relation }) {
            let existing = edges[index]
            edges[index] = ContextEdge(from: edge.from, to: edge.to, relation: edge.relation, weight: existing.weight + edge.weight, updatedAt: edge.updatedAt)
        } else {
            edges.append(edge)
        }
    }
}
