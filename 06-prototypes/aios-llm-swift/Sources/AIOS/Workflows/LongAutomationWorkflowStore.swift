import Foundation

struct LongAutomationWorkflowStore {
    static func catalog(goal: String = "") -> [String: String] {
        let query = normalizeForSearch(goal)
        let rows = workflowRows().map { row -> [String: String] in
            var annotated = row
            let haystack = normalizeForSearch(row.values.joined(separator: " "))
            let terms = workflowMatchTerms(goal: goal, query: query, haystack: haystack, workflowID: row["id"] ?? "")
            annotated["match_score"] = query.isEmpty ? "0" : "\(terms.count)"
            annotated["matched_terms"] = terms.joined(separator: ",")
            return annotated
        }.sorted {
            let left = int($0["match_score"]) ?? 0
            let right = int($1["match_score"]) ?? 0
            if left == right { return ($0["id"] ?? "") < ($1["id"] ?? "") }
            return left > right
        }
        return [
            "schema": "aios.long_automation.workflow_catalog.v1",
            "goal": goal,
            "workflows": jsonStringValue(rows),
            "primary_path": "chat_continuity -> browser_business -> document_message -> resident_autopilot -> cockpit_operator_board",
            "execution_contract": "Each workflow can create a durable task graph; resident_autopilot keeps it alive through daemon ticks; cockpit_operator_board exposes what to do next."
        ]
    }

    static func chatContinuity(args: [String: Any]) throws -> [String: String] {
        let app = chatAppName(string(args["app"]) ?? string(args["app_name"]) ?? "wechat")
        let target = string(args["recipient"]) ?? string(args["chat"]) ?? string(args["target"]) ?? ""
        let objective = string(args["objective"]) ?? string(args["goal"]) ?? "持续沟通并推进任务"
        let seed = string(args["message_text"]) ?? string(args["message"]) ?? ""
        let cadence = max(30, int(args["cadence_seconds"]) ?? 300)
        let maxTurns = max(1, int(args["max_turns"]) ?? 6)
        let createGraph = bool(args["create_graph"]) ?? true
        let createResident = bool(args["create_resident"]) ?? true
        let graphTitle = "Chat continuity: \(app) \(target)"
        let graphGoal = [
            "在\(app)里和\(target.isEmpty ? "目标聊天" : target)持续沟通。",
            "目标：\(objective)。",
            seed.isEmpty ? "先观察上下文，再判断是否需要回复。" : "先发送/同步这段起始消息：\(seed)",
            "每轮都先观察最近聊天内容，再给出下一步或回复。"
        ].joined(separator: "\n")
        let nodes = chatNodes(app: app, target: target, objective: objective, seedMessage: seed, cadenceSeconds: cadence, maxTurns: maxTurns)
        var payload = workflowPayload(
            id: "chat-continuity",
            title: "WeChat/Lark continuous conversation",
            goal: graphGoal,
            nodes: nodes,
            recommendedRecipes: ["continuous-chat-followup", "write-plan-and-sync", "send-file-to-contact"],
            primaryTools: ["app_skill_resolve_action", "\(chatToolPrefix(app))_search_chat", "\(chatToolPrefix(app))_send_text", "\(chatToolPrefix(app))_verify_recent_message", "resident_agent_plan"]
        )
        if createGraph {
            let graph = try TaskGraphStore.create(title: graphTitle, goal: graphGoal, nodes: nodes)
            payload["task_graph"] = jsonStringValue(graph.dictionary)
            payload["task_graph_id"] = graph.id
        }
        if createResident {
            let resident = try ResidentAgentStore.plan(goal: graphGoal, app: app, surface: "chat", wakeAfterSeconds: cadence)
            payload["resident_session"] = resident["session"] ?? ""
        }
        return payload
    }

