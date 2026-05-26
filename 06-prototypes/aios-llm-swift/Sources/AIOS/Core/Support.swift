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

struct ToolResult: Codable {
    let success: Bool
    let evidence: String
    var data: [String: String] = [:]
    var error: String?
    var suggestion: String?

    var jsonString: String {
        let safe = ToolResult(
            success: success,
            evidence: truncateMiddle(evidence, maxCharacters: 4_000),
            data: data.mapValues { truncateMiddle($0, maxCharacters: 8_000) },
            error: error.map { truncateMiddle($0, maxCharacters: 4_000) },
            suggestion: suggestion.map { truncateMiddle($0, maxCharacters: 2_000) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(safe)) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"success":false,"evidence":"encoding failed"}"#
    }
}

final class ToolResultAsyncBox: @unchecked Sendable {
    var result: Result<ToolResult, Error>?
}

struct VisualMatch {
    let id: String
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let imagePath: String

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }

    var dictionary: [String: String] {
        [
            "id": id,
            "text": text,
            "confidence": String(format: "%.3f", confidence),
            "x": "\(Int(x))",
            "y": "\(Int(y))",
            "width": "\(Int(width))",
            "height": "\(Int(height))",
            "center_x": "\(Int(centerX))",
            "center_y": "\(Int(centerY))",
            "image_path": imagePath
        ]
    }
}

