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

struct AppSkill: Codable {
    let id: String
    let appName: String
    let bundleID: String
    let version: String
    let capabilities: [String]
    let tools: [String]
    let recipes: [String]
    let selectors: [String: String]
    let permissions: [String]
    let notes: String

    var dictionary: [String: String] {
        [
            "id": id,
            "app_name": appName,
            "bundle_id": bundleID,
            "version": version,
            "capabilities": capabilities.joined(separator: ","),
            "tools": tools.joined(separator: ","),
            "recipes": recipes.joined(separator: ","),
            "selectors": jsonStringValue(selectors),
            "permissions": permissions.joined(separator: ","),
            "notes": notes
        ]
    }
}

struct AppSkillStore {
    static let builtIns: [AppSkill] = [
        AppSkill(id: "finder", appName: "Finder", bundleID: "com.apple.finder", version: "1", capabilities: ["files", "folders", "reveal", "search"], tools: ["finder_list_directory", "finder_file_info", "finder_find_files", "finder_create_folder", "finder_reveal_file"], recipes: [], selectors: [:], permissions: ["automation"], notes: "Native Finder file operations plus reveal."),
        AppSkill(id: "browser-chrome", appName: "Google Chrome", bundleID: "com.google.Chrome", version: "1", capabilities: ["web", "dom", "cdp", "javascript", "tabs", "shadow-dom", "iframes", "downloads", "file-upload"], tools: ["chrome_open_url", "chrome_eval_js", "browser_cdp_launch", "browser_cdp_tabs", "browser_cdp_eval", "browser_cdp_click", "browser_cdp_type", "browser_cdp_read", "browser_cdp_observe", "browser_cdp_act", "browser_cdp_extract", "browser_cdp_wait", "browser_cdp_file_upload", "browser_cdp_download_behavior", "browser_cdp_selector_cache"], recipes: [], selectors: ["default_input": "input,textarea,[contenteditable=true]"], permissions: ["automation", "remote-debugging-port when using CDP"], notes: "Use CDP tools for DOM-level background web app control when available; deep observe/act supports open shadow DOM, same-origin iframes, selector cache, downloads, and file inputs."),
        AppSkill(id: "browser-safari", appName: "Safari", bundleID: "com.apple.Safari", version: "1", capabilities: ["web", "javascript", "tabs", "page-text"], tools: ["safari_open_url", "safari_new_tab", "safari_search", "safari_get_current_url", "safari_get_page_text", "safari_eval_js", "background_driver_dispatch", "visual_grounder_run"], recipes: [], selectors: [:], permissions: ["automation"], notes: "Safari AppleScript/JavaScript adapter; use Chrome CDP for deeper no-focus DOM control when available."),
        AppSkill(id: "mail-calendar", appName: "Mail and Calendar", bundleID: "com.apple.mail,com.apple.iCal", version: "1", capabilities: ["mail", "drafts", "calendar", "search"], tools: ["mail_compose_draft", "mail_search_messages", "calendar_create_event", "calendar_find_events"], recipes: ["create-calendar-event"], selectors: [:], permissions: ["automation"], notes: "Native productivity adapters with typed verification."),
        AppSkill(id: "textedit", appName: "TextEdit", bundleID: "com.apple.TextEdit", version: "1", capabilities: ["text", "documents", "save"], tools: ["textedit_new_document", "textedit_set_text", "textedit_read_text", "textedit_save_as"], recipes: [], selectors: [:], permissions: ["automation"], notes: "AppleScript-backed deterministic text document operations."),
        AppSkill(id: "wechat", appName: "WeChat", bundleID: "com.tencent.xinWeChat", version: "1", capabilities: ["chat", "send", "verify"], tools: ["wechat_open", "wechat_search_chat", "wechat_open_chat", "wechat_stage_file", "wechat_send_text", "wechat_send_staged", "wechat_verify_chat", "wechat_verify_recent_message"], recipes: ["send-file-to-contact", "write-plan-and-sync"], selectors: [:], permissions: ["accessibility", "screen-recording"], notes: "Chat workflow adapter with recipient/message verification."),
        AppSkill(id: "terminal", appName: "Terminal", bundleID: "com.apple.Terminal", version: "1", capabilities: ["shell", "commands", "developer-workflows"], tools: ["terminal_run_command"], recipes: [], selectors: [:], permissions: ["automation"], notes: "Terminal command submission adapter."),
        AppSkill(id: "native-canvas", appName: "Figma/Blender/canvas native surfaces", bundleID: "", version: "1", capabilities: ["canvas", "icons", "non-ax", "vision-grounding", "native-driver"], tools: ["background_native_kernel", "background_driver_dispatch", "visual_grounder_run", "visual_grounder_model_registry", "visual_grounder_feedback"], recipes: [], selectors: [:], permissions: ["adapter-specific"], notes: "Non-AX native surfaces use visual grounding plus app-specific adapter or CUA-compatible external driver.")
    ]

