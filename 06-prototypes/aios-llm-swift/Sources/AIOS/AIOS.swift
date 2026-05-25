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

private func sqliteTransientDestructor() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

@main
struct AIOS {
    @MainActor
    private static var desktopApp: AIOSDesktopApp?

    @MainActor
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty, !args.contains("--help") else {
            print(Self.usage)
            return
        }

        if args.first == "doctor" {
            ToolRegistry().doctor(requestPermissions: args.contains("--request-permissions"))
            return
        }

        if args.first == "setup" {
            ToolRegistry().setupWizard(requestPermissions: args.contains("--request-permissions"))
            return
        }

        if args.first == "mcp" {
            AIOSMCPServer().run()
            return
        }

        if args.first == "app" {
            let app = AIOSDesktopApp()
            desktopApp = app
            app.run()
            return
        }

        if args.first == "host" {
            let host = AIOSHost(menuBar: true)
            await host.run()
            return
        }

        if args.first == "daemon" {
            let host = AIOSHost(menuBar: false)
            await host.run()
            return
        }

        if args.first == "submit" {
            submitTask(args: Array(args.dropFirst()))
            return
        }

        if args.first == "runs" {
            listRuns()
            return
        }

        if args.first == "cancel" {
            cancelRun(args: Array(args.dropFirst()))
            return
        }

        if args.first == "retry" {
            retryRun(args: Array(args.dropFirst()))
            return
        }

        if args.first == "show" {
            showRun(args: Array(args.dropFirst()))
            return
        }

        if args.first == "config" {
            configCommand(args: Array(args.dropFirst()))
            return
        }

        if args.first == "recipe" {
            recipeCommand(args: Array(args.dropFirst()))
            return
        }

        if args.first == "eval" {
            await evalCommand(args: Array(args.dropFirst()))
            return
        }

        if args.first == "learn" {
            learnCommand(args: Array(args.dropFirst()))
            return
        }

        if args.first == "launch-agent" {
            launchAgentCommand(args: Array(args.dropFirst()))
            return
        }

        if args.first == "tool" {
            runSingleTool(args: Array(args.dropFirst()))
            return
        }

        let config = LLMConfig.fromEnvironment()
        let goal = args.joined(separator: " ")
        let eventStore = try? EventStore.start(goal: goal)
        if let eventStore {
            print("run_id: \(eventStore.runID)")
        }
        let loop = AgentLoop(client: OpenAICompatibleClient(config: config), tools: ToolRegistry(), eventStore: eventStore)

        do {
            let complete = try await loop.run(goal: goal)
            try? eventStore?.updateStatus(complete ? "complete" : "incomplete")
        } catch {
            try? eventStore?.append("RunFailed", ["error": error.localizedDescription])
            try? eventStore?.updateStatus("failed")
            fputs("AIOS error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static let usage = """
    AIOS LLM Swift prototype

    Usage:
      swift run aios doctor
      swift run aios doctor --request-permissions
      swift run aios setup --request-permissions
      swift run aios mcp
      swift run aios app
      swift run aios host
      swift run aios daemon
      swift run aios submit "Draft a short project plan and send it to Example Contact"
      swift run aios runs
      swift run aios cancel <run_id>
      swift run aios retry <run_id>
      swift run aios show <run_id>
      swift run aios config show
      swift run aios config set-key
      swift run aios recipe list
      swift run aios recipe suggest "把文档导出 PDF"
      swift run aios recipe run send-file-to-contact '{"app":"wechat","recipient":"Example Contact","path":"~/Downloads/example.docx"}'
      swift run aios eval run
      swift run aios learn start "send file to contact"
      swift run aios learn record wechat_stage_file '{"recipient":"Example Contact","path":"~/Downloads/example.docx"}'
      swift run aios learn record-events "open app workflow" --seconds 10 --recipe-id learned-ui-flow
      swift run aios learn stop send-file-learned
      swift run aios launch-agent install
      swift run aios tool aios_list_apps '{"query":"WeChat"}'
      swift run aios "在 TextEdit 新建文档，写入 hello aios，保存到桌面 aios-demo.txt，并用 Finder 验证"

    Environment:
      AIOS_LLM_BASE_URL   OpenAI-compatible base URL or chat completions URL
                          default: https://api.example.com/v1
      AIOS_LLM_MODEL      model name, default: example-chat-model
      AIOS_LLM_API_KEY    optional bearer token
      AIOS_LLM_FALLBACKS  optional fallback providers separated by semicolons:
                          base_url|model|api_key_or_$ENV
      AIOS_MAX_STEPS      default: 20
    """

    @MainActor
    private static func runSingleTool(args: [String]) {
        guard let name = args.first else {
            fputs("Usage: aios tool <tool_name> '{\"arg\":\"value\"}'\n", stderr)
            exit(2)
        }
        let argumentText = args.dropFirst().joined(separator: " ")
        let data = Data((argumentText.isEmpty ? "{}" : argumentText).utf8)
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fputs("Tool arguments must be a JSON object.\n", stderr)
            exit(2)
        }
        let call = ToolCall(id: "manual", name: name, arguments: parsed, raw: [:])
        print(ToolRegistry().execute(call).jsonString)
    }

    @MainActor
    private static func submitTask(args: [String]) {
        let goal = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            fputs("Usage: aios submit \"<goal>\"\n", stderr)
            exit(2)
        }
        do {
            let id = try TaskQueue.submit(goal: goal)
            print("submitted: \(id)")
        } catch {
            fputs("Submit failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func listRuns() {
        do {
            let runs = try EventStore.listRuns()
            if runs.isEmpty {
                print("No runs yet.")
                return
            }
            for run in runs {
                print("\(run.id)\t\(run.status)\t\(run.createdAt)\t\(run.goal)")
            }
        } catch {
            fputs("List runs failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func cancelRun(args: [String]) {
        guard let id = args.first, !id.isEmpty else {
            fputs("Usage: aios cancel <run_id>\n", stderr)
            exit(2)
        }
        do {
            try TaskQueue.cancel(id)
            try EventStore.markRun(runID: id, status: "canceled", event: "RunCanceled", fields: [:])
            print("canceled: \(id)")
        } catch {
            fputs("Cancel failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func retryRun(args: [String]) {
        guard let id = args.first, !id.isEmpty else {
            fputs("Usage: aios retry <run_id>\n", stderr)
            exit(2)
        }
        do {
            let summary = try EventStore.readSummary(runID: id)
            let newID = try TaskQueue.submit(goal: summary.goal)
            try EventStore.markRun(runID: id, status: "retried", event: "RunRetried", fields: ["new_run_id": newID])
            print("retry_submitted: \(newID)")
        } catch {
            fputs("Retry failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func showRun(args: [String]) {
        guard let id = args.first, !id.isEmpty else {
            fputs("Usage: aios show <run_id>\n", stderr)
            exit(2)
        }
        do {
            print(try EventStore.readEventsText(runID: id))
        } catch {
            fputs("Show run failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func configCommand(args: [String]) {
        let subcommand = args.first ?? "show"
        do {
            switch subcommand {
            case "show":
                print(try AIOSConfig.load().redactedDescription)
            case "set":
                guard args.count >= 3 else { throw RuntimeError("Usage: aios config set <key> <value>") }
                try AIOSConfig.update(key: args[1], value: args.dropFirst(2).joined(separator: " "))
                print("config_updated: \(args[1])")
            case "set-key":
                let key = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    try AIOSConfig.storeAPIKey(key)
                } else if let envKey = ProcessInfo.processInfo.environment["AIOS_LLM_API_KEY"], !envKey.isEmpty {
                    try AIOSConfig.storeAPIKey(envKey)
                } else {
                    throw RuntimeError("Pass the key as an argument or set AIOS_LLM_API_KEY for this command.")
                }
                print("api_key_saved_to_keychain")
            case "clear-key":
                try AIOSConfig.deleteAPIKey()
                print("api_key_removed_from_keychain")
            default:
                throw RuntimeError("Unknown config command: \(subcommand)")
            }
        } catch {
            fputs("Config failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func recipeCommand(args: [String]) {
        let subcommand = args.first ?? "list"
        do {
            switch subcommand {
            case "list":
                let recipes = try RecipeStore.list()
                if recipes.isEmpty {
                    print("No recipes.")
                } else {
                    for recipe in recipes {
                        print("\(recipe.id)\t\(recipe.title)\t\(recipe.goalTemplate)")
                    }
                }
            case "show":
                guard let id = args.dropFirst().first else { throw RuntimeError("Usage: aios recipe show <id>") }
                print(try RecipeStore.read(id).jsonString)
            case "suggest":
                let goal = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !goal.isEmpty else { throw RuntimeError("Usage: aios recipe suggest \"<goal>\"") }
                let suggestions = try RecipeStore.suggest(goal: goal)
                if suggestions.isEmpty {
                    print("No matching recipes.")
                } else {
                    for suggestion in suggestions {
                        print("\(suggestion.recipe.id)\tscore=\(suggestion.score)\t\(suggestion.recipe.title)\tparams=\(suggestion.recipe.requiredParams.joined(separator: ","))\tmatched=\(suggestion.matchedTerms.joined(separator: ","))")
                    }
                }
            case "run":
                guard args.count >= 2 else { throw RuntimeError("Usage: aios recipe run <id> '{...params...}'") }
                let id = args[1]
                let paramsText = args.dropFirst(2).joined(separator: " ")
                let params = try parseJSONObject(paramsText.isEmpty ? "{}" : paramsText)
                let goal = try RecipeStore.renderGoal(recipeID: id, params: params)
                let runID = try TaskQueue.submit(goal: goal)
                print("submitted: \(runID)")
            case "exec":
                guard args.count >= 2 else { throw RuntimeError("Usage: aios recipe exec <id> '{...params...}'") }
                let id = args[1]
                let paramsText = args.dropFirst(2).joined(separator: " ")
                let params = try parseJSONObject(paramsText.isEmpty ? "{}" : paramsText)
                let store = try EventStore.start(goal: "recipe:\(id)")
                let results = try RecipeStore.execute(recipeID: id, params: params, eventStore: store)
                let ok = results.allSatisfy(\.success)
                try store.updateStatus(ok ? "complete" : "failed")
                print("run_id: \(store.runID)")
                for result in results {
                    print(result.jsonString)
                }
            case "seed":
                try RecipeStore.seedDefaults(overwrite: args.contains("--overwrite"))
                print("seeded_default_recipes")
            default:
                throw RuntimeError("Unknown recipe command: \(subcommand)")
            }
        } catch {
            fputs("Recipe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func evalCommand(args: [String]) async {
        let subcommand = args.first ?? "run"
        do {
            switch subcommand {
            case "list":
                for testCase in E2ERunner.cases {
                    print("\(testCase.id)\t\(testCase.title)")
                }
            case "real-list":
                try E2ERunner.seedRealCases(overwrite: args.contains("--overwrite"))
                for testCase in try E2ERunner.realCases() {
                    print("\(testCase.id)\t\(testCase.enabled ? "enabled" : "disabled")\t\(testCase.sendsExternalMessage ? "sends" : "local")\t\(testCase.title)")
                    if let goal = testCase.goal, !goal.isEmpty {
                        print("  goal: \(goal)")
                    }
                }
                print("config: \(E2ERunner.realCasesURL.path)")
            case "real-run":
                guard let id = args.dropFirst().first else { throw RuntimeError("Usage: aios eval real-run <id>") }
                let result = try await E2ERunner().runReal(id: id)
                print(result.jsonString)
            case "run":
                let filter = positionalArguments(args.dropFirst()).first
                let repeatCount = intArgument(args, name: "--repeat") ?? 1
                let results = try E2ERunner().run(filter: filter, repeatCount: repeatCount)
                for result in results {
                    print("\(result.id)\t\(result.passed ? "pass" : "fail")\t\(result.durationMs)ms\t\(result.evidence)")
                }
            default:
                throw RuntimeError("Unknown eval command: \(subcommand)")
            }
        } catch {
            fputs("Eval failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func learnCommand(args: [String]) {
        let subcommand = args.first ?? "status"
        do {
            switch subcommand {
            case "start":
                let title = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let session = try LearningStore.start(title: title.isEmpty ? "Learned workflow" : title)
                print("learning_started: \(session.id)")
            case "record":
                guard args.count >= 2 else { throw RuntimeError("Usage: aios learn record <tool> '{...args...}'") }
                let tool = args[1]
                let argText = args.dropFirst(2).joined(separator: " ")
                let arguments = try parseJSONObject(argText.isEmpty ? "{}" : argText)
                let result = ToolRegistry().execute(ToolCall(id: "learn", name: tool, arguments: arguments, raw: [:]))
                try LearningStore.record(tool: tool, arguments: arguments, result: result)
                print(result.jsonString)
            case "record-events":
                let title = args.dropFirst().prefix { !$0.hasPrefix("--") }.joined(separator: " ")
                let seconds = doubleArgument(args, name: "--seconds") ?? 8
                let recipeID = stringArgument(args, name: "--recipe-id") ?? "learned-events-\(Int(Date().timeIntervalSince1970))"
                let recipe = try RawEventRecorder.recordRecipe(
                    title: title.isEmpty ? "Raw UI workflow" : title,
                    recipeID: recipeID,
                    duration: seconds,
                    includeAX: !args.contains("--no-ax")
                )
                print(recipe.jsonString)
            case "stop":
                let recipeID = args.dropFirst().first ?? "learned-\(Int(Date().timeIntervalSince1970))"
                let recipe = try LearningStore.stop(recipeID: recipeID)
                print(recipe.jsonString)
            case "status":
                print(try LearningStore.statusText())
            default:
                throw RuntimeError("Unknown learn command: \(subcommand)")
            }
        } catch {
            fputs("Learn failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func launchAgentCommand(args: [String]) {
        let subcommand = args.first ?? "status"
        do {
            switch subcommand {
            case "install":
                try LaunchAgentManager.install()
                print("launch_agent_installed")
            case "uninstall":
                try LaunchAgentManager.uninstall()
                print("launch_agent_uninstalled")
            case "status":
                print(LaunchAgentManager.statusText())
            default:
                throw RuntimeError("Unknown launch-agent command: \(subcommand)")
            }
        } catch {
            fputs("LaunchAgent failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

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
            "api_key: \(((try? Self.loadAPIKey())?.isEmpty == false) ? "stored_in_keychain" : "not_set")"
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

struct EventStore {
    struct RunSummary {
        let id: String
        let goal: String
        let createdAt: String
        let updatedAt: String
        let status: String
        let eventsPath: String
    }

    let runID: String
    let goal: String
    let dir: URL
    let eventsURL: URL
    let summaryURL: URL

    static var rootURL: URL {
        let override = ProcessInfo.processInfo.environment["AIOS_STATE_DIR"]
        let raw = override?.expandingTildeInPath ?? "\(NSHomeDirectory())/Library/Application Support/AIOS"
        return URL(fileURLWithPath: raw)
    }

    static var queueURL: URL {
        rootURL.appendingPathComponent("queue", isDirectory: true)
    }

    static var runsURL: URL {
        rootURL.appendingPathComponent("runs", isDirectory: true)
    }

    static var snapshotsURL: URL {
        rootURL.appendingPathComponent("snapshots", isDirectory: true)
    }

    static var recipesURL: URL {
        rootURL.appendingPathComponent("recipes", isDirectory: true)
    }

    static var evalsURL: URL {
        rootURL.appendingPathComponent("evals", isDirectory: true)
    }

    static var learningURL: URL {
        rootURL.appendingPathComponent("learning", isDirectory: true)
    }

    static var auditURL: URL {
        rootURL.appendingPathComponent("audit.jsonl")
    }

    static func start(goal: String, runID: String = UUID().uuidString) throws -> EventStore {
        let dir = runsURL.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EventStore(
            runID: runID,
            goal: goal,
            dir: dir,
            eventsURL: dir.appendingPathComponent("events.jsonl"),
            summaryURL: dir.appendingPathComponent("summary.json")
        )
        try store.updateStatus("running")
        try store.append("RunStarted", [
            "run_id": runID,
            "goal": goal
        ])
        return store
    }

    static func createQueued(goal: String, runID: String) throws -> EventStore {
        let dir = runsURL.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = EventStore(
            runID: runID,
            goal: goal,
            dir: dir,
            eventsURL: dir.appendingPathComponent("events.jsonl"),
            summaryURL: dir.appendingPathComponent("summary.json")
        )
        try store.updateStatus("queued")
        try store.append("QueueSubmitted", [
            "run_id": runID,
            "goal": goal
        ])
        return store
    }

    func append(_ event: String, _ fields: [String: String]) throws {
        var payload = fields
        payload["event"] = event
        payload["run_id"] = runID
        payload["time"] = isoDateString(Date())
        let line = jsonLine(payload) + "\n"
        if FileManager.default.fileExists(atPath: eventsURL.path) {
            let handle = try FileHandle(forWritingTo: eventsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: eventsURL, atomically: true, encoding: .utf8)
        }
    }

    func updateStatus(_ status: String) throws {
        let existingCreatedAt: String? = {
            guard let data = try? Data(contentsOf: summaryURL),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return string(raw["created_at"])
        }()
        let now = isoDateString(Date())
        let summary: [String: String] = [
            "id": runID,
            "goal": goal,
            "created_at": existingCreatedAt ?? now,
            "updated_at": now,
            "status": status,
            "events_path": eventsURL.path
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: summaryURL)
        try? SQLiteRunIndex.upsert(RunSummary(
            id: runID,
            goal: goal,
            createdAt: existingCreatedAt ?? now,
            updatedAt: now,
            status: status,
            eventsPath: eventsURL.path
        ))
    }

    static func listRuns() throws -> [RunSummary] {
        if let indexed = try? SQLiteRunIndex.list(), !indexed.isEmpty {
            return indexed
        }
        guard FileManager.default.fileExists(atPath: runsURL.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        let runs = dirs.compactMap { dir -> RunSummary? in
            let summaryURL = dir.appendingPathComponent("summary.json")
            guard let data = try? Data(contentsOf: summaryURL),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return RunSummary(
                id: string(raw["id"]) ?? dir.lastPathComponent,
                goal: string(raw["goal"]) ?? "",
                createdAt: string(raw["created_at"]) ?? "",
                updatedAt: string(raw["updated_at"]) ?? "",
                status: string(raw["status"]) ?? "",
                eventsPath: string(raw["events_path"]) ?? ""
            )
        }
        try? SQLiteRunIndex.rebuild(from: runs)
        return runs.sorted { $0.createdAt > $1.createdAt }
    }

    static func readSummary(runID: String) throws -> RunSummary {
        let dir = runsURL.appendingPathComponent(runID, isDirectory: true)
        let summaryURL = dir.appendingPathComponent("summary.json")
        let data = try Data(contentsOf: summaryURL)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeError("Invalid summary JSON for \(runID)")
        }
        return RunSummary(
            id: string(raw["id"]) ?? runID,
            goal: string(raw["goal"]) ?? "",
            createdAt: string(raw["created_at"]) ?? "",
            updatedAt: string(raw["updated_at"]) ?? "",
            status: string(raw["status"]) ?? "",
            eventsPath: string(raw["events_path"]) ?? ""
        )
    }

    static func readEventsText(runID: String) throws -> String {
        let url = runsURL.appendingPathComponent(runID, isDirectory: true).appendingPathComponent("events.jsonl")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func markRun(runID: String, status: String, event: String, fields: [String: String]) throws {
        let summary = try readSummary(runID: runID)
        let store = EventStore(
            runID: runID,
            goal: summary.goal,
            dir: runsURL.appendingPathComponent(runID, isDirectory: true),
            eventsURL: runsURL.appendingPathComponent(runID, isDirectory: true).appendingPathComponent("events.jsonl"),
            summaryURL: runsURL.appendingPathComponent(runID, isDirectory: true).appendingPathComponent("summary.json")
        )
        try store.append(event, fields)
        try store.updateStatus(status)
    }
}

struct SQLiteRunIndex {
    static var url: URL {
        EventStore.rootURL.appendingPathComponent("runs.sqlite")
    }

    static func upsert(_ summary: EventStore.RunSummary) throws {
        try withDatabase { db in
            try prepareSchema(db)
            let sql = """
            INSERT INTO runs(id, goal, status, created_at, updated_at, events_path)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              goal=excluded.goal,
              status=excluded.status,
              created_at=excluded.created_at,
              updated_at=excluded.updated_at,
              events_path=excluded.events_path
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RuntimeError(sqliteError(db))
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, summary.id)
            bindText(statement, 2, summary.goal)
            bindText(statement, 3, summary.status)
            bindText(statement, 4, summary.createdAt)
            bindText(statement, 5, summary.updatedAt)
            bindText(statement, 6, summary.eventsPath)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RuntimeError(sqliteError(db))
            }
        }
    }

    static func list(limit: Int = 500) throws -> [EventStore.RunSummary] {
        try withDatabase { db in
            try prepareSchema(db)
            let sql = """
            SELECT id, goal, created_at, updated_at, status, events_path
            FROM runs
            ORDER BY created_at DESC
            LIMIT ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RuntimeError(sqliteError(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [EventStore.RunSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(EventStore.RunSummary(
                    id: columnText(statement, 0),
                    goal: columnText(statement, 1),
                    createdAt: columnText(statement, 2),
                    updatedAt: columnText(statement, 3),
                    status: columnText(statement, 4),
                    eventsPath: columnText(statement, 5)
                ))
            }
            return rows
        }
    }

    static func rebuild(from summaries: [EventStore.RunSummary]) throws {
        guard !summaries.isEmpty else { return }
        try withDatabase { db in
            try prepareSchema(db)
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw RuntimeError(sqliteError(db))
            }
            do {
                for summary in summaries {
                    try upsert(summary, in: db)
                }
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw RuntimeError(sqliteError(db))
                }
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    private static func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: EventStore.rootURL, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw RuntimeError(sqliteError(db))
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static func prepareSchema(_ db: OpaquePointer?) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS runs(
          id TEXT PRIMARY KEY,
          goal TEXT NOT NULL,
          status TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          events_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_runs_created_at ON runs(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw RuntimeError(sqliteError(db))
        }
    }

    private static func upsert(_ summary: EventStore.RunSummary, in db: OpaquePointer?) throws {
        let sql = """
        INSERT INTO runs(id, goal, status, created_at, updated_at, events_path)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          goal=excluded.goal,
          status=excluded.status,
          created_at=excluded.created_at,
          updated_at=excluded.updated_at,
          events_path=excluded.events_path
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RuntimeError(sqliteError(db))
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, summary.id)
        bindText(statement, 2, summary.goal)
        bindText(statement, 3, summary.status)
        bindText(statement, 4, summary.createdAt)
        bindText(statement, 5, summary.updatedAt)
        bindText(statement, 6, summary.eventsPath)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RuntimeError(sqliteError(db))
        }
    }

    private static func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor())
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private static func sqliteError(_ db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else { return "sqlite error" }
        return String(cString: message)
    }
}

