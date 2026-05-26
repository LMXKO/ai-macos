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

struct TrajectoryReplayAction {
    let index: Int
    let time: String
    let tool: String
    let arguments: [String: Any]
    let evidence: String

    var dictionary: [String: String] {
        [
            "index": "\(index)",
            "time": time,
            "tool": tool,
            "arguments": jsonStringValue(arguments),
            "evidence": evidence,
            "channel": channel,
            "foreground_sensitive": isForegroundSensitive ? "true" : "false"
        ]
    }

    var channel: String {
        if tool.hasPrefix("browser_cdp_") || tool.hasPrefix("chrome_") { return "browser_dom" }
        if tool.hasPrefix("aios_background_") || tool == "background_action" || tool == "background_appscript" { return "background_semantic" }
        if tool.hasPrefix("aios_") || tool.hasPrefix("ax_") || tool.hasPrefix("snapshot_") { return "accessibility_semantic" }
        if tool.hasPrefix("visual_") || tool.hasPrefix("ocr_") || tool.hasPrefix("screen_capture") { return "visual_grounding" }
        if tool.hasPrefix("ui_") || tool == "space_switch" || tool == "dock_open" || tool == "menubar_click" { return "foreground_input" }
        return "app_adapter"
    }

    var isForegroundSensitive: Bool {
        tool.hasPrefix("ui_") ||
            tool == "space_switch" ||
            tool == "visual_click" ||
            tool == "dock_open" ||
            tool == "menubar_click"
    }
}

struct TrajectoryReplayEngine {
    static func actions(runID: String, fromIndex: Int = 1, toIndex: Int? = nil) throws -> [TrajectoryReplayAction] {
        let text = try EventStore.readEventsText(runID: runID)
        let events = EpisodeStore.parseEvents(text)
        let end = toIndex ?? events.count
        return events.enumerated().compactMap { offset, event in
            let index = offset + 1
            guard index >= max(1, fromIndex), index <= max(fromIndex, end) else { return nil }
            guard event["event"] == "AppAction", let tool = event["tool"], !tool.isEmpty else { return nil }
            let arguments = parseArguments(event["arguments"] ?? "{}")
            return TrajectoryReplayAction(
                index: index,
                time: event["time"] ?? "",
                tool: tool,
                arguments: arguments,
                evidence: event["evidence"] ?? event["summary"] ?? ""
            )
        }
    }

    @MainActor
    static func replay(
        runID: String,
        fromIndex: Int = 1,
        toIndex: Int? = nil,
        dryRun: Bool = true,
        allowForeground: Bool = false,
        stopOnFailure: Bool = true,
        recordRun: Bool = false
    ) throws -> ToolResult {
        let actions = try actions(runID: runID, fromIndex: fromIndex, toIndex: toIndex)
        let replayStore: EventStore? = try recordRun && !dryRun ? EventStore.start(goal: "Replay trajectory \(runID)") : nil
        var rows: [[String: String]] = []
        let registry = ToolRegistry()
        let knownTools = Set(registry.definitions.compactMap { definition in
            (definition["function"] as? [String: Any])?["name"] as? String
        })
        let policy = PolicyEngine()

        for action in actions {
            var row = action.dictionary
            if action.isForegroundSensitive && !allowForeground {
                row["status"] = "skipped"
                row["reason"] = "foreground action requires allow_foreground=true"
                rows.append(row)
                if stopOnFailure { break }
                continue
            }
            if dryRun {
                row["status"] = "planned"
                row["reason"] = replayAdvice(for: action)
                rows.append(row)
                continue
            }

            let call = ToolCall(id: "replay-\(action.index)", name: action.tool, arguments: action.arguments, raw: [:])
            let decision = policy.evaluate(call, knownTools: knownTools)
            guard decision.allowed else {
                row["status"] = "blocked"
                row["reason"] = decision.reason
                rows.append(row)
                if stopOnFailure { break }
                continue
            }

            try replayStore?.append("AppAction", [
                "source_run_id": runID,
                "source_index": "\(action.index)",
                "tool": action.tool,
                "arguments": jsonStringValue(action.arguments),
                "channel": action.channel
            ])
            let result = registry.execute(call)
            try replayStore?.append("Observation", [
                "source_run_id": runID,
                "source_index": "\(action.index)",
                "tool": action.tool,
                "success": result.success ? "true" : "false",
                "evidence": result.evidence,
                "error": result.error ?? ""
            ])
            row["status"] = result.success ? "replayed" : "failed"
            row["result_evidence"] = result.evidence
            row["result_error"] = result.error ?? ""
            rows.append(row)
            if !result.success && stopOnFailure { break }
        }

        if let replayStore {
            try? replayStore.updateStatus(rows.allSatisfy { $0["status"] == "replayed" } ? "complete" : "incomplete")
        }
        let executed = rows.filter { $0["status"] == "replayed" }.count
        let skipped = rows.filter { ["skipped", "blocked", "failed"].contains($0["status"] ?? "") }.count
        return ToolResult(
            success: dryRun ? true : skipped == 0,
            evidence: dryRun ? "Prepared executable replay for \(actions.count) action(s)." : "Replayed \(executed)/\(actions.count) action(s).",
            data: [
                "run_id": runID,
                "replay_run_id": replayStore?.runID ?? "",
                "dry_run": dryRun ? "true" : "false",
                "actions": jsonStringValue(rows)
            ],
            error: dryRun || skipped == 0 ? nil : "trajectory_replay_incomplete",
            suggestion: skipped == 0 ? nil : "Inspect skipped/blocked/failed rows; rerun with allow_foreground=true only when foreground input is acceptable."
        )
    }

