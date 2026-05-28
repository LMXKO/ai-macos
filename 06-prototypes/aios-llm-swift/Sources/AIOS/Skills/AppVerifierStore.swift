import Foundation

struct AppVerifierContract: Codable {
    let id: String
    let appName: String
    let bundleID: String
    let effect: String
    let requiredInputs: [String]
    let verifierTools: [String]
    let evidenceFields: [String]
    let fallbackChannels: [String]
    let notes: String

    var dictionary: [String: String] {
        [
            "id": id,
            "app_name": appName,
            "bundle_id": bundleID,
            "effect": effect,
            "required_inputs": requiredInputs.joined(separator: ","),
            "verifier_tools": verifierTools.joined(separator: ","),
            "evidence_fields": evidenceFields.joined(separator: ","),
            "fallback_channels": fallbackChannels.joined(separator: ","),
            "notes": notes
        ]
    }
}

struct AppVerifierStore {
    static let builtIns: [AppVerifierContract] = [
        AppVerifierContract(
            id: "wechat-message-sent",
            appName: "WeChat",
            bundleID: "com.tencent.xinWeChat",
            effect: "message_sent",
            requiredInputs: ["recipient", "text"],
            verifierTools: ["wechat_verify_chat", "wechat_verify_recent_message"],
            evidenceFields: ["verified_recipient", "verified_message", "message_probe", "ax_excerpt", "ocr_excerpt"],
            fallbackChannels: ["ax_tree", "ocr_screen", "visual_grounder_verify"],
            notes: "Completion means the intended chat is visible and the recent message text or probe is visible after send."
        ),
        AppVerifierContract(
            id: "lark-message-sent",
            appName: "Lark/Feishu",
            bundleID: "com.larksuite.Lark,com.bytedance.macos.feishu",
            effect: "message_sent",
            requiredInputs: ["chat", "text"],
            verifierTools: ["lark_verify_chat", "lark_verify_recent_message"],
            evidenceFields: ["verified_recipient", "verified_message", "message_probe", "ax_excerpt", "ocr_excerpt"],
            fallbackChannels: ["ax_tree", "ocr_screen", "visual_grounder_verify"],
            notes: "Completion means the intended chat is visible and the recent message text or probe is visible after send."
        ),
        AppVerifierContract(
            id: "qq-message-sent",
            appName: "QQ",
            bundleID: "com.tencent.qq",
            effect: "message_sent",
            requiredInputs: ["recipient", "text"],
            verifierTools: ["qq_verify_chat", "qq_verify_recent_message"],
            evidenceFields: ["verified_recipient", "verified_message", "message_probe", "ax_excerpt", "ocr_excerpt"],
            fallbackChannels: ["ax_tree", "ocr_screen", "visual_grounder_verify"],
            notes: "Completion means the intended chat is visible and the recent message text or probe is visible after send."
        ),
        AppVerifierContract(
            id: "mail-draft-created",
            appName: "Mail",
            bundleID: "com.apple.mail",
            effect: "mail_draft_created",
            requiredInputs: ["subject", "body"],
            verifierTools: ["mail_search_messages", "visual_read", "ax_describe_frontmost"],
            evidenceFields: ["subject", "body_probe", "verified", "ax_excerpt", "ocr_excerpt"],
            fallbackChannels: ["scripting_bridge", "apple_script", "ax_tree", "ocr_screen"],
            notes: "Completion means a draft exists or the compose window shows the requested recipient/subject/body."
        ),
        AppVerifierContract(
            id: "calendar-event-created",
            appName: "Calendar",
            bundleID: "com.apple.iCal",
            effect: "calendar_event_created",
            requiredInputs: ["title"],
            verifierTools: ["calendar_find_events"],
            evidenceFields: ["verified", "events", "title", "date_range"],
            fallbackChannels: ["apple_script", "scripting_bridge", "ax_tree"],
            notes: "Completion means Calendar can find the created event by title in the expected window."
        ),
        AppVerifierContract(
            id: "finder-file-created",
            appName: "Finder",
            bundleID: "com.apple.finder",
            effect: "file_created",
            requiredInputs: ["path"],
            verifierTools: ["finder_file_info"],
            evidenceFields: ["verified", "path", "kind", "size", "modified"],
            fallbackChannels: ["filesystem", "finder_reveal_file"],
            notes: "Completion means the target path exists and has file metadata."
        ),
        AppVerifierContract(
            id: "document-pdf-exported",
            appName: "WPS/Office/LibreOffice/Preview",
            bundleID: "com.kingsoft.wpsoffice.mac,org.libreoffice.script,com.apple.Preview",
            effect: "document_exported",
            requiredInputs: ["path"],
            verifierTools: ["finder_file_info", "libreoffice_export_pdf"],
            evidenceFields: ["verified", "path", "pdf", "size", "modified"],
            fallbackChannels: ["filesystem", "app_adapter", "visual_read"],
            notes: "Completion means the expected exported document exists at the output path."
        ),
        AppVerifierContract(
            id: "chrome-web-state",
            appName: "Google Chrome",
            bundleID: "com.google.Chrome",
            effect: "web_state_reached",
            requiredInputs: ["url_or_text"],
            verifierTools: ["chrome_get_current_tab", "chrome_get_page_text", "browser_cdp_wait", "browser_agent_extract"],
            evidenceFields: ["verified_current_url", "url", "title", "text_probe", "selector", "extraction"],
            fallbackChannels: ["cdp", "javascript", "browser_agent", "visual_read"],
            notes: "Completion means the target URL, selector, or page text can be observed through CDP/JS or visual fallback."
        ),
        AppVerifierContract(
            id: "safari-web-state",
            appName: "Safari",
            bundleID: "com.apple.Safari",
            effect: "web_state_reached",
            requiredInputs: ["url_or_text"],
            verifierTools: ["safari_get_current_url", "safari_get_page_text", "safari_eval_js"],
            evidenceFields: ["verified_current_url", "url", "text_probe", "selector"],
            fallbackChannels: ["apple_script", "javascript", "visual_read"],
            notes: "Completion means the target URL or page text can be observed in Safari."
        ),
        AppVerifierContract(
            id: "figma-canvas-state",
            appName: "Figma",
            bundleID: "com.figma.Desktop",
            effect: "canvas_state_reached",
            requiredInputs: ["query"],
            verifierTools: ["background_driver_dispatch", "visual_grounder_run", "visual_grounder_verify"],
            evidenceFields: ["candidate_id", "image_path", "verified", "anchors", "driver_receipt"],
            fallbackChannels: ["app_skill_adapter", "cua_driver", "visual_grounding", "screenshot_diff"],
            notes: "Completion means a verifier can observe the requested canvas object/state through adapter, CUA driver, or visual anchors."
        ),
        AppVerifierContract(
            id: "ide-path-opened",
            appName: "Xcode/JetBrains IDE",
            bundleID: "com.apple.dt.Xcode,com.jetbrains.pycharm,com.jetbrains.rustrover",
            effect: "path_opened",
            requiredInputs: ["path"],
            verifierTools: ["ax_describe_frontmost", "visual_read"],
            evidenceFields: ["verified", "path", "window_title", "ax_excerpt", "ocr_excerpt"],
            fallbackChannels: ["ax_tree", "ocr_screen", "app_adapter"],
            notes: "Completion means the front IDE window shows the target file, folder, project, or workspace."
        ),
        AppVerifierContract(
            id: "netdisk-upload-visible",
            appName: "Baidu Netdisk",
            bundleID: "com.baidu.netdisk-mac",
            effect: "file_uploaded",
            requiredInputs: ["filename"],
            verifierTools: ["visual_read", "ax_describe_frontmost", "visual_grounder_verify"],
            evidenceFields: ["verified", "filename", "upload_state", "ax_excerpt", "ocr_excerpt"],
            fallbackChannels: ["ax_tree", "ocr_screen", "visual_grounding"],
            notes: "Completion means the destination listing or upload panel visibly contains the uploaded filename and a completed/success state."
        )
    ]