    static func browserBusiness(args: [String: Any]) throws -> [String: String] {
        let url = string(args["url"]) ?? ""
        let goal = string(args["goal"]) ?? string(args["objective"]) ?? "完成 Chrome 业务网页任务"
        let extractionSchema = string(args["extraction_schema"]) ?? string(args["schema"]) ?? ""
        let createGraph = bool(args["create_graph"]) ?? true
        let sessionName = normalizeID(url.isEmpty ? goal : url)
        let nodes = browserNodes(goal: goal, url: url, extractionSchema: extractionSchema)
        var payload = workflowPayload(
            id: "browser-business",
            title: "Chrome business web automation",
            goal: goal,
            nodes: nodes,
            recommendedRecipes: ["browser-business-task"],
            primaryTools: ["browser_runtime_session", "browser_cdp_launch", "browser_agent_observe", "browser_agent_act", "browser_agent_extract", "browser_agent_wait"]
        )
        payload["browser_agent_plan"] = jsonStringValue(BrowserAgentRuntime.agentPlan(goal: goal, url: url, extractionSchema: extractionSchema))
        payload["browser_session_name"] = sessionName
        if createGraph {
            let graph = try TaskGraphStore.create(title: "Browser business: \(goal)", goal: goal, nodes: nodes)
            payload["task_graph"] = jsonStringValue(graph.dictionary)
            payload["task_graph_id"] = graph.id
        }
        return payload
    }

    static func documentMessage(args: [String: Any]) throws -> [String: String] {
        let path = string(args["path"]) ?? string(args["source_path"]) ?? ""
        let outdir = string(args["outdir"]) ?? string(args["output_dir"]) ?? "~/Desktop"
        let app = chatAppName(string(args["app"]) ?? string(args["app_name"]) ?? "wechat")
        let target = string(args["recipient"]) ?? string(args["chat"]) ?? string(args["target"]) ?? ""
        let instructions = string(args["instructions"]) ?? string(args["goal"]) ?? "导出文档并同步给指定对象"
        let createGraph = bool(args["create_graph"]) ?? true
        let nodes = documentNodes(path: path, outdir: outdir, app: app, target: target, instructions: instructions)
        let goal = "处理文档 \(path)，输出到 \(outdir)，并通过 \(app) 发给 \(target)。要求：\(instructions)"
        var payload = workflowPayload(
            id: "document-message",
            title: "Finder + document + messaging workflow",
            goal: goal,
            nodes: nodes,
            recommendedRecipes: ["document-export-and-send", "export-document-pdf", "send-file-to-contact"],
            primaryTools: ["finder_file_info", "libreoffice_export_pdf", "\(chatToolPrefix(app))_stage_file", "\(chatToolPrefix(app))_send_staged", "\(chatToolPrefix(app))_verify_recent_message"]
        )
        if createGraph {
            let graph = try TaskGraphStore.create(title: "Document message: \(URL(fileURLWithPath: path).lastPathComponent)", goal: goal, nodes: nodes)
            payload["task_graph"] = jsonStringValue(graph.dictionary)
            payload["task_graph_id"] = graph.id
        }
        return payload
    }

    static func residentAutopilot(args: [String: Any]) throws -> [String: String] {
        let goal = string(args["goal"]) ?? "长期自动推进 macOS 任务"
        let app = string(args["app_name"]) ?? string(args["app"]) ?? ""
        let surface = string(args["surface"]) ?? ""
        let cadence = max(15, int(args["cadence_seconds"]) ?? int(args["wake_after_seconds"]) ?? 60)
        let createResident = bool(args["create_resident"]) ?? true
        let nodes = residentNodes(goal: goal, app: app, surface: surface, wakeAfterSeconds: cadence)
        var payload = workflowPayload(
            id: "resident-autopilot",
            title: "Resident long-task autopilot",
            goal: goal,
            nodes: nodes,
            recommendedRecipes: ["continuous-chat-followup", "browser-business-task", "document-export-and-send"],
            primaryTools: ["resident_agent_plan", "resident_agent_tick", "long_run_daemon_tick", "task_graph_tick", "memory_context_pack", "cockpit_live_summary"]
        )
        payload["cadence_seconds"] = "\(cadence)"
        payload["route"] = jsonStringValue(AgentRoleSystem.plan(goal: goal, app: app, surface: surface))
        payload["memory_context"] = jsonStringValue(MemoryIndexStore.contextPack(query: goal, limit: 8))
        if createResident {
            let resident = try ResidentAgentStore.plan(goal: goal, app: app, surface: surface, wakeAfterSeconds: cadence)
            payload["resident_session"] = resident["session"] ?? ""
            payload["task_graph"] = resident["task_graph"] ?? ""
        }
        return payload
    }

