import Foundation

struct AppSkillCorePackStore {
    static func corePack(install: Bool = false) throws -> [String: String] {
        let packages = coreDefinitions()
        var installed: [[String: String]] = []
        if install {
            for package in packages {
                let skill = try AppSkillPackageStore.scaffold(
                    id: package["id"] ?? "",
                    appName: package["app_name"] ?? "",
                    bundleID: package["bundle_id"] ?? "",
                    version: "1",
                    capabilities: csv(package["capabilities"] ?? ""),
                    tools: csv(package["tools"] ?? ""),
                    recipes: csv(package["recipes"] ?? ""),
                    selectors: [:],
                    permissions: csv(package["permissions"] ?? ""),
                    entrypoints: entrypoints(package["entrypoints"] ?? ""),
                    notes: package["notes"] ?? ""
                )
                installed.append(skill.dictionary)
            }
        }
        return [
            "schema": "aios.app_skill.core_pack.v1",
            "install": install ? "true" : "false",
            "packages": jsonStringValue(packages),
            "installed": jsonStringValue(installed),
            "coverage": "Finder, Chrome, Safari, Mail, Calendar, TextEdit, WeChat, Lark/Feishu, QQ, Notes, Reminders, WPS/Office/LibreOffice/Preview, IDEs, netdisk/meeting utilities, Terminal, Figma/canvas, generic native apps",
            "extension_policy": "each package owns selectors, recipes, app version compatibility, driver channel, and examples"
        ]
    }

