import Foundation

struct NativeBackgroundDriverKernel {
    static func profile(args: [String: Any]) -> [String: String] {
        let target = BackgroundControlKernel.target(from: args)
        let action = BackgroundControlKernel.action(from: args)
        let plan = BackgroundControlKernel.plan(target: target, action: action)
        let driverMatrix = BackgroundDriverBridge.matrix()
        let route = AppSkillRuntime.route(
            query: [action.query, target.appName, target.surface].joined(separator: " "),
            appName: target.appName,
            bundleID: target.bundleID
        )
        let externalCUA = driverMatrix.first { $0["id"] == "cua_driver" }
        let nativeSurface = target.surface == "canvas" ||
            normalizeForSearch([target.appName, target.bundleID, action.query].joined(separator: " ")).contains("figma") ||
            normalizeForSearch([target.appName, target.bundleID, action.query].joined(separator: " ")).contains("blender")

        return [
            "schema": "aios.background.native_kernel.v1",
            "target": jsonStringValue(target.dictionary),
            "action": jsonStringValue(action.dictionary),
            "native_surface": nativeSurface ? "true" : "false",
            "driver_matrix": jsonStringValue(driverMatrix),
            "selected_background_plan": jsonStringValue(plan.dictionary),
            "app_skill_route": jsonStringValue(route.dictionary),
            "external_cua_driver_available": externalCUA?["available"] ?? "false",
            "kernel_contract": "observe/verify/type/click must prefer no-cursor/no-focus/no-Space channels: CDP, app skill adapter, app scripting, AX semantic action, then vision-assisted plan; coordinate foreground is explicit opt-in.",
            "inactive_window_policy": "Only semantic backends may execute in inactive windows. Native non-AX pixels must bind to a per-app adapter or external CUA-compatible driver.",
            "offscreen_policy": "DOM, scripting, recipes, and state checks may run offscreen. Pixel grounding may observe captured windows/images; pixel actions require adapter support.",
            "adapter_protocol": jsonStringValue(adapterProtocol()),
            "recommended_driver": recommendedDriver(target: target, action: action, route: route, driverMatrix: driverMatrix),
            "remaining_public_api_boundary": "No public macOS API provides universal inactive/offscreen clicks into arbitrary non-AX pixels; AIOS closes this through adapter packages and external native driver capsules instead of pretending raw pixels are safe."
        ]
    }

    static func probe(args: [String: Any]) -> [String: String] {
        let profile = profile(args: args)
        let target = BackgroundControlKernel.target(from: args)
        let action = BackgroundControlKernel.action(from: args)
        let stages: [[String: String]] = [
            [
                "stage": "1",
                "name": "cdp_or_browser_extension",
                "tool": "browser_agent_plan/browser_cdp_observe",
                "can_execute_background": target.surface == "web" || !target.url.isEmpty ? "true" : "conditional",
                "evidence": "DOM/action map, selector cache, post-action observation"
            ],
            [
                "stage": "2",
                "name": "app_skill_adapter",
                "tool": "app_skill_route/background_driver_dispatch",
                "can_execute_background": profile["app_skill_route"]?.contains(#""tools":"""#) == true ? "true" : "conditional",
                "evidence": "adapter manifest, selector map, recipe binding, tool result"
            ],
            [
                "stage": "3",
                "name": "ax_semantic",
                "tool": "aios_background_click/aios_background_type/aios_read",
                "can_execute_background": "partial",
                "evidence": "AX element id, role, value/action support"
            ],
            [
                "stage": "4",
                "name": "vision_grounded_native_adapter",
                "tool": "visual_grounder_run + background_native_driver_capsule",
                "can_execute_background": "requires_adapter",
                "evidence": "candidate id, bounds, confidence, adapter execution receipt"
            ],
            [
                "stage": "5",
                "name": "foreground_coordinate_opt_in",
                "tool": "visual_ground_action/ui_click",
                "can_execute_background": action.allowForeground ? "false_but_allowed" : "blocked",
                "evidence": "screenshot before/after and verification result"
            ]
        ]
        var result = profile
        result["schema"] = "aios.background.native_probe.v1"
        result["probe_stages"] = jsonStringValue(stages)
        result["probe_summary"] = stages.map { "\($0["stage"] ?? "?"):\($0["name"] ?? "")=\($0["can_execute_background"] ?? "")" }.joined(separator: " -> ")
        return result
    }

    private static func recommendedDriver(
        target: BackgroundControlTarget,
        action: BackgroundControlAction,
        route: AppSkillRoute,
        driverMatrix: [[String: String]]
    ) -> String {
        let text = normalizeForSearch([target.appName, target.bundleID, target.url, target.surface, action.query, action.selector].joined(separator: " "))
        if text.contains("chrome") || text.contains("browser") || text.contains("web") || text.contains("http") || !action.selector.isEmpty {
            return "browser_cdp"
        }
        if !route.tools.isEmpty {
            return "semantic_app_adapter:\(route.selectedSkill?.id ?? route.package?.id ?? "matched")"
        }
        if (driverMatrix.first { $0["id"] == "cua_driver" }?["available"] ?? "false") == "true",
           text.contains("canvas") || text.contains("figma") || text.contains("blender") {
            return "cua_driver"
        }
        if text.contains("canvas") || text.contains("figma") || text.contains("blender") {
            return "visual_grounding_requires_adapter"
        }
        return "ax_semantic"
    }

    private static func adapterProtocol() -> [[String: String]] {
        [
            [
                "field": "manifest",
                "description": "app id, bundle id, version compatibility, surfaces, action types, required driver channel"
            ],
            [
                "field": "observe",
                "description": "return current semantic/visual state without stealing focus"
            ],
            [
                "field": "ground",
                "description": "map visual candidate or semantic selector to adapter-native target"
            ],
            [
                "field": "act",
                "description": "execute click/type/drag/verify through app-native, CDP, scripting, or driver API"
            ],
            [
                "field": "verify",
                "description": "return postcondition evidence: DOM/AX/app state/screenshot anchor"
            ]
        ]
    }
}