    static func cockpitOperatorBoard(runID: String? = nil, limit: Int = 20) -> [String: String] {
        let summary = CockpitDashboardStore.liveSummary(runID: runID, limit: limit)
        let dashboard = CockpitDashboardStore.dashboard(runID: runID, limit: limit)
        let workflows = catalog(goal: runID ?? "")
        let resident = ResidentAgentStore.status(limit: limit)
        let taskGraphs = TaskGraphStore.list().prefix(max(1, limit)).map(\.dictionary)
        let queue = TaskQueue.list().prefix(max(1, limit)).map(\.dictionary)
        let lanes: [[String: String]] = [
            ["id": "inbox", "title": "Task Inbox", "source": "queue", "count": "\(queue.count)", "action": "tick_daemon or submit a goal"],
            ["id": "autopilot", "title": "Resident Autopilot", "source": "resident_sessions", "count": "\(parseRows(resident["sessions"] ?? "[]").count)", "action": "resident_agent_tick / long_run_daemon_tick"],
            ["id": "workflows", "title": "Goal Workflows", "source": "workflow_catalog", "count": "\(workflowRows().count)", "action": "start chat/browser/document workflow"],
            ["id": "evidence", "title": "Evidence And Replay", "source": "trajectory/dashboard", "count": dashboard["artifacts"].map { "\(parseRows($0).count)" } ?? "0", "action": "open replay or export dashboard"],
            ["id": "operator", "title": "Human Interrupts", "source": "cockpit_commands", "count": "\(CockpitControlStore.list(runID: runID).count)", "action": "pause, feedback, replan, branch, resume"]
        ]
        return [
            "schema": "aios.cockpit.operator_board.v1",
            "run_id": runID ?? "",
            "lanes": jsonStringValue(lanes),
            "live_summary": jsonStringValue(summary),
            "dashboard": jsonStringValue(dashboard),
            "workflow_catalog": jsonStringValue(workflows),
            "task_graphs": jsonStringValue(Array(taskGraphs)),
            "queue": jsonStringValue(Array(queue)),
            "resident": jsonStringValue(resident),
            "next_operator_actions": "1) tick daemon, 2) inspect selected run, 3) continue/resume if waiting, 4) add feedback/replan if stuck, 5) export replay when done"
        ]
    }

    static func residentNodes(goal: String, app: String = "", surface: String = "", wakeAfterSeconds: Int = 60) -> [DurableTaskNode] {
        let text = normalizeForSearch([goal, app, surface].joined(separator: " "))
        let hasChat = text.contains("wechat") || text.contains("微信") || text.contains("lark") || text.contains("飞书") || text.contains("feishu") || text.contains("qq") || text.contains("chat") || text.contains("聊天") || text.contains("沟通")
        let hasBrowser = text.contains("chrome") || text.contains("browser") || text.contains("web") || text.contains("http") || text.contains("网页") || text.contains("网站")
        let hasDocument = text.contains("pdf") || text.contains("文档") || text.contains("文件") || text.contains("finder")
        if hasBrowser && hasChat {
            return browserThenChatNodes(goal: goal, url: firstURL(in: goal), chatApp: chatAppName(goal), wakeAfterSeconds: wakeAfterSeconds)
        }
        if hasDocument && hasChat {
            return documentNodes(path: "", outdir: "~/Desktop", app: chatAppName(goal), target: "", instructions: goal)
        }
        if hasBrowser {
            return browserNodes(goal: goal, url: firstURL(in: goal), extractionSchema: "")
        }
        if hasChat {
            return chatNodes(app: chatAppName(app.isEmpty ? goal : app), target: "", objective: goal, seedMessage: "", cadenceSeconds: wakeAfterSeconds, maxTurns: 3)
        }
        if hasDocument {
            return documentNodes(path: "", outdir: "~/Desktop", app: chatAppName(app), target: "", instructions: goal)
        }
        let now = isoDateString(Date())
        let wake = isoDateString(Date().addingTimeInterval(TimeInterval(max(15, wakeAfterSeconds))))
        return [
            DurableTaskNode(id: "A1", title: "Plan next durable step", goal: "读取记忆、任务图和当前 App 状态，为目标制定下一步：\(goal)", status: "pending", dependsOn: [], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "A2", title: "Execute bounded step", goal: "执行目标的一步真实 macOS 操作，优先 recipe/app skill/browser/background 工具：\(goal)", status: "pending", dependsOn: ["A1"], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "A3", title: "Observe and decide continuation", goal: "观察执行结果，更新记忆；如果还要等待外部状态，则安排下一次 resident tick：\(goal)", status: "waiting", dependsOn: ["A2"], runID: nil, waitCondition: "time", waitValue: wake, notBefore: wake, attempts: 0, updatedAt: now)
        ]
    }

