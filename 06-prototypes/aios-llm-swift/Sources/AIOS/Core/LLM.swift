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

struct LLMProvider {
    let baseURL: URL
    let model: String
    let apiKey: String?
    let label: String
}

struct LLMConfig {
    let baseURL: URL
    let model: String
    let apiKey: String?
    let maxSteps: Int
    let fallbacks: [LLMProvider]

    var providers: [LLMProvider] {
        [
            LLMProvider(baseURL: baseURL, model: model, apiKey: apiKey, label: "primary")
        ] + fallbacks
    }

    static func fromEnvironment() -> LLMConfig {
        let env = ProcessInfo.processInfo.environment
        let stored = (try? AIOSConfig.load()) ?? AIOSConfig.default
        let base = env["AIOS_LLM_BASE_URL"] ?? stored.baseURL
        let primaryURL = chatCompletionsURL(from: base)
        let primaryModel = env["AIOS_LLM_MODEL"] ?? stored.model
        let primaryKey = env["AIOS_LLM_API_KEY"] ?? (try? AIOSConfig.loadAPIKey())
        return LLMConfig(
            baseURL: primaryURL,
            model: primaryModel,
            apiKey: primaryKey,
            maxSteps: Int(env["AIOS_MAX_STEPS"] ?? "") ?? stored.maxSteps,
            fallbacks: parseFallbackProviders(
                env["AIOS_LLM_FALLBACKS"],
                defaultModel: primaryModel,
                defaultAPIKey: primaryKey,
                env: env
            )
        )
    }

    private static func chatCompletionsURL(from rawValue: String) -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)!
        }
        let base = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/chat/completions")!
    }

    private static func parseFallbackProviders(
        _ rawValue: String?,
        defaultModel: String,
        defaultAPIKey: String?,
        env: [String: String]
    ) -> [LLMProvider] {
        guard let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return rawValue
            .split(separator: ";")
            .enumerated()
            .compactMap { index, item -> LLMProvider? in
                let parts = item.split(separator: "|", omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let base = parts.first, !base.isEmpty else { return nil }
                let model = parts.indices.contains(1) && !parts[1].isEmpty ? parts[1] : defaultModel
                let key: String? = {
                    guard parts.indices.contains(2), !parts[2].isEmpty else { return defaultAPIKey }
                    if parts[2].hasPrefix("$") {
                        return env[String(parts[2].dropFirst())] ?? defaultAPIKey
                    }
                    return parts[2]
                }()
                return LLMProvider(
                    baseURL: chatCompletionsURL(from: base),
                    model: model,
                    apiKey: key,
                    label: "fallback_\(index + 1)"
                )
            }
    }
}

struct ToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
    let raw: [String: Any]
}

struct LLMResponse {
    let content: String?
    let toolCalls: [ToolCall]
    let rawMessage: [String: Any]
}

struct AIOSConfig: Codable {
    var baseURL: String
    var model: String
    var maxSteps: Int
    var runAtLogin: Bool
    var requireConfirmForProtectedActions: Bool
    var enableOCRFallback: Bool

    static let `default` = AIOSConfig(
        baseURL: "https://api.example.com/v1",
        model: "example-chat-model",
        maxSteps: 20,
        runAtLogin: false,
        requireConfirmForProtectedActions: true,
        enableOCRFallback: true
    )

    static var url: URL {
        EventStore.rootURL.appendingPathComponent("config.json")
    }

    var redactedDescription: String {
        [
            "base_url: \(baseURL)",
            "model: \(model)",
            "max_steps: \(maxSteps)",
            "run_at_login: \(runAtLogin)",
            "require_confirm_for_protected_actions: \(requireConfirmForProtectedActions)",
            "enable_ocr_fallback: \(enableOCRFallback)",
            "credential: \(((try? Self.loadAPIKey())?.isEmpty == false) ? "stored_in_keychain" : "not_set")"
        ].joined(separator: "\n")
    }

    static func load() throws -> AIOSConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try save(.default)
            return .default
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AIOSConfig.self, from: data)
    }

    static func save(_ config: AIOSConfig) throws {
        try FileManager.default.createDirectory(at: EventStore.rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: [.atomic])
    }

    static func update(key: String, value: String) throws {
        var config = try load()
        switch key {
        case "base_url", "baseURL":
            config.baseURL = value
        case "model":
            config.model = value
        case "max_steps", "maxSteps":
            guard let parsed = Int(value) else { throw RuntimeError("max_steps must be an integer") }
            config.maxSteps = parsed
        case "run_at_login", "runAtLogin":
            config.runAtLogin = ["1", "true", "yes"].contains(value.lowercased())
        case "require_confirm_for_protected_actions":
            config.requireConfirmForProtectedActions = ["1", "true", "yes"].contains(value.lowercased())
        case "enable_ocr_fallback":
            config.enableOCRFallback = ["1", "true", "yes"].contains(value.lowercased())
        default:
            throw RuntimeError("Unknown config key: \(key)")
        }
        try save(config)
    }

    private static let keychainService = "AIOS"
    private static let keychainAccount = "AIOS_LLM_API_KEY"

    static func storeAPIKey(_ key: String) throws {
        try deleteAPIKey()
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw RuntimeError("Keychain save failed: \(status)") }
    }

    static func loadAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RuntimeError("Keychain read failed: \(status)") }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RuntimeError("Keychain delete failed: \(status)")
        }
    }
}
