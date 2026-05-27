import Foundation

struct AgentRoleSpec: Codable {
    let id: String
    let title: String
    let mission: String
    let tools: [String]
    let inputs: [String]
    let outputs: [String]
    let handoffs: [String]

    var dictionary: [String: String] {
        [
            "id": id,
            "title": title,
            "mission": mission,
            "tools": tools.joined(separator: ","),
            "inputs": inputs.joined(separator: ","),
            "outputs": outputs.joined(separator: ","),
            "handoffs": handoffs.joined(separator: ",")
        ]
    }
}

struct AgentHandoffPacket: Codable {
    let id: String
    let goal: String
    let fromRole: String
    let toRole: String
    let reason: String
    let context: [String: String]
    let tools: [String]
    let stopConditions: [String]
    let createdAt: String

    var dictionary: [String: String] {
        [
            "id": id,
            "goal": goal,
            "from_role": fromRole,
            "to_role": toRole,
            "reason": reason,
            "context": jsonStringValue(context),
            "tools": tools.joined(separator: ","),
            "stop_conditions": stopConditions.joined(separator: " | "),
            "created_at": createdAt
        ]
    }
}

struct AgentRoleSystem {
    static let roles: [AgentRoleSpec] = [
        AgentRoleSpec(
            id: "planner",
            title: "Planner",
            mission: "Decompose the user goal into durable phases, pick recipes/skills first, and choose explicit stop conditions.",
            tools: ["computer_use_strategy", "computer_use_model_stack", "long_agent_capability_matrix", "recipe_suggest", "app_skill_suggest", "memory_context_pack", "task_graph_create"],
            inputs: ["goal", "memory_context", "available_skills"],
            outputs: ["task_plan", "role_route", "task_graph"],
            handoffs: ["recipe_runner", "browser_specialist", "app_skill_specialist", "executor", "runtime_operator"]
        ),
        AgentRoleSpec(
            id: "executor",
            title: "Executor",
            mission: "Execute one bounded step through the deepest non-invasive channel and return structured evidence.",
            tools: ["background_native_kernel", "background_driver_probe", "background_driver_capsule", "background_driver_dispatch", "background_action", "background_kernel_plan", "aios_find", "aios_read", "visual_ground_action"],
            inputs: ["step", "target", "constraints"],
            outputs: ["tool_result", "evidence", "recovery_hint"],
            handoffs: ["perception_grounder", "verifier", "runtime_operator"]
        ),
        AgentRoleSpec(
            id: "perception_grounder",
            title: "Perception Grounder",
            mission: "Convert screenshots/windows/images into UI candidates, action points, and verification anchors.",
            tools: ["visual_grounder_model_registry", "visual_grounder_policy", "visual_grounder_calibrate", "visual_grounder_feedback", "visual_grounder_verify", "visual_candidates", "visual_ground", "visual_grounder_run", "visual_ground_action", "visual_analyze", "screen_capture_window_sck"],
            inputs: ["image", "query", "target_surface"],
            outputs: ["grounding_candidates", "action_plan", "verification_anchors"],
            handoffs: ["executor", "verifier"]
        ),
        AgentRoleSpec(
            id: "browser_specialist",
            title: "Browser Specialist",
            mission: "Operate long web-app sessions through CDP observe/act/extract/wait with selector cache and session snapshots.",
            tools: ["browser_agent_contract", "browser_agent_plan", "browser_agent_observe", "browser_agent_act", "browser_agent_extract", "browser_agent_wait", "browser_agent_validate_extraction", "browser_runtime_snapshot", "browser_cdp_observe", "browser_cdp_act", "browser_cdp_extract", "browser_cdp_wait"],
            inputs: ["url", "web_goal", "selector_cache"],
            outputs: ["web_action_result", "browser_session_snapshot", "selector_repair"],
            handoffs: ["verifier", "recipe_runner"]
        ),
        AgentRoleSpec(
            id: "recipe_runner",
            title: "Recipe Runner",
            mission: "Compile, adapt, and execute reusable workflow programs before falling back to manual app control.",
            tools: ["recipe_program_compile", "recipe_stabilize_program", "recipe_execute_adaptive", "recipe_generalize", "recipe_repair_hint"],
            inputs: ["recipe_id", "params", "task_context"],
            outputs: ["recipe_result", "repair_hint", "promoted_recipe"],
            handoffs: ["executor", "memory_curator"]
        ),
        AgentRoleSpec(
            id: "memory_curator",
            title: "Memory Curator",
            mission: "Create durable episodes, consolidate context graph facts, and build compact context packs for long tasks.",
            tools: ["memory_episode_consolidate", "memory_context_pack", "memory_semantic_recall", "memory_shadow_capture", "shadow_episode_policy", "context_graph_ingest"],
            inputs: ["run_events", "task_outcome", "user_feedback"],
            outputs: ["episode", "context_graph_edges", "memory_context_pack"],
            handoffs: ["planner", "recipe_runner"]
        ),
        AgentRoleSpec(
            id: "app_skill_specialist",
            title: "App Skill Specialist",
            mission: "Resolve, validate, and apply app-specific adapters, selectors, recipes, and compatibility metadata.",
            tools: ["app_skill_route", "app_skill_execute_adapter", "app_skill_core_pack", "app_skill_sdk", "app_skill_package_validate", "app_skill_package_list", "app_skill_export_manifest"],
            inputs: ["app", "goal", "target_version"],
            outputs: ["skill_route", "selector_plan", "recipe_candidates"],
            handoffs: ["executor", "recipe_runner"]
        ),
        AgentRoleSpec(
            id: "runtime_operator",
            title: "Runtime Operator",
            mission: "Keep long tasks alive with durable queues, graph ticks, pauses, feedback, and resume packets.",
            tools: ["resident_agent_plan", "resident_agent_tick", "resident_agent_status", "long_run_daemon_tick", "long_run_daemon_status", "task_graph_tick", "cockpit_command", "cockpit_live_state"],
            inputs: ["task_graph", "queue", "user_commands"],
            outputs: ["scheduled_runs", "pause_resume_state", "runtime_report"],
            handoffs: ["planner", "executor", "memory_curator"]
        ),
        AgentRoleSpec(
            id: "verifier",
            title: "Verifier",
            mission: "Verify effects against postconditions and decide whether to continue, repair, or complete.",
            tools: ["observe_wait", "visual_ground", "browser_cdp_wait", "recipe_program_compile", "recipe_stabilize_program", "trajectory_resume_points", "cockpit_replay_spec"],
            inputs: ["expected_effect", "tool_result", "postconditions"],
            outputs: ["verification_result", "next_action", "failure_branch"],
            handoffs: ["executor", "recipe_runner", "memory_curator"]
        )
    ]

