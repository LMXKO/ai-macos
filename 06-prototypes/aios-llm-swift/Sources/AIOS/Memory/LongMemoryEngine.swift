import Foundation

struct LongMemoryEngine {
    static func entityGraph(query: String = "", limit: Int = 30) -> [String: String] {
        let episodes = EpisodeStore.recall(query: query, limit: limit)
        let memories = query.isEmpty ? MemoryStore.recent(limit: limit) : MemoryStore.recall(query: query, limit: limit)
        let graph = ContextGraphStore.query(query, limit: limit)
        var nodes: [[String: String]] = graph.nodes.map { node in
            ["id": node.id, "kind": node.kind, "label": node.label, "updated_at": node.updatedAt]
        }
        var edges: [[String: String]] = graph.edges.map { edge in
            ["from": edge.from, "to": edge.to, "relation": edge.relation, "weight": String(format: "%.2f", edge.weight), "updated_at": edge.updatedAt]
        }
        for episode in episodes {
            nodes.append(["id": "episode:\(episode.id)", "kind": "episode", "label": episode.goal, "updated_at": episode.endedAt])
            for app in episode.apps {
                let appID = "app:\(normalizeID(app))"
                nodes.append(["id": appID, "kind": "app", "label": app, "updated_at": episode.endedAt])
                edges.append(["from": "episode:\(episode.id)", "to": appID, "relation": "touched_app", "weight": "1.00", "updated_at": episode.endedAt])
            }
            for recipe in episode.recipes {
                let recipeID = "recipe:\(normalizeID(recipe))"
                nodes.append(["id": recipeID, "kind": "recipe", "label": recipe, "updated_at": episode.endedAt])
                edges.append(["from": "episode:\(episode.id)", "to": recipeID, "relation": "used_recipe", "weight": "1.00", "updated_at": episode.endedAt])
            }
        }
        for memory in memories {
            let memoryID = "memory:\(memory.id)"
            nodes.append(["id": memoryID, "kind": memory.kind, "label": memory.key, "updated_at": memory.updatedAt])
            if !memory.app.isEmpty {
                edges.append(["from": memoryID, "to": "app:\(normalizeID(memory.app))", "relation": "applies_to_app", "weight": String(format: "%.2f", memory.confidence), "updated_at": memory.updatedAt])
            }
        }
        return [
            "schema": "aios.memory.entity_graph.v1",
            "query": query,
            "nodes": jsonStringValue(dedup(nodes, key: "id").prefix(limit * 4).map { $0 }),
            "edges": jsonStringValue(dedup(edges, key: "from|to|relation").prefix(limit * 5).map { $0 }),
            "memory_count": "\(memories.count)",
            "episode_count": "\(episodes.count)"
        ]
    }

    static func preferenceDigest(query: String = "", limit: Int = 20) -> [String: String] {
        let memories = (query.isEmpty ? MemoryStore.recent(limit: limit * 2) : MemoryStore.recall(query: query, limit: limit * 2)).filter { memory in
            let kind = normalizeForSearch(memory.kind)
            return kind.contains("preference") || kind.contains("hint") || kind.contains("success") || kind.contains("episode")
        }
        let recipes = ((try? RecipeStore.list()) ?? []).sorted {
            (($0.successCount ?? 0) - ($0.failureCount ?? 0)) > (($1.successCount ?? 0) - ($1.failureCount ?? 0))
        }.prefix(limit).map { recipe in
            [
                "id": recipe.id,
                "title": recipe.title,
                "success_count": "\(recipe.successCount ?? 0)",
                "failure_count": "\(recipe.failureCount ?? 0)",
                "required_params": recipe.requiredParams.joined(separator: ",")
            ]
        }
        return [
            "schema": "aios.memory.preference_digest.v1",
            "query": query,
            "preferences": jsonStringValue(Array(memories.prefix(limit)).map(\.dictionary)),
            "recipe_success": jsonStringValue(recipes),
            "context_pack": jsonStringValue(MemoryIndexStore.contextPack(query: query, limit: min(8, max(1, limit / 2))))
        ]
    }

    private static func dedup(_ rows: [[String: String]], key: String) -> [[String: String]] {
        var seen = Set<String>()
        var output: [[String: String]] = []
        for row in rows {
            let identity: String
            if key.contains("|") {
                identity = key.split(separator: "|").map { row[String($0)] ?? "" }.joined(separator: "|")
            } else {
                identity = row[key] ?? jsonStringValue(row)
            }
            if !seen.contains(identity) {
                seen.insert(identity)
                output.append(row)
            }
        }
        return output
    }
}