    private static func coreDefinitions() -> [[String: String]] {
        [
            [
                "id": "core-finder",
                "app_name": "Finder",
                "bundle_id": "com.apple.finder",
                "capabilities": "files,folders,search,reveal",
                "tools": "finder_list_directory,finder_file_info,finder_find_files,finder_create_folder,finder_reveal_file",
                "recipes": "",
                "permissions": "automation",
                "notes": "File and folder operations with verification."
            ],
            [
                "id": "core-chrome",
                "app_name": "Google Chrome",
                "bundle_id": "com.google.Chrome",
                "capabilities": "web,dom,cdp,tabs,downloads,file-upload,stagehand",
                "tools": "browser_agent_contract,browser_agent_observe,browser_agent_act,browser_agent_extract,browser_agent_wait,browser_cdp_launch,browser_cdp_observe,browser_cdp_act,browser_cdp_extract,browser_cdp_wait,browser_cdp_file_upload,browser_cdp_download_behavior",
                "recipes": "",
                "permissions": "automation,remote-debugging-port",
                "notes": "Deep web-app control through CDP and Stagehand-style primitives."
            ],
            [
                "id": "core-safari",
                "app_name": "Safari",
                "bundle_id": "com.apple.Safari",
                "capabilities": "web,tabs,javascript,page-text",
                "tools": "safari_open_url,safari_new_tab,safari_search,safari_get_current_url,safari_get_page_text,safari_eval_js,background_driver_dispatch,visual_grounder_run",
                "recipes": "",
                "permissions": "automation",
                "notes": "AppleScript/JavaScript browser adapter; use Chrome CDP when deep DOM control is required."
            ],
            [
                "id": "core-mail-calendar",
                "app_name": "Mail and Calendar",
                "bundle_id": "com.apple.mail,com.apple.iCal",
                "capabilities": "mail-drafts,calendar-events,search",
                "tools": "mail_compose_draft,mail_search_messages,calendar_create_event,calendar_find_events",
                "recipes": "create-calendar-event",
                "permissions": "automation",
                "notes": "Native productivity app adapters with deterministic verification."
            ],
            [
                "id": "core-textedit",
                "app_name": "TextEdit",
                "bundle_id": "com.apple.TextEdit",
                "capabilities": "text,documents,save",
                "tools": "textedit_new_document,textedit_set_text,textedit_read_text,textedit_save_as",
                "recipes": "export-document-pdf",
                "permissions": "automation",
                "notes": "Scriptable text document workflows."
            ],
            [
                "id": "core-wechat",
                "app_name": "WeChat",
                "bundle_id": "com.tencent.xinWeChat",
                "capabilities": "chat,file-send,verify",
                "tools": "wechat_open,wechat_search_chat,wechat_open_chat,wechat_stage_file,wechat_send_text,wechat_send_staged,wechat_verify_chat,wechat_verify_recent_message",
                "recipes": "send-file-to-contact,write-plan-and-sync",
                "permissions": "accessibility,screen-recording",
                "notes": "Chat workflow adapter with recipient/message verification."
            ],
            [
                "id": "core-lark",
                "app_name": "Lark/Feishu",
                "bundle_id": "com.larksuite.Lark,com.bytedance.macos.feishu",
                "capabilities": "chat,file-send,verify",
                "tools": "lark_open,lark_search_chat,lark_stage_file,lark_send_text,lark_send_staged,lark_verify_chat,lark_verify_recent_message,app_verifier_plan,app_verifier_evaluate",
                "recipes": "send-file-to-contact,daily-work-sync",
                "permissions": "accessibility,screen-recording",
                "notes": "Lark/Feishu adapter seed with chat and recent-message completion contracts."
            ],
            [
                "id": "core-qq",
                "app_name": "QQ",
                "bundle_id": "com.tencent.qq",
                "capabilities": "chat,file-send,verify",
                "tools": "qq_open,qq_search_chat,qq_stage_file,qq_send_text,qq_send_staged,qq_verify_chat,qq_verify_recent_message,app_verifier_plan,app_verifier_evaluate",
                "recipes": "send-file-to-contact",
                "permissions": "accessibility,screen-recording",
                "notes": "QQ adapter seed with recipient and recent-message completion contracts."
            ],
            [
                "id": "core-notes-reminders",
                "app_name": "Notes and Reminders",
                "bundle_id": "com.apple.Notes,com.apple.reminders",
                "capabilities": "notes,reminders,local-productivity,verify",
                "tools": "notes_create_note,notes_search,reminders_create,app_verifier_plan",
                "recipes": "capture-note,create-reminder",
                "permissions": "automation",
                "notes": "Local productivity adapters for durable personal task capture."
            ],
            [
                "id": "core-office-docs",
                "app_name": "WPS/Office/LibreOffice/Preview",
                "bundle_id": "com.kingsoft.wpsoffice.mac,org.libreoffice.script,com.apple.Preview",
                "capabilities": "documents,spreadsheets,presentations,pdf-export,verify",
                "tools": "wps_open_file,libreoffice_open_file,libreoffice_export_pdf,preview_open_file,finder_file_info,finder_read_text_file,app_verifier_plan,app_verifier_evaluate",
                "recipes": "export-document-pdf,review-document",
                "permissions": "filesystem,automation",
                "notes": "Office document seed with deterministic filesystem verification for exported artifacts."
            ],
            [
                "id": "core-ide-pack",
                "app_name": "Xcode/JetBrains IDE",
                "bundle_id": "com.apple.dt.Xcode,com.jetbrains.pycharm,com.jetbrains.rustrover",
                "capabilities": "code,projects,open-path,verify",
                "tools": "xcode_open_path,pycharm_open_path,rustrover_open_path,ax_describe_frontmost,visual_read,app_verifier_plan",
                "recipes": "open-project-and-edit",
                "permissions": "automation,accessibility",
                "notes": "IDE adapter seed for opening project/file paths and checking active context by AX/OCR."
            ],
            [
                "id": "core-utility-apps",
                "app_name": "Baidu Netdisk, Tencent Meeting, ToDesk",
                "bundle_id": "com.baidu.netdisk-mac,com.tencent.meeting,com.youqu.todesk",
                "capabilities": "file-upload,meeting,remote-control,stage,verify",
                "tools": "baidunetdisk_open,baidunetdisk_stage_file,tencent_meeting_open,tencent_meeting_stage_join,todesk_open,todesk_stage_remote_id,visual_read,ax_describe_frontmost,app_verifier_plan",
                "recipes": "upload-file-and-verify,join-meeting-after-confirmation",
                "permissions": "accessibility,screen-recording",
                "notes": "High-frequency utility apps with staged actions and explicit visible-state verifiers."
            ],
            [
                "id": "core-terminal",
                "app_name": "Terminal",
                "bundle_id": "com.apple.Terminal",
                "capabilities": "shell,commands,developer-workflows",
                "tools": "terminal_run_command",
                "recipes": "",
                "permissions": "automation",
                "notes": "Terminal command submission adapter."
            ],
            [
                "id": "core-canvas-native",
                "app_name": "Figma/Blender/canvas native surfaces",
                "bundle_id": "com.figma.Desktop,org.blenderfoundation.blender",
                "capabilities": "canvas,icons,non-ax,vision-grounding,native-driver,verify",
                "tools": "background_native_kernel,background_driver_capsule,background_driver_dispatch,app_skill_execute_adapter,visual_grounder_run,visual_ground_action,visual_grounder_verify,visual_grounder_model_registry,visual_grounder_feedback,app_verifier_plan",
                "recipes": "canvas-edit-and-verify",
                "permissions": "adapter-specific",
                "entrypoints": "adapter=adapters/adapter.sh",
                "notes": "Non-AX native surfaces require app-specific adapter or external CUA-compatible driver capsule."
            ]
        ]
    }

