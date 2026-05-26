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

enum TaskStepStatus: String, Codable {
    case pending
    case running
    case done
    case failed
}

struct TaskStep: Codable {
    var id: String
    var title: String
    var goal: String
    var verification: String
    var deliverable: String
    var status: TaskStepStatus
    var attempts: Int
    var evidence: [String]

    init(
        id: String,
        title: String,
        goal: String,
        verification: String,
        deliverable: String = "",
        status: TaskStepStatus = .pending,
        attempts: Int = 0,
        evidence: [String] = []
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.verification = verification
        self.deliverable = deliverable
        self.status = status
        self.attempts = attempts
        self.evidence = evidence
    }
}

struct TaskPlan: Codable {
    var objective: String
    var steps: [TaskStep]

    var isComplete: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.status == .done }
    }

    static func from(arguments: [String: Any], fallbackGoal: String) -> TaskPlan {
        let objective = string(arguments["objective"]) ?? fallbackGoal
        let rawSteps = arguments["steps"] as? [[String: Any]] ?? []
        let steps = rawSteps.enumerated().map { index, raw -> TaskStep in
            TaskStep(
                id: string(raw["id"]) ?? "S\(index + 1)",
                title: string(raw["title"]) ?? "Step \(index + 1)",
                goal: string(raw["goal"]) ?? string(raw["action"]) ?? "",
                verification: string(raw["verification"]) ?? "Verify this step with tool evidence.",
                deliverable: string(raw["deliverable"]) ?? ""
            )
        }.filter { !$0.title.isEmpty || !$0.goal.isEmpty }

        if steps.isEmpty {
            return fallback(goal: fallbackGoal)
        }
        return TaskPlan(objective: objective, steps: steps)
    }

    static func fallback(goal: String) -> TaskPlan {
        TaskPlan(objective: goal, steps: [
            TaskStep(
                id: "S1",
                title: "Understand and prepare",
                goal: "Clarify the user goal, inspect relevant macOS/app context, and choose the safest tool path.",
                verification: "The available app/context evidence is captured."
            ),
            TaskStep(
                id: "S2",
                title: "Execute the work",
                goal: "Use app-specific or universal tools to complete the requested work.",
                verification: "Tool evidence shows the requested work was performed."
            ),
            TaskStep(
                id: "S3",
                title: "Verify and deliver",
                goal: "Observe the final state, verify success, and deliver the result.",
                verification: "The final result is verified and summarized."
            )
        ])
    }

    mutating func appendSteps(from arguments: [String: Any]) -> [TaskStep] {
        let rawSteps = arguments["steps"] as? [[String: Any]] ?? []
        var added: [TaskStep] = []
        for raw in rawSteps {
            let nextIndex = steps.count + added.count + 1
            let step = TaskStep(
                id: string(raw["id"]) ?? "S\(nextIndex)",
                title: string(raw["title"]) ?? "Step \(nextIndex)",
                goal: string(raw["goal"]) ?? string(raw["action"]) ?? "",
                verification: string(raw["verification"]) ?? "Verify this step with tool evidence.",
                deliverable: string(raw["deliverable"]) ?? ""
            )
            added.append(step)
        }
        steps.append(contentsOf: added)
        return added
    }

    func summaryForPrompt() -> String {
        steps.map { step in
            "- \(step.id) [\(step.status.rawValue)] \(step.title): \(step.goal) | verify: \(step.verification)"
        }.joined(separator: "\n")
    }
}

func stepContractText(_ step: TaskStep) -> String {
    "\(step.title)\n\(step.goal)\n\(step.verification)\n\(step.deliverable)"
}

struct CompletionContract: Hashable, Codable {
    let kind: String
    let app: String
    let target: String
    let value: String
    let source: String

    static func == (lhs: CompletionContract, rhs: CompletionContract) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.app == rhs.app &&
        lhs.target == rhs.target &&
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(app)
        hasher.combine(target)
        hasher.combine(value)
    }

    var summary: String {
        let qualifiers = [app, target, value]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " / ")
        return qualifiers.isEmpty ? kind : "\(kind)(\(qualifiers))"
    }
}

struct CompletionEvidence: Hashable, Codable {
    let kind: String
    let app: String
    let target: String
    let value: String
    let tool: String
    let evidence: String
    let verified: Bool