    static func clipRecipe(
        runID: String,
        fromIndex: Int = 1,
        toIndex: Int? = nil,
        recipeID: String? = nil,
        title: String? = nil
    ) throws -> Recipe {
        let sourceSummary = try EventStore.readSummary(runID: runID)
        let actions = try actions(runID: runID, fromIndex: fromIndex, toIndex: toIndex)
        guard !actions.isEmpty else {
            throw RuntimeError("No replayable AppAction events in the requested trajectory slice.")
        }
        let steps = actions.enumerated().map { offset, action in
            RecipeStep(
                id: "S\(offset + 1)",
                title: "Replay \(action.tool)",
                tool: action.tool,
                arguments: action.arguments.compactMapValues { value in
                    if let text = value as? String { return text }
                    if let number = value as? NSNumber { return number.stringValue }
                    if JSONSerialization.isValidJSONObject(value) { return jsonStringValue(value) }
                    return "\(value)"
                },
                fallbackTools: replayFallbacks(for: action),
                verifyExpression: "success"
            )
        }
        let id = normalizeID(recipeID ?? "\(sourceSummary.goal)-clip-\(fromIndex)-\(toIndex ?? actions.last?.index ?? fromIndex)")
        return try RecipeStore.save(Recipe(
            id: id,
            title: title ?? "Replay clip: \(sourceSummary.goal)",
            goalTemplate: sourceSummary.goal,
            parameters: [],
            requiredParams: [],
            preconditions: [],
            postconditions: [],
            appBindings: ["source_run_id": runID],
            notes: "Generated from trajectory slice \(fromIndex)...\(toIndex.map(String.init) ?? "end"). Re-ground visual and foreground-sensitive steps before production reuse.",
            steps: steps,
            successCount: 0,
            failureCount: 0
        ))
    }

    private static func parseArguments(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func replayAdvice(for action: TrajectoryReplayAction) -> String {
        switch action.channel {
        case "browser_dom":
            return "Replay through CDP/DOM against the matching tab; selectors remain semantic."
        case "background_semantic":
            return "Replay through non-invasive background channel."
        case "accessibility_semantic":
            return "Re-locate through AX/snapshot ids before acting."
        case "visual_grounding":
            return action.tool == "visual_click" ? "Re-ground query before foreground click." : "Replay as visual observation/grounding."
        case "foreground_input":
            return "Foreground input is intentionally gated behind allow_foreground=true."
        default:
            return "Replay through the recorded app adapter tool."
        }
    }

    private static func replayFallbacks(for action: TrajectoryReplayAction) -> [RecipeFallback] {
        if action.tool == "visual_click", let query = action.arguments["query"] as? String, !query.isEmpty {
            return [
                RecipeFallback(tool: "visual_ground", arguments: ["query": query]),
                RecipeFallback(tool: "aios_click", arguments: ["query": query])
            ]
        }
        if action.tool.hasPrefix("aios_background_"), let query = action.arguments["query"] as? String, !query.isEmpty {
            return [
                RecipeFallback(tool: "aios_find", arguments: ["query": query]),
                RecipeFallback(tool: "visual_ground", arguments: ["query": query])
            ]
        }
        return []
    }
}
