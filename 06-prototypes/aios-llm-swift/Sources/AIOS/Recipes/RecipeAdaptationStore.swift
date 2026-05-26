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

struct RecipeRepairHint: Codable {
    let id: String
    let recipeID: String
    let stepID: String
    let failedTool: String
    let replacementTool: String
    let arguments: [String: String]
    let reason: String
    let successes: Int
    let failures: Int
    let updatedAt: String

    var fallback: RecipeFallback {
        RecipeFallback(tool: replacementTool, arguments: arguments, verifyExpression: "success")
    }

    var dictionary: [String: String] {
        [
            "id": id,
            "recipe_id": recipeID,
            "step_id": stepID,
            "failed_tool": failedTool,
            "replacement_tool": replacementTool,
            "arguments": jsonStringValue(arguments),
            "reason": reason,
            "successes": "\(successes)",
            "failures": "\(failures)",
            "updated_at": updatedAt
        ]
    }
}

struct RecipeAdaptationStore {
    static var hintsURL: URL {
        EventStore.recipesURL.appendingPathComponent("repair-hints.json")
    }

    @discardableResult
    static func recordHint(recipeID: String, stepID: String, failedTool: String, replacementTool: String, arguments: [String: String], reason: String, success: Bool = false) throws -> RecipeRepairHint {
        var hints = readAll()
        let id = "\(normalizeID(recipeID))|\(normalizeID(stepID))|\(normalizeID(failedTool))|\(normalizeID(replacementTool))"
        let existingIndex = hints.firstIndex { $0.id == id }
        let existing = existingIndex.map { hints[$0] }
        let hint = RecipeRepairHint(
            id: id,
            recipeID: recipeID,
            stepID: stepID,
            failedTool: failedTool,
            replacementTool: replacementTool,
            arguments: arguments,
            reason: reason,
            successes: (existing?.successes ?? 0) + (success ? 1 : 0),
            failures: (existing?.failures ?? 0) + (success ? 0 : 1),
            updatedAt: isoDateString(Date())
        )
        if let existingIndex {
            hints[existingIndex] = hint
        } else {
            hints.append(hint)
        }
        try writeAll(hints)
        return hint
    }

    static func hints(recipeID: String, stepID: String? = nil) -> [RecipeRepairHint] {
        readAll().filter { hint in
            hint.recipeID == recipeID && (stepID == nil || hint.stepID == stepID)
        }.sorted {
            let lhs = $0.successes - $0.failures
            let rhs = $1.successes - $1.failures
            if lhs != rhs { return lhs > rhs }
            return $0.updatedAt > $1.updatedAt
        }
    }

    static func outcomeSummary(recipeID: String) -> [[String: String]] {
        hints(recipeID: recipeID).map(\.dictionary)
    }

    static func readAll() -> [RecipeRepairHint] {
        guard let data = try? Data(contentsOf: hintsURL),
              let hints = try? JSONDecoder().decode([RecipeRepairHint].self, from: data)
        else { return [] }
        return hints
    }

    private static func writeAll(_ hints: [RecipeRepairHint]) throws {
        try FileManager.default.createDirectory(at: EventStore.recipesURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(hints).write(to: hintsURL, options: [.atomic])
    }
}

struct RecipeGeneralizer {
    static func preferredRecipeID(for id: String) -> String {
        guard let recipes = try? RecipeStore.list() else { return id }
        let candidates = recipes.filter { recipe in
            recipe.id == id || recipe.id.hasPrefix("\(id)-v") || recipe.id.hasPrefix("\(id)-generalized")
        }
        guard let best = candidates.max(by: { lhs, rhs in
            let lhsScore = (lhs.successCount ?? 0) * 3 - (lhs.failureCount ?? 0) + (lhs.version ?? 1)
            let rhsScore = (rhs.successCount ?? 0) * 3 - (rhs.failureCount ?? 0) + (rhs.version ?? 1)
            if lhsScore == rhsScore { return lhs.id > rhs.id }
            return lhsScore < rhsScore
        }) else {
            return id
        }
        return best.id
    }

