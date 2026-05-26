import Foundation

struct RecipeStabilityStore {
    static func stabilize(recipeID: String, goal: String = "") throws -> [String: String] {
        let recipe = try RecipeStore.read(recipeID)
        let compiled = try RecipeProgramStore.compile(recipeID: recipeID)
        let records = RecipeLearningEngine.readAll().filter { $0.recipeID == recipeID || $0.programRecipeID == recipeID }
        let hints = RecipeAdaptationStore.hints(recipeID: recipeID).map(\.dictionary)
        let requiredParams = recipe.requiredParams
        let invariants = buildInvariants(recipe: recipe, compiled: compiled)
        let score = stabilityScore(recipe: recipe, compiled: compiled, records: records, hints: hints)
        let payload: [String: String] = [
            "schema": "aios.recipe.stability.v1",
            "recipe_id": recipeID,
            "title": recipe.title,
            "goal": goal,
            "valid_program": compiled["valid"] ?? "false",
            "stability_score": String(format: "%.2f", score),
            "ready_for_permanent_reuse": score >= 0.80 ? "true" : "false",
            "parameters": compiled["parameters"] ?? "[]",
            "required_params": requiredParams.joined(separator: ","),
            "invariants": jsonStringValue(invariants),
            "repair_hints": jsonStringValue(hints),
            "learning_records": jsonStringValue(records.map(\.dictionary)),
            "version_policy": "promote only valid programs with verification contracts, parameter references, repair hints, and outcome counters; keep prior versions as rollback candidates",
            "adaptation_policy": "resolve app state -> fill params -> check preconditions -> execute adaptive graph -> verify postconditions -> refine success/failure counters"
        ]
        if score >= 0.80 {
            _ = try? RecipeStore.recordRunOutcome(recipeID: recipeID, runID: records.first?.runID ?? "stability:\(recipeID)", success: true, notes: "recipe_stabilize_program marked permanent reuse candidate")
        }
        return payload
    }

    private static func buildInvariants(recipe: Recipe, compiled: [String: String]) -> [[String: String]] {
        var rows: [[String: String]] = []
        for condition in recipe.preconditions ?? [] {
            rows.append([
                "kind": "precondition",
                "description": condition.description,
                "tool": condition.tool,
                "expression": condition.expression ?? ""
            ])
        }
        for step in recipe.steps {
            rows.append([
                "kind": "step_contract",
                "step_id": step.id,
                "tool": step.tool,
                "verify_tool": step.verifyTool ?? "",
                "verify_expression": step.verifyExpression ?? "success",
                "fallback_count": "\((step.fallbackTools ?? []).count)"
            ])
        }
        for condition in recipe.postconditions ?? [] {
            rows.append([
                "kind": "postcondition",
                "description": condition.description,
                "tool": condition.tool,
                "expression": condition.expression ?? ""
            ])
        }
        rows.append([
            "kind": "compile",
            "entry_step": compiled["entry_step"] ?? "",
            "terminal_steps": compiled["terminal_steps"] ?? "",
            "issues": compiled["issues"] ?? ""
        ])
        return rows
    }

    private static func stabilityScore(
        recipe: Recipe,
        compiled: [String: String],
        records: [RecipeLearningRecord],
        hints: [[String: String]]
    ) -> Double {
        var score = 0.35
        if compiled["valid"] == "true" { score += 0.20 }
        if !(compiled["verification_contracts"] ?? "").isEmpty { score += 0.15 }
        if !(compiled["parameter_references"] ?? "").isEmpty { score += 0.10 }
        if !(recipe.preconditions ?? []).isEmpty { score += 0.05 }
        if !(recipe.postconditions ?? []).isEmpty { score += 0.05 }
        if !records.isEmpty { score += min(0.10, Double(records.count) * 0.04) }
        if !hints.isEmpty { score += 0.05 }
        if (recipe.successCount ?? 0) > (recipe.failureCount ?? 0) { score += 0.05 }
        return min(1.0, score)
    }
}
