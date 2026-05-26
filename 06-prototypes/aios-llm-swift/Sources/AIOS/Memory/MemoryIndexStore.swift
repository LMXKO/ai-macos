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

struct MemoryIndexItem: Codable {
    let id: String
    let kind: String
    let label: String
    let text: String
    let source: String
    let updatedAt: String
    let vector: [String: Double]

    var dictionary: [String: String] {
        [
            "id": id,
            "kind": kind,
            "label": label,
            "text": truncateMiddle(text, maxCharacters: 900),
            "source": source,
            "updated_at": updatedAt
        ]
    }
}

struct MemoryIndexStore {
    static var url: URL {
        EventStore.memoryURL.appendingPathComponent("index.json")
    }

    @discardableResult
    static func rebuild() throws -> [MemoryIndexItem] {
        var items: [MemoryIndexItem] = []
        let now = isoDateString(Date())

        items.append(contentsOf: MemoryStore.readAll().map { memory in
            makeItem(
                id: "memory:\(memory.id)",
                kind: "memory.\(memory.kind)",
                label: memory.key,
                text: [memory.scope, memory.app, memory.key, memory.value].joined(separator: " "),
                source: "memory",
                updatedAt: memory.updatedAt
            )
        })

        items.append(contentsOf: EpisodeStore.list(limit: 100).map { episode in
            makeItem(
                id: "episode:\(episode.id)",
                kind: "episode.\(episode.outcome)",
                label: episode.goal,
                text: [episode.goal, episode.summary, episode.steps.joined(separator: " "), episode.tools.joined(separator: " "), episode.apps.joined(separator: " "), episode.recipes.joined(separator: " ")].joined(separator: " "),
                source: "episode",
                updatedAt: episode.endedAt
            )
        })

        let graph = ContextGraphStore.query("", limit: 200)
        items.append(contentsOf: graph.nodes.map { node in
            makeItem(
                id: "graph:\(node.id)",
                kind: "graph.\(node.kind)",
                label: node.label,
                text: [node.kind, node.label, node.attributes.values.joined(separator: " ")].joined(separator: " "),
                source: "context_graph",
                updatedAt: node.updatedAt
            )
        })

        let recipes = (try? RecipeStore.list()) ?? []
        items.append(contentsOf: recipes.map { recipe in
            makeItem(
                id: "recipe:\(recipe.id)",
                kind: "recipe",
                label: recipe.title,
                text: [recipe.id, recipe.title, recipe.goalTemplate, recipe.notes, recipe.requiredParams.joined(separator: " "), recipe.steps.map { "\($0.title) \($0.tool) \($0.arguments.values.joined(separator: " "))" }.joined(separator: " ")].joined(separator: " "),
                source: "recipe",
                updatedAt: now
            )
        })

        items.append(contentsOf: AppSkillStore.list().map { skill in
            makeItem(
                id: "skill:\(skill.id)",
                kind: "app_skill",
                label: skill.appName,
                text: [skill.id, skill.appName, skill.bundleID, skill.capabilities.joined(separator: " "), skill.tools.joined(separator: " "), skill.recipes.joined(separator: " "), skill.notes].joined(separator: " "),
                source: "app_skill",
                updatedAt: now
            )
        })

        if let runs = try? EventStore.listRuns() {
            items.append(contentsOf: runs.prefix(200).map { run in
                makeItem(
                    id: "run:\(run.id)",
                    kind: "run.\(run.status)",
                    label: run.goal,
                    text: [run.goal, run.status, run.id].joined(separator: " "),
                    source: "run_summary",
                    updatedAt: run.updatedAt
                )
            })
        }

        let deduped = dedupe(items)
        try FileManager.default.createDirectory(at: EventStore.memoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(deduped).write(to: url, options: [.atomic])
        return deduped
    }

    static func recall(query: String, limit: Int = 10, kinds: [String] = []) -> [(item: MemoryIndexItem, score: Double)] {
        let items = readOrBuild()
        let queryVector = vectorize(query)
        guard !queryVector.isEmpty else {
            return Array(items.sorted { $0.updatedAt > $1.updatedAt }.prefix(min(50, max(1, limit)))).map { ($0, 0) }
        }
        let kindFilters = Set(kinds.map { normalizeForSearch($0) }.filter { !$0.isEmpty })
        return items.compactMap { item -> (MemoryIndexItem, Double)? in
            if !kindFilters.isEmpty {
                let normalizedKind = normalizeForSearch(item.kind)
                guard kindFilters.contains(where: { normalizedKind.contains($0) }) else { return nil }
            }
            var score = cosine(queryVector, item.vector)
            let haystack = normalizeForSearch([item.label, item.text, item.kind].joined(separator: " "))
            let normalizedQuery = normalizeForSearch(query)
            if haystack.contains(normalizedQuery), !normalizedQuery.isEmpty { score += 0.25 }
            if item.source == "episode" { score += 0.03 }
            if item.source == "memory" { score += 0.04 }
            guard score > 0.01 else { return nil }
            return (item, score)
        }
        .sorted {
            if abs($0.1 - $1.1) > 0.0001 { return $0.1 > $1.1 }
            return $0.0.updatedAt > $1.0.updatedAt
        }
        .prefix(min(50, max(1, limit)))
        .map { $0 }
    }

    static func contextPack(query: String, limit: Int = 8) -> [String: String] {
        let hits = recall(query: query, limit: limit)
        let graph = ContextGraphStore.query(query, limit: limit)
        let memoryHits = hits.filter { $0.item.source == "memory" }.map { scoredDictionary($0) }
        let episodeHits = hits.filter { $0.item.source == "episode" || $0.item.source == "run_summary" }.map { scoredDictionary($0) }
        let recipeHits = hits.filter { $0.item.source == "recipe" }.map { scoredDictionary($0) }
        let skillHits = hits.filter { $0.item.source == "app_skill" }.map { scoredDictionary($0) }
        let graphHits = hits.filter { $0.item.source == "context_graph" }.map { scoredDictionary($0) }
        return [
            "schema": "aios.memory.context_pack.v1",
            "query": query,
            "semantic_hits": jsonStringValue(hits.map(scoredDictionary)),
            "memory_hits": jsonStringValue(memoryHits),
            "episode_hits": jsonStringValue(episodeHits),
            "recipe_hits": jsonStringValue(recipeHits),
            "skill_hits": jsonStringValue(skillHits),
            "graph_hits": jsonStringValue(graphHits),
            "graph_nodes": jsonStringValue(graph.nodes.map { ["id": $0.id, "kind": $0.kind, "label": $0.label] }),
            "graph_edges": jsonStringValue(graph.edges.map { ["from": $0.from, "to": $0.to, "relation": $0.relation, "weight": String(format: "%.2f", $0.weight)] })
        ]
    }

    static func readAll() -> [MemoryIndexItem] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([MemoryIndexItem].self, from: data)
        else { return [] }
        return items
    }