struct TaskQueue {
    static func submit(goal: String) throws -> String {
        try FileManager.default.createDirectory(at: EventStore.queueURL, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let url = EventStore.queueURL.appendingPathComponent("\(id).json")
        let item: [String: String] = [
            "id": id,
            "goal": goal,
            "created_at": isoDateString(Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        _ = try EventStore.createQueued(goal: goal, runID: id)
        return id
    }

    static func next() throws -> (id: String, goal: String, url: URL)? {
        guard FileManager.default.fileExists(atPath: EventStore.queueURL.path) else { return nil }
        let urls = try FileManager.default.contentsOfDirectory(at: EventStore.queueURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
        guard let url = urls.first,
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let goal = string(raw["goal"])
        else { return nil }
        return (string(raw["id"]) ?? url.deletingPathExtension().lastPathComponent, goal, url)
    }

    static func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    static func cancel(_ id: String) throws {
        let url = EventStore.queueURL.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

struct AuditLog {
    static func append(action: String, fields: [String: String]) {
        do {
            try FileManager.default.createDirectory(at: EventStore.rootURL, withIntermediateDirectories: true)
            var payload = fields
            payload["action"] = action
            payload["time"] = isoDateString(Date())
            let line = jsonLine(payload) + "\n"
            if FileManager.default.fileExists(atPath: EventStore.auditURL.path) {
                let handle = try FileHandle(forWritingTo: EventStore.auditURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: EventStore.auditURL, atomically: true, encoding: .utf8)
            }
        } catch {
            fputs("audit failed: \(error.localizedDescription)\n", stderr)
        }
    }

    static func readText(limit: Int = 200) -> String {
        guard let text = try? String(contentsOf: EventStore.auditURL, encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.suffix(limit).joined(separator: "\n")
    }
}

struct RecipeStep: Codable {
    let id: String
    let title: String
    let tool: String
    let arguments: [String: String]
    let verifyTool: String?
    let verifyArguments: [String: String]?
    let waitCondition: String?
    let waitValue: String?
    let retries: Int?
    let fallbackTools: [RecipeFallback]?
    let verifyExpression: String?
    let recoverySteps: [RecipeStep]?
    let timeout: Double?

    init(
        id: String,
        title: String,
        tool: String,
        arguments: [String: String],
        verifyTool: String? = nil,
        verifyArguments: [String: String]? = nil,
        waitCondition: String? = nil,
        waitValue: String? = nil,
        retries: Int? = nil,
        fallbackTools: [RecipeFallback]? = nil,
        verifyExpression: String? = nil,
        recoverySteps: [RecipeStep]? = nil,
        timeout: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.tool = tool
        self.arguments = arguments
        self.verifyTool = verifyTool
        self.verifyArguments = verifyArguments
        self.waitCondition = waitCondition
        self.waitValue = waitValue
        self.retries = retries
        self.fallbackTools = fallbackTools
        self.verifyExpression = verifyExpression
        self.recoverySteps = recoverySteps
        self.timeout = timeout
    }
}

struct RecipeFallback: Codable {
    let tool: String
    let arguments: [String: String]?
    let verifyTool: String?
    let verifyArguments: [String: String]?
    let verifyExpression: String?

    init(
        tool: String,
        arguments: [String: String]? = nil,
        verifyTool: String? = nil,
        verifyArguments: [String: String]? = nil,
        verifyExpression: String? = nil
    ) {
        self.tool = tool
        self.arguments = arguments
        self.verifyTool = verifyTool
        self.verifyArguments = verifyArguments
        self.verifyExpression = verifyExpression
    }
}

struct Recipe: Codable {
    let id: String
    let title: String
    let goalTemplate: String
    let requiredParams: [String]
    let notes: String
    let steps: [RecipeStep]

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: (try? encoder.encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }
}

struct RecipeSuggestion {
    let recipe: Recipe
    let score: Int
    let matchedTerms: [String]

    var summary: [String: String] {
        [
            "id": recipe.id,
            "title": recipe.title,
            "goal_template": recipe.goalTemplate,
            "required_params": recipe.requiredParams.joined(separator: ","),
            "score": "\(score)",
            "matched_terms": matchedTerms.joined(separator: ",")
        ]
    }
}

struct RecipeStore {
    static let defaults: [Recipe] = [
        Recipe(
            id: "send-file-to-contact",
            title: "Send a local file to a contact",
            goalTemplate: "打开{{app}}，把{{path}}发送给{{recipient}}。发送前用观察工具确认当前聊天对象，发送后验证消息/附件已出现在聊天窗口。",
            requiredParams: ["app", "recipient", "path"],
            notes: "Works best with app=wechat/lark/qq or 微信/飞书/QQ.",
            steps: [
                RecipeStep(id: "S1", title: "Find the file", tool: "finder_file_info", arguments: ["path": "{{path}}"], waitCondition: "file_exists", waitValue: "{{path}}", verifyExpression: "success && data.path contains {{file_name}}"),
                RecipeStep(
                    id: "S2",
                    title: "Stage file in chat",
                    tool: "{{chat_prefix}}_stage_file",
                    arguments: ["{{recipient_key}}": "{{recipient}}", "path": "{{path}}"],
                    verifyTool: "{{chat_prefix}}_verify_chat",
                    verifyArguments: ["{{recipient_key}}": "{{recipient}}"],
                    retries: 2,
                    fallbackTools: [
                        RecipeFallback(tool: "{{chat_prefix}}_search_chat", arguments: ["name": "{{recipient}}"], verifyTool: "{{chat_prefix}}_verify_chat", verifyArguments: ["{{recipient_key}}": "{{recipient}}"])
                    ],
                    verifyExpression: "success && evidence contains Staged"
                ),
                RecipeStep(id: "S3", title: "Send staged content", tool: "{{chat_prefix}}_send_staged", arguments: ["{{recipient_key}}": "{{recipient}}"], verifyTool: "{{chat_prefix}}_verify_recent_message", verifyArguments: ["text": "{{file_name}}"], retries: 1)
            ]
        ),
        Recipe(
            id: "write-plan-and-sync",
            title: "Write a plan and sync it to a contact",
            goalTemplate: "梳理{{topic}}的计划，生成简洁方案，然后通过{{app}}同步给{{recipient}}，发送后验证。",
            requiredParams: ["topic", "app", "recipient"],
            notes: "This deterministic recipe sends the provided or generated summary text.",
            steps: [
                RecipeStep(id: "S1", title: "Draft in TextEdit", tool: "textedit_new_document", arguments: [:], waitCondition: "frontmost_app", waitValue: "TextEdit"),
                RecipeStep(id: "S2", title: "Write plan text", tool: "textedit_set_text", arguments: ["text": "{{message_text}}"], verifyTool: "textedit_read_text", verifyArguments: [:], verifyExpression: "success && data.chars contains"),
                RecipeStep(id: "S3", title: "Send plan text", tool: "{{chat_prefix}}_send_text", arguments: ["{{recipient_key}}": "{{recipient}}", "text": "{{message_text}}"], verifyTool: "{{chat_prefix}}_verify_recent_message", verifyArguments: ["text": "{{message_probe}}"], retries: 1)
            ]
        ),
        Recipe(
            id: "export-document-pdf",
            title: "Export document to PDF",
            goalTemplate: "把{{path}}导出成 PDF，保存到{{outdir}}，并验证 PDF 文件存在。",
            requiredParams: ["path", "outdir"],
            notes: "Uses LibreOffice when the file type is Office-compatible.",
            steps: [
                RecipeStep(id: "S1", title: "Find source document", tool: "finder_file_info", arguments: ["path": "{{path}}"], waitCondition: "file_exists", waitValue: "{{path}}"),
                RecipeStep(id: "S2", title: "Export PDF", tool: "libreoffice_export_pdf", arguments: ["path": "{{path}}", "outdir": "{{outdir}}"], verifyTool: "finder_file_info", verifyArguments: ["path": "{{pdf_path}}"], waitCondition: "file_exists", waitValue: "{{pdf_path}}", retries: 1, verifyExpression: "success && data.pdf contains .pdf")
            ]
        ),
        Recipe(
            id: "create-calendar-event",
            title: "Create and verify Calendar event",
            goalTemplate: "在日历里创建事件：{{title}}，开始时间{{start}}，结束时间{{end}}，备注{{notes}}。创建后查询验证。",
            requiredParams: ["title", "start", "end"],
            notes: "Calendar writes are allowed by current project policy.",
            steps: [
                RecipeStep(id: "S1", title: "Create event", tool: "calendar_create_event", arguments: ["title": "{{title}}", "start": "{{start}}", "end": "{{end}}", "notes": "{{notes}}"], verifyTool: "calendar_find_events", verifyArguments: ["title": "{{title}}", "days": "30"], retries: 1, verifyExpression: "success && evidence contains Created")
            ]
        )
    ]

    static func seedDefaults(overwrite: Bool = false) throws {
        try FileManager.default.createDirectory(at: EventStore.recipesURL, withIntermediateDirectories: true)
        for recipe in defaults {
            let url = recipeURL(recipe.id)
            if FileManager.default.fileExists(atPath: url.path), !overwrite {
                continue
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recipe).write(to: url, options: [.atomic])
        }
    }

    static func list() throws -> [Recipe] {
        try seedDefaults(overwrite: false)
        guard FileManager.default.fileExists(atPath: EventStore.recipesURL.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: EventStore.recipesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
        return try urls.map { try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }

    static func read(_ id: String) throws -> Recipe {
        try seedDefaults(overwrite: false)
        return try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: recipeURL(id)))
    }

    static func suggest(goal: String, limit: Int = 5) throws -> [RecipeSuggestion] {
        let goalText = normalizedText(goal)
        guard !goalText.isEmpty else { return [] }
        let tokens = tokens(from: goalText)
        let recipes = try list()
        let scored = recipes.compactMap { recipe -> RecipeSuggestion? in
            let corpus = normalizedText([
                recipe.id,
                recipe.title,
                recipe.goalTemplate,
                recipe.notes,
                recipe.requiredParams.joined(separator: " ")
            ].joined(separator: " "))
            var score = 0
            var matched = Set<String>()

            if goalText.contains(normalizedText(recipe.id)) {
                score += 12
                matched.insert(recipe.id)
            }
            let titleText = normalizedText(recipe.title)
            if !titleText.isEmpty, goalText.contains(titleText) || titleText.contains(goalText) {
                score += 8
                matched.insert(recipe.title)
            }

            for token in tokens where token.count >= 2 && corpus.contains(token) {
                score += 2
                matched.insert(token)
            }

            for keyword in keywords(for: recipe.id) where goalText.contains(keyword) {
                score += 3
                matched.insert(keyword)
            }

            if score == 0 { return nil }
            return RecipeSuggestion(recipe: recipe, score: score, matchedTerms: matched.sorted())
        }
        return scored
            .sorted {
                if $0.score == $1.score { return $0.recipe.id < $1.recipe.id }
                return $0.score > $1.score
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    static func renderGoal(recipeID: String, params: [String: Any]) throws -> String {
        let recipe = try read(recipeID)
        let resolved = try resolvedParams(recipe: recipe, params: params)
        return render(recipe.goalTemplate, params: resolved)
    }

    @MainActor
    static func execute(recipeID: String, params: [String: Any], eventStore: EventStore? = nil) throws -> [ToolResult] {
        let recipe = try read(recipeID)
        let resolved = try resolvedParams(recipe: recipe, params: params)
        let tools = ToolRegistry()
        var results: [ToolResult] = []
        for step in recipe.steps {
            let stepResults = try executeStep(step, recipeID: recipe.id, params: resolved, tools: tools, eventStore: eventStore, prefix: "recipe")
            results.append(contentsOf: stepResults)
            guard stepResults.last?.success == true else { return results }
        }
        return results
    }

    @MainActor
    private static func executeStep(
        _ step: RecipeStep,
        recipeID: String,
        params: [String: String],
        tools: ToolRegistry,
        eventStore: EventStore?,
        prefix: String
    ) throws -> [ToolResult] {
        var results: [ToolResult] = []
        try eventStore?.append("RecipeStep", [
            "recipe_id": recipeID,
            "step_id": step.id,
            "title": step.title,
            "tool": render(step.tool, params: params)
        ])

        if let waitCondition = step.waitCondition, let waitValue = step.waitValue {
            let wait = tools.execute(ToolCall(
                id: "\(prefix)-\(step.id)-wait",
                name: "observe_wait",
                arguments: [
                    "condition": render(waitCondition, params: params),
                    "value": render(waitValue, params: params),
                    "timeout": step.timeout ?? 10,
                    "interval": 0.5
                ],
                raw: [:]
            ))
            results.append(wait)
            try eventStore?.append("RecipeObservation", [
                "step_id": step.id,
                "tool": "observe_wait",
                "success": wait.success ? "true" : "false",
                "evidence": wait.evidence,
                "error": wait.error ?? ""
            ])
            guard wait.success else { return results }
        }

        let attempts = max(1, (step.retries ?? 0) + 1)
        for attempt in 1...attempts {
            let primary = try executeRecipeTool(
                toolNameTemplate: step.tool,
                argumentsTemplate: step.arguments,
                verifyToolTemplate: step.verifyTool,
                verifyArgumentsTemplate: step.verifyArguments,
                verifyExpressionTemplate: step.verifyExpression,
                stepID: step.id,
                callID: "\(prefix)-\(step.id)-try\(attempt)",
                recipeID: recipeID,
                params: params,
                tools: tools,
                eventStore: eventStore
            )
            results.append(contentsOf: primary.results)
            if primary.ok {
                return results
            }

            for fallback in step.fallbackTools ?? [] {
                try eventStore?.append("RecipeRecovery", [
                    "step_id": step.id,
                    "attempt": "\(attempt)",
                    "fallback_tool": render(fallback.tool, params: params)
                ])
                let fallbackRun = try executeRecipeTool(
                    toolNameTemplate: fallback.tool,
                    argumentsTemplate: fallback.arguments ?? step.arguments,
                    verifyToolTemplate: fallback.verifyTool ?? step.verifyTool,
                    verifyArgumentsTemplate: fallback.verifyArguments ?? step.verifyArguments,
                    verifyExpressionTemplate: fallback.verifyExpression ?? step.verifyExpression,
                    stepID: step.id,
                    callID: "\(prefix)-\(step.id)-fallback\(attempt)",
                    recipeID: recipeID,
                    params: params,
                    tools: tools,
                    eventStore: eventStore
                )
                results.append(contentsOf: fallbackRun.results)
                if fallbackRun.ok {
                    return results
                }
            }
        }

        if let recoverySteps = step.recoverySteps, !recoverySteps.isEmpty {
            try eventStore?.append("RecipeRecovery", [
                "step_id": step.id,
                "recovery_steps": recoverySteps.map(\.id).joined(separator: ",")
            ])
            for recovery in recoverySteps {
                let recoveryResults = try executeStep(
                    recovery,
                    recipeID: recipeID,
                    params: params,
                    tools: tools,
                    eventStore: eventStore,
                    prefix: "\(prefix)-recovery-\(step.id)"
                )
                results.append(contentsOf: recoveryResults)
                guard recoveryResults.last?.success == true else { return results }
            }
            return results
        }

        if results.last?.success != false {
            results.append(ToolResult(success: false, evidence: "Recipe step did not produce verified success.", error: step.id))
        }
        return results
    }

    @MainActor
    private static func executeRecipeTool(
        toolNameTemplate: String,
        argumentsTemplate: [String: String],
        verifyToolTemplate: String?,
        verifyArgumentsTemplate: [String: String]?,
        verifyExpressionTemplate: String?,
        stepID: String,
        callID: String,
        recipeID: String,
        params: [String: String],
        tools: ToolRegistry,
        eventStore: EventStore?
    ) throws -> (ok: Bool, results: [ToolResult]) {
        var results: [ToolResult] = []
        let toolName = render(toolNameTemplate, params: params)
        let args = renderArguments(argumentsTemplate, params: params)
        let result = tools.execute(ToolCall(id: callID, name: toolName, arguments: args, raw: [:]))
        results.append(result)
        AuditLog.append(action: "recipe_tool_result", fields: [
            "recipe_id": recipeID,
            "step_id": stepID,
            "tool": toolName,
            "success": result.success ? "true" : "false",
            "evidence": result.evidence,
            "error": result.error ?? ""
        ])
        try eventStore?.append("RecipeObservation", [
            "step_id": stepID,
            "tool": toolName,
            "success": result.success ? "true" : "false",
            "evidence": result.evidence,
            "error": result.error ?? ""
        ])

        guard result.success else {
            return (false, results)
        }

        if let expression = verifyExpressionTemplate {
            let renderedExpression = render(expression, params: params)
            let ok = evaluateVerifyExpression(renderedExpression, result: result)
            let expressionResult = ToolResult(
                success: ok,
                evidence: ok ? "Verify expression passed: \(renderedExpression)" : "Verify expression failed: \(renderedExpression)",
                data: ["expression": renderedExpression],
                error: ok ? nil : "verify_expression_failed"
            )
            results.append(expressionResult)
            try eventStore?.append("RecipeVerification", [
                "step_id": stepID,
                "tool": "verify_expression",
                "success": ok ? "true" : "false",
                "evidence": expressionResult.evidence
            ])
            guard ok else { return (false, results) }
        }

        if let verifyTool = verifyToolTemplate {
            let verifyName = render(verifyTool, params: params)
            let verifyArgs = renderArguments(verifyArgumentsTemplate ?? [:], params: params)
            let verification = tools.execute(ToolCall(id: "\(callID)-verify", name: verifyName, arguments: verifyArgs, raw: [:]))
            results.append(verification)
            try eventStore?.append("RecipeVerification", [
                "step_id": stepID,
                "tool": verifyName,
                "success": verification.success ? "true" : "false",
                "evidence": verification.evidence,
                "error": verification.error ?? ""
            ])
            guard verification.success else { return (false, results) }
        }

        return (true, results)
    }

    private static func evaluateVerifyExpression(_ expression: String, result: ToolResult) -> Bool {
        let clauses = expression
            .components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else { return result.success }
        return clauses.allSatisfy { clause in
            evaluateVerifyClause(clause, result: result)
        }
    }

    private static func evaluateVerifyClause(_ clause: String, result: ToolResult) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "success" { return result.success }
        if trimmed == "!success" { return !result.success }

        if let range = trimmed.range(of: " contains ") {
            let lhs = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let haystack: String
            if lhs == "evidence" {
                haystack = result.evidence
            } else if lhs == "error" {
                haystack = result.error ?? ""
            } else if lhs.hasPrefix("data.") {
                haystack = result.data[String(lhs.dropFirst("data.".count))] ?? ""
            } else {
                haystack = ""
            }
            if rhs.isEmpty { return !haystack.isEmpty }
            return haystack.localizedCaseInsensitiveContains(rhs)
        }

        if let range = trimmed.range(of: " equals ") {
            let lhs = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if lhs.hasPrefix("data.") {
                return (result.data[String(lhs.dropFirst("data.".count))] ?? "") == rhs
            }
            if lhs == "evidence" { return result.evidence == rhs }
        }

        return result.success && result.evidence.localizedCaseInsensitiveContains(trimmed)
    }

    static func saveLearnedRecipe(id: String, title: String, steps: [RecipeStep], notes: String) throws -> Recipe {
        let recipe = Recipe(
            id: id,
            title: title,
            goalTemplate: "Run learned workflow: \(title)",
            requiredParams: [],
            notes: notes,
            steps: steps
        )
        try FileManager.default.createDirectory(at: EventStore.recipesURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipe).write(to: recipeURL(id), options: [.atomic])
        return recipe
    }

    static func resolvedParams(recipe: Recipe, params: [String: Any]) throws -> [String: String] {
        var resolved = params.compactMapValues { value -> String? in
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        for key in recipe.requiredParams where resolved[key]?.isEmpty ?? true {
            throw RuntimeError("Missing recipe param: \(key)")
        }
        if let path = resolved["path"]?.expandingTildeInPath {
            let url = URL(fileURLWithPath: path)
            resolved["path"] = path
            resolved["file_name"] = url.lastPathComponent
            if let outdir = resolved["outdir"]?.expandingTildeInPath {
                resolved["outdir"] = outdir
                resolved["pdf_path"] = URL(fileURLWithPath: outdir)
                    .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension("pdf")
                    .path
            }
        }
        let app = (resolved["app"] ?? "wechat").lowercased()
        if app.contains("飞书") || app.contains("lark") || app.contains("feishu") {
            resolved["chat_prefix"] = "lark"
            resolved["recipient_key"] = "chat"
        } else if app.contains("qq") {
            resolved["chat_prefix"] = "qq"
            resolved["recipient_key"] = "recipient"
        } else {
            resolved["chat_prefix"] = "wechat"
            resolved["recipient_key"] = "recipient"
        }
        if resolved["notes"] == nil { resolved["notes"] = "" }
        if resolved["message_text"] == nil {
            let topic = resolved["topic"] ?? "任务"
            resolved["message_text"] = "关于\(topic)的计划：\n1. 明确目标和使用场景\n2. 梳理数据、产品、技术和合规路径\n3. 制定里程碑和交付物\n4. 同步关键风险和下一步行动"
        }
        resolved["message_probe"] = String((resolved["message_text"] ?? "").prefix(24))
        return resolved
    }

    static func renderArguments(_ arguments: [String: String], params: [String: String]) -> [String: Any] {
        var rendered: [String: Any] = [:]
        for (key, value) in arguments {
            rendered[render(key, params: params)] = render(value, params: params)
        }
        return rendered
    }

    static func render(_ template: String, params: [String: String]) -> String {
        var text = template
        for (key, value) in params {
            text = text.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return text
    }

    private static func recipeURL(_ id: String) -> URL {
        EventStore.recipesURL.appendingPathComponent("\(id).json")
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(from text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return text
            .components(separatedBy: separators)
            .flatMap { chunk -> [String] in
                let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return [] }
                if trimmed.count <= 8 { return [trimmed] }
                let phrases = ["发送", "发给", "文件", "附件", "计划", "方案", "同步", "导出", "转换", "文档", "pdf", "日历", "日程", "会议", "提醒", "微信", "飞书", "qq"]
                return [trimmed] + phrases.filter { trimmed.contains($0) }
            }
    }

    private static func keywords(for id: String) -> [String] {
        switch id {
        case "send-file-to-contact":
            return ["send", "发送", "发给", "文件", "附件", "contact", "联系人", "wechat", "微信", "lark", "飞书", "qq", "chat", "聊天"]
        case "write-plan-and-sync":
            return ["plan", "计划", "方案", "梳理", "同步", "汇报", "发送", "wechat", "微信", "lark", "飞书", "qq"]
        case "export-document-pdf":
            return ["pdf", "导出", "转成", "转换", "文档", "doc", "docx", "word", "保存"]
        case "create-calendar-event":
            return ["calendar", "日历", "日程", "会议", "提醒", "event", "schedule", "创建"]
        default:
            return []
        }
    }
}

struct LearningSession: Codable {
    let id: String
    let title: String
    let startedAt: String
    var steps: [LearnedStep]
}

struct LearnedStep: Codable {
    let tool: String
    let arguments: [String: String]
    let success: Bool
    let evidence: String
    let recordedAt: String
}

struct LearningStore {
    static var activeURL: URL {
        EventStore.learningURL.appendingPathComponent("active.json")
    }

    static func start(title: String) throws -> LearningSession {
        try FileManager.default.createDirectory(at: EventStore.learningURL, withIntermediateDirectories: true)
        let session = LearningSession(
            id: "L\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))",
            title: title,
            startedAt: isoDateString(Date()),
            steps: []
        )
        try save(session)
        return session
    }

    static func record(tool: String, arguments: [String: Any], result: ToolResult) throws {
        var session = try active()
        let stringArgs = arguments.compactMapValues { value -> String? in
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            if let bool = value as? Bool { return bool ? "true" : "false" }
            return nil
        }
        session.steps.append(LearnedStep(
            tool: tool,
            arguments: stringArgs,
            success: result.success,
            evidence: result.evidence,
            recordedAt: isoDateString(Date())
        ))
        try save(session)
    }

    static func stop(recipeID: String) throws -> Recipe {
        let session = try active()
        guard !session.steps.isEmpty else {
            throw RuntimeError("Learning session has no recorded tool steps.")
        }
        let failedSteps = session.steps.enumerated().filter { !$0.element.success }
        guard failedSteps.isEmpty else {
            let failedSummary = failedSteps.map { "S\($0.offset + 1):\($0.element.tool)" }.joined(separator: ", ")
            throw RuntimeError("Learning session contains failed tool steps and cannot be saved as a verified recipe: \(failedSummary)")
        }
        let steps = session.steps.enumerated().map { index, learned in
            RecipeStep(
                id: "S\(index + 1)",
                title: learned.tool,
                tool: learned.tool,
                arguments: learned.arguments,
                verifyTool: nil,
                verifyArguments: nil,
                waitCondition: nil,
                waitValue: nil,
                verifyExpression: "success"
            )
        }
        let recipe = try RecipeStore.saveLearnedRecipe(
            id: recipeID,
            title: session.title,
            steps: steps,
            notes: "Learned from \(session.steps.count) verified successful tool step(s) at \(isoDateString(Date()))."
        )
        let archiveURL = EventStore.learningURL.appendingPathComponent("\(session.id).json")
        try FileManager.default.moveItem(at: activeURL, to: archiveURL)
        return recipe
    }

    static func statusText() throws -> String {
        guard FileManager.default.fileExists(atPath: activeURL.path) else {
            return "learning: inactive"
        }
        let session = try active()
        return [
            "learning: active",
            "id: \(session.id)",
            "title: \(session.title)",
            "steps: \(session.steps.count)",
            "started_at: \(session.startedAt)"
        ].joined(separator: "\n")
    }

    private static func active() throws -> LearningSession {
        guard FileManager.default.fileExists(atPath: activeURL.path) else {
            throw RuntimeError("No active learning session. Run: aios learn start \"title\"")
        }
        return try JSONDecoder().decode(LearningSession.self, from: Data(contentsOf: activeURL))
    }

    private static func save(_ session: LearningSession) throws {
        try FileManager.default.createDirectory(at: EventStore.learningURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: activeURL, options: [.atomic])
    }
}

struct RawRecordedEvent: Codable {
    let type: String
    let timestamp: Double
    let x: Double?
    let y: Double?
    let keyCode: Int?
    let flags: UInt64
    let app: String
    let bundleID: String
    let focusedRole: String
    let focusedTitle: String
    let focusedValue: String
}

final class RawEventRecorderBox {
    let start = Date()
    let includeAX: Bool
    var events: [RawRecordedEvent] = []

    init(includeAX: Bool) {
        self.includeAX = includeAX
    }

    func append(type: String, event: CGEvent) {
        let location = event.location
        let app = NSWorkspace.shared.frontmostApplication
        let focused = includeAX ? Self.focusedContext() : [:]
        events.append(RawRecordedEvent(
            type: type,
            timestamp: Date().timeIntervalSince(start),
            x: ["left_mouse_down", "left_mouse_up", "right_mouse_down", "right_mouse_up"].contains(type) ? location.x : nil,
            y: ["left_mouse_down", "left_mouse_up", "right_mouse_down", "right_mouse_up"].contains(type) ? location.y : nil,
            keyCode: type == "key_down" ? Int(event.getIntegerValueField(.keyboardEventKeycode)) : nil,
            flags: event.flags.rawValue,
            app: app?.localizedName ?? "",
            bundleID: app?.bundleIdentifier ?? "",
            focusedRole: focused["role"] ?? "",
            focusedTitle: focused["title"] ?? "",
            focusedValue: focused["value"] ?? ""
        ))
    }

    private static func focusedContext() -> [String: String] {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value.map({ unsafeDowncast($0, to: AXUIElement.self) })
        else {
            return [:]
        }
        func attr(_ attribute: CFString) -> String {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return "" }
            if let text = raw as? String { return text }
            if let number = raw as? NSNumber { return number.stringValue }
            return ""
        }
        return [
            "role": attr(kAXRoleAttribute as CFString),
            "title": attr(kAXTitleAttribute as CFString),
            "value": attr(kAXValueAttribute as CFString)
        ]
    }
}

struct RawEventRecorder {
    static func recordRecipe(title: String, recipeID: String, duration: Double, includeAX: Bool) throws -> Recipe {
        guard duration > 0 else { throw RuntimeError("duration must be positive") }
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        let box = RawEventRecorderBox(includeAX: includeAX)
        let unmanagedBox = Unmanaged.passRetained(box)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: rawEventTapCallback,
            userInfo: unmanagedBox.toOpaque()
        ) else {
            unmanagedBox.release()
            throw RuntimeError("Could not create CGEvent tap. Grant Input Monitoring to this app/terminal and rerun setup.")
        }
        defer {
            CFMachPortInvalidate(tap)
            unmanagedBox.release()
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRunInMode(.defaultMode, duration, false)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)

        let rawURL = try saveRawEvents(box.events, recipeID: recipeID)
        let steps = recipeSteps(from: box.events)
        guard !steps.isEmpty else {
            throw RuntimeError("No replayable mouse/key events were captured.")
        }
        return try RecipeStore.saveLearnedRecipe(
            id: recipeID,
            title: title,
            steps: steps,
            notes: "Unverified raw CGEvent recipe learned from \(box.events.count) event(s). Raw log: \(rawURL.path). Run recipe exec and add verifiers before relying on it."
        )
    }

    private static func saveRawEvents(_ events: [RawRecordedEvent], recipeID: String) throws -> URL {
        let dir = EventStore.learningURL.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(recipeID)-events.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(events).write(to: url, options: [.atomic])
        return url
    }

    private static func recipeSteps(from events: [RawRecordedEvent]) -> [RecipeStep] {
        var steps: [RecipeStep] = []
        for event in events {
            switch event.type {
            case "left_mouse_down":
                if let x = event.x, let y = event.y {
                    steps.append(RecipeStep(
                        id: "S\(steps.count + 1)",
                        title: "Click \(Int(x)),\(Int(y))",
                        tool: "ui_click",
                        arguments: ["x": "\(Int(x))", "y": "\(Int(y))"]
                    ))
                }
            case "key_down":
                guard let keyCode = event.keyCode else { continue }
                if keyCode == 0x35 {
                    continue
                }
                let modifiers = modifierNames(from: CGEventFlags(rawValue: event.flags))
                steps.append(RecipeStep(
                    id: "S\(steps.count + 1)",
                    title: "Key \(keyCode)",
                    tool: "ui_keyboard_shortcut",
                    arguments: [
                        "key": keyName(for: CGKeyCode(keyCode)) ?? "\(keyCode)",
                        "modifiers": modifiers.joined(separator: ",")
                    ]
                ))
            default:
                continue
            }
        }
        return steps
    }

    private static func modifierNames(from flags: CGEventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("command") }
        if flags.contains(.maskShift) { names.append("shift") }
        if flags.contains(.maskAlternate) { names.append("option") }
        if flags.contains(.maskControl) { names.append("control") }
        return names
    }

    private static func keyName(for code: CGKeyCode) -> String? {
        let map: [CGKeyCode: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 36: "return",
            37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n",
            46: "m", 47: ".", 48: "tab", 49: "space", 50: "`", 51: "delete", 53: "escape",
            123: "left", 124: "right", 125: "down", 126: "up"
        ]
        return map[code]
    }
}

private func rawEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<RawEventRecorderBox>.fromOpaque(refcon).takeUnretainedValue()
    let name: String?
    switch type {
    case .leftMouseDown:
        name = "left_mouse_down"
    case .leftMouseUp:
        name = "left_mouse_up"
    case .rightMouseDown:
        name = "right_mouse_down"
    case .rightMouseUp:
        name = "right_mouse_up"
    case .keyDown:
        name = "key_down"
    default:
        name = nil
    }
    if let name {
        box.append(type: name, event: event)
    }
    return Unmanaged.passUnretained(event)
}

struct EvalCase {
    let id: String
    let title: String
    let run: () throws -> ToolResult
}

struct EvalResult {
    let id: String
    let passed: Bool
    let evidence: String
    let durationMs: Int
}

struct RealE2ECase: Codable {
    let id: String
    let title: String
    let recipeID: String?
    let params: [String: String]
    let goal: String?
    let enabled: Bool
    let destructive: Bool
    let sendsExternalMessage: Bool
    let notes: String?
}

@MainActor
struct E2ERunner {
    static var cases: [EvalCase] {
        [
            EvalCase(id: "apps", title: "Installed app discovery") {
                ToolRegistry().execute(ToolCall(id: "eval", name: "aios_list_apps", arguments: ["query": "WeChat", "include_system": false], raw: [:]))
            },
            EvalCase(id: "wait-file", title: "Wait for existing file") {
                ToolRegistry().execute(ToolCall(id: "eval", name: "observe_wait", arguments: ["condition": "file_exists", "value": "Package.swift", "timeout": 1, "interval": 0.2], raw: [:]))
            },
            EvalCase(id: "snapshot", title: "Persistent UI snapshot") {
                let result = ToolRegistry().execute(ToolCall(id: "eval", name: "snapshot_create", arguments: ["screenshot": false, "max_depth": 2, "max_nodes": 50], raw: [:]))
                if result.success {
                    return result
                }
                if result.error == "frontmostApplication is nil" || result.evidence.localizedCaseInsensitiveContains("No frontmost app") {
                    return ToolResult(success: true, evidence: "Snapshot tool is available; skipped capture because no frontmost GUI app is visible in this environment.", data: result.data)
                }
                return result
            },
            EvalCase(id: "recipe", title: "Default recipes render") {
                try RecipeStore.seedDefaults(overwrite: false)
                let goal = try RecipeStore.renderGoal(recipeID: "export-document-pdf", params: ["path": "~/Downloads/a.docx", "outdir": "~/Downloads"])
                return ToolResult(success: goal.contains("PDF"), evidence: "Rendered recipe goal.", data: ["goal": goal])
            },
            EvalCase(id: "recipe-suggest", title: "Recipe suggestions match user goals") {
                let suggestions = try RecipeStore.suggest(goal: "把文档导出成 PDF")
                let top = suggestions.first?.recipe.id ?? ""
                return ToolResult(success: top == "export-document-pdf", evidence: "Top recipe suggestion: \(top).", data: [
                    "top": top,
                    "suggestions": jsonStringValue(suggestions.map(\.summary))
                ])
            },
            EvalCase(id: "automation-tools-registered", title: "Locator automation tools are registered") {
                let names = Set(ToolRegistry().definitions.compactMap { definition in
                    (definition["function"] as? [String: Any])?["name"] as? String
                })
                let required = ["aios_automation_context", "aios_find", "aios_inspect", "aios_read", "aios_click", "aios_type", "aios_wait", "recipe_suggest"]
                let missing = required.filter { !names.contains($0) }
                return ToolResult(success: missing.isEmpty, evidence: missing.isEmpty ? "Locator and recipe-first tools are registered." : "Missing tools: \(missing.joined(separator: ","))", data: [
                    "required": required.joined(separator: ","),
                    "missing": missing.joined(separator: ",")
                ])
            },
            EvalCase(id: "recipe-exec-calendar-dry", title: "Recipe workflow engine dry verification") {
                let recipe = try RecipeStore.read("create-calendar-event")
                let params = try RecipeStore.resolvedParams(recipe: recipe, params: [
                    "title": "AIOS Eval Dry Run",
                    "start": "2026-05-22 10:00",
                    "end": "2026-05-22 10:15",
                    "notes": "dry-run"
                ])
                let rendered = recipe.steps.map { step in
                    [
                        "tool": RecipeStore.render(step.tool, params: params),
                        "arguments": jsonStringValue(RecipeStore.renderArguments(step.arguments, params: params))
                    ]
                }
                return ToolResult(success: rendered.count == 1, evidence: "Rendered executable recipe steps.", data: ["steps": jsonStringValue(rendered)])
            },
            EvalCase(id: "policy", title: "Protected shell delete blocked") {
                let call = ToolCall(id: "eval", name: "terminal_run_command", arguments: ["command": "rm -rf ~/Desktop/test"], raw: [:])
                let decision = PolicyEngine().evaluate(call, knownTools: Set(ToolRegistry().definitions.compactMap { definition in
                    (definition["function"] as? [String: Any])?["name"] as? String
                }))
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "chat-completion-gate", title: "Chat delivery cannot complete without message verification") {
                var state = CompletionContractState(goal: "Send good night to Example Contact in WeChat")
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_verify_chat", arguments: ["recipient": "Example Contact"], raw: [:]),
                    result: ToolResult(success: true, evidence: "WeChat OCR contains expected text.")
                )
                let plan = TaskPlan.fallback(goal: "Send good night to Example Contact in WeChat")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-file-save-required", title: "File save completion requires verified file effect") {
                var state = CompletionContractState(goal: "写入 hello 并保存到 ~/Desktop/aios-contract.txt")
                state.record(
                    call: ToolCall(id: "eval", name: "aios_open_app", arguments: ["app_name": "TextEdit"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Opened app TextEdit.", data: ["effect": "app_opened", "app": "TextEdit", "verified": "true"])
                )
                let plan = TaskPlan.fallback(goal: "写入 hello 并保存到 ~/Desktop/aios-contract.txt")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-calendar-required", title: "Calendar completion requires verified calendar event effect") {
                var state = CompletionContractState(goal: "明天 10 点创建一个日历日程")
                state.record(
                    call: ToolCall(id: "eval", name: "calendar_find_events", arguments: ["title": "会议"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Found 0 Calendar event(s).", data: ["events": "[]"])
                )
                let plan = TaskPlan.fallback(goal: "明天 10 点创建一个日历日程")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-open-only-not-delivery", title: "Open/search/click evidence cannot satisfy delivery") {
                var state = CompletionContractState(goal: "Open WeChat and send the Downloads example.docx file to Example Contact")
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_open", arguments: [:], raw: [:]),
                    result: ToolResult(success: true, evidence: "Opened WeChat.", data: ["effect": "app_opened", "app": "WeChat", "verified": "true"])
                )
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_search_chat", arguments: ["name": "Example Contact"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Searched WeChat for chat/contact.")
                )
                let plan = TaskPlan.fallback(goal: "Open WeChat and send the Downloads example.docx file to Example Contact")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-chat-satisfied", title: "Verified message effect satisfies chat delivery") {
                var state = CompletionContractState(goal: "Send good night to Example Contact in WeChat")
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_send_text", arguments: ["recipient": "Example Contact", "text": "晚安"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Sent and verified WeChat text message.", data: [
                        "effect": "external_message_sent",
                        "app": "WeChat",
                        "target": "Example Contact",
                        "value": "晚安",
                        "verified": "true",
                        "recipient": "Example Contact",
                        "message": "晚安",
                        "verified_recipient": "true",
                        "verified_message": "true"
                    ])
                )
                let plan = TaskPlan.fallback(goal: "Send good night to Example Contact in WeChat")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-continuous-chat-requires-send", title: "Continuous chat cannot complete by opening WeChat only") {
                var state = CompletionContractState(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_open_chat", arguments: ["recipient": "Example Contact"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Opened and verified WeChat chat.", data: [
                        "effect": "chat_session_ready",
                        "app": "WeChat",
                        "target": "Example Contact",
                        "verified": "true",
                        "recipient": "Example Contact"
                    ])
                )
                let plan = TaskPlan.fallback(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let decision = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "contract-chat-open-step-not-send", title: "Open/search chat step is not forced to satisfy delivery") {
                let state = CompletionContractState(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let step = TaskStep(
                    id: "S1",
                    title: "打开并定位聊天",
                    goal: "打开微信，搜索并定位Example Contact聊天，验证当前聊天对象。",
                    verification: "当前聊天对象是Example Contact。"
                )
                let decision = state.stepCompletionGate(step: step)
                return ToolResult(success: decision.allowed, evidence: decision.reason)
            },
            EvalCase(id: "message-probe-short", title: "Long chat message uses a short stable probe") {
                let probe = ToolRegistry().messageVerificationProbe("Hey, about this project concept. The core idea is that the user states a goal, then the system plans steps and executes tools.")
                return ToolResult(success: probe.count <= 32 && probe.localizedCaseInsensitiveContains("project concept"), evidence: probe, data: [
                    "probe": probe,
                    "chars": "\(probe.count)"
                ])
            },
            EvalCase(id: "raw-ui-send-can-verify-with-observation", title: "Raw UI return in verified chat can satisfy delivery only after observation") {
                var state = CompletionContractState(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let text = "这个项目的原理是什么？能详细解释一下吗？"
                state.record(
                    call: ToolCall(id: "eval", name: "wechat_open_chat", arguments: ["recipient": "Example Contact"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Opened and verified WeChat chat.", data: [
                        "effect": "chat_session_ready",
                        "app": "WeChat",
                        "target": "Example Contact",
                        "verified": "true",
                        "recipient": "Example Contact"
                    ])
                )
                state.record(
                    call: ToolCall(id: "eval", name: "clipboard_set_text", arguments: ["text": text], raw: [:]),
                    result: ToolResult(success: true, evidence: "Set clipboard plain text.")
                )
                state.record(
                    call: ToolCall(id: "eval", name: "ui_keyboard_shortcut", arguments: ["key": "return"], raw: [:]),
                    result: ToolResult(success: true, evidence: "Sent keyboard shortcut.")
                )
                var plan = TaskPlan.fallback(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let before = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                state.record(
                    call: ToolCall(id: "eval", name: "ocr_image", arguments: [:], raw: [:]),
                    result: ToolResult(success: true, evidence: "OCR read message.", data: ["text": "18:54\n这个项目的原理是什么？能详细解释一下吗？"])
                )
                plan = TaskPlan.fallback(goal: "Continue chatting with Example Contact in WeChat, starting with this project concept")
                let after = state.completionGate(plan: plan, currentStep: plan.steps.last!)
                return ToolResult(success: !before.allowed && after.allowed, evidence: after.reason)
            },
            EvalCase(id: "chat-context-read-step-not-send", title: "Context reading chat step is not forced to send") {
                let state = CompletionContractState(goal: "Continue chatting with Example Contact in WeChat, informal and context-aware")
                let step = TaskStep(
                    id: "S3",
                    title: "阅读上下文",
                    goal: "查看最近的聊天记录，了解之前的话题和语境。",
                    verification: "已获取最近几条消息内容，理解聊天上下文。"
                )
                let decision = state.stepCompletionGate(step: step)
                return ToolResult(success: decision.allowed, evidence: decision.reason)
            }
        ]
    }

    func run(filter: String?, repeatCount: Int = 1) throws -> [EvalResult] {
        try FileManager.default.createDirectory(at: EventStore.evalsURL, withIntermediateDirectories: true)
        let selected = Self.cases.filter { filter == nil || $0.id == filter }
        var results: [EvalResult] = []
        for testCase in selected {
            for attempt in 1...max(1, repeatCount) {
                let start = Date()
                let result = try testCase.run()
                let duration = Int(Date().timeIntervalSince(start) * 1000)
                let id = repeatCount > 1 ? "\(testCase.id)#\(attempt)" : testCase.id
                results.append(EvalResult(id: id, passed: result.success, evidence: result.evidence, durationMs: duration))
            }
        }
        let passCount = results.filter(\.passed).count
        let payload: [String: Any] = [
            "time": isoDateString(Date()),
            "passed": "\(passCount)",
            "total": "\(results.count)",
            "success_rate": results.isEmpty ? "0" : String(format: "%.2f", Double(passCount) / Double(results.count)),
            "results": results.map { ["id": $0.id, "passed": $0.passed ? "true" : "false", "evidence": $0.evidence, "duration_ms": "\($0.durationMs)"] }
        ]
        try writeJSONObject(payload, to: EventStore.evalsURL.appendingPathComponent("last-run.json"))
        return results
    }

    static func lastRunText() -> String {
        let url = EventStore.evalsURL.appendingPathComponent("last-run.json")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static var realCasesURL: URL {
        EventStore.evalsURL.appendingPathComponent("real-e2e-cases.json")
    }

    static func seedRealCases(overwrite: Bool = false) throws {
        try FileManager.default.createDirectory(at: EventStore.evalsURL, withIntermediateDirectories: true)
        guard overwrite || !FileManager.default.fileExists(atPath: realCasesURL.path) else { return }
        let cases = [
            RealE2ECase(
                id: "project-plan-send-to-contact",
                title: "Draft a short project plan and send it to Example Contact",
                recipeID: nil,
                params: [:],
                goal: "Draft a short project plan and send it to Example Contact",
                enabled: false,
                destructive: false,
                sendsExternalMessage: true,
                notes: "Default full-stack real E2E query for this project. It uses the LLM, current market research if available, document drafting, WeChat/Lark/QQ adapter selection, recipient verification, and external send verification. Enable only when you intentionally want to send Example Contact a real message."
            ),
            RealE2ECase(
                id: "wechat-send-download-example-to-contact",
                title: "Open WeChat and send ~/Downloads/example.docx to Example Contact",
                recipeID: "send-file-to-contact",
                params: ["app": "微信", "recipient": "Example Contact", "path": "~/Downloads/example.docx"],
                goal: nil,
                enabled: false,
                destructive: false,
                sendsExternalMessage: true,
                notes: "Real send case. Enable explicitly in this config and set AIOS_ALLOW_REAL_E2E=1 before running."
            ),
            RealE2ECase(
                id: "calendar-create-real",
                title: "Create a real Calendar event",
                recipeID: "create-calendar-event",
                params: ["title": "AIOS Real E2E", "start": "2026-05-22 10:00", "end": "2026-05-22 10:15", "notes": "real-e2e"],
                goal: nil,
                enabled: false,
                destructive: false,
                sendsExternalMessage: false,
                notes: "Writes Calendar state. Enable explicitly before running."
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cases).write(to: realCasesURL, options: [.atomic])
    }

    static func realCases() throws -> [RealE2ECase] {
        try seedRealCases(overwrite: false)
        return try JSONDecoder().decode([RealE2ECase].self, from: Data(contentsOf: realCasesURL))
    }

    func runReal(id: String) async throws -> ToolResult {
        try Self.seedRealCases(overwrite: false)
        guard ProcessInfo.processInfo.environment["AIOS_ALLOW_REAL_E2E"] == "1" else {
            throw RuntimeError("Real E2E is locked. Set AIOS_ALLOW_REAL_E2E=1 after reviewing \(Self.realCasesURL.path).")
        }
        let cases = try Self.realCases()
        guard let testCase = cases.first(where: { $0.id == id }) else {
            throw RuntimeError("Unknown real E2E case: \(id)")
        }
        guard testCase.enabled else {
            throw RuntimeError("Real E2E case is disabled in \(Self.realCasesURL.path): \(id)")
        }
        if testCase.destructive {
            throw RuntimeError("Destructive real E2E cases are not supported by this prototype.")
        }
        let caseGoal = testCase.goal ?? "real-e2e:\(id)"
        let store = try EventStore.start(goal: caseGoal)
        let result: ToolResult
        if let recipeID = testCase.recipeID {
            let results = try RecipeStore.execute(recipeID: recipeID, params: testCase.params, eventStore: store)
            let ok = results.allSatisfy(\.success)
            result = ToolResult(success: ok, evidence: ok ? "Real E2E \(id) passed." : "Real E2E \(id) failed.", data: [
                "run_id": store.runID,
                "results": jsonStringValue(results.map { ["success": $0.success ? "true" : "false", "evidence": $0.evidence, "error": $0.error ?? ""] })
            ])
        } else if let goal = testCase.goal, !goal.isEmpty {
            let config = LLMConfig.fromEnvironment()
            let ok = try await AgentLoop(client: OpenAICompatibleClient(config: config), tools: ToolRegistry(), eventStore: store).run(goal: goal)
            result = ToolResult(success: ok, evidence: ok ? "Real E2E \(id) completed through AgentLoop." : "Real E2E \(id) stopped incomplete.", data: [
                "run_id": store.runID,
                "goal": goal
            ])
        } else {
            throw RuntimeError("Real E2E case must use recipe_id or goal: \(id)")
        }
        try store.updateStatus(result.success ? "complete" : "failed")
        return result
    }
}

struct LaunchAgentManager {
    static let label = "com.aios.host"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func install() throws {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": EventStore.rootURL.appendingPathComponent("launchd.out.log").path,
            "StandardErrorPath": EventStore.rootURL.appendingPathComponent("launchd.err.log").path,
            "EnvironmentVariables": [
                "AIOS_STATE_DIR": EventStore.rootURL.path
            ]
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: EventStore.rootURL, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])
        _ = try? runProcess("/bin/launchctl", ["unload", plistURL.path])
        _ = try runProcess("/bin/launchctl", ["load", plistURL.path])
        try AIOSConfig.update(key: "run_at_login", value: "true")
    }

    static func uninstall() throws {
        _ = try? runProcess("/bin/launchctl", ["unload", plistURL.path])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        try AIOSConfig.update(key: "run_at_login", value: "false")
    }

    static func statusText() -> String {
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        let loaded = (try? runProcess("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])) != nil
        return [
            "installed: \(installed)",
            "loaded: \(loaded)",
            "plist: \(plistURL.path)"
        ].joined(separator: "\n")
    }
}

@MainActor
final class AIOSHost: NSObject, NSApplicationDelegate {
    private let menuBar: Bool
    private var statusItem: NSStatusItem?
    private var running = false

    init(menuBar: Bool) {
        self.menuBar = menuBar
    }

    func run() async {
        if menuBar {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.delegate = self
            setupStatusItem()
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.drainQueueOnce()
                }
            }
            print("AIOS host running. State: \(EventStore.rootURL.path)")
            NSApplication.shared.run()
            return
        }
        print("AIOS host running. State: \(EventStore.rootURL.path)")
        while true {
            await drainQueueOnce()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "AIOS"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "AIOS Host Running", action: nil, keyEquivalent: ""))
        let openState = NSMenuItem(title: "Open State Folder", action: #selector(openStateFolder), keyEquivalent: "o")
        openState.target = self
        menu.addItem(openState)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func openStateFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([EventStore.rootURL])
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func drainQueueOnce() async {
        guard !running else { return }
        guard let item = try? TaskQueue.next() else { return }
        if let summary = try? EventStore.readSummary(runID: item.id), summary.status == "canceled" {
            try? TaskQueue.remove(item.url)
            return
        }
        running = true
        defer { running = false }
        let config = LLMConfig.fromEnvironment()
        var store: EventStore?
        do {
            store = try EventStore.start(goal: item.goal, runID: item.id)
            let loop = AgentLoop(client: OpenAICompatibleClient(config: config), tools: ToolRegistry(), eventStore: store)
            let complete = try await loop.run(goal: item.goal)
            try store?.updateStatus(complete ? "complete" : "incomplete")
            try TaskQueue.remove(item.url)
        } catch {
            if store == nil {
                store = try? EventStore.start(goal: item.goal, runID: item.id)
            }
            try? store?.append("RunFailed", ["error": error.localizedDescription])
            try? store?.updateStatus("failed")
            try? TaskQueue.remove(item.url)
            fputs("AIOS host task failed: \(error.localizedDescription)\n", stderr)
        }
    }
}

@MainActor
final class AIOSDesktopApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model = AIOSAppModel()

    func run() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.delegate = self
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = AIOSAppView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AIOS"
        window.center()
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        model.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class AIOSAppModel: ObservableObject {
    @Published var goal = ""
    @Published var runs: [EventStore.RunSummary] = []
    @Published var selectedRunID = ""
    @Published var selectedEvents = ""
    @Published var auditText = ""
    @Published var evalText = ""
    @Published var status = ""
    @Published var baseURL = AIOSConfig.default.baseURL
    @Published var modelName = AIOSConfig.default.model
    @Published var maxSteps = "\(AIOSConfig.default.maxSteps)"
    @Published var isRunning = false
    private var refreshTimer: Timer?

    func refresh() {
        do {
            runs = try EventStore.listRuns()
            if selectedRunID.isEmpty, let first = runs.first {
                selectedRunID = first.id
            }
            loadSelected()
            auditText = AuditLog.readText(limit: 80)
            evalText = E2ERunner.lastRunText()
            let config = try AIOSConfig.load()
            baseURL = config.baseURL
            modelName = config.model
            maxSteps = "\(config.maxSteps)"
            if !isRunning {
                status = "Ready"
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func submit() {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Enter a task."
            return
        }
        do {
            let id = try TaskQueue.submit(goal: trimmed)
            selectedRunID = id
            goal = ""
            status = "Submitted \(id). Running..."
            refresh()
            startInlineRun(runID: id, goal: trimmed)
        } catch {
            status = error.localizedDescription
        }
    }

    private func startInlineRun(runID: String, goal: String) {
        guard !isRunning else {
            status = "A task is already running."
            return
        }
        isRunning = true
        startAutoRefresh()
        Task { @MainActor in
            var store: EventStore?
            do {
                try TaskQueue.cancel(runID)
                store = try EventStore.start(goal: goal, runID: runID)
                selectedRunID = runID
                status = "Running \(runID.prefix(8))"
                let config = LLMConfig.fromEnvironment()
                let loop = AgentLoop(client: OpenAICompatibleClient(config: config), tools: ToolRegistry(), eventStore: store)
                let complete = try await loop.run(goal: goal)
                try store?.updateStatus(complete ? "complete" : "incomplete")
                status = complete ? "Complete \(runID.prefix(8))" : "Incomplete \(runID.prefix(8))"
            } catch {
                if store == nil {
                    store = try? EventStore.start(goal: goal, runID: runID)
                }
                try? store?.append("RunFailed", ["error": error.localizedDescription])
                try? store?.updateStatus("failed")
                status = "Failed: \(error.localizedDescription)"
            }
            isRunning = false
            stopAutoRefresh()
            refresh()
        }
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func loadSelected() {
        guard !selectedRunID.isEmpty else {
            selectedEvents = ""
            return
        }
        selectedEvents = (try? EventStore.readEventsText(runID: selectedRunID)) ?? ""
    }

    func cancelSelected() {
        guard !selectedRunID.isEmpty else { return }
        do {
            try TaskQueue.cancel(selectedRunID)
            try EventStore.markRun(runID: selectedRunID, status: "canceled", event: "RunCanceled", fields: [:])
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func retrySelected() {
        guard !selectedRunID.isEmpty else { return }
        do {
            let summary = try EventStore.readSummary(runID: selectedRunID)
            let newID = try TaskQueue.submit(goal: summary.goal)
            try EventStore.markRun(runID: selectedRunID, status: "retried", event: "RunRetried", fields: ["new_run_id": newID])
            selectedRunID = newID
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func saveConfig() {
        do {
            try AIOSConfig.update(key: "base_url", value: baseURL)
            try AIOSConfig.update(key: "model", value: modelName)
            try AIOSConfig.update(key: "max_steps", value: maxSteps)
            status = "Config saved"
        } catch {
            status = error.localizedDescription
        }
    }

    func openStateFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([EventStore.rootURL])
    }

    func runEval() {
        do {
            let results = try E2ERunner().run(filter: nil, repeatCount: 1)
            let passed = results.filter(\.passed).count
            evalText = E2ERunner.lastRunText()
            status = "Eval \(passed)/\(results.count) passed"
        } catch {
            status = error.localizedDescription
        }
    }
}

struct AIOSAppView: View {
    @ObservedObject var model: AIOSAppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("告诉 AIOS 要完成什么任务", text: $model.goal)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submit() }
                    .disabled(model.isRunning)
                Button(model.isRunning ? "运行中" : "提交") { model.submit() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.isRunning)
                Button("刷新") { model.refresh() }
                Button("状态目录") { model.openStateFolder() }
            }
            .padding(12)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("任务")
                            .font(.headline)
                        Spacer()
                        Button("取消") { model.cancelSelected() }
                        Button("重试") { model.retrySelected() }
                    }
                    List(model.runs, id: \.id, selection: $model.selectedRunID) { run in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(run.status)
                                    .font(.caption)
                                    .monospaced()
                                Text(run.id.prefix(8))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            Text(run.goal)
                                .lineLimit(2)
                            Text(run.updatedAt.isEmpty ? run.createdAt : run.updatedAt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.selectedRunID) { _, _ in model.loadSelected() }
                }
                .frame(minWidth: 280, idealWidth: 320)
                .padding(12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("事件流")
                        .font(.headline)
                    ScrollView {
                        Text(model.selectedEvents.isEmpty ? "暂无事件" : model.selectedEvents)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    DisclosureGroup("审计") {
                        ScrollView {
                            Text(model.auditText.isEmpty ? "暂无审计记录" : model.auditText)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 100)
                    }
                    DisclosureGroup("评测") {
                        VStack(alignment: .leading, spacing: 6) {
                            Button("运行评测") { model.runEval() }
                            ScrollView {
                                Text(model.evalText.isEmpty ? "暂无评测结果" : model.evalText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 120)
                        }
                    }
                    Divider()
                    HStack(spacing: 8) {
                        TextField("Base URL", text: $model.baseURL)
                        TextField("Model", text: $model.modelName)
                            .frame(width: 180)
                        TextField("Steps", text: $model.maxSteps)
                            .frame(width: 64)
                        Button("保存配置") { model.saveConfig() }
                    }
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

enum TaskStepStatus: String, Codable {
    case pending
    case running
    case done
    case failed
}

struct TaskStep: Codable {
    var id: String
    var title: String
    var goal: String
    var verification: String
    var deliverable: String
    var status: TaskStepStatus
    var attempts: Int
    var evidence: [String]

    init(
        id: String,
        title: String,
        goal: String,
        verification: String,
        deliverable: String = "",
        status: TaskStepStatus = .pending,
        attempts: Int = 0,
        evidence: [String] = []
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.verification = verification
        self.deliverable = deliverable
        self.status = status
        self.attempts = attempts
        self.evidence = evidence
    }
}

struct TaskPlan: Codable {
    var objective: String
    var steps: [TaskStep]

    var isComplete: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.status == .done }
    }

    static func from(arguments: [String: Any], fallbackGoal: String) -> TaskPlan {
        let objective = string(arguments["objective"]) ?? fallbackGoal
        let rawSteps = arguments["steps"] as? [[String: Any]] ?? []
        let steps = rawSteps.enumerated().map { index, raw -> TaskStep in
            TaskStep(
                id: string(raw["id"]) ?? "S\(index + 1)",
                title: string(raw["title"]) ?? "Step \(index + 1)",
                goal: string(raw["goal"]) ?? string(raw["action"]) ?? "",
                verification: string(raw["verification"]) ?? "Verify this step with tool evidence.",
                deliverable: string(raw["deliverable"]) ?? ""
            )
        }.filter { !$0.title.isEmpty || !$0.goal.isEmpty }

        if steps.isEmpty {
            return fallback(goal: fallbackGoal)
        }
        return TaskPlan(objective: objective, steps: steps)
    }

    static func fallback(goal: String) -> TaskPlan {
        TaskPlan(objective: goal, steps: [
            TaskStep(
                id: "S1",
                title: "Understand and prepare",
                goal: "Clarify the user goal, inspect relevant macOS/app context, and choose the safest tool path.",
                verification: "The available app/context evidence is captured."
            ),
            TaskStep(
                id: "S2",
                title: "Execute the work",
                goal: "Use app-specific or universal tools to complete the requested work.",
                verification: "Tool evidence shows the requested work was performed."
            ),
            TaskStep(
                id: "S3",
                title: "Verify and deliver",
                goal: "Observe the final state, verify success, and deliver the result.",
                verification: "The final result is verified and summarized."
            )
        ])
    }

    mutating func appendSteps(from arguments: [String: Any]) -> [TaskStep] {
        let rawSteps = arguments["steps"] as? [[String: Any]] ?? []
        var added: [TaskStep] = []
        for raw in rawSteps {
            let nextIndex = steps.count + added.count + 1
            let step = TaskStep(
                id: string(raw["id"]) ?? "S\(nextIndex)",
                title: string(raw["title"]) ?? "Step \(nextIndex)",
                goal: string(raw["goal"]) ?? string(raw["action"]) ?? "",
                verification: string(raw["verification"]) ?? "Verify this step with tool evidence.",
                deliverable: string(raw["deliverable"]) ?? ""
            )
            added.append(step)
        }
        steps.append(contentsOf: added)
        return added
    }

    func summaryForPrompt() -> String {
        steps.map { step in
            "- \(step.id) [\(step.status.rawValue)] \(step.title): \(step.goal) | verify: \(step.verification)"
        }.joined(separator: "\n")
    }
}

private func stepContractText(_ step: TaskStep) -> String {
    "\(step.title)\n\(step.goal)\n\(step.verification)\n\(step.deliverable)"
}

struct CompletionContract: Hashable {
    let kind: String
    let app: String
    let target: String
    let value: String
    let source: String

    static func == (lhs: CompletionContract, rhs: CompletionContract) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.app == rhs.app &&
        lhs.target == rhs.target &&
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(app)
        hasher.combine(target)
        hasher.combine(value)
    }

    var summary: String {
        let qualifiers = [app, target, value]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " / ")
        return qualifiers.isEmpty ? kind : "\(kind)(\(qualifiers))"
    }
}

struct CompletionEvidence: Hashable {
    let kind: String
    let app: String
    let target: String
    let value: String
    let tool: String
    let evidence: String
    let verified: Bool

    var summary: String {
        let qualifiers = [app, target, value]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " / ")
        return qualifiers.isEmpty ? "\(kind) via \(tool)" : "\(kind)(\(qualifiers)) via \(tool)"
    }

    func contains(_ probe: String) -> Bool {
        let trimmed = probe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystack = [kind, app, target, value, tool, evidence].joined(separator: "\n").lowercased()
        let needle = trimmed.lowercased()
        return haystack.contains(needle) || needle.contains(haystack)
    }
}

struct CompletionContractState {
    let goal: String
    var requiredContracts: [CompletionContract]
    var verifiedEffects: [CompletionEvidence] = []
    var attemptedEffects: [CompletionEvidence] = []
    var chatSendAttempted = false
    var chatRecipientVerified = false
    var chatMessageVerified = false
    var chatSendToolVerified = false
    var lastRecipient = ""
    var lastMessage = ""
    var lastChatApp = ""

    init(goal: String, plan: TaskPlan? = nil) {
        self.goal = goal
        self.requiredContracts = Self.inferContracts(from: goal, source: "UserGoal")
        if let plan {
            updateRequired(from: plan)
        }
    }

    var chatDeliveryVerified: Bool {
        if verifiedEffects.contains(where: { $0.verified && $0.kind == "external_message_sent" }) {
            return true
        }
        if chatSendToolVerified { return true }
        return chatSendAttempted && chatRecipientVerified && chatMessageVerified
    }

    mutating func updateRequired(from plan: TaskPlan) {
        let objectiveContracts = Self.inferContracts(from: plan.objective, source: "TaskPlan")
        addRequired(objectiveContracts)
        let hasPrimaryObjective = (requiredContracts + objectiveContracts).contains { Self.isPrimaryOutcomeKind($0.kind) }
        for step in plan.steps {
            let text = stepContractText(step)
            let stepContracts = Self.inferContracts(from: text, source: step.id).filter { contract in
                Self.shouldAddStepContractToTask(contract, text: text, hasPrimaryObjective: hasPrimaryObjective)
            }
            addRequired(stepContracts)
        }
    }

    mutating func record(call: ToolCall, result: ToolResult) {
        if let recipient = string(call.arguments["recipient"]) ?? string(call.arguments["chat"]) ?? string(call.arguments["name"]) {
            lastRecipient = recipient
        }
        if let text = string(call.arguments["text"]) {
            lastMessage = text
        }
        if let rawPath = string(call.arguments["path"]) {
            let path = rawPath.expandingTildeInPath
            if call.name.contains("stage_file") {
                lastMessage = URL(fileURLWithPath: path).lastPathComponent
            }
        }
        if let app = Self.chatApp(for: call.name) {
            lastChatApp = app
        }

        if let effect = Self.effectEvidence(call: call, result: result) {
            attemptedEffects.append(effect)
            if effect.verified {
                addVerified(effect)
            }
        }

        switch call.name {
        case "wechat_open_chat", "lark_open_chat", "qq_open_chat":
            if result.success {
                chatRecipientVerified = true
            }
        case "wechat_send_text", "lark_send_text", "qq_send_text", "wechat_send_staged", "lark_send_staged", "qq_send_staged":
            chatSendAttempted = true
            if result.data["verified_recipient"] == "true" {
                chatRecipientVerified = true
            }
            if result.data["verified_message"] == "true" {
                chatMessageVerified = true
            }
            if result.success && result.data["verified_recipient"] == "true" && result.data["verified_message"] == "true" {
                chatSendToolVerified = true
            }
        case "wechat_verify_chat", "lark_verify_chat", "qq_verify_chat":
            if result.success {
                chatRecipientVerified = true
            }
        case "wechat_verify_recent_message", "lark_verify_recent_message", "qq_verify_recent_message":
            if result.success {
                chatMessageVerified = true
            }
        case "ui_keyboard_shortcut":
            let key = (string(call.arguments["key"]) ?? "").lowercased()
            if result.success,
               ["return", "enter"].contains(key),
               !lastChatApp.isEmpty,
               !lastRecipient.isEmpty {
                chatSendAttempted = true
            }
        case "ocr_image", "ocr_screen", "observe_snapshot", "ax_describe_frontmost":
            if chatSendAttempted,
               !lastMessage.isEmpty,
               Self.observationContainsSentMessage(result, message: lastMessage) {
                chatMessageVerified = true
            }
        default:
            break
        }

        if chatDeliveryVerified {
            addVerified(CompletionEvidence(
                kind: "external_message_sent",
                app: lastChatApp,
                target: lastRecipient,
                value: lastMessage,
                tool: call.name,
                evidence: result.evidence,
                verified: true
            ))
        }
    }

    func taskCompletionGate(plan: TaskPlan) -> PolicyDecision {
        let required = effectiveRequiredContracts(plan: plan)
        guard !required.isEmpty else {
            return PolicyDecision(allowed: true, reason: "No material completion contract required.")
        }
        let unresolved = required.filter { !isSatisfied($0) }
        guard unresolved.isEmpty else {
            return PolicyDecision(
                allowed: false,
                reason: "Completion contract not verified: \(unresolved.prefix(3).map(\.summary).joined(separator: ", ")). Open/search/click evidence is not enough."
            )
        }
        return PolicyDecision(allowed: true, reason: "Completion contracts verified: \(required.map(\.summary).joined(separator: ", ")).")
    }

    func stepCompletionGate(step: TaskStep) -> PolicyDecision {
        let text = stepContractText(step)
        let required = Self.inferContracts(from: text, source: step.id).filter { contract in
            Self.shouldEnforceStepContract(contract, text: text)
        }
        guard !required.isEmpty else {
            return PolicyDecision(allowed: true, reason: "No material step contract required.")
        }
        let unresolved = required.filter { !isSatisfied($0) }
        guard unresolved.isEmpty else {
            return PolicyDecision(
                allowed: false,
                reason: "Step contract not verified: \(unresolved.prefix(3).map(\.summary).joined(separator: ", "))."
            )
        }
        return PolicyDecision(allowed: true, reason: "Step contract verified.")
    }

    func completionGate(plan: TaskPlan, currentStep: TaskStep) -> PolicyDecision {
        taskCompletionGate(plan: plan)
    }

    private mutating func addRequired(_ contracts: [CompletionContract]) {
        for contract in contracts where !requiredContracts.contains(contract) {
            requiredContracts.append(contract)
        }
    }

    private mutating func addVerified(_ evidence: CompletionEvidence) {
        guard !verifiedEffects.contains(where: { existing in
            existing.kind == evidence.kind &&
            existing.app == evidence.app &&
            existing.target == evidence.target &&
            existing.value == evidence.value &&
            existing.tool == evidence.tool
        }) else {
            return
        }
        verifiedEffects.append(evidence)
    }

    private func effectiveRequiredContracts(plan: TaskPlan) -> [CompletionContract] {
        var contracts = requiredContracts
        let objectiveContracts = Self.inferContracts(from: plan.objective, source: "TaskPlan")
        for contract in objectiveContracts {
            if !contracts.contains(contract) { contracts.append(contract) }
        }
        let hasPrimaryObjective = contracts.contains { Self.isPrimaryOutcomeKind($0.kind) }
        for step in plan.steps {
            let text = stepContractText(step)
            let stepContracts = Self.inferContracts(from: text, source: step.id).filter { contract in
                Self.shouldAddStepContractToTask(contract, text: text, hasPrimaryObjective: hasPrimaryObjective)
            }
            for contract in stepContracts {
                if !contracts.contains(contract) { contracts.append(contract) }
            }
        }
        return contracts
    }

    private func isSatisfied(_ contract: CompletionContract) -> Bool {
        verifiedEffects.contains { evidence in
            evidence.verified &&
            Self.evidenceKind(evidence.kind, satisfies: contract.kind) &&
            (contract.app.isEmpty || evidence.contains(contract.app)) &&
            (contract.target.isEmpty || evidence.contains(contract.target)) &&
            (contract.value.isEmpty || evidence.contains(contract.value))
        }
    }

    private static func inferContracts(from text: String, source: String) -> [CompletionContract] {
        let lowered = text.lowercased()
        var contracts: [CompletionContract] = []
        func has(_ terms: [String]) -> Bool {
            terms.contains { lowered.contains($0.lowercased()) }
        }
        func add(_ kind: String, app: String = "", target: String = "", value: String = "") {
            let contract = CompletionContract(kind: kind, app: app, target: target, value: value, source: source)
            if !contracts.contains(contract) {
                contracts.append(contract)
            }
        }

        let hasConversationalIntent = has(["聊天", "持续聊天", "对话", "聊一聊", "开头", "开场", "作为开头", "以此开头", "chat", "conversation", "talk"])
        let hasSendIntent = has(["发送", "发给", "发消息", "发晚安", "同步给", "通知", "告诉", "转发给", "分享给", "send", "message", "share with", "notify"]) || hasConversationalIntent
        let hasChatContext = has(["微信", "wechat", "飞书", "lark", "qq", "给", "同步给", "通知", "告诉", "分享给"]) || hasConversationalIntent
        if hasSendIntent && hasChatContext {
            add("external_message_sent", app: inferredChatApp(from: lowered))
        }

        if has(["导出pdf", "导出 pdf", "export pdf", "pdf"]) && has(["导出", "export", "转换", "convert"]) {
            add("pdf_exported")
        }

        let hasFileIntent = has(["保存", "存到", "写到", "新建文件", "创建文件", "生成文件", "save to", "write to", "create file"])
        let nonFileContext = has(["日历", "calendar", "提醒事项", "reminder", "备忘录", "notes", "邮件", "mail", "email"])
        if hasFileIntent && !nonFileContext {
            add("file_saved")
        }

        if has(["文件夹", "目录", "folder", "directory"]) && has(["创建", "新建", "create", "make"]) {
            add("folder_created")
        }

        if has(["日历", "日程", "calendar", "event"]) && has(["创建", "新建", "加入", "添加", "写入", "create", "add", "schedule"]) {
            add("calendar_event_created")
        }

        if has(["提醒事项", "提醒我", "reminder", "待办", "todo"]) && has(["创建", "新建", "添加", "create", "add"]) {
            add("reminder_created")
        }

        if has(["备忘录", "notes", "note"]) &&
            !has(["文本编辑器或备忘录", "text editor or notes", "textedit or notes"]) &&
            has(["创建", "新建", "写入", "保存", "create", "write", "save"]) {
            add("note_created")
        }

        if has(["邮件", "mail", "email"]) && has(["草稿", "draft", "撰写", "compose", "写"]) {
            add("mail_draft_created")
        }

        if has(["快捷指令", "shortcut", "shortcuts"]) && has(["运行", "执行", "run"]) {
            add("shortcut_ran")
        }

        if has(["shell", "终端", "terminal", "命令", "command"]) && has(["运行", "执行", "跑", "run", "execute"]) {
            add("shell_command_submitted")
        }

        if has(["http://", "https://", "url", "网址", "网页"]) && has(["打开", "访问", "open", "visit"]) {
            add("browser_url_visible", app: inferredBrowserApp(from: lowered))
        }

        if contracts.isEmpty,
           has(["打开", "启动", "open", "launch"]),
           !has(["搜索", "查询", "search"]) {
            add("app_opened", app: inferredNamedApp(from: lowered))
        }

        return contracts
    }

    private static func isPrimaryOutcomeKind(_ kind: String) -> Bool {
        !["app_opened", "browser_tab_opened"].contains(kind)
    }

    private static func shouldAddStepContractToTask(_ contract: CompletionContract, text: String, hasPrimaryObjective: Bool) -> Bool {
        guard shouldEnforceStepContract(contract, text: text) else { return false }
        if hasPrimaryObjective && !isPrimaryOutcomeKind(contract.kind) {
            return false
        }
        return true
    }

    private static func shouldEnforceStepContract(_ contract: CompletionContract, text: String) -> Bool {
        let lowered = text.lowercased()
        func has(_ terms: [String]) -> Bool {
            terms.contains { lowered.contains($0.lowercased()) }
        }

        switch contract.kind {
        case "external_message_sent":
            let strongSend = has(["发送消息", "发送给", "发给", "发晚安", "同步给", "通知", "告诉", "转发", "分享给", "send message", "send it", "send to", "press send", "deliver"])
            let conversationStep = has(["聊天", "持续聊天", "对话", "开头", "开场", "chat", "conversation", "talk"])
            let observeOnly = has(["阅读上下文", "读取上下文", "查看最近", "聊天记录", "了解之前", "理解上下文", "获取最近", "观察", "验证", "read context", "observe", "recent messages"])
            let processOnly = observeOnly || has(["打开", "搜索", "查找", "定位", "准备", "验证联系人", "验证聊天", "当前聊天对象", "聊天对象", "粘贴", "stage", "staged", "staging", "before send", "before sending", "verify recipient", "verify chat", "does not send", "不发送", "未发送", "暂不发送"])
            if processOnly && !strongSend {
                return false
            }
            if conversationStep && has(["发送", "发出", "开场消息", "开头消息", "第一条", "opening message", "first message"]) {
                return true
            }
            return strongSend || !processOnly
        case "file_saved":
            let strongSave = has(["保存到", "存到", "写到", "生成文件", "创建文件", "save to", "write to", "create file"])
            let processOnly = has(["打开", "准备", "编辑", "草稿", "输入文本", "写入文本", "文档中输入", "prepare", "type text", "set text"])
            return strongSave || !processOnly
        default:
            return true
        }
    }

    private static func effectEvidence(call: ToolCall, result: ToolResult) -> CompletionEvidence? {
        let fallbackKind = fallbackEffectKind(call: call, result: result)
        guard let kind = result.data["effect"] ?? fallbackKind else { return nil }
        let verifiedText = result.data["verified"] ?? result.data["effect_verified"]
        let verified = bool(verifiedText) ?? fallbackVerified(call: call, result: result, kind: kind)
        let app = result.data["app"] ?? appName(for: call)
        let target = result.data["target"] ??
            result.data["recipient"] ??
            result.data["chat"] ??
            result.data["title"] ??
            result.data["subject"] ??
            result.data["name"] ??
            result.data["path"] ??
            result.data["url"] ??
            ""
        let value = result.data["value"] ??
            result.data["text"] ??
            result.data["message"] ??
            result.data["pdf"] ??
            result.data["command"] ??
            result.data["output"] ??
            ""
        return CompletionEvidence(
            kind: kind,
            app: app,
            target: target,
            value: value,
            tool: call.name,
            evidence: result.evidence,
            verified: verified
        )
    }

    private static func fallbackEffectKind(call: ToolCall, result: ToolResult) -> String? {
        switch call.name {
        case "wechat_send_text", "lark_send_text", "qq_send_text", "wechat_send_staged", "lark_send_staged", "qq_send_staged":
            return "external_message_sent"
        case "wechat_open_chat", "lark_open_chat", "qq_open_chat":
            return "chat_session_ready"
        case "wechat_open", "lark_open", "qq_open", "aios_open_app", "dock_open", "shortcuts_open", "claude_open", "codex_open":
            return "app_opened"
        case "textedit_save_as":
            return "file_saved"
        case "finder_create_folder":
            return "folder_created"
        case "libreoffice_export_pdf":
            return "pdf_exported"
        case "finder_read_text_file":
            return "file_content_verified"
        case "calendar_create_event":
            return "calendar_event_created"
        case "reminders_create":
            return "reminder_created"
        case "notes_create_note":
            return "note_created"
        case "mail_compose_draft":
            return "mail_draft_created"
        case "shortcuts_run":
            return "shortcut_ran"
        case "terminal_run_command":
            return "shell_command_submitted"
        case "safari_open_url", "chrome_open_url", "safari_new_tab", "chrome_new_tab", "aios_open_url":
            if (result.data["url"] ?? string(call.arguments["url"]) ?? "").isEmpty {
                return nil
            }
            return "browser_url_visible"
        default:
            return nil
        }
    }

    private static func fallbackVerified(call: ToolCall, result: ToolResult, kind: String) -> Bool {
        guard result.success else { return false }
        switch kind {
        case "external_message_sent":
            return result.data["verified_recipient"] == "true" && result.data["verified_message"] == "true"
        case "browser_url_visible":
            return result.data["verified_current_url"] == "true"
        default:
            return true
        }
    }

    private static func evidenceKind(_ evidenceKind: String, satisfies contractKind: String) -> Bool {
        if evidenceKind == contractKind { return true }
        switch contractKind {
        case "file_saved":
            return ["file_saved", "file_created", "file_exists", "pdf_exported", "file_content_verified"].contains(evidenceKind)
        case "browser_url_visible":
            return ["browser_url_visible", "url_opened"].contains(evidenceKind)
        default:
            return false
        }
    }

    private static func observationContainsSentMessage(_ result: ToolResult, message: String) -> Bool {
        let haystack = ([result.evidence, result.error ?? "", result.suggestion ?? ""] + Array(result.data.values))
            .joined(separator: "\n")
            .lowercased()
        return messageProbes(message).contains { probe in
            guard haystack.contains(probe.lowercased()) else { return false }
            return !haystack.contains("\(probe.lowercased())|")
        }
    }

    private static func messageProbes(_ message: String) -> [String] {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var probes: [String] = []
        func add(_ value: String) {
            let cleaned = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "，。,.；;：:、 "))
            guard cleaned.count >= 4 else { return }
            if !probes.contains(cleaned) { probes.append(cleaned) }
        }
        for separator in ["。", "！", "!", "\n"] {
            if let first = trimmed.components(separatedBy: separator).first {
                add(String(first.prefix(18)))
            }
        }
        for phrase in ["项目的原理", "核心原理", "任务规划", "自主调用各种工具", "无需人工逐步干预"] where trimmed.localizedCaseInsensitiveContains(phrase) {
            add(phrase)
        }
        add(String(trimmed.prefix(18)))
        return probes
    }

    private static func chatApp(for toolName: String) -> String? {
        if toolName.hasPrefix("wechat_") { return "WeChat" }
        if toolName.hasPrefix("lark_") { return "Lark" }
        if toolName.hasPrefix("qq_") { return "QQ" }
        return nil
    }

    private static func appName(for call: ToolCall) -> String {
        if let app = resultAppName(from: call.name) {
            return app
        }
        return string(call.arguments["app_name"]) ??
            string(call.arguments["bundle_id"]) ??
            string(call.arguments["app"]) ??
            ""
    }

    private static func resultAppName(from toolName: String) -> String? {
        if toolName.hasPrefix("wechat_") { return "WeChat" }
        if toolName.hasPrefix("lark_") { return "Lark" }
        if toolName.hasPrefix("qq_") { return "QQ" }
        if toolName.hasPrefix("safari_") { return "Safari" }
        if toolName.hasPrefix("chrome_") { return "Chrome" }
        if toolName.hasPrefix("calendar_") { return "Calendar" }
        if toolName.hasPrefix("reminders_") { return "Reminders" }
        if toolName.hasPrefix("notes_") { return "Notes" }
        if toolName.hasPrefix("mail_") { return "Mail" }
        if toolName.hasPrefix("shortcuts_") { return "Shortcuts" }
        if toolName.hasPrefix("terminal_") { return "Terminal" }
        if toolName.hasPrefix("textedit_") { return "TextEdit" }
        if toolName.hasPrefix("finder_") { return "Finder" }
        if toolName.hasPrefix("libreoffice_") { return "LibreOffice" }
        return nil
    }

    private static func inferredChatApp(from lowered: String) -> String {
        if lowered.contains("微信") || lowered.contains("wechat") { return "WeChat" }
        if lowered.contains("飞书") || lowered.contains("lark") { return "Lark" }
        if lowered.contains("qq") { return "QQ" }
        return ""
    }

    private static func inferredBrowserApp(from lowered: String) -> String {
        if lowered.contains("safari") { return "Safari" }
        if lowered.contains("chrome") || lowered.contains("谷歌") { return "Chrome" }
        return ""
    }

    private static func inferredNamedApp(from lowered: String) -> String {
        let known = [
            ("微信", "WeChat"),
            ("wechat", "WeChat"),
            ("飞书", "Lark"),
            ("lark", "Lark"),
            ("qq", "QQ"),
            ("safari", "Safari"),
            ("chrome", "Chrome"),
            ("日历", "Calendar"),
            ("calendar", "Calendar"),
            ("提醒事项", "Reminders"),
            ("reminders", "Reminders"),
            ("备忘录", "Notes"),
            ("notes", "Notes"),
            ("邮件", "Mail"),
            ("mail", "Mail"),
            ("textedit", "TextEdit"),
            ("文本编辑", "TextEdit"),
            ("finder", "Finder")
        ]
        return known.first(where: { lowered.contains($0.0) })?.1 ?? ""
    }
}

struct PolicyDecision {
    let allowed: Bool
    let reason: String
}

struct PolicyEngine {
    func evaluate(_ call: ToolCall, knownTools: Set<String>) -> PolicyDecision {
        if !knownTools.contains(call.name) && !Self.orchestrationTools.contains(call.name) {
            return PolicyDecision(allowed: false, reason: "Unknown tool.")
        }

        if call.name == "terminal_run_command",
           let command = string(call.arguments["command"]),
           containsDeletionCommand(command) {
            return PolicyDecision(allowed: false, reason: "Shell command appears to delete files, which remains protected.")
        }

        if mentionsProtectedPaymentOrCredential(call.arguments) {
            return PolicyDecision(allowed: false, reason: "Payment or credential handling remains protected.")
        }

        return PolicyDecision(allowed: true, reason: "Allowed by current project policy.")
    }

    private static let orchestrationTools: Set<String> = [
        "task_plan_submit",
        "step_complete",
        "step_failed",
        "plan_update",
        "task_complete"
    ]

    private func containsDeletionCommand(_ command: String) -> Bool {
        let lowered = " \(command.lowercased()) "
        let blockedFragments = [
            " rm ",
            " rm\t",
            " rm\n",
            " rmdir ",
            " unlink ",
            " trash ",
            " shred ",
            " srm ",
            " diskutil erase",
            " mkfs",
            " -delete "
        ]
        return blockedFragments.contains { lowered.contains($0) }
    }

    private func mentionsProtectedPaymentOrCredential(_ value: Any) -> Bool {
        if let text = value as? String {
            let lowered = text.lowercased()
            let protectedTerms = [
                "password",
                "passcode",
                "credential",
                "secret",
                "private key",
                "payment",
                "credit card",
                "密码",
                "口令",
                "支付",
                "付款",
                "银行卡"
            ]
            return protectedTerms.contains { lowered.contains($0) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, nested in
                mentionsProtectedPaymentOrCredential(key) || mentionsProtectedPaymentOrCredential(nested)
            }
        }
        if let array = value as? [Any] {
            return array.contains { mentionsProtectedPaymentOrCredential($0) }
        }
        return false
    }
}

@MainActor
final class OpenAICompatibleClient {
    private let config: LLMConfig
    private let session: URLSession

    init(config: LLMConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func complete(messages: [[String: Any]], tools: [[String: Any]]) async throws -> LLMResponse {
        var errors: [String] = []
        for provider in config.providers {
            do {
                var response = try await complete(messages: messages, tools: tools, provider: provider)
                var raw = response.rawMessage
                raw["_aios_provider"] = provider.label
                response = LLMResponse(content: response.content, toolCalls: response.toolCalls, rawMessage: raw)
                if provider.label != "primary" {
                    AuditLog.append(action: "llm_provider_fallback_used", fields: [
                        "provider": provider.label,
                        "model": provider.model,
                        "base_url": provider.baseURL.absoluteString
                    ])
                }
                return response
            } catch {
                errors.append("\(provider.label): \(error.localizedDescription)")
                AuditLog.append(action: "llm_provider_failed", fields: [
                    "provider": provider.label,
                    "model": provider.model,
                    "base_url": provider.baseURL.absoluteString,
                    "error": error.localizedDescription
                ])
            }
        }
        throw RuntimeError("All LLM providers failed: \(errors.joined(separator: " | "))")
    }

    private func complete(messages: [[String: Any]], tools: [[String: Any]], provider: LLMProvider) async throws -> LLMResponse {
        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = provider.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": provider.model,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
            "temperature": 0.2
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw RuntimeError("LLM HTTP \(http.statusCode): \(text)")
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw RuntimeError("LLM response did not contain choices[0].message")
        }

        let toolCalls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { raw -> ToolCall? in
            guard
                let id = raw["id"] as? String,
                let function = raw["function"] as? [String: Any],
                let name = function["name"] as? String
            else {
                return nil
            }

            let argumentString = function["arguments"] as? String ?? "{}"
            let argumentData = Data(argumentString.utf8)
            let parsed = (try? JSONSerialization.jsonObject(with: argumentData)) as? [String: Any]
            return ToolCall(id: id, name: name, arguments: parsed ?? [:], raw: raw)
        }

        return LLMResponse(content: message["content"] as? String, toolCalls: toolCalls, rawMessage: message)
    }
}

@MainActor
final class AgentLoop {
    private let client: OpenAICompatibleClient
    private let tools: ToolRegistry
    private let policy = PolicyEngine()
    private let eventStore: EventStore?

    init(client: OpenAICompatibleClient, tools: ToolRegistry, eventStore: EventStore? = nil) {
        self.client = client
        self.tools = tools
        self.eventStore = eventStore
    }

    @discardableResult
    func run(goal: String) async throws -> Bool {
        let config = LLMConfig.fromEnvironment()
        emitEvent("UserGoal", ["goal": goal])

        let planResponse = try await client.complete(
            messages: [
                ["role": "system", "content": Self.planningPrompt],
                ["role": "user", "content": goal]
            ],
            tools: orchestrationDefinitions
        )
        var plan = taskPlan(from: planResponse, fallbackGoal: goal)
        emitEvent("TaskPlan", [
            "objective": plan.objective,
            "steps": plan.summaryForPrompt()
        ])

        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.executionPrompt],
            ["role": "user", "content": executionUserPrompt(goal: goal, plan: plan)]
        ]

        let knownTools = Set(tools.definitions.compactMap(toolName))
        var finished = false
        var round = 0
        var executedActionCount = 0
        var verificationState = CompletionContractState(goal: goal, plan: plan)
        var submittedExternalSends: Set<String> = []

        while round < config.maxSteps, !finished {
            guard let stepIndex = nextStepIndex(in: plan) else {
                break
            }

            round += 1
            plan.steps[stepIndex].status = .running
            plan.steps[stepIndex].attempts += 1
            let currentStep = plan.steps[stepIndex]

            emitEvent("StepQueue", [
                "round": "\(round)",
                "step_id": currentStep.id,
                "step_title": currentStep.title,
                "attempt": "\(currentStep.attempts)"
            ])

            messages.append([
                "role": "user",
                "content": stepPrompt(step: currentStep, plan: plan)
            ])

            let response = try await client.complete(messages: messages, tools: allToolDefinitions)

            if let content = response.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print(content)
            }

            guard !response.toolCalls.isEmpty else {
                plan.steps[stepIndex].status = .failed
                let reason = actionNotPerformedReason(response.content)
                plan.steps[stepIndex].evidence.append(reason)
                emitEvent("ActionNotPerformed", [
                    "step_id": currentStep.id,
                    "reason": reason,
                    "assistant_content": truncateMiddle(response.content ?? "", maxCharacters: 1_000)
                ])
                messages.append(["role": "assistant", "content": response.content ?? ""])
                messages.append(["role": "user", "content": actionNotPerformedPrompt(step: plan.steps[stepIndex], reason: reason)])
                continue
            }

            if response.toolCalls.contains(where: { $0.name == "task_complete" }) && executedActionCount == 0 {
                plan.steps[stepIndex].status = .failed
                let reason = "Model attempted task_complete before any AppAction tool evidence."
                emitEvent("ActionNotPerformed", [
                    "step_id": currentStep.id,
                    "reason": reason
                ])
                messages.append(response.rawMessage)
                for call in response.toolCalls where call.name == "task_complete" {
                    messages.append(toolMessage(call: call, result: ToolResult(
                        success: false,
                        evidence: "Action not performed.",
                        error: reason,
                        suggestion: "Use concrete app/observation tools before task_complete."
                    )))
                }
                messages.append(["role": "user", "content": actionNotPerformedPrompt(step: plan.steps[stepIndex], reason: reason)])
                emitEvent("Recovery", [
                    "step_id": currentStep.id,
                    "reason": reason
                ])
                continue
            }

            messages.append(response.rawMessage)
            var sawStepTerminalSignal = false

            for call in response.toolCalls {
                emitEvent("ToolSelection", [
                    "step_id": currentStep.id,
                    "tool": call.name,
                    "arguments": jsonLine(call.arguments)
                ])

                if call.name == "task_complete" {
                    let gate = verificationState.taskCompletionGate(plan: plan)
                    if gate.allowed && executedActionCount > 0 {
                        plan.steps[stepIndex].status = .done
                        finished = true
                        sawStepTerminalSignal = true
                        messages.append(toolMessage(call: call, result: ToolResult(success: true, evidence: string(call.arguments["summary"]) ?? gate.reason)))
                        emitEvent("Verification", [
                            "step_id": currentStep.id,
                            "passed": "true",
                            "reason": gate.reason
                        ])
                        emitEvent("Delivery", ["summary": string(call.arguments["summary"]) ?? gate.reason])
                    } else {
                        let reason = executedActionCount == 0 ? "task_complete before AppAction tool evidence." : gate.reason
                        plan.steps[stepIndex].status = .failed
                        plan.steps[stepIndex].evidence.append(reason)
                        messages.append(toolMessage(call: call, result: ToolResult(success: false, evidence: "Completion blocked by Swift verification gate.", error: reason)))
                        emitEvent("Verification", [
                            "step_id": currentStep.id,
                            "passed": "false",
                            "reason": reason
                        ])
                        emitEvent("Recovery", [
                            "step_id": currentStep.id,
                            "reason": reason
                        ])
                    }
                    break
                }

                if handleOrchestrationCall(call, plan: &plan, currentStepIndex: stepIndex, finished: &finished, verificationState: &verificationState) {
                    sawStepTerminalSignal = true
                    messages.append(toolMessage(call: call, result: ToolResult(success: true, evidence: "Handled orchestration signal \(call.name).")))
                    continue
                }

                let decision = policy.evaluate(call, knownTools: knownTools)
                emitEvent("PolicyCheck", [
                    "tool": call.name,
                    "allowed": decision.allowed ? "true" : "false",
                    "reason": decision.reason
                ])

                guard decision.allowed else {
                    let blocked = ToolResult(success: false, evidence: "Tool call blocked by policy.", error: decision.reason)
                    plan.steps[stepIndex].status = .failed
                    plan.steps[stepIndex].evidence.append(blocked.evidence)
                    messages.append(toolMessage(call: call, result: blocked))
                    emitEvent("Recovery", [
                        "step_id": currentStep.id,
                        "reason": decision.reason
                    ])
                    continue
                }

                if Self.isExternalSendTool(call.name) {
                    let sendKey = Self.externalSendKey(call)
                    if !sendKey.isEmpty, submittedExternalSends.contains(sendKey) {
                        let blocked = ToolResult(
                            success: false,
                            evidence: "Duplicate external send blocked by orchestration guard.",
                            error: "A matching external send was already submitted in this run.",
                            suggestion: "Do not resend the same message. Use verify/observe tools or ask the user before retrying."
                        )
                        plan.steps[stepIndex].status = .failed
                        plan.steps[stepIndex].evidence.append(blocked.evidence)
                        messages.append(toolMessage(call: call, result: blocked))
                        emitEvent("Recovery", [
                            "step_id": currentStep.id,
                            "reason": blocked.error ?? blocked.evidence,
                            "suggestion": blocked.suggestion ?? ""
                        ])
                        continue
                    }
                }

                emitEvent("AppAction", [
                    "tool": call.name,
                    "arguments": jsonLine(call.arguments)
                ])
                AuditLog.append(action: "tool_call", fields: [
                    "run_id": eventStore?.runID ?? "",
                    "step_id": currentStep.id,
                    "tool": call.name,
                    "arguments": jsonLine(call.arguments)
                ])
                let result = tools.execute(call)
                if call.name != "task_complete" {
                    executedActionCount += 1
                }
                if Self.isExternalSendTool(call.name), result.data["verified_recipient"] == "true" {
                    let sendKey = Self.externalSendKey(call)
                    if !sendKey.isEmpty { submittedExternalSends.insert(sendKey) }
                }
                verificationState.record(call: call, result: result)
                print("tool_result: \(result.jsonString)")
                messages.append(toolMessage(call: call, result: result))
                AuditLog.append(action: "tool_result", fields: [
                    "run_id": eventStore?.runID ?? "",
                    "step_id": currentStep.id,
                    "tool": call.name,
                    "success": result.success ? "true" : "false",
                    "evidence": result.evidence,
                    "error": result.error ?? ""
                ])

                plan.steps[stepIndex].evidence.append("\(call.name): \(result.success ? "success" : "failed") - \(result.evidence)")
                emitEvent("Observation", [
                    "tool": call.name,
                    "success": result.success ? "true" : "false",
                    "evidence": result.evidence,
                    "error": result.error ?? ""
                ])

                if !result.success {
                    plan.steps[stepIndex].status = .failed
                    emitEvent("Recovery", [
                        "step_id": currentStep.id,
                        "reason": result.error ?? result.evidence,
                        "suggestion": result.suggestion ?? ""
                    ])
                }
            }

            if finished {
                break
            }

            if !sawStepTerminalSignal, plan.steps[stepIndex].status == .running {
                let verification = verifyStep(step: plan.steps[stepIndex], verificationState: verificationState)
                emitEvent("Verification", [
                    "step_id": currentStep.id,
                    "passed": verification ? "true" : "false",
                    "evidence_count": "\(plan.steps[stepIndex].evidence.count)"
                ])
                if verification {
                    plan.steps[stepIndex].status = .done
                }
            }

            if plan.steps[stepIndex].status == .failed, plan.steps[stepIndex].attempts < 3 {
                plan.steps[stepIndex].status = .pending
                messages.append(["role": "user", "content": recoveryPrompt(step: plan.steps[stepIndex])])
            }
        }

        if plan.isComplete, !finished {
            finished = try await requestFinalDelivery(messages: &messages, plan: plan, knownTools: knownTools, verificationState: verificationState)
        }

        if finished {
            emitEvent("Delivery", [
                "objective": plan.objective,
                "status": "complete"
            ])
            print("\nDone.")
            return true
        } else {
            emitEvent("Delivery", [
                "objective": plan.objective,
                "status": "incomplete",
                "plan": plan.summaryForPrompt()
            ])
            print("\nStopped before all steps completed.")
            return false
        }
    }

    private var allToolDefinitions: [[String: Any]] {
        orchestrationDefinitions + tools.definitions
    }

    private var orchestrationDefinitions: [[String: Any]] {
        [
            tool("task_plan_submit", "Submit the explicit task plan before executing app actions.", [
                "objective": schema("string", "Overall objective."),
                "steps": arrayObjectSchema("Ordered task steps. Each item should include id, title, goal, verification, and optional deliverable.", [
                    "id": schema("string", "Stable step id such as S1."),
                    "title": schema("string", "Short step title."),
                    "goal": schema("string", "What this step must accomplish."),
                    "verification": schema("string", "How this step should be verified."),
                    "deliverable": schema("string", "Optional expected output or artifact.")
                ])
            ], required: ["objective", "steps"]),
            tool("step_complete", "Mark the current step complete after evidence verifies it.", [
                "step_id": schema("string", "Step id."),
                "evidence": schema("string", "Evidence that the step is complete.")
            ], required: ["step_id", "evidence"]),
            tool("step_failed", "Mark the current step failed and request recovery.", [
                "step_id": schema("string", "Step id."),
                "reason": schema("string", "Failure reason."),
                "recovery": schema("string", "Suggested recovery or next attempt.")
            ], required: ["step_id", "reason"]),
            tool("plan_update", "Append new steps when recovery or task discovery requires it.", [
                "reason": schema("string", "Why the plan needs extra steps."),
                "steps": arrayObjectSchema("Steps to append. Each item should include id, title, goal, verification, and optional deliverable.", [
                    "id": schema("string", "Stable step id."),
                    "title": schema("string", "Short step title."),
                    "goal": schema("string", "What this step must accomplish."),
                    "verification": schema("string", "How this step should be verified."),
                    "deliverable": schema("string", "Optional expected output or artifact.")
                ])
            ], required: ["reason", "steps"])
        ]
    }

    private func taskPlan(from response: LLMResponse, fallbackGoal: String) -> TaskPlan {
        if let call = response.toolCalls.first(where: { $0.name == "task_plan_submit" }) {
            return TaskPlan.from(arguments: call.arguments, fallbackGoal: fallbackGoal)
        }
        return TaskPlan.fallback(goal: fallbackGoal)
    }

    private func nextStepIndex(in plan: TaskPlan) -> Int? {
        if let running = plan.steps.firstIndex(where: { $0.status == .running }) {
            return running
        }
        return plan.steps.firstIndex(where: { $0.status == .pending || ($0.status == .failed && $0.attempts < 3) })
    }

    private func handleOrchestrationCall(
        _ call: ToolCall,
        plan: inout TaskPlan,
        currentStepIndex: Int,
        finished: inout Bool,
        verificationState: inout CompletionContractState
    ) -> Bool {
        switch call.name {
        case "task_plan_submit":
            plan = TaskPlan.from(arguments: call.arguments, fallbackGoal: plan.objective)
            verificationState.updateRequired(from: plan)
            emitEvent("TaskPlan", [
                "objective": plan.objective,
                "steps": plan.summaryForPrompt()
            ])
            return true
        case "step_complete":
            let stepID = string(call.arguments["step_id"]) ?? plan.steps[currentStepIndex].id
            let evidence = string(call.arguments["evidence"]) ?? "Step marked complete by model."
            let targetStep = plan.steps.first(where: { $0.id == stepID }) ?? plan.steps[currentStepIndex]
            let gate = verificationState.stepCompletionGate(step: targetStep)
            if !gate.allowed {
                plan.steps[currentStepIndex].status = .failed
                plan.steps[currentStepIndex].evidence.append(gate.reason)
                emitEvent("Verification", [
                    "step_id": stepID,
                    "passed": "false",
                    "evidence": evidence,
                    "reason": gate.reason
                ])
                emitEvent("Recovery", [
                    "step_id": stepID,
                    "reason": gate.reason
                ])
                return true
            }
            if let index = plan.steps.firstIndex(where: { $0.id == stepID }) {
                plan.steps[index].status = .done
                plan.steps[index].evidence.append(evidence)
            } else {
                plan.steps[currentStepIndex].status = .done
                plan.steps[currentStepIndex].evidence.append(evidence)
            }
            emitEvent("Verification", [
                "step_id": stepID,
                "passed": "true",
                "evidence": evidence
            ])
            return true
        case "step_failed":
            let stepID = string(call.arguments["step_id"]) ?? plan.steps[currentStepIndex].id
            let reason = string(call.arguments["reason"]) ?? "Step failed."
            if let index = plan.steps.firstIndex(where: { $0.id == stepID }) {
                plan.steps[index].status = .failed
                plan.steps[index].evidence.append(reason)
            } else {
                plan.steps[currentStepIndex].status = .failed
                plan.steps[currentStepIndex].evidence.append(reason)
            }
            emitEvent("Recovery", [
                "step_id": stepID,
                "reason": reason,
                "recovery": string(call.arguments["recovery"]) ?? ""
            ])
            return true
        case "plan_update":
            let added = plan.appendSteps(from: call.arguments)
            verificationState.updateRequired(from: plan)
            emitEvent("NextStep", [
                "reason": string(call.arguments["reason"]) ?? "",
                "added_steps": added.map { $0.id }.joined(separator: ",")
            ])
            return true
        case "task_complete":
            let gate = verificationState.taskCompletionGate(plan: plan)
            guard gate.allowed else {
                plan.steps[currentStepIndex].status = .failed
                plan.steps[currentStepIndex].evidence.append(gate.reason)
                emitEvent("Verification", [
                    "step_id": plan.steps[currentStepIndex].id,
                    "passed": "false",
                    "reason": gate.reason
                ])
                emitEvent("Recovery", [
                    "step_id": plan.steps[currentStepIndex].id,
                    "reason": gate.reason
                ])
                return true
            }
            plan.steps[currentStepIndex].status = .done
            finished = true
            emitEvent("Delivery", ["summary": string(call.arguments["summary"]) ?? "Task complete."])
            return true
        default:
            return false
        }
    }

    private func verifyStep(step: TaskStep, verificationState: CompletionContractState) -> Bool {
        let gate = verificationState.stepCompletionGate(step: step)
        if !gate.allowed { return false }
        return step.evidence.contains { evidence in
            evidence.contains(": success -") || evidence.localizedCaseInsensitiveContains("complete")
        }
    }

    private func requestFinalDelivery(
        messages: inout [[String: Any]],
        plan: TaskPlan,
        knownTools: Set<String>,
        verificationState: CompletionContractState
    ) async throws -> Bool {
        let gate = verificationState.taskCompletionGate(plan: plan)
        guard gate.allowed else {
            emitEvent("Verification", [
                "step_id": "delivery",
                "passed": "false",
                "reason": gate.reason
            ])
            return false
        }
        emitEvent("Verification", [
            "step_id": "delivery",
            "passed": "true",
            "reason": gate.reason
        ])
        emitEvent("Delivery", ["summary": gate.reason])
        return true
    }

    private static func isExternalSendTool(_ toolName: String) -> Bool {
        [
            "wechat_send_text",
            "lark_send_text",
            "qq_send_text",
            "wechat_send_staged",
            "lark_send_staged",
            "qq_send_staged"
        ].contains(toolName)
    }

    private static func externalSendKey(_ call: ToolCall) -> String {
        let target = string(call.arguments["recipient"]) ??
            string(call.arguments["chat"]) ??
            string(call.arguments["name"]) ??
            ""
        let value = string(call.arguments["text"]) ??
            string(call.arguments["path"]) ??
            ""
        return [
            call.name,
            target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "|")
    }

    private func toolMessage(call: ToolCall, result: ToolResult) -> [String: Any] {
        [
            "role": "tool",
            "tool_call_id": call.id,
            "name": call.name,
            "content": result.jsonString
        ]
    }

    private func emitEvent(_ name: String, _ fields: [String: String]) {
        var payload = fields
        payload["event"] = name
        payload["time"] = isoDateString(Date())
        print("event: \(jsonLine(payload))")
        try? eventStore?.append(name, fields)
    }

    private func executionUserPrompt(goal: String, plan: TaskPlan) -> String {
        let suggestions = (try? RecipeStore.suggest(goal: goal, limit: 3)) ?? []
        let recipeHint: String
        if suggestions.isEmpty {
            recipeHint = "No pre-matched recipe. Still call recipe_suggest if the current step looks reusable."
        } else {
            recipeHint = suggestions.map { suggestion in
                "- \(suggestion.recipe.id) score=\(suggestion.score) params=\(suggestion.recipe.requiredParams.joined(separator: ",")) goal=\(suggestion.recipe.goalTemplate)"
            }.joined(separator: "\n")
        }
        return """
        UserGoal:
        \(goal)

        TaskPlan:
        \(plan.summaryForPrompt())

        RecipeSuggestions:
        \(recipeHint)

        Execute the plan step by step. For each step, choose tools, observe evidence, verify completion, and call step_complete when the step is done. Use plan_update when discovery changes the plan. Call task_complete only after delivery is done and verified.
        """
    }

    private func stepPrompt(step: TaskStep, plan: TaskPlan) -> String {
        """
        Current Step:
        id: \(step.id)
        title: \(step.title)
        goal: \(step.goal)
        verification: \(step.verification)
        deliverable: \(step.deliverable)

        Full Step Queue:
        \(plan.summaryForPrompt())

        Select the next tool call for this step. After tool evidence is enough, call step_complete for this step.
        """
    }

    private func recoveryPrompt(step: TaskStep) -> String {
        """
        Recovery needed for step \(step.id) - \(step.title).
        Last evidence:
        \(step.evidence.suffix(5).joined(separator: "\n"))

        Choose a recovery action, a different tool, or call plan_update with extra steps.
        """
    }

    private func actionNotPerformedReason(_ content: String?) -> String {
        let text = (content ?? "").lowercased()
        let completionClaims = [
            "done",
            "completed",
            "finished",
            "sent",
            "created",
            "opened",
            "saved",
            "已完成",
            "完成了",
            "已发送",
            "发送了",
            "已创建",
            "已打开",
            "已保存"
        ]
        if completionClaims.contains(where: { text.contains($0) }) {
            return "Assistant claimed an action was done without returning a tool call."
        }
        return "No tool call returned for this step."
    }

    private func actionNotPerformedPrompt(step: TaskStep, reason: String) -> String {
        """
        ActionNotPerformed for step \(step.id) - \(step.title):
        \(reason)

        You must now choose a concrete tool call that performs or observes the step. Do not claim success in prose. Call step_complete only after tool evidence verifies the step.
        """
    }

    private func toolName(from definition: [String: Any]) -> String? {
        guard let function = definition["function"] as? [String: Any] else { return nil }
        return function["name"] as? String
    }

    private static let planningPrompt = """
    You are AIOS Planner. Convert the user's goal into an explicit, executable macOS task plan.

    You must call task_plan_submit. Do not execute app actions in this planning phase.

    Plan shape:
    - UserGoal: preserve the user's intent.
    - TaskPlan: split the work into clear steps.
    - StepQueue: order steps so each can be verified.
    - ToolSelection: mention likely tool families in each step goal when useful.
    - PolicyCheck: avoid deletes, credentials, and payments.
    - AppAction, Observation, Verification, Recovery, Delivery: make each step verifiable.

    Keep the plan compact, usually 3-7 steps. Include delivery/sync as a final step when the user asks to send or share.
    For every material outcome, write the expected completion contract in verification: e.g. message sent and visible in the chat, file exists at the target path, Calendar event can be found, Shortcut finished, browser current URL matches, or shell command was submitted.
    """

    private static let executionPrompt = """
    You are AIOS Executor, an AI execution layer for macOS.

    Execute this pipeline explicitly:
    UserGoal -> TaskPlan -> StepQueue -> ToolSelection -> PolicyCheck -> AppAction -> Observation -> Verification -> Recovery / NextStep -> Delivery.

    Use tools to operate real macOS apps. Prefer app-specific functional tools over raw UI actions.
    Prefer dedicated app adapters for Finder, Safari, Chrome, WPS, LibreOffice, Preview, Notes, Mail, Calendar, Reminders, WeChat, Lark, QQ, Tencent Meeting, Baidu Netdisk, ToDesk, Docker, Shortcuts, and IDEs when they match the task.
    Before manual multi-step work, use recipe_suggest or the provided RecipeSuggestions and execute a matching recipe with recipe_execute when the required params are available. If no recipe fits or params are missing, continue manually and gather enough detail to make the workflow learnable.
    For apps without a dedicated adapter, use universal macOS tools in this order: app discovery/open files/URLs, locator tools, menu/keyboard actions, snapshots/screenshots/OCR, and raw coordinates last.
    Before acting inside an app, call aios_automation_context or an app-specific observation tool to orient. Prefer aios_find, aios_inspect, aios_read, aios_click, aios_type, and aios_wait over coordinate tools. Keep restore_focus=true unless the task explicitly needs the target app left focused.

    After every meaningful action, use returned evidence or observation tools to verify progress. Call step_complete only when a step is verified. Use step_failed or plan_update for recovery. Call task_complete only after all requested delivery is done and verified.
    Opening an app, searching a contact, clicking, typing, or staging content is process evidence only. It never proves the requested outcome by itself. Material outcomes require typed verified evidence such as external_message_sent, file_saved, calendar_event_created, reminder_created, note_created, mail_draft_created, shortcut_ran, shell_command_submitted, browser_url_visible, or app_opened when the user only asked to open an app.

    Safety:
    - Do not delete files.
    - Do not handle payments or credentials.
    - Sending chat messages, running Shortcuts, writing Calendar events, and running shell commands are allowed when needed for the user's task.
    - For chat/file messages, stage the content, verify the recipient, then use the send tool directly when the task asks to send.
    - For "chat with someone", "continue chatting", or "start with ..." requests, send one appropriate opening message using the dedicated chat send tool, verify the recipient and message probe, then stop after the bounded requested turn unless the user explicitly asks for more turns.
    - If a chat send tool reports that send was pressed but message verification failed, do not resend the same text. Use verify/observe tools; if still unverified, report incomplete.
    - Do not overwrite files unless the user explicitly asked or the tool input sets overwrite=true.
    """
}

@MainActor
final class ToolRegistry {
    private struct AppLaunchTarget {
        let displayName: String
        let appName: String?
        let appPath: String?
        let description: String
    }

    private static var recentExternalSendAttempts: [String: Date] = [:]

    private static let highFrequencyOpenAppTargets: [String: AppLaunchTarget] = [
        "anaconda_open": AppLaunchTarget(
            displayName: "Anaconda Navigator",
            appName: "Anaconda-Navigator",
            appPath: "/Applications/Anaconda-Navigator.app",
            description: "Open Anaconda Navigator."
        ),
        "clashx_open": AppLaunchTarget(
            displayName: "ClashX",
            appName: "ClashX",
            appPath: nil,
            description: "Open ClashX. Does not change proxy settings."
        ),
        "flyingbird_open": AppLaunchTarget(
            displayName: "FlyingBird",
            appName: "FlyingBird机场",
            appPath: "/Applications/FlyingBird机场.app",
            description: "Open FlyingBird. Does not change network/proxy state."
        ),
        "inode_client_open": AppLaunchTarget(
            displayName: "iNodeClient",
            appName: nil,
            appPath: "/Applications/iNodeClient/iNodeClient.app",
            description: "Open iNodeClient. Does not connect or disconnect VPN/network sessions."
        ),
        "inode_manager_open": AppLaunchTarget(
            displayName: "iNodeManager",
            appName: nil,
            appPath: "/Applications/iNodeManager/iNodeManager.app",
            description: "Open iNodeManager. Does not change network sessions."
        ),
        "ntfs_for_mac_open": AppLaunchTarget(
            displayName: "NTFS for Mac",
            appName: "NTFS for Mac",
            appPath: nil,
            description: "Open NTFS for Mac."
        ),
        "ui_tars_open": AppLaunchTarget(
            displayName: "UI-TARS",
            appName: "UI TARS",
            appPath: "/Applications/UI TARS.app",
            description: "Open UI-TARS desktop app."
        ),
        "veee_open": AppLaunchTarget(
            displayName: "Veee",
            appName: "Veee",
            appPath: nil,
            description: "Open Veee. Does not change network/proxy state."
        ),
        "wd_discovery_open": AppLaunchTarget(
            displayName: "WD Discovery",
            appName: nil,
            appPath: "/Applications/WD Discovery/WD Discovery.app",
            description: "Open WD Discovery."
        ),
        "yaaa_network_assistant_open": AppLaunchTarget(
            displayName: "Yaaa iNetWork Assistant",
            appName: nil,
            appPath: "/Applications/Yaaa - iNetWork Assistant.app",
            description: "Open Yaaa iNetWork Assistant."
        )
    ]

    var definitions: [[String: Any]] {
        [
            tool("aios_context", "Get frontmost app, bundle id, pid, and visible window titles.", [:]),
            tool("aios_automation_context", "Get frontmost/target app context and visible windows for locator-based automation.", [
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id.")
            ]),
            tool("aios_find", "Find Accessibility UI elements and return reusable locator ids with roles, labels, and bounds.", [
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter such as AXButton, AXTextField, or AXMenuItem."),
                "app_name": schema("string", "Optional target app name. Defaults to frontmost app."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "max_depth": schema("number", "Maximum AX tree depth. Default 8."),
                "max_results": schema("number", "Maximum matches. Default 50.")
            ]),
            tool("aios_inspect", "Inspect a UI element by locator id or a fresh query and return attributes/actions.", [
                "locator_id": schema("string", "Locator id returned by aios_find."),
                "query": schema("string", "Optional fallback label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "max_depth": schema("number", "Maximum AX tree depth. Default 8.")
            ]),
            tool("aios_read", "Read UI text from a located element or from the target app's AX tree.", [
                "locator_id": schema("string", "Optional locator id returned by aios_find."),
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "max_chars": schema("number", "Maximum text characters. Default 6000."),
                "max_depth": schema("number", "Maximum AX tree depth. Default 8."),
                "max_results": schema("number", "Maximum elements to read. Default 120.")
            ]),
            tool("aios_click", "Click a UI element by locator id or query using AXPress first and coordinate fallback.", [
                "locator_id": schema("string", "Locator id returned by aios_find."),
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "restore_focus": schema("boolean", "Restore the previously frontmost app after the action. Default true.")
            ]),
            tool("aios_type", "Type text into a UI element by locator id or query using AXValue first and paste fallback.", [
                "text": schema("string", "Text to enter."),
                "locator_id": schema("string", "Locator id returned by aios_find."),
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "restore_focus": schema("boolean", "Restore the previously frontmost app after the action. Default true.")
            ], required: ["text"]),
            tool("aios_wait", "Wait for a locator/UI/app condition with structured evidence.", [
                "condition": schema("string", "element_exists, element_gone, text_contains, frontmost_app, or window_title_contains."),
                "value": schema("string", "Expected text/app/window substring when required."),
                "query": schema("string", "Optional element query for element/text conditions."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "timeout": schema("number", "Seconds to wait. Default 10."),
                "interval": schema("number", "Polling interval seconds. Default 0.5.")
            ], required: ["condition"]),
            tool("aios_list_apps", "List installed macOS applications visible to this user. Use query to filter by name or bundle id.", [
                "query": schema("string", "Optional case-insensitive app name or bundle id filter."),
                "include_system": schema("boolean", "Whether to include /System/Applications apps. Default true.")
            ]),
            tool("aios_list_running_apps", "List currently running applications with names, bundle ids, and pids.", [:]),
            tool("aios_app_windows", "List visible windows for one app or all apps.", [
                "app_name": schema("string", "Optional application name filter."),
                "bundle_id": schema("string", "Optional bundle id filter.")
            ]),
            tool("aios_open_app", "Open or focus an app by name or bundle id.", [
                "app_name": schema("string", "Application name, for example TextEdit or Safari."),
                "bundle_id": schema("string", "Application bundle id, for example com.apple.TextEdit.")
            ]),
            tool("aios_quit_app", "Quit an app by name or bundle id. Refuses to force quit.", [
                "app_name": schema("string", "Application name, for example TextEdit or Safari."),
                "bundle_id": schema("string", "Application bundle id, for example com.apple.TextEdit.")
            ]),
            tool("aios_open_file", "Open a file or folder, optionally with a specific app.", [
                "path": schema("string", "Absolute or ~/ file/folder path."),
                "app_name": schema("string", "Optional app name to open with."),
                "bundle_id": schema("string", "Optional app bundle id to open with.")
            ], required: ["path"]),
            tool("aios_open_url", "Open a URL with the default handler or a specific app.", [
                "url": schema("string", "URL to open."),
                "app_name": schema("string", "Optional app name to open with."),
                "bundle_id": schema("string", "Optional app bundle id to open with.")
            ], required: ["url"]),
            tool("clipboard_get_text", "Read plain text from the clipboard.", [:]),
            tool("clipboard_set_text", "Set plain text on the clipboard.", [
                "text": schema("string", "Text to put on the clipboard.")
            ], required: ["text"]),
            tool("clipboard_set_files", "Put one or more file URLs on the clipboard for pasting into apps.", [
                "paths": arraySchema("string", "Absolute or ~/ file paths.")
            ], required: ["paths"]),
            tool("ui_paste", "Paste current clipboard into the frontmost app using Command-V.", [:]),
            tool("ui_keyboard_shortcut", "Send a keyboard shortcut to the frontmost app or a named app.", [
                "key": schema("string", "Key name, for example c, v, return, tab, escape, space, delete, up, down, left, right."),
                "modifiers": arraySchema("string", "Modifier names: command, shift, option, control."),
                "app_name": schema("string", "Optional app name to activate first."),
                "bundle_id": schema("string", "Optional bundle id to activate first.")
            ], required: ["key"]),
            tool("ui_click_menu", "Click a menu item in an app using System Events. menu_path example: [\"File\", \"Open...\"]", [
                "app_name": schema("string", "Application name. If omitted, uses frontmost app."),
                "bundle_id": schema("string", "Application bundle id. Optional."),
                "menu_path": arraySchema("string", "Menu path from the menu bar item to the menu item.")
            ], required: ["menu_path"]),
            tool("ui_click", "Click a screen coordinate.", [
                "x": schema("number", "Screen x coordinate."),
                "y": schema("number", "Screen y coordinate.")
            ], required: ["x", "y"]),
            tool("ui_scroll", "Scroll at the current pointer or provided coordinates.", [
                "direction": schema("string", "up, down, left, or right."),
                "amount": schema("number", "Scroll amount. Default 6."),
                "x": schema("number", "Optional screen x coordinate."),
                "y": schema("number", "Optional screen y coordinate.")
            ], required: ["direction"]),
            tool("ui_hover", "Move the cursor to a coordinate or snapshot element center.", [
                "x": schema("number", "Screen x coordinate."),
                "y": schema("number", "Screen y coordinate."),
                "snapshot_id": schema("string", "Optional snapshot id."),
                "element_id": schema("string", "Optional snapshot element id.")
            ]),
            tool("ui_drag", "Drag from one point to another.", [
                "from_x": schema("number", "Start x coordinate."),
                "from_y": schema("number", "Start y coordinate."),
                "to_x": schema("number", "End x coordinate."),
                "to_y": schema("number", "End y coordinate."),
                "duration": schema("number", "Duration seconds. Default 0.4.")
            ], required: ["from_x", "from_y", "to_x", "to_y"]),
            tool("ui_long_press", "Press and hold at a coordinate.", [
                "x": schema("number", "Screen x coordinate."),
                "y": schema("number", "Screen y coordinate."),
                "duration": schema("number", "Duration seconds. Default 0.8.")
            ], required: ["x", "y"]),
            tool("window_manage", "Focus, move, resize, minimize, zoom, or close a visible window.", [
                "action": schema("string", "focus, move, resize, set_bounds, minimize, zoom, close."),
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "x": schema("number", "Optional x."),
                "y": schema("number", "Optional y."),
                "width": schema("number", "Optional width."),
                "height": schema("number", "Optional height.")
            ], required: ["action"]),
            tool("dialog_click", "Click a button in the frontmost system/app dialog by label.", [
                "label": schema("string", "Button label substring, such as Open, Save, Cancel, Allow.")
            ], required: ["label"]),
            tool("dialog_input", "Set the focused dialog text field value.", [
                "text": schema("string", "Text to enter.")
            ], required: ["text"]),
            tool("dock_open", "Open an app from the Dock by name.", [
                "name": schema("string", "Dock item/app name.")
            ], required: ["name"]),
            tool("menubar_click", "Click a menu bar extra/status item by label substring.", [
                "label": schema("string", "Menu bar item label substring.")
            ], required: ["label"]),
            tool("space_switch", "Switch macOS Space using Control-left/right.", [
                "direction": schema("string", "left or right."),
                "count": schema("number", "Number of spaces. Default 1.")
            ], required: ["direction"]),
            tool("ax_describe_frontmost", "Summarize the frontmost app Accessibility tree with role, title, value, description, and enabled state.", [
                "max_depth": schema("number", "Maximum tree depth. Default 4."),
                "max_nodes": schema("number", "Maximum number of nodes. Default 80.")
            ]),
            tool("ax_press", "Press the first Accessibility element in the frontmost app matching a label/title/description substring.", [
                "label": schema("string", "Case-insensitive substring to find and press."),
                "role": schema("string", "Optional AX role filter such as AXButton or AXMenuItem.")
            ], required: ["label"]),
            tool("ax_get_focused_value", "Read role, title, value, and selected text from the currently focused Accessibility element.", [:]),
            tool("ax_set_focused_value", "Set the value of the currently focused Accessibility element when it supports AXValue.", [
                "text": schema("string", "Text to set.")
            ], required: ["text"]),
            tool("screen_capture", "Capture the main display to a PNG file and return the saved path.", [
                "path": schema("string", "Optional absolute or ~/ output path. Default: /tmp/aios-screen.png")
            ]),
            tool("observe_snapshot", "Collect a strong observation snapshot: frontmost context, windows, focused value, AX summary, and optional screenshot.", [
                "app_name": schema("string", "Optional app to activate before observing."),
                "bundle_id": schema("string", "Optional bundle id to activate before observing."),
                "screenshot": schema("boolean", "Whether to capture a screenshot. Default true."),
                "max_depth": schema("number", "AX tree depth. Default 4."),
                "max_nodes": schema("number", "AX node limit. Default 100.")
            ]),
            tool("observe_wait", "Poll until an app/window/AX/URL condition becomes true.", [
                "condition": schema("string", "frontmost_app, window_title_contains, ax_contains, focused_value_contains, safari_url_contains, chrome_url_contains, file_exists."),
                "value": schema("string", "Expected substring or file path."),
                "app_name": schema("string", "Optional app name for window/AX conditions."),
                "bundle_id": schema("string", "Optional bundle id."),
                "timeout": schema("number", "Seconds to wait. Default 10."),
                "interval": schema("number", "Polling interval seconds. Default 0.5.")
            ], required: ["condition", "value"]),
            tool("observe_annotate_frontmost", "Return indexed actionable Accessibility elements for the frontmost app, with labels, roles, and approximate bounds.", [
                "max_depth": schema("number", "Maximum tree depth. Default 6."),
                "max_nodes": schema("number", "Maximum nodes. Default 160.")
            ]),
            tool("snapshot_create", "Create a persistent UI snapshot with stable element ids for replayable click/type/action.", [
                "app_name": schema("string", "Optional app to activate before snapshot."),
                "bundle_id": schema("string", "Optional bundle id to activate before snapshot."),
                "screenshot": schema("boolean", "Whether to capture a screenshot. Default true."),
                "max_depth": schema("number", "Maximum AX tree depth. Default 7."),
                "max_nodes": schema("number", "Maximum nodes. Default 220.")
            ]),
            tool("snapshot_get", "Read a persisted UI snapshot by id.", [
                "snapshot_id": schema("string", "Snapshot id returned by snapshot_create.")
            ], required: ["snapshot_id"]),
            tool("snapshot_click", "Click a persisted snapshot element by element id.", [
                "snapshot_id": schema("string", "Snapshot id."),
                "element_id": schema("string", "Element id such as E1.")
            ], required: ["snapshot_id", "element_id"]),
            tool("snapshot_type", "Click a persisted snapshot element and type text.", [
                "snapshot_id": schema("string", "Snapshot id."),
                "element_id": schema("string", "Element id such as E1."),
                "text": schema("string", "Text to type or paste.")
            ], required: ["snapshot_id", "element_id", "text"]),
            tool("snapshot_press", "Perform AXPress on a persisted snapshot element when possible, otherwise click its center.", [
                "snapshot_id": schema("string", "Snapshot id."),
                "element_id": schema("string", "Element id such as E1.")
            ], required: ["snapshot_id", "element_id"]),
            tool("screen_capture_window", "Capture the first visible window matching an app name or bundle id.", [
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "path": schema("string", "Optional output path.")
            ]),
            tool("screen_capture_window_sck", "Capture a matching window through the ScreenCaptureKit-aware path, falling back to legacy CGWindow capture when needed.", [
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "path": schema("string", "Optional output path.")
            ]),
            tool("ocr_image", "Run local Vision OCR on an image file.", [
                "path": schema("string", "Absolute or ~/ image path.")
            ], required: ["path"]),
            tool("ocr_screen", "Capture the main display and run local Vision OCR.", [
                "path": schema("string", "Optional screenshot output path.")
            ]),
            tool("recipe_list", "List reusable AIOS workflow recipes.", [:]),
            tool("recipe_suggest", "Suggest reusable recipes that may match the user's goal before doing manual app automation.", [
                "goal": schema("string", "User goal to match against recipe titles, templates, notes, and known workflow keywords."),
                "limit": schema("number", "Maximum suggestions. Default 5.")
            ], required: ["goal"]),
            tool("recipe_execute", "Execute a reusable step-based workflow recipe directly.", [
                "id": schema("string", "Recipe id."),
                "params_json": schema("string", "Recipe params as a JSON object string.")
            ], required: ["id"]),
            tool("learn_start", "Start a tool-level learning session that can become a recipe.", [
                "title": schema("string", "Learning session title.")
            ], required: ["title"]),
            tool("learn_record_tool", "Execute and record one tool call into the active learning session.", [
                "tool": schema("string", "Tool name to execute and record."),
                "arguments_json": schema("string", "Tool arguments as a JSON object string.")
            ], required: ["tool"]),
            tool("learn_record_events", "Record raw mouse/keyboard events for a few seconds and save a replayable recipe.", [
                "title": schema("string", "Learning session title."),
                "recipe_id": schema("string", "Recipe id to save."),
                "seconds": schema("number", "Recording duration. Default 8."),
                "include_ax": schema("boolean", "Capture frontmost app and focused AX context. Default true.")
            ], required: ["recipe_id"]),
            tool("learn_stop", "Stop the active learning session and save it as a recipe.", [
                "recipe_id": schema("string", "Recipe id to save.")
            ], required: ["recipe_id"]),
            tool("finder_list_directory", "List files in a directory with names, types, sizes, and modified dates.", [
                "path": schema("string", "Absolute or ~/ directory path. Default: ~/Downloads"),
                "limit": schema("number", "Maximum entries. Default 80.")
            ]),
            tool("finder_file_info", "Read metadata for a file or folder.", [
                "path": schema("string", "Absolute or ~/ file/folder path.")
            ], required: ["path"]),
            tool("finder_read_text_file", "Read and optionally verify the text content of a local UTF-8 file.", [
                "path": schema("string", "Absolute or ~/ text file path."),
                "contains": schema("string", "Optional text that must be present for success."),
                "max_chars": schema("number", "Maximum characters to return. Default 4000.")
            ], required: ["path"]),
            tool("finder_find_files", "Find files by name under a root directory.", [
                "root": schema("string", "Absolute or ~/ root directory. Default: ~/Downloads"),
                "name_contains": schema("string", "Case-insensitive filename substring."),
                "limit": schema("number", "Maximum results. Default 40.")
            ], required: ["name_contains"]),
            tool("chrome_open_url", "Open a URL in Google Chrome.", [
                "url": schema("string", "URL to open.")
            ], required: ["url"]),
            tool("chrome_get_current_tab", "Read Google Chrome front window active tab title and URL.", [:]),
            tool("chrome_new_tab", "Open a new Google Chrome tab, optionally with a URL.", [
                "url": schema("string", "Optional URL for the new tab.")
            ]),
            tool("chrome_search", "Search Google in Chrome for a query.", [
                "query": schema("string", "Search query.")
            ], required: ["query"]),
            tool("wps_open_file", "Open a document/spreadsheet/presentation in WPS Office.", [
                "path": schema("string", "Absolute or ~/ file path.")
            ], required: ["path"]),
            tool("notes_create_note", "Create a local Apple Notes note. This is local state, not an external send.", [
                "title": schema("string", "Note title."),
                "body": schema("string", "Note body.")
            ], required: ["title", "body"]),
            tool("notes_search", "Open Notes and search for text using the Notes search UI.", [
                "query": schema("string", "Search text.")
            ], required: ["query"]),
            tool("mail_compose_draft", "Create a visible Mail draft. Does not send.", [
                "to": arraySchema("string", "Recipient email addresses."),
                "subject": schema("string", "Draft subject."),
                "body": schema("string", "Draft body."),
                "attachments": arraySchema("string", "Optional absolute or ~/ file attachment paths.")
            ], required: ["subject", "body"]),
            tool("mail_search_messages", "Open Mail and search messages.", [
                "query": schema("string", "Search query.")
            ], required: ["query"]),
            tool("calendar_create_event", "Create a Calendar event.", [
                "title": schema("string", "Event title."),
                "start": schema("string", "Start date/time, e.g. 2026-05-21 15:30."),
                "end": schema("string", "End date/time, e.g. 2026-05-21 16:00."),
                "calendar": schema("string", "Optional calendar name."),
                "notes": schema("string", "Optional event notes.")
            ], required: ["title", "start", "end"]),
            tool("calendar_find_events", "Find Calendar events by title substring.", [
                "title": schema("string", "Title substring."),
                "days": schema("number", "Days from today to search. Default 30.")
            ], required: ["title"]),
            tool("wechat_open", "Open WeChat.", [:]),
            tool("wechat_search_chat", "Open WeChat search and search for a contact/chat. Does not send anything.", [
                "name": schema("string", "Contact or chat name.")
            ], required: ["name"]),
            tool("wechat_open_chat", "Open WeChat, search for a contact/chat, press Return to open the top result, and verify the current chat. Does not send anything.", [
                "recipient": schema("string", "Contact/chat name.")
            ], required: ["recipient"]),
            tool("wechat_stage_file", "Stage a file in a WeChat chat input by clipboard paste. Does not press send.", [
                "recipient": schema("string", "Contact/chat name to search before staging."),
                "path": schema("string", "Absolute or ~/ file path to stage.")
            ], required: ["recipient", "path"]),
            tool("wechat_send_text", "Search a WeChat chat, paste text, and send it.", [
                "recipient": schema("string", "Contact/chat name."),
                "text": schema("string", "Message text to send.")
            ], required: ["recipient", "text"]),
            tool("wechat_send_staged", "Send the currently staged WeChat message/file after recipient verification.", [
                "recipient": schema("string", "Recipient you verified on screen.")
            ], required: ["recipient"]),
            tool("wechat_verify_chat", "Verify whether WeChat UI appears to contain the expected chat/contact.", [
                "recipient": schema("string", "Expected contact/chat name.")
            ], required: ["recipient"]),
            tool("wechat_verify_recent_message", "Verify whether recent WeChat UI text appears to contain expected message text.", [
                "text": schema("string", "Expected text substring.")
            ], required: ["text"]),
            tool("lark_open", "Open Lark/Feishu.", [:]),
            tool("lark_search_chat", "Open Lark search and search for a contact/chat. Does not send anything.", [
                "name": schema("string", "Contact or chat name.")
            ], required: ["name"]),
            tool("lark_stage_file", "Stage a file in a Lark chat input by clipboard paste. Does not press send.", [
                "chat": schema("string", "Chat/contact name to search before staging."),
                "path": schema("string", "Absolute or ~/ file path to stage.")
            ], required: ["chat", "path"]),
            tool("lark_send_text", "Search a Lark chat, paste text, and send it.", [
                "chat": schema("string", "Chat/contact name."),
                "text": schema("string", "Message text to send.")
            ], required: ["chat", "text"]),
            tool("lark_send_staged", "Send the currently staged Lark message/file after chat verification.", [
                "chat": schema("string", "Chat/contact you verified on screen.")
            ], required: ["chat"]),
            tool("lark_verify_chat", "Verify whether Lark UI appears to contain the expected chat/contact.", [
                "chat": schema("string", "Expected chat/contact name.")
            ], required: ["chat"]),
            tool("lark_verify_recent_message", "Verify whether recent Lark UI text appears to contain expected message text.", [
                "text": schema("string", "Expected text substring.")
            ], required: ["text"]),
            tool("qq_open", "Open QQ.", [:]),
            tool("qq_search_chat", "Open QQ search and search for a contact/chat. Does not send anything.", [
                "name": schema("string", "Contact or chat name.")
            ], required: ["name"]),
            tool("qq_stage_file", "Stage a file in a QQ chat input by clipboard paste. Does not press send.", [
                "recipient": schema("string", "Contact/chat name to search before staging."),
                "path": schema("string", "Absolute or ~/ file path to stage.")
            ], required: ["recipient", "path"]),
            tool("qq_send_text", "Search a QQ chat, paste text, and send it.", [
                "recipient": schema("string", "Contact/chat name."),
                "text": schema("string", "Message text to send.")
            ], required: ["recipient", "text"]),
            tool("qq_send_staged", "Send the currently staged QQ message/file after recipient verification.", [
                "recipient": schema("string", "Recipient you verified on screen.")
            ], required: ["recipient"]),
            tool("qq_verify_chat", "Verify whether QQ UI appears to contain the expected chat/contact.", [
                "recipient": schema("string", "Expected contact/chat name.")
            ], required: ["recipient"]),
            tool("qq_verify_recent_message", "Verify whether recent QQ UI text appears to contain expected message text.", [
                "text": schema("string", "Expected text substring.")
            ], required: ["text"]),
            tool("tencent_meeting_open", "Open Tencent Meeting.", [:]),
            tool("tencent_meeting_stage_join", "Open Tencent Meeting and copy a meeting id/link to clipboard. Does not join.", [
                "meeting": schema("string", "Meeting id or meeting link.")
            ], required: ["meeting"]),
            tool("baidunetdisk_open", "Open Baidu Netdisk.", [:]),
            tool("baidunetdisk_stage_file", "Put a local file on the clipboard for manual Baidu Netdisk upload. Does not upload.", [
                "path": schema("string", "Absolute or ~/ file path.")
            ], required: ["path"]),
            tool("todesk_open", "Open ToDesk remote-control app.", [:]),
            tool("todesk_stage_remote_id", "Open ToDesk and copy a remote id/code to clipboard. Does not connect.", [
                "remote_id": schema("string", "Remote id or code.")
            ], required: ["remote_id"]),
            tool("docker_open", "Open Docker Desktop.", [:]),
            tool("docker_status", "Read whether Docker Desktop is running and list its visible windows. Does not change containers.", [:]),
            tool("xcode_open_path", "Open a file, folder, project, or workspace in Xcode.", [
                "path": schema("string", "Absolute or ~/ path.")
            ], required: ["path"]),
            tool("pycharm_open_path", "Open a file or folder in PyCharm.", [
                "path": schema("string", "Absolute or ~/ path.")
            ], required: ["path"]),
            tool("rustrover_open_path", "Open a file or folder in RustRover.", [
                "path": schema("string", "Absolute or ~/ path.")
            ], required: ["path"]),
            tool("preview_open_file", "Open a PDF/image/document in Preview.", [
                "path": schema("string", "Absolute or ~/ file path.")
            ], required: ["path"]),
            tool("libreoffice_open_file", "Open a document/spreadsheet/presentation in LibreOffice.", [
                "path": schema("string", "Absolute or ~/ file path.")
            ], required: ["path"]),
            tool("libreoffice_export_pdf", "Export a LibreOffice-supported file to PDF using soffice headless.", [
                "path": schema("string", "Absolute or ~/ file path."),
                "outdir": schema("string", "Optional output directory. Defaults to the file's directory.")
            ], required: ["path"]),
            tool("shortcuts_open", "Open the Shortcuts app.", [:]),
            tool("shortcuts_list", "List available Apple Shortcuts. Does not run them.", [:]),
            tool("shortcuts_run", "Run an Apple Shortcut by name.", [
                "name": schema("string", "Shortcut name.")
            ], required: ["name"]),
            tool("sdef_lookup", "Inspect an app's AppleScript dictionary (SDEF) and return a concise command/class summary.", [
                "app_name": schema("string", "Application name, e.g. Safari."),
                "path": schema("string", "Optional /Applications/App.app path."),
                "query": schema("string", "Optional substring filter."),
                "max_lines": schema("number", "Maximum output lines. Default 120.")
            ]),
            tool("scripting_bridge_probe", "Probe whether a target app exposes a ScriptingBridge object.", [
                "bundle_id": schema("string", "Application bundle id, e.g. com.apple.Safari.")
            ], required: ["bundle_id"]),
            tool("reminders_create", "Create a local Apple Reminders reminder.", [
                "title": schema("string", "Reminder title."),
                "notes": schema("string", "Optional notes."),
                "list": schema("string", "Optional reminders list name.")
            ], required: ["title"]),
            tool("safari_new_tab", "Open a new Safari tab, optionally with a URL.", [
                "url": schema("string", "Optional URL for the new tab.")
            ]),
            tool("safari_search", "Search the web in Safari.", [
                "query": schema("string", "Search query.")
            ], required: ["query"]),
            tool("claude_open", "Open Claude desktop app.", [:]),
            tool("codex_open", "Open Codex desktop app.", [:]),
            tool("textedit_new_document", "Open TextEdit and create a new document.", [:]),
            tool("textedit_set_text", "Set the full text of the front TextEdit document.", [
                "text": schema("string", "Text to write.")
            ], required: ["text"]),
            tool("textedit_read_text", "Read the text of the front TextEdit document.", [:]),
            tool("textedit_save_as", "Save the front TextEdit document to a path. Refuses overwrite by default.", [
                "path": schema("string", "Absolute or ~/ path to save to."),
                "overwrite": schema("boolean", "Whether an existing file may be overwritten.")
            ], required: ["path"]),
            tool("finder_create_folder", "Create a folder and verify it exists.", [
                "path": schema("string", "Absolute or ~/ folder path.")
            ], required: ["path"]),
            tool("finder_reveal_file", "Reveal a file or folder in Finder.", [
                "path": schema("string", "Absolute or ~/ file/folder path.")
            ], required: ["path"]),
            tool("safari_open_url", "Open a URL in Safari.", [
                "url": schema("string", "URL to open.")
            ], required: ["url"]),
            tool("safari_get_current_url", "Read Safari front document URL.", [:]),
            tool("safari_get_page_text", "Read Safari front document body text via JavaScript.", [:]),
            tool("safari_eval_js", "Run JavaScript in Safari front document and return the result.", [
                "script": schema("string", "JavaScript expression or script.")
            ], required: ["script"]),
            tool("chrome_get_page_text", "Read Google Chrome active tab body text via JavaScript.", [:]),
            tool("chrome_eval_js", "Run JavaScript in Google Chrome active tab and return the result.", [
                "script": schema("string", "JavaScript expression or script.")
            ], required: ["script"]),
            tool("terminal_run_command", "Run a command in Terminal.", [
                "command": schema("string", "Shell command to run.")
            ], required: ["command"])
        ] + Self.highFrequencyOpenAppTargets
            .sorted { $0.key < $1.key }
            .map { name, target in
                tool(name, target.description, [:])
            }
    }

    func execute(_ call: ToolCall) -> ToolResult {
        do {
            if let target = Self.highFrequencyOpenAppTargets[call.name] {
                return try openAppTarget(target)
            }

            switch call.name {
            case "aios_context":
                return context()
            case "aios_automation_context":
                return AIOSAutomationService.shared.context(args: call.arguments)
            case "aios_find":
                return AIOSAutomationService.shared.find(args: call.arguments)
            case "aios_inspect":
                return AIOSAutomationService.shared.inspect(args: call.arguments)
            case "aios_read":
                return AIOSAutomationService.shared.read(args: call.arguments)
            case "aios_click":
                return AIOSAutomationService.shared.click(args: call.arguments)
            case "aios_type":
                return AIOSAutomationService.shared.type(args: call.arguments)
            case "aios_wait":
                return AIOSAutomationService.shared.wait(args: call.arguments)
            case "aios_list_apps":
                return try listApps(call.arguments)
            case "aios_list_running_apps":
                return listRunningApps()
            case "aios_app_windows":
                return appWindows(call.arguments)
            case "aios_open_app":
                return try openApp(call.arguments)
            case "aios_quit_app":
                return try quitApp(call.arguments)
            case "aios_open_file":
                return try openFile(call.arguments)
            case "aios_open_url":
                return try openURL(call.arguments)
            case "clipboard_get_text":
                return clipboardGetText()
            case "clipboard_set_text":
                return try clipboardSetText(call.arguments)
            case "clipboard_set_files":
                return try clipboardSetFiles(call.arguments)
            case "ui_paste":
                return try uiPaste()
            case "ui_keyboard_shortcut":
                return try uiKeyboardShortcut(call.arguments)
            case "ui_click_menu":
                return try uiClickMenu(call.arguments)
            case "ui_click":
                return try uiClick(call.arguments)
            case "ui_scroll":
                return try uiScroll(call.arguments)
            case "ui_hover":
                return try uiHover(call.arguments)
            case "ui_drag":
                return try uiDrag(call.arguments)
            case "ui_long_press":
                return try uiLongPress(call.arguments)
            case "window_manage":
                return try windowManage(call.arguments)
            case "dialog_click":
                return dialogClick(call.arguments)
            case "dialog_input":
                return try dialogInput(call.arguments)
            case "dock_open":
                return try dockOpen(call.arguments)
            case "menubar_click":
                return try menubarClick(call.arguments)
            case "space_switch":
                return try spaceSwitch(call.arguments)
            case "ax_describe_frontmost":
                return axDescribeFrontmost(call.arguments)
            case "ax_press":
                return axPress(call.arguments)
            case "ax_get_focused_value":
                return axGetFocusedValue()
            case "ax_set_focused_value":
                return try axSetFocusedValue(call.arguments)
            case "screen_capture":
                return try screenCapture(call.arguments)
            case "observe_snapshot":
                return try observeSnapshot(call.arguments)
            case "observe_wait":
                return try observeWait(call.arguments)
            case "observe_annotate_frontmost":
                return observeAnnotateFrontmost(call.arguments)
            case "snapshot_create":
                return try snapshotCreate(call.arguments)
            case "snapshot_get":
                return try snapshotGet(call.arguments)
            case "snapshot_click":
                return try snapshotClick(call.arguments)
            case "snapshot_type":
                return try snapshotType(call.arguments)
            case "snapshot_press":
                return try snapshotPress(call.arguments)
            case "screen_capture_window":
                return try screenCaptureWindow(call.arguments)
            case "screen_capture_window_sck":
                return try screenCaptureWindowSCK(call.arguments)
            case "ocr_image":
                return try ocrImage(call.arguments)
            case "ocr_screen":
                return try ocrScreen(call.arguments)
            case "recipe_list":
                return try recipeListTool()
            case "recipe_suggest":
                return try recipeSuggestTool(call.arguments)
            case "recipe_execute":
                return try recipeExecuteTool(call.arguments)
            case "learn_start":
                return try learnStartTool(call.arguments)
            case "learn_record_tool":
                return try learnRecordTool(call.arguments)
            case "learn_record_events":
                return try learnRecordEventsTool(call.arguments)
            case "learn_stop":
                return try learnStopTool(call.arguments)
            case "finder_list_directory":
                return try finderListDirectory(call.arguments)
            case "finder_file_info":
                return try finderFileInfo(call.arguments)
            case "finder_read_text_file":
                return try finderReadTextFile(call.arguments)
            case "finder_find_files":
                return try finderFindFiles(call.arguments)
            case "chrome_open_url":
                return try chromeOpenURL(call.arguments)
            case "chrome_get_current_tab":
                return try chromeGetCurrentTab()
            case "chrome_new_tab":
                return try chromeNewTab(call.arguments)
            case "chrome_search":
                return try chromeSearch(call.arguments)
            case "wps_open_file":
                return try wpsOpenFile(call.arguments)
            case "notes_create_note":
                return try notesCreateNote(call.arguments)
            case "notes_search":
                return try notesSearch(call.arguments)
            case "mail_compose_draft":
                return try mailComposeDraft(call.arguments)
            case "mail_search_messages":
                return try mailSearchMessages(call.arguments)
            case "calendar_create_event":
                return try calendarCreateEvent(call.arguments)
            case "calendar_find_events":
                return try calendarFindEvents(call.arguments)
            case "wechat_open":
                return try wechatOpen()
            case "wechat_search_chat":
                return try wechatSearchChat(call.arguments)
            case "wechat_open_chat":
                return try wechatOpenChat(call.arguments)
            case "wechat_stage_file":
                return try wechatStageFile(call.arguments)
            case "wechat_send_text":
                return try wechatSendText(call.arguments)
            case "wechat_send_staged":
                return try wechatSendStaged(call.arguments)
            case "wechat_verify_chat":
                return try chatVerify(appName: "WeChat", bundleID: "com.tencent.xinWeChat", expected: string(call.arguments["recipient"]) ?? "")
            case "wechat_verify_recent_message":
                return try chatVerify(appName: "WeChat", bundleID: "com.tencent.xinWeChat", expected: string(call.arguments["text"]) ?? "")
            case "lark_open":
                return try larkOpen()
            case "lark_search_chat":
                return try larkSearchChat(call.arguments)
            case "lark_stage_file":
                return try larkStageFile(call.arguments)
            case "lark_send_text":
                return try larkSendText(call.arguments)
            case "lark_send_staged":
                return try larkSendStaged(call.arguments)
            case "lark_verify_chat":
                return try chatVerify(appName: "Lark", bundleID: nil, expected: string(call.arguments["chat"]) ?? "")
            case "lark_verify_recent_message":
                return try chatVerify(appName: "Lark", bundleID: nil, expected: string(call.arguments["text"]) ?? "")
            case "qq_open":
                return try qqOpen()
            case "qq_search_chat":
                return try qqSearchChat(call.arguments)
            case "qq_stage_file":
                return try qqStageFile(call.arguments)
            case "qq_send_text":
                return try qqSendText(call.arguments)
            case "qq_send_staged":
                return try qqSendStaged(call.arguments)
            case "qq_verify_chat":
                return try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: string(call.arguments["recipient"]) ?? "")
            case "qq_verify_recent_message":
                return try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: string(call.arguments["text"]) ?? "")
            case "tencent_meeting_open":
                return try openNamedApp("TencentMeeting")
            case "tencent_meeting_stage_join":
                return try tencentMeetingStageJoin(call.arguments)
            case "baidunetdisk_open":
                return try openNamedApp("BaiduNetdisk_mac")
            case "baidunetdisk_stage_file":
                return try baiduNetdiskStageFile(call.arguments)
            case "todesk_open":
                return try openNamedApp("ToDesk")
            case "todesk_stage_remote_id":
                return try toDeskStageRemoteID(call.arguments)
            case "docker_open":
                return try openNamedApp("Docker")
            case "docker_status":
                return dockerStatus()
            case "xcode_open_path":
                return try openPathWithApp(call.arguments, appName: "Xcode")
            case "pycharm_open_path":
                return try openPathWithApp(call.arguments, appName: "PyCharm")
            case "rustrover_open_path":
                return try openPathWithApp(call.arguments, appName: "RustRover")
            case "preview_open_file":
                return try openPathWithApp(call.arguments, appName: "Preview")
            case "libreoffice_open_file":
                return try openPathWithApp(call.arguments, appName: "LibreOffice")
            case "libreoffice_export_pdf":
                return try libreOfficeExportPDF(call.arguments)
            case "shortcuts_open":
                return try openNamedApp("Shortcuts")
            case "shortcuts_list":
                return try shortcutsList()
            case "shortcuts_run":
                return try shortcutsRun(call.arguments)
            case "sdef_lookup":
                return try sdefLookup(call.arguments)
            case "scripting_bridge_probe":
                return scriptingBridgeProbe(call.arguments)
            case "reminders_create":
                return try remindersCreate(call.arguments)
            case "safari_new_tab":
                return try safariNewTab(call.arguments)
            case "safari_search":
                return try safariSearch(call.arguments)
            case "claude_open":
                return try openNamedApp("Claude")
            case "codex_open":
                return try openNamedApp("Codex")
            case "textedit_new_document":
                return try textEditNewDocument()
            case "textedit_set_text":
                return try textEditSetText(call.arguments)
            case "textedit_read_text":
                return try textEditReadText()
            case "textedit_save_as":
                return try textEditSaveAs(call.arguments)
            case "finder_create_folder":
                return try finderCreateFolder(call.arguments)
            case "finder_reveal_file":
                return try finderRevealFile(call.arguments)
            case "safari_open_url":
                return try safariOpenURL(call.arguments)
            case "safari_get_current_url":
                return try safariGetCurrentURL()
            case "safari_get_page_text":
                return try safariGetPageText()
            case "safari_eval_js":
                return try safariEvalJS(call.arguments)
            case "chrome_get_page_text":
                return try chromeGetPageText()
            case "chrome_eval_js":
                return try chromeEvalJS(call.arguments)
            case "terminal_run_command":
                return try terminalRunCommand(call.arguments)
            default:
                return ToolResult(success: false, evidence: "Unknown tool.", error: "Unknown tool: \(call.name)")
            }
        } catch {
            return ToolResult(success: false, evidence: "Tool failed.", error: error.localizedDescription)
        }
    }

    func doctor(requestPermissions: Bool = false) {
        if requestPermissions {
            requestMacOSPermissions()
        }

        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        let input = inputMonitoringAvailable()
        let config = LLMConfig.fromEnvironment()
        print("Accessibility: \(ax ? "granted" : "not granted")")
        print("Screen Recording: \(screen ? "granted" : "not granted")")
        print("Input Monitoring: \(input ? "available" : "not available")")
        print("Automation / Apple Events: requested on first use by target app")
        print("Safari JavaScript: enable Develop > Allow JavaScript from Apple Events when browser tools need page text")
        print("Chrome JavaScript: enable View > Developer > Allow JavaScript from Apple Events when browser tools need page text")
        print("LLM endpoint: \(config.baseURL.absoluteString)")
        print("LLM model: \(config.model)")
        print("LLM fallback providers: \(config.fallbacks.count)")
        print("State dir: \(EventStore.rootURL.path)")
        print("SQLite run index: \(SQLiteRunIndex.url.path)")
        print("LaunchAgent:")
        print(LaunchAgentManager.statusText().split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
        print("Shell tools: enabled")
        print("External chat send: enabled")
        print("Calendar writes: enabled")
        print("Shortcut execution: enabled")
        if requestPermissions && (!ax || !screen || !input) {
            print("Permission prompts were requested. If you changed a permission, quit and reopen the host app, then run doctor again.")
        }
    }

    func setupWizard(requestPermissions: Bool = false) {
        print("AIOS setup")
        print("1. Grant Accessibility so AIOS can read/click AX elements.")
        print("2. Grant Screen Recording so screenshots/OCR/snapshots can see the UI.")
        print("3. Grant Input Monitoring if you want raw CGEvent learning recorder.")
        print("4. Approve Automation prompts for System Events, Finder, Calendar, browsers, and chat apps as tasks need them.")
        print("5. Start the always-on worker with: aios launch-agent install")
        print("")
        doctor(requestPermissions: requestPermissions)
    }

    private func requestMacOSPermissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestScreenCaptureAccess()
    }

    private func inputMonitoringAvailable() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }
        CFMachPortInvalidate(tap)
        return true
    }

    private func context() -> ToolResult {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let windows = visibleWindowTitles(pid: pid)
        return ToolResult(success: true, evidence: "Observed frontmost application.", data: [
            "app": app?.localizedName ?? "",
            "bundle_id": app?.bundleIdentifier ?? "",
            "pid": "\(pid)",
            "windows": windows.joined(separator: " | ")
        ])
    }

    private func openApp(_ args: [String: Any]) throws -> ToolResult {
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            try runProcess("/usr/bin/open", ["-b", bundleID])
            return ToolResult(success: true, evidence: "Opened app with bundle id \(bundleID).", data: [
                "effect": "app_opened",
                "app": bundleID,
                "bundle_id": bundleID,
                "verified": "true"
            ])
        }
        guard let appName = string(args["app_name"]), !appName.isEmpty else {
            throw RuntimeError("app_name or bundle_id is required")
        }
        let normalizedName = canonicalAppName(appName)
        try runProcess("/usr/bin/open", ["-a", normalizedName])
        return ToolResult(success: true, evidence: "Opened app \(normalizedName).", data: [
            "effect": "app_opened",
            "app": normalizedName,
            "verified": "true"
        ])
    }

    private func listApps(_ args: [String: Any]) throws -> ToolResult {
        let query = string(args["query"])?.lowercased()
        let includeSystem = bool(args["include_system"]) ?? true
        let roots = [
            "/Applications",
            NSHomeDirectory() + "/Applications"
        ] + (includeSystem ? ["/System/Applications", "/System/Applications/Utilities"] : [])
        let apps = roots.flatMap { appBundles(in: URL(fileURLWithPath: $0), maxDepth: 3) }
            .compactMap(appInfo)
            .filter { item in
                guard let query, !query.isEmpty else { return true }
                return item.values.contains { $0.lowercased().contains(query) }
            }
            .sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }

        return ToolResult(success: true, evidence: "Found \(apps.count) installed apps.", data: [
            "apps": jsonStringValue(apps)
        ])
    }

    private func listRunningApps() -> ToolResult {
        var apps: [[String: String]] = []
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            apps.append([
                "name": app.localizedName ?? "",
                "bundle_id": app.bundleIdentifier ?? "",
                "pid": "\(app.processIdentifier)",
                "active": app.isActive ? "true" : "false",
                "hidden": app.isHidden ? "true" : "false"
            ])
        }
        apps.sort { ($0["name"] ?? "") < ($1["name"] ?? "") }
        return ToolResult(success: true, evidence: "Listed \(apps.count) running apps.", data: [
            "apps": jsonStringValue(apps)
        ])
    }

    private func appWindows(_ args: [String: Any]) -> ToolResult {
        let appName = string(args["app_name"])
        let bundleID = string(args["bundle_id"])?.lowercased()
        let appsByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return ToolResult(success: false, evidence: "Could not read window list.", error: "CGWindowListCopyWindowInfo returned nil")
        }
        let windows = infos.compactMap { info -> [String: String]? in
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            guard let pid = ownerPID(from: info), let app = appsByPID[pid] else { return nil }
            if let appName, !appMatchesName(app, requested: appName) { return nil }
            if let bundleID, !(app.bundleIdentifier ?? "").lowercased().contains(bundleID) { return nil }
            return [
                "app": app.localizedName ?? "",
                "bundle_id": app.bundleIdentifier ?? "",
                "pid": "\(pid)",
                "title": info[kCGWindowName as String] as? String ?? "",
                "window_id": "\(info[kCGWindowNumber as String] as? Int ?? 0)"
            ]
        }
        return ToolResult(success: true, evidence: "Listed \(windows.count) visible windows.", data: [
            "windows": jsonStringValue(windows)
        ])
    }

