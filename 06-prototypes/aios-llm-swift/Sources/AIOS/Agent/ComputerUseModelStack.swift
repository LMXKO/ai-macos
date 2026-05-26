import Foundation

struct ComputerUseModelStack {
    static func strategy(goal: String, app: String = "", mode: String = "balanced") -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let text = normalizeForSearch([goal, app].joined(separator: " "))
        let long = text.contains("长期") || text.contains("长时间") || text.contains("持续") || text.contains("watch") || text.contains("wait")
        let visual = text.contains("canvas") || text.contains("figma") || text.contains("blender") || text.contains("image") || text.contains("图")
        let browser = text.contains("web") || text.contains("browser") || text.contains("chrome") || text.contains("safari") || text.contains("http")
        let recipe = text.contains("重复") || text.contains("复用") || text.contains("again") || text.contains("recipe")
        let roles: [[String: String]] = [
            [
                "role": "planner",
                "model": env["AIOS_PLANNER_MODEL"] ?? env["AIOS_LLM_MODEL"] ?? "primary-llm",
                "trigger": "new goal, replan, hard failure",
                "budget": mode == "fast" ? "low" : "medium"
            ],
            [
                "role": "executor",
                "model": env["AIOS_EXECUTOR_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? env["AIOS_LLM_MODEL"] ?? "primary-or-small-llm",
                "trigger": "bounded step execution",
                "budget": mode == "deep" ? "medium" : "low"
            ],
            [
                "role": "vision_grounder",
                "model": env["AIOS_LOCAL_GROUNDER_MODEL"] ?? env["AIOS_VISION_MODEL"] ?? "builtin-heuristics",
                "trigger": visual ? "required" : "fallback",
                "budget": visual ? "medium" : "minimal"
            ],
            [
                "role": "recipe_runner",
                "model": env["AIOS_RECIPE_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? "deterministic-swift-runner",
                "trigger": recipe ? "preferred" : "when recipe_program_select matches",
                "budget": "minimal"
            ],
            [
                "role": "browser_specialist",
                "model": env["AIOS_BROWSER_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? "cdp-deterministic-runner",
                "trigger": browser ? "preferred" : "when URL/web app detected",
                "budget": "low"
            ],
            [
                "role": "verifier",
                "model": env["AIOS_VERIFIER_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? env["AIOS_LLM_MODEL"] ?? "primary-or-small-llm",
                "trigger": "after every material action",
                "budget": "low"
            ],
            [
                "role": "memory_curator",
                "model": env["AIOS_MEMORY_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? "deterministic-indexer",
                "trigger": long ? "every pause/tick/complete" : "run start/complete",
                "budget": "minimal"
            ]
        ]
        return [
            "schema": "aios.computer_use.model_stack.v1",
            "goal": goal,
            "app": app,
            "mode": mode,
            "roles": jsonStringValue(roles),
            "routing": jsonStringValue(ComputerUseStrategy.suggest(goal: goal, app: app)),
            "long_task_policy": long ? "resident_agent + daemon tick + task graph + shadow capture + cockpit interrupt" : "checkpointed run with episode consolidation",
            "visual_policy": visual ? "visual_grounder_model_registry + calibration + VLM/local grounder before coordinates" : "AX/DOM first, visual fallback",
            "browser_policy": browser ? "browser_agent_contract + CDP observe/act/extract/wait + selector cache" : "use only when URL/browser app appears",
            "recipe_policy": "recipe_program_select first; after success use recipe_learn_once/recipe_stabilize_program so small runner can reuse it"
        ]
    }
}
