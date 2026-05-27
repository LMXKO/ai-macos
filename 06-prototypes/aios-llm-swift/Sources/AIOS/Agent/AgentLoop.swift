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
        if let harness = try? AgentHarnessStore.plan(goal: goal) {
            emitEvent("AgentHarnessPlan", [
                "harness_id": harness["id"] ?? "",
                "route": harness["route"] ?? "",
                "background_plan": harness["background_plan"] ?? ""
            ])
        }
        captureShadow(goal: goal, trigger: "start")

        let checkpoint = eventStore?.loadCheckpoint()
        let resumed = checkpoint?.finished == false && checkpoint?.goal == goal
        let initialPlan: TaskPlan
        let checkpointRound: Int
        let checkpointExecutedActionCount: Int
        let checkpointVerificationState: CompletionContractState?
        let checkpointExternalSends: Set<String>

        if let checkpoint, resumed {
            initialPlan = checkpoint.plan
            checkpointRound = checkpoint.round
            checkpointExecutedActionCount = checkpoint.executedActionCount
            checkpointVerificationState = checkpoint.verificationState
            checkpointExternalSends = Set(checkpoint.submittedExternalSends)
            emitEvent("RunResumed", [
                "checkpoint_updated_at": checkpoint.updatedAt,
                "round": "\(checkpoint.round)"
            ])
        } else {
            let planResponse = try await client.complete(
                messages: [
                    ["role": "system", "content": Self.planningPrompt],
                    ["role": "user", "content": goal]
                ],
                tools: orchestrationDefinitions
            )
            initialPlan = taskPlan(from: planResponse, fallbackGoal: goal)
            checkpointRound = 0
            checkpointExecutedActionCount = 0
            checkpointVerificationState = nil
            checkpointExternalSends = []
            emitEvent("TaskPlan", [
                "objective": initialPlan.objective,
                "steps": initialPlan.summaryForPrompt()
            ])
        }

        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.executionPrompt],
            ["role": "user", "content": executionUserPrompt(goal: goal, plan: initialPlan) + (resumed ? "\n\nResumeFromCheckpoint:\nContinue from the pending or failed step. Do not redo completed steps unless verification requires it." : "")]
        ]

        let knownTools = Set(tools.definitions.compactMap(toolName))
        var finished = false
        var paused = false
        var plan = initialPlan
        var round = checkpointRound
        var executedActionCount = checkpointExecutedActionCount
        var verificationState = checkpointVerificationState ?? CompletionContractState(goal: goal, plan: plan)
        var submittedExternalSends = checkpointExternalSends
        var handledCockpitCommandIDs = Set(eventStore.map { CockpitControlStore.list(runID: $0.runID).map(\.id) } ?? [])
        saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)

        while round < config.maxSteps, !finished {
            handleCockpitCommands(
                handledIDs: &handledCockpitCommandIDs,
                messages: &messages,
                goal: goal,
                plan: &plan,
                currentStepIndex: nil,
                round: round,
                executedActionCount: executedActionCount,
                submittedExternalSends: submittedExternalSends,
                verificationState: verificationState,
                paused: &paused,
                finished: &finished
            )
            if paused || finished {
                break
            }
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
            if let tick = try? AgentHarnessStore.tick(goal: goal, currentRole: "executor", evidence: "step \(currentStep.id): \(currentStep.title)") {
                emitEvent("AgentHarnessTick", [
                    "current_role": tick["current_role"] ?? "",
                    "next_role": tick["next_role"] ?? "",
                    "handoff": tick["handoff"] ?? ""
                ])
            }

            messages.append([
                "role": "user",
                "content": stepPrompt(step: currentStep, plan: plan)
            ])

            handleCockpitCommands(
                handledIDs: &handledCockpitCommandIDs,
                messages: &messages,
                goal: goal,
                plan: &plan,
                currentStepIndex: stepIndex,
                round: round,
                executedActionCount: executedActionCount,
                submittedExternalSends: submittedExternalSends,
                verificationState: verificationState,
                paused: &paused,
                finished: &finished
            )
            if paused || finished {
                break
            }

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
                saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
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
                saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
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

                if call.name == "runtime_pause" {
                    let pause = handleRuntimePause(
                        call,
                        goal: goal,
                        plan: &plan,
                        currentStepIndex: stepIndex,
                        round: round,
                        executedActionCount: executedActionCount,
                        submittedExternalSends: submittedExternalSends,
                        verificationState: verificationState
                    )
                    paused = true
                    sawStepTerminalSignal = true
                    messages.append(toolMessage(call: call, result: pause))
                    break
                }

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
                    saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: finished)
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
                    saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
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
                        saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
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
                let learnedMemory = MemoryStore.rememberToolResult(call: call, result: result, runID: eventStore?.runID)
                if !learnedMemory.isEmpty {
                    emitEvent("MemoryRemembered", [
                        "tool": call.name,
                        "entries": "\(learnedMemory.count)"
                    ])
                }
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
                if let runID = eventStore?.runID,
                   let evidence = try? TrajectoryEvidenceStore.capture(runID: runID, stepID: currentStep.id, call: call, result: result) {
                    emitEvent("TrajectoryEvidence", evidence)
                }

                if !result.success {
                    plan.steps[stepIndex].status = .failed
                    emitEvent("Recovery", [
                        "step_id": currentStep.id,
                        "reason": result.error ?? result.evidence,
                        "suggestion": result.suggestion ?? ""
                    ])
                }
                saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
                handleCockpitCommands(
                    handledIDs: &handledCockpitCommandIDs,
                    messages: &messages,
                    goal: goal,
                    plan: &plan,
                    currentStepIndex: stepIndex,
                    round: round,
                    executedActionCount: executedActionCount,
                    submittedExternalSends: submittedExternalSends,
                    verificationState: verificationState,
                    paused: &paused,
                    finished: &finished
                )
                if paused || finished {
                    break
                }
            }

            if finished {
                break
            }

            if paused {
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
                saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
            }

            if plan.steps[stepIndex].status == .failed, plan.steps[stepIndex].attempts < 3 {
                plan.steps[stepIndex].status = .pending
                messages.append(["role": "user", "content": recoveryPrompt(step: plan.steps[stepIndex])])
                saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
            }
        }

        if plan.isComplete, !finished {
            finished = try await requestFinalDelivery(messages: &messages, plan: plan, knownTools: knownTools, verificationState: verificationState)
        }

        if paused {
            emitEvent("Delivery", [
                "objective": plan.objective,
                "status": "paused",
                "plan": plan.summaryForPrompt()
            ])
            recordEpisode(goal: goal, plan: plan, outcome: "paused")
            captureShadow(goal: goal, trigger: "paused")
            print("\nPaused and scheduled for resume.")
            return false
        } else if finished {
            emitEvent("Delivery", [
                "objective": plan.objective,
                "status": "complete"
            ])
            saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: true)
            rememberTaskOutcome(goal: goal, plan: plan)
            captureShadow(goal: goal, trigger: "complete")
            eventStore?.clearCheckpoint()
            print("\nDone.")
            return true
        } else {
            emitEvent("Delivery", [
                "objective": plan.objective,
                "status": "incomplete",
                "plan": plan.summaryForPrompt()
            ])
            recordEpisode(goal: goal, plan: plan, outcome: "incomplete")
            captureShadow(goal: goal, trigger: "incomplete")
            saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
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
            ], required: ["reason", "steps"]),
            tool("runtime_pause", "Pause a long-running task, persist checkpoint, and optionally schedule the same run to resume later.", [
                "reason": schema("string", "Why the task should pause."),
                "resume_after_seconds": schema("number", "Optional seconds before requeueing the same run."),
                "resume_at": schema("string", "Optional ISO-8601 timestamp to requeue the same run.")
            ], required: ["reason"])
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

    private func handleRuntimePause(
        _ call: ToolCall,
        goal: String,
        plan: inout TaskPlan,
        currentStepIndex: Int,
        round: Int,
        executedActionCount: Int,
        submittedExternalSends: Set<String>,
        verificationState: CompletionContractState
    ) -> ToolResult {
        let reason = string(call.arguments["reason"]) ?? "Paused by runtime request."
        if plan.steps.indices.contains(currentStepIndex), plan.steps[currentStepIndex].status == .running {
            plan.steps[currentStepIndex].status = .pending
            plan.steps[currentStepIndex].evidence.append("Paused: \(reason)")
        }
        let resumeAt: String? = {
            if let text = string(call.arguments["resume_at"]), !text.isEmpty {
                return text
            }
            if let seconds = double(call.arguments["resume_after_seconds"]), seconds > 0 {
                return isoDateString(Date().addingTimeInterval(seconds))
            }
            return nil
        }()
        saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
        if let eventStore {
            try? eventStore.append("RunPaused", [
                "reason": reason,
                "resume_at": resumeAt ?? ""
            ])
            try? eventStore.updateStatus(resumeAt == nil ? "paused" : "scheduled")
            if let resumeAt {
                try? TaskQueue.submitExisting(runID: eventStore.runID, goal: goal, notBefore: resumeAt)
            }
        }
        return ToolResult(success: true, evidence: resumeAt == nil ? "Paused task: \(reason)" : "Paused task until \(resumeAt ?? ""): \(reason)", data: [
            "runtime_state": resumeAt == nil ? "paused" : "scheduled",
            "resume_at": resumeAt ?? "",
            "reason": reason
        ])
    }

    private func handleCockpitCommands(
        handledIDs: inout Set<String>,
        messages: inout [[String: Any]],
        goal: String,
        plan: inout TaskPlan,
        currentStepIndex: Int?,
        round: Int,
        executedActionCount: Int,
        submittedExternalSends: Set<String>,
        verificationState: CompletionContractState,
        paused: inout Bool,
        finished: inout Bool
    ) {
        guard let eventStore else { return }
        let commands = CockpitControlStore.list(runID: eventStore.runID)
            .reversed()
            .filter { !handledIDs.contains($0.id) }
        guard !commands.isEmpty else { return }

        for command in commands {
            handledIDs.insert(command.id)
            emitEvent("CockpitCommandObserved", [
                "command_id": command.id,
                "command": command.command,
                "feedback": command.feedback
            ])
            switch command.command {
            case "pause":
                markStepPaused(plan: &plan, currentStepIndex: currentStepIndex, reason: "Cockpit pause")
                saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
                try? eventStore.updateStatus("paused")
                try? eventStore.append("RunPaused", ["reason": "Cockpit pause"])
                captureShadow(goal: goal, trigger: "cockpit_pause")
                paused = true
                return
            case "stop", "cancel":
                markStepPaused(plan: &plan, currentStepIndex: currentStepIndex, reason: "Cockpit stop")
                saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
                try? eventStore.updateStatus("canceled")
                try? eventStore.append("RunCanceled", ["reason": "Cockpit stop"])
                captureShadow(goal: goal, trigger: "cockpit_stop")
                paused = true
                return
            case "feedback":
                let feedback = command.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !feedback.isEmpty else { continue }
                messages.append(["role": "user", "content": "HumanFeedback:\n\(feedback)\nUse this feedback in the next action and acknowledge it with concrete tool evidence."])
                try? eventStore.append("UserFeedbackApplied", ["feedback": feedback, "command_id": command.id])
                captureShadow(goal: goal, trigger: "cockpit_feedback")
            case "replan":
                let feedback = command.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
                if let currentStepIndex, plan.steps.indices.contains(currentStepIndex), plan.steps[currentStepIndex].status == .running {
                    plan.steps[currentStepIndex].status = .pending
                    plan.steps[currentStepIndex].evidence.append("Cockpit replan requested: \(feedback)")
                }
                messages.append(["role": "user", "content": "HumanReplanRequest:\n\(feedback.isEmpty ? goal : feedback)\nCall plan_update if the plan should change, then continue with concrete app/observation tools."])
                saveCheckpoint(goal: goal, plan: plan, round: round, executedActionCount: executedActionCount, submittedExternalSends: submittedExternalSends, verificationState: verificationState, finished: false)
                try? eventStore.append("UserReplanApplied", ["feedback": feedback, "command_id": command.id])
                captureShadow(goal: goal, trigger: "cockpit_replan")
            case "branch":
                let feedback = command.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
                messages.append(["role": "user", "content": "HumanBranchHint:\n\(feedback)\nIf continuing this run is still correct, continue; otherwise preserve evidence for a branch run."])
                try? eventStore.append("UserBranchHintApplied", ["feedback": feedback, "command_id": command.id])
            case "resume", "continue":
                try? eventStore.updateStatus("running")
                messages.append(["role": "user", "content": "CockpitResume:\nContinue from the checkpoint/current step. Do not redo completed delivery unless verification requires it."])
                try? eventStore.append("RunResumeApplied", ["command_id": command.id])
            default:
                let feedback = command.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
                messages.append(["role": "user", "content": "CockpitCommand \(command.command):\n\(feedback)"])
            }
        }
    }

    private func markStepPaused(plan: inout TaskPlan, currentStepIndex: Int?, reason: String) {
        guard let currentStepIndex,
              plan.steps.indices.contains(currentStepIndex),
              plan.steps[currentStepIndex].status == .running
        else { return }
        plan.steps[currentStepIndex].status = .pending
        plan.steps[currentStepIndex].evidence.append(reason)
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

    private func saveCheckpoint(
        goal: String,
        plan: TaskPlan,
        round: Int,
        executedActionCount: Int,
        submittedExternalSends: Set<String>,
        verificationState: CompletionContractState,
        finished: Bool
    ) {
        guard let eventStore else { return }
        let checkpoint = AgentCheckpoint(
            goal: goal,
            plan: plan,
            round: round,
            executedActionCount: executedActionCount,
            submittedExternalSends: Array(submittedExternalSends),
            verificationState: verificationState,
            finished: finished
        )
        do {
            try eventStore.saveCheckpoint(checkpoint)
        } catch {
            emitEvent("CheckpointError", ["error": error.localizedDescription])
        }
    }

    private func rememberTaskOutcome(goal: String, plan: TaskPlan) {
        recordEpisode(goal: goal, plan: plan, outcome: plan.isComplete ? "complete" : "finished")
        guard let entry = try? MemoryStore.remember(
            kind: "task_outcome",
            scope: "goal",
            app: "",
            key: goal,
            value: "Completed verified task with \(plan.steps.count) step(s).",
            confidence: 0.7,
            sourceRunID: eventStore?.runID,
            sourceTool: "agent_loop"
        ) else {
            return
        }
        emitEvent("MemoryRemembered", [
            "kind": entry.kind,
            "key": entry.key
        ])
    }

    private func recordEpisode(goal: String, plan: TaskPlan, outcome: String) {
        guard let eventStore,
              let eventsText = try? EventStore.readEventsText(runID: eventStore.runID)
        else { return }
        let episode = EpisodeStore.record(
            runID: eventStore.runID,
            goal: goal,
            plan: plan,
            outcome: outcome,
            eventsText: eventsText
        )
        emitEvent("EpisodeRecorded", [
            "episode_id": episode.id,
            "tools": episode.tools.joined(separator: ",")
        ])
    }

    private func captureShadow(goal: String, trigger: String) {
        guard let eventStore,
              let capture = try? ShadowMemoryStore.capture(runID: eventStore.runID, goal: goal, trigger: trigger, limit: 20)
        else { return }
        emitEvent("ShadowMemoryCaptured", [
            "shadow_id": capture["id"] ?? "",
            "trigger": trigger
        ])
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
        let memoryHint = MemoryStore.contextText(for: goal, limit: 6)
        let episodeHint = EpisodeStore.recall(query: goal, limit: 3)
            .map { "- \($0.outcome) \($0.goal) tools=\($0.tools.prefix(5).joined(separator: ","))" }
            .joined(separator: "\n")
        let contextPack = MemoryIndexStore.contextPack(query: goal, limit: 5)
        let shadowDigest = EpisodeContextEngine.shadowDigest(limit: 8)
        let strategyHint = ComputerUseStrategy.suggest(goal: goal)
        return """
        UserGoal:
        \(goal)

        TaskPlan:
        \(plan.summaryForPrompt())

        RecipeSuggestions:
        \(recipeHint)

        MemoryContext:
        \(memoryHint)

        EpisodeContext:
        \(episodeHint.isEmpty ? "No relevant prior episodes yet." : episodeHint)

        SemanticContextPack:
        \(jsonStringValue(contextPack))

        ShadowMemoryDigest:
        \(jsonStringValue(shadowDigest))

        ComputerUseStrategy:
        \(jsonStringValue(strategyHint))

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
    Use MemoryContext, SemanticContextPack, memory_recall, memory_semantic_recall, and memory_context_pack for stable user/app/workflow facts and prior episodes that may help the current task. Use memory_remember only for reusable, non-sensitive preferences or automation hints; never store passwords, tokens, keys, payment data, or private secrets.
    Use computer_use_strategy, computer_use_model_stack, long_agent_capability_matrix, tool_service_catalog, memory_profile, app_skill_suggest, app_verifier_plan, background_native_kernel, background_driver_probe, background_driver_capsule, and background_capabilities when the route is unclear. For browser/web app tasks, prefer browser_agent_contract, browser_agent_plan, browser_agent_observe, browser_agent_act, browser_agent_extract, browser_agent_wait, and CDP tools when an endpoint is available; they can control tabs without cursor/focus and keep selector/observation cache. For apps without a dedicated adapter, use universal macOS tools in this order: app discovery/open files/URLs, background_native_kernel/background_driver_dispatch/background_action or direct CDP/app scripting, app_skill_route/app_skill_execute_adapter, background locator tools, foreground locator tools, visual_grounder_run/visual_ground/visual_analyze, menu/keyboard actions, and raw coordinates last.
    Before acting inside an app, call aios_automation_context or an app-specific observation tool to orient. Prefer aios_find, aios_inspect, aios_read, aios_background_click, aios_background_type, aios_click, aios_type, and aios_wait over coordinate tools. For long-running tasks, try the background tools first because they use AXPress/AXValue only and avoid stealing focus. Keep restore_focus=true unless the task explicitly needs the target app left focused.
    For visual/canvas/icon-heavy interfaces, call visual_grounder_model_registry, visual_grounder_policy, visual_grounder_run, visual_ground, or visual_analyze before visual_click; verify reusable candidates with visual_grounder_verify, and record visual_grounder_feedback when a candidate succeeds or fails.
    For repeatable workflows, call recipe_program_select/recipe_learn_once/recipe_stabilize_program or learn_workflow_plan/learn_workflow_finalize so successful demonstrations become durable workflow programs.
    For work that must wait on time or external state, use resident_agent_plan, routine_create, long_task_trigger_create, long_task_watch, or runtime_pause with a resume time instead of busy-waiting through many steps. Use shadow_episode_policy and memory_shadow_capture at long pauses and completions.

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