    private static func chatNodes(app: String, target: String, objective: String, seedMessage: String, cadenceSeconds: Int, maxTurns: Int) -> [DurableTaskNode] {
        let now = isoDateString(Date())
        let prefix = chatToolPrefix(app)
        let targetText = target.isEmpty ? "目标聊天" : target
        var nodes: [DurableTaskNode] = [
            DurableTaskNode(
                id: "C1",
                title: "Open and observe chat",
                goal: "使用 \(prefix)_search_chat / \(prefix)_verify_chat 打开并确认 \(app) 的 \(targetText)，读取最近可见聊天上下文，提炼对方诉求和下一步。",
                status: "pending",
                dependsOn: [],
                runID: nil,
                waitCondition: nil,
                waitValue: nil,
                notBefore: nil,
                attempts: 0,
                updatedAt: now
            ),
            DurableTaskNode(
                id: "C2",
                title: seedMessage.isEmpty ? "Draft first response" : "Send seed message",
                goal: seedMessage.isEmpty ?
                    "围绕目标「\(objective)」生成并发送一条上下文相关回复；发送后用 \(prefix)_verify_recent_message 验证。" :
                    "向 \(targetText) 发送这段消息并验证：\(seedMessage)",
                status: "pending",
                dependsOn: ["C1"],
                runID: nil,
                waitCondition: nil,
                waitValue: nil,
                notBefore: nil,
                attempts: 0,
                updatedAt: now
            )
        ]
        for turn in 1...max(1, maxTurns - 1) {
            let wake = isoDateString(Date().addingTimeInterval(TimeInterval(cadenceSeconds * turn)))
            nodes.append(DurableTaskNode(
                id: "C\(turn + 2)",
                title: "Continue chat turn \(turn)",
                goal: "等待后重新观察 \(app) 的 \(targetText)；如果对方有新回复，则继续围绕「\(objective)」给出下一条回复；如果没有新信息，记录状态并继续等待。",
                status: "waiting",
                dependsOn: ["C\(turn + 1)"],
                runID: nil,
                waitCondition: "time",
                waitValue: wake,
                notBefore: wake,
                attempts: 0,
                updatedAt: now
            ))
        }
        return nodes
    }

    private static func browserNodes(goal: String, url: String, extractionSchema: String) -> [DurableTaskNode] {
        let now = isoDateString(Date())
        return [
            DurableTaskNode(id: "B1", title: "Open browser session", goal: "启动/绑定 Chrome CDP 长会话，打开 \(url.isEmpty ? "目标网页" : url)，保留登录态和下载目录。目标：\(goal)", status: "pending", dependsOn: [], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "B2", title: "Observe and act", goal: "使用 browser_agent_observe/act 完成网页上的主要操作。每次 act 前先 observe，失败后重建 selector。目标：\(goal)", status: "pending", dependsOn: ["B1"], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "B3", title: "Extract result", goal: extractionSchema.isEmpty ? "用 browser_agent_extract 抽取页面结果、表格、链接、下载状态，并生成结构化摘要。" : "按 schema 抽取网页结果：\(extractionSchema)", status: "pending", dependsOn: ["B2"], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "B4", title: "Wait and verify", goal: "使用 browser_agent_wait / observe_wait 验证 URL、文本、selector、下载文件或业务状态已经达到目标：\(goal)", status: "pending", dependsOn: ["B3"], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now)
        ]
    }

