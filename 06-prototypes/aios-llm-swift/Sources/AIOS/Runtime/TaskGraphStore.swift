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

struct DurableTaskGraph: Codable {
    var schema: String
    var id: String
    var title: String
    var goal: String
    var status: String
    var createdAt: String
    var updatedAt: String
    var nodes: [DurableTaskNode]

    var dictionary: [String: String] {
        [
            "schema": schema,
            "id": id,
            "title": title,
            "goal": goal,
            "status": status,
            "created_at": createdAt,
            "updated_at": updatedAt,
            "nodes": jsonStringValue(nodes.map(\.dictionary))
        ]
    }
}

struct DurableTaskNode: Codable {
    var id: String
    var title: String
    var goal: String
    var status: String
    var dependsOn: [String]
    var runID: String?
    var waitCondition: String?
    var waitValue: String?
    var notBefore: String?
    var attempts: Int
    var updatedAt: String

    var dictionary: [String: String] {
        [
            "id": id,
            "title": title,
            "goal": goal,
            "status": status,
            "depends_on": dependsOn.joined(separator: ","),
            "run_id": runID ?? "",
            "wait_condition": waitCondition ?? "",
            "wait_value": waitValue ?? "",
            "not_before": notBefore ?? "",
            "attempts": "\(attempts)",
            "updated_at": updatedAt
        ]
    }
}

struct TaskGraphTickResult {
    var graphID: String
    var scheduled: [String]
    var completed: [String]
    var failed: [String]
    var waiting: [String]

    var dictionary: [String: String] {
        [
            "graph_id": graphID,
            "scheduled": scheduled.joined(separator: ","),
            "completed": completed.joined(separator: ","),
            "failed": failed.joined(separator: ","),
            "waiting": waiting.joined(separator: ",")
        ]
    }
}

struct TaskGraphStore {
    static let schema = "aios.task_graph.v1"

    static var rootURL: URL {
        EventStore.rootURL.appendingPathComponent("task-graphs", isDirectory: true)
    }

    static func url(id: String) -> URL {
        rootURL.appendingPathComponent("\(normalizeID(id)).json")
    }

    @discardableResult
    static func create(title: String, goal: String, nodes: [DurableTaskNode]) throws -> DurableTaskGraph {
        let now = isoDateString(Date())
        let id = "TG-\(normalizeID(title.isEmpty ? goal : title))-\(Int(Date().timeIntervalSince1970))"
        let graph = DurableTaskGraph(
            schema: schema,
            id: id,
            title: title.isEmpty ? goal : title,
            goal: goal,
            status: "active",
            createdAt: now,
            updatedAt: now,
            nodes: nodes.isEmpty ? [
                DurableTaskNode(id: "N1", title: "Run goal", goal: goal, status: "pending", dependsOn: [], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now)
            ] : nodes
        )
        try save(graph)
        return graph
    }

    static func list() -> [DurableTaskGraph] {
        guard FileManager.default.fileExists(atPath: rootURL.path),
              let urls = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(DurableTaskGraph.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func read(_ id: String) throws -> DurableTaskGraph {
        let candidates = [url(id: id)] + list().filter { $0.id == id }.map { url(id: $0.id) }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            return try JSONDecoder().decode(DurableTaskGraph.self, from: data)
        }
        throw RuntimeError("Task graph not found: \(id)")
    }

    static func save(_ graph: DurableTaskGraph) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(graph).write(to: url(id: graph.id), options: [.atomic])
    }

    @discardableResult
    static func tick(graphID: String? = nil) throws -> [TaskGraphTickResult] {
        let graphs = graphID.flatMap { try? [read($0)] } ?? list()
        var results: [TaskGraphTickResult] = []
        for var graph in graphs where graph.status == "active" || graph.status == "waiting" {
            var result = TaskGraphTickResult(graphID: graph.id, scheduled: [], completed: [], failed: [], waiting: [])
            var completedIDs = Set(graph.nodes.filter { $0.status == "complete" }.map(\.id))
            for index in graph.nodes.indices {
                var node = graph.nodes[index]
                if node.status == "running", let runID = node.runID, let summary = try? EventStore.readSummary(runID: runID) {
                    if summary.status == "complete" {
                        node.status = "complete"
                        node.updatedAt = isoDateString(Date())
                        completedIDs.insert(node.id)
                        result.completed.append(node.id)
                    } else if ["failed", "canceled"].contains(summary.status) {
                        node.status = "failed"
                        node.updatedAt = isoDateString(Date())
                        result.failed.append(node.id)
                    }
                    graph.nodes[index] = node
                    continue
                }
                guard node.status == "pending" || node.status == "waiting" || node.status == "queued" else { continue }
                guard Set(node.dependsOn).isSubset(of: completedIDs) else {
                    result.waiting.append(node.id)
                    continue
                }
                guard watcherReady(node) else {
                    node.status = "waiting"
                    node.updatedAt = isoDateString(Date())
                    graph.nodes[index] = node
                    result.waiting.append(node.id)
                    continue
                }
                let runID = try TaskQueue.submit(goal: node.goal, notBefore: node.notBefore)
                node.status = node.notBefore == nil ? "running" : "waiting"
                node.runID = runID
                node.attempts += 1
                node.updatedAt = isoDateString(Date())
                graph.nodes[index] = node
                result.scheduled.append(node.id)
            }
            graph.status = graph.nodes.allSatisfy { $0.status == "complete" } ? "complete" :
                graph.nodes.contains(where: { $0.status == "failed" }) ? "failed" :
                graph.nodes.contains(where: { $0.status == "waiting" }) ? "waiting" : "active"
            graph.updatedAt = isoDateString(Date())
            try save(graph)
            results.append(result)
        }
        return results
    }

    static func nodes(from rawJSON: String, fallbackGoal: String) throws -> [DurableTaskNode] {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data = Data(trimmed.utf8)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw RuntimeError("nodes_json must be a JSON array")
        }
        let now = isoDateString(Date())
        return raw.enumerated().map { offset, item in
            DurableTaskNode(
                id: string(item["id"]) ?? "N\(offset + 1)",
                title: string(item["title"]) ?? string(item["goal"]) ?? "Node \(offset + 1)",
                goal: string(item["goal"]) ?? fallbackGoal,
                status: string(item["status"]) ?? "pending",
                dependsOn: (try? stringArray(item["depends_on"], name: "depends_on")) ?? [],
                runID: string(item["run_id"]),
                waitCondition: string(item["wait_condition"]),
                waitValue: string(item["wait_value"]),
                notBefore: string(item["not_before"]),
                attempts: int(item["attempts"]) ?? 0,
                updatedAt: now
            )
        }
    }

    private static func watcherReady(_ node: DurableTaskNode) -> Bool {
        if let notBefore = node.notBefore, let date = isoDate(from: notBefore), date > Date() {
            return false
        }
        let condition = normalizeForSearch(node.waitCondition ?? "").replacingOccurrences(of: " ", with: "_")
        let value = node.waitValue ?? ""
        switch condition {
        case "", "none":
            return true
        case "time", "not_before":
            guard let date = isoDate(from: value) else { return false }
            return date <= Date()
        case "file_exists":
            return FileManager.default.fileExists(atPath: value.expandingTildeInPath)
        case "run_complete":
            guard let summary = try? EventStore.readSummary(runID: value) else { return false }
            return summary.status == "complete"
        case "run_finished":
            guard let summary = try? EventStore.readSummary(runID: value) else { return false }
            return ["complete", "failed", "canceled"].contains(summary.status)
        default:
            return false
        }
    }
}
