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

struct RecipeStep: Codable {
    let id: String
    let title: String
    let tool: String
    let arguments: [String: String]
    let preconditions: [RecipeCondition]?
    let verifyTool: String?
    let verifyArguments: [String: String]?
    let waitCondition: String?
    let waitValue: String?
    let retries: Int?
    let fallbackTools: [RecipeFallback]?
    let verifyExpression: String?
    let postconditions: [RecipeCondition]?
    let recoverySteps: [RecipeStep]?
    let timeout: Double?
    let nextOnSuccess: String?
    let nextOnFailure: String?
    let loopUntil: RecipeCondition?
    let maxIterations: Int?
    let stateWrites: [String: String]?

    init(
        id: String,
        title: String,
        tool: String,
        arguments: [String: String],
        preconditions: [RecipeCondition]? = nil,
        verifyTool: String? = nil,
        verifyArguments: [String: String]? = nil,
        waitCondition: String? = nil,
        waitValue: String? = nil,
        retries: Int? = nil,
        fallbackTools: [RecipeFallback]? = nil,
        verifyExpression: String? = nil,
        postconditions: [RecipeCondition]? = nil,
        recoverySteps: [RecipeStep]? = nil,
        timeout: Double? = nil,
        nextOnSuccess: String? = nil,
        nextOnFailure: String? = nil,
        loopUntil: RecipeCondition? = nil,
        maxIterations: Int? = nil,
        stateWrites: [String: String]? = nil
    ) {
        self.id = id
        self.title = title
        self.tool = tool
        self.arguments = arguments
        self.preconditions = preconditions
        self.verifyTool = verifyTool
        self.verifyArguments = verifyArguments
        self.waitCondition = waitCondition
        self.waitValue = waitValue
        self.retries = retries
        self.fallbackTools = fallbackTools
        self.verifyExpression = verifyExpression
        self.postconditions = postconditions
        self.recoverySteps = recoverySteps
        self.timeout = timeout
        self.nextOnSuccess = nextOnSuccess
        self.nextOnFailure = nextOnFailure
        self.loopUntil = loopUntil
        self.maxIterations = maxIterations
        self.stateWrites = stateWrites
    }
}

struct RecipeCondition: Codable {
    let description: String
    let tool: String
    let arguments: [String: String]
    let expression: String?

    init(description: String = "", tool: String, arguments: [String: String] = [:], expression: String? = nil) {
        self.description = description
        self.tool = tool
        self.arguments = arguments
        self.expression = expression
    }
}

struct RecipeParameter: Codable {
    let name: String
    let description: String
    let required: Bool
    let defaultValue: String?
    let examples: [String]

