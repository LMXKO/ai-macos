import Foundation

struct AppSkillEcosystemStore {
    static func sdkSpec() -> [String: String] {
        let manifestFields = [
            "id", "app_name", "bundle_id", "version", "capabilities", "tools",
            "recipes", "selectors", "permissions", "entrypoints", "notes", "compatibility"
        ]
        return [
            "schema": "aios.app_skill.sdk.v1",
            "package_root": AppSkillPackageStore.packagesURL.path,
            "manifest_fields": manifestFields.joined(separator: ","),
            "required_files": "skill-package.json,selectors.json,recipes/,README.md,optional adapters/",
            "adapter_request_schema": "aios.app_skill.adapter.request.v1",
            "adapter_response_schema": "aios.app_skill.adapter.response.v1",
            "adapter_contract": "declare capabilities -> expose tool names -> bundle selectors/recipes -> optional executable adapter receives JSON on stdin and must return one JSON object on stdout with success:boolean and evidence:string",
            "adapter_request_fields": "schema,package,route,action,query,arguments,raw_arguments,resolved_action,response_contract,created_at",
            "adapter_response_required": "success,evidence",
            "adapter_response_optional": "error,suggestion,effect,target,value,verified,artifacts,post_observation",
            "resolution_contract": "app_skill_resolve_action maps generic action args into selected_tool, normalized_arguments, and adapter_payload_preview before execution",
            "verifier_contract": "declare postconditions with app_verifier_*: effect, required inputs, verifier tools, evidence fields, fallback channels, and completion rule",
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
            "verifier_contracts": jsonStringValue(AppVerifierStore.list(query: query, limit: limit).map(\.dictionary)),
            "sdk": jsonStringValue(sdkSpec())
        ]
    }
}