final class CDPResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<String, Error>

    init(_ result: Result<String, Error>) {
        self.stored = result
    }

    func set(_ result: Result<String, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func get() -> Result<String, Error> {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class CDPJSONResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<[String: Any], Error>

    init(_ result: Result<[String: Any], Error>) {
        self.stored = result
    }

    func set(_ result: Result<[String: Any], Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func get() -> Result<[String: Any], Error> {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

struct VisionSidecar {
    static var isConfigured: Bool {
        let env = ProcessInfo.processInfo.environment
        return !(env["AIOS_VISION_BASE_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !(env["AIOS_VISION_MODEL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func analyze(imagePath: String, prompt: String, timeout: TimeInterval = 30) throws -> String {
        let env = ProcessInfo.processInfo.environment
        guard let rawBase = env["AIOS_VISION_BASE_URL"], !rawBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("AIOS_VISION_BASE_URL is not configured.")
        }
        guard let model = env["AIOS_VISION_MODEL"], !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("AIOS_VISION_MODEL is not configured.")
        }
        let url = chatCompletionsURL(from: rawBase)
        let imageURL = try dataURL(forImagePath: imagePath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = env["AIOS_VISION_API_KEY"] ?? env["AIOS_LLM_API_KEY"], !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": imageURL]]
                ]
            ]],
            "temperature": 0.1
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let semaphore = DispatchSemaphore(value: 0)
        let output = CDPResultBox(.failure(RuntimeError("Vision sidecar timed out.")))
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            defer {
                session.invalidateAndCancel()
                semaphore.signal()
            }
            if let error {
                output.set(.failure(error))
                return
            }
            let data = data ?? Data()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                output.set(.failure(RuntimeError("Vision HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")))
                return
            }
            do {
                output.set(.success(try parseVisionAnswer(data)))
            } catch {
                output.set(.failure(error))
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        return try output.get().get()
    }

    private static func chatCompletionsURL(from rawValue: String) -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/chat/completions") { return URL(string: trimmed)! }
        let base = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/chat/completions")!
    }

    private static func dataURL(forImagePath path: String) throws -> String {
        let url = URL(fileURLWithPath: path.expandingTildeInPath)
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : ext == "webp" ? "image/webp" : "image/png"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func parseVisionAnswer(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            throw RuntimeError("Vision response did not contain choices[0].message")
        }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        return jsonStringValue(message)
    }
}

struct ChromeCDP {
    struct Endpoint {
        let host: String
        let port: Int

        var base: URL {
            URL(string: "http://\(host):\(port)")!
        }
    }

    struct Tab {
        let id: String
        let type: String
        let title: String
        let url: String
        let webSocketDebuggerURL: String

        var dictionary: [String: String] {
            [
                "id": id,
                "type": type,
                "title": title,
                "url": url,
                "web_socket_debugger_url": webSocketDebuggerURL
            ]
        }
    }

    static func version(endpoint: Endpoint) throws -> [String: String] {
        let url = endpoint.base.appendingPathComponent("json/version")
        let data = try Data(contentsOf: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeError("Invalid CDP version response.")
        }
        return raw.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String {
                result[pair.key] = value
            } else if let value = pair.value as? NSNumber {
                result[pair.key] = value.stringValue
            }
        }
    }

    static func tabs(endpoint: Endpoint) throws -> [Tab] {
        let url = endpoint.base.appendingPathComponent("json/list")
        let data = try Data(contentsOf: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw RuntimeError("Invalid CDP tabs response.")
        }
        return raw.compactMap { item in
            guard let id = string(item["id"]),
                  let ws = string(item["webSocketDebuggerUrl"])
            else { return nil }
            return Tab(
                id: id,
                type: string(item["type"]) ?? "",
                title: string(item["title"]) ?? "",
                url: string(item["url"]) ?? "",
                webSocketDebuggerURL: ws
            )
        }
    }

    static func evaluate(tab: Tab, expression: String, timeout: TimeInterval = 8) throws -> String {
        guard let url = URL(string: tab.webSocketDebuggerURL) else {
            throw RuntimeError("Invalid CDP websocket URL.")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url)
        let output = CDPResultBox(.failure(RuntimeError("CDP websocket timed out.")))
        let payload: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression,
                "awaitPromise": true,
                "returnByValue": true,
                "userGesture": true
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        socket.resume()
        socket.send(.string(text)) { error in
            if let error {
                output.set(.failure(error))
                semaphore.signal()
                return
            }
            socket.receive { result in
                defer {
                    socket.cancel(with: .normalClosure, reason: nil)
                    session.invalidateAndCancel()
                    semaphore.signal()
                }
                switch result {
                case .failure(let error):
                    output.set(.failure(error))
                case .success(let message):
                    let responseText: String
                    switch message {
                    case .string(let text):
                        responseText = text
                    case .data(let data):
                        responseText = String(data: data, encoding: .utf8) ?? ""
                    @unknown default:
                        responseText = ""
                    }
                    output.set(.success(extractEvaluationResult(responseText)))
                }
            }
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return try output.get().get()
    }

    static func call(tab: Tab, method: String, params: [String: Any] = [:], timeout: TimeInterval = 8) throws -> [String: Any] {
        guard let url = URL(string: tab.webSocketDebuggerURL) else {
            throw RuntimeError("Invalid CDP websocket URL.")
        }
        let requestID = Int.random(in: 10_000...999_999)
        let semaphore = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url)
        let output = CDPJSONResultBox(.failure(RuntimeError("CDP websocket timed out.")))
        let payload: [String: Any] = ["id": requestID, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8) ?? "{}"

        @Sendable func receiveUntilResponse() {
            socket.receive { result in
                switch result {
                case .failure(let error):
                    output.set(.failure(error))
                    socket.cancel(with: .normalClosure, reason: nil)
                    session.invalidateAndCancel()
                    semaphore.signal()
                case .success(let message):
                    let responseText: String
                    switch message {
                    case .string(let text):
                        responseText = text
                    case .data(let data):
                        responseText = String(data: data, encoding: .utf8) ?? ""
                    @unknown default:
                        responseText = ""
                    }
                    guard let rawData = responseText.data(using: .utf8),
                          let raw = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
                    else {
                        receiveUntilResponse()
                        return
                    }
                    if let id = raw["id"] as? Int, id == requestID {
                        if let error = raw["error"] {
                            output.set(.failure(RuntimeError(jsonStringValue(error))))
                        } else {
                            output.set(.success(raw))
                        }
                        socket.cancel(with: .normalClosure, reason: nil)
                        session.invalidateAndCancel()
                        semaphore.signal()
                    } else {
                        receiveUntilResponse()
                    }
                }
            }
        }

        socket.resume()
        socket.send(.string(text)) { error in
            if let error {
                output.set(.failure(error))
                semaphore.signal()
                return
            }
            receiveUntilResponse()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return try output.get().get()
    }

    private static func extractEvaluationResult(_ responseText: String) -> String {
        guard let data = responseText.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return responseText }
        if let error = raw["error"] {
            return jsonStringValue(error)
        }
        guard let result = raw["result"] as? [String: Any],
              let nested = result["result"] as? [String: Any]
        else { return responseText }
        if let value = nested["value"] {
            return jsonStringValue(value)
        }
        if let description = nested["description"] as? String {
            return description
        }
        return jsonStringValue(nested)
    }
}

func javascriptLiteral(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
    let encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
    return String(encoded.dropFirst().dropLast())
}

struct RuntimeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
    [
        "type": "function",
        "function": [
            "name": name,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ]
        ]
    ]
}