    static func list(query: String = "", limit: Int = 50) -> [AppVerifierContract] {
        let normalized = normalizeForSearch(query)
        let rows = builtIns.filter { contract in
            guard !normalized.isEmpty else { return true }
            return normalizeForSearch(contract.dictionary.values.joined(separator: " ")).contains(normalized) ||
                normalized.split(separator: " ").contains { token in
                    normalizeForSearch(contract.dictionary.values.joined(separator: " ")).contains(token)
                }
        }
        return Array(rows.prefix(max(1, limit)))
    }

    static func suggest(goal: String = "", appName: String = "", bundleID: String = "", effect: String = "", limit: Int = 5) -> [String: String] {
        let query = [goal, appName, bundleID, effect].filter { !$0.isEmpty }.joined(separator: " ")
        let matches = ranked(query: query, effect: effect).prefix(max(1, limit)).map(\.contract.dictionary)
        return [
            "schema": "aios.app_verifier.suggest.v1",
            "query": query,
            "effect": effect,
            "contracts": jsonStringValue(Array(matches)),
            "selection_policy": "prefer exact bundle/effect, then app name/capability, then generic observable postcondition"
        ]
    }

    static func plan(goal: String = "", appName: String = "", bundleID: String = "", effect: String = "", target: String = "", value: String = "", path: String = "", url: String = "") -> [String: String] {
        let query = [goal, appName, bundleID, effect, target, value, path, url].filter { !$0.isEmpty }.joined(separator: " ")
        let contract = ranked(query: query, effect: effect).first?.contract
        guard let contract else {
            return [
                "schema": "aios.app_verifier.plan.v1",
                "found": "false",
                "query": query,
                "reason": "no matching app verifier contract"
            ]
        }
        return [
            "schema": "aios.app_verifier.plan.v1",
            "found": "true",
            "contract": jsonStringValue(contract.dictionary),
            "tool_sequence": jsonStringValue(toolSequence(contract: contract, target: target, value: value, path: path, url: url)),
            "pre_check_sequence": jsonStringValue(preCheckSequence(contract: contract, target: target, value: value, path: path, url: url)),
            "post_check_sequence": jsonStringValue(postCheckSequence(contract: contract, target: target, value: value, path: path, url: url)),
            "required_inputs": contract.requiredInputs.joined(separator: ","),
            "evidence_fields": contract.evidenceFields.joined(separator: ","),
            "fallback_channels": contract.fallbackChannels.joined(separator: ","),
            "completion_rule": completionRule(for: contract),
            "idempotency_key_fields": idempotencyKeyFields(for: contract).joined(separator: ","),
            "side_effect_policy": sideEffectPolicy(for: contract)
        ]
    }

