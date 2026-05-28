import Foundation

struct LearnWorkflowRecord: Codable {
    let id: String
    let title: String
    let goal: String
    let appName: String
    let startedAt: String
    var status: String
    var learningSessionID: String
    var recipeID: String
    var programRecipeID: String
    var verifierPlan: [String: String]
    var notes: String

    var dictionary: [String: String] {
        [
            "id": id,
            "title": title,
            "goal": goal,
            "app_name": appName,
            "started_at": startedAt,
            "status": status,
            "learning_session_id": learningSessionID,
            "recipe_id": recipeID,
            "program_recipe_id": programRecipeID,
            "verifier_plan": jsonStringValue(verifierPlan),
            "notes": notes
        ]
    }
}

struct LearnWorkflowStore {
    static var recordsURL: URL {
        EventStore.learningURL.appendingPathComponent("workflow-records.json")
    }

    static func plan(goal: String = "", appName: String = "", verifierEffect: String = "") -> [String: String] {
        let verifier = AppVerifierStore.plan(goal: goal, appName: appName, effect: verifierEffect)
        return [
            "schema": "aios.learn.workflow.plan.v1",
            "goal": goal,
            "app_name": appName,
            "phases": jsonStringValue([
                ["id": "start", "action": "learn_workflow_start", "output": "durable learning workflow + optional tool learning session"],
                ["id": "demonstrate", "action": "learn_record_tool or learn_record_events", "output": "successful tool steps or raw UI event recipe"],
                ["id": "parameterize", "action": "learn_workflow_finalize", "output": "generalized recipe program with inferred parameters"],
                ["id": "confirm", "action": "user/tool confirmation through verifier plan", "output": "ready_for_reuse true/false"],
                ["id": "reuse", "action": "recipe_program_select + recipe_execute_adaptive", "output": "future tasks use the stable program first"],
                ["id": "repair", "action": "recipe_repair_hint + recipe_stabilize_program", "output": "failed recipes learn a patch instead of being discarded"]
            ]),
            "default_verifier_plan": jsonStringValue(verifier),
            "operator_contract": "the user demonstrates once; AIOS extracts parameters, attaches verifiers, asks for confirmation, then reuses or repairs the workflow"
        ]
    }

    @discardableResult
    static func start(title: String, goal: String = "", appName: String = "", startToolSession: Bool = true, notes: String = "") throws -> LearnWorkflowRecord {
        let session = startToolSession ? try? LearningStore.start(title: title) : nil
        let record = LearnWorkflowRecord(
            id: "learnflow-\(normalizeID(title))-\(UUID().uuidString.prefix(8))",
            title: title,
            goal: goal,
            appName: appName,
            startedAt: isoDateString(Date()),
            status: "demonstrating",
            learningSessionID: session?.id ?? "",
            recipeID: "",
            programRecipeID: "",
            verifierPlan: AppVerifierStore.plan(goal: goal, appName: appName),
            notes: notes
        )
        try upsert(record)
        return record
    }

    @discardableResult
    static func finalize(
        workflowID: String = "",
        recipeID: String,
        sourceRunID: String = "",
        title: String = "",
        verifierEffect: String = "",
        verifierTarget: String = "",
        verifierValue: String = "",
        verifierPath: String = "",
        verifierURL: String = "",
        confirm: Bool = false
    ) throws -> LearnWorkflowRecord {
        let learned = try RecipeLearningEngine.learnRecipe(recipeID: recipeID, sourceRunID: sourceRunID, title: title)
        let verifier = AppVerifierStore.plan(
            goal: title,
            effect: verifierEffect,
            target: verifierTarget,
            value: verifierValue,
            path: verifierPath,
            url: verifierURL
        )
        var record = find(workflowID) ?? LearnWorkflowRecord(
            id: workflowID.isEmpty ? "learnflow-\(normalizeID(recipeID))-\(UUID().uuidString.prefix(8))" : workflowID,
            title: title.isEmpty ? recipeID : title,
            goal: title,
            appName: "",
            startedAt: isoDateString(Date()),
            status: "finalizing",
            learningSessionID: "",
            recipeID: "",
            programRecipeID: "",
            verifierPlan: [:],
            notes: ""
        )
        record.status = confirm && learned["ready_for_reuse"] == "true" ? "ready_for_reuse" : "awaiting_confirmation"
        record.recipeID = recipeID
        record.programRecipeID = learned["program_recipe_id"] ?? ""
        record.verifierPlan = verifier
        record.notes = [
            "stability=\(learned["stability_score"] ?? "")",
            "ready=\(learned["ready_for_reuse"] ?? "false")",
            confirm ? "confirmed=true" : "confirmed=false"
        ].joined(separator: ";")
        try upsert(record)
        return record
    }