    var summary: String {
        let qualifiers = [app, target, value]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " / ")
        return qualifiers.isEmpty ? "\(kind) via \(tool)" : "\(kind)(\(qualifiers)) via \(tool)"
    }

    func contains(_ probe: String) -> Bool {
        let trimmed = probe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystack = [kind, app, target, value, tool, evidence].joined(separator: "\n").lowercased()
        let needle = trimmed.lowercased()
        return haystack.contains(needle) || needle.contains(haystack)
    }
}

struct CompletionContractState: Codable {
    let goal: String
    var requiredContracts: [CompletionContract]
    var verifiedEffects: [CompletionEvidence] = []
    var attemptedEffects: [CompletionEvidence] = []
    var chatSendAttempted = false
    var chatRecipientVerified = false
    var chatMessageVerified = false
    var chatSendToolVerified = false
    var lastRecipient = ""
    var lastMessage = ""
    var lastChatApp = ""

    init(goal: String, plan: TaskPlan? = nil) {
        self.goal = goal
        self.requiredContracts = Self.inferContracts(from: goal, source: "UserGoal")
        if let plan {
            updateRequired(from: plan)
        }
    }

    var chatDeliveryVerified: Bool {
        if verifiedEffects.contains(where: { $0.verified && $0.kind == "external_message_sent" }) {
            return true
        }
        if chatSendToolVerified { return true }
        return chatSendAttempted && chatRecipientVerified && chatMessageVerified
    }

    mutating func updateRequired(from plan: TaskPlan) {
        let objectiveContracts = Self.inferContracts(from: plan.objective, source: "TaskPlan")
        addRequired(objectiveContracts)
        let hasPrimaryObjective = (requiredContracts + objectiveContracts).contains { Self.isPrimaryOutcomeKind($0.kind) }
        for step in plan.steps {
            let text = stepContractText(step)
            let stepContracts = Self.inferContracts(from: text, source: step.id).filter { contract in
                Self.shouldAddStepContractToTask(contract, text: text, hasPrimaryObjective: hasPrimaryObjective)
            }
            addRequired(stepContracts)
        }
    }

    mutating func record(call: ToolCall, result: ToolResult) {
        if let recipient = string(call.arguments["recipient"]) ?? string(call.arguments["chat"]) ?? string(call.arguments["name"]) {
            lastRecipient = recipient
        }
        if let text = string(call.arguments["text"]) {
            lastMessage = text
        }
        if let rawPath = string(call.arguments["path"]) {
            let path = rawPath.expandingTildeInPath
            if call.name.contains("stage_file") {
                lastMessage = URL(fileURLWithPath: path).lastPathComponent
            }
        }
        if let app = Self.chatApp(for: call.name) {
            lastChatApp = app
        }

        if let effect = Self.effectEvidence(call: call, result: result) {
            attemptedEffects.append(effect)
            if effect.verified {
                addVerified(effect)
            }
        }

        switch call.name {
        case "wechat_open_chat", "lark_open_chat", "qq_open_chat":
            if result.success {
                chatRecipientVerified = true
            }
        case "wechat_send_text", "lark_send_text", "qq_send_text", "wechat_send_staged", "lark_send_staged", "qq_send_staged":
            chatSendAttempted = true
            if result.data["verified_recipient"] == "true" {
                chatRecipientVerified = true
            }
            if result.data["verified_message"] == "true" {
                chatMessageVerified = true
            }
            if result.success && result.data["verified_recipient"] == "true" && result.data["verified_message"] == "true" {
                chatSendToolVerified = true
            }
        case "wechat_verify_chat", "lark_verify_chat", "qq_verify_chat":
            if result.success {
                chatRecipientVerified = true
            }
        case "wechat_verify_recent_message", "lark_verify_recent_message", "qq_verify_recent_message":
            if result.success {
                chatMessageVerified = true
            }
        case "ui_keyboard_shortcut":
            let key = (string(call.arguments["key"]) ?? "").lowercased()
            if result.success,
               ["return", "enter"].contains(key),
               !lastChatApp.isEmpty,
               !lastRecipient.isEmpty {
                chatSendAttempted = true
            }
        case "ocr_image", "ocr_screen", "observe_snapshot", "ax_describe_frontmost":
            if chatSendAttempted,
               !lastMessage.isEmpty,
               Self.observationContainsSentMessage(result, message: lastMessage) {
                chatMessageVerified = true
            }
        default:
            break
        }

        if chatDeliveryVerified {
            addVerified(CompletionEvidence(
                kind: "external_message_sent",
                app: lastChatApp,
                target: lastRecipient,
                value: lastMessage,
                tool: call.name,
                evidence: result.evidence,
                verified: true
            ))
        }
    }

