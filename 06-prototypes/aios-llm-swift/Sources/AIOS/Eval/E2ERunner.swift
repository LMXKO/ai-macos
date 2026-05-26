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

struct EvalCase {
    let id: String
    let title: String
    let run: () throws -> ToolResult
}

struct EvalResult {
    let id: String
    let passed: Bool
    let evidence: String
    let durationMs: Int
}

struct RealE2ECase: Codable {
    let id: String
    let title: String
    let recipeID: String?
    let params: [String: String]
    let goal: String?
    let enabled: Bool
    let destructive: Bool
    let sendsExternalMessage: Bool
    let notes: String?
}

@MainActor
struct E2ERunner {
    static var cases: [EvalCase] {
        [
            EvalCase(id: "apps", title: "Installed app discovery") {
                ToolRegistry().execute(ToolCall(id: "eval", name: "aios_list_apps", arguments: ["query": "WeChat", "include_system": false], raw: [:]))
            },
            EvalCase(id: "wait-file", title: "Wait for existing file") {
                ToolRegistry().execute(ToolCall(id: "eval", name: "observe_wait", arguments: ["condition": "file_exists", "value": "Package.swift", "timeout": 1, "interval": 0.2], raw: [:]))
            },
            EvalCase(id: "snapshot", title: "Persistent UI snapshot") {
                let result = ToolRegistry().execute(ToolCall(id: "eval", name: "snapshot_create", arguments: ["screenshot": false, "max_depth": 2, "max_nodes": 50], raw: [:]))
                if result.success {
                    return result
                }
                if result.error == "frontmostApplication is nil" || result.evidence.localizedCaseInsensitiveContains("No frontmost app") {
                    return ToolResult(success: true, evidence: "Snapshot tool is available; skipped capture because no frontmost GUI app is visible in this environment.", data: result.data)
                }
                return result
            },
            EvalCase(id: "recipe", title: "Default recipes render") {
                try RecipeStore.seedDefaults(overwrite: false)
                let goal = try RecipeStore.renderGoal(recipeID: "export-document-pdf", params: ["path": "~/Downloads/a.docx", "outdir": "~/Downloads"])
                return ToolResult(success: goal.contains("PDF"), evidence: "Rendered recipe goal.", data: ["goal": goal])
            },
            EvalCase(id: "recipe-suggest", title: "Recipe suggestions match user goals") {
                let suggestions = try RecipeStore.suggest(goal: "把文档导出成 PDF")
                let top = suggestions.first?.recipe.id ?? ""
                return ToolResult(success: top == "export-document-pdf", evidence: "Top recipe suggestion: \(top).", data: [
                    "top": top,
                    "suggestions": jsonStringValue(suggestions.map(\.summary))
                ])
            },
            EvalCase(id: "automation-tools-registered", title: "Locator automation tools are registered") {
                let names = Set(ToolRegistry().definitions.compactMap { definition in
                    (definition["function"] as? [String: Any])?["name"] as? String
                })
                let required = [
                    "aios_automation_context",
                    "aios_find",
                    "aios_inspect",
                    "aios_read",
                    "aios_click",
                    "aios_type",
                    "aios_background_click",
                    "aios_background_type",
                    "aios_wait",
                    "visual_find",
                    "visual_read",
                    "visual_click",
                    "visual_ground",
                    "visual_analyze",
                    "visual_perception_strategy",
                    "visual_ui_map_cache",
                    "visual_ui_map_recent",
                    "background_control_plan",
                    "background_capabilities",
                    "background_appscript",
                    "background_action",
                    "background_dispatch_plan",
                    "browser_cdp_launch",
                    "browser_cdp_status",
                    "browser_cdp_tabs",
                    "browser_cdp_eval",
                    "browser_cdp_click",
                    "browser_cdp_type",
                    "browser_cdp_read",
                    "browser_cdp_observe",
                    "browser_cdp_act",
                    "browser_cdp_extract",
                    "browser_cdp_wait",
                    "browser_cdp_file_upload",
                    "browser_cdp_download_behavior",
                    "browser_cdp_selector_cache",
                    "browser_runtime_session",
                    "browser_runtime_plan",
                    "browser_runtime_snapshot",
                    "recipe_suggest",
                    "recipe_promote_run",
                    "recipe_compile",
                    "recipe_refine",
                    "recipe_generalize",
                    "recipe_execute_adaptive",
                    "recipe_repair_hint",
                    "recipe_program_compile",
                    "recipe_schema_infer",
                    "recipe_distill_success",
                    "memory_remember",
                    "memory_recall",
                    "memory_recent",
                    "episode_recall",
                    "context_graph_query",
                    "context_graph_ingest",
                    "memory_profile",
                    "memory_index_rebuild",
                    "memory_semantic_recall",
                    "memory_context_pack",
                    "memory_episode_consolidate",
                    "memory_shadow_digest",
                    "session_timeline",
                    "session_export",
                    "cockpit_snapshot",
                    "cockpit_live_state",
                    "cockpit_command",
                    "platform_status",
                    "agent_role_plan",
                    "agent_handoff_packet",
                    "app_skill_list",
                    "app_skill_suggest",
                    "app_skill_install",
                    "app_skill_package_scaffold",
                    "app_skill_package_list",
                    "app_skill_package_validate",
                    "app_skill_route",
                    "app_skill_export_manifest",
                    "trajectory_get",
                    "trajectory_export",
                    "trajectory_session_export",
                    "trajectory_replay_plan",
                    "trajectory_replay",
                    "trajectory_clip_recipe",
                    "trajectory_product_export",
                    "trajectory_resume_points",
                    "trajectory_branch_create",
                    "runtime_status",
                    "runtime_schedule",
                    "long_run_daemon_status",
                    "long_run_daemon_tick",
                    "long_run_schedule",
                    "task_graph_create",
                    "task_graph_list",
                    "task_graph_status",
                    "task_graph_tick",
                    "background_driver_matrix",
                    "background_driver_dispatch",
                    "visual_grounder_profiles",
                    "visual_grounder_session",
                    "visual_grounder_run",
                    "visual_ui_map_query",
                    "recipe_learn_once",
                    "recipe_learn_recipe",
                    "recipe_program_select",
                    "long_task_state",
                    "long_task_watch",
                    "long_task_interrupt",
                    "memory_entity_graph",
                    "memory_preference_digest",
                    "browser_agent_plan",
                    "browser_agent_observe",
                    "browser_agent_act",
                    "browser_agent_extract",
                    "browser_agent_wait",
                    "browser_agent_observation",
                    "browser_agent_snapshot",
                    "memory_shadow_capture",
                    "app_skill_sdk",
                    "app_skill_marketplace",
                    "cockpit_dashboard",
                    "cockpit_dashboard_export",
                    "trajectory_bundle_manifest",
                    "trajectory_bundle_export",
                    "agent_harness_plan",
                    "agent_harness_tick",
                    "computer_use_strategy"
                ]
                let missing = required.filter { !names.contains($0) }
                return ToolResult(success: missing.isEmpty, evidence: missing.isEmpty ? "Locator and recipe-first tools are registered." : "Missing tools: \(missing.joined(separator: ","))", data: [
                    "required": required.joined(separator: ","),
                    "missing": missing.joined(separator: ",")
                ])
            },
            EvalCase(id: "memory-store", title: "Durable memory recalls context and rejects secrets") {
                let key = "aios_eval_memory_probe"
                let entry = try MemoryStore.remember(
                    kind: "workflow_hint",
                    scope: "eval",
                    app: "TextEdit",
                    key: key,
                    value: "Use TextEdit AXValue before paste fallback for eval workflow.",
                    confidence: 0.9,
                    sourceRunID: "eval",
                    sourceTool: "eval"
                )
                let recalled = MemoryStore.recall(query: "TextEdit AXValue eval workflow", limit: 3)
                let rejected = (try? MemoryStore.remember(
                    kind: "blocked_value",
                    scope: "eval",
                    app: "",
                    key: "aios_eval_sensitive_probe",
                    value: "credential marker should be rejected",
                    confidence: 1.0,
                    sourceRunID: "eval",
                    sourceTool: "eval"
                )) == nil
                let found = recalled.contains { $0.id == entry.id || $0.key == key }
                return ToolResult(success: found && rejected, evidence: found && rejected ? "Memory recall works and secret-like values are rejected." : "Memory eval failed.", data: [
                    "found": found ? "true" : "false",
                    "rejected_secret": rejected ? "true" : "false",
                    "matches": jsonStringValue(recalled.map(\.dictionary))
                ])
            },
            EvalCase(id: "checkpoint-roundtrip", title: "Agent checkpoint persists and reloads long-task state") {
                let runID = "eval-checkpoint-\(UUID().uuidString)"
                let store = try EventStore.start(goal: "eval checkpoint", runID: runID)
                let plan = TaskPlan.fallback(goal: "eval checkpoint")
                let state = CompletionContractState(goal: "eval checkpoint", plan: plan)
                try store.saveCheckpoint(AgentCheckpoint(
                    goal: "eval checkpoint",
                    plan: plan,
                    round: 2,
                    executedActionCount: 3,
                    submittedExternalSends: ["send|target|value"],
                    verificationState: state,
                    finished: false
                ))
                let loaded = store.loadCheckpoint()
                store.clearCheckpoint()
                try? store.updateStatus("complete")
                let ok = loaded?.goal == "eval checkpoint" &&
                    loaded?.round == 2 &&
                    loaded?.executedActionCount == 3 &&
                    loaded?.submittedExternalSends.first == "send|target|value"
                return ToolResult(success: ok, evidence: ok ? "Checkpoint roundtrip succeeded." : "Checkpoint roundtrip failed.", data: [
                    "run_id": runID,
                    "round": "\(loaded?.round ?? -1)",
                    "executed_actions": "\(loaded?.executedActionCount ?? -1)"
                ])
            },
            EvalCase(id: "runtime-platform", title: "Runtime platform exposes strategy, skills, trajectory, and recipe promotion") {
                let store = try EventStore.start(goal: "Open TextEdit and write hello", runID: "eval-runtime-\(UUID().uuidString)")
                try store.append("AppAction", ["tool": "textedit_new_document", "arguments": "{}"])
                try store.append("Observation", ["tool": "textedit_new_document", "success": "true", "evidence": "Opened TextEdit."])
                try store.append("AppAction", ["tool": "textedit_set_text", "arguments": #"{"text":"hello"}"#])
                try store.append("Observation", ["tool": "textedit_set_text", "success": "true", "evidence": "Set TextEdit text."])
                let recipe = try RecipeStore.promoteRun(runID: store.runID)
                let trajectory = try TrajectoryStore.summarize(runID: store.runID, limit: 10)
                let episode = EpisodeStore.record(runID: store.runID, goal: store.goal, plan: TaskPlan.fallback(goal: store.goal), outcome: "eval", eventsText: try EventStore.readEventsText(runID: store.runID))
                let graph = ContextGraphStore.query("TextEdit", limit: 10)
                let skills = AppSkillStore.suggest(query: "Chrome DOM web", limit: 3)
                let strategy = ComputerUseStrategy.suggest(goal: "use Chrome web app")
                let ok = recipe.steps.count == 2 &&
                    !trajectory.isEmpty &&
                    episode.runID == store.runID &&
                    !graph.nodes.isEmpty &&
                    skills.contains(where: { $0.id == "browser-chrome" }) &&
                    strategy["primary_controller"] == "browser_cdp_dom"
                try? store.updateStatus("complete")
                return ToolResult(success: ok, evidence: ok ? "Runtime platform stores and recalls durable automation context." : "Runtime platform check failed.", data: [
                    "recipe_id": recipe.id,
                    "trajectory_events": "\(trajectory.count)",
                    "episode_id": episode.id,
                    "graph_nodes": "\(graph.nodes.count)",
                    "skills": skills.map(\.id).joined(separator: ","),
                    "strategy": jsonStringValue(strategy)
                ])
            },
            EvalCase(id: "recipe-exec-calendar-dry", title: "Recipe workflow engine dry verification") {
                let recipe = try RecipeStore.read("create-calendar-event")
                let params = try RecipeStore.resolvedParams(recipe: recipe, params: [
                    "title": "AIOS Eval Dry Run",
                    "start": "2026-05-22 10:00",
                    "end": "2026-05-22 10:15",
                    "notes": "dry-run"
                ])
                let rendered = recipe.steps.map { step in
                    [
                        "tool": RecipeStore.render(step.tool, params: params),
                        "arguments": jsonStringValue(RecipeStore.renderArguments(step.arguments, params: params))
                    ]
                }
                return ToolResult(success: rendered.count == 1, evidence: "Rendered executable recipe steps.", data: ["steps": jsonStringValue(rendered)])
            },
            EvalCase(id: "trajectory-replay-engine", title: "Trajectory replay engine dry-runs and clips recipes") {
                let store = try EventStore.start(goal: "Replay local file info", runID: "eval-replay-\(UUID().uuidString)")
                try store.append("AppAction", ["tool": "finder_file_info", "arguments": #"{"path":"Package.swift"}"#])
                try store.append("Observation", ["tool": "finder_file_info", "success": "true", "evidence": "Path exists."])
                let replay = try TrajectoryReplayEngine.replay(runID: store.runID, dryRun: true)
                let recipe = try TrajectoryReplayEngine.clipRecipe(runID: store.runID, recipeID: "eval-replay-\(store.runID)", title: "Eval Replay Clip")
                try? store.updateStatus("complete")
                let ok = replay.success && replay.data["actions"]?.contains("finder_file_info") == true && recipe.steps.count == 1
                return ToolResult(success: ok, evidence: ok ? "Replay engine can plan and clip trajectory actions." : "Replay engine check failed.", data: [
                    "run_id": store.runID,
                    "recipe_id": recipe.id,
                    "actions": replay.data["actions"] ?? ""
                ])
            },
            EvalCase(id: "session-protocol", title: "Session protocol projects cockpit state") {
                let store = try EventStore.start(goal: "Session protocol eval", runID: "eval-session-\(UUID().uuidString)")
                try store.append("UserGoal", ["goal": store.goal])
                try store.append("TaskPlan", ["objective": "Check session projection", "steps": "S1"])
                try store.append("StepQueue", ["step_id": "S1", "step_title": "Inspect status"])
                try store.append("AppAction", ["tool": "platform_status", "arguments": "{}"])
                try store.append("Observation", ["tool": "platform_status", "success": "true", "evidence": "Loaded platform status."])
                let timeline = try SessionProtocolStore.timeline(runID: store.runID, limit: 20)
                let snapshot = try SessionProtocolStore.cockpitSnapshot(runID: store.runID, limit: 20)
                let exportURL = try SessionProtocolStore.export(runID: store.runID)
                try? store.updateStatus("complete")
                let ok = timeline.contains(where: { $0.kind == "tool_call" }) &&
                    snapshot["schema"] == "aios.cockpit.snapshot.v1" &&
                    FileManager.default.fileExists(atPath: exportURL.path)
                return ToolResult(success: ok, evidence: ok ? "Session protocol and cockpit snapshot are available." : "Session protocol check failed.", data: [
                    "run_id": store.runID,
                    "events": "\(timeline.count)",
                    "snapshot_schema": snapshot["schema"] ?? "",
                    "export": exportURL.path
                ])
            },
            EvalCase(id: "semantic-memory-index", title: "Semantic memory index builds context packs") {
                _ = try MemoryStore.remember(
                    kind: "workflow_hint",
                    scope: "eval",
                    app: "Chrome",
                    key: "Chrome background DOM",
                    value: "Prefer browser_cdp_observe and browser_cdp_act for long web app tasks.",
                    confidence: 0.9,
                    sourceRunID: "eval",
                    sourceTool: "eval"
                )
                let store = try EventStore.start(goal: "Use Chrome CDP for a web app", runID: "eval-memory-\(UUID().uuidString)")
                let episode = EpisodeStore.record(runID: store.runID, goal: store.goal, plan: TaskPlan.fallback(goal: store.goal), outcome: "eval", eventsText: "")
                ContextGraphStore.ingest(fromKind: "workflow", fromLabel: "web automation", toKind: "app", toLabel: "Chrome", relation: "prefers_tool", weight: 1, attributes: ["tool": "browser_cdp_act"])
                let items = try MemoryIndexStore.rebuild()
                let hits = MemoryIndexStore.recall(query: "Chrome web app DOM automation", limit: 5)
                let pack = MemoryIndexStore.contextPack(query: "Chrome web app DOM automation", limit: 5)
                try? store.updateStatus("complete")
                let ok = !items.isEmpty &&
                    hits.contains(where: { $0.item.source == "memory" || $0.item.source == "episode" }) &&
                    pack["semantic_hits"]?.contains("Chrome") == true &&
                    episode.runID == store.runID
                return ToolResult(success: ok, evidence: ok ? "Semantic memory index and context pack work." : "Semantic memory index check failed.", data: [
                    "items": "\(items.count)",
                    "hits": jsonStringValue(hits.map { $0.item.dictionary }),
                    "pack": jsonStringValue(pack)
                ])
            },
            EvalCase(id: "browser-runtime-cache", title: "Browser runtime selector cache is durable") {
                let entry = BrowserSelectorCacheStore.record(
                    url: "https://example.com/app",
                    query: "Submit",
                    selector: "button[data-testid=\"submit\"]",
                    action: "click",
                    success: true
                )
                let found = BrowserSelectorCacheStore.lookup(url: "https://example.com/app", query: "Submit", action: "click")
                let listed = BrowserSelectorCacheStore.list(query: "Submit", limit: 5)
                let skill = AppSkillStore.suggest(query: "Chrome shadow iframe upload download", limit: 3).first
                let ok = found?.selector == entry.selector &&
                    listed.contains(where: { $0.id == entry.id }) &&
                    (skill?.tools.contains("browser_cdp_file_upload") == true)
                return ToolResult(success: ok, evidence: ok ? "Browser selector cache and Chrome skill capabilities are available." : "Browser runtime cache check failed.", data: [
                    "entry": jsonStringValue(entry.dictionary),
                    "listed": jsonStringValue(listed.map(\.dictionary)),
                    "skill": skill.map { jsonStringValue($0.dictionary) } ?? ""
                ])
            },
            EvalCase(id: "app-skill-package", title: "App skill package scaffold loads as a skill") {
                let package = try AppSkillPackageStore.scaffold(
                    id: "eval-notes-skill",
                    appName: "Notes",
                    bundleID: "com.apple.Notes",
                    capabilities: ["notes", "text", "search"],
                    tools: ["notes_create_note", "notes_search"],
                    recipes: ["eval-notes-recipe"],
                    selectors: ["search": "AXSearchField"],
                    permissions: ["automation"],
                    notes: "Eval package."
                )
                let knownTools = Set(ToolRegistry().definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
                let issues = AppSkillPackageStore.validate(package, knownTools: knownTools)
                let listed = AppSkillPackageStore.list()
                let suggested = AppSkillStore.suggest(query: "Notes search eval", limit: 5)
                let ok = issues.isEmpty &&
                    listed.contains(where: { $0.id == package.id }) &&
                    suggested.contains(where: { $0.id == package.id }) &&
                    FileManager.default.fileExists(atPath: AppSkillPackageStore.packageURL(id: package.id).appendingPathComponent("recipes", isDirectory: true).path)
                return ToolResult(success: ok, evidence: ok ? "App skill package scaffold is loadable." : "App skill package check failed.", data: [
                    "package": jsonStringValue(package.dictionary),
                    "issues": issues.joined(separator: "\n"),
                    "suggested": jsonStringValue(suggested.map(\.dictionary))
                ])
            },
            EvalCase(id: "task-graph-runtime", title: "Durable task graph schedules ready nodes") {
                let nodesJSON = """
                [
                  {"id":"N1","title":"Immediate","goal":"Task graph eval immediate"},
                  {"id":"N2","title":"Wait for Package.swift","goal":"Task graph eval file watcher","depends_on":["N1"],"wait_condition":"file_exists","wait_value":"Package.swift"}
                ]
                """
                var graph = try TaskGraphStore.create(
                    title: "Eval Task Graph",
                    goal: "Evaluate task graph",
                    nodes: try TaskGraphStore.nodes(from: nodesJSON, fallbackGoal: "Evaluate task graph")
                )
                let firstTick = try TaskGraphStore.tick(graphID: graph.id)
                graph = try TaskGraphStore.read(graph.id)
                if let runID = graph.nodes.first(where: { $0.id == "N1" })?.runID {
                    try? EventStore.markRun(runID: runID, status: "complete", event: "EvalRunComplete", fields: [:])
                }
                let secondTick = try TaskGraphStore.tick(graphID: graph.id)
                graph = try TaskGraphStore.read(graph.id)
                let n1 = graph.nodes.first { $0.id == "N1" }
                let n2 = graph.nodes.first { $0.id == "N2" }
                let ok = firstTick.first?.scheduled.contains("N1") == true &&
                    secondTick.first?.scheduled.contains("N2") == true &&
                    n1?.status == "complete" &&
                    n2?.runID?.isEmpty == false
                return ToolResult(success: ok, evidence: ok ? "Durable task graph schedules dependencies and watchers." : "Task graph runtime check failed.", data: [
                    "graph": jsonStringValue(graph.dictionary),
                    "first_tick": jsonStringValue(firstTick.map(\.dictionary)),
                    "second_tick": jsonStringValue(secondTick.map(\.dictionary))
                ])
            },
            EvalCase(id: "recipe-adaptation", title: "Recipe generalizer and adaptive runner prepare self-healing workflows") {
                let base = try RecipeStore.save(Recipe(
                    id: "eval-adapt-base",
                    title: "Eval Adapt Base",
                    goalTemplate: "Check Package.swift and click Submit",
                    parameters: [],
                    requiredParams: [],
                    notes: "eval",
                    steps: [
                        RecipeStep(id: "S1", title: "Check package", tool: "finder_file_info", arguments: ["path": "Package.swift"], verifyExpression: "success"),
                        RecipeStep(id: "S2", title: "Click submit", tool: "browser_cdp_click", arguments: ["selector": "button[data-testid='submit']"], verifyExpression: "success")
                    ]
                ))
                let generalized = try RecipeGeneralizer.generalize(recipeID: base.id, outputID: "eval-adapt-generalized")
                let hint = try RecipeAdaptationStore.recordHint(
                    recipeID: generalized.id,
                    stepID: "S2",
                    failedTool: "browser_cdp_click",
                    replacementTool: "browser_cdp_act",
                    arguments: ["action": "click", "query": "Submit"],
                    reason: "Selector can drift; query-based act can re-resolve.",
                    success: true
                )
                let adaptive = RecipeGeneralizer.adaptiveRecipe(generalized)
                let s2 = adaptive.steps.first { $0.id == "S2" }
                let ok = generalized.requiredParams.contains("path") &&
                    (s2?.fallbackTools ?? []).contains(where: { $0.tool == "browser_cdp_act" }) &&
                    RecipeAdaptationStore.hints(recipeID: generalized.id).contains(where: { $0.id == hint.id })
                return ToolResult(success: ok, evidence: ok ? "Recipe generalization and repair hint injection work." : "Recipe adaptation check failed.", data: [
                    "base": base.id,
                    "generalized": generalized.jsonString,
                    "adaptive_step": s2.map { jsonStringValue(["id": $0.id, "fallbacks": jsonStringValue(($0.fallbackTools ?? []).map { $0.tool })]) } ?? "",
                    "hint": jsonStringValue(hint.dictionary)
                ])
            },
            EvalCase(id: "visual-grounding-v2", title: "Visual grounding returns schema-rich color/layout/action candidates") {
                let url = URL(fileURLWithPath: "/private/tmp/aios-visual-grounding-eval.png")
                let width = 360
                let height = 220
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: width,
                    pixelsHigh: height,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) else {
                    return ToolResult(success: false, evidence: "Could not create eval bitmap.", error: "bitmap_create_failed")
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.white.setFill()
                NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
                NSColor(calibratedRed: 0.08, green: 0.36, blue: 0.92, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 238, y: 142, width: 92, height: 40), xRadius: 8, yRadius: 8).fill()
                NSColor.white.set()
                ("Submit" as NSString).draw(at: CGPoint(x: 258, y: 154), withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 17),
                    .foregroundColor: NSColor.white
                ])
                NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
                NSBezierPath(rect: CGRect(x: 0, y: 0, width: 92, height: height)).fill()
                NSGraphicsContext.restoreGraphicsState()
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    return ToolResult(success: false, evidence: "Could not encode eval bitmap.", error: "bitmap_encode_failed")
                }
                try png.write(to: url, options: [.atomic])
                let result = ToolRegistry().execute(ToolCall(
                    id: "eval",
                    name: "visual_ground_action",
                    arguments: ["path": url.path, "query": "primary", "action": "click", "execute": false, "max_results": 40],
                    raw: [:]
                ))
                let candidatesText = result.data["candidates"] ?? ""
                let checks = [
                    "success": result.success ? "true" : "false",
                    "foreground": result.data["requires_foreground"] == "true" ? "true" : "false",
                    "color": candidatesText.contains("color_saliency") ? "true" : "false",
                    "layout": candidatesText.contains("layout_prior") ? "true" : "false",
                    "schema": (result.data["candidate"] ?? "").contains("grounding_version") ? "true" : "false"
                ]
                let ok = checks.values.allSatisfy { $0 == "true" }
                return ToolResult(success: ok, evidence: ok ? "Visual grounding v2 produced schema-rich action candidates." : "Visual grounding v2 check failed: \(jsonStringValue(checks))", data: result.data, error: ok ? nil : result.error)
            },
            EvalCase(id: "background-control-kernel", title: "Background control kernel exposes CUA-style channel guarantees and boundaries") {
                let plan = ToolRegistry().execute(ToolCall(
                    id: "eval",
                    name: "background_kernel_plan",
                    arguments: [
                        "action": "click",
                        "app_name": "Figma",
                        "surface": "canvas",
                        "query": "prototype play button",
                        "allow_foreground": false
                    ],
                    raw: [:]
                ))
                let channels = plan.data["channels"] ?? ""
                let ok = plan.success &&
                    channels.contains("browser_cdp_dom") &&
                    channels.contains("visual_grounding") &&
                    channels.contains("public_api_boundary") &&
                    channels.contains("cursor_safe") &&
                    channels.contains("non_ax_surface") &&
                    (plan.data["boundary"] ?? "").contains("non-AX native")
                return ToolResult(success: ok, evidence: ok ? "Background control kernel models channels, guarantees, and macOS boundary." : "Background control kernel check failed.", data: plan.data, error: ok ? nil : plan.error)
            },
            EvalCase(id: "long-agent-platform-10", title: "Long-running computer-use platform kernels are integrated") {
                let tools = ToolRegistry()
                let store = try EventStore.start(goal: "Long platform eval: use Chrome, visual grounding, recipe, and memory", runID: "eval-long-platform-\(UUID().uuidString)")
                try store.append("StepQueue", ["step_id": "S1", "step_title": "Inspect file"])
                try store.append("AppAction", ["tool": "finder_file_info", "arguments": #"{"path":"Package.swift"}"#])
                try store.append("Observation", ["tool": "finder_file_info", "success": "true", "evidence": "Path exists."])
                try store.updateStatus("complete")

                let role = tools.execute(ToolCall(id: "eval", name: "agent_role_plan", arguments: ["goal": "持续使用 Chrome web app，并在 Figma canvas 上识别按钮", "app_name": "Chrome", "surface": "canvas"], raw: [:]))
                let handoff = tools.execute(ToolCall(id: "eval", name: "agent_handoff_packet", arguments: ["goal": store.goal, "from_role": "planner", "to_role": "browser_specialist", "reason": "web app step"], raw: [:]))
                let browserSession = tools.execute(ToolCall(id: "eval", name: "browser_runtime_session", arguments: ["name": "eval-browser", "endpoint": "http://127.0.0.1:9222", "profile_dir": "/private/tmp/aios-eval-browser"], raw: [:]))
                let browserPlan = tools.execute(ToolCall(id: "eval", name: "browser_runtime_plan", arguments: ["goal": "Click Submit in long web app", "url": "https://example.com/app"], raw: [:]))
                let browserAgentPlan = tools.execute(ToolCall(id: "eval", name: "browser_agent_plan", arguments: ["goal": "Click Submit in long web app", "url": "https://example.com/app"], raw: [:]))
                let skillRoute = tools.execute(ToolCall(id: "eval", name: "app_skill_route", arguments: ["query": "Chrome web CDP"], raw: [:]))
                let skillExport = tools.execute(ToolCall(id: "eval", name: "app_skill_export_manifest", arguments: ["id": "browser-chrome"], raw: [:]))
                let memory = tools.execute(ToolCall(id: "eval", name: "memory_episode_consolidate", arguments: ["run_id": store.runID, "outcome": "success"], raw: [:]))
                let shadow = tools.execute(ToolCall(id: "eval", name: "memory_shadow_digest", arguments: ["limit": 5], raw: [:]))
                let shadowCapture = tools.execute(ToolCall(id: "eval", name: "memory_shadow_capture", arguments: ["run_id": store.runID, "goal": store.goal, "trigger": "eval", "limit": 5], raw: [:]))
                let cockpitCommand = tools.execute(ToolCall(id: "eval", name: "cockpit_command", arguments: ["run_id": store.runID, "command": "feedback", "feedback": "continue from the browser step"], raw: [:]))
                let cockpit = tools.execute(ToolCall(id: "eval", name: "cockpit_live_state", arguments: ["limit": 5], raw: [:]))
                let trajectoryProduct = tools.execute(ToolCall(id: "eval", name: "trajectory_product_export", arguments: ["run_id": store.runID], raw: [:]))
                let resumePoints = tools.execute(ToolCall(id: "eval", name: "trajectory_resume_points", arguments: ["run_id": store.runID], raw: [:]))
                let branch = tools.execute(ToolCall(id: "eval", name: "trajectory_branch_create", arguments: ["run_id": store.runID, "from_index": 2, "goal": "continue branch"], raw: [:]))
                let recipeProgram = tools.execute(ToolCall(id: "eval", name: "recipe_program_compile", arguments: ["id": "create-calendar-event"], raw: [:]))
                let recipeInfer = tools.execute(ToolCall(id: "eval", name: "recipe_schema_infer", arguments: ["run_id": store.runID, "recipe_id": "eval-long-platform-recipe"], raw: [:]))
                let visualStrategy = tools.execute(ToolCall(id: "eval", name: "visual_perception_strategy", arguments: ["surface": "canvas", "query": "icon button"], raw: [:]))
                let visualCache = tools.execute(ToolCall(id: "eval", name: "visual_ui_map_cache", arguments: ["image_path": "/private/tmp/eval.png", "query": "button", "candidates_json": "[]"], raw: [:]))
                let dispatch = tools.execute(ToolCall(id: "eval", name: "background_dispatch_plan", arguments: ["action": "click", "app_name": "Figma", "surface": "canvas", "query": "play"], raw: [:]))
                let schedule = tools.execute(ToolCall(id: "eval", name: "long_run_schedule", arguments: ["goal": "scheduled eval", "after_seconds": 0], raw: [:]))
                let daemon = tools.execute(ToolCall(id: "eval", name: "long_run_daemon_tick", arguments: [:], raw: [:]))

                let results = [
                    role, handoff, browserSession, browserPlan, browserAgentPlan, skillRoute, skillExport,
                    memory, shadow, shadowCapture, cockpitCommand, cockpit, trajectoryProduct, resumePoints,
                    branch, recipeProgram, recipeInfer, visualStrategy, visualCache, dispatch,
                    schedule, daemon
                ]
                let inferredRecipeValid = (recipeInfer.data["compile"] ?? "").contains(#""valid":"true""#)
                let ok = results.allSatisfy(\.success) &&
                    (role.data["route"] ?? "").contains("browser_specialist") &&
                    (dispatch.data["can_dispatch_without_focus"] ?? "") == "true" &&
                    (resumePoints.data["resume_points"] ?? "").contains("finder_file_info") &&
                    (cockpitCommand.data["status"] ?? "") == "applied" &&
                    inferredRecipeValid
                let failed = results.filter { !$0.success }.map { $0.error ?? $0.evidence }.joined(separator: " | ")
                return ToolResult(success: ok, evidence: ok ? "All 10 long-agent platform kernels are callable and integrated." : "Long-agent platform integration failed: \(failed)", data: [
                    "run_id": store.runID,
                    "results": jsonStringValue(results.map { ["success": $0.success ? "true" : "false", "evidence": $0.evidence, "error": $0.error ?? ""] }),
                    "role": role.data["route"] ?? "",
                    "dispatch": jsonStringValue(dispatch.data),
                    "cockpit_command_status": cockpitCommand.data["status"] ?? "",
                    "inferred_recipe_valid": inferredRecipeValid ? "true" : "false",
                    "inferred_recipe_compile": recipeInfer.data["compile"] ?? ""
                ], error: ok ? nil : "long_agent_platform_incomplete")
            },
            EvalCase(id: "open-source-parity-10", title: "Open-source parity kernels cover long macOS computer-use gaps") {
                let tools = ToolRegistry()
                let store = try EventStore.start(goal: "Open-source parity eval: inspect Package.swift, learn it, replay it, and keep runtime observable", runID: "eval-parity-\(UUID().uuidString)")
                try store.append("StepQueue", ["step_id": "S1", "step_title": "Inspect package"])
                try store.append("AppAction", ["tool": "finder_file_info", "arguments": #"{"path":"Package.swift"}"#])
                try store.append("Observation", ["tool": "finder_file_info", "success": "true", "evidence": "Path exists.", "path": "Package.swift"])
                try store.updateStatus("complete")

                let calls: [ToolCall] = [
                    ToolCall(id: "eval", name: "background_driver_matrix", arguments: [:], raw: [:]),
                    ToolCall(id: "eval", name: "background_driver_dispatch", arguments: ["app_name": "Figma", "surface": "canvas", "action": "click", "query": "play", "dry_run": true], raw: [:]),
                    ToolCall(id: "eval", name: "visual_grounder_profiles", arguments: [:], raw: [:]),
                    ToolCall(id: "eval", name: "visual_grounder_session", arguments: ["surface": "canvas", "query": "play button", "image_path": "/private/tmp/eval.png"], raw: [:]),
                    ToolCall(id: "eval", name: "visual_ui_map_query", arguments: ["query": "button", "limit": 5], raw: [:]),
                    ToolCall(id: "eval", name: "recipe_learn_once", arguments: ["run_id": store.runID, "recipe_id": "eval-parity-learned"], raw: [:]),
                    ToolCall(id: "eval", name: "recipe_learn_recipe", arguments: ["recipe_id": "eval-parity-learned", "source_run_id": store.runID], raw: [:]),
                    ToolCall(id: "eval", name: "recipe_program_select", arguments: ["goal": "inspect Package.swift", "limit": 5], raw: [:]),
                    ToolCall(id: "eval", name: "long_task_state", arguments: ["run_id": store.runID, "limit": 5], raw: [:]),
                    ToolCall(id: "eval", name: "long_task_watch", arguments: ["goal": "continue after Package.swift appears", "condition": "file_exists", "value": "Package.swift", "title": "Parity watch"], raw: [:]),
                    ToolCall(id: "eval", name: "memory_entity_graph", arguments: ["query": "Package.swift", "limit": 10], raw: [:]),
                    ToolCall(id: "eval", name: "memory_preference_digest", arguments: ["query": "Package.swift", "limit": 10], raw: [:]),
                    ToolCall(id: "eval", name: "memory_shadow_capture", arguments: ["run_id": store.runID, "goal": store.goal, "trigger": "parity", "limit": 10], raw: [:]),
                    ToolCall(id: "eval", name: "browser_agent_plan", arguments: ["goal": "Submit form in web app", "url": "https://example.com/app"], raw: [:]),
                    ToolCall(id: "eval", name: "browser_agent_observation", arguments: ["url": "https://example.com/app", "goal": "Submit form in web app", "observation_json": #"{"buttons":["Submit"]}"#], raw: [:]),
                    ToolCall(id: "eval", name: "browser_agent_snapshot", arguments: ["query": "Submit", "limit": 5], raw: [:]),
                    ToolCall(id: "eval", name: "app_skill_sdk", arguments: [:], raw: [:]),
                    ToolCall(id: "eval", name: "app_skill_marketplace", arguments: ["query": "Chrome", "limit": 5], raw: [:]),
                    ToolCall(id: "eval", name: "cockpit_dashboard", arguments: ["run_id": store.runID, "limit": 5], raw: [:]),
                    ToolCall(id: "eval", name: "cockpit_dashboard_export", arguments: ["run_id": store.runID, "limit": 5], raw: [:]),
                    ToolCall(id: "eval", name: "trajectory_bundle_manifest", arguments: ["run_id": store.runID, "limit": 80], raw: [:]),
                    ToolCall(id: "eval", name: "trajectory_bundle_export", arguments: ["run_id": store.runID, "limit": 80], raw: [:]),
                    ToolCall(id: "eval", name: "agent_harness_plan", arguments: ["goal": "持续在 Chrome 和 Figma 完成任务", "app_name": "Chrome", "surface": "canvas"], raw: [:]),
                    ToolCall(id: "eval", name: "agent_harness_tick", arguments: ["goal": "持续在 Chrome 和 Figma 完成任务", "current_role": "planner", "evidence": "parity eval"], raw: [:]),
                    ToolCall(id: "eval", name: "long_task_interrupt", arguments: ["run_id": store.runID, "instruction": "continue with learned recipe", "mode": "replan"], raw: [:])
                ]
                let results = calls.map { tools.execute($0) }
                let ok = results.allSatisfy(\.success) &&
                    (results.first { $0.data["schema"] == "aios.background.driver.dispatch.v1" }?.data["request"] ?? "").contains("must_not_move_cursor") &&
                    (results.first { $0.data["schema"] == "aios.recipe.learn_once.v1" }?.data["ready_for_reuse"] ?? "") == "true" &&
                    (results.first { $0.data["schema"] == "aios.agent.harness.plan.v1" }?.data["route"] ?? "").contains("planner")
                let failed = zip(calls, results).filter { !$0.1.success }.map { "\($0.0.name):\($0.1.error ?? $0.1.evidence)" }.joined(separator: " | ")
                return ToolResult(success: ok, evidence: ok ? "All open-source parity kernels are integrated." : "Parity kernel integration failed: \(failed)", data: [
                    "run_id": store.runID,
                    "results": jsonStringValue(zip(calls, results).map { ["tool": $0.0.name, "success": $0.1.success ? "true" : "false", "evidence": $0.1.evidence, "error": $0.1.error ?? ""] })
                ], error: ok ? nil : "open_source_parity_incomplete")
            },
            EvalCase(id: "policy", title: "Protected shell delete blocked") {
                let call = ToolCall(id: "eval", name: "terminal_run_command", arguments: ["command": "rm -rf ~/Desktop/test"], raw: [:])
                let decision = PolicyEngine().evaluate(call, knownTools: Set(ToolRegistry().definitions.compactMap { definition in
                    (definition["function"] as? [String: Any])?["name"] as? String
                }))
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "chat-completion-gate", title: "Chat delivery cannot complete without message verification") {
                var state = CompletionContractState(goal: "Send good night to Example Contact in WeChat")
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_verify_chat", arguments: ["recipient": "Example Contact"], raw: [:]),
                    result: ToolResult(success: true, evidence: "WeChat OCR contains expected text.")
                )
                let plan = TaskPlan.fallback(goal: "Send good night to Example Contact in WeChat")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-file-save-required", title: "File save completion requires verified file effect") {
                var state = CompletionContractState(goal: "写入 hello 并保存到 ~/Desktop/aios-contract.txt")
                state.record(
                    call: ToolCall(id: "eval", name: "aios_open_app", arguments: ["app_name": "TextEdit"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Opened app TextEdit.", data: ["effect": "app_opened", "app": "TextEdit", "verified": "true"])
                )
                let plan = TaskPlan.fallback(goal: "写入 hello 并保存到 ~/Desktop/aios-contract.txt")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-calendar-required", title: "Calendar completion requires verified calendar event effect") {
                var state = CompletionContractState(goal: "明天 10 点创建一个日历日程")
                state.record(
                    call: ToolCall(id: "eval", name: "calendar_find_events", arguments: ["title": "会议"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Found 0 Calendar event(s).", data: ["events": "[]"])
                )
                let plan = TaskPlan.fallback(goal: "明天 10 点创建一个日历日程")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-open-only-not-delivery", title: "Open/search/click evidence cannot satisfy delivery") {
                var state = CompletionContractState(goal: "Open WeChat and send the Downloads example.docx file to Example Contact")
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_open", arguments: [:], raw: [:]),
                    result: ToolResult(success: true, evidence: "Opened WeChat.", data: ["effect": "app_opened", "app": "WeChat", "verified": "true"])
                )
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_search_chat", arguments: ["name": "Example Contact"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Searched WeChat for chat/contact.")
                )
                let plan = TaskPlan.fallback(goal: "Open WeChat and send the Downloads example.docx file to Example Contact")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-chat-satisfied", title: "Verified message effect satisfies chat delivery") {
                var state = CompletionContractState(goal: "Send good night to Example Contact in WeChat")
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_send_text", arguments: ["recipient": "Example Contact", "text": "晚安"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Sent and verified WeChat text message.", data: [
                        "effect": "external_message_sent",
                        "app": "WeChat",
                        "target": "Example Contact",
                        "value": "晚安",
                        "verified": "true",
                        "recipient": "Example Contact",
                        "message": "晚安",
                        "verified_recipient": "true",
                        "verified_message": "true"
                    ])
                )
                let plan = TaskPlan.fallback(goal: "Send good night to Example Contact in WeChat")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-continuous-chat-requires-send", title: "Continuous chat cannot complete by opening WeChat only") {
                var state = CompletionContractState(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_open_chat", arguments: ["recipient": "Example Contact"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Opened and verified WeChat chat.", data: [
                        "effect": "chat_session_ready",
                        "app": "WeChat",
                        "target": "Example Contact",
                        "verified": "true",
                        "recipient": "Example Contact"
                    ])
                )
                let plan = TaskPlan.fallback(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-chat-open-step-not-send", title: "Open/search chat step is not forced to satisfy delivery") {
                let state = CompletionContractState(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let step = TaskStep(
                    id: "S1",
                    title: "打开并定位聊天",
                    goal: "打开微信，搜索并定位Example Contact聊天，验证当前聊天对象。",
                    verification: "当前聊天对象是Example Contact。"
                )
                let decision = state.stepCompletionGate(step: step)
                return ToolResult(success: decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "message-probe-short", title: "Long chat message uses a short stable probe") {
                let probe = ToolRegistry().messageVerificationProbe("Hey, about this project concept. The core idea is that the user states a goal, then the system plans steps and executes tools.")
                return ToolResult(success: probe.count <= 32 && probe.localizedCaseInsensitiveContains("project concept"), evidence: probe, data: [
                    "probe": probe,
                    "chars": "\(probe.count)"
                ])
            },
            EvalCase(id: "raw-ui-send-can-verify-with-observation", title: "Raw UI return in verified chat can satisfy delivery only after observation") {
                var state = CompletionContractState(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let text = "这个项目的原理是什么？能详细解释一下吗？"
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_open_chat", arguments: ["recipient": "Example Contact"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Opened and verified WeChat chat.", data: [
                        "effect": "chat_session_ready",
                        "app": "WeChat",
                        "target": "Example Contact",
                        "verified": "true",
                        "recipient": "Example Contact"
                    ])
                )
                state.record(
                    call: ToolCall(id: "eval", name: "clipboard_set_text", arguments: ["text": text], raw: [:]),
                    result: ToolResult(success: true, evidence: "Set clipboard plain text.")
                )
                state.record(
                    call: ToolCall(id: "eval", name: "ui_keyboard_shortcut", arguments: ["key": "return"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Sent keyboard shortcut.")
                )
                var plan = TaskPlan.fallback(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let before = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                state.record(
                    call: ToolCall(id: "eval", name: "ocr_image", arguments: [:], raw: [:]),
                    result: ToolResult(success: true, evidence: "OCR read message.", data: ["text": "18:54\n这个项目的原理是什么？能详细解释一下吗？"])
                )
                plan = TaskPlan.fallback(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let after = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !before.allowed && after.allowed, evidence: after.reason)
            },
            EvalCase(id: "chat-context-read-step-not-send", title: "Context reading chat step is not forced to send") {
                let state = CompletionContractState(goal: "Continue chatting with Example Contact in WeChat, informal and context-aware")
                let step = TaskStep(
                    id: "S3",
                    title: "阅读上下文",
                    goal: "查看最近的聊天记录，了解之前的话题和语境。",
                    verification: "已获取最近几条消息内容，理解聊天上下文。"
                )
                let decision = state.stepCompletionGate(step: step)
                return ToolResult(success: decision.allowed, evidence: decision.reason)
            }
        ]
    }

    func run(filter: String?, repeatCount: Int = 1) throws -> [EvalResult] {
        try FileManager.default.createDirectory(at: EventStore.evalsURL, withIntermediateDirectories: true)
        let selected = Self.cases.filter { filter == nil || $0.id == filter }
        var results: [EvalResult] = []
        for testCase in selected {
            for attempt in 1...max(1, repeatCount) {
                let start = Date()
                let result = try testCase.run()
                let duration = Int(Date().timeIntervalSince(start) * 1000)
                let id = repeatCount > 1 ? "\(testCase.id)#\(attempt)" : testCase.id
                results.append(EvalResult(id: id, passed: result.success, evidence: result.evidence, durationMs: duration))
            }
        }
        let passCount = results.filter(\.passed).count
        let payload: [String: Any] = [
            "time": isoDateString(Date()),
            "passed": "\(passCount)",
            "total": "\(results.count)",
            "success_rate": results.isEmpty ? "0" : String(format: "%.2f", Double(passCount) / Double(results.count)),
            "results": results.map { ["id": $0.id, "passed": $0.passed ? "true" : "false", "evidence": $0.evidence, "duration_ms": "\($0.durationMs)"] }
        ]
        try writeJSONObject(payload, to: EventStore.evalsURL.appendingPathComponent("last-run.json"))
        return results
    }

    static func lastRunText() -> String {
        let url = EventStore.evalsURL.appendingPathComponent("last-run.json")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static var realCasesURL: URL {
        EventStore.evalsURL.appendingPathComponent("real-e2e-cases.json")
    }

    static func seedRealCases(overwrite: Bool = false) throws {
        try FileManager.default.createDirectory(at: EventStore.evalsURL, withIntermediateDirectories: true)
        guard overwrite || !FileManager.default.fileExists(atPath: realCasesURL.path) else { return }
        let cases = [
            RealE2ECase(
                id: "project-plan-send-to-contact",
                title: "Draft a short project plan and send it to Example Contact",
                recipeID: nil,
                params: [:],
                goal: "Draft a short project plan and send it to Example Contact",
                enabled: false,
                destructive: false,
                sendsExternalMessage: true,
                notes: "Default full-stack real E2E query for this project. It uses the LLM, current market research if available, document drafting, WeChat/Lark/QQ adapter selection, recipient verification, and external send verification. Enable only when you intentionally want to send Example Contact a real message."
            ),
            RealE2ECase(
                id: "wechat-send-download-example-to-contact",
                title: "Open WeChat and send ~/Downloads/example.docx to Example Contact",
                recipeID: "send-file-to-contact",
                params: ["app": "微信", "recipient": "Example Contact", "path": "~/Downloads/example.docx"],
                goal: nil,
                enabled: false,
                destructive: false,
                sendsExternalMessage: true,
                notes: "Real send case. Enable explicitly in this config and set AIOS_ALLOW_REAL_E2E=1 before running."
            ),
            RealE2ECase(
                id: "calendar-create-real",
                title: "Create a real Calendar event",
                recipeID: "create-calendar-event",
                params: ["title": "AIOS Real E2E", "start": "2026-05-22 10:00", "end": "2026-05-22 10:15", "notes": "real-e2e"],
                goal: nil,
                enabled: false,
                destructive: false,
                sendsExternalMessage: false,
                notes: "Writes Calendar state. Enable explicitly before running."
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cases).write(to: realCasesURL, options: [.atomic])
    }

    static func realCases() throws -> [RealE2ECase] {
        try seedRealCases(overwrite: false)
        return try JSONDecoder().decode([RealE2ECase].self, from: Data(contentsOf: realCasesURL))
    }

    func runReal(id: String) async throws -> ToolResult {
        try Self.seedRealCases(overwrite: false)
        guard ProcessInfo.processInfo.environment["AIOS_ALLOW_REAL_E2E"] == "1" else {
            throw RuntimeError("Real E2E is locked. Set AIOS_ALLOW_REAL_E2E=1 after reviewing \(Self.realCasesURL.path).")
        }
        let cases = try Self.realCases()
        guard let testCase = cases.first(where: { $0.id == id }) else {
            throw RuntimeError("Unknown real E2E case: \(id)")
        }
        guard testCase.enabled else {
            throw RuntimeError("Real E2E case is disabled in \(Self.realCasesURL.path): \(id)")
        }
        if testCase.destructive {
            throw RuntimeError("Destructive real E2E cases are not supported by this prototype.")
        }
        let caseGoal = testCase.goal ?? "real-e2e:\(id)"
        let store = try EventStore.start(goal: caseGoal)
        let result: ToolResult
        if let recipeID = testCase.recipeID {
            let results = try RecipeStore.execute(recipeID: recipeID, params: testCase.params, eventStore: store)
            let ok = results.allSatisfy(\.success)
            result = ToolResult(success: ok, evidence: ok ? "Real E2E \(id) passed." : "Real E2E \(id) failed.", data: [
                "run_id": store.runID,
                "results": jsonStringValue(results.map { ["success": $0.success ? "true" : "false", "evidence": $0.evidence, "error": $0.error ?? ""] })
            ])
        } else if let goal = testCase.goal, !goal.isEmpty {
            let config = LLMConfig.fromEnvironment()
            let ok = try await AgentLoop(client: OpenAICompatibleClient(config: config), tools: ToolRegistry(), eventStore: store).run(goal: goal)
            result = ToolResult(success: ok, evidence: ok ? "Real E2E \(id) completed through AgentLoop." : "Real E2E \(id) stopped incomplete.", data: [
                "run_id": store.runID,
                "goal": goal
            ])
        } else {
            throw RuntimeError("Real E2E case must use recipe_id or goal: \(id)")
        }
        try store.updateStatus(result.success ? "complete" : "failed")
        return result
    }
}