    static func list(limit: Int = 20) -> [LearnWorkflowRecord] {
        Array(readAll().sorted { $0.startedAt > $1.startedAt }.prefix(max(1, limit)))
    }

    static func reusePlan(goal: String, appName: String = "", verifierEffect: String = "", limit: Int = 5) throws -> [String: String] {
        let cappedLimit = max(1, limit)
        let verifier = AppVerifierStore.plan(goal: goal, appName: appName, effect: verifierEffect)
        let workflows = list(limit: max(cappedLimit, 20))
        let matchedWorkflows = workflows
            .filter { workflowMatches($0, goal: goal, appName: appName) }
            .prefix(cappedLimit)
            .map(\.dictionary)
        let workflowConfirmation = workflows
            .filter { workflowMatches($0, goal: goal, appName: appName) }
            .filter { ["awaiting_confirmation", "ready_for_reuse"].contains($0.status) }
            .prefix(cappedLimit)
            .map(\.dictionary)
        let selected = RecipeLearningEngine.select(goal: goal, limit: cappedLimit)
        let candidates = try candidateRows(from: selected["candidates"] ?? "[]").prefix(cappedLimit)
        let learningRecords = RecipeLearningEngine.readAll()
        let enrichedCandidates = candidates.map { candidate -> [String: String] in
            let recipeID = candidate["recipe_id"] ?? ""
            let compiled = (try? RecipeProgramStore.compile(recipeID: recipeID)) ?? [:]
            let stability = (try? RecipeStabilityStore.profile(recipeID: recipeID, goal: goal, promote: false)) ?? [:]
            let record = learningRecords.first { $0.recipeID == recipeID || $0.programRecipeID == recipeID }
            let ready = candidateReady(candidate: candidate, compiled: compiled, stability: stability)
            var row = candidate
            row["compile_valid"] = compiled["valid"] ?? candidate["valid_program"] ?? "unknown"
            row["compile_issues"] = compiled["issues"] ?? ""
            row["compiled_parameters"] = compiled["parameters"] ?? ""
            row["verification_contracts"] = compiled["verification_contracts"] ?? ""
            row["stability_score"] = stability["stability_score"] ?? candidate["stability_score"] ?? record.map { String(format: "%.2f", $0.stabilityScore) } ?? ""
            row["ready_for_permanent_reuse"] = stability["ready_for_permanent_reuse"] ?? (ready ? "true" : "false")
            row["learning_record_id"] = record?.id ?? ""
            row["program_recipe_id"] = record?.programRecipeID ?? recipeID
            row["adaptive_execution_tool"] = "recipe_execute_adaptive"
            row["recommended_action"] = ready ? "reuse" : "stabilize_or_repair"
            row["recommended_call"] = ready
                ? jsonStringValue(["tool": "recipe_execute_adaptive", "arguments": ["id": record?.programRecipeID ?? recipeID, "params_json": "{}"]])
                : jsonStringValue(["tool": "recipe_stabilize_program", "arguments": ["id": record?.programRecipeID ?? recipeID, "goal": goal]])
            return row
        }
        let nextActions = nextActions(
            goal: goal,
            appName: appName,
            candidates: enrichedCandidates,
            workflows: Array(matchedWorkflows),
            confirmation: Array(workflowConfirmation),
            verifier: verifier
        )
        return [
            "schema": "aios.learn.workflow.reuse_plan.v1",
            "goal": goal,
            "app_name": appName,
            "recipe_selection": jsonStringValue(selected),
            "candidate_reuse_plans": jsonStringValue(enrichedCandidates),
            "matched_workflows": jsonStringValue(Array(matchedWorkflows)),
            "confirmation_queue": jsonStringValue(Array(workflowConfirmation)),
            "verifier_plan": jsonStringValue(verifier),
            "next_actions": jsonStringValue(nextActions),
            "primary_recommendation": nextActions.first?["action"] ?? "record_demo",
            "operator_contract": "reuse a verified program first; if unstable, stabilize or repair it; if no match, record one demonstration and finalize it into a reusable workflow"
        ]
    }

    private static func find(_ id: String) -> LearnWorkflowRecord? {
        guard !id.isEmpty else { return nil }
        return readAll().first { $0.id == id }
    }