    static var packetsURL: URL {
        EventStore.rootURL.appendingPathComponent("agent-role-handoffs.jsonl")
    }

    static func role(id: String) -> AgentRoleSpec? {
        roles.first { $0.id == id }
    }

    static func plan(goal: String, app: String = "", surface: String = "") -> [[String: String]] {
        let text = normalizeForSearch([goal, app, surface].joined(separator: " "))
        var route = ["planner"]
        if text.contains("browser") || text.contains("chrome") || text.contains("web") || text.contains("http") {
            route.append("browser_specialist")
        }
        if text.contains("recipe") || text.contains("repeat") || text.contains("again") || text.contains("复用") || text.contains("流程") {
            route.append("recipe_runner")
        }
        if text.contains("image") || text.contains("canvas") || text.contains("figma") || text.contains("screen") || text.contains("截图") {
            route.append("perception_grounder")
        }
        if !app.isEmpty {
            route.append("app_skill_specialist")
        }
        if text.contains("long") || text.contains("watch") || text.contains("wait") || text.contains("持续") || text.contains("长期") {
            route.append("runtime_operator")
        }
        route.append(contentsOf: ["executor", "verifier", "memory_curator"])
        return unique(route).compactMap { role(id: $0)?.dictionary }
    }

    @discardableResult
    static func recordHandoff(goal: String, fromRole: String, toRole: String, reason: String, context: [String: String] = [:]) throws -> AgentHandoffPacket {
        let target = role(id: toRole)
        let packet = AgentHandoffPacket(
            id: "handoff-\(UUID().uuidString)",
            goal: goal,
            fromRole: fromRole,
            toRole: toRole,
            reason: reason,
            context: context,
            tools: target?.tools ?? [],
            stopConditions: [
                "Return structured evidence for the role output.",
                "Escalate to verifier when the expected effect is observable.",
                "Escalate to runtime_operator when waiting or user feedback is needed."
            ],
            createdAt: isoDateString(Date())
        )
        try FileManager.default.createDirectory(at: packetsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = packet.dictionary.merging(["event": "AgentHandoff"]) { current, _ in current }
        let text = jsonStringValue(line) + "\n"
        if FileManager.default.fileExists(atPath: packetsURL.path) {
            let handle = try FileHandle(forWritingTo: packetsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try text.write(to: packetsURL, atomically: true, encoding: .utf8)
        }
        return packet
    }
}