    static func generalize(recipeID: String, outputID: String? = nil) throws -> Recipe {
        let recipe = try RecipeStore.read(recipeID)
        var parameters = recipe.parameters ?? []
        var seenParams = Set(parameters.map(\.name))
        var replacements: [String: String] = [:]

        func parameterName(for key: String, value: String) -> String? {
            let loweredKey = normalizeForSearch(key)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("{{") else { return nil }
            if loweredKey.contains("path") || trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return loweredKey.contains("out") ? "outdir" : "path" }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return "url" }
            if loweredKey.contains("recipient") || loweredKey.contains("chat") || loweredKey.contains("contact") || loweredKey.contains("name") { return loweredKey.contains("chat") ? "chat" : "recipient" }
            if loweredKey.contains("text") || loweredKey.contains("message") || trimmed.count > 40 { return "text" }
            if loweredKey.contains("title") { return "title" }
            if loweredKey.contains("selector") { return "selector" }
            if loweredKey.contains("query") { return "query" }
            return nil
        }

        for step in recipe.steps {
            for (key, value) in step.arguments {
                if let name = parameterName(for: key, value: value) {
                    replacements[value] = "{{\(name)}}"
                    if !seenParams.contains(name) {
                        seenParams.insert(name)
                        parameters.append(RecipeParameter(name: name, description: "Generalized from \(key) in recipe \(recipe.id).", required: true, defaultValue: nil, examples: [value]))
                    }
                }
            }
        }

        let steps = recipe.steps.map { step in
            var args = step.arguments
            for (literal, placeholder) in replacements {
                args = args.mapValues { $0.replacingOccurrences(of: literal, with: placeholder) }
            }
            let fallbacks = mergeFallbacks(step.fallbackTools ?? [], inferredFallbacks(for: step))
            return RecipeStep(
                id: step.id,
                title: step.title,
                tool: step.tool,
                arguments: args,
                preconditions: step.preconditions,
                verifyTool: step.verifyTool,
                verifyArguments: step.verifyArguments,
                waitCondition: step.waitCondition,
                waitValue: step.waitValue,
                retries: max(step.retries ?? 0, fallbacks.isEmpty ? 0 : 1),
                fallbackTools: fallbacks,
                verifyExpression: step.verifyExpression ?? "success",
                postconditions: step.postconditions,
                recoverySteps: step.recoverySteps,
                timeout: step.timeout,
                nextOnSuccess: step.nextOnSuccess,
                nextOnFailure: step.nextOnFailure,
                loopUntil: step.loopUntil,
                maxIterations: step.maxIterations,
                stateWrites: step.stateWrites
            )
        }

