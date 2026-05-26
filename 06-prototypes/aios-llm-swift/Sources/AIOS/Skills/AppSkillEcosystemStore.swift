import Foundation

struct AppSkillEcosystemStore {
    static func sdkSpec() -> [String: String] {
        let manifestFields = [
            "id", "app_name", "bundle_id", "version", "capabilities", "tools",
            "recipes", "selectors", "permissions", "notes", "compatibility"
        ]
        return [
            "schema": "aios.app_skill.sdk.v1",
            "package_root": AppSkillPackageStore.packagesURL.path,
            "manifest_fields": manifestFields.joined(separator: ","),
            "required_files": "manifest.json,selectors.json,recipes/,README.md",
            "adapter_contract": "declare capabilities -> expose tool names -> bundle selectors/recipes -> validate against ToolRegistry -> route by app/task",
            "versioning": "semver recommended; compatibility can pin bundle_id, app version, OS version, and required driver channels",
            "distribution": "portable package directory or exported manifest JSON"
        ]
    }

    static func marketplace(query: String = "", limit: Int = 20) -> [String: String] {
        let normalized = normalizeForSearch(query)
        let builtins = AppSkillStore.list().map { skill in
            [
                "kind": "builtin",
                "id": skill.id,
                "app_name": skill.appName,
                "bundle_id": skill.bundleID,
                "version": skill.version,
                "capabilities": skill.capabilities.joined(separator: ","),
                "tools": skill.tools.joined(separator: ","),
                "recipes": skill.recipes.joined(separator: ",")
            ]
        }
        let packages = AppSkillPackageStore.list().map { package in
            [
                "kind": "package",
                "id": package.id,
                "app_name": package.appName,
                "bundle_id": package.bundleID,
                "version": package.version,
                "capabilities": package.capabilities.joined(separator: ","),
                "tools": package.tools.joined(separator: ","),
                "recipes": package.recipes.joined(separator: ",")
            ]
        }
        let rows = (builtins + packages).filter { row in
            normalized.isEmpty || normalizeForSearch(row.values.joined(separator: " ")).contains(normalized)
        }.prefix(max(1, limit))
        return [
            "schema": "aios.app_skill.marketplace.v1",
            "query": query,
            "skills": jsonStringValue(Array(rows)),
            "sdk": jsonStringValue(sdkSpec())
        ]
    }
}
