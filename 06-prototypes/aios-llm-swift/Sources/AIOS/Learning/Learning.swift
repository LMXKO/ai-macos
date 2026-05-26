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

struct LearningSession: Codable {
    let id: String
    let title: String
    let startedAt: String
    var steps: [LearnedStep]
}

struct LearnedStep: Codable {
    let tool: String
    let arguments: [String: String]
    let success: Bool
    let evidence: String
    let recordedAt: String
}

struct LearningStore {
    static var activeURL: URL {
        EventStore.learningURL.appendingPathComponent("active.json")
    }

    static func start(title: String) throws -> LearningSession {
        try FileManager.default.createDirectory(at: EventStore.learningURL, withIntermediateDirectories: true)
        let session = LearningSession(
            id: "L\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))",
            title: title,
            startedAt: isoDateString(Date()),
            steps: []
        )
        try save(session)
        return session
    }

    static func record(tool: String, arguments: [String: Any], result: ToolResult) throws {
        var session = try active()
        let stringArgs = arguments.compactMapValues { value -> String? in
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            if let bool = value as? Bool { return bool ? "true" : "false" }
            return nil
        }
        session.steps.append(LearnedStep(
            tool: tool,
            arguments: stringArgs,
            success: result.success,
            evidence: result.evidence,
            recordedAt: isoDateString(Date())
        ))
        try save(session)
    }

    static func stop(recipeID: String) throws -> Recipe {
        let session = try active()
        guard !session.steps.isEmpty else {
            throw RuntimeError("Learning session has no recorded tool steps.")
        }
        let failedSteps = session.steps.enumerated().filter { !$0.element.success }
        guard failedSteps.isEmpty else {
            let failedSummary = failedSteps.map { "S\($0.offset + 1):\($0.element.tool)" }.joined(separator: ", ")
            throw RuntimeError("Learning session contains failed tool steps and cannot be saved as a verified recipe: \(failedSummary)")
        }
        let steps = session.steps.enumerated().map { index, learned in
            RecipeStep(
                id: "S\(index + 1)",
                title: learned.tool,
                tool: learned.tool,
                arguments: learned.arguments,
                verifyTool: nil,
                verifyArguments: nil,
                waitCondition: nil,
                waitValue: nil,
                verifyExpression: "success"
            )
        }
        let recipe = try RecipeStore.saveLearnedRecipe(
            id: recipeID,
            title: session.title,
            steps: steps,
            notes: "Learned from \(session.steps.count) verified successful tool step(s) at \(isoDateString(Date()))."
        )
        let archiveURL = EventStore.learningURL.appendingPathComponent("\(session.id).json")
        try FileManager.default.moveItem(at: activeURL, to: archiveURL)
        return recipe
    }

    static func statusText() throws -> String {
        guard FileManager.default.fileExists(atPath: activeURL.path) else {
            return "learning: inactive"
        }
        let session = try active()
        return [
            "learning: active",
            "id: \(session.id)",
            "title: \(session.title)",
            "steps: \(session.steps.count)",
            "started_at: \(session.startedAt)"
        ].joined(separator: "\n")
    }

    private static func active() throws -> LearningSession {
        guard FileManager.default.fileExists(atPath: activeURL.path) else {
            throw RuntimeError("No active learning session. Run: aios learn start \"title\"")
        }
        return try JSONDecoder().decode(LearningSession.self, from: Data(contentsOf: activeURL))
    }

    private static func save(_ session: LearningSession) throws {
        try FileManager.default.createDirectory(at: EventStore.learningURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: activeURL, options: [.atomic])
    }
}

struct RawRecordedEvent: Codable {
    let type: String
    let timestamp: Double
    let x: Double?
    let y: Double?
    let keyCode: Int?
    let flags: UInt64
    let app: String
    let bundleID: String
    let focusedRole: String
    let focusedTitle: String
    let focusedValue: String
}

final class RawEventRecorderBox {
    let start = Date()
    let includeAX: Bool
    var events: [RawRecordedEvent] = []

    init(includeAX: Bool) {
        self.includeAX = includeAX
    }

