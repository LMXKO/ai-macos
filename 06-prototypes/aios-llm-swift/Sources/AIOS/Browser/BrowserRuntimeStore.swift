import Foundation

struct BrowserRuntimeSession: Codable {
    let id: String
    let name: String
    let endpoint: String
    let profileDir: String
    let urlHint: String
    let status: String
    let createdAt: String
    let updatedAt: String

    var dictionary: [String: String] {
        [
            "id": id,
            "name": name,
            "endpoint": endpoint,
            "profile_dir": profileDir,
            "url_hint": urlHint,
            "status": status,
            "created_at": createdAt,
            "updated_at": updatedAt
        ]
    }
}

struct BrowserRuntimeStore {
    static var rootURL: URL {
        EventStore.rootURL.appendingPathComponent("browser-runtime", isDirectory: true)
    }

    static var sessionsURL: URL {
        rootURL.appendingPathComponent("sessions.json")
    }

    static func upsertSession(name: String, endpoint: String, profileDir: String, urlHint: String = "", status: String = "planned") throws -> BrowserRuntimeSession {
        var sessions = list()
        let id = normalizeID(name.isEmpty ? endpoint : name)
        let now = isoDateString(Date())
        let existing = sessions.first { $0.id == id }
        let session = BrowserRuntimeSession(
            id: id,
            name: name.isEmpty ? id : name,
            endpoint: endpoint,
            profileDir: profileDir,
            urlHint: urlHint,
            status: status,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        sessions.removeAll { $0.id == id }
        sessions.append(session)
        try write(sessions)
        return session
    }

    static func list() -> [BrowserRuntimeSession] {
        guard let data = try? Data(contentsOf: sessionsURL),
              let sessions = try? JSONDecoder().decode([BrowserRuntimeSession].self, from: data)
        else { return [] }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func plan(goal: String, url: String = "") -> [String: String] {
        let cache = BrowserSelectorCacheStore.list(query: goal, limit: 8)
        let session = list().first
        return [
            "runtime": "browser-runtime-v1",
            "goal": goal,
            "preferred_channel": "browser_cdp_dom",
            "session_id": session?.id ?? "",
            "endpoint": session?.endpoint ?? "http://127.0.0.1:9222",
            "url": url,
            "observe": "browser_cdp_observe",
            "act": "browser_cdp_act",
            "extract": "browser_cdp_extract",
            "wait": "browser_cdp_wait",
            "selector_cache": jsonStringValue(cache.map(\.dictionary)),
            "long_task_contract": "Keep the CDP profile stable, observe before act, cache successful selectors, wait on DOM/network conditions, export session snapshots."
        ]
    }

    static func snapshot(sessionID: String? = nil) -> [String: String] {
        let sessions = list()
        let selected = sessionID.flatMap { id in sessions.first { $0.id == id } } ?? sessions.first
        let cache = BrowserSelectorCacheStore.list(query: "", limit: 40)
        return [
            "schema": "aios.browser.runtime.snapshot.v1",
            "selected_session": selected.map { jsonStringValue($0.dictionary) } ?? "",
            "sessions": jsonStringValue(sessions.map(\.dictionary)),
            "selector_cache": jsonStringValue(cache.map(\.dictionary)),
            "capabilities": "cdp_tabs,cdp_eval,observe,act,extract,wait,network_idle,file_upload,download_behavior,selector_cache"
        ]
    }

    private static func write(_ sessions: [BrowserRuntimeSession]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sessions).write(to: sessionsURL, options: [.atomic])
    }
}