        let requiredParams = unique((recipe.requiredParams + parameters.filter(\.required).map(\.name)))
        let generalized = Recipe(
            id: outputID ?? "\(recipe.id)-generalized",
            title: recipe.title + " (generalized)",
            version: (recipe.version ?? 1) + 1,
            goalTemplate: generalizedGoalTemplate(recipe.goalTemplate, replacements: replacements, requiredParams: requiredParams),
            parameters: parameters,
            requiredParams: requiredParams,
            preconditions: recipe.preconditions,
            postconditions: recipe.postconditions,
            appBindings: recipe.appBindings,
            notes: [recipe.notes, "Generalized with inferred parameter schema and self-healing fallbacks."].filter { !$0.isEmpty }.joined(separator: "\n"),
            steps: steps,
            successCount: recipe.successCount,
            failureCount: recipe.failureCount
        )
        return try RecipeStore.save(generalized)
    }

    static func adaptiveRecipe(_ recipe: Recipe) -> Recipe {
        let steps = recipe.steps.map { step -> RecipeStep in
            let repairFallbacks = RecipeAdaptationStore.hints(recipeID: recipe.id, stepID: step.id).map(\.fallback)
            let fallbacks = mergeFallbacks(step.fallbackTools ?? [], repairFallbacks + inferredFallbacks(for: step))
            return RecipeStep(
                id: step.id,
                title: step.title,
                tool: step.tool,
                arguments: step.arguments,
                preconditions: step.preconditions,
                verifyTool: step.verifyTool,
                verifyArguments: step.verifyArguments,
                waitCondition: step.waitCondition,
                waitValue: step.waitValue,
                retries: max(step.retries ?? 0, fallbacks.isEmpty ? 0 : 1),
                fallbackTools: fallbacks,
                verifyExpression: step.verifyExpression,
                postconditions: step.postconditions,
                recoverySteps: step.recoverySteps,
                timeout: step.timeout,
                nextOnSuccess: step.nextOnSuccess,
                nextOnFailure: step.nextOnFailure,
                loopUntil: step.loopUntil,
                maxIterations: step.maxIterations,
                stateWrites: step.stateWrites
            )
        }
        return Recipe(
            id: recipe.id,
            title: recipe.title,
            version: recipe.version,
            goalTemplate: recipe.goalTemplate,
            parameters: recipe.parameters,
            requiredParams: recipe.requiredParams,
            preconditions: recipe.preconditions,
            postconditions: recipe.postconditions,
            appBindings: recipe.appBindings,
            notes: recipe.notes,
            steps: steps,
            successCount: recipe.successCount,
            failureCount: recipe.failureCount
        )
    }

    static func inferredFallbacks(for step: RecipeStep) -> [RecipeFallback] {
        let tool = step.tool
        let query = step.arguments["query"] ?? step.arguments["selector"] ?? step.arguments["name"] ?? step.arguments["recipient"] ?? step.arguments["chat"] ?? ""
        if tool == "visual_click", !query.isEmpty {
            return [RecipeFallback(tool: "aios_click", arguments: ["query": query]), RecipeFallback(tool: "background_action", arguments: ["action": "click", "query": query])]
        }
        if tool.hasPrefix("aios_background_"), !query.isEmpty {
            return [RecipeFallback(tool: "aios_find", arguments: ["query": query]), RecipeFallback(tool: "visual_ground", arguments: ["query": query])]
        }
        if tool == "browser_cdp_click", !query.isEmpty {
            return [RecipeFallback(tool: "browser_cdp_act", arguments: ["action": "click", "query": query])]
        }
        if tool == "browser_cdp_type", !query.isEmpty {
            var args = ["action": "type", "query": query]
            if let text = step.arguments["text"] { args["text"] = text }
            return [RecipeFallback(tool: "browser_cdp_act", arguments: args)]
        }
        return []
    }

    private static func generalizedGoalTemplate(_ template: String, replacements: [String: String], requiredParams: [String]) -> String {
        var output = template.trimmingCharacters(in: .whitespacesAndNewlines)
        for (literal, placeholder) in replacements {
            output = output.replacingOccurrences(of: literal, with: placeholder)
        }
        let missing = requiredParams.filter { output.contains("{{\($0)}}") == false }
        guard !missing.isEmpty else { return output }
        let suffix = missing.map { "\($0)={{\($0)}}" }.joined(separator: ", ")
        if output.isEmpty {
            return "Run reusable workflow with inputs: \(suffix)."
        }
        if output.hasSuffix(".") || output.hasSuffix("。") {
            return "\(output) Inputs: \(suffix)."
        }
        return "\(output). Inputs: \(suffix)."
    }

    private static func mergeFallbacks(_ lhs: [RecipeFallback], _ rhs: [RecipeFallback]) -> [RecipeFallback] {
        var seen = Set<String>()
        var output: [RecipeFallback] = []
        for fallback in lhs + rhs {
            let key = "\(fallback.tool)|\(jsonStringValue(fallback.arguments ?? [:]))"
            if !seen.contains(key) {
                seen.insert(key)
                output.append(fallback)
            }
        }
        return output
    }
}

struct RecipeAdaptiveRunner {
    @MainActor
    static func run(recipeID: String, params: [String: Any], eventStore: EventStore? = nil) throws -> [ToolResult] {
        let selectedID = RecipeGeneralizer.preferredRecipeID(for: recipeID)
        let recipe = RecipeGeneralizer.adaptiveRecipe(try RecipeStore.read(selectedID))
        let results = try RecipeStore.execute(recipe: recipe, params: params, eventStore: eventStore)
        if results.allSatisfy(\.success) {
            _ = try? RecipeStore.recordRunOutcome(recipeID: selectedID, runID: eventStore?.runID ?? "adaptive-\(Int(Date().timeIntervalSince1970))", success: true, notes: "adaptive runner success")
        } else if let failed = results.last(where: { !$0.success }) {
            _ = try? RecipeStore.recordRunOutcome(recipeID: selectedID, runID: eventStore?.runID ?? "adaptive-\(Int(Date().timeIntervalSince1970))", success: false, notes: failed.evidence)
            let stepID = failed.data["step_id"] ?? "unknown"
            let failedTool = failed.data["tool"] ?? "unknown"
            _ = try? RecipeAdaptationStore.recordHint(
                recipeID: selectedID,
                stepID: stepID,
                failedTool: failedTool,
                replacementTool: "visual_ground",
                arguments: [:],
                reason: failed.evidence,
                success: false
            )
        }
        return results
    }
}