    func append(type: String, event: CGEvent) {
        let location = event.location
        let app = NSWorkspace.shared.frontmostApplication
        let focused = includeAX ? Self.focusedContext() : [:]
        events.append(RawRecordedEvent(
            type: type,
            timestamp: Date().timeIntervalSince(start),
            x: ["left_mouse_down", "left_mouse_up", "right_mouse_down", "right_mouse_up"].contains(type) ? location.x : nil,
            y: ["left_mouse_down", "left_mouse_up", "right_mouse_down", "right_mouse_up"].contains(type) ? location.y : nil,
            keyCode: type == "key_down" ? Int(event.getIntegerValueField(.keyboardEventKeycode)) : nil,
            flags: event.flags.rawValue,
            app: app?.localizedName ?? "",
            bundleID: app?.bundleIdentifier ?? "",
            focusedRole: focused["role"] ?? "",
            focusedTitle: focused["title"] ?? "",
            focusedValue: focused["value"] ?? ""
        ))
    }

    private static func focusedContext() -> [String: String] {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value.map({ unsafeDowncast($0, to: AXUIElement.self) })
        else {
            return [:]
        }
        func attr(_ attribute: CFString) -> String {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return "" }
            if let text = raw as? String { return text }
            if let number = raw as? NSNumber { return number.stringValue }
            return ""
        }
        return [
            "role": attr(kAXRoleAttribute as CFString),
            "title": attr(kAXTitleAttribute as CFString),
            "value": attr(kAXValueAttribute as CFString)
        ]
    }
}

struct RawEventRecorder {
    static func recordRecipe(title: String, recipeID: String, duration: Double, includeAX: Bool, synthesize: Bool = true) throws -> Recipe {
        guard duration > 0 else { throw RuntimeError("duration must be positive") }
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        let box = RawEventRecorderBox(includeAX: includeAX)
        let unmanagedBox = Unmanaged.passRetained(box)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: rawEventTapCallback,
            userInfo: unmanagedBox.toOpaque()
        ) else {
            unmanagedBox.release()
            throw RuntimeError("Could not create CGEvent tap. Grant Input Monitoring to this app/terminal and rerun setup.")
        }
        defer {
            CFMachPortInvalidate(tap)
            unmanagedBox.release()
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRunInMode(.defaultMode, duration, false)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)

