import Foundation

struct ComputerUseModelStack {
    static func strategy(goal: String, app: String = "", mode: String = "balanced") -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let config = LLMConfig.fromEnvironment()
        let text = normalizeForSearch([goal, app].joined(separator: " "))
        let long = text.contains("长期") || text.contains("长时间") || text.contains("持续") || text.contains("watch") || text.contains("wait")
        let visual = text.contains("canvas") || text.contains("figma") || text.contains("blender") || text.contains("image") || text.contains("图")
        let browser = text.contains("web") || text.contains("browser") || text.contains("chrome") || text.contains("safari") || text.contains("http")
        let recipe = text.contains("重复") || text.contains("复用") || text.contains("again") || text.contains("recipe")
        let roles: [[String: String]] = [
            [
                "role": "planner",
                "model": env["AIOS_PLANNER_MODEL"] ?? env["AIOS_LLM_MODEL"] ?? config.model,
                "trigger": "new goal, replan, hard failure",
                "budget": mode == "fast" ? "low" : "medium"
            ],
            [
                "role": "executor",
                "model": env["AIOS_EXECUTOR_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? env["AIOS_LLM_MODEL"] ?? config.model,
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
                "model": env["AIOS_VERIFIER_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? env["AIOS_LLM_MODEL"] ?? config.model,
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
            "provider_plan": jsonStringValue(providerPlan(goal: goal, app: app, mode: mode)),
            "long_task_policy": long ? "resident_agent + daemon tick + task graph + shadow capture + cockpit interrupt" : "checkpointed run with episode consolidation",
            "visual_policy": visual ? "visual_grounder_model_registry + calibration + VLM/local grounder before coordinates" : "AX/DOM first, visual fallback",
            "browser_policy": browser ? "browser_agent_contract + CDP observe/act/extract/wait + selector cache" : "use only when URL/browser app appears",
            "recipe_policy": "recipe_program_select first; after success use recipe_learn_once/recipe_stabilize_program so small runner can reuse it"
        ]
    }

    static func providerPlan(goal: String, app: String = "", mode: String = "balanced") -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let config = LLMConfig.fromEnvironment()
        let text = normalizeForSearch([goal, app].joined(separator: " "))
        let long = text.contains("长期") || text.contains("长时间") || text.contains("持续") || text.contains("watch") || text.contains("wait")
        let visual = text.contains("canvas") || text.contains("figma") || text.contains("blender") || text.contains("image") || text.contains("图")
        let browser = text.contains("web") || text.contains("browser") || text.contains("chrome") || text.contains("safari") || text.contains("http")
        let roleRoutes: [[String: String]] = [
            llmRole(
                id: "planner",
                env: env,
                config: config,
                modelKeys: ["AIOS_PLANNER_MODEL", "AIOS_LLM_MODEL"],
                defaultModel: config.model,
                trigger: long ? "goal decomposition, resident replan, hard failure" : "goal decomposition and hard failure",
                budget: mode == "fast" ? "low" : "medium",
                runner: "OpenAI-compatible chat-completions planner"
            ),
            llmRole(
                id: "executor",
                env: env,
                config: config,
                modelKeys: ["AIOS_EXECUTOR_MODEL", "AIOS_SMALL_MODEL", "AIOS_LLM_MODEL"],
                defaultModel: config.model,
                trigger: "bounded action translation when no deterministic adapter can execute directly",
                budget: mode == "deep" ? "medium" : "low",
                runner: "tool-call executor with policy and checkpoint feedback"
            ),
            [
                "role": "browser_specialist",
                "provider": env["AIOS_BROWSER_MODEL"] == nil && env["AIOS_SMALL_MODEL"] == nil ? "deterministic_cdp_first" : "small_llm_plus_cdp",
                "model": env["AIOS_BROWSER_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? "cdp-deterministic-runner",
                "model_source": firstModelSource(env: env, keys: ["AIOS_BROWSER_MODEL", "AIOS_SMALL_MODEL"]) ?? "built-in CDP runner",
                "base_url": (env["AIOS_BROWSER_MODEL"] ?? env["AIOS_SMALL_MODEL"]) == nil ? "" : config.baseURL.absoluteString,
                "trigger": browser ? "preferred for web/browser task" : "only when URL or browser app is detected",
                "budget": "low",
                "runner": "browser_agent_contract + CDP observe/act/extract/wait"
            ],
            [
                "role": "vision_grounder",
                "provider": visionProvider(env: env),
                "model": env["AIOS_LOCAL_GROUNDER_MODEL"] ?? env["AIOS_VISION_MODEL"] ?? "builtin-heuristics",
                "model_source": firstModelSource(env: env, keys: ["AIOS_LOCAL_GROUNDER_MODEL", "AIOS_VISION_MODEL"]) ?? "built-in visual heuristics",
                "base_url": env["AIOS_VISION_BASE_URL"] ?? "",
                "trigger": visual ? "required for canvas/image-heavy task" : "fallback after AX/DOM/native adapters",
                "budget": visual ? "medium" : "minimal",
                "runner": "visual_grounder_run + visual_grounder_verify with calibration/feedback cache"
            ],
            [
                "role": "recipe_runner",
                "provider": env["AIOS_RECIPE_MODEL"] == nil && env["AIOS_SMALL_MODEL"] == nil ? "deterministic_recipe_runtime" : "small_llm_for_parameter_fill",
                "model": env["AIOS_RECIPE_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? "deterministic-swift-runner",
                "model_source": firstModelSource(env: env, keys: ["AIOS_RECIPE_MODEL", "AIOS_SMALL_MODEL"]) ?? "built-in recipe runner",
                "base_url": (env["AIOS_RECIPE_MODEL"] ?? env["AIOS_SMALL_MODEL"]) == nil ? "" : config.baseURL.absoluteString,
                "trigger": "recipe_program_select match, learned workflow reuse, or repeated task",
                "budget": "minimal",
                "runner": "recipe_execute_adaptive with repair hints and verifier contracts"
            ],
            llmRole(
                id: "verifier",
                env: env,
                config: config,
                modelKeys: ["AIOS_VERIFIER_MODEL", "AIOS_SMALL_MODEL", "AIOS_LLM_MODEL"],
                defaultModel: config.model,
                trigger: "after every material app/file/browser effect",
                budget: "low",
                runner: "deterministic verifier first, LLM only for ambiguous evidence"
            ),
            [
                "role": "memory_curator",
                "provider": env["AIOS_MEMORY_MODEL"] == nil && env["AIOS_SMALL_MODEL"] == nil ? "deterministic_memory_indexer" : "small_llm_for_summarization",
                "model": env["AIOS_MEMORY_MODEL"] ?? env["AIOS_SMALL_MODEL"] ?? "deterministic-indexer",
                "model_source": firstModelSource(env: env, keys: ["AIOS_MEMORY_MODEL", "AIOS_SMALL_MODEL"]) ?? "built-in indexer",
                "base_url": (env["AIOS_MEMORY_MODEL"] ?? env["AIOS_SMALL_MODEL"]) == nil ? "" : config.baseURL.absoluteString,
                "trigger": long ? "every pause/tick/complete" : "run start/complete",
                "budget": "minimal",
                "runner": "episode consolidation + context graph + preference digest"
            ],
            [
                "role": "runtime_operator",
                "provider": "deterministic_resident_runtime",
                "model": "swift-daemon",
                "model_source": "built-in resident runtime",
                "base_url": "",
                "trigger": long ? "always on for durable task" : "when queue, delay, pause, or user feedback is present",
                "budget": "minimal",
                "runner": "TaskQueue + LongRunDaemonStore + ResidentAgentStore + cockpit commands"
            ]
        ]
        return [
            "schema": "aios.computer_use.provider_plan.v1",
            "goal": goal,
            "app": app,
            "mode": mode,
            "primary_provider": jsonStringValue(providerSummary(config.providers.first)),
            "fallback_provider_count": "\(config.fallbacks.count)",
            "fallback_providers": jsonStringValue(config.fallbacks.map { providerSummary($0) }),
            "role_routes": jsonStringValue(roleRoutes),
            "routing_policy": "planner chooses the cheapest deterministic runner that can observe and verify the effect; LLM providers are used for planning, ambiguous execution, and evidence interpretation; fallbacks are tried by LLMConfig providers order",
            "vision_policy": visual ? "route through local/VLM sidecar before coordinate fallback" : "avoid vision cost until native/AX/DOM/background adapters cannot resolve the target",
            "browser_policy": browser ? "CDP is the primary browser driver; browser model only repairs selectors or extracts ambiguous state" : "browser route stays dormant until a URL/browser surface appears",
            "recipe_policy": "learn_workflow_reuse_plan -> recipe_program_select -> recipe_execute_adaptive -> recipe_repair_hint/recipe_stabilize_program",
            "runtime_policy": long ? "resident runtime owns wakeups, queue ticks, cockpit interruption, replay bundle, and memory consolidation" : "checkpoint and summarize at run boundaries"
        ]
    }

    private static func llmRole(
        id: String,
        env: [String: String],
        config: LLMConfig,
        modelKeys: [String],
        defaultModel: String,
        trigger: String,
        budget: String,
        runner: String
    ) -> [String: String] {
        let model = modelKeys.compactMap { env[$0] }.first ?? defaultModel
        return [
            "role": id,
            "provider": "openai_compatible",
            "model": model,
            "model_source": firstModelSource(env: env, keys: modelKeys) ?? configModelSource(env: env),
            "base_url": config.baseURL.absoluteString,
            "fallbacks": "\(config.fallbacks.count)",
            "trigger": trigger,
            "budget": budget,
            "runner": runner
        ]
    }

    private static func providerSummary(_ provider: LLMProvider?) -> [String: String] {
        guard let provider else { return [:] }
        return [
            "label": provider.label,
            "base_url": provider.baseURL.absoluteString,
            "model": provider.model,
            "api_key": provider.apiKey?.isEmpty == false ? "configured" : "not_set"
        ]
    }

    private static func firstModelSource(env: [String: String], keys: [String]) -> String? {
        keys.first { key in
            guard let value = env[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func configModelSource(env: [String: String]) -> String {
        env["AIOS_LLM_MODEL"] == nil ? "AIOS config model" : "AIOS_LLM_MODEL"
    }

    private static func visionProvider(env: [String: String]) -> String {
        if env["AIOS_LOCAL_GROUNDER_MODEL"]?.isEmpty == false { return "local_grounder" }
        if VisionSidecar.isConfigured { return "vision_sidecar" }
        return "builtin_heuristic_grounder"
    }
}