    init(name: String, description: String = "", required: Bool = true, defaultValue: String? = nil, examples: [String] = []) {
        self.name = name
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
        self.examples = examples
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
    let version: Int?
    let goalTemplate: String
    let parameters: [RecipeParameter]?
    let requiredParams: [String]
    let preconditions: [RecipeCondition]?
    let postconditions: [RecipeCondition]?
    let appBindings: [String: String]?
    let notes: String
    let steps: [RecipeStep]
    let successCount: Int?
    let failureCount: Int?

    init(
        id: String,
        title: String,
        version: Int? = 1,
        goalTemplate: String,
        parameters: [RecipeParameter]? = nil,
        requiredParams: [String],
        preconditions: [RecipeCondition]? = nil,
        postconditions: [RecipeCondition]? = nil,
        appBindings: [String: String]? = nil,
        notes: String,
        steps: [RecipeStep],
        successCount: Int? = nil,
        failureCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.goalTemplate = goalTemplate
        self.parameters = parameters
        self.requiredParams = requiredParams
        self.preconditions = preconditions
        self.postconditions = postconditions
        self.appBindings = appBindings
        self.notes = notes
        self.steps = steps
        self.successCount = successCount
        self.failureCount = failureCount
    }

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
        ),
        Recipe(
            id: "continuous-chat-followup",
            title: "Continue a chat conversation",
            goalTemplate: "在{{app}}里和{{recipient}}围绕{{objective}}持续沟通。先打开并观察聊天，再发送{{message_text}}，然后验证最近消息。",
            requiredParams: ["app", "recipient", "objective", "message_text"],
            notes: "Reusable bounded chat turn for resident long-running conversation loops.",
            steps: [
                RecipeStep(
                    id: "S1",
                    title: "Open or search chat",
                    tool: "{{chat_prefix}}_search_chat",
                    arguments: ["name": "{{recipient}}"],
                    retries: 1,
                    fallbackTools: [
                        RecipeFallback(tool: "{{chat_prefix}}_open", arguments: [:])
                    ]
                ),
                RecipeStep(
                    id: "S2",
                    title: "Send bounded reply",
                    tool: "{{chat_prefix}}_send_text",
                    arguments: ["{{recipient_key}}": "{{recipient}}", "text": "{{message_text}}"],
                    verifyTool: "{{chat_prefix}}_verify_recent_message",
                    verifyArguments: ["text": "{{message_probe}}"],
                    retries: 1,
                    verifyExpression: "success && data.verified_message contains true"
                ),
                RecipeStep(
                    id: "S3",
                    title: "Remember chat outcome",
                    tool: "memory_remember",
                    arguments: ["kind": "workflow_hint", "scope": "chat", "app": "{{app}}", "key": "{{recipient}}", "value": "{{objective}} -> {{message_probe}}"],
                    verifyExpression: "success"
                )
            ]
        ),
        Recipe(
            id: "browser-business-task",
            title: "Operate a Chrome business web task",
            goalTemplate: "打开{{url}}并在 Chrome 里完成业务任务：{{objective}}。用 CDP observe/act/extract/wait 推进并验证页面状态。",
            requiredParams: ["url", "objective"],
            notes: "Stagehand-style browser recipe for authenticated business web apps. Keep selector repair evidence in the browser runtime cache.",
            steps: [
                RecipeStep(id: "S1", title: "Register browser session", tool: "browser_runtime_session", arguments: ["name": "{{browser_session}}", "url": "{{url}}", "status": "planned"], verifyExpression: "success"),
                RecipeStep(id: "S2", title: "Launch Chrome CDP", tool: "browser_cdp_launch", arguments: ["url": "{{url}}"], verifyTool: "browser_cdp_status", verifyArguments: [:], retries: 1),
                RecipeStep(id: "S3", title: "Observe page", tool: "browser_agent_observe", arguments: ["goal": "{{objective}}", "query": "{{browser_query}}"], retries: 1),
                RecipeStep(id: "S4", title: "Extract business state", tool: "browser_agent_extract", arguments: ["goal": "{{objective}}", "selector": "body", "schema": "{{extraction_schema}}"], retries: 1),
                RecipeStep(id: "S5", title: "Wait for stable page state", tool: "browser_agent_wait", arguments: ["goal": "{{objective}}", "condition": "network_idle", "value": "750", "timeout": "15"])
            ]
        ),
        Recipe(
            id: "document-export-and-send",
            title: "Export a document and send it to a contact",
            goalTemplate: "用 Finder 找到{{path}}，导出 PDF 到{{outdir}}，再通过{{app}}发给{{recipient}}并验证发送结果。",
            requiredParams: ["path", "outdir", "app", "recipient"],
            notes: "Combines Finder, document export, and chat delivery into one reusable workflow.",
            steps: [
                RecipeStep(id: "S1", title: "Verify source file", tool: "finder_file_info", arguments: ["path": "{{path}}"], waitCondition: "file_exists", waitValue: "{{path}}", verifyExpression: "success"),
                RecipeStep(id: "S2", title: "Export PDF", tool: "libreoffice_export_pdf", arguments: ["path": "{{path}}", "outdir": "{{outdir}}"], verifyTool: "finder_file_info", verifyArguments: ["path": "{{pdf_path}}"], waitCondition: "file_exists", waitValue: "{{pdf_path}}", retries: 1),
                RecipeStep(id: "S3", title: "Stage exported PDF", tool: "{{chat_prefix}}_stage_file", arguments: ["{{recipient_key}}": "{{recipient}}", "path": "{{pdf_path}}"], verifyTool: "{{chat_prefix}}_verify_chat", verifyArguments: ["{{recipient_key}}": "{{recipient}}"], retries: 1),
                RecipeStep(id: "S4", title: "Send staged PDF", tool: "{{chat_prefix}}_send_staged", arguments: ["{{recipient_key}}": "{{recipient}}"], verifyTool: "{{chat_prefix}}_verify_recent_message", verifyArguments: ["text": "{{pdf_file_name}}"], retries: 1)
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
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let recipe = try? JSONDecoder().decode(Recipe.self, from: data)
            else {
                return nil
            }
            return recipe
        }
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
                recipe.requiredParams.joined(separator: " "),
                (recipe.parameters ?? []).map { [$0.name, $0.description, $0.examples.joined(separator: " ")].joined(separator: " ") }.joined(separator: " "),
                (recipe.preconditions ?? []).map(\.description).joined(separator: " "),
                (recipe.postconditions ?? []).map(\.description).joined(separator: " ")
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

            if recipe.id == "document-export-and-send", !isDeliveryGoal(goalText) {
                score -= 8
            }
            if recipe.id == "export-document-pdf", isExportOnlyPDFGoal(goalText) {
                score += 8
                matched.insert("export-only")
            }

            if score <= 0 { return nil }
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
        return try execute(recipe: recipe, params: params, eventStore: eventStore)
    }