        let rawURL = try saveRawEvents(box.events, recipeID: recipeID)
        let steps = synthesize ? semanticRecipeSteps(from: box.events) : exactReplaySteps(from: box.events)
        guard !steps.isEmpty else {
            throw RuntimeError("No replayable mouse/key events were captured.")
        }
        return try RecipeStore.saveLearnedRecipe(
            id: recipeID,
            title: title,
            steps: steps,
            notes: synthesize
                ? "Synthesized from \(box.events.count) raw CGEvent(s) plus AX focus context. Semantic steps prefer locator tools and keep original coordinates only as fallback. Raw log: \(rawURL.path). Run recipe exec to verify in the target app before relying on it."
                : "Unverified raw CGEvent recipe learned from \(box.events.count) event(s). Raw log: \(rawURL.path). Run recipe exec and add verifiers before relying on it."
        )
    }

    private static func saveRawEvents(_ events: [RawRecordedEvent], recipeID: String) throws -> URL {
        let dir = EventStore.learningURL.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(recipeID)-events.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(events).write(to: url, options: [.atomic])
        return url
    }

    private static func semanticRecipeSteps(from events: [RawRecordedEvent]) -> [RecipeStep] {
        var steps: [RecipeStep] = []
        var textBuffer = ""
        var textContext: RawRecordedEvent?

        func appendTextStep() {
            guard !textBuffer.isEmpty else { return }
            let text = textBuffer
            let context = textContext
            textBuffer = ""
            textContext = nil

            if let context {
                let label = bestLocatorText(for: context)
                if !label.isEmpty {
                    var arguments: [String: String] = [
                        "query": label,
                        "text": text,
                        "restore_focus": "true",
                        "allow_paste_fallback": "false"
                    ]
                    if !context.focusedRole.isEmpty {
                        arguments["role"] = context.focusedRole
                    }
                    if !context.bundleID.isEmpty {
                        arguments["bundle_id"] = context.bundleID
                    } else if !context.app.isEmpty {
                        arguments["app_name"] = context.app
                    }
                    var pasteArguments = arguments
                    pasteArguments["allow_paste_fallback"] = "true"
                    steps.append(RecipeStep(
                        id: "S\(steps.count + 1)",
                        title: "Type text",
                        tool: "aios_background_type",
                        arguments: arguments,
                        retries: 1,
                        fallbackTools: [
                            RecipeFallback(tool: "aios_type", arguments: pasteArguments)
                        ],
                        verifyExpression: "success"
                    ))
                    return
                }
            }

            steps.append(RecipeStep(
                id: "S\(steps.count + 1)",
                title: "Set clipboard text",
                tool: "clipboard_set_text",
                arguments: ["text": text],
                verifyExpression: "success"
            ))
            steps.append(RecipeStep(
                id: "S\(steps.count + 1)",
                title: "Paste clipboard text",
                tool: "ui_paste",
                arguments: [:],
                verifyExpression: "success"
            ))
        }

        for event in events {
            switch event.type {
            case "left_mouse_down":
                appendTextStep()
                guard let x = event.x, let y = event.y else { continue }
                let label = bestLocatorText(for: event)
                if !label.isEmpty {
                    var arguments: [String: String] = [
                        "query": label,
                        "restore_focus": "true",
                        "allow_coordinate_fallback": "false"
                    ]
                    if !event.focusedRole.isEmpty {
                        arguments["role"] = event.focusedRole
                    }
                    if !event.bundleID.isEmpty {
                        arguments["bundle_id"] = event.bundleID
                    } else if !event.app.isEmpty {
                        arguments["app_name"] = event.app
                    }
                    steps.append(RecipeStep(
                        id: "S\(steps.count + 1)",
                        title: "Click \(label)",
                        tool: "aios_background_click",
                        arguments: arguments,
                        retries: 1,
                        fallbackTools: [
                            RecipeFallback(tool: "visual_click", arguments: ["query": label]),
                            RecipeFallback(tool: "aios_click", arguments: arguments),
                            RecipeFallback(tool: "ui_click", arguments: ["x": "\(Int(x))", "y": "\(Int(y))"])
                        ],
                        verifyExpression: "success"
                    ))
                } else {
                    steps.append(RecipeStep(
                        id: "S\(steps.count + 1)",
                        title: "Click \(Int(x)),\(Int(y))",
                        tool: "ui_click",
                        arguments: ["x": "\(Int(x))", "y": "\(Int(y))"],
                        verifyExpression: "success"
                    ))
                }
            case "key_down":
                guard let keyCode = event.keyCode, keyCode != 0x35 else { continue }
                if let character = printableCharacter(for: CGKeyCode(keyCode), flags: CGEventFlags(rawValue: event.flags)) {
                    textBuffer.append(character)
                    textContext = event
                    continue
                }
                appendTextStep()
                let modifiers = modifierNames(from: CGEventFlags(rawValue: event.flags))
                steps.append(RecipeStep(
                    id: "S\(steps.count + 1)",
                    title: modifiers.isEmpty ? "Key \(keyCode)" : "\(modifiers.joined(separator: "+"))+\(keyName(for: CGKeyCode(keyCode)) ?? "\(keyCode)")",
                    tool: "ui_keyboard_shortcut",
                    arguments: [
                        "key": keyName(for: CGKeyCode(keyCode)) ?? "\(keyCode)",
                        "modifiers": modifiers.joined(separator: ",")
                    ],
                    verifyExpression: "success"
                ))
            default:
                continue
            }
        }
        appendTextStep()
        return coalescedSteps(steps)
    }

    private static func exactReplaySteps(from events: [RawRecordedEvent]) -> [RecipeStep] {
        var steps: [RecipeStep] = []
        for event in events {
            switch event.type {
            case "left_mouse_down":
                if let x = event.x, let y = event.y {
                    steps.append(RecipeStep(
                        id: "S\(steps.count + 1)",
                        title: "Click \(Int(x)),\(Int(y))",
                        tool: "ui_click",
                        arguments: ["x": "\(Int(x))", "y": "\(Int(y))"]
                    ))
                }
            case "key_down":
                guard let keyCode = event.keyCode else { continue }
                if keyCode == 0x35 {
                    continue
                }
                let modifiers = modifierNames(from: CGEventFlags(rawValue: event.flags))
                steps.append(RecipeStep(
                    id: "S\(steps.count + 1)",
                    title: "Key \(keyCode)",
                    tool: "ui_keyboard_shortcut",
                    arguments: [
                        "key": keyName(for: CGKeyCode(keyCode)) ?? "\(keyCode)",
                        "modifiers": modifiers.joined(separator: ",")
                    ]
                ))
            default:
                continue
            }
        }
        return steps
    }

    private static func bestLocatorText(for event: RawRecordedEvent) -> String {
        [event.focusedTitle, event.focusedValue]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.count <= 80 } ?? ""
    }

    private static func coalescedSteps(_ steps: [RecipeStep]) -> [RecipeStep] {
        var output: [RecipeStep] = []
        for step in steps {
            if let last = output.last,
               last.tool == step.tool,
               last.arguments == step.arguments {
                continue
            }
            output.append(RecipeStep(
                id: "S\(output.count + 1)",
                title: step.title,
                tool: step.tool,
                arguments: step.arguments,
                preconditions: step.preconditions,
                verifyTool: step.verifyTool,
                verifyArguments: step.verifyArguments,
                waitCondition: step.waitCondition,
                waitValue: step.waitValue,
                retries: step.retries,
                fallbackTools: step.fallbackTools,
                verifyExpression: step.verifyExpression,
                postconditions: step.postconditions,
                recoverySteps: step.recoverySteps,
                timeout: step.timeout
            ))
        }
        return output
    }

    private static func modifierNames(from flags: CGEventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("command") }
        if flags.contains(.maskShift) { names.append("shift") }
        if flags.contains(.maskAlternate) { names.append("option") }
        if flags.contains(.maskControl) { names.append("control") }
        return names
    }

    private static func printableCharacter(for code: CGKeyCode, flags: CGEventFlags) -> String? {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return nil
        }
        let shifted = flags.contains(.maskShift)
        if let key = keyName(for: code),
           key.count == 1,
           key.range(of: "[a-zA-Z]", options: .regularExpression) != nil {
            let text = shifted ? key.uppercased() : key
            return text
        }
        let base: [CGKeyCode: (String, String)] = [
            18: ("1", "!"),
            19: ("2", "@"),
            20: ("3", "#"),
            21: ("4", "$"),
            23: ("5", "%"),
            22: ("6", "^"),
            26: ("7", "&"),
            28: ("8", "*"),
            25: ("9", "("),
            29: ("0", ")"),
            24: ("=", "+"),
            27: ("-", "_"),
            30: ("]", "}"),
            33: ("[", "{"),
            39: ("'", "\""),
            41: (";", ":"),
            42: ("\\", "|"),
            43: (",", "<"),
            44: ("/", "?"),
            47: (".", ">"),
            49: (" ", " "),
            50: ("`", "~")
        ]
        guard let pair = base[code] else { return nil }
        return shifted ? pair.1 : pair.0
    }

    private static func keyName(for code: CGKeyCode) -> String? {
        let map: [CGKeyCode: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 36: "return",
            37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n",
            46: "m", 47: ".", 48: "tab", 49: "space", 50: "`", 51: "delete", 53: "escape",
            123: "left", 124: "right", 125: "down", 126: "up"
        ]
        return map[code]
    }
}

func rawEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<RawEventRecorderBox>.fromOpaque(refcon).takeUnretainedValue()
    let name: String?
    switch type {
    case .leftMouseDown:
        name = "left_mouse_down"
    case .leftMouseUp:
        name = "left_mouse_up"
    case .rightMouseDown:
        name = "right_mouse_down"
    case .rightMouseUp:
        name = "right_mouse_up"
    case .keyDown:
        name = "key_down"
    default:
        name = nil
    }
    if let name {
        box.append(type: name, event: event)
    }
    return Unmanaged.passUnretained(event)
}