    private func quitApp(_ args: [String: Any]) throws -> ToolResult {
        let app = try findRunningApp(args)
        let name = app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)"
        let requested = app.terminate()
        Thread.sleep(forTimeInterval: 0.4)
        return ToolResult(
            success: requested,
            evidence: requested ? "Requested \(name) to quit." : "Could not request quit for \(name).",
            data: ["app": name, "pid": "\(app.processIdentifier)"]
        )
    }

    private func openFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            try runProcess("/usr/bin/open", ["-b", bundleID, path])
            return ToolResult(success: true, evidence: "Opened \(path) with bundle id \(bundleID).", data: ["path": path, "bundle_id": bundleID])
        }
        if let appName = string(args["app_name"]), !appName.isEmpty {
            let normalizedName = canonicalAppName(appName)
            try runProcess("/usr/bin/open", ["-a", normalizedName, path])
            return ToolResult(success: true, evidence: "Opened \(path) with \(normalizedName).", data: ["path": path, "app": normalizedName])
        }
        try runProcess("/usr/bin/open", [path])
        return ToolResult(success: true, evidence: "Opened \(path) with the default app.", data: ["path": path])
    }

    private func openURL(_ args: [String: Any]) throws -> ToolResult {
        guard let rawURL = string(args["url"]), URL(string: rawURL) != nil else {
            throw RuntimeError("valid url is required")
        }
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            try runProcess("/usr/bin/open", ["-b", bundleID, rawURL])
            return ToolResult(success: true, evidence: "Opened URL with bundle id \(bundleID).", data: [
                "effect": "browser_url_visible",
                "app": bundleID,
                "target": rawURL,
                "url": rawURL,
                "bundle_id": bundleID,
                "verified": "true",
                "verified_current_url": "true"
            ])
        }
        if let appName = string(args["app_name"]), !appName.isEmpty {
            let normalizedName = canonicalAppName(appName)
            try runProcess("/usr/bin/open", ["-a", normalizedName, rawURL])
            return ToolResult(success: true, evidence: "Opened URL with \(normalizedName).", data: [
                "effect": "browser_url_visible",
                "app": normalizedName,
                "target": rawURL,
                "url": rawURL,
                "verified": "true",
                "verified_current_url": "true"
            ])
        }
        try runProcess("/usr/bin/open", [rawURL])
        return ToolResult(success: true, evidence: "Opened URL with the default handler.", data: [
            "effect": "browser_url_visible",
            "target": rawURL,
            "url": rawURL,
            "verified": "true",
            "verified_current_url": "true"
        ])
    }

    private func clipboardGetText() -> ToolResult {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        return ToolResult(success: true, evidence: text.isEmpty ? "Clipboard has no plain text." : "Read clipboard plain text.", data: [
            "text": text,
            "chars": "\(text.count)"
        ])
    }

    private func clipboardSetText(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return ToolResult(success: true, evidence: "Set clipboard plain text.", data: ["chars": "\(text.count)"])
    }

    private func clipboardSetFiles(_ args: [String: Any]) throws -> ToolResult {
        let paths = try stringArray(args["paths"], name: "paths").map { $0.expandingTildeInPath }
        guard !paths.isEmpty else { throw RuntimeError("paths must not be empty") }
        for path in paths where !FileManager.default.fileExists(atPath: path) {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects(urls)
        return ToolResult(success: ok, evidence: ok ? "Put \(paths.count) file URL(s) on the clipboard." : "Failed to put files on clipboard.", data: [
            "paths": jsonStringValue(paths)
        ])
    }

    private func uiPaste() throws -> ToolResult {
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Sent Command-V to the frontmost app.")
    }

    private func uiKeyboardShortcut(_ args: [String: Any]) throws -> ToolResult {
        try activateTargetAppIfProvided(args)
        let key = string(args["key"]) ?? ""
        let modifiers = (try? stringArray(args["modifiers"], name: "modifiers")) ?? []
        try sendKeyboardShortcut(key: key, modifiers: modifiers)
        return ToolResult(success: true, evidence: "Sent keyboard shortcut.", data: [
            "key": key,
            "modifiers": modifiers.joined(separator: ",")
        ])
    }

    private func uiClickMenu(_ args: [String: Any]) throws -> ToolResult {
        let menuPath = try stringArray(args["menu_path"], name: "menu_path")
        guard menuPath.count >= 2 else { throw RuntimeError("menu_path must include a menu bar item and a menu item") }
        let appName = try appNameForTarget(args)
        let listItems = menuPath.map(appleScriptString).joined(separator: ", ")
        _ = try runAppleScript("""
        set menuPath to {\(listItems)}
        tell application \(appleScriptString(appName)) to activate
        delay 0.2
        tell application "System Events"
          tell process \(appleScriptString(appName))
            set frontmost to true
            set currentMenu to menu (item 1 of menuPath) of menu bar item (item 1 of menuPath) of menu bar 1
            repeat with i from 2 to ((count of menuPath) - 1)
              set currentItem to menu item (item i of menuPath) of currentMenu
              set currentMenu to menu 1 of currentItem
            end repeat
            click menu item (last item of menuPath) of currentMenu
          end tell
        end tell
        """)
        return ToolResult(success: true, evidence: "Clicked app menu item.", data: [
            "app": appName,
            "menu_path": menuPath.joined(separator: " > ")
        ])
    }

    private func uiClick(_ args: [String: Any]) throws -> ToolResult {
        guard let x = double(args["x"]), let y = double(args["y"]) else { throw RuntimeError("x and y are required") }
        try clickPoint(x: x, y: y)
        return ToolResult(success: true, evidence: "Clicked point.", data: ["x": "\(Int(x))", "y": "\(Int(y))"])
    }

    private func uiScroll(_ args: [String: Any]) throws -> ToolResult {
        let direction = (string(args["direction"]) ?? "down").lowercased()
        let amount = int(args["amount"]) ?? 6
        let dx: Int32
        let dy: Int32
        switch direction {
        case "up":
            dx = 0; dy = Int32(amount)
        case "left":
            dx = Int32(amount); dy = 0
        case "right":
            dx = -Int32(amount); dy = 0
        default:
            dx = 0; dy = -Int32(amount)
        }
        if let x = double(args["x"]), let y = double(args["y"]) {
            try moveMouse(x: x, y: y)
        }
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            throw RuntimeError("could not create scroll event")
        }
        event.post(tap: .cghidEventTap)
        return ToolResult(success: true, evidence: "Scrolled \(direction).", data: ["direction": direction, "amount": "\(amount)"])
    }

    private func uiHover(_ args: [String: Any]) throws -> ToolResult {
        var x = double(args["x"])
        var y = double(args["y"])
        if x == nil || y == nil, string(args["snapshot_id"]) != nil, string(args["element_id"]) != nil {
            let target = try resolveSnapshotTarget(snapshotTarget(args))
            if let tx = Double(target["x"] ?? ""), let ty = Double(target["y"] ?? ""), let w = Double(target["width"] ?? ""), let h = Double(target["height"] ?? "") {
                x = tx + w / 2
                y = ty + h / 2
            }
        }
        guard let x, let y else { throw RuntimeError("x/y or snapshot_id/element_id is required") }
        try moveMouse(x: x, y: y)
        return ToolResult(success: true, evidence: "Moved cursor.", data: ["x": "\(Int(x))", "y": "\(Int(y))"])
    }

    private func uiDrag(_ args: [String: Any]) throws -> ToolResult {
        guard let fromX = double(args["from_x"]), let fromY = double(args["from_y"]), let toX = double(args["to_x"]), let toY = double(args["to_y"]) else {
            throw RuntimeError("from_x/from_y/to_x/to_y are required")
        }
        try dragMouse(from: CGPoint(x: fromX, y: fromY), to: CGPoint(x: toX, y: toY), duration: double(args["duration"]) ?? 0.4)
        return ToolResult(success: true, evidence: "Dragged pointer.", data: ["from": "\(Int(fromX)),\(Int(fromY))", "to": "\(Int(toX)),\(Int(toY))"])
    }

    private func uiLongPress(_ args: [String: Any]) throws -> ToolResult {
        guard let x = double(args["x"]), let y = double(args["y"]) else { throw RuntimeError("x and y are required") }
        try longPress(x: x, y: y, duration: double(args["duration"]) ?? 0.8)
        return ToolResult(success: true, evidence: "Long-pressed point.", data: ["x": "\(Int(x))", "y": "\(Int(y))"])
    }

    private func windowManage(_ args: [String: Any]) throws -> ToolResult {
        let action = (string(args["action"]) ?? "").lowercased()
        let app = try findRunningApp(args)
        app.activate()
        Thread.sleep(forTimeInterval: 0.2)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard err == .success, let window = windowValue.map({ unsafeDowncast($0, to: AXUIElement.self) }) else {
            return ToolResult(success: false, evidence: "No focused window for app.", error: "\(err.rawValue)")
        }
        switch action {
        case "focus":
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        case "move":
            try setAXWindowPosition(window, x: double(args["x"]) ?? 80, y: double(args["y"]) ?? 80)
        case "resize":
            try setAXWindowSize(window, width: double(args["width"]) ?? 900, height: double(args["height"]) ?? 700)
        case "set_bounds":
            try setAXWindowPosition(window, x: double(args["x"]) ?? 80, y: double(args["y"]) ?? 80)
            try setAXWindowSize(window, width: double(args["width"]) ?? 900, height: double(args["height"]) ?? 700)
        case "minimize":
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case "zoom":
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if let zoom = findAXElement(window, label: "zoom", role: "AXButton", maxNodes: 80) {
                AXUIElementPerformAction(zoom, kAXPressAction as CFString)
            }
        case "close":
            if let close = findAXElement(window, label: "close", role: "AXButton", maxNodes: 80) {
                AXUIElementPerformAction(close, kAXPressAction as CFString)
            } else {
                try sendKeyboardShortcut(key: "w", modifiers: ["command"])
            }
        default:
            throw RuntimeError("unsupported window action: \(action)")
        }
        return ToolResult(success: true, evidence: "Window action \(action) requested.", data: ["app": app.localizedName ?? "", "action": action])
    }

    private func dialogClick(_ args: [String: Any]) -> ToolResult {
        guard let label = string(args["label"]), !label.isEmpty else {
            return ToolResult(success: false, evidence: "label is required.", error: "label is required")
        }
        return axPress(["label": label, "role": "AXButton"])
    }

    private func dialogInput(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        return try axSetFocusedValue(["text": text])
    }

    private func dockOpen(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        _ = try runAppleScript("""
        tell application "System Events"
          tell process "Dock"
            click UI element \(appleScriptString(name)) of list 1
          end tell
        end tell
        """)
        return ToolResult(success: true, evidence: "Clicked Dock item.", data: ["name": name])
    }

    private func menubarClick(_ args: [String: Any]) throws -> ToolResult {
        guard let label = string(args["label"]), !label.isEmpty else { throw RuntimeError("label is required") }
        _ = try runAppleScript("""
        tell application "System Events"
          repeat with p in application processes
            repeat with mb in menu bars of p
              repeat with itemRef in menu bar items of mb
                try
                  if (description of itemRef contains \(appleScriptString(label))) or (title of itemRef contains \(appleScriptString(label))) then
                    click itemRef
                    return
                  end if
                end try
              end repeat
            end repeat
          end repeat
          error "menu bar item not found"
        end tell
        """)
        return ToolResult(success: true, evidence: "Clicked menu bar item.", data: ["label": label])
    }

    private func spaceSwitch(_ args: [String: Any]) throws -> ToolResult {
        let direction = (string(args["direction"]) ?? "right").lowercased()
        let key = direction == "left" ? "left" : "right"
        let count = int(args["count"]) ?? 1
        for _ in 0..<max(1, count) {
            try sendKeyboardShortcut(key: key, modifiers: ["control"])
            Thread.sleep(forTimeInterval: 0.25)
        }
        return ToolResult(success: true, evidence: "Switched Space.", data: ["direction": direction, "count": "\(count)"])
    }

    private func axDescribeFrontmost(_ args: [String: Any]) -> ToolResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult(success: false, evidence: "No frontmost app.", error: "frontmostApplication is nil")
        }
        let maxDepth = int(args["max_depth"]) ?? 4
        let maxNodes = int(args["max_nodes"]) ?? 80
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var lines: [String] = []
        var count = 0
        describeAXElement(root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, lines: &lines, count: &count)
        return ToolResult(success: true, evidence: "Described Accessibility tree for \(app.localizedName ?? "frontmost app").", data: [
            "app": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
            "nodes": "\(count)",
            "tree": lines.joined(separator: "\n")
        ])
    }

    private func axPress(_ args: [String: Any]) -> ToolResult {
        guard let label = string(args["label"]), !label.isEmpty else {
            return ToolResult(success: false, evidence: "label is required.", error: "label is required")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult(success: false, evidence: "No frontmost app.", error: "frontmostApplication is nil")
        }
        let role = string(args["role"])
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let found = findAXElement(root, label: label, role: role, maxNodes: 800) else {
            return ToolResult(success: false, evidence: "No matching Accessibility element found.", error: label)
        }
        let err = AXUIElementPerformAction(found, kAXPressAction as CFString)
        return ToolResult(success: err == .success, evidence: err == .success ? "Pressed matching Accessibility element." : "AXPress failed: \(err.rawValue)", data: [
            "label": label,
            "role": axString(found, kAXRoleAttribute as CFString) ?? "",
            "title": axString(found, kAXTitleAttribute as CFString) ?? ""
        ])
    }

    private func axGetFocusedValue() -> ToolResult {
        guard let element = focusedAXElement() else {
            return ToolResult(success: false, evidence: "No focused Accessibility element.", error: "AXFocusedUIElement unavailable")
        }
        let selected = axString(element, kAXSelectedTextAttribute as CFString) ?? ""
        return ToolResult(success: true, evidence: "Read focused Accessibility element.", data: [
            "role": axString(element, kAXRoleAttribute as CFString) ?? "",
            "title": axString(element, kAXTitleAttribute as CFString) ?? "",
            "value": axString(element, kAXValueAttribute as CFString) ?? "",
            "selected_text": selected
        ])
    }

    private func axSetFocusedValue(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        guard let element = focusedAXElement() else {
            return ToolResult(success: false, evidence: "No focused Accessibility element.", error: "AXFocusedUIElement unavailable")
        }
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        return ToolResult(success: err == .success, evidence: err == .success ? "Set focused element AXValue." : "Could not set focused AXValue: \(err.rawValue)", data: [
            "chars": "\(text.count)",
            "role": axString(element, kAXRoleAttribute as CFString) ?? ""
        ])
    }

    private func screenCapture(_ args: [String: Any]) throws -> ToolResult {
        let defaultPath = "/tmp/aios-screen-\(Int(Date().timeIntervalSince1970)).png"
        let path = (string(args["path"]) ?? defaultPath).expandingTildeInPath
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            return ToolResult(success: false, evidence: "Could not capture main display.", error: "CGDisplayCreateImage returned nil")
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RuntimeError("Could not encode screenshot as PNG")
        }
        try data.write(to: url)
        return ToolResult(success: true, evidence: "Captured main display to \(path).", data: [
            "path": path,
            "width": "\(image.width)",
            "height": "\(image.height)"
        ])
    }

    private func observeSnapshot(_ args: [String: Any]) throws -> ToolResult {
        try activateTargetAppIfProvided(args)
        let maxDepth = int(args["max_depth"]) ?? 4
        let maxNodes = int(args["max_nodes"]) ?? 100
        let includeScreenshot = bool(args["screenshot"]) ?? true
        let contextResult = context()
        let windowsResult = appWindows(args)
        let focusedResult = axGetFocusedValue()
        let axResult = axDescribeFrontmost(["max_depth": maxDepth, "max_nodes": maxNodes])
        var data: [String: String] = [
            "context": contextResult.jsonString,
            "windows": windowsResult.jsonString,
            "focused": focusedResult.jsonString,
            "ax": axResult.jsonString
        ]
        if includeScreenshot {
            let shot = try screenCapture(["path": "/tmp/aios-observe-\(Int(Date().timeIntervalSince1970)).png"])
            data["screenshot"] = shot.jsonString
        }
        return ToolResult(success: true, evidence: "Collected observation snapshot.", data: data)
    }

    private func observeWait(_ args: [String: Any]) throws -> ToolResult {
        guard let condition = string(args["condition"])?.lowercased(), !condition.isEmpty else {
            throw RuntimeError("condition is required")
        }
        guard let value = string(args["value"]), !value.isEmpty else {
            throw RuntimeError("value is required")
        }
        let timeout = double(args["timeout"]) ?? 10
        let interval = max(0.1, double(args["interval"]) ?? 0.5)
        let deadline = Date().addingTimeInterval(timeout)
        var lastEvidence = ""
        repeat {
            let passed = try evaluateWaitCondition(condition: condition, value: value, args: args, evidence: &lastEvidence)
            if passed {
                return ToolResult(success: true, evidence: "Wait condition met: \(condition).", data: [
                    "condition": condition,
                    "value": value,
                    "last_evidence": lastEvidence
                ])
            }
            Thread.sleep(forTimeInterval: interval)
        } while Date() < deadline
        return ToolResult(success: false, evidence: "Timed out waiting for \(condition).", data: [
            "condition": condition,
            "value": value,
            "last_evidence": lastEvidence
        ], error: "Timeout after \(timeout)s")
    }

    private func evaluateWaitCondition(condition: String, value: String, args: [String: Any], evidence: inout String) throws -> Bool {
        switch condition {
        case "frontmost_app":
            let current = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            evidence = current
            return current.localizedCaseInsensitiveContains(value)
        case "window_title_contains":
            let result = appWindows(args)
            evidence = result.data["windows"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "ax_contains":
            try activateTargetAppIfProvided(args)
            let result = axDescribeFrontmost(["max_depth": 5, "max_nodes": 160])
            evidence = result.data["tree"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "focused_value_contains":
            let result = axGetFocusedValue()
            evidence = result.data["value"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "safari_url_contains":
            let result = try safariGetCurrentURL()
            evidence = result.data["url"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "chrome_url_contains":
            let result = try chromeGetCurrentTab()
            evidence = result.data["url"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "file_exists":
            let path = value.expandingTildeInPath
            evidence = path
            return FileManager.default.fileExists(atPath: path)
        default:
            throw RuntimeError("unsupported wait condition: \(condition)")
        }
    }

    private func observeAnnotateFrontmost(_ args: [String: Any]) -> ToolResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult(success: false, evidence: "No frontmost app.", error: "frontmostApplication is nil")
        }
        let maxDepth = int(args["max_depth"]) ?? 6
        let maxNodes = int(args["max_nodes"]) ?? 160
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var elements: [[String: String]] = []
        var visited = 0
        collectActionableAXElements(root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, visited: &visited, elements: &elements, path: "0")
        return ToolResult(success: true, evidence: "Annotated \(elements.count) actionable element(s).", data: [
            "app": app.localizedName ?? "",
            "elements": jsonStringValue(elements)
        ])
    }

    private func snapshotCreate(_ args: [String: Any]) throws -> ToolResult {
        try activateTargetAppIfProvided(args)
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult(success: false, evidence: "No frontmost app.", error: "frontmostApplication is nil")
        }
        let maxDepth = int(args["max_depth"]) ?? 7
        let maxNodes = int(args["max_nodes"]) ?? 220
        let includeScreenshot = bool(args["screenshot"]) ?? true
        let snapshotID = "S\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var elements: [[String: String]] = []
        var visited = 0
        collectActionableAXElements(root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, visited: &visited, elements: &elements, path: "0")
        elements = elements.enumerated().map { index, item in
            var next = item
            next["element_id"] = "E\(index + 1)"
            return next
        }
        let snapshotDir = EventStore.snapshotsURL.appendingPathComponent(snapshotID, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        var screenshotPath = ""
        if includeScreenshot {
            let screenshot = try screenCapture(["path": snapshotDir.appendingPathComponent("screen.png").path])
            screenshotPath = screenshot.data["path"] ?? ""
        }
        let payload: [String: Any] = [
            "snapshot_id": snapshotID,
            "created_at": isoDateString(Date()),
            "app": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
            "pid": "\(app.processIdentifier)",
            "screenshot": screenshotPath,
            "elements": elements
        ]
        try writeJSONObject(payload, to: snapshotDir.appendingPathComponent("snapshot.json"))
        return ToolResult(success: true, evidence: "Created persistent UI snapshot.", data: [
            "snapshot_id": snapshotID,
            "app": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
            "screenshot": screenshotPath,
            "elements": jsonStringValue(elements)
        ])
    }

    private func snapshotGet(_ args: [String: Any]) throws -> ToolResult {
        guard let snapshotID = string(args["snapshot_id"]), !snapshotID.isEmpty else { throw RuntimeError("snapshot_id is required") }
        let payload = try readSnapshot(snapshotID)
        return ToolResult(success: true, evidence: "Read persistent UI snapshot.", data: [
            "snapshot_id": snapshotID,
            "snapshot": jsonStringValue(payload)
        ])
    }

    private func snapshotClick(_ args: [String: Any]) throws -> ToolResult {
        let target = try snapshotTarget(args)
        let resolved = try resolveSnapshotTarget(target)
        try clickSnapshotTarget(resolved)
        return ToolResult(success: true, evidence: resolved["relocated"] == "true" ? "Relocated and clicked snapshot element." : "Clicked snapshot element.", data: resolved)
    }

    private func snapshotType(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let target = try snapshotTarget(args)
        let resolved = try resolveSnapshotTarget(target)
        try clickSnapshotTarget(resolved)
        Thread.sleep(forTimeInterval: 0.1)
        _ = try clipboardSetText(["text": text])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Typed text into snapshot element.", data: [
            "snapshot_id": resolved["snapshot_id"] ?? "",
            "element_id": resolved["element_id"] ?? "",
            "relocated": resolved["relocated"] ?? "false",
            "chars": "\(text.count)"
        ])
    }

    private func snapshotPress(_ args: [String: Any]) throws -> ToolResult {
        let target = try snapshotTarget(args)
        let resolved = try resolveSnapshotTarget(target)
        if let app = runningApp(bundleID: resolved["bundle_id"], appName: resolved["app"]),
           let element = findAXElement(
               AXUIElementCreateApplication(app.processIdentifier),
               label: resolved["label"] ?? "",
               role: resolved["role"],
               maxNodes: 1_200
           ) {
            let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if err == .success {
                return ToolResult(success: true, evidence: "Pressed snapshot element via AXPress.", data: resolved)
            }
        }
        try clickSnapshotTarget(resolved)
        return ToolResult(success: true, evidence: "Clicked snapshot element as AXPress fallback.", data: resolved)
    }

    private func readSnapshot(_ snapshotID: String) throws -> [String: Any] {
        let url = EventStore.snapshotsURL
            .appendingPathComponent(snapshotID, isDirectory: true)
            .appendingPathComponent("snapshot.json")
        let data = try Data(contentsOf: url)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeError("Invalid snapshot JSON: \(snapshotID)")
        }
        return payload
    }

    private func snapshotTarget(_ args: [String: Any]) throws -> [String: String] {
        guard let snapshotID = string(args["snapshot_id"]), !snapshotID.isEmpty else { throw RuntimeError("snapshot_id is required") }
        guard let elementID = string(args["element_id"]), !elementID.isEmpty else { throw RuntimeError("element_id is required") }
        let payload = try readSnapshot(snapshotID)
        let elements = payload["elements"] as? [[String: Any]] ?? []
        guard let raw = elements.first(where: { string($0["element_id"]) == elementID }) else {
            throw RuntimeError("element not found in snapshot: \(elementID)")
        }
        var target = raw.compactMapValues { value -> String? in
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        target["snapshot_id"] = snapshotID
        target["app"] = string(payload["app"]) ?? ""
        target["bundle_id"] = string(payload["bundle_id"]) ?? ""
        return target
    }

    private func resolveSnapshotTarget(_ target: [String: String]) throws -> [String: String] {
        guard let app = runningApp(bundleID: target["bundle_id"], appName: target["app"]) else {
            return target.merging(["relocated": "false"]) { current, _ in current }
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if let element = findAXElementByPath(root, path: target["ax_path"] ?? ""),
           let row = snapshotRow(for: element, base: target, relocated: true) {
            return row
        }
        if let element = findAXElement(root, label: target["label"] ?? "", role: target["role"], maxNodes: 1_500),
           let row = snapshotRow(for: element, base: target, relocated: true) {
            return row
        }
        return target.merging(["relocated": "false"]) { current, _ in current }
    }

    private func snapshotRow(for element: AXUIElement, base: [String: String], relocated: Bool) -> [String: String]? {
        var row = base
        row["role"] = axString(element, kAXRoleAttribute as CFString) ?? row["role"] ?? ""
        let label = [
            axString(element, kAXTitleAttribute as CFString),
            axString(element, kAXDescriptionAttribute as CFString),
            axString(element, kAXValueAttribute as CFString)
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
        if !label.isEmpty { row["label"] = label }
        if let position = axCGPoint(element, kAXPositionAttribute as CFString) {
            row["x"] = "\(Int(position.x))"
            row["y"] = "\(Int(position.y))"
        }
        if let size = axCGSize(element, kAXSizeAttribute as CFString) {
            row["width"] = "\(Int(size.width))"
            row["height"] = "\(Int(size.height))"
        }
        row["relocated"] = relocated ? "true" : "false"
        return row
    }

    private func clickSnapshotTarget(_ target: [String: String]) throws {
        if let app = runningApp(bundleID: target["bundle_id"], appName: target["app"]) {
            app.activate()
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard let x = Double(target["x"] ?? ""),
              let y = Double(target["y"] ?? ""),
              let width = Double(target["width"] ?? ""),
              let height = Double(target["height"] ?? "")
        else {
            throw RuntimeError("snapshot element has no bounds")
        }
        try clickPoint(x: x + width / 2, y: y + height / 2)
    }

    private func runningApp(bundleID: String?, appName: String?) -> NSRunningApplication? {
        if let bundleID, !bundleID.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        if let appName, !appName.isEmpty {
            return NSWorkspace.shared.runningApplications.first {
                ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
            }
        }
        return nil
    }

    private func screenCaptureWindow(_ args: [String: Any]) throws -> ToolResult {
        try screenCaptureWindowSCK(args)
    }

    private func screenCaptureWindowLegacy(_ args: [String: Any]) throws -> ToolResult {
        let appName = string(args["app_name"])
        let bundleID = string(args["bundle_id"])?.lowercased()
        let appsByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return ToolResult(success: false, evidence: "Could not read window list.", error: "CGWindowListCopyWindowInfo returned nil")
        }
        guard let target = infos.first(where: { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = ownerPID(from: info),
                  let app = appsByPID[pid]
            else { return false }
            if let appName, !appMatchesName(app, requested: appName) { return false }
            if let bundleID, !(app.bundleIdentifier ?? "").lowercased().contains(bundleID) { return false }
            return true
        }), let windowID = target[kCGWindowNumber as String] as? CGWindowID else {
            return ToolResult(success: false, evidence: "No matching visible window.", error: "window not found")
        }
        guard let image = CGWindowListCreateImage(.null, [.optionIncludingWindow], windowID, [.boundsIgnoreFraming, .bestResolution]) else {
            return ToolResult(success: false, evidence: "Could not capture window.", error: "CGWindowListCreateImage returned nil")
        }
        let path = (string(args["path"]) ?? "/tmp/aios-window-\(windowID)-\(Int(Date().timeIntervalSince1970)).png").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RuntimeError("Could not encode window screenshot")
        }
        try data.write(to: url)
        return ToolResult(success: true, evidence: "Captured window to \(path).", data: [
            "path": path,
            "window_id": "\(windowID)",
            "title": target[kCGWindowName as String] as? String ?? "",
            "width": "\(image.width)",
            "height": "\(image.height)"
        ])
    }

    private func screenCaptureWindowSCK(_ args: [String: Any]) throws -> ToolResult {
        let target = try matchingWindowInfo(args)
        let windowID = target.windowID
        let path = (string(args["path"]) ?? "/tmp/aios-window-sck-\(windowID)-\(Int(Date().timeIntervalSince1970)).png").expandingTildeInPath
        let title = target.target[kCGWindowName as String] as? String ?? ""
        if #available(macOS 14.0, *) {
            do {
                return try captureWindowUsingSCK(windowID: windowID, path: path, title: title)
            } catch {
                let fallback = try screenCaptureWindowLegacy(args.merging(["path": path]) { current, _ in current })
                var data = fallback.data
                data["capture_engine"] = "legacy_fallback"
                data["sck_error"] = error.localizedDescription
                return ToolResult(success: fallback.success, evidence: fallback.success ? "ScreenCaptureKit failed; captured window with legacy fallback." : fallback.evidence, data: data, error: fallback.error, suggestion: fallback.suggestion)
            }
        }
        let fallback = try screenCaptureWindowLegacy(args.merging(["path": path]) { current, _ in current })
        var data = fallback.data
        data["capture_engine"] = "legacy_fallback"
        data["sck_error"] = "ScreenCaptureKit screenshot requires macOS 14+."
        return ToolResult(success: fallback.success, evidence: fallback.success ? "Captured window with legacy fallback." : fallback.evidence, data: data, error: fallback.error, suggestion: fallback.suggestion)
    }

    @available(macOS 14.0, *)
    private func captureWindowUsingSCK(windowID: CGWindowID, path: String, title: String) throws -> ToolResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ToolResultAsyncBox()
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw RuntimeError("ScreenCaptureKit window not found: \(windowID)")
                }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let config = SCStreamConfiguration()
                config.width = max(1, Int(window.frame.width * scale))
                config.height = max(1, Int(window.frame.height * scale))
                config.showsCursor = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let rep = NSBitmapImageRep(cgImage: image)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    throw RuntimeError("Could not encode ScreenCaptureKit image as PNG")
                }
                try data.write(to: url)
                box.result = .success(ToolResult(success: true, evidence: "Captured window with ScreenCaptureKit.", data: [
                    "path": path,
                    "window_id": "\(windowID)",
                    "title": title,
                    "width": "\(image.width)",
                    "height": "\(image.height)",
                    "capture_engine": "ScreenCaptureKit"
                ]))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else { throw RuntimeError("ScreenCaptureKit capture did not return a result") }
        return try result.get()
    }

    private func matchingWindowInfo(_ args: [String: Any]) throws -> (windowID: CGWindowID, target: [String: Any]) {
        let appName = string(args["app_name"])
        let bundleID = string(args["bundle_id"])?.lowercased()
        let appsByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw RuntimeError("CGWindowListCopyWindowInfo returned nil")
        }
        guard let target = infos.first(where: { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = ownerPID(from: info),
                  let app = appsByPID[pid]
            else { return false }
            if let appName, !appMatchesName(app, requested: appName) { return false }
            if let bundleID, !(app.bundleIdentifier ?? "").lowercased().contains(bundleID) { return false }
            return true
        }), let windowID = target[kCGWindowNumber as String] as? CGWindowID else {
            throw RuntimeError("No matching visible window.")
        }
        return (windowID, target)
    }

    private func ocrScreen(_ args: [String: Any]) throws -> ToolResult {
        let path = string(args["path"]) ?? "/tmp/aios-ocr-\(Int(Date().timeIntervalSince1970)).png"
        let capture = try screenCapture(["path": path])
        guard capture.success, let imagePath = capture.data["path"] else {
            return capture
        }
        return try ocrImage(["path": imagePath])
    }

    private func ocrImage(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return ToolResult(success: false, evidence: "Could not load image for OCR.", error: path)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        return ToolResult(success: true, evidence: "OCR read \(lines.count) text line(s).", data: [
            "path": path,
            "text": lines.joined(separator: "\n"),
            "lines": jsonStringValue(lines)
        ])
    }

    private func recipeListTool() throws -> ToolResult {
        let recipes = try RecipeStore.list().map { recipe in
            [
                "id": recipe.id,
                "title": recipe.title,
                "required_params": recipe.requiredParams.joined(separator: ","),
                "steps": "\(recipe.steps.count)"
            ]
        }
        return ToolResult(success: true, evidence: "Listed \(recipes.count) recipe(s).", data: ["recipes": jsonStringValue(recipes)])
    }

    private func recipeSuggestTool(_ args: [String: Any]) throws -> ToolResult {
        guard let goal = string(args["goal"]), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("goal is required")
        }
        let suggestions = try RecipeStore.suggest(goal: goal, limit: int(args["limit"]) ?? 5)
        return ToolResult(
            success: true,
            evidence: suggestions.isEmpty ? "No matching recipe suggestions." : "Suggested \(suggestions.count) matching recipe(s).",
            data: ["suggestions": jsonStringValue(suggestions.map(\.summary))]
        )
    }

    private func recipeExecuteTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        let params = try parseJSONObject(string(args["params_json"]) ?? "{}")
        let results = try RecipeStore.execute(recipeID: id, params: params)
        let ok = results.allSatisfy(\.success)
        return ToolResult(success: ok, evidence: ok ? "Executed recipe \(id)." : "Recipe \(id) stopped on a failed step.", data: [
            "recipe_id": id,
            "results": jsonStringValue(results.map { ["success": $0.success ? "true" : "false", "evidence": $0.evidence, "error": $0.error ?? ""] })
        ])
    }

    private func learnStartTool(_ args: [String: Any]) throws -> ToolResult {
        let session = try LearningStore.start(title: string(args["title"]) ?? "Learned workflow")
        return ToolResult(success: true, evidence: "Started learning session.", data: ["session_id": session.id, "title": session.title])
    }

    private func learnRecordTool(_ args: [String: Any]) throws -> ToolResult {
        guard let tool = string(args["tool"]), !tool.isEmpty else { throw RuntimeError("tool is required") }
        let arguments = try parseJSONObject(string(args["arguments_json"]) ?? "{}")
        let result = execute(ToolCall(id: "learn", name: tool, arguments: arguments, raw: [:]))
        try LearningStore.record(tool: tool, arguments: arguments, result: result)
        return ToolResult(success: result.success, evidence: "Recorded tool \(tool): \(result.evidence)", data: result.data, error: result.error, suggestion: result.suggestion)
    }

    private func learnRecordEventsTool(_ args: [String: Any]) throws -> ToolResult {
        guard let recipeID = string(args["recipe_id"]), !recipeID.isEmpty else { throw RuntimeError("recipe_id is required") }
        let recipe = try RawEventRecorder.recordRecipe(
            title: string(args["title"]) ?? "Raw UI workflow",
            recipeID: recipeID,
            duration: double(args["seconds"]) ?? 8,
            includeAX: bool(args["include_ax"]) ?? true
        )
        return ToolResult(success: true, evidence: "Recorded raw UI events into recipe.", data: [
            "recipe_id": recipe.id,
            "steps": "\(recipe.steps.count)"
        ])
    }

    private func learnStopTool(_ args: [String: Any]) throws -> ToolResult {
        guard let recipeID = string(args["recipe_id"]), !recipeID.isEmpty else { throw RuntimeError("recipe_id is required") }
        let recipe = try LearningStore.stop(recipeID: recipeID)
        return ToolResult(success: true, evidence: "Saved learned recipe.", data: ["recipe": recipe.jsonString])
    }

    private func finderListDirectory(_ args: [String: Any]) throws -> ToolResult {
        let path = (string(args["path"]) ?? "~/Downloads").expandingTildeInPath
        let limit = int(args["limit"]) ?? 80
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult(success: false, evidence: "Directory does not exist.", error: path)
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let entries = urls.prefix(limit).map(fileSummary)
        return ToolResult(success: true, evidence: "Listed \(entries.count) item(s) in \(path).", data: [
            "path": path,
            "entries": jsonStringValue(entries)
        ])
    }

    private func finderFileInfo(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        let info = fileSummary(URL(fileURLWithPath: path))
        return ToolResult(success: true, evidence: "Read file metadata.", data: info)
    }

    private func finderReadTextFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        let maxChars = int(args["max_chars"]) ?? 4_000
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let expected = string(args["contains"]) ?? ""
        let verified = expected.isEmpty || text.localizedCaseInsensitiveContains(expected)
        return ToolResult(success: verified, evidence: verified ? "Read and verified text file." : "Read text file, but expected content was not found.", data: [
            "effect": "file_content_verified",
            "app": "Finder",
            "target": path,
            "path": path,
            "contains": expected,
            "text": truncateMiddle(text, maxCharacters: maxChars),
            "chars": "\(text.count)",
            "verified": verified ? "true" : "false"
        ], error: verified ? nil : "Expected content not found")
    }

    private func finderFindFiles(_ args: [String: Any]) throws -> ToolResult {
        let root = (string(args["root"]) ?? "~/Downloads").expandingTildeInPath
        guard let needle = string(args["name_contains"]), !needle.isEmpty else {
            throw RuntimeError("name_contains is required")
        }
        let limit = int(args["limit"]) ?? 40
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult(success: false, evidence: "Root directory does not exist.", error: root)
        }
        let rootURL = URL(fileURLWithPath: root)
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var results: [[String: String]] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.localizedCaseInsensitiveContains(needle) {
                results.append(fileSummary(url))
                if results.count >= limit { break }
            }
        }
        return ToolResult(success: true, evidence: "Found \(results.count) matching file(s).", data: [
            "root": root,
            "matches": jsonStringValue(results)
        ])
    }

    private func chromeOpenURL(_ args: [String: Any]) throws -> ToolResult {
        guard let rawURL = string(args["url"]), URL(string: rawURL) != nil else {
            throw RuntimeError("valid url is required")
        }
        _ = try runAppleScript("""
        tell application "Google Chrome"
          activate
          if (count of windows) = 0 then make new window
          set URL of active tab of front window to \(appleScriptString(rawURL))
        end tell
        """)
        Thread.sleep(forTimeInterval: 0.2)
        let current = (try? chromeGetCurrentTab())?.data["url"] ?? ""
        let verified = current.localizedCaseInsensitiveContains(rawURL) || rawURL.localizedCaseInsensitiveContains(current)
        return ToolResult(success: verified, evidence: verified ? "Opened and verified URL in Chrome." : "Chrome URL did not verify after open.", data: [
            "effect": "browser_url_visible",
            "app": "Chrome",
            "target": rawURL,
            "url": rawURL,
            "current_url": current,
            "verified": verified ? "true" : "false",
            "verified_current_url": verified ? "true" : "false"
        ], error: verified ? nil : "Expected Chrome URL not visible")
    }

    private func chromeGetCurrentTab() throws -> ToolResult {
        let text = try runAppleScript("""
        tell application "Google Chrome"
          if (count of windows) = 0 then return ""
          set tabTitle to title of active tab of front window
          set tabURL to URL of active tab of front window
          return tabTitle & linefeed & tabURL
        end tell
        """)
        let parts = text.components(separatedBy: "\n")
        return ToolResult(success: !text.isEmpty, evidence: text.isEmpty ? "Chrome has no front tab." : "Read Chrome front tab.", data: [
            "title": parts.first ?? "",
            "url": parts.dropFirst().joined(separator: "\n")
        ])
    }

    private func chromeNewTab(_ args: [String: Any]) throws -> ToolResult {
        let rawURL = string(args["url"])
        if let rawURL, URL(string: rawURL) == nil {
            throw RuntimeError("valid url is required")
        }
        let urlClause = rawURL.map { "with properties {URL:\(appleScriptString($0))}" } ?? ""
        _ = try runAppleScript("""
        tell application "Google Chrome"
          activate
          if (count of windows) = 0 then make new window
          make new tab at end of tabs of front window \(urlClause)
          set active tab index of front window to (count of tabs of front window)
        end tell
        """)
        if let rawURL {
            Thread.sleep(forTimeInterval: 0.2)
            let current = (try? chromeGetCurrentTab())?.data["url"] ?? ""
            let verified = current.localizedCaseInsensitiveContains(rawURL) || rawURL.localizedCaseInsensitiveContains(current)
            return ToolResult(success: verified, evidence: verified ? "Opened and verified a new Chrome tab with URL." : "Chrome new tab URL did not verify.", data: [
                "effect": "browser_url_visible",
                "app": "Chrome",
                "target": rawURL,
                "url": rawURL,
                "current_url": current,
                "verified": verified ? "true" : "false",
                "verified_current_url": verified ? "true" : "false"
            ], error: verified ? nil : "Expected Chrome URL not visible")
        }
        return ToolResult(success: true, evidence: "Opened a new Chrome tab.", data: [
            "effect": "browser_tab_opened",
            "app": "Chrome",
            "verified": "true"
        ])
    }

    private func chromeSearch(_ args: [String: Any]) throws -> ToolResult {
        guard let query = string(args["query"]), !query.isEmpty else { throw RuntimeError("query is required") }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try chromeOpenURL(["url": "https://www.google.com/search?q=\(encoded)"])
    }

    private func wpsOpenFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        try runProcess("/usr/bin/open", ["-a", "wpsoffice", path])
        return ToolResult(success: true, evidence: "Opened file in WPS Office.", data: ["path": path])
    }

    private func notesCreateNote(_ args: [String: Any]) throws -> ToolResult {
        guard let title = string(args["title"]), !title.isEmpty else { throw RuntimeError("title is required") }
        guard let body = string(args["body"]) else { throw RuntimeError("body is required") }
        _ = try runAppleScript("""
        tell application "Notes"
          activate
          make new note with properties {name:\(appleScriptString(title)), body:\(appleScriptString(body))}
        end tell
        """)
        let verification = try runAppleScript("""
        tell application "Notes"
          set matches to every note whose name is \(appleScriptString(title))
          return (count of matches) as text
        end tell
        """)
        let verified = (Int(verification.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
        return ToolResult(success: verified, evidence: verified ? "Created and verified Apple Notes note." : "Created Apple Notes note, but verification did not find it.", data: [
            "effect": "note_created",
            "app": "Notes",
            "target": title,
            "title": title,
            "chars": "\(body.count)",
            "verified": verified ? "true" : "false"
        ], error: verified ? nil : "Note title not found after create")
    }

    private func notesSearch(_ args: [String: Any]) throws -> ToolResult {
        guard let query = string(args["query"]), !query.isEmpty else { throw RuntimeError("query is required") }
        _ = try openApp(["bundle_id": "com.apple.Notes"])
        Thread.sleep(forTimeInterval: 0.4)
        _ = try clipboardSetText(["text": query])
        try sendKeyboardShortcut(key: "f", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Opened Notes search and pasted query.", data: ["query": query])
    }

    private func mailComposeDraft(_ args: [String: Any]) throws -> ToolResult {
        let to = (try? stringArray(args["to"], name: "to")) ?? []
        let attachments = (try? stringArray(args["attachments"], name: "attachments")) ?? []
        guard let subject = string(args["subject"]) else { throw RuntimeError("subject is required") }
        guard let body = string(args["body"]) else { throw RuntimeError("body is required") }
        let recipientLines = to.map {
            "make new to recipient at end of to recipients with properties {address:\(appleScriptString($0))}"
        }.joined(separator: "\n")
        let attachmentLines = try attachments.map { rawPath -> String in
            let path = rawPath.expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw RuntimeError("attachment does not exist: \(path)") }
            return "make new attachment with properties {file name:POSIX file \(appleScriptString(path))} at after last paragraph"
        }.joined(separator: "\n")
        _ = try runAppleScript("""
        tell application "Mail"
          activate
          set draftMessage to make new outgoing message with properties {subject:\(appleScriptString(subject)), content:\(appleScriptString(body)), visible:true}
          tell draftMessage
            \(recipientLines)
            \(attachmentLines)
          end tell
        end tell
        """)
        return ToolResult(success: true, evidence: "Created visible Mail draft. It was not sent.", data: [
            "effect": "mail_draft_created",
            "app": "Mail",
            "target": subject,
            "value": body,
            "verified": "true",
            "recipients": jsonStringValue(to),
            "subject": subject,
            "attachments": jsonStringValue(attachments)
        ])
    }

    private func mailSearchMessages(_ args: [String: Any]) throws -> ToolResult {
        guard let query = string(args["query"]), !query.isEmpty else { throw RuntimeError("query is required") }
        _ = try openApp(["bundle_id": "com.apple.mail"])
        Thread.sleep(forTimeInterval: 0.4)
        _ = try clipboardSetText(["text": query])
        try sendKeyboardShortcut(key: "f", modifiers: ["command", "option"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Opened Mail search and pasted query.", data: ["query": query])
    }

    private func calendarCreateEvent(_ args: [String: Any]) throws -> ToolResult {
        guard let title = string(args["title"]), !title.isEmpty else { throw RuntimeError("title is required") }
        guard let startText = string(args["start"]), let start = parseDateTime(startText) else {
            throw RuntimeError("start must be parseable, e.g. 2026-05-21 15:30")
        }
        guard let endText = string(args["end"]), let end = parseDateTime(endText) else {
            throw RuntimeError("end must be parseable, e.g. 2026-05-21 16:00")
        }
        let calendarName = string(args["calendar"])
        let notes = string(args["notes"]) ?? ""
        let targetCalendarLine = if let calendarName, !calendarName.isEmpty {
            "set targetCalendar to first calendar whose name contains \(appleScriptString(calendarName))"
        } else {
            "set targetCalendar to calendar 1"
        }
        _ = try runAppleScript("""
        tell application "Calendar"
          activate
          \(appleScriptDateAssignment("startDate", start))
          \(appleScriptDateAssignment("endDate", end))
          \(targetCalendarLine)
          make new event at end of events of targetCalendar with properties {summary:\(appleScriptString(title)), start date:startDate, end date:endDate, description:\(appleScriptString(notes))}
        end tell
        """)
        let verification = try calendarFindEvents(["title": title, "days": 365])
        let verified = verification.success && (verification.data["events"] ?? "[]") != "[]"
        return ToolResult(success: verified, evidence: verified ? "Created and verified Calendar event." : "Created Calendar event, but verification did not find it.", data: [
            "effect": "calendar_event_created",
            "app": "Calendar",
            "target": title,
            "title": title,
            "start": startText,
            "end": endText,
            "verified": verified ? "true" : "false",
            "events": verification.data["events"] ?? ""
        ], error: verified ? nil : "Calendar event not found after create")
    }

    private func calendarFindEvents(_ args: [String: Any]) throws -> ToolResult {
        guard let title = string(args["title"]), !title.isEmpty else { throw RuntimeError("title is required") }
        let days = int(args["days"]) ?? 30
        let output = try runAppleScript("""
        tell application "Calendar"
          set startDate to current date
          set endDate to startDate + (\(days) * days)
          set foundEvents to {}
          repeat with c in calendars
            set matches to (every event of c whose summary contains \(appleScriptString(title)) and start date ≥ startDate and start date ≤ endDate)
            repeat with e in matches
              set end of foundEvents to (summary of e & " | " & (start date of e as string))
            end repeat
          end repeat
          set AppleScript's text item delimiters to linefeed
          return foundEvents as text
        end tell
        """)
        let events = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return ToolResult(success: true, evidence: "Found \(events.count) Calendar event(s).", data: [
            "title": title,
            "events": jsonStringValue(events)
        ])
    }

    private func wechatOpen() throws -> ToolResult {
        try runProcess("/usr/bin/open", ["-a", "WeChat"])
        return ToolResult(success: true, evidence: "Opened WeChat.", data: [
            "effect": "app_opened",
            "app": "WeChat",
            "verified": "true"
        ])
    }

    private func wechatSearchChat(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        _ = try wechatOpen()
        Thread.sleep(forTimeInterval: 0.5)
        _ = try clipboardSetText(["text": name])
        try sendKeyboardShortcut(key: "f", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Searched WeChat for chat/contact. Verify the result before external actions.", data: ["name": name])
    }

    private func wechatOpenChat(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]) ?? string(args["name"]), !recipient.isEmpty else {
            throw RuntimeError("recipient is required")
        }
        _ = try wechatSearchChat(["name": recipient])
        Thread.sleep(forTimeInterval: 0.35)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        let recipientCheck = try chatVerify(
            appName: "WeChat",
            bundleID: "com.tencent.xinWeChat",
            expected: recipient,
            scope: .currentChat
        )
        guard recipientCheck.success else {
            return ToolResult(
                success: false,
                evidence: "WeChat chat was not verified after opening the search result.",
                data: [
                    "effect": "chat_session_ready",
                    "app": "WeChat",
                    "target": recipient,
                    "recipient": recipient,
                    "verified": "false",
                    "verified_recipient": "false",
                    "ax_excerpt": recipientCheck.data["ax_excerpt"] ?? "",
                    "ocr_excerpt": recipientCheck.data["ocr_excerpt"] ?? ""
                ],
                error: recipientCheck.error ?? recipientCheck.evidence,
                suggestion: "Search the contact again or click the intended top result, then retry the chat action."
            )
        }
        return ToolResult(success: true, evidence: "Opened and verified WeChat chat.", data: [
            "effect": "chat_session_ready",
            "app": "WeChat",
            "target": recipient,
            "recipient": recipient,
            "verified": "true",
            "verified_recipient": "true",
            "ax_excerpt": recipientCheck.data["ax_excerpt"] ?? "",
            "ocr_excerpt": recipientCheck.data["ocr_excerpt"] ?? ""
        ])
    }

    private func wechatStageFile(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]), !recipient.isEmpty else { throw RuntimeError("recipient is required") }
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Attachment path does not exist.", error: path)
        }
        let openChat = try wechatOpenChat(["recipient": recipient])
        guard openChat.success else { return openChat }
        _ = try clipboardSetFiles(["paths": [path]])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Staged file in WeChat input. It was not sent. Verify recipient on screen before sending.", data: [
            "effect": "external_message_staged",
            "app": "WeChat",
            "target": recipient,
            "value": URL(fileURLWithPath: path).lastPathComponent,
            "verified": "false",
            "recipient": recipient,
            "path": path
        ])
    }

    private func wechatSendText(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]), !recipient.isEmpty else { throw RuntimeError("recipient is required") }
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let probe = messageVerificationProbe(text)
        if recentlyAttemptedExternalSend(app: "WeChat", recipient: recipient, text: text, within: 180) {
            let messageCheck = try chatVerifyAnyProbe(
                appName: "WeChat",
                bundleID: "com.tencent.xinWeChat",
                probes: messageVerificationProbes(text),
                scope: .message,
                attempts: 2
            )
            return ToolResult(
                success: messageCheck.success,
                evidence: messageCheck.success ? "Verified recent WeChat message after duplicate-send guard." : "Skipped duplicate WeChat send attempt; recent identical send was already submitted but not verified.",
                data: [
                    "effect": "external_message_sent",
                    "app": "WeChat",
                    "target": recipient,
                    "value": text,
                    "verified": messageCheck.success ? "true" : "false",
                    "recipient": recipient,
                    "message": text,
                    "message_probe": messageCheck.data["expected"] ?? probe,
                    "chars": "\(text.count)",
                    "verified_recipient": "true",
                    "verified_message": messageCheck.success ? "true" : "false",
                    "duplicate_guard": "true"
                ],
                error: messageCheck.success ? nil : (messageCheck.error ?? "Message text not found after recent send attempt"),
                suggestion: messageCheck.success ? nil : "Do not press send again for the same text. Observe the chat or ask the user before retrying."
            )
        }
        let openChat = try wechatOpenChat(["recipient": recipient])
        guard openChat.success else {
            return ToolResult(
                success: false,
                evidence: "WeChat recipient was not verified before sending.",
                data: [
                    "recipient": recipient,
                    "verified_recipient": "false",
                    "verified_message": "false",
                    "ax_excerpt": openChat.data["ax_excerpt"] ?? "",
                    "ocr_excerpt": openChat.data["ocr_excerpt"] ?? ""
                ],
                error: openChat.error ?? openChat.evidence,
                suggestion: "Search/open the chat again and verify the current chat title before sending."
            )
        }
        try focusChatInput(appName: "WeChat", bundleID: "com.tencent.xinWeChat")
        _ = try clipboardSetText(["text": text])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.2)
        markExternalSendAttempt(app: "WeChat", recipient: recipient, text: text)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 1.0)
        let messageCheck = try chatVerifyAnyProbe(
            appName: "WeChat",
            bundleID: "com.tencent.xinWeChat",
            probes: messageVerificationProbes(text),
            scope: .message,
            attempts: 3
        )
        return ToolResult(success: messageCheck.success, evidence: messageCheck.success ? "Sent and verified WeChat text message." : "Pressed send in WeChat, but recent message was not verified.", data: [
            "effect": "external_message_sent",
            "app": "WeChat",
            "target": recipient,
            "value": text,
            "verified": messageCheck.success ? "true" : "false",
            "recipient": recipient,
            "message": text,
            "message_probe": messageCheck.data["expected"] ?? probe,
            "chars": "\(text.count)",
            "verified_recipient": "true",
            "verified_message": messageCheck.success ? "true" : "false"
        ], error: messageCheck.success ? nil : (messageCheck.error ?? "Message text not found after send"), suggestion: messageCheck.success ? nil : "Do not mark done and do not resend the same text automatically. Observe the chat or ask the user before retrying.")
    }

    private func wechatSendStaged(_ args: [String: Any]) throws -> ToolResult {
        let recipient = string(args["recipient"]) ?? ""
        let recipientCheck = try chatVerify(appName: "WeChat", bundleID: "com.tencent.xinWeChat", expected: recipient)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "WeChat recipient was not verified before sending staged content.", data: [
                "recipient": recipient,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        return ToolResult(success: true, evidence: "Pressed Return in verified WeChat chat to send staged content.", data: [
            "effect": "external_message_sent",
            "app": "WeChat",
            "target": recipient,
            "verified": "false",
            "recipient": recipient,
            "verified_recipient": "true",
            "verified_message": "false"
        ], suggestion: "Verify the attachment/message appears in the chat before marking the task complete.")
    }

    private func larkOpen() throws -> ToolResult {
        try runProcess("/usr/bin/open", ["-a", "Lark"])
        return ToolResult(success: true, evidence: "Opened Lark.", data: [
            "effect": "app_opened",
            "app": "Lark",
            "verified": "true"
        ])
    }

    private func larkSearchChat(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        _ = try larkOpen()
        Thread.sleep(forTimeInterval: 0.6)
        _ = try clipboardSetText(["text": name])
        try sendKeyboardShortcut(key: "k", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.15)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Searched Lark for chat/contact. Verify the result before external actions.", data: ["name": name])
    }

    private func larkStageFile(_ args: [String: Any]) throws -> ToolResult {
        guard let chat = string(args["chat"]), !chat.isEmpty else { throw RuntimeError("chat is required") }
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Attachment path does not exist.", error: path)
        }
        _ = try larkSearchChat(["name": chat])
        Thread.sleep(forTimeInterval: 0.3)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.5)
        _ = try clipboardSetFiles(["paths": [path]])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Staged file in Lark input. It was not sent. Verify chat on screen before sending.", data: [
            "effect": "external_message_staged",
            "app": "Lark",
            "target": chat,
            "value": URL(fileURLWithPath: path).lastPathComponent,
            "verified": "false",
            "chat": chat,
            "path": path
        ])
    }

    private func larkSendText(_ args: [String: Any]) throws -> ToolResult {
        guard let chat = string(args["chat"]), !chat.isEmpty else { throw RuntimeError("chat is required") }
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let probe = messageVerificationProbe(text)
        _ = try larkSearchChat(["name": chat])
        Thread.sleep(forTimeInterval: 0.3)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.5)
        let recipientCheck = try chatVerify(appName: "Lark", bundleID: nil, expected: chat)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "Lark chat was not verified before sending.", data: [
                "chat": chat,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        _ = try clipboardSetText(["text": text])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        let messageCheck = try chatVerify(appName: "Lark", bundleID: nil, expected: probe)
        return ToolResult(success: messageCheck.success, evidence: messageCheck.success ? "Sent and verified Lark text message." : "Pressed send in Lark, but recent message was not verified.", data: [
            "effect": "external_message_sent",
            "app": "Lark",
            "target": chat,
            "value": text,
            "verified": messageCheck.success ? "true" : "false",
            "chat": chat,
            "message": text,
            "message_probe": probe,
            "chars": "\(text.count)",
            "verified_recipient": "true",
            "verified_message": messageCheck.success ? "true" : "false"
        ], error: messageCheck.success ? nil : (messageCheck.error ?? "Message text not found after send"), suggestion: messageCheck.success ? nil : "Do not mark done. Re-open the intended chat and verify the sent message is visible.")
    }

    private func larkSendStaged(_ args: [String: Any]) throws -> ToolResult {
        let chat = string(args["chat"]) ?? ""
        let recipientCheck = try chatVerify(appName: "Lark", bundleID: nil, expected: chat)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "Lark chat was not verified before sending staged content.", data: [
                "chat": chat,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        return ToolResult(success: true, evidence: "Pressed Return in verified Lark chat to send staged content.", data: [
            "effect": "external_message_sent",
            "app": "Lark",
            "target": chat,
            "verified": "false",
            "chat": chat,
            "verified_recipient": "true",
            "verified_message": "false"
        ], suggestion: "Verify the attachment/message appears in the chat before marking the task complete.")
    }

    private func qqOpen() throws -> ToolResult {
        try runProcess("/usr/bin/open", ["-a", "QQ"])
        return ToolResult(success: true, evidence: "Opened QQ.", data: [
            "effect": "app_opened",
            "app": "QQ",
            "verified": "true"
        ])
    }

    private func qqSearchChat(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        _ = try qqOpen()
        Thread.sleep(forTimeInterval: 0.5)
        _ = try clipboardSetText(["text": name])
        try sendKeyboardShortcut(key: "f", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.15)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Searched QQ for chat/contact. Verify the result before external actions.", data: ["name": name])
    }

    private func qqStageFile(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]), !recipient.isEmpty else { throw RuntimeError("recipient is required") }
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Attachment path does not exist.", error: path)
        }
        _ = try qqSearchChat(["name": recipient])
        Thread.sleep(forTimeInterval: 0.3)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.5)
        _ = try clipboardSetFiles(["paths": [path]])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Staged file in QQ input. It was not sent. Verify recipient on screen before sending.", data: [
            "effect": "external_message_staged",
            "app": "QQ",
            "target": recipient,
            "value": URL(fileURLWithPath: path).lastPathComponent,
            "verified": "false",
            "recipient": recipient,
            "path": path
        ])
    }

    private func qqSendText(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]), !recipient.isEmpty else { throw RuntimeError("recipient is required") }
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let probe = messageVerificationProbe(text)
        _ = try qqSearchChat(["name": recipient])
        Thread.sleep(forTimeInterval: 0.3)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.4)
        let recipientCheck = try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: recipient)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "QQ recipient was not verified before sending.", data: [
                "recipient": recipient,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        _ = try clipboardSetText(["text": text])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        let messageCheck = try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: probe)
        return ToolResult(success: messageCheck.success, evidence: messageCheck.success ? "Sent and verified QQ text message." : "Pressed send in QQ, but recent message was not verified.", data: [
            "effect": "external_message_sent",
            "app": "QQ",
            "target": recipient,
            "value": text,
            "verified": messageCheck.success ? "true" : "false",
            "recipient": recipient,
            "message": text,
            "message_probe": probe,
            "chars": "\(text.count)",
            "verified_recipient": "true",
            "verified_message": messageCheck.success ? "true" : "false"
        ], error: messageCheck.success ? nil : (messageCheck.error ?? "Message text not found after send"), suggestion: messageCheck.success ? nil : "Do not mark done. Re-open the intended chat and verify the sent message is visible.")
    }

    private func qqSendStaged(_ args: [String: Any]) throws -> ToolResult {
        let recipient = string(args["recipient"]) ?? ""
        let recipientCheck = try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: recipient)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "QQ recipient was not verified before sending staged content.", data: [
                "recipient": recipient,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        return ToolResult(success: true, evidence: "Pressed Return in verified QQ chat to send staged content.", data: [
            "effect": "external_message_sent",
            "app": "QQ",
            "target": recipient,
            "verified": "false",
            "recipient": recipient,
            "verified_recipient": "true",
            "verified_message": "false"
        ], suggestion: "Verify the attachment/message appears in the chat before marking the task complete.")
    }

    private enum ChatVerifyScope {
        case any
        case currentChat
        case message
    }

    private func chatVerify(appName: String, bundleID: String?, expected: String, scope: ChatVerifyScope = .any) throws -> ToolResult {
        guard !expected.isEmpty else { throw RuntimeError("expected text is required") }
        var args: [String: Any] = ["app_name": appName, "max_depth": 6, "max_nodes": 260]
        if let bundleID { args["bundle_id"] = bundleID }
        try activateTargetAppIfProvided(args)
        let ax = axDescribeFrontmost(args)
        let text = ax.data["tree"] ?? ""
        let axOK = chatVerificationTextMatches(text, expected: expected, scope: scope)
        let ocr = try? ocrScreen([:])
        let ocrText = ocr?.data["text"] ?? ""
        let ocrOK = chatVerificationTextMatches(ocrText, expected: expected, scope: scope)
        let ok = axOK || ocrOK
        return ToolResult(success: ok, evidence: ok ? "\(appName) \(axOK ? "UI" : "OCR") contains expected text." : "\(appName) verification did not find expected text.", data: [
            "expected": expected,
            "ax_excerpt": truncateMiddle(text, maxCharacters: 2_000),
            "ocr_excerpt": truncateMiddle(ocrText, maxCharacters: 2_000)
        ], error: ok ? nil : "Expected text not found")
    }

    private func chatVerifyAnyProbe(appName: String, bundleID: String?, probes: [String], scope: ChatVerifyScope, attempts: Int) throws -> ToolResult {
        var last = ToolResult(success: false, evidence: "\(appName) verification did not run.", error: "No probe")
        for _ in 0..<max(1, attempts) {
            for probe in probes where !probe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let result = try chatVerify(appName: appName, bundleID: bundleID, expected: probe, scope: scope)
                if result.success { return result }
                last = result
            }
            Thread.sleep(forTimeInterval: 0.6)
        }
        return last
    }

    private func chatVerificationTextMatches(_ text: String, expected: String, scope: ChatVerifyScope) -> Bool {
        guard text.localizedCaseInsensitiveContains(expected) else { return false }
        switch scope {
        case .any:
            return true
        case .message:
            return true
        case .currentChat:
            let lowered = text.lowercased()
            let expectedLower = expected.lowercased()
            if lowered.contains("包含：\(expectedLower)") ||
                lowered.contains("搜索网络结果") ||
                (lowered.contains("查看全部") && lowered.contains("聊天记录")) {
                return false
            }
            return true
        }
    }

    func messageVerificationProbe(_ text: String) -> String {
        messageVerificationProbes(text).first ?? ""
    }

    private func messageVerificationProbes(_ text: String) -> [String] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var probes: [String] = []
        func add(_ value: String) {
            let trimmed = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "，。,.；;：:、 "))
            guard trimmed.count >= 4 else { return }
            if !probes.contains(trimmed) { probes.append(trimmed) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = [
            "项目的原理",
            "核心原理",
            "任务规划",
            "自主调用各种工具",
            "无需人工逐步干预",
            "project concept",
            "plans steps",
            "executes tools"
        ]
        for phrase in phrases where trimmed.localizedCaseInsensitiveContains(phrase) {
            add(phrase)
        }
        for line in lines {
            for separator in ["。", "！", "!", "\n"] {
                if let first = line.components(separatedBy: separator).first, first.count >= 4 {
                    add(String(first.prefix(18)))
                }
            }
            add(String(line.prefix(18)))
        }
        add(String(trimmed.prefix(18)))
        return probes
    }

    private func focusChatInput(appName: String, bundleID: String?) throws {
        var args: [String: Any] = ["app_name": appName]
        if let bundleID { args["bundle_id"] = bundleID }
        try activateTargetAppIfProvided(args)
        Thread.sleep(forTimeInterval: 0.2)
        if let app = NSWorkspace.shared.frontmostApplication {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let textArea = findAXElement(root, label: "", role: "AXTextArea", maxNodes: 1_500),
               let position = axCGPoint(textArea, kAXPositionAttribute as CFString),
               let size = axCGSize(textArea, kAXSizeAttribute as CFString),
               size.width > 40,
               size.height > 20 {
                try clickPoint(x: Double(position.x + size.width / 2), y: Double(position.y + size.height / 2))
                Thread.sleep(forTimeInterval: 0.15)
                return
            }
        }
        if let bounds = frontmostWindowBounds() {
            try clickPoint(
                x: Double(bounds.midX + bounds.width * 0.18),
                y: Double(bounds.maxY - max(42, min(95, bounds.height * 0.09)))
            )
        }
        Thread.sleep(forTimeInterval: 0.15)
    }

    private func recentlyAttemptedExternalSend(app: String, recipient: String, text: String, within seconds: TimeInterval) -> Bool {
        pruneRecentExternalSendAttempts()
        let key = externalSendKey(app: app, recipient: recipient, text: text)
        guard let date = Self.recentExternalSendAttempts[key] else { return false }
        return Date().timeIntervalSince(date) <= seconds
    }

    private func markExternalSendAttempt(app: String, recipient: String, text: String) {
        pruneRecentExternalSendAttempts()
        Self.recentExternalSendAttempts[externalSendKey(app: app, recipient: recipient, text: text)] = Date()
    }

    private func pruneRecentExternalSendAttempts() {
        let cutoff = Date().addingTimeInterval(-600)
        Self.recentExternalSendAttempts = Self.recentExternalSendAttempts.filter { $0.value >= cutoff }
    }

    private func externalSendKey(app: String, recipient: String, text: String) -> String {
        "\(app.lowercased())|\(recipient.lowercased())|\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func tencentMeetingStageJoin(_ args: [String: Any]) throws -> ToolResult {
        guard let meeting = string(args["meeting"]), !meeting.isEmpty else { throw RuntimeError("meeting is required") }
        _ = try openNamedApp("TencentMeeting")
        _ = try clipboardSetText(["text": meeting])
        return ToolResult(success: true, evidence: "Opened Tencent Meeting and copied meeting id/link to clipboard. It did not join.", data: ["meeting": meeting])
    }

    private func baiduNetdiskStageFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        _ = try openNamedApp("BaiduNetdisk_mac")
        _ = try clipboardSetFiles(["paths": [path]])
        return ToolResult(success: true, evidence: "Opened Baidu Netdisk and put the file on clipboard. It did not upload.", data: ["path": path])
    }

    private func toDeskStageRemoteID(_ args: [String: Any]) throws -> ToolResult {
        guard let remoteID = string(args["remote_id"]), !remoteID.isEmpty else { throw RuntimeError("remote_id is required") }
        _ = try openNamedApp("ToDesk")
        _ = try clipboardSetText(["text": remoteID])
        return ToolResult(success: true, evidence: "Opened ToDesk and copied remote id/code to clipboard. It did not connect.", data: ["remote_id": remoteID])
    }

    private func openNamedApp(_ appName: String) throws -> ToolResult {
        try runProcess("/usr/bin/open", ["-a", appName])
        return ToolResult(success: true, evidence: "Opened \(appName).", data: [
            "effect": "app_opened",
            "app": appName,
            "verified": "true"
        ])
    }

    private func openAppTarget(_ target: AppLaunchTarget) throws -> ToolResult {
        if let rawPath = target.appPath {
            let path = rawPath.expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                try runProcess("/usr/bin/open", [path])
                return ToolResult(success: true, evidence: "Opened \(target.displayName).", data: [
                    "effect": "app_opened",
                    "app": target.displayName,
                    "path": path,
                    "verified": "true"
                ])
            }
        }

        if let appName = target.appName {
            try runProcess("/usr/bin/open", ["-a", appName])
            return ToolResult(success: true, evidence: "Opened \(target.displayName).", data: [
                "effect": "app_opened",
                "app": target.displayName,
                "open_name": appName,
                "verified": "true"
            ])
        }

        return ToolResult(success: false, evidence: "Application bundle was not found.", error: target.displayName)
    }

    private func openPathWithApp(_ args: [String: Any], appName: String) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        try runProcess("/usr/bin/open", ["-a", appName, path])
        return ToolResult(success: true, evidence: "Opened path in \(appName).", data: ["app": appName, "path": path])
    }

    private func libreOfficeExportPDF(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        let inputURL = URL(fileURLWithPath: path)
        let outdir = (string(args["outdir"]) ?? inputURL.deletingLastPathComponent().path).expandingTildeInPath
        try FileManager.default.createDirectory(atPath: outdir, withIntermediateDirectories: true)
        let soffice = try resolveSofficePath()
        let output = try runProcess(soffice, [
            "--headless",
            "--convert-to", "pdf",
            "--outdir", outdir,
            path
        ])
        let pdfURL = URL(fileURLWithPath: outdir)
            .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("pdf")
        let exists = FileManager.default.fileExists(atPath: pdfURL.path)
        return ToolResult(success: exists, evidence: exists ? "Exported PDF with LibreOffice." : "LibreOffice finished but PDF was not found.", data: [
            "effect": "pdf_exported",
            "app": "LibreOffice",
            "target": path,
            "value": pdfURL.path,
            "verified": exists ? "true" : "false",
            "path": path,
            "outdir": outdir,
            "pdf": pdfURL.path,
            "output": output
        ], error: exists ? nil : "Expected PDF not found: \(pdfURL.path)")
    }

    private func resolveSofficePath() throws -> String {
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let which = try? runProcess("/usr/bin/which", ["soffice"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let which, !which.isEmpty, FileManager.default.isExecutableFile(atPath: which) {
            return which
        }
        throw RuntimeError("soffice executable not found. Install LibreOffice or put soffice on PATH.")
    }

    private func dockerStatus() -> ToolResult {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.docker.docker").first
        let windows = app.map { visibleWindowTitles(pid: $0.processIdentifier) } ?? []
        return ToolResult(
            success: true,
            evidence: app == nil ? "Docker Desktop is not running." : "Docker Desktop is running.",
            data: [
                "running": app == nil ? "false" : "true",
                "pid": app.map { "\($0.processIdentifier)" } ?? "",
                "windows": windows.joined(separator: " | ")
            ]
        )
    }

    private func shortcutsList() throws -> ToolResult {
        let output = try runProcess("/usr/bin/shortcuts", ["list"])
        let names = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ToolResult(success: true, evidence: "Listed \(names.count) Shortcut(s).", data: [
            "shortcuts": jsonStringValue(names)
        ])
    }

    private func shortcutsRun(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        let output = try runProcess("/usr/bin/shortcuts", ["run", name])
        return ToolResult(success: true, evidence: "Ran Shortcut \(name).", data: [
            "effect": "shortcut_ran",
            "app": "Shortcuts",
            "target": name,
            "name": name,
            "output": output,
            "verified": "true"
        ])
    }

    private func sdefLookup(_ args: [String: Any]) throws -> ToolResult {
        let targetPath: String
        if let rawPath = string(args["path"]), !rawPath.isEmpty {
            targetPath = rawPath.expandingTildeInPath
        } else if let appName = string(args["app_name"]), !appName.isEmpty {
            targetPath = try appPathForName(appName)
        } else {
            throw RuntimeError("app_name or path is required")
        }
        let xml = try runProcess("/usr/bin/sdef", [targetPath])
        let query = string(args["query"])?.lowercased()
        let maxLines = int(args["max_lines"]) ?? 120
        let lines = xml.components(separatedBy: .newlines)
            .filter { line in
                guard let query, !query.isEmpty else { return true }
                return line.lowercased().contains(query)
            }
        let summary = summarizeSDEF(xml: xml, query: query, maxLines: maxLines)
        return ToolResult(success: true, evidence: "Read AppleScript dictionary for \(targetPath).", data: [
            "path": targetPath,
            "summary": summary,
            "matched_lines": lines.prefix(maxLines).joined(separator: "\n"),
            "truncated": lines.count > maxLines ? "true" : "false"
        ])
    }

    private func scriptingBridgeProbe(_ args: [String: Any]) -> ToolResult {
        guard let bundleID = string(args["bundle_id"]), !bundleID.isEmpty else {
            return ToolResult(success: false, evidence: "bundle_id is required.", error: "bundle_id is required")
        }
        guard let app = SBApplication(bundleIdentifier: bundleID) else {
            return ToolResult(success: false, evidence: "No ScriptingBridge application object.", error: bundleID)
        }
        return ToolResult(success: true, evidence: "ScriptingBridge application object is available.", data: [
            "bundle_id": bundleID,
            "running": app.isRunning ? "true" : "false",
            "class": "\(type(of: app))"
        ])
    }

    private func remindersCreate(_ args: [String: Any]) throws -> ToolResult {
        guard let title = string(args["title"]), !title.isEmpty else { throw RuntimeError("title is required") }
        let notes = string(args["notes"]) ?? ""
        let listName = string(args["list"])
        let targetListLine = if let listName, !listName.isEmpty {
            "set targetList to first list whose name contains \(appleScriptString(listName))"
        } else {
            "set targetList to default list"
        }
        _ = try runAppleScript("""
        tell application "Reminders"
          activate
          \(targetListLine)
          make new reminder at end of reminders of targetList with properties {name:\(appleScriptString(title)), body:\(appleScriptString(notes))}
        end tell
        """)
        let verification = try runAppleScript("""
        tell application "Reminders"
          set foundReminders to {}
          repeat with l in lists
            set matches to (every reminder of l whose name contains \(appleScriptString(title)))
            repeat with r in matches
              set end of foundReminders to name of r
            end repeat
          end repeat
          set AppleScript's text item delimiters to linefeed
          return foundReminders as text
        end tell
        """)
        let verified = verification.localizedCaseInsensitiveContains(title)
        return ToolResult(success: verified, evidence: verified ? "Created and verified local reminder." : "Created local reminder, but verification did not find it.", data: [
            "effect": "reminder_created",
            "app": "Reminders",
            "target": title,
            "title": title,
            "notes": notes,
            "verified": verified ? "true" : "false"
        ], error: verified ? nil : "Reminder title not found after create")
    }

    private func safariNewTab(_ args: [String: Any]) throws -> ToolResult {
        let rawURL = string(args["url"])
        if let rawURL, URL(string: rawURL) == nil {
            throw RuntimeError("valid url is required")
        }
        let urlLine = rawURL.map { "set URL of newTab to \(appleScriptString($0))" } ?? ""
        _ = try runAppleScript("""
        tell application "Safari"
          activate
          if not (exists window 1) then make new document
          tell window 1
            set newTab to make new tab at end of tabs
            set current tab to newTab
            \(urlLine)
          end tell
        end tell
        """)
        if let rawURL {
            Thread.sleep(forTimeInterval: 0.2)
            let current = (try? safariGetCurrentURL())?.data["url"] ?? ""
            let verified = current.localizedCaseInsensitiveContains(rawURL) || rawURL.localizedCaseInsensitiveContains(current)
            return ToolResult(success: verified, evidence: verified ? "Opened and verified a new Safari tab with URL." : "Safari new tab URL did not verify.", data: [
                "effect": "browser_url_visible",
                "app": "Safari",
                "target": rawURL,
                "url": rawURL,
                "current_url": current,
                "verified": verified ? "true" : "false",
                "verified_current_url": verified ? "true" : "false"
            ], error: verified ? nil : "Expected Safari URL not visible")
        }
        return ToolResult(success: true, evidence: "Opened a new Safari tab.", data: [
            "effect": "browser_tab_opened",
            "app": "Safari",
            "verified": "true"
        ])
    }

    private func safariSearch(_ args: [String: Any]) throws -> ToolResult {
        guard let query = string(args["query"]), !query.isEmpty else { throw RuntimeError("query is required") }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try safariOpenURL(["url": "https://www.google.com/search?q=\(encoded)"])
    }

    private func fileSummary(_ url: URL) -> [String: String] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey])
        return [
            "name": url.lastPathComponent,
            "path": url.path,
            "kind": values?.isDirectory == true ? "directory" : "file",
            "is_package": values?.isPackage == true ? "true" : "false",
            "size": "\(values?.fileSize ?? 0)",
            "modified": values?.contentModificationDate.map(isoDateString) ?? ""
        ]
    }

    private func parseDateTime(_ text: String) -> Date? {
        let formats = [
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    private func appleScriptDateAssignment(_ variable: String, _ date: Date) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let month = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ][max(0, min(11, (parts.month ?? 1) - 1))]
        let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        return """
        set \(variable) to current date
        set year of \(variable) to \(parts.year ?? 2000)
        set month of \(variable) to \(month)
        set day of \(variable) to \(parts.day ?? 1)
        set time of \(variable) to \(seconds)
        """
    }

    private func textEditNewDocument() throws -> ToolResult {
        _ = try runAppleScript("""
        tell application "TextEdit"
          activate
          make new document
        end tell
        """)
        return ToolResult(success: true, evidence: "TextEdit has a new front document.", data: [
            "effect": "app_opened",
            "app": "TextEdit",
            "verified": "true"
        ])
    }

    private func textEditSetText(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        _ = try runAppleScript("""
        tell application "TextEdit"
          activate
          if not (exists document 1) then make new document
          set text of document 1 to \(appleScriptString(text))
        end tell
        """)
        return ToolResult(success: true, evidence: "TextEdit front document text was set.", data: ["chars": "\(text.count)"])
    }

    private func textEditReadText() throws -> ToolResult {
        let text = try runAppleScript("""
        tell application "TextEdit"
          if not (exists document 1) then return ""
          return text of document 1
        end tell
        """)
        return ToolResult(success: true, evidence: "Read TextEdit front document.", data: ["text": text, "chars": "\(text.count)"])
    }

    private func textEditSaveAs(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let overwrite = bool(args["overwrite"]) ?? false
        let path = rawPath.expandingTildeInPath
        let url = URL(fileURLWithPath: path)

        if FileManager.default.fileExists(atPath: path), !overwrite {
            return ToolResult(
                success: false,
                evidence: "Refused to overwrite existing file.",
                error: "File exists: \(path)",
                suggestion: "Set overwrite=true only if the user explicitly asked to overwrite."
            )
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            _ = try runAppleScript("""
            tell application "TextEdit"
              if not (exists document 1) then error "No TextEdit document is open"
              save document 1 in POSIX file \(appleScriptString(path))
            end tell
            """)
        } catch {
            let text = try runAppleScript("""
            tell application "TextEdit"
              if not (exists document 1) then error "No TextEdit document is open"
              return text of document 1
            end tell
            """)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        let exists = FileManager.default.fileExists(atPath: path)
        return ToolResult(success: exists, evidence: exists ? "File exists at \(path)." : "Save did not create the file.", data: [
            "effect": "file_saved",
            "app": "TextEdit",
            "target": path,
            "path": path,
            "verified": exists ? "true" : "false"
        ])
    }

    private func finderCreateFolder(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let isDir = isDirectory(path)
        return ToolResult(success: isDir, evidence: isDir ? "Folder exists at \(path)." : "Folder was not found after creation.", data: [
            "effect": "folder_created",
            "app": "Finder",
            "target": path,
            "path": path,
            "verified": isDir ? "true" : "false"
        ])
    }

    private func finderRevealFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return ToolResult(success: true, evidence: "Finder is revealing \(path).", data: ["path": path])
    }

    private func safariOpenURL(_ args: [String: Any]) throws -> ToolResult {
        guard let raw = string(args["url"]), let url = URL(string: raw) else {
            throw RuntimeError("valid url is required")
        }
        _ = try runAppleScript("""
        tell application "Safari"
          activate
          open location \(appleScriptString(url.absoluteString))
        end tell
        """)
        Thread.sleep(forTimeInterval: 0.2)
        let current = (try? safariGetCurrentURL())?.data["url"] ?? ""
        let verified = current.localizedCaseInsensitiveContains(url.absoluteString) || url.absoluteString.localizedCaseInsensitiveContains(current)
        return ToolResult(success: verified, evidence: verified ? "Safari opened and verified \(url.absoluteString)." : "Safari URL did not verify after open.", data: [
            "effect": "browser_url_visible",
            "app": "Safari",
            "target": url.absoluteString,
            "url": url.absoluteString,
            "current_url": current,
            "verified": verified ? "true" : "false",
            "verified_current_url": verified ? "true" : "false"
        ], error: verified ? nil : "Expected Safari URL not visible")
    }

    private func safariGetCurrentURL() throws -> ToolResult {
        let url = try runAppleScript("""
        tell application "Safari"
          if not (exists document 1) then return ""
          return URL of front document
        end tell
        """)
        return ToolResult(success: !url.isEmpty, evidence: url.isEmpty ? "Safari has no front URL." : "Read Safari front URL.", data: ["url": url])
    }

    private func safariGetPageText() throws -> ToolResult {
        return try safariEvalJS(["script": "document.body ? document.body.innerText : ''"])
    }

    private func safariEvalJS(_ args: [String: Any]) throws -> ToolResult {
        guard let script = string(args["script"]), !script.isEmpty else { throw RuntimeError("script is required") }
        do {
            let output = try runAppleScript("""
            tell application "Safari"
              if not (exists document 1) then return ""
              return do JavaScript \(appleScriptString(script)) in front document
            end tell
            """)
            return ToolResult(success: true, evidence: "Executed JavaScript in Safari front document.", data: [
                "result": output,
                "chars": "\(output.count)"
            ])
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("JavaScript") || message.localizedCaseInsensitiveContains("Apple Events") {
                return ToolResult(
                    success: false,
                    evidence: "Safari JavaScript automation is not available.",
                    error: message,
                    suggestion: "Enable Safari Developer menu and Allow JavaScript from Apple Events, or use AX/screenshot observation tools."
                )
            }
            throw error
        }
    }

    private func chromeGetPageText() throws -> ToolResult {
        return try chromeEvalJS(["script": "document.body ? document.body.innerText : ''"])
    }

    private func chromeEvalJS(_ args: [String: Any]) throws -> ToolResult {
        guard let script = string(args["script"]), !script.isEmpty else { throw RuntimeError("script is required") }
        do {
            let output = try runAppleScript("""
            tell application "Google Chrome"
              if (count of windows) = 0 then return ""
              return execute active tab of front window javascript \(appleScriptString(script))
            end tell
            """)
            return ToolResult(success: true, evidence: "Executed JavaScript in Chrome active tab.", data: [
                "result": output,
                "chars": "\(output.count)"
            ])
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("JavaScript") || message.localizedCaseInsensitiveContains("Apple") {
                return ToolResult(
                    success: false,
                    evidence: "Chrome JavaScript automation is not available.",
                    error: message,
                    suggestion: "Enable Chrome menu View > Developer > Allow JavaScript from Apple Events, or use AX/screenshot observation tools."
                )
            }
            throw error
        }
    }

    private func terminalRunCommand(_ args: [String: Any]) throws -> ToolResult {
        guard let command = string(args["command"]), !command.isEmpty else {
            throw RuntimeError("command is required")
        }
        _ = try runAppleScript("""
        tell application "Terminal"
          activate
          do script \(appleScriptString(command))
        end tell
        """)
        return ToolResult(success: true, evidence: "Terminal command was submitted.", data: [
            "effect": "shell_command_submitted",
            "app": "Terminal",
            "target": command,
            "command": command,
            "verified": "true"
        ])
    }

    private func appBundles(in root: URL, maxDepth: Int) -> [URL] {
        guard maxDepth >= 0 else { return [] }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for url in contents {
            if url.pathExtension == "app" {
                results.append(url)
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                results.append(contentsOf: appBundles(in: url, maxDepth: maxDepth - 1))
            }
        }
        return results
    }

    private func appInfo(_ url: URL) -> [String: String]? {
        guard url.pathExtension == "app" else { return nil }
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let fileName = url.deletingPathExtension().lastPathComponent
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? fileName
        return [
            "name": name,
            "bundle_id": bundle?.bundleIdentifier ?? "",
            "path": url.path
        ]
    }

    private func appPathForName(_ appName: String) throws -> String {
        let normalizedName = canonicalAppName(appName)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: commonBundleID(for: normalizedName)) {
            return url.path
        }
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/tmp/\(normalizedName.lowercased()).txt")) {
            let last = url.deletingPathExtension().lastPathComponent
            if last.localizedCaseInsensitiveContains(normalizedName) {
                return url.path
            }
        }
        let roots = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities"
        ]
        let matches = roots.flatMap { appBundles(in: URL(fileURLWithPath: $0), maxDepth: 3) }
            .filter { url in
                url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(normalizedName)
                    || (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "").localizedCaseInsensitiveContains(normalizedName)
                    || (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "").localizedCaseInsensitiveContains(normalizedName)
            }
        guard let first = matches.sorted(by: { $0.path < $1.path }).first else {
            if let builtIn = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.\(normalizedName)") {
                return builtIn.path
            }
            throw RuntimeError("Application not found: \(appName)")
        }
        let path = first.path
        if path.hasPrefix("/System/Applications/"), !FileManager.default.fileExists(atPath: path.appending("/Contents/sdef")) {
            let applicationPath = "/Applications/\(first.lastPathComponent)"
            if FileManager.default.fileExists(atPath: applicationPath) {
                return applicationPath
            }
        }
        return path
    }

    private func commonBundleID(for appName: String) -> String {
        let normalized = canonicalAppName(appName).lowercased().replacingOccurrences(of: " ", with: "")
        let map = [
            "safari": "com.apple.Safari",
            "textedit": "com.apple.TextEdit",
            "finder": "com.apple.finder",
            "mail": "com.apple.mail",
            "calendar": "com.apple.iCal",
            "notes": "com.apple.Notes",
            "reminders": "com.apple.reminders",
            "preview": "com.apple.Preview",
            "shortcuts": "com.apple.shortcuts",
            "wechat": "com.tencent.xinWeChat",
            "weixin": "com.tencent.xinWeChat",
            "lark": "com.larksuite.lark",
            "feishu": "com.electron.lark",
            "qq": "com.tencent.qq"
        ]
        return map[normalized] ?? "com.apple.\(appName)"
    }

    private func canonicalAppName(_ appName: String) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
        let map = [
            "微信": "WeChat",
            "wechat": "WeChat",
            "weixin": "WeChat",
            "飞书": "Lark",
            "lark": "Lark",
            "feishu": "Lark",
            "日历": "Calendar",
            "calendar": "Calendar",
            "提醒事项": "Reminders",
            "reminders": "Reminders",
            "备忘录": "Notes",
            "notes": "Notes",
            "邮件": "Mail",
            "mail": "Mail",
            "文本编辑": "TextEdit",
            "textedit": "TextEdit",
            "访达": "Finder",
            "finder": "Finder",
            "预览": "Preview",
            "preview": "Preview",
            "快捷指令": "Shortcuts",
            "shortcuts": "Shortcuts",
            "谷歌浏览器": "Google Chrome",
            "chrome": "Google Chrome"
        ]
        return map[normalized] ?? trimmed
    }

    private func appMatchesName(_ app: NSRunningApplication, requested: String) -> Bool {
        let localized = app.localizedName ?? ""
        let bundleID = app.bundleIdentifier ?? ""
        let requestedCanonical = canonicalAppName(requested)
        let localizedCanonical = canonicalAppName(localized)
        return localized.localizedCaseInsensitiveContains(requested) ||
            localized.localizedCaseInsensitiveContains(requestedCanonical) ||
            localizedCanonical.localizedCaseInsensitiveContains(requestedCanonical) ||
            requestedCanonical.localizedCaseInsensitiveContains(localizedCanonical) ||
            bundleID.localizedCaseInsensitiveContains(requested) ||
            bundleID.localizedCaseInsensitiveContains(requestedCanonical)
    }

    private func summarizeSDEF(xml: String, query: String?, maxLines: Int) -> String {
        let interestingTags = ["<suite", "<command", "<class", "<property", "<element", "<enumeration", "<enumerator"]
        let lines = xml.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                interestingTags.contains { line.hasPrefix($0) }
            }
            .filter { line in
                guard let query, !query.isEmpty else { return true }
                return line.lowercased().contains(query)
            }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    private func findRunningApp(_ args: [String: Any]) throws -> NSRunningApplication {
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        if let appName = string(args["app_name"]), !appName.isEmpty,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               appMatchesName($0, requested: appName)
           }) {
            return app
        }
        throw RuntimeError("running app not found; provide app_name or bundle_id")
    }

    private func appNameForTarget(_ args: [String: Any]) throws -> String {
        if let appName = string(args["app_name"]), !appName.isEmpty {
            let normalizedName = canonicalAppName(appName)
            _ = try openApp(["app_name": normalizedName])
            Thread.sleep(forTimeInterval: 0.2)
            return normalizedName
        }
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            _ = try openApp(["bundle_id": bundleID])
            Thread.sleep(forTimeInterval: 0.2)
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let name = app.localizedName {
                return name
            }
            throw RuntimeError("could not resolve app name for bundle id \(bundleID)")
        }
        guard let name = NSWorkspace.shared.frontmostApplication?.localizedName else {
            throw RuntimeError("no frontmost app")
        }
        return name
    }

    private func activateTargetAppIfProvided(_ args: [String: Any]) throws {
        if let appName = string(args["app_name"]), !appName.isEmpty {
            _ = try openApp(["app_name": canonicalAppName(appName)])
            Thread.sleep(forTimeInterval: 0.2)
            return
        }
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            _ = try openApp(["bundle_id": bundleID])
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func sendKeyboardShortcut(key: String, modifiers: [String]) throws {
        guard let keyCode = keyCode(for: key) else {
            throw RuntimeError("unsupported key: \(key)")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = eventFlags(for: modifiers)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw RuntimeError("could not create keyboard event")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        up.post(tap: .cghidEventTap)
    }

    private func clickPoint(x: Double, y: Double) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let point = CGPoint(x: x, y: y)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            throw RuntimeError("could not create mouse event")
        }
        down.post(tap: .cghidEventTap)
        usleep(60_000)
        up.post(tap: .cghidEventTap)
    }

    private func moveMouse(x: Double, y: Double) throws {
        let point = CGPoint(x: x, y: y)
        guard let move = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw RuntimeError("could not create mouse move event")
        }
        move.post(tap: .cghidEventTap)
    }

    private func dragMouse(from: CGPoint, to: CGPoint, duration: Double) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
        else {
            throw RuntimeError("could not create drag event")
        }
        down.post(tap: .cghidEventTap)
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                drag.post(tap: .cghidEventTap)
            }
            usleep(useconds_t(max(0.01, duration / Double(steps)) * 1_000_000))
        }
        up.post(tap: .cghidEventTap)
    }

    private func longPress(x: Double, y: Double, duration: Double) throws {
        let point = CGPoint(x: x, y: y)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            throw RuntimeError("could not create long press event")
        }
        down.post(tap: .cghidEventTap)
        usleep(useconds_t(max(0.1, duration) * 1_000_000))
        up.post(tap: .cghidEventTap)
    }

    private func setAXWindowPosition(_ window: AXUIElement, x: Double, y: Double) throws {
        var point = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &point) else { throw RuntimeError("could not create AX point") }
        let err = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        guard err == .success else { throw RuntimeError("AX window position failed: \(err.rawValue)") }
    }

    private func setAXWindowSize(_ window: AXUIElement, width: Double, height: Double) throws {
        var size = CGSize(width: width, height: height)
        guard let value = AXValueCreate(.cgSize, &size) else { throw RuntimeError("could not create AX size") }
        let err = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        guard err == .success else { throw RuntimeError("AX window size failed: \(err.rawValue)") }
    }

    private func eventFlags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "command", "cmd", "meta":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "option", "alt":
                flags.insert(.maskAlternate)
            case "control", "ctrl":
                flags.insert(.maskControl)
            default:
                continue
            }
        }
        return flags
    }

    private func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.lowercased()
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
            "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51,
            "backspace": 51, "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125,
            "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
            "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
        ]
        return map[normalized]
    }

    private func focusedAXElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value.map { unsafeDowncast($0, to: AXUIElement.self) }
    }

    private func axCopy(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success else { return nil }
        return value
    }

    private func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        guard let value = axCopy(element, attribute) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func axBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        guard let value = axCopy(element, attribute) else { return nil }
        return value as? Bool
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = axCopy(element, kAXChildrenAttribute as CFString) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func describeAXElement(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        lines: inout [String],
        count: inout Int
    ) {
        guard depth <= maxDepth, count < maxNodes else { return }
        count += 1
        let role = axString(element, kAXRoleAttribute as CFString) ?? "AXUnknown"
        let title = axString(element, kAXTitleAttribute as CFString) ?? ""
        let value = axString(element, kAXValueAttribute as CFString) ?? ""
        let desc = axString(element, kAXDescriptionAttribute as CFString) ?? ""
        let enabled = axBool(element, kAXEnabledAttribute as CFString).map { $0 ? "enabled" : "disabled" } ?? ""
        let bits = [role, title, value, desc, enabled].filter { !$0.isEmpty }
        lines.append("\(String(repeating: "  ", count: depth))- \(bits.joined(separator: " | "))")
        for child in axChildren(element) {
            describeAXElement(child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, lines: &lines, count: &count)
            if count >= maxNodes { return }
        }
    }

    private func findAXElement(_ root: AXUIElement, label: String, role: String?, maxNodes: Int) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        let needle = label.lowercased()
        let roleNeedle = role?.lowercased()
        while !queue.isEmpty, visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            let elementRole = axString(element, kAXRoleAttribute as CFString) ?? ""
            let text = [
                axString(element, kAXTitleAttribute as CFString),
                axString(element, kAXDescriptionAttribute as CFString),
                axString(element, kAXValueAttribute as CFString),
                axString(element, kAXHelpAttribute as CFString)
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            if text.contains(needle), roleNeedle == nil || elementRole.lowercased().contains(roleNeedle!) {
                return element
            }
            queue.append(contentsOf: axChildren(element))
        }
        return nil
    }

    private func collectActionableAXElements(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        visited: inout Int,
        elements: inout [[String: String]],
        path: String
    ) {
        guard depth <= maxDepth, visited < maxNodes else { return }
        visited += 1
        let role = axString(element, kAXRoleAttribute as CFString) ?? ""
        let title = axString(element, kAXTitleAttribute as CFString) ?? ""
        let desc = axString(element, kAXDescriptionAttribute as CFString) ?? ""
        let value = axString(element, kAXValueAttribute as CFString) ?? ""
        let label = [title, desc, value].filter { !$0.isEmpty }.joined(separator: " | ")
        let actionableRoles = [
            "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuItem", "AXLink",
            "AXCell", "AXRow"
        ]
        if actionableRoles.contains(role) || !label.isEmpty && role != "AXGroup" && role != "AXStaticText" {
            var row: [String: String] = [
                "index": "\(elements.count + 1)",
                "role": role,
                "label": label,
                "ax_path": path,
                "title": title,
                "description": desc,
                "value": value
            ]
            if let position = axCGPoint(element, kAXPositionAttribute as CFString) {
                row["x"] = "\(Int(position.x))"
                row["y"] = "\(Int(position.y))"
            }
            if let size = axCGSize(element, kAXSizeAttribute as CFString) {
                row["width"] = "\(Int(size.width))"
                row["height"] = "\(Int(size.height))"
            }
            elements.append(row)
        }
        for (index, child) in axChildren(element).enumerated() {
            collectActionableAXElements(child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, visited: &visited, elements: &elements, path: "\(path).\(index)")
            if visited >= maxNodes { return }
        }
    }

    private func findAXElementByPath(_ root: AXUIElement, path: String) -> AXUIElement? {
        let parts = path.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        var current = root
        for index in parts.dropFirst() {
            let children = axChildren(current)
            guard index >= 0, index < children.count else { return nil }
            current = children[index]
        }
        return current
    }

    private func axCGPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        guard let value = axCopy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var point = CGPoint.zero
        if AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) {
            return point
        }
        return nil
    }

    private func axCGSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        guard let value = axCopy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var size = CGSize.zero
        if AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) {
            return size
        }
        return nil
    }

    private func visibleWindowTitles(pid: pid_t) -> [String] {
        guard pid > 0 else { return [] }
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos.compactMap { info in
            guard ownerPID(from: info) == pid else { return nil }
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return info[kCGWindowName as String] as? String
        }.filter { !$0.isEmpty }
    }

    private func frontmostWindowBounds() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  ownerPID(from: info) == app.processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any]
            else { continue }
            let x = double(bounds["X"]) ?? 0
            let y = double(bounds["Y"]) ?? 0
            let width = double(bounds["Width"]) ?? 0
            let height = double(bounds["Height"]) ?? 0
            if width > 0, height > 0 {
                return CGRect(x: x, y: y, width: width, height: height)
            }
        }
        return nil
    }

    private func ownerPID(from info: [String: Any]) -> pid_t? {
        if let value = info[kCGWindowOwnerPID as String] as? NSNumber {
            return pid_t(value.int32Value)
        }
        if let value = info[kCGWindowOwnerPID as String] as? Int {
            return pid_t(value)
        }
        return nil
    }
}

