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

func sqliteTransientDestructor() -> sqlite3_destructor_type {
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
            await daemonCommand(args: Array(args.dropFirst()))
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

        if args.first == "resume" {
            resumeRun(args: Array(args.dropFirst()))
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
      swift run aios daemon status
      swift run aios daemon tick
      swift run aios daemon schedule "wait for the download and summarize it" --after-seconds 60
      swift run aios submit "Draft a short project plan and send it to Example Contact"
      swift run aios runs
      swift run aios cancel <run_id>
      swift run aios retry <run_id>
      swift run aios resume <run_id>
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
    private static func daemonCommand(args: [String]) async {
        let subcommand = args.first ?? "run"
        do {
            switch subcommand {
            case "run", "start":
                let host = AIOSHost(menuBar: false)
                await host.run()
            case "status":
                print(jsonStringValue(LongRunDaemonStore.status().dictionary))
            case "tick", "once":
                print(jsonStringValue(try LongRunDaemonStore.tick().dictionary))
            case "schedule":
                let goal = positionalArguments(args.dropFirst()).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !goal.isEmpty else { throw RuntimeError("Usage: aios daemon schedule \"<goal>\" [--after-seconds N]") }
                let scheduled = try LongRunDaemonStore.schedule(goal: goal, afterSeconds: doubleArgument(args, name: "--after-seconds") ?? 0)
                print(jsonStringValue(scheduled))
            default:
                throw RuntimeError("Unknown daemon command: \(subcommand)")
            }
        } catch {
            fputs("Daemon failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

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
    private static func resumeRun(args: [String]) {
        guard let id = args.first, !id.isEmpty else {
            fputs("Usage: aios resume <run_id>\n", stderr)
            exit(2)
        }
        do {
            let summary = try EventStore.readSummary(runID: id)
            try TaskQueue.submitExisting(runID: id, goal: summary.goal)
            print("resume_submitted: \(id)")
        } catch {
            fputs("Resume failed: \(error.localizedDescription)\n", stderr)
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
                    includeAX: !args.contains("--no-ax"),
                    synthesize: !args.contains("--raw")
                )
                if !args.contains("--no-learn-program"), !args.contains("--raw") {
                    let learned = try RecipeLearningEngine.learnRecipe(recipeID: recipe.id, sourceRunID: "raw-events:\(recipe.id)", title: recipe.title)
                    print(jsonStringValue([
                        "recipe": recipe.jsonString,
                        "learned_program": jsonStringValue(learned)
                    ]))
                } else {
                    print(recipe.jsonString)
                }
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
