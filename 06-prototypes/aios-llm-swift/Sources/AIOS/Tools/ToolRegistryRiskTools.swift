import Foundation

extension ToolRegistry {
    func appSkillResolveActionTool(_ args: [String: Any]) throws -> ToolResult {
        let actionArgs = try parseJSONObject(string(args["arguments_json"]) ?? "{}")
        let plan = AppSkillRuntime.actionPlan(
            query: string(args["query"]) ?? "",
            appName: string(args["app_name"]) ?? "",
            bundleID: string(args["bundle_id"]) ?? "",
            action: string(args["action"]) ?? "observe",
            arguments: actionArgs
        )
        let resolved = !(plan["selected_tool"] ?? "").isEmpty || plan["can_execute_package_adapter"] == "true"
        return ToolResult(
            success: resolved,
            evidence: resolved ? "Resolved app skill action plan." : "No executable app skill action was resolved.",
            data: plan,
            error: resolved ? nil : "app_skill_action_not_resolved",
            suggestion: resolved ? nil : "Provide app_name/bundle_id plus action arguments such as path, url, recipient/chat, text, title, start/end, or command."
        )
    }

    func cockpitLiveSummaryTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(
            success: true,
            evidence: "Built live cockpit summary.",
            data: CockpitDashboardStore.liveSummary(runID: string(args["run_id"]), limit: int(args["limit"]) ?? 20)
        )
    }

    func computerUseProviderPlanTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(
            success: true,
            evidence: "Built computer-use provider routing plan.",
            data: ComputerUseModelStack.providerPlan(
                goal: string(args["goal"]) ?? "",
                app: string(args["app"]) ?? string(args["app_name"]) ?? "",
                mode: string(args["mode"]) ?? "balanced"
            )
        )
    }

    func learnWorkflowReusePlanTool(_ args: [String: Any]) throws -> ToolResult {
        guard let goal = string(args["goal"]), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("goal is required")
        }
        return ToolResult(
            success: true,
            evidence: "Built learned workflow reuse plan.",
            data: try LearnWorkflowStore.reusePlan(
                goal: goal,
                appName: string(args["app_name"]) ?? string(args["app"]) ?? "",
                verifierEffect: string(args["verifier_effect"]) ?? "",
                limit: int(args["limit"]) ?? 5
            )
        )
    }

    func sideEffectLedgerStatusTool(_ args: [String: Any]) -> ToolResult {
        let rows = SideEffectLedgerStore.records(
            runID: string(args["run_id"]),
            key: string(args["key"]),
            limit: int(args["limit"]) ?? 50
        )
        return ToolResult(success: true, evidence: "Loaded \(rows.count) side effect ledger record(s).", data: [
            "schema": "aios.side_effect_ledger.status.v1",
            "records": jsonStringValue(rows.map(\.dictionary)),
            "count": "\(rows.count)"
        ])
    }
}
