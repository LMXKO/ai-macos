import Foundation

struct AppSkillRoute {
    let query: String
    let selectedSkill: AppSkill?
    let package: AppSkillPackage?
    let tools: [String]
    let selectors: [String: String]
    let recipes: [String]
    let compatibility: [String: String]
    let entrypoints: [String: String]

    var dictionary: [String: String] {
        [
            "query": query,
            "selected_skill": selectedSkill?.id ?? "",
            "package": package?.id ?? "",
            "app_name": selectedSkill?.appName ?? package?.appName ?? "",
            "bundle_id": selectedSkill?.bundleID ?? package?.bundleID ?? "",
            "tools": tools.joined(separator: ","),
            "selectors": jsonStringValue(selectors),
            "recipes": recipes.joined(separator: ","),
            "entrypoints": jsonStringValue(entrypoints),
            "compatibility": jsonStringValue(compatibility)
        ]
    }
}

struct AppSkillResolvedAction {
    let tool: String
    let arguments: [String: Any]
    let reason: String

    var dictionary: [String: String] {
        [
            "tool": tool,
            "arguments": jsonStringValue(arguments),
            "reason": reason
        ]
    }
}

struct AppSkillRuntime {
    static func route(query: String, appName: String = "", bundleID: String = "") -> AppSkillRoute {
        let search = [query, appName, bundleID].filter { !$0.isEmpty }.joined(separator: " ")
        let normalizedSearch = normalizeForSearch(search)
        let normalizedApp = normalizeForSearch(appName)
        let normalizedBundle = normalizeForSearch(bundleID)
        let skill = exactSkill(appName: appName, bundleID: bundleID) ?? AppSkillStore.suggest(query: search, limit: 1).first
        let package = AppSkillPackageStore.list().first { package in
            let haystack = normalizeForSearch([package.id, package.appName, package.bundleID, package.capabilities.joined(separator: " ")].joined(separator: " "))
            let bundleIDs = package.bundleID.split(separator: ",").map { normalizeForSearch(String($0)) }
            return (!normalizedBundle.isEmpty && bundleIDs.contains(normalizedBundle)) ||
                (!normalizedApp.isEmpty && normalizeForSearch(package.appName).contains(normalizedApp)) ||
                normalizedSearch.split(separator: " ").contains { haystack.contains($0) }
        }
        let selectors = package?.selectors ?? skill?.selectors ?? [:]
        let tools = unique((package?.tools ?? []) + (skill?.tools ?? []))
        let recipes = unique((package?.recipes ?? []) + (skill?.recipes ?? []))
        let entrypoints = package?.entrypoints ?? [:]
        return AppSkillRoute(
            query: search,
            selectedSkill: skill,
            package: package,
            tools: tools,
            selectors: selectors,
            recipes: recipes,
            compatibility: [
                "skill_version": skill?.version ?? "package",
                "package_version": package?.version ?? "",
                "adapter_contract": "tools + selectors + recipes + capability manifest + optional executable adapter entrypoint",
                "dynamic_loading": package == nil ? "builtin" : "package"
            ],
            entrypoints: entrypoints
        )
    }

    static func actionPlan(
        query: String,
        appName: String = "",
        bundleID: String = "",
        action: String = "observe",
        arguments: [String: Any] = [:]
    ) -> [String: String] {
        let route = route(query: query, appName: appName, bundleID: bundleID)
        let resolved = resolveAction(route: route, action: action, arguments: arguments)
        let payload = adapterPayload(
            route: route,
            action: action,
            query: query,
            rawArguments: arguments,
            resolved: resolved
        )
        return [
            "schema": "aios.app_skill.action_plan.v1",
            "query": query,
            "action": normalizeForSearch(action).isEmpty ? "observe" : normalizeForSearch(action),
            "route": jsonStringValue(route.dictionary),
            "resolved_action": resolved.map { jsonStringValue($0.dictionary) } ?? "",
            "selected_tool": resolved?.tool ?? "",
            "normalized_arguments": jsonStringValue(resolved?.arguments ?? arguments),
            "can_execute_builtin_tool": resolved == nil ? "false" : "true",
            "can_execute_package_adapter": route.entrypoints["adapter"]?.isEmpty == false ? "true" : "false",
            "adapter_payload_preview": jsonStringValue(payload),
            "adapter_protocol": adapterProtocolSummary
        ]
    }

    static func resolveAction(route: AppSkillRoute, action: String, arguments: [String: Any]) -> AppSkillResolvedAction? {
        AppSkillActionResolver.resolve(route: route, action: action, arguments: arguments)
    }