    private static func ranked(query: String, effect: String) -> [(contract: AppVerifierContract, score: Int)] {
        let normalized = normalizeForSearch(query)
        let normalizedEffect = normalizeForSearch(effect)
        return builtIns.compactMap { contract in
            let haystack = normalizeForSearch(contract.dictionary.values.joined(separator: " "))
            var score = 0
            if !normalizedEffect.isEmpty && normalizeForSearch(contract.effect) == normalizedEffect { score += 18 }
            if !normalized.isEmpty && haystack.contains(normalized) { score += 12 }
            for token in normalized.split(separator: " ") where token.count >= 2 && haystack.contains(token) {
                score += 3
            }
            if score == 0 && normalized.isEmpty { score = 1 }
            return score > 0 ? (contract, score) : nil
        }.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.contract.id < rhs.contract.id }
            return lhs.score > rhs.score
        }
    }

    private static func toolSequence(contract: AppVerifierContract, target: String, value: String, path: String, url: String) -> [[String: String]] {
        switch contract.id {
        case "wechat-message-sent":
            return [
                ["tool": "wechat_verify_chat", "recipient": target],
                ["tool": "wechat_verify_recent_message", "text": value]
            ]
        case "lark-message-sent":
            return [
                ["tool": "lark_verify_chat", "chat": target],
                ["tool": "lark_verify_recent_message", "text": value]
            ]
        case "qq-message-sent":
            return [
                ["tool": "qq_verify_chat", "recipient": target],
                ["tool": "qq_verify_recent_message", "text": value]
            ]
        case "calendar-event-created":
            return [["tool": "calendar_find_events", "title": value.isEmpty ? target : value]]
        case "finder-file-created", "document-pdf-exported":
            return [["tool": "finder_file_info", "path": path.isEmpty ? value : path]]
        case "chrome-web-state":
            return [
                ["tool": "chrome_get_current_tab", "url": url],
                ["tool": "chrome_get_page_text", "text": value]
            ]
        case "safari-web-state":
            return [
                ["tool": "safari_get_current_url", "url": url],
                ["tool": "safari_get_page_text", "text": value]
            ]
        default:
            return contract.verifierTools.map { ["tool": $0, "target": target, "value": value, "path": path, "url": url] }
        }
    }

    private static func preCheckSequence(contract: AppVerifierContract, target: String, value: String, path: String, url: String) -> [[String: String]] {
        switch contract.effect {
        case "message_sent":
            let sequence = toolSequence(contract: contract, target: target, value: "", path: path, url: url)
            return sequence.isEmpty ? contract.verifierTools.prefix(1).map { ["tool": $0, "target": target] } : sequence
        case "file_created", "document_exported":
            let checkPath = path.isEmpty ? value : path
            return checkPath.isEmpty ? [] : [["tool": "finder_file_info", "path": checkPath, "purpose": "detect_existing_artifact_before_write"]]
        case "calendar_event_created":
            let title = value.isEmpty ? target : value
            return title.isEmpty ? [] : [["tool": "calendar_find_events", "title": title, "purpose": "detect_existing_event_before_create"]]
        case "web_state_reached":
            return url.isEmpty ? [] : [["tool": contract.id == "safari-web-state" ? "safari_get_current_url" : "chrome_get_current_tab", "url": url]]
        default:
            return []
        }
    }

    private static func postCheckSequence(contract: AppVerifierContract, target: String, value: String, path: String, url: String) -> [[String: String]] {
        toolSequence(contract: contract, target: target, value: value, path: path, url: url)
    }

    private static func idempotencyKeyFields(for contract: AppVerifierContract) -> [String] {
        switch contract.effect {
        case "message_sent":
            return ["app_name", "recipient_or_chat", "message_probe_or_attachment"]
        case "calendar_event_created":
            return ["calendar", "title", "start", "end"]
        case "mail_draft_created":
            return ["recipient", "subject", "body_probe"]
        case "file_created", "document_exported":
            return ["path"]
        case "web_state_reached":
            return ["browser", "url", "selector_or_text_probe"]
        default:
            return contract.requiredInputs
        }
    }

    private static func sideEffectPolicy(for contract: AppVerifierContract) -> String {
        switch contract.effect {
        case "message_sent", "calendar_event_created", "mail_draft_created", "shortcut_ran", "shell_command_submitted":
            return "exactly_once_per_run: record submitted before action; verify with post_check_sequence before completion; retry only after failed ledger status or explicit user approval"
        case "file_created", "document_exported", "file_uploaded":
            return "verified_once_per_run: retry allowed until verified; once verified, use verifier instead of repeating the write/upload"
        default:
            return "verify_before_complete"
        }
    }

    private static func completionRule(for contract: AppVerifierContract) -> String {
        switch contract.effect {
        case "message_sent":
            return "recipient/chat visible AND recent outgoing message text/probe visible"
        case "file_created", "document_exported":
            return "expected output path exists with filesystem metadata"
        case "calendar_event_created":
            return "calendar query returns the expected title/date entry"
        case "web_state_reached":
            return "current URL, selector, or page text matches the requested postcondition"
        case "canvas_state_reached":
            return "adapter/driver or visual anchors verify the requested canvas object/state"
        case "file_uploaded":
            return "destination UI or API shows filename plus completed upload state"
        default:
            return "declared verifier tools return observable success evidence"
        }
    }
}