    private static func browserThenChatNodes(goal: String, url: String, chatApp: String, wakeAfterSeconds: Int) -> [DurableTaskNode] {
        let now = isoDateString(Date())
        let prefix = chatToolPrefix(chatApp)
        let wake = isoDateString(Date().addingTimeInterval(TimeInterval(max(30, wakeAfterSeconds))))
        return [
            DurableTaskNode(id: "M1", title: "Open browser session", goal: "启动/绑定 Chrome CDP 长会话，打开 \(url.isEmpty ? "目标业务网页" : url)，保留登录态。目标：\(goal)", status: "pending", dependsOn: [], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "M2", title: "Operate business page", goal: "使用 browser_agent_observe/act/extract/wait 推进网页业务任务，并提取可同步结果。目标：\(goal)", status: "pending", dependsOn: ["M1"], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "M3", title: "Send browser result to chat", goal: "把网页处理结果通过 \(chatApp) 同步给目标联系人或群。先用 \(prefix)_search_chat / \(prefix)_verify_chat 确认目标，再发送摘要并验证最近消息。", status: "pending", dependsOn: ["M2"], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "M4", title: "Follow up after response", goal: "等待后重新观察 \(chatApp) 回复和网页状态；如有新要求，回到浏览器继续处理并再次同步。", status: "waiting", dependsOn: ["M3"], runID: nil, waitCondition: "time", waitValue: wake, notBefore: wake, attempts: 0, updatedAt: now)
        ]
    }

    private static func documentNodes(path: String, outdir: String, app: String, target: String, instructions: String) -> [DurableTaskNode] {
        let now = isoDateString(Date())
        let prefix = chatToolPrefix(app)
        return [
            DurableTaskNode(id: "D1", title: "Locate source document", goal: "用 Finder 验证源文件存在并读取文件信息：\(path.isEmpty ? "待从任务中识别" : path)。要求：\(instructions)", status: "pending", dependsOn: [], runID: nil, waitCondition: path.isEmpty ? nil : "file_exists", waitValue: path.isEmpty ? nil : path, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "D2", title: "Export or prepare artifact", goal: "将文档导出/准备为可发送交付物，优先使用 libreoffice_export_pdf，输出目录：\(outdir)。", status: "pending", dependsOn: ["D1"], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "D3", title: "Send artifact", goal: "通过 \(app) 把准备好的文件发送给 \(target.isEmpty ? "目标联系人" : target)，使用 \(prefix)_stage_file 和 \(prefix)_send_staged，并验证聊天和最近消息/附件。", status: "pending", dependsOn: ["D2"], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now),
            DurableTaskNode(id: "D4", title: "Summarize delivery", goal: "验证 Finder 输出文件和 \(app) 发送状态，生成最终交付摘要。", status: "pending", dependsOn: ["D3"], runID: nil, waitCondition: nil, waitValue: nil, notBefore: nil, attempts: 0, updatedAt: now)
        ]
    }

    private static func workflowPayload(
        id: String,
        title: String,
        goal: String,
        nodes: [DurableTaskNode],
        recommendedRecipes: [String],
        primaryTools: [String]
    ) -> [String: String] {
        [
            "schema": "aios.long_automation.workflow.v1",
            "id": id,
            "title": title,
            "goal": goal,
            "nodes": jsonStringValue(nodes.map(\.dictionary)),
            "recommended_recipes": recommendedRecipes.joined(separator: ","),
            "primary_tools": primaryTools.joined(separator: ","),
            "handoff": "Planner creates/chooses this workflow, task graph schedules bounded runs, resident runtime wakes it, cockpit displays progress and accepts feedback."
        ]
    }

