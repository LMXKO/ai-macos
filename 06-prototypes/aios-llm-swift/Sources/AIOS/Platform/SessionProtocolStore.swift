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

struct AIOSSessionEvent: Codable {
    let schema: String
    let sequence: Int
    let runID: String
    let time: String
    let kind: String
    let title: String
    let severity: String
    let payload: [String: String]

    var dictionary: [String: String] {
        [
            "schema": schema,
            "sequence": "\(sequence)",
            "run_id": runID,
            "time": time,
            "kind": kind,
            "title": title,
            "severity": severity,
            "payload": jsonStringValue(payload)
        ]
    }
}

struct SessionProtocolStore {
    static let schema = "aios.session.event.v1"

    static var sessionsURL: URL {
        EventStore.rootURL.appendingPathComponent("sessions", isDirectory: true)
    }

    static func schemaDescription() -> [String: String] {
        [
            "schema": schema,
            "purpose": "Codex-style structured task event stream for CLI, MCP, desktop cockpit, replay, and future IDE/Web frontends.",
            "fields": "sequence,run_id,time,kind,title,severity,payload",
            "kinds": "user_goal,plan,step,tool_call,tool_result,verification,recovery,checkpoint,delivery,warning,complete,raw",
            "storage": sessionsURL.path
        ]
    }

    static func timeline(runID: String, limit: Int = 200) throws -> [AIOSSessionEvent] {
        let raw = EpisodeStore.parseEvents(try EventStore.readEventsText(runID: runID))
        let projected = raw.enumerated().map { offset, event in
            project(event: event, sequence: offset + 1, runID: runID)
        }
        return Array(projected.suffix(min(2_000, max(1, limit))))
    }

    static func export(runID: String) throws -> URL {
        let summary = try EventStore.readSummary(runID: runID)
        let events = try timeline(runID: runID, limit: 10_000)
        let payload: [String: Any] = [
            "schema": "aios.session.v1",
            "run_id": runID,
            "goal": summary.goal,
            "status": summary.status,
            "exported_at": isoDateString(Date()),
            "events": events.map(\.dictionary)
        ]
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let url = sessionsURL.appendingPathComponent("\(runID).json")
        try writeJSONObject(payload, to: url)
        return url
    }

    static func cockpitSnapshot(runID: String, limit: Int = 80) throws -> [String: String] {
        let summary = try EventStore.readSummary(runID: runID)
        let timelineEvents = try timeline(runID: runID, limit: limit)
        let runDir = EventStore.runsURL.appendingPathComponent(runID, isDirectory: true)
        let store = EventStore(
            runID: runID,
            goal: summary.goal,
            dir: runDir,
            eventsURL: URL(fileURLWithPath: summary.eventsPath),
            summaryURL: runDir.appendingPathComponent("summary.json")
        )
        let checkpoint: String = {
            guard let checkpoint = store.loadCheckpoint(),
                  let data = try? JSONEncoder().encode(checkpoint),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { return "" }
            return jsonStringValue(object)
        }()
        let rawEvents = EpisodeStore.parseEvents((try? EventStore.readEventsText(runID: runID)) ?? "")
        let artifacts = unique(rawEvents.flatMap { event in
            [event["path"], event["image_path"], event["screenshot"], event["events_path"]].compactMap { $0 }
        })
        let current = currentStep(from: timelineEvents)
        let memories = MemoryStore.recall(query: summary.goal, limit: 6)
        let episodes = EpisodeStore.recall(query: summary.goal, limit: 4)
        let graph = ContextGraphStore.query(summary.goal, limit: 8)
        let recipes = (try? RecipeStore.suggest(goal: summary.goal, limit: 5)) ?? []
        let skills = AppSkillStore.suggest(query: summary.goal, limit: 5)
        let replayPlan = (try? TrajectoryStore.replayPlan(runID: runID, fromIndex: 1, toIndex: nil)) ?? []
        return [
            "schema": "aios.cockpit.snapshot.v1",
            "run_id": runID,
            "goal": summary.goal,
            "status": summary.status,
            "created_at": summary.createdAt,
            "updated_at": summary.updatedAt,
            "current_step": current,
            "checkpoint": checkpoint,
            "timeline": jsonStringValue(timelineEvents.map(\.dictionary)),
            "trajectory": jsonStringValue((try? TrajectoryStore.summarize(runID: runID, limit: limit)) ?? []),
            "replay_plan": jsonStringValue(replayPlan),
            "memories": jsonStringValue(memories.map(\.dictionary)),
            "episodes": jsonStringValue(episodes.map(\.dictionary)),
            "graph_nodes": jsonStringValue(graph.nodes.map { ["id": $0.id, "kind": $0.kind, "label": $0.label] }),
            "graph_edges": jsonStringValue(graph.edges.map { ["from": $0.from, "to": $0.to, "relation": $0.relation, "weight": String(format: "%.2f", $0.weight)] }),
            "recipes": jsonStringValue(recipes.map(\.summary)),
            "app_skills": jsonStringValue(skills.map(\.dictionary)),
            "artifacts": jsonStringValue(artifacts)
        ]
    }