    private static func readOrBuild() -> [MemoryIndexItem] {
        let items = readAll()
        if !items.isEmpty { return items }
        return (try? rebuild()) ?? []
    }

    private static func makeItem(id: String, kind: String, label: String, text: String, source: String, updatedAt: String) -> MemoryIndexItem {
        let compactText = truncateMiddle(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression), maxCharacters: 4_000)
        return MemoryIndexItem(
            id: id,
            kind: kind,
            label: truncateMiddle(label, maxCharacters: 300),
            text: compactText,
            source: source,
            updatedAt: updatedAt,
            vector: vectorize([kind, label, compactText].joined(separator: " "))
        )
    }

    private static func dedupe(_ items: [MemoryIndexItem]) -> [MemoryIndexItem] {
        var seen = Set<String>()
        var output: [MemoryIndexItem] = []
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            output.append(item)
        }
        return output
    }

    private static func scoredDictionary(_ scored: (item: MemoryIndexItem, score: Double)) -> [String: String] {
        var dictionary = scored.item.dictionary
        dictionary["score"] = String(format: "%.4f", scored.score)
        return dictionary
    }

    private static func vectorize(_ text: String) -> [String: Double] {
        var counts: [String: Double] = [:]
        for token in tokens(text) {
            counts[token, default: 0] += 1
        }
        let norm = sqrt(counts.values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return [:] }
        return counts.mapValues { $0 / norm }
    }

    private static func cosine(_ lhs: [String: Double], _ rhs: [String: Double]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let small = lhs.count <= rhs.count ? lhs : rhs
        let large = lhs.count <= rhs.count ? rhs : lhs
        return small.reduce(0) { partial, pair in
            partial + pair.value * (large[pair.key] ?? 0)
        }
    }

    private static func tokens(_ text: String) -> [String] {
        let normalized = normalizeForSearch(text)
        var output: [String] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        for raw in normalized.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            output.append(token)
            if token.count > 4 {
                output.append(String(token.prefix(4)))
                output.append(String(token.suffix(4)))
            }
        }
        let scalars = normalized.unicodeScalars.map(String.init)
        for scalar in scalars where scalar.range(of: #"[\u{4e00}-\u{9fff}]"#, options: .regularExpression) != nil {
            output.append(scalar)
        }
        if scalars.count >= 2 {
            for index in 0..<(scalars.count - 1) {
                let pair = scalars[index] + scalars[index + 1]
                if pair.range(of: #"[\u{4e00}-\u{9fff}]"#, options: .regularExpression) != nil {
                    output.append(pair)
                }
            }
        }
        return output.filter { $0.count > 1 || $0.range(of: #"[\u{4e00}-\u{9fff}]"#, options: .regularExpression) != nil }
    }
}