    private static func workflowRows() -> [[String: String]] {
        [
            [
                "id": "chat-continuity",
                "title": "WeChat/Lark continuous conversation",
                "start_tool": "chat_continuity_start",
                "recipes": "continuous-chat-followup,write-plan-and-sync,send-file-to-contact",
                "apps": "WeChat,Lark,Feishu,QQ",
                "does": "open/verify chat, observe context, send bounded replies, schedule follow-up turns"
            ],
            [
                "id": "browser-business",
                "title": "Chrome business web automation",
                "start_tool": "browser_business_start",
                "recipes": "browser-business-task",
                "apps": "Chrome,web apps",
                "does": "bind CDP session, observe/act/extract/wait, cache selectors, verify web state"
            ],
            [
                "id": "document-message",
                "title": "Finder + document + messaging workflow",
                "start_tool": "document_message_start",
                "recipes": "document-export-and-send,export-document-pdf,send-file-to-contact",
                "apps": "Finder,LibreOffice,WPS,Preview,WeChat,Lark,QQ",
                "does": "locate file, export/prepare artifact, send to chat, verify delivery"
            ],
            [
                "id": "resident-autopilot",
                "title": "Resident long-task autopilot",
                "start_tool": "resident_autopilot_start",
                "recipes": "all reusable recipes",
                "apps": "all",
                "does": "create role route, task graph, cadence, memory context, daemon wake contract"
            ],
            [
                "id": "cockpit-operator-board",
                "title": "Cockpit operator board",
                "start_tool": "cockpit_operator_board",
                "recipes": "",
                "apps": "AIOS desktop app",
                "does": "show task inbox, resident sessions, workflows, evidence/replay, operator actions"
            ]
        ]
    }

    private static func workflowMatchTerms(goal: String, query: String, haystack: String, workflowID: String) -> [String] {
        var terms = query.split(separator: " ").map(String.init).filter { haystack.contains($0) }
        let raw = goal.lowercased()
        func add(_ value: String) {
            if !terms.contains(value) { terms.append(value) }
        }
        func containsAny(_ values: [String]) -> Bool {
            values.contains { raw.contains($0.lowercased()) || query.contains(normalizeForSearch($0)) }
        }
        switch workflowID {
        case "chat-continuity":
            if containsAny(["wechat", "微信", "lark", "feishu", "飞书", "qq", "聊天", "沟通", "回复", "持续"]) { add("chat") }
        case "browser-business":
            if containsAny(["chrome", "browser", "web", "http", "网页", "网站", "业务", "表单", "下载", "提取"]) { add("browser") }
        case "document-message":
            if containsAny(["finder", "文档", "文件", "pdf", "导出", "附件", "发送", "发给", "wps", "office"]) { add("document") }
        case "resident-autopilot":
            if containsAny(["长期", "长时间", "持续", "自动", "resident", "daemon", "定时", "等待"]) { add("resident") }
        case "cockpit-operator-board":
            if containsAny(["cockpit", "驾驶舱", "控制台", "看板", "状态", "replay", "回放"]) { add("cockpit") }
        default:
            break
        }
        return terms
    }

    private static func chatAppName(_ raw: String) -> String {
        let text = normalizeForSearch(raw)
        if text.contains("lark") || text.contains("feishu") || text.contains("飞书") { return "Lark" }
        if text.contains("qq") { return "QQ" }
        return "WeChat"
    }

    private static func chatToolPrefix(_ app: String) -> String {
        let text = normalizeForSearch(app)
        if text.contains("lark") || text.contains("feishu") || text.contains("飞书") { return "lark" }
        if text.contains("qq") { return "qq" }
        return "wechat"
    }

    private static func firstURL(in text: String) -> String {
        guard let range = text.range(of: #"https?://[^\s，。；,]+"#, options: .regularExpression) else { return "" }
        return String(text[range])
    }

    private static func parseRows(_ json: String) -> [[String: String]] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.map { row in
            row.reduce(into: [String: String]()) { result, pair in
                if let value = pair.value as? String {
                    result[pair.key] = value
                } else if let value = pair.value as? NSNumber {
                    result[pair.key] = value.stringValue
                } else if JSONSerialization.isValidJSONObject(pair.value) {
                    result[pair.key] = jsonStringValue(pair.value)
                }
            }
        }
    }
}
