import Foundation
import XCTest
@testable import AIOS

final class SideEffectLedgerTests: XCTestCase {
    private var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aios-side-effect-tests-\(UUID().uuidString)", isDirectory: true)
        setenv("AIOS_STATE_DIR", stateDir.path, 1)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try SideEffectLedgerStore.clearAllForTesting()
    }

    override func tearDownWithError() throws {
        unsetenv("AIOS_STATE_DIR")
        if let stateDir, FileManager.default.fileExists(atPath: stateDir.path) {
            try FileManager.default.removeItem(at: stateDir)
        }
    }

    func testSubmittedExternalMessageBlocksDuplicateWithinRun() throws {
        let call = ToolCall(
            id: "send-1",
            name: "wechat_send_text",
            arguments: ["recipient": "Example Contact", "text": "hello"],
            raw: [:]
        )
        let intent = try XCTUnwrap(SideEffectLedgerStore.intent(for: call))

        XCTAssertTrue(SideEffectLedgerStore.duplicateDecision(for: intent, runID: "run-a").allowed)
        try SideEffectLedgerStore.recordSubmitted(intent: intent, runID: "run-a")

        let decision = SideEffectLedgerStore.duplicateDecision(for: intent, runID: "run-a")
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(
            SideEffectLedgerStore.duplicateDecision(for: intent, runID: "run-b").allowed,
            "Exactly-once side effect guard is per run, not a global ban."
        )
    }

    func testFailedExternalMessageCanBeRetried() throws {
        let call = ToolCall(
            id: "send-1",
            name: "wechat_send_text",
            arguments: ["recipient": "Example Contact", "text": "hello"],
            raw: [:]
        )
        let intent = try XCTUnwrap(SideEffectLedgerStore.intent(for: call))
        try SideEffectLedgerStore.recordSubmitted(intent: intent, runID: "run-a")
        try SideEffectLedgerStore.recordResult(
            intent: intent,
            runID: "run-a",
            result: ToolResult(success: false, evidence: "App was not running.", error: "not_running")
        )

        XCTAssertTrue(SideEffectLedgerStore.duplicateDecision(for: intent, runID: "run-a").allowed)
    }

    func testVerifiedFileSaveBlocksOnlyVerifiedRepeatWithinRun() throws {
        let call = ToolCall(
            id: "save-1",
            name: "textedit_save_as",
            arguments: ["path": "~/Desktop/aios.txt"],
            raw: [:]
        )
        let intent = try XCTUnwrap(SideEffectLedgerStore.intent(for: call))
        try SideEffectLedgerStore.recordSubmitted(intent: intent, runID: "run-a")

        XCTAssertTrue(SideEffectLedgerStore.duplicateDecision(for: intent, runID: "run-a").allowed)

        try SideEffectLedgerStore.recordResult(
            intent: intent,
            runID: "run-a",
            result: ToolResult(success: true, evidence: "Saved file.", data: ["verified": "true"])
        )

        XCTAssertFalse(SideEffectLedgerStore.duplicateDecision(for: intent, runID: "run-a").allowed)
    }
}
