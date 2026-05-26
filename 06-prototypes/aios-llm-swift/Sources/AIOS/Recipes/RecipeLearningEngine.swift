import Foundation

struct RecipeLearningRecord: Codable {
    let id: String
    let runID: String
    let recipeID: String
    let programRecipeID: String
    let parameters: String
    let compile: String
    let stabilityScore: Double
    let createdAt: String

    var dictionary: [String: String] {
        [
            "id": id,
            "run_id": runID,
            "recipe_id": recipeID,
            "program_recipe_id": programRecipeID,
            "parameters": parameters,
            "compile": compile,
            "stability_score": String(format: "%.2f", stabilityScore),
            "created_at": createdAt
        ]
    }
}

struct RecipeLearningEngine {
    static var recordsURL: URL {
        EventStore.recipesURL.appendingPathComponent("learning-records.jsonl")
    }

    static func learnOnce(runID: String, recipeID: String? = nil, title: String = "") throws -> [String: String] {
        let inferred = try RecipeProgramStore.inferSchema(from: runID, recipeID: recipeID)
        guard let programRecipeID = inferred["program_recipe_id"], !programRecipeID.isEmpty else {
            throw RuntimeError("Recipe program inference did not return program_recipe_id.")
        }
        let compiled = try RecipeProgramStore.compile(recipeID: programRecipeID)
        let parameters = inferred["parameters"] ?? ""
        let score = stabilityScore(compile: compiled, parameters: parameters)
        let record = RecipeLearningRecord(
            id: "learn-\(runID)-\(UUID().uuidString.prefix(8))",
            runID: runID,
            recipeID: inferred["promoted_recipe_id"] ?? recipeID ?? "",
            programRecipeID: programRecipeID,
            parameters: parameters,
            compile: jsonStringValue(compiled),
            stabilityScore: score,
            createdAt: isoDateString(Date())
        )
        try append(record)
        if score >= 0.75 {
            _ = try? RecipeStore.recordRunOutcome(recipeID: programRecipeID, runID: runID, success: true, notes: "learn_once promoted stable program")
        }
        return [
            "schema": "aios.recipe.learn_once.v1",
            "record": jsonStringValue(record.dictionary),
            "program_recipe_id": programRecipeID,
            "stability_score": String(format: "%.2f", score),
            "ready_for_reuse": score >= 0.75 ? "true" : "false",
            "title": title
        ]
    }

    static func learnRecipe(recipeID: String, sourceRunID: String = "", title: String = "") throws -> [String: String] {
        let programID = recipeID.hasSuffix("-program") ? recipeID : "\(recipeID)-program"
        let generalized = try RecipeGeneralizer.generalize(recipeID: recipeID, outputID: programID)
        let compiled = try RecipeProgramStore.compile(recipeID: generalized.id)
        let parameters = compiled["parameters"] ?? ""
        let score = stabilityScore(compile: compiled, parameters: parameters)
        let record = RecipeLearningRecord(
            id: "learn-\(normalizeID(recipeID))-\(UUID().uuidString.prefix(8))",
            runID: sourceRunID.isEmpty ? "recipe:\(recipeID)" : sourceRunID,
            recipeID: recipeID,
            programRecipeID: generalized.id,
            parameters: parameters,
            compile: jsonStringValue(compiled),
            stabilityScore: score,
            createdAt: isoDateString(Date())
        )
        try append(record)
        if score >= 0.75 {
            _ = try? RecipeStore.recordRunOutcome(recipeID: generalized.id, runID: record.runID, success: true, notes: "learn_recipe promoted stable program")
        }
        return [
            "schema": "aios.recipe.learn_recipe.v1",
            "record": jsonStringValue(record.dictionary),
            "recipe_id": recipeID,
            "program_recipe_id": generalized.id,
            "stability_score": String(format: "%.2f", score),
            "ready_for_reuse": score >= 0.75 ? "true" : "false",
            "compile": jsonStringValue(compiled),
            "title": title.isEmpty ? generalized.title : title
        ]
    }

    static func select(goal: String, limit: Int = 5) -> [String: String] {
        let suggestions = (try? RecipeStore.suggest(goal: goal, limit: limit)) ?? []
        let records = readAll()
        let candidates = suggestions.map { suggestion -> [String: String] in
            let compiled = (try? RecipeProgramStore.compile(recipeID: suggestion.recipe.id)) ?? [:]
            let record = records.first { $0.programRecipeID == suggestion.recipe.id || $0.recipeID == suggestion.recipe.id }
            return [
                "recipe_id": suggestion.recipe.id,
                "title": suggestion.recipe.title,
                "score": "\(suggestion.score)",
                "matched_terms": suggestion.matchedTerms.joined(separator: ","),
                "valid_program": compiled["valid"] ?? "unknown",
                "stability_score": record.map { String(format: "%.2f", $0.stabilityScore) } ?? "",
                "required_params": suggestion.recipe.requiredParams.joined(separator: ",")
            ]
        }
        return [
            "schema": "aios.recipe.program.select.v1",
            "goal": goal,
            "candidates": jsonStringValue(candidates),
            "learning_records": jsonStringValue(records.prefix(20).map(\.dictionary))
        ]
    }

    static func readAll() -> [RecipeLearningRecord] {
        guard let text = try? String(contentsOf: recordsURL, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8), !data.isEmpty else { return nil }
            return try? JSONDecoder().decode(RecipeLearningRecord.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private static func append(_ record: RecipeLearningRecord) throws {
        try FileManager.default.createDirectory(at: recordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let line = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        if FileManager.default.fileExists(atPath: recordsURL.path) {
            let handle = try FileHandle(forWritingTo: recordsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: recordsURL, atomically: true, encoding: .utf8)
        }
    }

    private static func stabilityScore(compile: [String: String], parameters: String) -> Double {
        var score = 0.45
        if compile["valid"] == "true" { score += 0.25 }
        if !(compile["verification_contracts"] ?? "").isEmpty { score += 0.10 }
        if !(compile["parameter_references"] ?? "").isEmpty { score += 0.10 }
        if parameters.contains("name") || parameters.contains("path") || parameters.contains("query") || parameters.contains("title") { score += 0.05 }
        if (compile["issues"] ?? "").isEmpty { score += 0.05 }
        return min(1.0, score)
    }
}