    static func executeAdapter(
        query: String,
        appName: String = "",
        bundleID: String = "",
        action: String = "observe",
        arguments: [String: Any] = [:]
    ) throws -> ToolResult {
        let route = route(query: query, appName: appName, bundleID: bundleID)
        let resolved = resolveAction(route: route, action: action, arguments: arguments)
        guard let package = route.package else {
            return ToolResult(success: false, evidence: "No package-backed app skill route found.", data: route.dictionary, error: "app_skill_package_not_found")
        }
        guard let adapter = route.entrypoints["adapter"], !adapter.isEmpty else {
            return ToolResult(success: false, evidence: "App skill package has no executable adapter entrypoint.", data: route.dictionary, error: "app_skill_adapter_missing")
        }
        guard let packageURL = AppSkillPackageStore.resolvedPackageURL(id: package.id) else {
            return ToolResult(success: false, evidence: "Could not resolve app skill package directory.", data: route.dictionary, error: "app_skill_package_path_missing")
        }
        let adapterURL = packageURL.appendingPathComponent(adapter)
        guard FileManager.default.fileExists(atPath: adapterURL.path) else {
            return ToolResult(success: false, evidence: "Adapter entrypoint does not exist.", data: route.dictionary.merging(["adapter_path": adapterURL.path]) { current, _ in current }, error: "app_skill_adapter_not_found")
        }
        let payload = adapterPayload(route: route, action: action, query: query, rawArguments: arguments, resolved: resolved)
        let output = try runAdapter(url: adapterURL, payload: payload)
        var data = route.dictionary
        data["adapter_path"] = adapterURL.path
        data["adapter_stdout"] = truncateMiddle(output.stdout, maxCharacters: 6_000)
        data["adapter_stderr"] = truncateMiddle(output.stderr, maxCharacters: 2_000)
        data["exit_code"] = "\(output.exitCode)"
        data["adapter_protocol"] = adapterProtocolSummary
        data["adapter_payload"] = jsonStringValue(payload)
        if let resolved {
            data["resolved_action"] = jsonStringValue(resolved.dictionary)
            data["selected_tool"] = resolved.tool
        }
        guard let parsed = parseAdapterOutput(output.stdout) else {
            data["adapter_protocol_valid"] = "false"
            return ToolResult(
                success: false,
                evidence: "App skill adapter did not return a valid JSON evidence object.",
                data: data,
                error: "app_skill_adapter_invalid_output",
                suggestion: "Adapter stdout must be a single JSON object with at least success and evidence fields."
            )
        }
        data["adapter_protocol_valid"] = "true"
        data.merge(parsed) { current, _ in current }
        let adapterSuccess: Bool
        if let explicit = bool(data["success"]) {
            adapterSuccess = explicit
        } else {
            adapterSuccess = false
        }
        let evidence = data["evidence"] ?? (adapterSuccess ? "Executed app skill adapter." : "App skill adapter failed.")
        return ToolResult(success: adapterSuccess, evidence: evidence, data: data, error: adapterSuccess ? nil : (data["error"] ?? "app_skill_adapter_failed"))
    }

    static func exportManifest(id: String) throws -> URL {
        let package = AppSkillPackageStore.list().first { $0.id == id }
        let skill = AppSkillStore.read(id) ?? AppSkillStore.suggest(query: id, limit: 20).first { $0.id == id }
        let payload: [String: Any]
        if let package {
            payload = [
                "schema": "aios.app-skill.export.v1",
                "kind": "package",
                "manifest": package.dictionary,
                "selectors": package.selectors
            ]
        } else if let skill {
            payload = [
                "schema": "aios.app-skill.export.v1",
                "kind": "skill",
                "manifest": skill.dictionary,
                "selectors": skill.selectors
            ]
        } else {
            throw RuntimeError("App skill not found: \(id)")
        }
        let url = EventStore.appSkillsURL.appendingPathComponent("exports", isDirectory: true).appendingPathComponent("\(id).json")
        try writeJSONObject(payload, to: url)
        return url
    }

    private static func runAdapter(url: URL, payload: [String: Any]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        if url.pathExtension == "sh" {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [url.path]
        } else {
            process.executableURL = url
            process.arguments = []
        }
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return (
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    private static func adapterPayload(
        route: AppSkillRoute,
        action: String,
        query: String,
        rawArguments: [String: Any],
        resolved: AppSkillResolvedAction?
    ) -> [String: Any] {
        [
            "schema": "aios.app_skill.adapter.request.v1",
            "package": route.package?.dictionary ?? [:],
            "route": route.dictionary,
            "action": normalizeForSearch(action).isEmpty ? "observe" : normalizeForSearch(action),
            "query": query,
            "arguments": resolved?.arguments ?? rawArguments,
            "raw_arguments": rawArguments,
            "resolved_action": resolved?.dictionary ?? [:],
            "response_contract": [
                "schema": "aios.app_skill.adapter.response.v1",
                "required": ["success", "evidence"],
                "optional": ["error", "suggestion", "effect", "target", "value", "verified", "artifacts", "post_observation"],
                "material_effects": MaterialEffectVerificationPolicy.materialEffectKindList,
                "material_effects_require_verified": true
            ],
            "created_at": isoDateString(Date())
        ]
    }

    private static func parseAdapterOutput(_ text: String) -> [String: String]? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard raw["success"] != nil, raw["evidence"] != nil else { return nil }
        return raw.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String {
                result[pair.key] = value
            } else if let value = pair.value as? NSNumber {
                result[pair.key] = value.stringValue
            } else if JSONSerialization.isValidJSONObject(pair.value) {
                result[pair.key] = jsonStringValue(pair.value)
            }
        }
    }

    private static let adapterProtocolSummary = "stdin JSON schema=aios.app_skill.adapter.request.v1; stdout must be one JSON object with success:boolean and evidence:string; material side effects require verified:true to satisfy completion; optional error,suggestion,effect,target,value,artifacts,post_observation"

    private static func exactSkill(appName: String, bundleID: String) -> AppSkill? {
        let normalizedApp = normalizeForSearch(appName)
        let normalizedBundle = normalizeForSearch(bundleID)
        return AppSkillStore.list().first { skill in
            let appNames = normalizeForSearch(skill.appName).split(separator: " ")
            let bundleIDs = skill.bundleID.split(separator: ",").map { normalizeForSearch(String($0)) }
            return (!normalizedBundle.isEmpty && bundleIDs.contains(normalizedBundle)) ||
                (!normalizedApp.isEmpty && (normalizeForSearch(skill.appName).contains(normalizedApp) || appNames.contains(Substring(normalizedApp))))
        }
    }

}
