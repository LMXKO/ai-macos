import Foundation

struct BackgroundExecutionKernel {
    static func dispatchPlan(args: [String: Any]) -> [String: String] {
        let target = BackgroundControlKernel.target(from: args)
        let action = BackgroundControlKernel.action(from: args)
        let plan = BackgroundControlKernel.plan(target: target, action: action)
        let semantic = plan.channels.filter { $0.nonInvasive && $0.id != "visual_grounding" && $0.id != "public_api_boundary" }
        let visual = plan.channels.first { $0.id == "visual_grounding" }
        let ladder = semantic.map(\.id) + [visual?.id].compactMap { $0 } + ["foreground_coordinate_opt_in"]
        return [
            "schema": "aios.background.dispatch.v1",
            "target": jsonStringValue(target.dictionary),
            "action": jsonStringValue(action.dictionary),
            "semantic_channels": jsonStringValue(semantic.map(\.dictionary)),
            "visual_grounding": visual.map { jsonStringValue($0.dictionary) } ?? "",
            "execution_ladder": ladder.joined(separator: " -> "),
            "guarantees": semantic.isEmpty ? "No universal no-focus/no-cursor guarantee for this target; require adapter or explicit foreground fallback." : "Use semantic channel only for no-focus/no-cursor/no-Space-change execution.",
            "can_dispatch_without_focus": semantic.isEmpty ? "false" : "true",
            "requires_adapter_for_universal_non_ax": "true",
            "adapter_boundary": "Non-AX inactive/offscreen surfaces need app-specific semantic adapters such as CDP, AppleScript/ScriptingBridge, Shortcuts, app plugin APIs, or an app skill package.",
            "contract": "Dispatch only through semantic backends for no-cursor/no-focus guarantees; visual coordinate execution is opt-in foreground."
        ]
    }
}
