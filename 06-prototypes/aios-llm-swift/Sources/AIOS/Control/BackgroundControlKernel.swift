import Foundation

struct BackgroundControlTarget {
    let appName: String
    let bundleID: String
    let url: String
    let surface: String

    var normalizedText: String {
        normalizeForSearch([appName, bundleID, url, surface].joined(separator: " "))
    }

    var dictionary: [String: String] {
        [
            "app_name": appName,
            "bundle_id": bundleID,
            "url": url,
            "surface": surface
        ]
    }
}

struct BackgroundControlAction {
    let action: String
    let query: String
    let selector: String
    let text: String
    let script: String
    let allowForeground: Bool

    var dictionary: [String: String] {
        [
            "action": action,
            "query": query,
            "selector": selector,
            "text_chars": "\(text.count)",
            "has_script": script.isEmpty ? "false" : "true",
            "allow_foreground": allowForeground ? "true" : "false"
        ]
    }
}

struct BackgroundControlChannel {
    let id: String
    let title: String
    let depth: String
    let rank: Int
    let available: String
    let confidence: Double
    let nonInvasive: Bool
    let cursorSafe: Bool
    let focusSafe: Bool
    let spaceSafe: Bool
    let inactiveWindow: String
    let offscreen: String
    let nonAXSurface: String
    let actionTypes: [String]
    let tools: [String]
    let requirements: [String]
    let limitations: [String]
    let reason: String

    var dictionary: [String: String] {
        [
            "channel": id,
            "title": title,
            "depth": depth,
            "rank": "\(rank)",
            "available": available,
            "confidence": String(format: "%.2f", confidence),
            "non_invasive": nonInvasive ? "true" : "false",
            "cursor_safe": cursorSafe ? "true" : "false",
            "focus_safe": focusSafe ? "true" : "false",
            "space_safe": spaceSafe ? "true" : "false",
            "inactive_window": inactiveWindow,
            "offscreen": offscreen,
            "non_ax_surface": nonAXSurface,
            "action_types": actionTypes.joined(separator: ","),
            "tools": tools.joined(separator: ","),
            "requirements": requirements.joined(separator: " | "),
            "limitations": limitations.joined(separator: " | "),
            "reason": reason
        ]
    }
}

struct BackgroundControlPlan {
    let target: BackgroundControlTarget
    let action: BackgroundControlAction
    let channels: [BackgroundControlChannel]
    let boundary: String

    var dictionary: [String: String] {
        [
            "target": jsonStringValue(target.dictionary),
            "action": jsonStringValue(action.dictionary),
            "channels": jsonStringValue(channels.map(\.dictionary)),
            "boundary": boundary,
            "best_channel": channels.first?.id ?? ""
        ]
    }
}

struct BackgroundControlKernel {
    static func target(from args: [String: Any]) -> BackgroundControlTarget {
        let surface = string(args["surface"]) ?? inferredSurface(args)
        return BackgroundControlTarget(
            appName: string(args["app_name"]) ?? "",
            bundleID: string(args["bundle_id"]) ?? "",
            url: string(args["url"]) ?? "",
            surface: surface
        )
    }

    static func action(from args: [String: Any]) -> BackgroundControlAction {
        BackgroundControlAction(
            action: normalizeForSearch(string(args["action"]) ?? ""),
            query: string(args["query"]) ?? "",
            selector: string(args["selector"]) ?? "",
            text: string(args["text"]) ?? "",
            script: string(args["script"]) ?? "",
            allowForeground: bool(args["allow_foreground"]) ?? false
        )
    }

