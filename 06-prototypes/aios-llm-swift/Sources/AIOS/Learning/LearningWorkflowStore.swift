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

    private static func find(_ id: String) -> LearnWorkflowRecord? {
        guard !id.isEmpty else { return nil }
        return readAll().first { $0.id == id }
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