    static func platformStatus(toolDefinitions: [[String: Any]]) -> [String: String] {
        let names = toolDefinitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        let families = Dictionary(grouping: names) { name -> String in
            if name.hasPrefix("browser_cdp_") { return "browser" }
            if name.hasPrefix("visual_") || name.hasPrefix("ocr_") { return "perception" }
            if name.hasPrefix("trajectory_") { return "trajectory" }
            if name.hasPrefix("recipe_") || name.hasPrefix("learn_") { return "recipes" }
            if name.hasPrefix("memory_") || name.hasPrefix("episode_") || name.hasPrefix("context_graph_") { return "memory" }
            if name.hasPrefix("app_skill") { return "skills" }
            if name.hasPrefix("runtime_") { return "runtime" }
            if name.hasPrefix("session_") || name == "cockpit_snapshot" || name == "platform_status" { return "platform" }
            return "macos"
        }
        return [
            "schema": "aios.platform.status.v1",
            "state_root": EventStore.rootURL.path,
            "tool_count": "\(names.count)",
            "tool_families": jsonStringValue(families.mapValues(\.count)),
            "session_schema": schema,
            "module_layout": "AIOS.swift,Core,Runtime,Memory,Skills,Recipes,Learning,Eval,Host,Agent,Tools,Trajectory,Platform"
        ]
    }

    private static func project(event: [String: String], sequence: Int, runID: String) -> AIOSSessionEvent {
        let rawName = event["event"] ?? "Raw"
        let kind: String
        let title: String
        let severity: String
        switch rawName {
        case "UserGoal":
            kind = "user_goal"
            title = event["goal"] ?? "User goal"
            severity = "info"
        case "TaskPlan":
            kind = "plan"
            title = event["objective"] ?? "Task plan"
            severity = "info"
        case "StepQueue", "NextStep":
            kind = "step"
            title = event["step_title"] ?? event["step_id"] ?? rawName
            severity = "info"
        case "ToolSelection", "AppAction":
            kind = "tool_call"
            title = event["tool"] ?? rawName
            severity = "info"
        case "Observation":
            kind = "tool_result"
            title = event["tool"] ?? "Observation"
            severity = event["success"] == "false" ? "error" : "info"
        case "Verification":
            kind = "verification"
            title = event["step_id"] ?? "Verification"
            severity = event["verified"] == "false" ? "warning" : "info"
        case "Recovery", "ActionNotPerformed":
            kind = "recovery"
            title = event["reason"] ?? rawName
            severity = "warning"
        case "CheckpointSaved", "RunPaused", "RunScheduled", "RunResumed":
            kind = "checkpoint"
            title = rawName
            severity = "info"
        case "Delivery", "TaskComplete":
            kind = "delivery"
            title = rawName
            severity = "info"
        case "RunFailed":
            kind = "warning"
            title = event["error"] ?? rawName
            severity = "error"
        default:
            kind = "raw"
            title = rawName
            severity = "info"
        }
        return AIOSSessionEvent(
            schema: schema,
            sequence: sequence,
            runID: runID,
            time: event["time"] ?? "",
            kind: kind,
            title: truncateMiddle(title, maxCharacters: 500),
            severity: severity,
            payload: event
        )
    }

    private static func currentStep(from events: [AIOSSessionEvent]) -> String {
        if let step = events.reversed().first(where: { $0.kind == "step" }) {
            return jsonStringValue(step.dictionary)
        }
        if let tool = events.reversed().first(where: { $0.kind == "tool_call" || $0.kind == "tool_result" }) {
            return jsonStringValue(tool.dictionary)
        }
        return ""
    }
}
