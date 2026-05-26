import Foundation

struct BackgroundDriverBridge {
    static func matrix() -> [[String: String]] {
        [
            driver(
                id: "cua_driver",
                title: "CUA-compatible native background driver",
                binary: configuredDriverPath() ?? "AIOS_CUA_DRIVER_PATH not configured",
                surfaces: "chromium,canvas,figma,blender,native_non_ax",
                guarantees: "no_cursor,no_focus,no_space_when_driver_available",
                available: configuredDriverPath() != nil,
                notes: "External driver boundary for inactive/offscreen/non-AX native surfaces."
            ),
            driver(
                id: "browser_cdp",
                title: "Chrome DevTools Protocol",
                binary: "built-in CDP client",
                surfaces: "web,dom,chromium",
                guarantees: "no_cursor,no_focus,no_space_for_dom",
                available: true,
                notes: "Best current deep channel for web apps; canvas needs JS or visual fallback."
            ),
            driver(
                id: "semantic_app_adapter",
                title: "App skill semantic adapter",
                binary: "app-skills/packages/*",
                surfaces: "scriptable_native_apps",
                guarantees: "no_cursor,no_focus,no_space_when_adapter_supports_action",
                available: !AppSkillPackageStore.list().isEmpty || !AppSkillStore.list().isEmpty,
                notes: "Plugin-style adapter layer for AppleScript/ScriptingBridge/app-specific APIs."
            ),
            driver(
                id: "ax_semantic",
                title: "Accessibility semantic action",
                binary: "built-in AX client",
                surfaces: "ax_controls",
                guarantees: "no_cursor,no_focus,no_space_for_axpress_axvalue",
                available: true,
                notes: "Works only when target exposes actionable AX elements."
            )
        ]
    }

    static func dispatch(args: [String: Any]) throws -> [String: String] {
        let target = BackgroundControlKernel.target(from: args)
        let action = BackgroundControlKernel.action(from: args)
        let plan = BackgroundExecutionKernel.dispatchPlan(args: args)
        let selected = selectDriver(target: target, action: action)
        let request = requestEnvelope(driver: selected, target: target, action: action)
        let dryRun = bool(args["dry_run"]) ?? true
        let binary = selected["binary"] ?? ""
        let available = selected["available"] == "true"
        var data: [String: String] = [
            "schema": "aios.background.driver.dispatch.v1",
            "selected_driver": selected["id"] ?? "",
            "driver": jsonStringValue(selected),
            "dispatch_plan": jsonStringValue(plan),
            "request": jsonStringValue(request),
            "status": dryRun ? "planned" : "pending_execution",
            "dry_run": dryRun ? "true" : "false",
            "can_attempt_true_background": selected["guarantees"]?.contains("no_cursor") == true ? "true" : "false"
        ]
        if ["browser_cdp", "semantic_app_adapter", "ax_semantic"].contains(selected["id"] ?? "") {
            data["execution_mode"] = "builtin_tool_runtime"
            return data
        }
        guard !dryRun, available, FileManager.default.fileExists(atPath: binary) else {
            if !available {
                data["reason"] = "Selected driver is not available locally; returning portable driver request envelope."
            } else if !FileManager.default.fileExists(atPath: binary) {
                data["reason"] = "Selected external driver binary is not present."
            }
            return data
        }
        let result = try runDriver(binary: binary, request: request)
        data["driver_stdout"] = truncateMiddle(result.stdout, maxCharacters: 4_000)
        data["driver_stderr"] = truncateMiddle(result.stderr, maxCharacters: 2_000)
        data["exit_code"] = "\(result.exitCode)"
        data["status"] = result.exitCode == 0 ? "executed" : "failed"
        return data
    }

    private static func selectDriver(target: BackgroundControlTarget, action: BackgroundControlAction) -> [String: String] {
        let text = target.normalizedText
        if configuredDriverPath() != nil,
           text.contains("figma") || text.contains("blender") || text.contains("canvas") || text.contains("non_ax") || target.surface.contains("canvas") {
            return matrix().first { $0["id"] == "cua_driver" } ?? matrix()[0]
        }
        if text.contains("chrome") || text.contains("browser") || text.contains("web") || text.contains("http") || !action.selector.isEmpty {
            return matrix().first { $0["id"] == "browser_cdp" } ?? matrix()[0]
        }
        if !AppSkillRuntime.route(query: [target.appName, target.bundleID, action.query].joined(separator: " ")).tools.isEmpty {
            return matrix().first { $0["id"] == "semantic_app_adapter" } ?? matrix()[0]
        }
        return matrix().first { $0["id"] == "ax_semantic" } ?? matrix()[0]
    }

    private static func requestEnvelope(driver: [String: String], target: BackgroundControlTarget, action: BackgroundControlAction) -> [String: Any] {
        [
            "schema": "aios.background.driver.request.v1",
            "driver": driver["id"] ?? "",
            "target": target.dictionary,
            "action": action.dictionary.merging([
                "text": action.text,
                "query": action.query,
                "selector": action.selector,
                "script": action.script
            ]) { current, _ in current },
            "requirements": [
                "must_not_move_cursor": true,
                "must_not_steal_focus": true,
                "must_not_change_space": true,
                "must_return_observable_evidence": true
            ]
        ]
    }

    private static func driver(id: String, title: String, binary: String, surfaces: String, guarantees: String, available: Bool, notes: String) -> [String: String] {
        [
            "id": id,
            "title": title,
            "binary": binary,
            "surfaces": surfaces,
            "guarantees": guarantees,
            "available": available ? "true" : "false",
            "notes": notes
        ]
    }

    private static func configuredDriverPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["AIOS_CUA_DRIVER_PATH"],
            env["AIOS_BACKGROUND_DRIVER_PATH"]
        ].compactMap { $0?.expandingTildeInPath }.filter { !$0.isEmpty }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func runDriver(binary: String, request: [String: Any]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--json"]
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }
}