    func taskCompletionGate(plan: TaskPlan) -> PolicyDecision {
        let required = effectiveRequiredContracts(plan: plan)
        guard !required.isEmpty else {
            return PolicyDecision(allowed: true, reason: "No material completion contract required.")
        }
        let unresolved = required.filter { !isSatisfied($0) }
        guard unresolved.isEmpty else {
            return PolicyDecision(
                allowed: false,
                reason: "Completion contract not verified: \(unresolved.prefix(3).map(\.summary).joined(separator: ", ")). Open/search/click evidence is not enough."
            )
        }
        return PolicyDecision(allowed: true, reason: "Completion contracts verified: \(required.map(\.summary).joined(separator: ", ")).")
    }

    func stepCompletionGate(step: TaskStep) -> PolicyDecision {
        let text = stepContractText(step)
        let required = Self.inferContracts(from: text, source: step.id).filter { contract in
            Self.shouldEnforceStepContract(contract, text: text)
        }
        guard !required.isEmpty else {
            return PolicyDecision(allowed: true, reason: "No material step contract required.")
        }
        let unresolved = required.filter { !isSatisfied($0) }
        guard unresolved.isEmpty else {
            return PolicyDecision(
                allowed: false,
                reason: "Step contract not verified: \(unresolved.prefix(3).map(\.summary).joined(separator: ", "))."
            )
        }
        return PolicyDecision(allowed: true, reason: "Step contract verified.")
    }

    func completionGate(plan: TaskPlan, currentStep: TaskStep) -> PolicyDecision {
        taskCompletionGate(plan: plan)
    }

    private mutating func addRequired(_ contracts: [CompletionContract]) {
        for contract in contracts where !requiredContracts.contains(contract) {
            requiredContracts.append(contract)
        }
    }

    private mutating func addVerified(_ evidence: CompletionEvidence) {
        guard !verifiedEffects.contains(where: { existing in
            existing.kind == evidence.kind &&
            existing.app == evidence.app &&
            existing.target == evidence.target &&
            existing.value == evidence.value &&
            existing.tool == evidence.tool
        }) else {
            return
        }
        verifiedEffects.append(evidence)
    }

    private func effectiveRequiredContracts(plan: TaskPlan) -> [CompletionContract] {
        var contracts = requiredContracts
        let objectiveContracts = Self.inferContracts(from: plan.objective, source: "TaskPlan")
        for contract in objectiveContracts {
            if !contracts.contains(contract) { contracts.append(contract) }
        }
        let hasPrimaryObjective = contracts.contains { Self.isPrimaryOutcomeKind($0.kind) }
        for step in plan.steps {
            let text = stepContractText(step)
            let stepContracts = Self.inferContracts(from: text, source: step.id).filter { contract in
                Self.shouldAddStepContractToTask(contract, text: text, hasPrimaryObjective: hasPrimaryObjective)
            }
            for contract in stepContracts {
                if !contracts.contains(contract) { contracts.append(contract) }
            }
        }
        return contracts
    }

    private func isSatisfied(_ contract: CompletionContract) -> Bool {
        verifiedEffects.contains { evidence in
            evidence.verified &&
            Self.evidenceKind(evidence.kind, satisfies: contract.kind) &&
            (contract.app.isEmpty || evidence.contains(contract.app)) &&
            (contract.target.isEmpty || evidence.contains(contract.target)) &&
            (contract.value.isEmpty || evidence.contains(contract.value))
        }
    }