    static func list() -> [AppSkill] {
        let disk = diskSkills()
        let diskIDs = Set(disk.map(\.id))
        return disk + builtIns.filter { !diskIDs.contains($0.id) }
    }

    static func suggest(query: String, limit: Int = 8) -> [AppSkill] {
        let normalizedQuery = normalizeForSearch(query)
        guard !normalizedQuery.isEmpty else { return Array(list().prefix(limit)) }
        let scored = list().compactMap { skill -> (AppSkill, Int)? in
            let haystack = normalizeForSearch([
                skill.id,
                skill.appName,
                skill.bundleID,
                skill.capabilities.joined(separator: " "),
                skill.tools.joined(separator: " "),
                skill.recipes.joined(separator: " "),
                skill.notes
            ].joined(separator: " "))
            var score = haystack.contains(normalizedQuery) ? 8 : 0
            for token in normalizedQuery.components(separatedBy: " ") where token.count >= 2 && haystack.contains(token) {
                score += 2
            }
            guard score > 0 else { return nil }
            return (skill, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(min(50, max(1, limit))).map(\.0)
    }

    @discardableResult
    static func install(_ skill: AppSkill) throws -> AppSkill {
        try FileManager.default.createDirectory(at: EventStore.appSkillsURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(skill).write(to: EventStore.appSkillsURL.appendingPathComponent("\(skill.id).json"), options: [.atomic])
        return skill
    }

    static func read(_ id: String) -> AppSkill? {
        list().first { $0.id == id }
    }

    static func validate(_ skill: AppSkill, knownTools: Set<String>) -> [String] {
        var issues: [String] = []
        if skill.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("id is empty") }
        if skill.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("app_name is empty") }
        let missingTools = skill.tools.filter { !knownTools.contains($0) }
        if !missingTools.isEmpty { issues.append("unknown tools: \(missingTools.joined(separator: ","))") }
        return issues
    }

    private static func diskSkills() -> [AppSkill] {
        guard FileManager.default.fileExists(atPath: EventStore.appSkillsURL.path),
              let urls = try? FileManager.default.contentsOfDirectory(at: EventStore.appSkillsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return AppSkillPackageStore.skills() }
        let flat: [AppSkill] = urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(AppSkill.self, from: data)
        }
        let packageSkills = AppSkillPackageStore.skills()
        let flatIDs = Set(flat.map(\.id))
        return flat + packageSkills.filter { !flatIDs.contains($0.id) }
    }
}

struct TrajectoryStore {
    static func summarize(runID: String, limit: Int = 200) throws -> [[String: String]] {
        let text = try EventStore.readEventsText(runID: runID)
        let events = EpisodeStore.parseEvents(text)
        return events.enumerated().prefix(min(1_000, max(1, limit))).map { index, event in
            [
                "index": "\(index + 1)",
                "time": event["time"] ?? "",
                "event": event["event"] ?? "",
                "step_id": event["step_id"] ?? "",
                "tool": event["tool"] ?? "",
                "success": event["success"] ?? "",
                "evidence": truncateMiddle(event["evidence"] ?? event["reason"] ?? event["summary"] ?? "", maxCharacters: 500),
                "screenshot": event["screen_path"] ?? event["path"] ?? event["image_path"] ?? "",
                "evidence_manifest": event["event"] == "TrajectoryEvidence" ? (event["path"] ?? "") : ""
            ]
        }
    }

    static func export(runID: String) throws -> URL {
        let summary = try EventStore.readSummary(runID: runID)
        let events = try summarize(runID: runID, limit: 1_000)
        let payload: [String: Any] = [
            "run_id": runID,
            "goal": summary.goal,
            "status": summary.status,
            "exported_at": isoDateString(Date()),
            "events": events
        ]
        try FileManager.default.createDirectory(at: EventStore.trajectoriesURL, withIntermediateDirectories: true)
        let url = EventStore.trajectoriesURL.appendingPathComponent("\(runID).json")
        try writeJSONObject(payload, to: url)
        return url
    }