    @MainActor
    static func execute(recipe: Recipe, params: [String: Any], eventStore: EventStore? = nil) throws -> [ToolResult] {
        let resolved = try resolvedParams(recipe: recipe, params: params)
        let tools = ToolRegistry()
        var results: [ToolResult] = []

        let recipePreconditions = try evaluateConditions(
            recipe.preconditions,
            phase: "recipe_precondition",
            stepID: "recipe",
            callIDPrefix: "recipe-\(recipe.id)-pre",
            recipeID: recipe.id,
            params: resolved,
            tools: tools,
            eventStore: eventStore
        )
        results.append(contentsOf: recipePreconditions.results)
        guard recipePreconditions.ok else { return results }

        let indexByID = Dictionary(uniqueKeysWithValues: recipe.steps.enumerated().map { ($0.element.id, $0.offset) })
        var stepIndex = 0
        var transitions = 0
        var iterations: [String: Int] = [:]
        let maxTransitions = max(100, recipe.steps.count * 12)
        while stepIndex < recipe.steps.count && transitions < maxTransitions {
            transitions += 1
            let step = recipe.steps[stepIndex]
            let iteration = (iterations[step.id] ?? 0) + 1
            iterations[step.id] = iteration
            let maxIterations = max(1, step.maxIterations ?? 1)
            if iteration > maxIterations {
                results.append(ToolResult(success: false, evidence: "Recipe step \(step.id) exceeded maxIterations=\(maxIterations).", error: "recipe_loop_limit"))
                return results
            }

            let stepResults = try executeStep(step, recipeID: recipe.id, params: resolved, tools: tools, eventStore: eventStore, prefix: "recipe")
            results.append(contentsOf: stepResults)
            let ok = stepResults.last?.success == true

            if ok, let stateWrites = step.stateWrites, !stateWrites.isEmpty {
                var fields = renderArguments(stateWrites, params: resolved).compactMapValues { string($0) }
                fields["recipe_id"] = recipe.id
                fields["step_id"] = step.id
                try eventStore?.append("RecipeState", fields)
            }

            if ok, let loopUntil = step.loopUntil {
                let loopCheck = try evaluateConditions(
                    [loopUntil],
                    phase: "loop_until",
                    stepID: step.id,
                    callIDPrefix: "recipe-\(step.id)-loop\(iteration)",
                    recipeID: recipe.id,
                    params: resolved,
                    tools: tools,
                    eventStore: eventStore
                )
                results.append(contentsOf: loopCheck.results)
                if !loopCheck.ok {
                    continue
                }
            }

            if let nextID = ok ? step.nextOnSuccess : step.nextOnFailure {
                if nextID.uppercased() == "END" { break }
                guard let nextIndex = indexByID[nextID] else {
                    results.append(ToolResult(success: false, evidence: "Recipe branch target \(nextID) was not found.", error: "recipe_branch_target_missing"))
                    return results
                }
                stepIndex = nextIndex
                continue
            }

            guard ok else { return results }
            stepIndex += 1
        }
        if transitions >= maxTransitions {
            results.append(ToolResult(success: false, evidence: "Recipe exceeded transition limit.", error: "recipe_transition_limit"))
            return results
        }

        let recipePostconditions = try evaluateConditions(
            recipe.postconditions,
            phase: "recipe_postcondition",
            stepID: "recipe",
            callIDPrefix: "recipe-\(recipe.id)-post",
            recipeID: recipe.id,
            params: resolved,
            tools: tools,
            eventStore: eventStore
        )
        results.append(contentsOf: recipePostconditions.results)
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

        let preconditions = try evaluateConditions(
            step.preconditions,
            phase: "precondition",
            stepID: step.id,
            callIDPrefix: "\(prefix)-\(step.id)-pre",
            recipeID: recipeID,
            params: params,
            tools: tools,
            eventStore: eventStore
        )
        results.append(contentsOf: preconditions.results)
        guard preconditions.ok else { return results }

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
                role: "primary",
                callID: "\(prefix)-\(step.id)-try\(attempt)",
                recipeID: recipeID,
                params: params,
                tools: tools,
                eventStore: eventStore
            )
            results.append(contentsOf: primary.results)
            if primary.ok {
                let postconditions = try evaluateConditions(
                    step.postconditions,
                    phase: "postcondition",
                    stepID: step.id,
                    callIDPrefix: "\(prefix)-\(step.id)-post",
                    recipeID: recipeID,
                    params: params,
                    tools: tools,
                    eventStore: eventStore
                )
                results.append(contentsOf: postconditions.results)
                guard postconditions.ok else { return results }
                return results
            }

