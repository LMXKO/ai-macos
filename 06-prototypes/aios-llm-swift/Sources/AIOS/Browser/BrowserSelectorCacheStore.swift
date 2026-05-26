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

struct BrowserSelectorCacheEntry: Codable {
    let id: String
    let urlKey: String
    let query: String
    let selector: String
    let action: String
    let successes: Int
    let failures: Int
    let updatedAt: String

    var dictionary: [String: String] {
        [
            "id": id,
            "url_key": urlKey,
            "query": query,
            "selector": selector,
            "action": action,
            "successes": "\(successes)",
            "failures": "\(failures)",
            "updated_at": updatedAt
        ]
    }
}

struct BrowserSelectorCacheStore {
    static var url: URL {
        EventStore.rootURL.appendingPathComponent("browser", isDirectory: true).appendingPathComponent("selector-cache.json")
    }

    static func lookup(url rawURL: String, query: String, action: String = "") -> BrowserSelectorCacheEntry? {
        let urlKey = key(for: rawURL)
        let normalizedQuery = normalizeForSearch(query)
        let normalizedAction = normalizeForSearch(action)
        return readAll()
            .filter { entry in
                entry.urlKey == urlKey &&
                    normalizeForSearch(entry.query) == normalizedQuery &&
                    (normalizedAction.isEmpty || normalizeForSearch(entry.action) == normalizedAction) &&
                    entry.successes >= entry.failures
            }
            .sorted { lhs, rhs in
                let lhsScore = lhs.successes - lhs.failures
                let rhsScore = rhs.successes - rhs.failures
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    @discardableResult
    static func record(url rawURL: String, query: String, selector: String, action: String, success: Bool) -> BrowserSelectorCacheEntry {
        let urlKey = key(for: rawURL)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAction = normalizeForSearch(action)
        var entries = readAll()
        let id = "\(urlKey)|\(normalizeID(normalizedQuery))|\(normalizeID(normalizedAction))"
        let existingIndex = entries.firstIndex { $0.id == id }
        let existing = existingIndex.map { entries[$0] }
        let entry = BrowserSelectorCacheEntry(
            id: id,
            urlKey: urlKey,
            query: normalizedQuery,
            selector: selector,
            action: normalizedAction,
            successes: (existing?.successes ?? 0) + (success ? 1 : 0),
            failures: (existing?.failures ?? 0) + (success ? 0 : 1),
            updatedAt: isoDateString(Date())
        )
        if let existingIndex {
            entries[existingIndex] = entry
        } else {
            entries.append(entry)
        }
        if entries.count > 2_000 {
            entries = Array(entries.sorted { $0.updatedAt < $1.updatedAt }.suffix(2_000))
        }
        try? writeAll(entries)
        return entry
    }

    static func list(query: String = "", limit: Int = 50) -> [BrowserSelectorCacheEntry] {
        let normalized = normalizeForSearch(query)
        return readAll()
            .filter { entry in
                normalized.isEmpty ||
                    normalizeForSearch([entry.urlKey, entry.query, entry.selector, entry.action].joined(separator: " ")).contains(normalized)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(min(200, max(1, limit)))
            .map { $0 }
    }

    static func readAll() -> [BrowserSelectorCacheEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([BrowserSelectorCacheEntry].self, from: data)
        else { return [] }
        return entries
    }

    private static func writeAll(_ entries: [BrowserSelectorCacheEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: [.atomic])
    }

    private static func key(for rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL), let host = components.host else {
            return normalizeID(rawURL)
        }
        let path = components.path.isEmpty ? "/" : components.path
        return normalizeID("\(host)\(path)")
    }
}
