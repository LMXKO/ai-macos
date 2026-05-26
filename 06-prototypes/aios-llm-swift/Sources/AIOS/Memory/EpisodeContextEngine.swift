import Foundation

struct EpisodeContextEngine {
    static func consolidate(runID: String, outcome: String = "unknown") throws -> [String: String] {
        let summary = try EventStore.readSummary(runID: runID)
        let eventsText = try EventStore.readEventsText(runID: runID)
        let plan = TaskPlan.fallback(goal: summary.goal)
        let episode = EpisodeStore.record(runID: runID, goal: summary.goal, plan: plan, outcome: outcome, eventsText: eventsText)
        let events = EpisodeStore.parseEvents(eventsText)
        let tools = unique(events.compactMap { $0["tool"] })
        let apps = unique(events.compactMap { $0["app"] } + events.compactMap { $0["app_name"] })
        for tool in tools {
            ContextGraphStore.ingest(fromKind: "episode", fromLabel: episode.id, toKind: "tool", toLabel: tool, relation: "used_tool", weight: 1, attributes: ["run_id": runID])
        }
        for app in apps where !app.isEmpty {
            ContextGraphStore.ingest(fromKind: "episode", fromLabel: episode.id, toKind: "app", toLabel: app, relation: "touched_app", weight: 1, attributes: ["run_id": runID])
        }
        if let recipe = (try? RecipeStore.suggest(goal: summary.goal, limit: 1).first?.recipe.id) ?? nil {
            ContextGraphStore.ingest(fromKind: "episode", fromLabel: episode.id, toKind: "recipe", toLabel: recipe, relation: "candidate_recipe", weight: 0.6, attributes: ["run_id": runID])
        }
        let remembered = try? MemoryStore.remember(
            kind: "episode_summary",
            scope: "long_task",
            app: apps.first ?? "",
            key: summary.goal,
            value: episode.summary,
            confidence: outcome == "success" ? 0.85 : 0.65,
            sourceRunID: runID,
            sourceTool: "memory_episode_consolidate"
        )
        let profile = MemoryStore.contextText(for: summary.goal, limit: 8)
        let indexItems = (try? MemoryIndexStore.rebuild()) ?? []
        return [
            "schema": "aios.memory.episode_context.v1",
            "episode": jsonStringValue(episode.dictionary),
            "tools": tools.joined(separator: ","),
            "apps": apps.joined(separator: ","),
            "remembered_episode_memory": remembered?.id ?? "",
            "profile": profile,
            "index_items": "\(indexItems.count)"
        ]
    }

    static func shadowDigest(limit: Int = 20) -> [String: String] {
        let episodes = EpisodeStore.recall(query: "", limit: limit)
        let memories = MemoryStore.recent(limit: limit)
        let graph = ContextGraphStore.query("", limit: limit)
        return [
            "schema": "aios.memory.shadow_digest.v1",
            "episodes": jsonStringValue(episodes.map(\.dictionary)),
            "memories": jsonStringValue(memories.map(\.dictionary)),
            "graph": jsonStringValue([
                "nodes": graph.nodes.map { ["id": $0.id, "kind": $0.kind, "label": $0.label, "attributes": jsonStringValue($0.attributes), "updated_at": $0.updatedAt] },
                "edges": graph.edges.map { ["from": $0.from, "to": $0.to, "relation": $0.relation, "weight": "\($0.weight)", "updated_at": $0.updatedAt] }
            ]),
            "consolidation": "episodes + memories + context graph + recipes + skills are folded into memory_context_pack for long tasks."
        ]
    }
}