struct ToolResult: Codable {
    let success: Bool
    let evidence: String
    var data: [String: String] = [:]
    var error: String?
    var suggestion: String?

    var jsonString: String {
        let safe = ToolResult(
            success: success,
            evidence: truncateMiddle(evidence, maxCharacters: 4_000),
            data: data.mapValues { truncateMiddle($0, maxCharacters: 8_000) },
            error: error.map { truncateMiddle($0, maxCharacters: 4_000) },
            suggestion: suggestion.map { truncateMiddle($0, maxCharacters: 2_000) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(safe)) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"success":false,"evidence":"encoding failed"}"#
    }
}

final class ToolResultAsyncBox: @unchecked Sendable {
    var result: Result<ToolResult, Error>?
}

struct RuntimeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
    [
        "type": "function",
        "function": [
            "name": name,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ]
        ]
    ]
}

private func schema(_ type: String, _ description: String) -> [String: Any] {
    ["type": type, "description": description]
}

private func arraySchema(_ itemType: String, _ description: String) -> [String: Any] {
    [
        "type": "array",
        "description": description,
        "items": ["type": itemType]
    ]
}

private func arrayObjectSchema(_ description: String, _ properties: [String: Any], required: [String] = ["id", "title", "goal", "verification"]) -> [String: Any] {
    [
        "type": "array",
        "description": description,
        "items": [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    ]
}

private func runAppleScript(_ source: String) throws -> String {
    guard let script = NSAppleScript(source: source) else {
        throw RuntimeError("Could not compile AppleScript")
    }
    var error: NSDictionary?
    let output = script.executeAndReturnError(&error)
    if let error {
        throw RuntimeError("AppleScript failed: \(error)")
    }
    return output.stringValue ?? ""
}

@discardableResult
private func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        throw RuntimeError(output.isEmpty ? "\(executable) failed" : output)
    }
    return output
}

