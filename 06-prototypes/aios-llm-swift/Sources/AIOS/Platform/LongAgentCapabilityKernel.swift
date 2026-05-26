import Foundation

struct LongAgentCapabilityKernel {
    static func matrix(goal: String = "") -> [String: String] {
        let rows: [[String: String]] = [
            row(
                id: "background-control",
                title: "CUA-grade background control kernel",
                primaryTools: ["background_native_kernel", "background_driver_dispatch", "background_action"],
                state: "semantic channels executable; native non-AX closed through adapter/external driver capsules",
                parityTarget: "CUA Driver"
            ),
            row(
                id: "visual-grounding",
                title: "Multimodal visual grounding with calibration",
                primaryTools: ["visual_grounder_run", "visual_grounder_model_registry", "visual_grounder_calibrate", "visual_grounder_feedback"],
                state: "local/VLM/builtin registry, UI map cache, calibration, and feedback rerank loop",
                parityTarget: "Ghost OS, Peekaboo"
            ),
            row(
                id: "recipe-programs",
                title: "Learn once, reuse as stable workflow program",
                primaryTools: ["recipe_learn_once", "recipe_program_compile", "recipe_stabilize_program", "recipe_execute_adaptive"],
                state: "parameter schema, invariants, version policy, repair hints, success counters",
                parityTarget: "Ghost OS"
            ),
            row(
                id: "resident-runtime",
                title: "Long-running resident agent runtime",
                primaryTools: ["resident_agent_plan", "resident_agent_tick", "long_run_daemon_tick", "task_graph_tick"],
                state: "durable resident sessions over daemon, task graph, role handoffs, cockpit interrupts",
                parityTarget: "Codex automations"
            ),
            row(
                id: "deep-memory",
                title: "Episode/context graph/Shadow memory",
                primaryTools: ["memory_shadow_capture", "shadow_episode_policy", "memory_context_pack", "memory_entity_graph"],
                state: "episode digest, entity graph, preference digest, context injection policy",
                parityTarget: "Codex Chronicle, Ghost Shadow"
            ),
            row(
                id: "app-skill-ecosystem",
                title: "Plugin-style app skill ecosystem",
                primaryTools: ["app_skill_sdk", "app_skill_core_pack", "app_skill_package_scaffold", "app_skill_route"],
                state: "SDK contract, package manifests, compatibility metadata, core app pack scaffold",
                parityTarget: "Codex skills/plugins"
            ),
            row(
                id: "browser-agent",
                title: "Stagehand-style browser automation",
                primaryTools: ["browser_agent_contract", "browser_agent_observe", "browser_agent_act", "browser_agent_extract", "browser_agent_wait"],
                state: "observe/act/extract/wait contract, selector cache, session policy, extraction validation",
                parityTarget: "Stagehand"
            ),
            row(
                id: "cockpit-replay",
                title: "Product cockpit and replayable sessions",
                primaryTools: ["cockpit_dashboard", "cockpit_replay_spec", "trajectory_bundle_manifest", "trajectory_branch_create"],
                state: "dashboard views, action/evidence lanes, replay bundle, resume/branch/clip controls",
                parityTarget: "Codex app, Peekaboo"
            ),
            row(
                id: "multi-agent-harness",
                title: "Codex-style multi-agent harness",
                primaryTools: ["agent_harness_plan", "agent_harness_dispatch", "agent_handoff_packet", "resident_agent_tick"],
                state: "role route, handoff packets, per-role budgets, resident role ticks",
                parityTarget: "Codex subagents"
            ),
            row(
                id: "model-stack",
                title: "Computer-use model/perception strategy",
                primaryTools: ["computer_use_model_stack", "computer_use_strategy", "visual_grounder_model_registry"],
                state: "planner/executor/grounder/recipe/verifier/memory model routing with deterministic fallback",
                parityTarget: "Ghost OS, Codex"
            )
        ]
        return [
            "schema": "aios.long_agent.capability_matrix.v1",
            "goal": goal,
            "target": "AI long-running, automatic macOS software driver",
            "items": jsonStringValue(rows),
            "complete_count": "\(rows.count)",
            "operating_principle": "prefer deterministic semantic backends, use models for planning/grounding/repair, persist every long-running decision as durable state"
        ]
    }

    private static func row(id: String, title: String, primaryTools: [String], state: String, parityTarget: String) -> [String: String] {
        [
            "id": id,
            "title": title,
            "primary_tools": primaryTools.joined(separator: ","),
            "state": state,
            "parity_target": parityTarget,
            "closure_status": "implemented_kernel"
        ]
    }
}