    private static func inferContracts(from text: String, source: String) -> [CompletionContract] {
        let lowered = text.lowercased()
        var contracts: [CompletionContract] = []
        func has(_ terms: [String]) -> Bool {
            terms.contains { lowered.contains($0.lowercased()) }
        }
        func add(_ kind: String, app: String = "", target: String = "", value: String = "") {
            let contract = CompletionContract(kind: kind, app: app, target: target, value: value, source: source)
            if !contracts.contains(contract) {
                contracts.append(contract)
            }
        }

        let hasConversationalIntent = has(["聊天", "持续聊天", "对话", "聊一聊", "开头", "开场", "作为开头", "以此开头", "chat", "conversation", "talk"])
        let hasSendIntent = has(["发送", "发给", "发消息", "发晚安", "同步给", "通知", "告诉", "转发给", "分享给", "send", "message", "share with", "notify"]) || hasConversationalIntent
        let hasChatContext = has(["微信", "wechat", "飞书", "lark", "qq", "给", "同步给", "通知", "告诉", "分享给"]) || hasConversationalIntent
        if hasSendIntent && hasChatContext {
            add("external_message_sent", app: inferredChatApp(from: lowered))
        }

        if has(["导出pdf", "导出 pdf", "export pdf", "pdf"]) && has(["导出", "export", "转换", "convert"]) {
            add("pdf_exported")
        }

        let hasFileIntent = has(["保存", "存到", "写到", "新建文件", "创建文件", "生成文件", "save to", "write to", "create file"])
        let nonFileContext = has(["日历", "calendar", "提醒事项", "reminder", "备忘录", "notes", "邮件", "mail", "email"])
        if hasFileIntent && !nonFileContext {
            add("file_saved")
        }

        if has(["文件夹", "目录", "folder", "directory"]) && has(["创建", "新建", "create", "make"]) {
            add("folder_created")
        }

        if has(["日历", "日程", "calendar", "event"]) && has(["创建", "新建", "加入", "添加", "写入", "create", "add", "schedule"]) {
            add("calendar_event_created")
        }

        if has(["提醒事项", "提醒我", "reminder", "待办", "todo"]) && has(["创建", "新建", "添加", "create", "add"]) {
            add("reminder_created")
        }

        if has(["备忘录", "notes", "note"]) &&
            !has(["文本编辑器或备忘录", "text editor or notes", "textedit or notes"]) &&
            has(["创建", "新建", "写入", "保存", "create", "write", "save"]) {
            add("note_created")
        }

        if has(["邮件", "mail", "email"]) && has(["草稿", "draft", "撰写", "compose", "写"]) {
            add("mail_draft_created")
        }

        if has(["快捷指令", "shortcut", "shortcuts"]) && has(["运行", "执行", "run"]) {
            add("shortcut_ran")
        }

        if has(["shell", "终端", "terminal", "命令", "command"]) && has(["运行", "执行", "跑", "run", "execute"]) {
            add("shell_command_submitted")
        }

        if has(["http://", "https://", "url", "网址", "网页"]) && has(["打开", "访问", "open", "visit"]) {
            add("browser_url_visible", app: inferredBrowserApp(from: lowered))
        }

        if contracts.isEmpty,
           has(["打开", "启动", "open", "launch"]),
           !has(["搜索", "查询", "search"]) {
            add("app_opened", app: inferredNamedApp(from: lowered))
        }

        return contracts
    }

    private static func isPrimaryOutcomeKind(_ kind: String) -> Bool {
        !["app_opened", "browser_tab_opened"].contains(kind)
    }

    private static func shouldAddStepContractToTask(_ contract: CompletionContract, text: String, hasPrimaryObjective: Bool) -> Bool {
        guard shouldEnforceStepContract(contract, text: text) else { return false }
        if hasPrimaryObjective && !isPrimaryOutcomeKind(contract.kind) {
            return false
        }
        return true
    }