    static func plan(target: BackgroundControlTarget, action: BackgroundControlAction) -> BackgroundControlPlan {
        let text = target.normalizedText
        let actionName = action.action.isEmpty ? "click" : action.action
        let isWeb = text.contains("chrome") || text.contains("safari") || text.contains("browser") || text.contains("http") || text.contains("web") || target.surface == "web"
        let isCanvasLike = text.contains("figma") || text.contains("canvas") || text.contains("blender") || target.surface == "canvas" || target.surface == "design"
        let hasNativeTarget = !target.appName.isEmpty || !target.bundleID.isEmpty
        var channels: [BackgroundControlChannel] = []

        channels.append(BackgroundControlChannel(
            id: "browser_cdp_dom",
            title: "Browser DOM/CDP driver",
            depth: "deep_background",
            rank: 10,
            available: isWeb || !action.selector.isEmpty || !action.query.isEmpty && text.contains("chrome") ? "probe" : "conditional",
            confidence: (isWeb || !action.selector.isEmpty) ? 0.86 : 0.42,
            nonInvasive: true,
            cursorSafe: true,
            focusSafe: true,
            spaceSafe: true,
            inactiveWindow: "yes_for_browser_tab",
            offscreen: "yes_for_dom_no_for_pixels",
            nonAXSurface: isCanvasLike ? "partial_canvas_requires_js_or_visual" : "yes_for_dom",
            actionTypes: ["click", "type", "read", "verify", "eval", "wait", "extract"],
            tools: ["browser_cdp_act", "browser_cdp_click", "browser_cdp_type", "browser_cdp_read", "browser_cdp_eval", "browser_cdp_wait"],
            requirements: ["Chrome remote debugging endpoint for CDP", "Selector, query, or JavaScript"],
            limitations: ["Does not control arbitrary native apps", "Canvas pixels need app-specific JS or visual grounding"],
            reason: "Best match for web apps because it avoids cursor, focus, and Space changes."
        ))

        channels.append(BackgroundControlChannel(
            id: "app_script_or_scripting_bridge",
            title: "Native app scripting driver",
            depth: "semantic_background",
            rank: 20,
            available: hasNativeTarget ? "probe" : "conditional",
            confidence: hasNativeTarget ? 0.68 : 0.34,
            nonInvasive: true,
            cursorSafe: true,
            focusSafe: true,
            spaceSafe: true,
            inactiveWindow: "yes_when_app_exposes_scripting",
            offscreen: "yes_when_semantic_command",
            nonAXSurface: "yes_when_scriptable",
            actionTypes: ["script", "read", "verify", "open", "export", "create"],
            tools: ["background_appscript", "sdef_lookup", "scripting_bridge_probe", "app_skill_*"],
            requirements: ["App exposes AppleScript/SDEF/ScriptingBridge or an app skill"],
            limitations: ["Many apps expose little or no scripting surface"],
            reason: "Deepest native channel when the app exposes semantic commands."
        ))

        channels.append(BackgroundControlChannel(
            id: "accessibility_semantic",
            title: "Accessibility semantic driver",
            depth: "non_intrusive_ax",
            rank: 30,
            available: hasNativeTarget || !action.query.isEmpty ? "probe" : "conditional",
            confidence: hasNativeTarget ? 0.62 : 0.46,
            nonInvasive: true,
            cursorSafe: true,
            focusSafe: true,
            spaceSafe: true,
            inactiveWindow: "partial_depends_on_ax_element",
            offscreen: "partial_ax_tree_only",
            nonAXSurface: "no",
            actionTypes: ["click", "type", "read", "verify"],
            tools: ["aios_background_click", "aios_background_type", "aios_find", "aios_read"],
            requirements: ["Target exposes AXPress/AXValue/AX tree"],
            limitations: ["Cannot operate non-AX canvas/game/design surfaces by itself"],
            reason: "Useful for inactive-window semantic controls without moving cursor."
        ))

        channels.append(BackgroundControlChannel(
            id: "visual_grounding",
            title: "Visual perception and action planner",
            depth: "perception_fallback",
            rank: 40,
            available: "yes",
            confidence: isCanvasLike ? 0.72 : 0.58,
            nonInvasive: true,
            cursorSafe: true,
            focusSafe: true,
            spaceSafe: true,
            inactiveWindow: "observe_yes_action_no_without_semantic_channel",
            offscreen: "capture_dependent",
            nonAXSurface: "yes_for_grounding_not_background_action",
            actionTypes: ["observe", "verify", "click", "type"],
            tools: ["visual_candidates", "visual_ground", "visual_ground_action", "visual_analyze"],
            requirements: ["Screenshot/window/image capture", "Optional AIOS_VISION_* sidecar for icons/canvas"],
            limitations: ["Coordinate execution is foreground unless paired with a semantic backend"],
            reason: "Grounds icons, colors, canvas, image buttons, and complex layouts when AX/DOM are weak."
        ))

        channels.append(BackgroundControlChannel(
            id: "foreground_coordinate",
            title: "Foreground coordinate executor",
            depth: "last_resort",
            rank: 90,
            available: action.allowForeground ? "opt_in" : "blocked",
            confidence: action.allowForeground ? 0.70 : 0.0,
            nonInvasive: false,
            cursorSafe: false,
            focusSafe: false,
            spaceSafe: false,
            inactiveWindow: "no",
            offscreen: "no",
            nonAXSurface: "yes_visible_only",
            actionTypes: ["click", "type", "drag", "hover"],
            tools: ["ui_click", "ui_drag", "ui_keyboard_shortcut", "visual_click", "visual_ground_action"],
            requirements: ["allow_foreground=true", "Visible coordinate target"],
            limitations: ["May move cursor/focus and disturb the active Space"],
            reason: "Broad but intentionally last because it is intrusive."
        ))

        channels.append(BackgroundControlChannel(
            id: "public_api_boundary",
            title: "macOS public API boundary",
            depth: "boundary",
            rank: 100,
            available: "informational",
            confidence: 1.0,
            nonInvasive: true,
            cursorSafe: true,
            focusSafe: true,
            spaceSafe: true,
            inactiveWindow: "not_guaranteed_for_arbitrary_non_ax_native_surface",
            offscreen: "not_guaranteed_for_arbitrary_non_ax_native_surface",
            nonAXSurface: "requires_app_specific_backend_or_foreground_coordinate",
            actionTypes: ["explain"],
            tools: [],
            requirements: ["App-specific API, browser CDP/extension, plugin adapter, or foreground opt-in"],
            limitations: ["Public macOS APIs do not provide universal background clicks into every inactive/offscreen non-AX native surface"],
            reason: "Models the hard boundary instead of pretending universal background native input exists."
        ))

        let supported = channels.filter { channel in
            channel.actionTypes.contains(actionName) || channel.id == "public_api_boundary" || actionName.isEmpty
        }
        let sorted = supported.sorted {
            if $0.rank == $1.rank { return $0.confidence > $1.confidence }
            return $0.rank < $1.rank
        }
        return BackgroundControlPlan(
            target: target,
            action: action,
            channels: sorted,
            boundary: "CUA-grade non-invasive control is guaranteed for semantic backends (CDP, scripting, AX when exposed). Arbitrary inactive/offscreen non-AX native pixels still require an app-specific adapter, browser/extension backend, vision-assisted planning plus foreground opt-in, or a private backend outside public macOS APIs."
        )
    }

    static func capabilityMatrix() -> [[String: String]] {
        let plan = plan(
            target: BackgroundControlTarget(appName: "", bundleID: "", url: "https://example.com", surface: "web"),
            action: BackgroundControlAction(action: "click", query: "", selector: "", text: "", script: "", allowForeground: false)
        )
        return plan.channels.map(\.dictionary)
    }

    private static func inferredSurface(_ args: [String: Any]) -> String {
        let text = normalizeForSearch([
            string(args["app_name"]),
            string(args["bundle_id"]),
            string(args["url"]),
            string(args["goal"]),
            string(args["query"])
        ].compactMap { $0 }.joined(separator: " "))
        if text.contains("figma") || text.contains("canvas") || text.contains("blender") { return "canvas" }
        if text.contains("http") || text.contains("chrome") || text.contains("safari") || text.contains("browser") { return "web" }
        if text.isEmpty { return "unknown" }
        return "native"
    }
}
