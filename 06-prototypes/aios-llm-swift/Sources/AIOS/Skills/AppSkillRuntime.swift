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

struct AppSkillRuntime {
    static func route(query: String, appName: String = "", bundleID: String = "") -> AppSkillRoute {
        let search = [query, appName, bundleID].filter { !$0.isEmpty }.joined(separator: " ")
        let skill = AppSkillStore.suggest(query: search, limit: 1).first
        let package = AppSkillPackageStore.list().first { package in
            let haystack = normalizeForSearch([package.id, package.appName, package.bundleID, package.capabilities.joined(separator: " ")].joined(separator: " "))
            return normalizeForSearch(search).split(separator: " ").contains { haystack.contains($0) } ||
                (!bundleID.isEmpty && package.bundleID == bundleID)
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

    static func executeAdapter(
        query: String,
        appName: String = "",
        bundleID: String = "",
        action: String = "observe",
        arguments: [String: Any] = [:]
    ) throws -> ToolResult {
        let route = route(query: query, appName: appName, bundleID: bundleID)
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
        let payload: [String: Any] = [
            "schema": "aios.app_skill.adapter.request.v1",
            "package": package.dictionary,
            "route": route.dictionary,
            "action": action,
            "query": query,
            "arguments": arguments,
            "created_at": isoDateString(Date())
        ]
        let output = try runAdapter(url: adapterURL, payload: payload)
        var data = route.dictionary
        data["adapter_path"] = adapterURL.path
        data["adapter_stdout"] = truncateMiddle(output.stdout, maxCharacters: 6_000)
        data["adapter_stderr"] = truncateMiddle(output.stderr, maxCharacters: 2_000)
        data["exit_code"] = "\(output.exitCode)"
        if let parsed = parseAdapterOutput(output.stdout) {
            data.merge(parsed) { current, _ in current }
        }
        let adapterSuccess: Bool
        if let explicit = bool(data["success"]) {
            adapterSuccess = explicit
        } else {
            adapterSuccess = output.exitCode == 0
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

    private static func parseAdapterOutput(_ text: String) -> [String: String]? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
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
}