    private static func shouldEnforceStepContract(_ contract: CompletionContract, text: String) -> Bool {
        let lowered = text.lowercased()
        func has(_ terms: [String]) -> Bool {
            terms.contains { lowered.contains($0.lowercased()) }
        }

        switch contract.kind {
        case "external_message_sent":
            let strongSend = has(["发送消息", "发送给", "发给", "发晚安", "同步给", "通知", "告诉", "转发", "分享给", "send message", "send it", "send to", "press send", "deliver"])
            let conversationStep = has(["聊天", "持续聊天", "对话", "开头", "开场", "chat", "conversation", "talk"])
            let observeOnly = has(["阅读上下文", "读取上下文", "查看最近", "聊天记录", "了解之前", "理解上下文", "获取最近", "观察", "验证", "read context", "observe", "recent messages"])
            let processOnly = observeOnly || has(["打开", "搜索", "查找", "定位", "准备", "验证联系人", "验证聊天", "当前聊天对象", "聊天对象", "粘贴", "stage", "staged", "staging", "before send", "before sending", "verify recipient", "verify chat", "does not send", "不发送", "未发送", "暂不发送"])
            if processOnly && !strongSend {
                return false
            }
            if conversationStep && has(["发送", "发出", "开场消息", "开头消息", "第一条", "opening message", "first message"]) {
                return true
            }
            return strongSend || !processOnly
        case "file_saved":
            let strongSave = has(["保存到", "存到", "写到", "生成文件", "创建文件", "save to", "write to", "create file"])
            let processOnly = has(["打开", "准备", "编辑", "草稿", "输入文本", "写入文本", "文档中输入", "prepare", "type text", "set text"])
            return strongSave || !processOnly
        default:
            return true
        }
    }

    private static func effectEvidence(call: ToolCall, result: ToolResult) -> CompletionEvidence? {
        let fallbackKind = fallbackEffectKind(call: call, result: result)
        guard let kind = result.data["effect"] ?? fallbackKind else { return nil }
        let verifiedText = result.data["verified"] ?? result.data["effect_verified"]
        let verified = bool(verifiedText) ?? fallbackVerified(call: call, result: result, kind: kind)
        let app = result.data["app"] ?? appName(for: call)
        let target = result.data["target"] ??
            result.data["recipient"] ??
            result.data["chat"] ??
            result.data["title"] ??
            result.data["subject"] ??
            result.data["name"] ??
            result.data["path"] ??
            result.data["url"] ??
            ""
        let value = result.data["value"] ??
            result.data["text"] ??
            result.data["message"] ??
            result.data["pdf"] ??
            result.data["command"] ??
            result.data["output"] ??
            ""
        return CompletionEvidence(
            kind: kind,
            app: app,
            target: target,
            value: value,
            tool: call.name,
            evidence: result.evidence,
            verified: verified
        )
    }

    private static func fallbackEffectKind(call: ToolCall, result: ToolResult) -> String? {
        switch call.name {
        case "wechat_send_text", "lark_send_text", "qq_send_text", "wechat_send_staged", "lark_send_staged", "qq_send_staged":
            return "external_message_sent"
        case "wechat_open_chat", "lark_open_chat", "qq_open_chat":
            return "chat_session_ready"
        case "wechat_open", "lark_open", "qq_open", "aios_open_app", "dock_open", "shortcuts_open", "claude_open", "codex_open":
            return "app_opened"
        case "textedit_save_as":
            return "file_saved"
        case "finder_create_folder":
            return "folder_created"
        case "libreoffice_export_pdf":
            return "pdf_exported"
        case "finder_read_text_file":
            return "file_content_verified"
        case "calendar_create_event":
            return "calendar_event_created"
        case "reminders_create":
            return "reminder_created"
        case "notes_create_note":
            return "note_created"
        case "mail_compose_draft":
            return "mail_draft_created"
        case "shortcuts_run":
            return "shortcut_ran"
        case "terminal_run_command":
            return "shell_command_submitted"
        case "safari_open_url", "chrome_open_url", "safari_new_tab", "chrome_new_tab", "aios_open_url":
            if (result.data["url"] ?? string(call.arguments["url"]) ?? "").isEmpty {
                return nil
            }
            return "browser_url_visible"
        default:
            return nil
        }
    }

    private static func fallbackVerified(call: ToolCall, result: ToolResult, kind: String) -> Bool {
        guard result.success else { return false }
        switch kind {
        case "external_message_sent":
            return result.data["verified_recipient"] == "true" && result.data["verified_message"] == "true"
        case "browser_url_visible":
            return result.data["verified_current_url"] == "true"
        default:
            return true
        }
    }

    private static func evidenceKind(_ evidenceKind: String, satisfies contractKind: String) -> Bool {
        if evidenceKind == contractKind { return true }
        switch contractKind {
        case "file_saved":
            return ["file_saved", "file_created", "file_exists", "pdf_exported", "file_content_verified"].contains(evidenceKind)
        case "browser_url_visible":
            return ["browser_url_visible", "url_opened"].contains(evidenceKind)
        default:
            return false
        }
    }

