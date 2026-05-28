import XCTest
@testable import AIOS

final class CompletionContractTests: XCTestCase {
    func testPackageAdapterMaterialEffectDoesNotSatisfyCompletionWithoutExplicitVerification() {
        var state = CompletionContractState(goal: "保存文件到 ~/Desktop/aios-risk.txt")
        let plan = TaskPlan(objective: "保存文件到 ~/Desktop/aios-risk.txt", steps: [
            TaskStep(
                id: "S1",
                title: "Save file",
                goal: "保存文件到 ~/Desktop/aios-risk.txt",
                verification: "Verify the file exists."
            )
        ])
        let call = ToolCall(
            id: "adapter-1",
            name: "app_skill_execute_adapter",
            arguments: ["path": "~/Desktop/aios-risk.txt"],
            raw: [:]
        )
        let result = ToolResult(
            success: true,
            evidence: "Adapter reported that the file was saved.",
            data: [
                "effect": "file_saved",
                "path": "~/Desktop/aios-risk.txt",
                "adapter_protocol_valid": "true"
            ]
        )

        state.record(call: call, result: result)

        XCTAssertFalse(
            state.taskCompletionGate(plan: plan).allowed,
            "Package-backed adapter effects must not satisfy material completion contracts without explicit verifier evidence."
        )
    }

    func testPackageAdapterMaterialEffectSatisfiesCompletionWithExplicitVerification() {
        var state = CompletionContractState(goal: "保存文件到 ~/Desktop/aios-risk.txt")
        let plan = TaskPlan(objective: "保存文件到 ~/Desktop/aios-risk.txt", steps: [
            TaskStep(
                id: "S1",
                title: "Save file",
                goal: "保存文件到 ~/Desktop/aios-risk.txt",
                verification: "Verify the file exists."
            )
        ])
        let call = ToolCall(
            id: "adapter-1",
            name: "app_skill_execute_adapter",
            arguments: ["path": "~/Desktop/aios-risk.txt"],
            raw: [:]
        )
        let result = ToolResult(
            success: true,
            evidence: "Adapter saved the file and a verifier confirmed it exists.",
            data: [
                "effect": "file_saved",
                "path": "~/Desktop/aios-risk.txt",
                "verified": "true",
                "adapter_protocol_valid": "true"
            ]
        )

        state.record(call: call, result: result)

        XCTAssertTrue(state.taskCompletionGate(plan: plan).allowed)
    }

    func testNativeVerifiedToolCanStillSatisfyMaterialCompletion() {
        var state = CompletionContractState(goal: "保存文件到 ~/Desktop/aios-risk.txt")
        let plan = TaskPlan(objective: "保存文件到 ~/Desktop/aios-risk.txt", steps: [
            TaskStep(
                id: "S1",
                title: "Save file",
                goal: "保存文件到 ~/Desktop/aios-risk.txt",
                verification: "Verify the file exists."
            )
        ])
        let call = ToolCall(
            id: "native-1",
            name: "textedit_save_as",
            arguments: ["path": "~/Desktop/aios-risk.txt"],
            raw: [:]
        )
        let result = ToolResult(
            success: true,
            evidence: "Saved TextEdit document.",
            data: ["path": "~/Desktop/aios-risk.txt"]
        )

        state.record(call: call, result: result)

        XCTAssertTrue(state.taskCompletionGate(plan: plan).allowed)
    }
}
