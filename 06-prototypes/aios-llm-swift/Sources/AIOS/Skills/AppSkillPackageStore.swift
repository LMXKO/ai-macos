import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Security
import ScriptingBridge
import SQLite3
import SwiftUI
import Vision

struct AppSkillPackage: Codable {
    let schema: String
    let id: String
    let version: String
    let appName: String
    let bundleID: String
    let minAIOSVersion: String
    let capabilities: [String]
    let tools: [String]
    let recipes: [String]
    let selectors: [String: String]
    let permissions: [String]
    let compatibility: [String: String]
    let entrypoints: [String: String]
    let notes: String

    var skill: AppSkill {
        AppSkill(
            id: id,
            appName: appName,
            bundleID: bundleID,
            version: version,
            capabilities: capabilities,
            tools: tools,
            recipes: recipes,
            selectors: selectors,
            permissions: permissions,
            notes: notes
        )
    }

    var dictionary: [String: String] {
        [
            "schema": schema,
            "id": id,
            "version": version,
            "app_name": appName,
            "bundle_id": bundleID,
            "min_aios_version": minAIOSVersion,
            "capabilities": capabilities.joined(separator: ","),
            "tools": tools.joined(separator: ","),
            "recipes": recipes.joined(separator: ","),
            "selectors": jsonStringValue(selectors),
            "permissions": permissions.joined(separator: ","),
            "compatibility": jsonStringValue(compatibility),
            "entrypoints": jsonStringValue(entrypoints),
            "notes": notes
        ]
    }
}

struct AppSkillPackageStore {
    static let schema = "aios.app_skill.package.v1"

    static var packagesURL: URL {
        EventStore.appSkillsURL.appendingPathComponent("packages", isDirectory: true)
    }

    static func packageURL(id: String) -> URL {
        packagesURL.appendingPathComponent(normalizeID(id), isDirectory: true)
    }

    static func manifestURL(id: String) -> URL {
        packageURL(id: id).appendingPathComponent("skill-package.json")
    }

