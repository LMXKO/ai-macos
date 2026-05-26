import Foundation

struct AppSkillRoute {
    let query: String
    let selectedSkill: AppSkill?
    let package: AppSkillPackage?
    let tools: [String]
    let selectors: [String: String]
    let recipes: [String]
    let compatibility: [String: String]

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
                "adapter_contract": "tools + selectors + recipes + capability manifest",
                "dynamic_loading": package == nil ? "builtin" : "package"
            ]
        )
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
}
