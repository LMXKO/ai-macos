import XCTest
@testable import AIOS

final class AppSkillActionResolverTests: XCTestCase {
    func testResolvesWeChatSendTextToConcreteTool() {
        let route = AppSkillRoute(
            query: "send a WeChat message",
            selectedSkill: nil,
            package: nil,
            tools: [
                "wechat_open",
                "wechat_send_text",
                "wechat_send_staged",
                "wechat_verify_chat",
                "wechat_verify_recent_message"
            ],
            selectors: [:],
            recipes: [],
            compatibility: [:],
            entrypoints: [:]
        )

        let resolved = AppSkillRuntime.resolveAction(
            route: route,
            action: "send message",
            arguments: ["recipient": "Example Contact", "text": "hello"]
        )

        XCTAssertEqual(resolved?.tool, "wechat_send_text")
        XCTAssertEqual(resolved?.arguments["recipient"] as? String, "Example Contact")
        XCTAssertEqual(resolved?.arguments["text"] as? String, "hello")
    }

    func testResolvesCalendarCreateToConcreteTool() {
        let route = AppSkillRoute(
            query: "create calendar event",
            selectedSkill: nil,
            package: nil,
            tools: ["calendar_create_event", "calendar_find_events"],
            selectors: [:],
            recipes: [],
            compatibility: [:],
            entrypoints: [:]
        )

        let resolved = AppSkillRuntime.resolveAction(
            route: route,
            action: "create",
            arguments: [
                "title": "Review",
                "start": "2026-05-28 10:00",
                "end": "2026-05-28 10:30"
            ]
        )

        XCTAssertEqual(resolved?.tool, "calendar_create_event")
        XCTAssertEqual(resolved?.arguments["title"] as? String, "Review")
        XCTAssertEqual(resolved?.arguments["start"] as? String, "2026-05-28 10:00")
        XCTAssertEqual(resolved?.arguments["end"] as? String, "2026-05-28 10:30")
    }

    func testFinderVerifyPathUsesMetadataInsteadOfTextRead() {
        let route = AppSkillRoute(
            query: "verify file exists",
            selectedSkill: nil,
            package: nil,
            tools: ["finder_file_info", "finder_read_text_file", "finder_list_directory"],
            selectors: [:],
            recipes: [],
            compatibility: [:],
            entrypoints: [:]
        )

        let resolved = AppSkillRuntime.resolveAction(
            route: route,
            action: "verify",
            arguments: ["path": "/tmp/example.pdf"]
        )

        XCTAssertEqual(resolved?.tool, "finder_file_info")
        XCTAssertEqual(resolved?.arguments["path"] as? String, "/tmp/example.pdf")
    }

    func testChromeVerifyUrlUsesCurrentTab() {
        let route = AppSkillRoute(
            query: "verify Chrome url",
            selectedSkill: nil,
            package: nil,
            tools: ["chrome_open_url", "chrome_get_current_tab", "chrome_get_page_text"],
            selectors: [:],
            recipes: [],
            compatibility: [:],
            entrypoints: [:]
        )

        let resolved = AppSkillRuntime.resolveAction(
            route: route,
            action: "verify",
            arguments: ["url": "https://example.com"]
        )

        XCTAssertEqual(resolved?.tool, "chrome_get_current_tab")
    }

    func testLarkOpenTargetSearchesChat() {
        let route = AppSkillRoute(
            query: "open Lark chat",
            selectedSkill: nil,
            package: nil,
            tools: ["lark_open", "lark_search_chat"],
            selectors: [:],
            recipes: [],
            compatibility: [:],
            entrypoints: [:]
        )

        let resolved = AppSkillRuntime.resolveAction(
            route: route,
            action: "open",
            arguments: ["chat": "Team"]
        )

        XCTAssertEqual(resolved?.tool, "lark_search_chat")
        XCTAssertEqual(resolved?.arguments["name"] as? String, "Team")
    }
}