    static func exportSession(runID: String) throws -> URL {
        let summary = try EventStore.readSummary(runID: runID)
        let rawEventsText = try EventStore.readEventsText(runID: runID)
        let rawEvents = EpisodeStore.parseEvents(rawEventsText)
        let runDir = EventStore.runsURL.appendingPathComponent(summary.id, isDirectory: true)
        let checkpointStore = EventStore(
            runID: summary.id,
            goal: summary.goal,
            dir: runDir,
            eventsURL: URL(fileURLWithPath: summary.eventsPath),
            summaryURL: runDir.appendingPathComponent("summary.json")
        )
        var checkpointPayload: Any = [:]
        if let checkpoint = checkpointStore.loadCheckpoint(),
           let data = try? JSONEncoder().encode(checkpoint),
           let object = try? JSONSerialization.jsonObject(with: data) {
            checkpointPayload = object
        }
        let screenshots = unique(rawEvents.flatMap { event in
            [event["path"], event["image_path"], event["screenshot"]].compactMap { $0 }
        })
        let payload: [String: Any] = [
            "schema": "aios.replay.session.v1",
            "run_id": runID,
            "goal": summary.goal,
            "status": summary.status,
            "exported_at": isoDateString(Date()),
            "checkpoint": checkpointPayload,
            "screenshots": screenshots,
            "timeline": try summarize(runID: runID, limit: 2_000),
            "events": rawEvents
        ]
        try FileManager.default.createDirectory(at: EventStore.trajectoriesURL, withIntermediateDirectories: true)
        let url = EventStore.trajectoriesURL.appendingPathComponent("\(runID)-session.json")
        try writeJSONObject(payload, to: url)
        return url
    }

    static func replayPlan(runID: String, fromIndex: Int = 1, toIndex: Int? = nil) throws -> [[String: String]] {
        let events = try summarize(runID: runID, limit: 2_000)
        let end = toIndex ?? events.count
        return events.compactMap { event in
            guard let index = Int(event["index"] ?? ""),
                  index >= max(1, fromIndex),
                  index <= max(fromIndex, end),
                  ["AppAction", "RecipeStep", "RecipeObservation", "Observation", "Verification"].contains(event["event"] ?? "")
            else { return nil }
            return [
                "index": "\(index)",
                "event": event["event"] ?? "",
                "step_id": event["step_id"] ?? "",
                "tool": event["tool"] ?? "",
                "replay_hint": replayHint(for: event),
                "evidence": event["evidence"] ?? ""
            ]
        }
    }

    private static func replayHint(for event: [String: String]) -> String {
        if let tool = event["tool"], !tool.isEmpty {
            if tool.hasPrefix("browser_cdp_") { return "Replay through CDP against the same URL/tab selector context." }
            if tool.hasPrefix("aios_background_") { return "Replay as non-invasive AX action after re-locating the element." }
            if tool.hasPrefix("visual_") { return "Re-ground the screenshot/window first; do not blindly reuse coordinates." }
            return "Replay by calling \(tool) with the recorded or parameterized arguments."
        }
        return "Use surrounding AppAction/Observation events to reconstruct this step."
    }
}

struct ComputerUseStrategy {
    static func suggest(goal: String, app: String = "") -> [String: String] {
        let text = normalizeForSearch([goal, app].joined(separator: " "))
        let recipe = text.contains("pdf") || text.contains("发送") || text.contains("send") || text.contains("日历") || text.contains("calendar")
        let browser = text.contains("web") || text.contains("网页") || text.contains("browser") || text.contains("chrome") || text.contains("safari") || text.contains("figma")
        let visual = text.contains("canvas") || text.contains("图") || text.contains("image") || text.contains("figma") || text.contains("blender")
        let long = text.contains("持续") || text.contains("等待") || text.contains("watch") || text.contains("long") || text.contains("长时间")
        let primary: String
        if browser {
            primary = "browser_cdp_dom"
        } else if recipe {
            primary = "recipe_runner"
        } else {
            primary = "app_adapter_or_ax"
        }
        let perception = visual ? "visual_grounding_then_action" : "ax_or_dom_first_visual_fallback"
        let runtime = long ? "state_machine_with_runtime_pause_and_resume" : "checkpointed_step_loop"
        return [
            "primary_controller": primary,
            "planner": "llm_task_planner",
            "executor": "swift_tool_executor",
            "perception": perception,
            "recipe_policy": "suggest_execute_then_promote_successful_trajectory",
            "runtime": runtime,
            "memory": "recall_memory_episode_context_graph",
            "model_stack": "planner/executor/vision_grounder/recipe_runner/verifier/memory_curator with computer_use_model_stack",
            "resident_policy": long ? "resident_agent_plan + daemon tick + task graph + cockpit interrupt" : "single checkpointed run",
            "background_policy": "background_native_kernel -> background_driver_dispatch -> visual grounding -> explicit foreground fallback"
        ]
    }
}

func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty {
        let key = value.lowercased()
        if !seen.contains(key) {
            seen.insert(key)
            result.append(value)
        }
    }
    return result
}

func normalizeForSearch(_ text: String) -> String {
    text
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .lowercased()
        .replacingOccurrences(of: "[\\p{Punct}\\p{Symbol}]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizeID(_ text: String) -> String {
    let cleaned = normalizeForSearch(text)
        .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
    return cleaned.isEmpty ? "unknown" : String(cleaned.prefix(80))
}