    @discardableResult
    static func scaffold(
        id: String,
        appName: String,
        bundleID: String = "",
        version: String = "1",
        capabilities: [String] = [],
        tools: [String] = [],
        recipes: [String] = [],
        selectors: [String: String] = [:],
        permissions: [String] = [],
        entrypoints: [String: String] = [:],
        notes: String = ""
    ) throws -> AppSkillPackage {
        let packageEntrypoints = [
            "manifest": "skill-package.json",
            "selectors": "selectors.json",
            "recipes": "recipes/"
        ].merging(entrypoints) { _, new in new }
        let package = AppSkillPackage(
            schema: schema,
            id: normalizeID(id),
            version: version,
            appName: appName,
            bundleID: bundleID,
            minAIOSVersion: "0.1.0",
            capabilities: capabilities,
            tools: tools,
            recipes: recipes,
            selectors: selectors,
            permissions: permissions,
            compatibility: [
                "macos": "14+",
                "driver": "app_adapter_or_ax"
            ],
            entrypoints: packageEntrypoints,
            notes: notes
        )
        let dir = packageURL(id: package.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("recipes", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("docs", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("adapters", isDirectory: true), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(package).write(to: dir.appendingPathComponent("skill-package.json"), options: [.atomic])
        try writeJSONObject(selectors, to: dir.appendingPathComponent("selectors.json"))
        if let adapter = packageEntrypoints["adapter"], !adapter.isEmpty {
            let adapterURL = dir.appendingPathComponent(adapter)
            if !FileManager.default.fileExists(atPath: adapterURL.path) {
                try FileManager.default.createDirectory(at: adapterURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let template = """
                #!/bin/sh
                # AIOS app skill adapter template. Read JSON from stdin and print a JSON object.
                payload=$(cat)
                printf '{"schema":"aios.app_skill.adapter.response.v1","success":true,"evidence":"adapter template received request","payload":%s}\\n' "$payload"
                """
                try template.write(to: adapterURL, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adapterURL.path)
            }
        }
        let readme = """
        # \(appName) AIOS Skill Package

        Schema: \(schema)

        Add recipes under `recipes/*.json`, selectors in `selectors.json`, and keep tool/capability declarations in `skill-package.json`.

        Optional executable adapters live under `adapters/` and receive an AIOS JSON payload on stdin:

        - `action`: observe, ground, act, verify, wait, click, type, or app-specific verbs
        - `arguments`: normalized arguments selected by `app_skill_resolve_action`
        - `raw_arguments`: original caller arguments
        - `resolved_action`: selected built-in tool/arguments when applicable
        - stdout must be one JSON object with `success` and `evidence`
        - optional stdout fields: `error`, `suggestion`, `effect`, `target`, `value`, `verified`, `artifacts`, `post_observation`
        """
        try readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return package
    }

    static func list() -> [AppSkillPackage] {
        var seen = Set<String>()
        var packages: [AppSkillPackage] = []
        for package in packageRoots().flatMap({ loadPackages(from: $0) }) where !seen.contains(package.id) {
            seen.insert(package.id)
            packages.append(package)
        }
        return packages
    }

    private static func loadPackages(from root: URL) -> [AppSkillPackage] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        if root.pathExtension == "json" {
            return decodePackage(at: root).map { [$0] } ?? []
        }
        let directManifest = root.appendingPathComponent("skill-package.json")
        if FileManager.default.fileExists(atPath: directManifest.path) {
            return decodePackage(at: directManifest).map { [$0] } ?? []
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return urls.compactMap { url in
            let manifest = url.pathExtension == "json" ? url : url.appendingPathComponent("skill-package.json")
            return decodePackage(at: manifest)
        }
    }

    private static func decodePackage(at manifest: URL) -> AppSkillPackage? {
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder().decode(AppSkillPackage.self, from: data)
    }

    static func resolvedPackageURL(id: String) -> URL? {
        let normalized = normalizeID(id)
        for root in packageRoots() {
            if root.pathExtension == "json",
               let package = decodePackage(at: root),
               package.id == normalized || package.id == id {
                return root.deletingLastPathComponent()
            }
            let directManifest = root.appendingPathComponent("skill-package.json")
            if let package = decodePackage(at: directManifest),
               package.id == normalized || package.id == id {
                return root
            }
            guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in urls {
                let manifest = url.pathExtension == "json" ? url : url.appendingPathComponent("skill-package.json")
                if let package = decodePackage(at: manifest),
                   package.id == normalized || package.id == id {
                    return url.pathExtension == "json" ? url.deletingLastPathComponent() : url
                }
            }
        }
        return nil
    }

    static func skills() -> [AppSkill] {
        list().map(\.skill)
    }

    static func validate(_ package: AppSkillPackage, knownTools: Set<String>) -> [String] {
        var issues: [String] = []
        if package.schema != schema { issues.append("schema must be \(schema)") }
        if package.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("id is empty") }
        if package.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("app_name is empty") }
        let missing = package.tools.filter { !knownTools.contains($0) }
        if !missing.isEmpty { issues.append("unknown tools: \(missing.joined(separator: ","))") }
        let dir = resolvedPackageURL(id: package.id) ?? packageURL(id: package.id)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("selectors.json").path) {
            issues.append("selectors.json missing")
        }
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("recipes", isDirectory: true).path) {
            issues.append("recipes directory missing")
        }
        if let adapter = package.entrypoints["adapter"], !adapter.isEmpty,
           !FileManager.default.fileExists(atPath: dir.appendingPathComponent(adapter).path) {
            issues.append("adapter entrypoint missing: \(adapter)")
        }
        return issues
    }

    private static func packageRoots() -> [URL] {
        let envRoots = (ProcessInfo.processInfo.environment["AIOS_APP_SKILL_PATHS"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0).expandingTildeInPath, isDirectory: true) }
        return [packagesURL] + envRoots
    }
}