            for fallback in step.fallbackTools ?? [] {
                let failedToolName = render(step.tool, params: params)
                let fallbackToolName = render(fallback.tool, params: params)
                let fallbackArgumentsTemplate = fallback.arguments ?? step.arguments
                try eventStore?.append("RecipeRecovery", [
                    "step_id": step.id,
                    "attempt": "\(attempt)",
                    "failed_tool": failedToolName,
                    "fallback_tool": fallbackToolName
                ])
                let fallbackRun = try executeRecipeTool(
                    toolNameTemplate: fallback.tool,
                    argumentsTemplate: fallbackArgumentsTemplate,
                    verifyToolTemplate: fallback.verifyTool ?? step.verifyTool,
                    verifyArgumentsTemplate: fallback.verifyArguments ?? step.verifyArguments,
                    verifyExpressionTemplate: fallback.verifyExpression ?? step.verifyExpression,
                    stepID: step.id,
                    role: "fallback",
                    callID: "\(prefix)-\(step.id)-fallback\(attempt)",
                    recipeID: recipeID,
                    params: params,
                    tools: tools,
                    eventStore: eventStore
                )
                results.append(contentsOf: fallbackRun.results)
                if fallbackRun.ok {
                    let fallbackArgs = renderArguments(fallbackArgumentsTemplate, params: params).compactMapValues { string($0) }
                    _ = try? RecipeAdaptationStore.recordHint(
                        recipeID: recipeID,
                        stepID: step.id,
                        failedTool: failedToolName,
                        replacementTool: fallbackToolName,
                        arguments: fallbackArgs,
                        reason: "Fallback succeeded after primary tool \(failedToolName) failed.",
                        success: true
                    )
                    let postconditions = try evaluateConditions(
                        step.postconditions,
                        phase: "postcondition",
                        stepID: step.id,
                        callIDPrefix: "\(prefix)-\(step.id)-post",
                        recipeID: recipeID,
                        params: params,
                        tools: tools,
                        eventStore: eventStore
                    )
                    results.append(contentsOf: postconditions.results)
                    guard postconditions.ok else { return results }
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

        let failedToolName = render(step.tool, params: params)
        results.append(ToolResult(
            success: false,
            evidence: "Recipe step \(step.id) did not produce verified success.",
            data: [
                "recipe_id": recipeID,
                "step_id": step.id,
                "tool": failedToolName,
                "failure_phase": "step_exhausted"
            ],
            error: "recipe_step_failed"
        ))
        return results
    }

    @MainActor
    private static func evaluateConditions(
        _ conditions: [RecipeCondition]?,
        phase: String,
        stepID: String,
        callIDPrefix: String,
        recipeID: String,
        params: [String: String],
        tools: ToolRegistry,
        eventStore: EventStore?
    ) throws -> (ok: Bool, results: [ToolResult]) {
        guard let conditions, !conditions.isEmpty else { return (true, []) }
        var results: [ToolResult] = []
        for (index, condition) in conditions.enumerated() {
            let toolName = render(condition.tool, params: params)
            let args = renderArguments(condition.arguments, params: params)
            let result = tools.execute(ToolCall(id: "\(callIDPrefix)-\(index + 1)", name: toolName, arguments: args, raw: [:]))
            results.append(result)
            let expression = condition.expression.map { render($0, params: params) }
            let ok = result.success && (expression.map { evaluateVerifyExpression($0, result: result) } ?? true)
            let evidence = ok
                ? "\(phase) passed: \(condition.description.isEmpty ? toolName : condition.description)"
                : "\(phase) failed: \(condition.description.isEmpty ? toolName : condition.description)"
            let conditionResult = ToolResult(
                success: ok,
                evidence: evidence,
                data: [
                    "recipe_id": recipeID,
                    "step_id": stepID,
                    "phase": phase,
                    "tool": toolName,
                    "expression": expression ?? ""
                ],
                error: ok ? nil : "\(phase)_failed"
            )
            results.append(conditionResult)
            try eventStore?.append("RecipeCondition", [
                "recipe_id": recipeID,
                "step_id": stepID,
                "phase": phase,
                "tool": toolName,
                "success": ok ? "true" : "false",
                "evidence": conditionResult.evidence,
                "error": conditionResult.error ?? ""
            ])
            guard ok else { return (false, results) }
        }
        return (true, results)
    }

    @MainActor
    private static func executeRecipeTool(
        toolNameTemplate: String,
        argumentsTemplate: [String: String],
        verifyToolTemplate: String?,
        verifyArgumentsTemplate: [String: String]?,
        verifyExpressionTemplate: String?,
        stepID: String,
        role: String,
        callID: String,
        recipeID: String,
        params: [String: String],
        tools: ToolRegistry,
        eventStore: EventStore?
    ) throws -> (ok: Bool, results: [ToolResult]) {
        var results: [ToolResult] = []
        let toolName = render(toolNameTemplate, params: params)
        let args = renderArguments(argumentsTemplate, params: params)
        var result = tools.execute(ToolCall(id: callID, name: toolName, arguments: args, raw: [:]))
        result.data.merge([
            "recipe_id": recipeID,
            "step_id": stepID,
            "tool": toolName,
            "role": role,
            "call_id": callID,
            "arguments": jsonStringValue(args)
        ], uniquingKeysWith: { existing, _ in existing })
        results.append(result)
        AuditLog.append(action: "recipe_tool_result", fields: [
            "recipe_id": recipeID,
            "step_id": stepID,
            "tool": toolName,
            "role": role,
            "success": result.success ? "true" : "false",
            "evidence": result.evidence,
            "error": result.error ?? ""
        ])
        try eventStore?.append("RecipeObservation", [
            "step_id": stepID,
            "tool": toolName,
            "role": role,
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

    static func saveLearnedRecipe(id: String, title: String, steps: [RecipeStep], notes: String, requiredParams: [String] = [], goalTemplate: String? = nil) throws -> Recipe {
        let recipe = Recipe(
            id: id,
            title: title,
            goalTemplate: goalTemplate ?? "Run learned workflow: \(title)",
            requiredParams: requiredParams,
            notes: notes,
            steps: steps
        )
        return try save(recipe)
    }

    static func save(_ recipe: Recipe) throws -> Recipe {
        try FileManager.default.createDirectory(at: EventStore.recipesURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipe).write(to: recipeURL(recipe.id), options: [.atomic])
        return recipe
    }

    static func promoteRun(runID: String, recipeID: String? = nil, title: String? = nil) throws -> Recipe {
        let summary = try EventStore.readSummary(runID: runID)
        let events = EpisodeStore.parseEvents(try EventStore.readEventsText(runID: runID))
        var steps: [RecipeStep] = []
        var pendingAction: [String: String]?
        for event in events {
            switch event["event"] {
            case "AppAction":
                pendingAction = event
            case "Observation":
                guard let action = pendingAction,
                      event["success"] == "true",
                      let toolName = action["tool"],
                      !toolName.isEmpty,
                      let argumentsText = action["arguments"],
                      let argumentsData = argumentsText.data(using: .utf8),
                      let rawArgs = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any]
                else {
                    pendingAction = nil
                    continue
                }
                let args = rawArgs.compactMapValues { value -> String? in
                    if let text = value as? String { return parameterize(text) }
                    if let number = value as? NSNumber { return number.stringValue }
                    return nil
                }
                steps.append(RecipeStep(
                    id: "S\(steps.count + 1)",
                    title: toolName,
                    tool: toolName,
                    arguments: args,
                    verifyExpression: "success"
                ))
                pendingAction = nil
            default:
                continue
            }
        }
        guard !steps.isEmpty else {
            throw RuntimeError("Run \(runID) has no successful AppAction/Observation pairs to promote.")
        }
        let requiredParams = inferPlaceholders(from: steps)
        let parameters = requiredParams.map { name in
            RecipeParameter(name: name, description: "Promoted parameter inferred from run \(runID).", required: true)
        }
        let id = recipeID ?? "promoted-\(runID.prefix(8))"
        let recipe = Recipe(
            id: id,
            title: title ?? "Promoted workflow from \(runID.prefix(8))",
            goalTemplate: parameterize(summary.goal),
            parameters: parameters,
            requiredParams: requiredParams,
            preconditions: nil,
            postconditions: nil,
            appBindings: [:],
            notes: "Promoted from successful trajectory \(runID) at \(isoDateString(Date())). Review parameters, preconditions, and postconditions before broad reuse.",
            steps: coalescedRecipeSteps(steps),
            successCount: 1,
            failureCount: 0
        )
        return try save(recipe)
    }

    static func compile(recipeID: String) throws -> [[String: String]] {
        let recipe = try read(recipeID)
        let ids = Set(recipe.steps.map(\.id))
        return recipe.steps.map { step in
            let fallbacks = step.fallbackTools?.map(\.tool).joined(separator: ",") ?? ""
            let branchOK = step.nextOnSuccess.map { ids.contains($0) || $0.uppercased() == "END" } ?? true
            let branchFail = step.nextOnFailure.map { ids.contains($0) || $0.uppercased() == "END" } ?? true
            return [
                "id": step.id,
                "title": step.title,
                "tool": step.tool,
                "preconditions": "\((step.preconditions ?? []).count)",
                "postconditions": "\((step.postconditions ?? []).count)",
                "fallbacks": fallbacks,
                "next_on_success": step.nextOnSuccess ?? "",
                "next_on_failure": step.nextOnFailure ?? "",
                "loop_until": step.loopUntil?.description ?? "",
                "max_iterations": "\(step.maxIterations ?? 1)",
                "branch_valid": (branchOK && branchFail) ? "true" : "false"
            ]
        }
    }

    static func recordRunOutcome(recipeID: String, runID: String, success: Bool, notes: String = "") throws -> Recipe {
        let existing = try read(recipeID)
        let stamp = isoDateString(Date())
        let updatedNotes = [
            existing.notes,
            "\(stamp): run=\(runID) outcome=\(success ? "success" : "failure") \(notes)"
        ]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        let updated = Recipe(
            id: existing.id,
            title: existing.title,
            version: (existing.version ?? 1) + 1,
            goalTemplate: existing.goalTemplate,
            parameters: existing.parameters,
            requiredParams: existing.requiredParams,
            preconditions: existing.preconditions,
            postconditions: existing.postconditions,
            appBindings: existing.appBindings,
            notes: updatedNotes,
            steps: existing.steps,
            successCount: (existing.successCount ?? 0) + (success ? 1 : 0),
            failureCount: (existing.failureCount ?? 0) + (success ? 0 : 1)
        )
        return try save(updated)
    }

    private static func parameterize(_ value: String) -> String {
        let pathPattern = #"(/[^\s"'{}]+|\~/[^\s"'{}]+)"#
        var output = value.replacingOccurrences(of: pathPattern, with: "{{path}}", options: .regularExpression)
        if output.contains("@") {
            output = output.replacingOccurrences(of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, with: "{{email}}", options: [.regularExpression, .caseInsensitive])
        }
        return output
    }

    private static func inferPlaceholders(from steps: [RecipeStep]) -> [String] {
        let text = steps.flatMap { [$0.tool] + Array($0.arguments.keys) + Array($0.arguments.values) }.joined(separator: "\n")
        let pattern = #"\{\{([a-zA-Z0-9_\-]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsrange).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        return unique(matches)
    }

    private static func coalescedRecipeSteps(_ steps: [RecipeStep]) -> [RecipeStep] {
        var output: [RecipeStep] = []
        for step in steps {
            if let last = output.last, last.tool == step.tool, last.arguments == step.arguments {
                continue
            }
            output.append(RecipeStep(
                id: "S\(output.count + 1)",
                title: step.title,
                tool: step.tool,
                arguments: step.arguments,
                preconditions: step.preconditions,
                verifyTool: step.verifyTool,
                verifyArguments: step.verifyArguments,
                waitCondition: step.waitCondition,
                waitValue: step.waitValue,
                retries: step.retries,
                fallbackTools: step.fallbackTools,
                verifyExpression: step.verifyExpression,
                postconditions: step.postconditions,
                recoverySteps: step.recoverySteps,
                timeout: step.timeout,
                nextOnSuccess: step.nextOnSuccess,
                nextOnFailure: step.nextOnFailure,
                loopUntil: step.loopUntil,
                maxIterations: step.maxIterations,
                stateWrites: step.stateWrites
            ))
        }
        return output
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
                resolved["pdf_file_name"] = URL(fileURLWithPath: resolved["pdf_path"] ?? "").lastPathComponent
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
        if resolved["objective"] == nil { resolved["objective"] = resolved["topic"] ?? resolved["goal"] ?? "完成任务" }
        if resolved["browser_query"] == nil { resolved["browser_query"] = resolved["objective"] ?? "" }
        if resolved["extraction_schema"] == nil { resolved["extraction_schema"] = "title,url,text,links,forms,downloads,status" }
        if resolved["expected_text"] == nil { resolved["expected_text"] = resolved["browser_query"] ?? resolved["objective"] ?? "" }
        if resolved["browser_session"] == nil {
            resolved["browser_session"] = normalizeID(resolved["url"] ?? resolved["objective"] ?? "browser-task")
        }
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
                let phrases = ["发送", "发给", "文件", "附件", "计划", "方案", "同步", "导出", "转换", "文档", "pdf", "日历", "日程", "会议", "提醒", "微信", "飞书", "qq", "持续", "沟通", "网页", "业务", "chrome", "browser"]
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
        case "continuous-chat-followup":
            return ["chat", "聊天", "沟通", "持续", "followup", "follow-up", "reply", "回复", "wechat", "微信", "lark", "飞书", "qq"]
        case "browser-business-task":
            return ["browser", "chrome", "web", "网页", "业务", "表单", "提取", "下载", "selector", "cdp", "网站"]
        case "document-export-and-send":
            return ["文档", "文件", "pdf", "导出", "发送", "发给", "附件", "finder", "libreoffice", "wps", "微信", "飞书", "qq"]
        default:
            return []
        }
    }

    private static func isDeliveryGoal(_ text: String) -> Bool {
        ["发送", "发给", "同步", "分享", "联系人", "聊天", "微信", "飞书", "lark", "wechat", "qq", "contact", "send", "message"].contains { text.contains($0) }
    }

    private static func isExportOnlyPDFGoal(_ text: String) -> Bool {
        let wantsPDF = text.contains("pdf") || text.contains("导出") || text.contains("转换") || text.contains("转成")
        return wantsPDF && !isDeliveryGoal(text)
    }
}