    private static func csv(_ text: String) -> [String] {
        text.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func entrypoints(_ text: String) -> [String: String] {
        text.split(separator: ",").reduce(into: [String: String]()) { result, item in
            let parts = item.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return }
            result[parts[0]] = parts[1]
        }
    }
}

struct CockpitReplaySpecStore {
    @MainActor
    static func spec(runID: String? = nil, limit: Int = 80) -> [String: String] {
        let dashboard = CockpitDashboardStore.dashboard(runID: runID, limit: limit)
        let bundle = runID.flatMap { try? ReplayableSessionBundleStore.manifest(runID: $0, limit: limit) } ?? [:]
        return [
            "schema": "aios.cockpit.replay_spec.v1",
            "run_id": runID ?? "",
            "dashboard": jsonStringValue(dashboard),
            "bundle": jsonStringValue(bundle),
            "live_views": "current_step,plan_tree,screenshot_lane,ax_lane,dom_lane,action_result_lane,memory_hits,recipe_hits,artifact_list",
            "controls": "pause,resume,feedback,replan,branch,takeover,continue,clip_recipe,export_bundle",
            "resume_policy": "branch from any trajectory resume point with checkpoint + memory pack + replay evidence",
            "recipe_clipping_policy": "select trajectory slice -> trajectory_clip_recipe -> recipe_program_compile -> recipe_stabilize_program"
        ]
    }
}

struct ShadowEpisodePolicyStore {
    static func policy(goal: String = "", limit: Int = 20) -> [String: String] {
        let digest = EpisodeContextEngine.shadowDigest(limit: limit)
        let graph = LongMemoryEngine.entityGraph(query: goal, limit: limit)
        let preferences = LongMemoryEngine.preferenceDigest(query: goal, limit: limit)
        return [
            "schema": "aios.memory.shadow_episode_policy.v1",
            "goal": goal,
            "digest": jsonStringValue(digest),
            "entity_graph": jsonStringValue(graph),
            "preference_digest": jsonStringValue(preferences),
            "capture_triggers": "run_start,step_failure,pause,resume,human_feedback,task_complete,daemon_tick",
            "episode_policy": "segment by run/task graph/app boundary; consolidate finished/paused runs; connect apps, tools, recipes, files, outcomes",
            "injection_policy": "planner gets compact context_pack; executor gets app/recipe hints; verifier gets prior completion evidence and failure repairs"
        ]
    }
}

struct AgentHarnessDispatchStore {
    static func dispatch(goal: String, app: String = "", surface: String = "") throws -> [String: String] {
        let plan = try AgentHarnessStore.plan(goal: goal, app: app, surface: surface)
        let route = AgentRoleSystem.plan(goal: goal, app: app, surface: surface)
        let packets = try route.enumerated().dropFirst().map { index, role -> [String: String] in
            let previous = route[index - 1]["id"] ?? "planner"
            let current = role["id"] ?? "executor"
            return try AgentRoleSystem.recordHandoff(
                goal: goal,
                fromRole: previous,
                toRole: current,
                reason: "dispatch role \(current)",
                context: ["harness_id": plan["id"] ?? ""]
            ).dictionary
        }
        return [
            "schema": "aios.agent.harness.dispatch.v1",
            "harness": jsonStringValue(plan),
            "route": jsonStringValue(route),
            "handoff_packets": jsonStringValue(packets),
            "execution_contract": "roles may be run by separate workers or by resident_agent_tick; every role returns structured evidence before handoff"
        ]
    }
}
