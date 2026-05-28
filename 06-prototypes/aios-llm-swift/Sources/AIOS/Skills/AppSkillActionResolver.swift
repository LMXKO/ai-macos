import Foundation

struct AppSkillActionResolver {
    static func resolve(route: AppSkillRoute, action: String, arguments: [String: Any]) -> AppSkillResolvedAction? {
        let op = normalizeForSearch([
            action,
            firstString(arguments, ["effect", "intent", "operation"]) ?? "",
            firstString(arguments, ["goal"]) ?? ""
        ].joined(separator: " "))
        let available = Set(route.tools)
        func has(_ tool: String) -> Bool { available.contains(tool) }
        func resolved(_ tool: String, _ args: [String: Any], _ reason: String) -> AppSkillResolvedAction? {
            guard has(tool) else { return nil }
            return AppSkillResolvedAction(tool: tool, arguments: args, reason: reason)
        }
        func isAny(_ values: String...) -> Bool {
            values.contains { op.contains($0) }
        }

        if has("wechat_open") {
            if isAny("verify") {
                if let text = messageText(arguments) {
                    return resolved("wechat_verify_recent_message", ["text": text], "verify WeChat recent message text")
                }
                if let recipient = chatTarget(arguments) {
                    return resolved("wechat_verify_chat", ["recipient": recipient], "verify WeChat chat target")
                }
            }
            if isAny("stage", "attach", "file") || (isAny("send") && firstString(arguments, ["path", "file_path", "attachment"]) != nil) {
                if let recipient = chatTarget(arguments), let path = firstString(arguments, ["path", "file_path", "attachment"]) {
                    return resolved("wechat_stage_file", ["recipient": recipient, "path": path], "stage file in WeChat chat")
                }
            }
            if isAny("send", "message") {
                if let recipient = chatTarget(arguments), let text = messageText(arguments) {
                    return resolved("wechat_send_text", ["recipient": recipient, "text": text], "send and verify WeChat text")
                }
                if let recipient = chatTarget(arguments) {
                    return resolved("wechat_send_staged", ["recipient": recipient], "send staged WeChat content after chat verification")
                }
            }
            if isAny("search", "find") {
                if let target = chatTarget(arguments) {
                    return resolved("wechat_search_chat", ["name": target], "search WeChat chat/contact")
                }
            }
            if isAny("open") {
                if let target = chatTarget(arguments) {
                    return resolved("wechat_open_chat", ["recipient": target], "open and verify WeChat chat")
                }
                return resolved("wechat_open", [:], "open WeChat")
            }
        }

        if has("lark_open") {
            if isAny("verify") {
                if let text = messageText(arguments) {
                    return resolved("lark_verify_recent_message", ["text": text], "verify Lark recent message text")
                }
                if let chat = chatTarget(arguments) {
                    return resolved("lark_verify_chat", ["chat": chat], "verify Lark chat target")
                }
            }
            if isAny("stage", "attach", "file") || (isAny("send") && firstString(arguments, ["path", "file_path", "attachment"]) != nil) {
                if let chat = chatTarget(arguments), let path = firstString(arguments, ["path", "file_path", "attachment"]) {
                    return resolved("lark_stage_file", ["chat": chat, "path": path], "stage file in Lark chat")
                }
            }
            if isAny("send", "message") {
                if let chat = chatTarget(arguments), let text = messageText(arguments) {
                    return resolved("lark_send_text", ["chat": chat, "text": text], "send and verify Lark text")
                }
                if let chat = chatTarget(arguments) {
                    return resolved("lark_send_staged", ["chat": chat], "send staged Lark content after chat verification")
                }
            }
            if isAny("search", "find") {
                if let chat = chatTarget(arguments) {
                    return resolved("lark_search_chat", ["name": chat], "search Lark chat/contact")
                }
            }
            if isAny("open") {
                if let chat = chatTarget(arguments) {
                    return resolved("lark_search_chat", ["name": chat], "open/search Lark chat target")
                }
                return resolved("lark_open", [:], "open Lark")
            }
        }

        if has("qq_open") {
            if isAny("verify") {
                if let text = messageText(arguments) {
                    return resolved("qq_verify_recent_message", ["text": text], "verify QQ recent message text")
                }
                if let recipient = chatTarget(arguments) {
                    return resolved("qq_verify_chat", ["recipient": recipient], "verify QQ chat target")
                }
            }
            if isAny("stage", "attach", "file") || (isAny("send") && firstString(arguments, ["path", "file_path", "attachment"]) != nil) {
                if let recipient = chatTarget(arguments), let path = firstString(arguments, ["path", "file_path", "attachment"]) {
                    return resolved("qq_stage_file", ["recipient": recipient, "path": path], "stage file in QQ chat")
                }
            }
            if isAny("send", "message") {
                if let recipient = chatTarget(arguments), let text = messageText(arguments) {
                    return resolved("qq_send_text", ["recipient": recipient, "text": text], "send and verify QQ text")
                }
                if let recipient = chatTarget(arguments) {
                    return resolved("qq_send_staged", ["recipient": recipient], "send staged QQ content after chat verification")
                }
            }
            if isAny("search", "find") {
                if let target = chatTarget(arguments) {
                    return resolved("qq_search_chat", ["name": target], "search QQ chat/contact")
                }
            }
            if isAny("open") {
                return resolved("qq_open", [:], "open QQ")
            }
        }

        if has("finder_list_directory") {
            if isAny("create", "mkdir", "folder") {
                if let path = firstString(arguments, ["path", "target", "folder"]) {
                    return resolved("finder_create_folder", ["path": path], "create Finder folder")
                }
            }
            if isAny("reveal", "open", "show") {
                if let path = firstString(arguments, ["path", "target", "file"]) {
                    return resolved("finder_reveal_file", ["path": path], "reveal path in Finder")
                }
            }
            if isAny("verify") {
                if let path = firstString(arguments, ["path", "target", "file"]) {
                    if let contains = firstString(arguments, ["contains", "text", "value"]) {
                        return resolved("finder_read_text_file", ["path": path, "contains": contains], "verify text file content")
                    }
                    return resolved("finder_file_info", ["path": path], "verify file or folder metadata")
                }
            }
            if isAny("read") {
                if let path = firstString(arguments, ["path", "target", "file"]) {
                    return resolved("finder_read_text_file", ["path": path], "read text file")
                }
            }
            if isAny("info", "metadata", "exists") {
                if let path = firstString(arguments, ["path", "target", "file", "folder"]) {
                    return resolved("finder_file_info", ["path": path], "read file or folder metadata")
                }
            }
            if isAny("find", "search") {
                if let needle = firstString(arguments, ["name_contains", "name", "query", "target"]) {
                    var args: [String: Any] = ["name_contains": needle]
                    if let root = firstString(arguments, ["root", "path", "directory"]) { args["root"] = root }
                    return resolved("finder_find_files", args, "find files by name")
                }
            }
            if let path = firstString(arguments, ["path", "directory", "root"]) {
                return resolved("finder_list_directory", ["path": path], "list Finder directory")
            }
            return resolved("finder_list_directory", arguments, "list Finder directory")
        }

        if has("textedit_new_document") {
            if isAny("save", "export") {
                if let path = firstString(arguments, ["path", "target", "file"]) {
                    var args: [String: Any] = ["path": path]
                    if let overwrite = bool(arguments["overwrite"]) { args["overwrite"] = overwrite }
                    return resolved("textedit_save_as", args, "save TextEdit document")
                }
            }
            if isAny("read", "verify") {
                return resolved("textedit_read_text", [:], "read TextEdit document")
            }
            if isAny("write", "type", "set", "create") {
                if let text = firstString(arguments, ["text", "body", "content", "value"]) {
                    return resolved("textedit_set_text", ["text": text], "write TextEdit document text")
                }
            }
            if isAny("open", "new", "create") {
                return resolved("textedit_new_document", [:], "open new TextEdit document")
            }
        }

        if has("notes_create_note") || has("reminders_create") {
            let routeText = normalizeForSearch([route.selectedSkill?.appName ?? "", route.package?.appName ?? "", route.query, op].joined(separator: " "))
            if routeText.contains("reminder"), isAny("create", "write", "remind"), let title = firstString(arguments, ["title", "target", "query", "text"]) {
                var args: [String: Any] = ["title": title]
                if let notes = firstString(arguments, ["notes", "body", "content", "value"]) { args["notes"] = notes }
                if let list = firstString(arguments, ["list"]) { args["list"] = list }
                return resolved("reminders_create", args, "create local reminder")
            }
            if isAny("search", "find") {
                if let query = firstString(arguments, ["query", "title", "target", "text"]) {
                    return resolved("notes_search", ["query": query], "search Notes")
                }
            }
            if isAny("create", "write", "note") {
                if let title = firstString(arguments, ["title", "target", "query"]) {
                    let body = firstString(arguments, ["body", "content", "text", "value", "notes"]) ?? ""
                    return resolved("notes_create_note", ["title": title, "body": body], "create local note")
                }
            }
        }

        if has("mail_compose_draft") || has("calendar_create_event") {
            let routeText = normalizeForSearch([route.selectedSkill?.appName ?? "", route.query, op].joined(separator: " "))
            if routeText.contains("calendar") || firstString(arguments, ["start", "end"]) != nil {
                if isAny("find", "search", "verify"), let title = firstString(arguments, ["title", "target", "query"]) {
                    return resolved("calendar_find_events", ["title": title, "days": int(arguments["days"]) ?? 30], "find Calendar events")
                }
                if let title = firstString(arguments, ["title", "target", "query"]),
                   let start = firstString(arguments, ["start", "start_at", "start_time"]),
                   let end = firstString(arguments, ["end", "end_at", "end_time"]) {
                    var args: [String: Any] = ["title": title, "start": start, "end": end]
                    if let calendar = firstString(arguments, ["calendar"]) { args["calendar"] = calendar }
                    if let notes = firstString(arguments, ["notes", "body", "text"]) { args["notes"] = notes }
                    return resolved("calendar_create_event", args, "create and verify Calendar event")
                }
            }
            if isAny("search", "find"), let query = firstString(arguments, ["query", "subject", "target"]) {
                return resolved("mail_search_messages", ["query": query], "search Mail messages")
            }
            if isAny("compose", "draft", "create", "write") {
                if let subject = firstString(arguments, ["subject", "title", "target", "query"]) {
                    var args: [String: Any] = [
                        "subject": subject,
                        "body": firstString(arguments, ["body", "content", "text", "value"]) ?? ""
                    ]
                    if let to = stringArrayIfPresent(arguments["to"] ?? arguments["recipient"] ?? arguments["recipients"]) { args["to"] = to }
                    if let attachments = stringArrayIfPresent(arguments["attachments"] ?? arguments["path"]) { args["attachments"] = attachments }
                    return resolved("mail_compose_draft", args, "compose visible Mail draft")
                }
            }
        }

        if has("safari_open_url") {
            if isAny("verify") {
                if firstString(arguments, ["url", "target"]) != nil {
                    return resolved("safari_get_current_url", [:], "verify Safari current URL")
                }
                if firstString(arguments, ["text", "value", "query"]) != nil {
                    return resolved("safari_get_page_text", [:], "verify Safari page text")
                }
            }
            if isAny("eval", "script"), let script = firstString(arguments, ["script", "javascript"]) {
                return resolved("safari_eval_js", ["script": script], "evaluate JavaScript in Safari")
            }
            if isAny("read", "observe", "extract") {
                return resolved("safari_get_page_text", [:], "read Safari page text")
            }
            if isAny("search"), let query = firstString(arguments, ["query", "target"]) {
                return resolved("safari_search", ["query": query], "search in Safari")
            }
            if let url = firstString(arguments, ["url", "target"]), URL(string: url) != nil {
                return resolved("safari_open_url", ["url": url], "open URL in Safari")
            }
            if isAny("open", "new") {
                return resolved("safari_new_tab", arguments, "open Safari tab")
            }
        }

        if has("chrome_open_url") {
            if isAny("verify") {
                if firstString(arguments, ["url", "target"]) != nil {
                    return resolved("chrome_get_current_tab", [:], "verify Chrome current URL")
                }
                if firstString(arguments, ["text", "value", "query"]) != nil {
                    return resolved("chrome_get_page_text", [:], "verify Chrome page text")
                }
            }
            if isAny("eval", "script"), let script = firstString(arguments, ["script", "javascript"]) {
                return resolved("chrome_eval_js", ["script": script], "evaluate JavaScript in Chrome")
            }
            if isAny("read", "observe", "extract") {
                return resolved("chrome_get_page_text", [:], "read Chrome page text")
            }
            if isAny("search"), let query = firstString(arguments, ["query", "target"]) {
                return resolved("chrome_search", ["query": query], "search in Chrome")
            }
            if let url = firstString(arguments, ["url", "target"]), URL(string: url) != nil {
                return resolved("chrome_open_url", ["url": url], "open URL in Chrome")
            }
            if isAny("open", "new") {
                return resolved("chrome_new_tab", arguments, "open Chrome tab")
            }
        }

        if has("libreoffice_export_pdf") || has("preview_open_file") || has("wps_open_file") {
            if isAny("export", "pdf") {
                if let path = firstString(arguments, ["path", "target", "file"]) {
                    var args: [String: Any] = ["path": path]
                    if let outdir = firstString(arguments, ["outdir", "output_dir"]) { args["outdir"] = outdir }
                    return resolved("libreoffice_export_pdf", args, "export document to PDF")
                }
            }
            if let path = firstString(arguments, ["path", "target", "file"]) {
                let routeText = normalizeForSearch([route.selectedSkill?.appName ?? "", route.query].joined(separator: " "))
                if routeText.contains("preview") {
                    return resolved("preview_open_file", ["path": path], "open file in Preview")
                }
                if routeText.contains("libreoffice") {
                    return resolved("libreoffice_open_file", ["path": path], "open file in LibreOffice")
                }
                return resolved("wps_open_file", ["path": path], "open file in WPS")
            }
        }

        if has("xcode_open_path") || has("pycharm_open_path") || has("rustrover_open_path") {
            if let path = firstString(arguments, ["path", "target", "file", "folder"]) {
                let routeText = normalizeForSearch([route.selectedSkill?.appName ?? "", route.query].joined(separator: " "))
                if routeText.contains("pycharm") {
                    return resolved("pycharm_open_path", ["path": path], "open path in PyCharm")
                }
                if routeText.contains("rustrover") {
                    return resolved("rustrover_open_path", ["path": path], "open path in RustRover")
                }
                return resolved("xcode_open_path", ["path": path], "open path in Xcode")
            }
        }

        if has("terminal_run_command"), let command = firstString(arguments, ["command", "script", "text", "query"]) {
            return resolved("terminal_run_command", ["command": command], "run Terminal command")
        }

        if has("shortcuts_run") {
            if isAny("list", "observe", "read") {
                return resolved("shortcuts_list", [:], "list Shortcuts")
            }
            if let name = firstString(arguments, ["name", "shortcut", "target", "query"]) {
                return resolved("shortcuts_run", ["name": name], "run Shortcut")
            }
        }

        if has("baidunetdisk_stage_file"), let path = firstString(arguments, ["path", "file_path", "attachment"]) {
            return resolved("baidunetdisk_stage_file", ["path": path], "stage Baidu Netdisk upload file")
        }
        if has("tencent_meeting_stage_join"), let meeting = firstString(arguments, ["meeting", "meeting_id", "url", "target", "query"]) {
            return resolved("tencent_meeting_stage_join", ["meeting": meeting], "stage Tencent Meeting join")
        }
        if has("todesk_stage_remote_id"), let remoteID = firstString(arguments, ["remote_id", "target", "query"]) {
            return resolved("todesk_stage_remote_id", ["remote_id": remoteID], "stage ToDesk remote id")
        }
        if isAny("open"), let openTool = route.tools.first(where: { $0.hasSuffix("_open") }) {
            return AppSkillResolvedAction(tool: openTool, arguments: [:], reason: "open app through app skill")
        }
        return nil
    }

    private static func firstString(_ args: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = string(args[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func chatTarget(_ args: [String: Any]) -> String? {
        firstString(args, ["recipient", "chat", "contact", "target", "name", "to"])
    }

    private static func messageText(_ args: [String: Any]) -> String? {
        firstString(args, ["text", "message", "body", "content", "value"])
    }

    private static func stringArrayIfPresent(_ value: Any?) -> [String]? {
        guard let value else { return nil }
        return try? stringArray(value, name: "value")
    }
}