    private static func workflowMatches(_ record: LearnWorkflowRecord, goal: String, appName: String) -> Bool {
        let needle = normalizeForSearch([goal, appName].joined(separator: " "))
        guard !needle.isEmpty else { return true }
        let haystack = normalizeForSearch([record.title, record.goal, record.appName, record.notes, record.recipeID, record.programRecipeID].joined(separator: " "))
        let tokens = needle.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        return tokens.contains { haystack.contains($0) }
    }

    private static func candidateRows(from text: String) throws -> [[String: String]] {
        let data = Data(text.utf8)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.map { row in
            row.reduce(into: [String: String]()) { partial, item in
                if let value = item.value as? String {
                    partial[item.key] = value
                } else if let number = item.value as? NSNumber {
                    partial[item.key] = number.stringValue
                }
            }
        }
    }

    private static func candidateReady(candidate: [String: String], compiled: [String: String], stability: [String: String]) -> Bool {
        if stability["ready_for_permanent_reuse"] == "true" { return true }
        let valid = (compiled["valid"] ?? candidate["valid_program"] ?? "") == "true"
        let stabilityScore = Double(stability["stability_score"] ?? candidate["stability_score"] ?? "") ?? 0
        return valid && stabilityScore >= 0.75
    }

    private static func nextActions(
        goal: String,
        appName: String,
        candidates: [[String: String]],
        workflows: [[String: String]],
        confirmation: [[String: String]],
        verifier: [String: String]
    ) -> [[String: String]] {
        if let pending = confirmation.first(where: { $0["status"] == "awaiting_confirmation" }) {
            return [
                [
                    "action": "confirm",
                    "tool": "learn_workflow_finalize",
                    "workflow_id": pending["id"] ?? "",
                    "recipe_id": pending["recipe_id"] ?? "",
                    "reason": "a matching learned workflow exists but still needs confirmation before routine reuse"
                ],
                [
                    "action": "verify",
                    "tool": verifier["tool"] ?? "app_verifier_plan",
                    "reason": "run the attached verifier plan against the demonstrated effect"
                ]
            ]
        }
        if let reusable = candidates.first, reusable["recommended_action"] == "reuse" {
            return [
                [
                    "action": "reuse",
                    "tool": "recipe_execute_adaptive",
                    "recipe_id": reusable["program_recipe_id"] ?? reusable["recipe_id"] ?? "",
                    "reason": "matching compiled recipe is stable enough for adaptive execution",
                    "call": reusable["recommended_call"] ?? ""
                ],
                [
                    "action": "verify",
                    "tool": verifier["tool"] ?? "app_verifier_plan",
                    "reason": "confirm the observable postcondition before marking complete"
                ]
            ]
        }
        if let repair = candidates.first {
            return [
                [
                    "action": "stabilize_or_repair",
                    "tool": "recipe_stabilize_program",
                    "recipe_id": repair["program_recipe_id"] ?? repair["recipe_id"] ?? "",
                    "reason": "a similar recipe exists but is not stable enough for blind reuse",
                    "call": repair["recommended_call"] ?? ""
                ],
                [
                    "action": "record_repair_hint",
                    "tool": "recipe_repair_hint",
                    "reason": "after a failed adaptive run, save the replacement step instead of discarding the workflow"
                ]
            ]
        }
        if let workflow = workflows.first {
            return [
                [
                    "action": "finalize",
                    "tool": "learn_workflow_finalize",
                    "workflow_id": workflow["id"] ?? "",
                    "recipe_id": workflow["recipe_id"] ?? "",
                    "reason": "a matching demonstration exists but has not produced a reusable program yet"
                ]
            ]
        }
        return [
            [
                "action": "record_demo",
                "tool": "learn_workflow_start",
                "reason": "no reusable recipe or learned workflow matched this goal",
                "call": jsonStringValue(["tool": "learn_workflow_start", "arguments": ["title": goal.isEmpty ? "New workflow" : goal, "goal": goal, "app_name": appName]])
            ],
            [
                "action": "finalize_after_demo",
                "tool": "learn_workflow_finalize",
                "reason": "promote the recorded recipe, attach verifier plan, then reuse on the next similar task"
            ]
        ]
    }

    private static func readAll() -> [LearnWorkflowRecord] {
        guard let data = try? Data(contentsOf: recordsURL),
              let records = try? JSONDecoder().decode([LearnWorkflowRecord].self, from: data)
        else { return [] }
        return records
    }

    private static func upsert(_ record: LearnWorkflowRecord) throws {
        try FileManager.default.createDirectory(at: EventStore.learningURL, withIntermediateDirectories: true)
        var records = readAll().filter { $0.id != record.id }
        records.append(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: recordsURL, options: [.atomic])
    }
}