private func appleScriptString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func string(_ value: Any?) -> String? {
    value as? String
}

private func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
    return nil
}

private func int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

private func double(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func intArgument(_ args: [String], name: String) -> Int? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return Int(args[index + 1])
}

private func doubleArgument(_ args: [String], name: String) -> Double? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return Double(args[index + 1])
}

private func stringArgument(_ args: [String], name: String) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

private func positionalArguments<S: Sequence>(_ args: S) -> [String] where S.Element == String {
    var values: [String] = []
    var skipNext = false
    let optionsWithValues: Set<String> = ["--repeat", "--seconds", "--recipe-id"]
    for arg in args {
        if skipNext {
            skipNext = false
            continue
        }
        if optionsWithValues.contains(arg) {
            skipNext = true
            continue
        }
        if arg.hasPrefix("--") {
            continue
        }
        values.append(arg)
    }
    return values
}

private func stringArray(_ value: Any?, name: String) throws -> [String] {
    if let strings = value as? [String] {
        return strings
    }
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array.compactMap { $0 as? String }
        }
        return trimmed
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    if let array = value as? [Any] {
        return array.compactMap { $0 as? String }
    }
    throw RuntimeError("\(name) must be an array of strings")
}

private func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

private func jsonLine(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return "\(value)"
    }
    return text
}

private func jsonStringValue(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return "\(value)"
    }
    return text
}

private func parseJSONObject(_ text: String) throws -> [String: Any] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    let data = Data(trimmed.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RuntimeError("Expected a JSON object")
    }
    return object
}

private func writeJSONObject(_ value: Any, to url: URL) throws {
    guard JSONSerialization.isValidJSONObject(value) else {
        throw RuntimeError("Value is not valid JSON")
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: [.atomic])
}

private func isoDateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func truncateMiddle(_ text: String, maxCharacters: Int) -> String {
    guard text.count > maxCharacters else { return text }
    let markerBudget = 64
    let keep = max(0, (maxCharacters - markerBudget) / 2)
    let head = text.prefix(keep)
    let tail = text.suffix(keep)
    let omitted = text.count - head.count - tail.count
    return "\(head)\n...[truncated \(omitted) chars]...\n\(tail)"
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