func schema(_ type: String, _ description: String) -> [String: Any] {
    ["type": type, "description": description]
}

func arraySchema(_ itemType: String, _ description: String) -> [String: Any] {
    [
        "type": "array",
        "description": description,
        "items": ["type": itemType]
    ]
}

func arrayObjectSchema(_ description: String, _ properties: [String: Any], required: [String] = ["id", "title", "goal", "verification"]) -> [String: Any] {
    [
        "type": "array",
        "description": description,
        "items": [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    ]
}

func runAppleScript(_ source: String) throws -> String {
    guard let script = NSAppleScript(source: source) else {
        throw RuntimeError("Could not compile AppleScript")
    }
    var error: NSDictionary?
    let output = script.executeAndReturnError(&error)
    if let error {
        throw RuntimeError("AppleScript failed: \(error)")
    }
    return output.stringValue ?? ""
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        throw RuntimeError(output.isEmpty ? "\(executable) failed" : output)
    }
    return output
}

func appleScriptString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

func string(_ value: Any?) -> String? {
    value as? String
}

func bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
    return nil
}

func int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

func double(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

func intArgument(_ args: [String], name: String) -> Int? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return Int(args[index + 1])
}

func doubleArgument(_ args: [String], name: String) -> Double? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return Double(args[index + 1])
}

func stringArgument(_ args: [String], name: String) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

func positionalArguments<S: Sequence>(_ args: S) -> [String] where S.Element == String {
    var values: [String] = []
    var skipNext = false
    let optionsWithValues: Set<String> = ["--repeat", "--seconds", "--recipe-id"]
    for arg in args {
        if skipNext {
            skipNext = false
            continue
        }
        if optionsWithValues.contains(arg) {
            skipNext = true
            continue
        }
        if arg.hasPrefix("--") {
            continue
        }
        values.append(arg)
    }
    return values
}

func stringArray(_ value: Any?, name: String) throws -> [String] {
    if let strings = value as? [String] {
        return strings
    }
    if let text = value as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array.compactMap { $0 as? String }
        }
        return trimmed
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    if let array = value as? [Any] {
        return array.compactMap { $0 as? String }
    }
    throw RuntimeError("\(name) must be an array of strings")
}

func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

func jsonLine(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return "\(value)"
    }
    return text
}

func jsonStringValue(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return "\(value)"
    }
    return text
}

func parseJSONObject(_ text: String) throws -> [String: Any] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    let data = Data(trimmed.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RuntimeError("Expected a JSON object")
    }
    return object
}

func writeJSONObject(_ value: Any, to url: URL) throws {
    guard JSONSerialization.isValidJSONObject(value) else {
        throw RuntimeError("Value is not valid JSON")
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: [.atomic])
}

func isoDateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

func isoDate(from text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) {
        return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
}

func truncateMiddle(_ text: String, maxCharacters: Int) -> String {
    guard text.count > maxCharacters else { return text }
    let markerBudget = 64
    let keep = max(0, (maxCharacters - markerBudget) / 2)
    let head = text.prefix(keep)
    let tail = text.suffix(keep)
    let omitted = text.count - head.count - tail.count
    return "\(head)\n...[truncated \(omitted) chars]...\n\(tail)"
}

extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
