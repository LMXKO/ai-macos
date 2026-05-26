import Foundation

struct RecipeProgramStore {
    static func compile(recipeID: String) throws -> [String: String] {
        let recipe = try RecipeStore.read(recipeID)
        let graph = try RecipeStore.compile(recipeID: recipeID)
        let stepIDs = Set(recipe.steps.map(\.id))
        let duplicateStepIDs = Dictionary(grouping: recipe.steps, by: \.id).filter { $0.value.count > 1 }.keys.sorted()
        let references = parameterReferences(recipe)
        var issues: [String] = []
        for id in duplicateStepIDs {
            issues.append("duplicate step id \(id)")
        }
        for param in recipe.requiredParams where recipe.goalTemplate.contains("{{\(param)}}") == false {
            issues.append("required param \(param) is not referenced in goal_template")
        }
        for param in recipe.requiredParams where references[param, default: []].isEmpty {
            issues.append("required param \(param) is not referenced by any step, condition, or goal")
        }
        for step in recipe.steps {
            if !stepIDs.contains(step.id) { issues.append("step id missing: \(step.title)") }
            if let next = step.nextOnSuccess, next.uppercased() != "END", !stepIDs.contains(next) {
                issues.append("invalid next_on_success \(next) in \(step.id)")
            }
            if let next = step.nextOnFailure, next.uppercased() != "END", !stepIDs.contains(next) {
                issues.append("invalid next_on_failure \(next) in \(step.id)")
            }
            if step.verifyTool == nil && step.verifyExpression == nil && (step.postconditions ?? []).isEmpty {
                issues.append("step \(step.id) has no verification contract")
            }
        }
        return [
            "schema": "aios.recipe.program.v1",
            "recipe_id": recipeID,
            "version": "\(recipe.version ?? 1)",
            "parameters": jsonStringValue((recipe.parameters ?? []).map { ["name": $0.name, "required": $0.required ? "true" : "false", "default": $0.defaultValue ?? "", "examples": $0.examples.joined(separator: ",")] }),
            "required_params": recipe.requiredParams.joined(separator: ","),
            "graph": jsonStringValue(graph),
            "preconditions": jsonStringValue((recipe.preconditions ?? []).map { ["description": $0.description, "tool": $0.tool, "expression": $0.expression ?? ""] }),
            "postconditions": jsonStringValue((recipe.postconditions ?? []).map { ["description": $0.description, "tool": $0.tool, "expression": $0.expression ?? ""] }),
            "entry_step": recipe.steps.first?.id ?? "",
            "terminal_steps": recipe.steps.filter { ($0.nextOnSuccess ?? "END").uppercased() == "END" }.map(\.id).joined(separator: ","),
            "verification_contracts": jsonStringValue(recipe.steps.map { ["step_id": $0.id, "verify_tool": $0.verifyTool ?? "", "verify_expression": $0.verifyExpression ?? "", "postconditions": "\(($0.postconditions ?? []).count)"] }),
            "parameter_references": jsonStringValue(references.mapValues { $0.sorted().joined(separator: ",") }),
            "issues": issues.joined(separator: "\n"),
            "valid": issues.isEmpty ? "true" : "false"
        ]
    }

    static func inferSchema(from runID: String, recipeID: String? = nil) throws -> [String: String] {
        let promoted = try RecipeStore.promoteRun(runID: runID, recipeID: recipeID)
        let generalized = try RecipeGeneralizer.generalize(recipeID: promoted.id, outputID: "\(promoted.id)-program")
        return [
            "promoted_recipe_id": promoted.id,
            "program_recipe_id": generalized.id,
            "parameters": jsonStringValue((generalized.parameters ?? []).map { ["name": $0.name, "description": $0.description, "required": $0.required ? "true" : "false", "examples": $0.examples.joined(separator: ",")] }),
            "compile": jsonStringValue(try compile(recipeID: generalized.id))
        ]
    }

    static func distillSuccess(runID: String, title: String = "") throws -> [String: String] {
        let recipe = try RecipeStore.promoteRun(runID: runID, title: title.isEmpty ? nil : title)
        let generalized = try RecipeGeneralizer.generalize(recipeID: recipe.id, outputID: "\(recipe.id)-stable")
        _ = try? RecipeStore.recordRunOutcome(recipeID: generalized.id, runID: runID, success: true, notes: "distilled successful run into stable recipe program")
        return [
            "recipe_id": generalized.id,
            "recipe": generalized.jsonString,
            "compile": jsonStringValue(try compile(recipeID: generalized.id))
        ]
    }

    private static func parameterReferences(_ recipe: Recipe) -> [String: Set<String>] {
        var references: [String: Set<String>] = [:]
        func scan(_ text: String, location: String) {
            for placeholder in placeholders(in: text) {
                references[placeholder, default: []].insert(location)
            }
        }
        scan(recipe.goalTemplate, location: "goal_template")
        for condition in recipe.preconditions ?? [] {
            scan(condition.description, location: "recipe_precondition")
            scan(condition.tool, location: "recipe_precondition")
            condition.arguments.forEach { scan($0.key, location: "recipe_precondition"); scan($0.value, location: "recipe_precondition") }
            scan(condition.expression ?? "", location: "recipe_precondition")
        }
        for condition in recipe.postconditions ?? [] {
            scan(condition.description, location: "recipe_postcondition")
            scan(condition.tool, location: "recipe_postcondition")
            condition.arguments.forEach { scan($0.key, location: "recipe_postcondition"); scan($0.value, location: "recipe_postcondition") }
            scan(condition.expression ?? "", location: "recipe_postcondition")
        }
        for step in recipe.steps {
            let location = "step:\(step.id)"
            scan(step.title, location: location)
            scan(step.tool, location: location)
            step.arguments.forEach { scan($0.key, location: location); scan($0.value, location: location) }
            scan(step.verifyTool ?? "", location: location)
            step.verifyArguments?.forEach { scan($0.key, location: location); scan($0.value, location: location) }
            scan(step.waitCondition ?? "", location: location)
            scan(step.waitValue ?? "", location: location)
            scan(step.verifyExpression ?? "", location: location)
        }
        return references
    }

    private static func placeholders(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([a-zA-Z0-9_\-]+)\}\}"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[nameRange])
        }
    }
}