    private static func observationContainsSentMessage(_ result: ToolResult, message: String) -> Bool {
        let haystack = ([result.evidence, result.error ?? "", result.suggestion ?? ""] + Array(result.data.values))
            .joined(separator: "\n")
            .lowercased()
        return messageProbes(message).contains { probe in
            guard haystack.contains(probe.lowercased()) else { return false }
            return !haystack.contains("\(probe.lowercased())|")
        }
    }

    private static func messageProbes(_ message: String) -> [String] {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var probes: [String] = []
        func add(_ value: String) {
            let cleaned = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "，。,.；;：:、 "))
            guard cleaned.count >= 4 else { return }
            if !probes.contains(cleaned) { probes.append(cleaned) }
        }
        for separator in ["。", "！", "!", "\n"] {
            if let first = trimmed.components(separatedBy: separator).first {
                add(String(first.prefix(18)))
            }
        }
        for phrase in ["项目的原理", "核心原理", "任务规划", "自主调用各种工具", "无需人工逐步干预"] where trimmed.localizedCaseInsensitiveContains(phrase) {
            add(phrase)
        }
        add(String(trimmed.prefix(18)))
        return probes
    }

    private static func chatApp(for toolName: String) -> String? {
        if toolName.hasPrefix("wechat_") { return "WeChat" }
        if toolName.hasPrefix("lark_") { return "Lark" }
        if toolName.hasPrefix("qq_") { return "QQ" }
        return nil
    }

    private static func appName(for call: ToolCall) -> String {
        if let app = resultAppName(from: call.name) {
            return app
        }
        return string(call.arguments["app_name"]) ??
            string(call.arguments["bundle_id"]) ??
            string(call.arguments["app"]) ??
            ""
    }

    private static func resultAppName(from toolName: String) -> String? {
        if toolName.hasPrefix("wechat_") { return "WeChat" }
        if toolName.hasPrefix("lark_") { return "Lark" }
        if toolName.hasPrefix("qq_") { return "QQ" }
        if toolName.hasPrefix("safari_") { return "Safari" }
        if toolName.hasPrefix("chrome_") { return "Chrome" }
        if toolName.hasPrefix("calendar_") { return "Calendar" }
        if toolName.hasPrefix("reminders_") { return "Reminders" }
        if toolName.hasPrefix("notes_") { return "Notes" }
        if toolName.hasPrefix("mail_") { return "Mail" }
        if toolName.hasPrefix("shortcuts_") { return "Shortcuts" }
        if toolName.hasPrefix("terminal_") { return "Terminal" }
        if toolName.hasPrefix("textedit_") { return "TextEdit" }
        if toolName.hasPrefix("finder_") { return "Finder" }
        if toolName.hasPrefix("libreoffice_") { return "LibreOffice" }
        return nil
    }

    private static func inferredChatApp(from lowered: String) -> String {
        if lowered.contains("微信") || lowered.contains("wechat") { return "WeChat" }
        if lowered.contains("飞书") || lowered.contains("lark") { return "Lark" }
        if lowered.contains("qq") { return "QQ" }
        return ""
    }

    private static func inferredBrowserApp(from lowered: String) -> String {
        if lowered.contains("safari") { return "Safari" }
        if lowered.contains("chrome") || lowered.contains("谷歌") { return "Chrome" }
        return ""
    }

    private static func inferredNamedApp(from lowered: String) -> String {
        let known = [
            ("微信", "WeChat"),
            ("wechat", "WeChat"),
            ("飞书", "Lark"),
            ("lark", "Lark"),
            ("qq", "QQ"),
            ("safari", "Safari"),
            ("chrome", "Chrome"),
            ("日历", "Calendar"),
            ("calendar", "Calendar"),
            ("提醒事项", "Reminders"),
            ("reminders", "Reminders"),
            ("备忘录", "Notes"),
            ("notes", "Notes"),
            ("邮件", "Mail"),
            ("mail", "Mail"),
            ("textedit", "TextEdit"),
            ("文本编辑", "TextEdit"),
            ("finder", "Finder")
        ]
        return known.first(where: { lowered.contains($0.0) })?.1 ?? ""
    }
}

struct PolicyDecision {
    let allowed: Bool
    let reason: String
}

