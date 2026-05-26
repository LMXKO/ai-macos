import Foundation

struct AgentHarnessStore {
    static var plansURL: URL {
        EventStore.rootURL.appendingPathComponent("agent-harness-plans.jsonl")
    }

    static func plan(goal: String, app: String = "", surface: String = "") throws -> [String: String] {
        let route = AgentRoleSystem.plan(goal: goal, app: app, surface: surface)
        let memory = MemoryIndexStore.contextPack(query: goal, limit: 8)
        let recipes = RecipeLearningEngine.select(goal: goal, limit: 5)
        let skills = AppSkillRuntime.route(query: goal, appName: app, bundleID: "")
        let browser = BrowserAgentRuntime.agentPlan(goal: goal, url: "")
        let visual = VisualGrounderRuntime.sessionPlan(args: ["surface": surface, "query": goal])
        let background = try BackgroundDriverBridge.dispatch(args: ["app_name": app, "surface": surface, "query": goal, "action": "observe", "dry_run": true])
        let modelStack = ComputerUseModelStack.strategy(goal: goal, app: app)
        let nativeKernel = NativeBackgroundDriverKernel.profile(args: ["app_name": app, "surface": surface, "query": goal, "action": "observe"])
        let payload: [String: String] = [
            "schema": "aios.agent.harness.plan.v1",
            "id": "harness-\(UUID().uuidString)",
            "goal": goal,
            "app": app,
            "surface": surface,
            "route": jsonStringValue(route),
            "memory_context": jsonStringValue(memory),
            "recipe_candidates": jsonStringValue(recipes),
            "skill_route": jsonStringValue(skills.dictionary),
            "browser_plan": jsonStringValue(browser),
            "visual_plan": jsonStringValue(visual),
            "background_plan": jsonStringValue(background),
            "native_kernel": jsonStringValue(nativeKernel),
            "model_stack": jsonStringValue(modelStack),
            "budgets": "planner=1,executor_per_step=3,verifier=1,memory_curator=1,runtime_operator=daemon_tick",
            "handoff_contract": "each role receives goal, context, tools, stop_conditions, evidence_required; verifier decides continue/repair/complete; resident_agent_tick can advance roles across long waits",
            "created_at": isoDateString(Date())
        ]
        try append(payload)
        return payload
    }

    static func tick(goal: String, currentRole: String = "planner", evidence: String = "") throws -> [String: String] {
        let route = AgentRoleSystem.plan(goal: goal)
        let roleIDs = route.compactMap { $0["id"] }
        let currentIndex = roleIDs.firstIndex(of: currentRole) ?? 0
        let nextRole = roleIDs.indices.contains(currentIndex + 1) ? roleIDs[currentIndex + 1] : "verifier"
        let packet = try AgentRoleSystem.recordHandoff(
            goal: goal,
            fromRole: currentRole,
            toRole: nextRole,
            reason: evidence.isEmpty ? "advance harness role" : evidence,
            context: ["evidence": evidence]
        )
        return [
            "schema": "aios.agent.harness.tick.v1",
            "goal": goal,
            "current_role": currentRole,
            "next_role": nextRole,
            "handoff": jsonStringValue(packet.dictionary),
            "route": jsonStringValue(route)
        ]
    }

    private static func append(_ payload: [String: String]) throws {
        try FileManager.default.createDirectory(at: plansURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = jsonStringValue(payload) + "\n"
        if FileManager.default.fileExists(atPath: plansURL.path) {
            let handle = try FileHandle(forWritingTo: plansURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: plansURL, atomically: true, encoding: .utf8)
        }
    }
}
