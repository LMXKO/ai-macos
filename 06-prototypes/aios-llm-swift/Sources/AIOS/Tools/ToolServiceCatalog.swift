import Foundation

struct ToolServiceCatalog {
    struct Service {
        let id: String
        let title: String
        let module: String
        let prefixes: [String]
        let tools: [String]
        let executionBoundary: String

        var dictionary: [String: String] {
            [
                "id": id,
                "title": title,
                "module": module,
                "prefixes": prefixes.joined(separator: ","),
                "tools": tools.joined(separator: ","),
                "tool_count": "\(tools.count)",
                "execution_boundary": executionBoundary
            ]
        }
    }

    static func catalog(toolDefinitions: [[String: Any]]) -> [String: String] {
        let names = toolDefinitions.compactMap { definition in
            (definition["function"] as? [String: Any])?["name"] as? String
        }.sorted()
        let services = serviceSpecs(names: names)
        let unassigned = names.filter { name in
            !services.contains { service in service.tools.contains(name) }
        }
        return [
            "schema": "aios.tool.service_catalog.v1",
            "services": jsonStringValue(services.map(\.dictionary)),
            "unassigned_tools": jsonStringValue(unassigned),
            "router_contract": "model-visible schemas stay in ToolRegistry; service catalog owns grouping, routing hints, and future executor split boundaries",
            "service_count": "\(services.count)",
            "tool_count": "\(names.count)"
        ]
    }

    static func serviceFor(toolName: String) -> [String: String] {
        let match = serviceSpecs(names: [toolName]).first { !$0.tools.isEmpty }
        return match?.dictionary ?? [
            "id": "macos",
            "title": "macOS Universal Tools",
            "module": "Tools/ToolRegistry.swift",
            "prefixes": "",
            "tools": toolName,
            "tool_count": "1",
            "execution_boundary": "legacy ToolRegistry executor"
        ]
    }

    private static func serviceSpecs(names: [String]) -> [Service] {
        [
            service(
                id: "background-control",
                title: "Background Driver Runtime",
                module: "Control",
                prefixes: ["background_", "aios_background_"],
                names: names,
                executionBoundary: "BackgroundDriverBridge + BackgroundDriverCapsuleStore"
            ),
            service(
                id: "vision-grounding",
                title: "Visual Perception And Grounding",
                module: "Vision",
                prefixes: ["visual_", "ocr_", "screen_capture_"],
                names: names,
                executionBoundary: "VisualGrounderRuntime + VisualPerceptionEngine"
            ),
            service(
                id: "browser-agent",
                title: "Browser CDP And Agent Runtime",
                module: "Browser",
                prefixes: ["browser_", "chrome_", "safari_"],
                names: names,
                executionBoundary: "BrowserRuntimeStore + BrowserAgentRuntime + CDP tools"
            ),
            service(
                id: "resident-runtime",
                title: "Long-Running Resident Runtime",
                module: "Runtime",
                prefixes: ["resident_", "long_", "runtime_", "task_graph_", "routine_"],
                names: names,
                executionBoundary: "ResidentAgentStore + LongRunDaemonStore + TaskGraphStore + RoutineStore"
            ),
            service(
                id: "cockpit",
                title: "Cockpit, Session, Replay",
                module: "Platform/Trajectory",
                prefixes: ["cockpit_", "session_", "trajectory_"],
                names: names,
                executionBoundary: "CockpitDashboardStore + SessionProtocolStore + Trajectory stores"
            ),
            service(
                id: "app-skills",
                title: "App Skill Ecosystem",
                module: "Skills",
                prefixes: ["app_skill", "app_verifier"],
                names: names,
                executionBoundary: "AppSkillRuntime + AppSkillPackageStore + AppVerifierStore"
            ),
            service(
                id: "native-app-adapters",
                title: "Native App Adapters",
                module: "Tools/Skills",
                prefixes: ["finder_", "mail_", "calendar_", "wechat_", "lark_", "qq_", "wps_", "notes_", "reminders_", "preview_", "libreoffice_", "xcode_", "pycharm_", "rustrover_", "baidunetdisk_", "tencent_meeting_", "todesk_", "shortcuts_", "docker_"],
                names: names,
                executionBoundary: "ToolRegistry app adapters today; target split is AppAdapterService"
            ),
            service(
                id: "recipes-learning",
                title: "Recipes And Learning",
                module: "Recipes/Learning",
                prefixes: ["recipe_", "learn_"],
                names: names,
                executionBoundary: "RecipeStore + RecipeLearningEngine"
            ),
            service(
                id: "memory",
                title: "Memory And Context Graph",
                module: "Memory",
                prefixes: ["memory_", "episode_", "context_graph_", "shadow_"],
                names: names,
                executionBoundary: "MemoryIndexStore + EpisodeStore + ContextGraphStore"
            )
        ]
    }

    private static func service(
        id: String,
        title: String,
        module: String,
        prefixes: [String],
        names: [String],
        executionBoundary: String
    ) -> Service {
        let tools = names.filter { name in prefixes.contains { name.hasPrefix($0) } }
        return Service(id: id, title: title, module: module, prefixes: prefixes, tools: tools, executionBoundary: executionBoundary)
    }
}