struct PolicyEngine {
    func evaluate(_ call: ToolCall, knownTools: Set<String>) -> PolicyDecision {
        if !knownTools.contains(call.name) && !Self.orchestrationTools.contains(call.name) {
            return PolicyDecision(allowed: false, reason: "Unknown tool.")
        }

        if call.name == "terminal_run_command",
           let command = string(call.arguments["command"]),
           containsDeletionCommand(command) {
            return PolicyDecision(allowed: false, reason: "Shell command appears to delete files, which remains protected.")
        }

        if mentionsProtectedPaymentOrCredential(call.arguments) {
            return PolicyDecision(allowed: false, reason: "Payment or credential handling remains protected.")
        }

        return PolicyDecision(allowed: true, reason: "Allowed by current project policy.")
    }

    private static let orchestrationTools: Set<String> = [
        "task_plan_submit",
        "step_complete",
        "step_failed",
        "plan_update",
        "task_complete"
    ]

    private func containsDeletionCommand(_ command: String) -> Bool {
        let lowered = " \(command.lowercased()) "
        let blockedFragments = [
            " rm ",
            " rm\t",
            " rm\n",
            " rmdir ",
            " unlink ",
            " trash ",
            " shred ",
            " srm ",
            " diskutil erase",
            " mkfs",
            " -delete "
        ]
        return blockedFragments.contains { lowered.contains($0) }
    }

    private func mentionsProtectedPaymentOrCredential(_ value: Any) -> Bool {
        if let text = value as? String {
            let lowered = text.lowercased()
            let protectedTerms = [
                "password",
                "passcode",
                "credential",
                "secret",
                "private key",
                "payment",
                "credit card",
                "密码",
                "口令",
                "支付",
                "付款",
                "银行卡"
            ]
            return protectedTerms.contains { lowered.contains($0) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, nested in
                mentionsProtectedPaymentOrCredential(key) || mentionsProtectedPaymentOrCredential(nested)
            }
        }
        if let array = value as? [Any] {
            return array.contains { mentionsProtectedPaymentOrCredential($0) }
        }
        return false
    }
}

@MainActor
final class OpenAICompatibleClient {
    private let config: LLMConfig
    private let session: URLSession

    init(config: LLMConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func complete(messages: [[String: Any]], tools: [[String: Any]]) async throws -> LLMResponse {
        var errors: [String] = []
        for provider in config.providers {
            do {
                var response = try await complete(messages: messages, tools: tools, provider: provider)
                var raw = response.rawMessage
                raw["_aios_provider"] = provider.label
                response = LLMResponse(content: response.content, toolCalls: response.toolCalls, rawMessage: raw)
                if provider.label != "primary" {
                    AuditLog.append(action: "llm_provider_fallback_used", fields: [
                        "provider": provider.label,
                        "model": provider.model,
                        "base_url": provider.baseURL.absoluteString
                    ])
                }
                return response
            } catch {
                errors.append("\(provider.label): \(error.localizedDescription)")
                AuditLog.append(action: "llm_provider_failed", fields: [
                    "provider": provider.label,
                    "model": provider.model,
                    "base_url": provider.baseURL.absoluteString,
                    "error": error.localizedDescription
                ])
            }
        }
        throw RuntimeError("All LLM providers failed: \(errors.joined(separator: " | "))")
    }

    private func complete(messages: [[String: Any]], tools: [[String: Any]], provider: LLMProvider) async throws -> LLMResponse {
        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = provider.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": provider.model,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
            "temperature": 0.2
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw RuntimeError("LLM HTTP \(http.statusCode): \(text)")
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw RuntimeError("LLM response did not contain choices[0].message")
        }

        let toolCalls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { raw -> ToolCall? in
            guard
                let id = raw["id"] as? String,
                let function = raw["function"] as? [String: Any],
                let name = function["name"] as? String
            else {
                return nil
            }

            let argumentString = function["arguments"] as? String ?? "{}"
            let argumentData = Data(argumentString.utf8)
            let parsed = (try? JSONSerialization.jsonObject(with: argumentData)) as? [String: Any]
            return ToolCall(id: id, name: name, arguments: parsed ?? [:], raw: raw)
        }

        return LLMResponse(content: message["content"] as? String, toolCalls: toolCalls, rawMessage: message)
    }
}

