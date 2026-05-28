import XCTest
@testable import AIOS

final class AppVerifierContractTests: XCTestCase {
    func testMessageVerifierPlanIncludesIdempotencyAndPrePostChecks() {
        let plan = AppVerifierStore.plan(
            appName: "WeChat",
            effect: "message_sent",
            target: "Example Contact",
            value: "hello"
        )

        XCTAssertEqual(plan["found"], "true")
        XCTAssertTrue((plan["side_effect_policy"] ?? "").contains("exactly_once_per_run"))
        XCTAssertTrue((plan["pre_check_sequence"] ?? "").contains("wechat_verify_chat"))
        XCTAssertTrue((plan["post_check_sequence"] ?? "").contains("wechat_verify_recent_message"))
        XCTAssertTrue((plan["idempotency_key_fields"] ?? "").contains("recipient_or_chat"))
    }

    func testFileVerifierPlanUsesVerifiedOncePolicy() {
        let plan = AppVerifierStore.plan(
            appName: "Finder",
            effect: "file_created",
            path: "/private/tmp/example.txt"
        )

        XCTAssertEqual(plan["found"], "true")
        XCTAssertTrue((plan["side_effect_policy"] ?? "").contains("verified_once_per_run"))
        XCTAssertTrue((plan["pre_check_sequence"] ?? "").contains("finder_file_info"))
        XCTAssertTrue((plan["post_check_sequence"] ?? "").contains("finder_file_info"))
        XCTAssertEqual(plan["idempotency_key_fields"], "path")
    }

    func testCalendarVerifierPlanUsesFindEventsBeforeAndAfterCreate() {
        let plan = AppVerifierStore.plan(
            appName: "Calendar",
            effect: "calendar_event_created",
            target: "AIOS Review"
        )

        XCTAssertEqual(plan["found"], "true")
        XCTAssertTrue((plan["side_effect_policy"] ?? "").contains("exactly_once_per_run"))
        XCTAssertTrue((plan["pre_check_sequence"] ?? "").contains("calendar_find_events"))
        XCTAssertTrue((plan["post_check_sequence"] ?? "").contains("calendar_find_events"))
        XCTAssertTrue((plan["idempotency_key_fields"] ?? "").contains("start"))
    }
}
