import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AIOSWindowSnapshot: Codable {
    let id: UInt32
    let title: String
    let ownerName: String
    let pid: Int32
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct AIOSLocator: Codable {
    let id: String
    let appName: String
    let bundleID: String
    let pid: Int32
    let role: String
    let title: String
    let value: String
    let description: String
    let identifier: String
    let domID: String
    let enabled: Bool
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let path: String

    var labelText: String {
        [title, value, description, identifier, domID]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " | ")
    }
}

struct AIOSLocatedElement {
    let locator: AIOSLocator
    let element: AXUIElement
}

@MainActor
final class AIOSAutomationService {
    static let shared = AIOSAutomationService()

    private var elementStore: [String: AXUIElement] = [:]
    private var locatorStore: [String: AIOSLocator] = [:]
    private var generation = 0

    private init() {}

    func context(args: [String: Any] = [:]) -> ToolResult {
        let app = resolveApplication(args: args) ?? NSWorkspace.shared.frontmostApplication
        let windows = visibleWindows(pid: app?.processIdentifier)
        let payload: [String: Any] = [
            "frontmost_app": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            "frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "target_app": app?.localizedName ?? "",
            "target_bundle_id": app?.bundleIdentifier ?? "",
            "target_pid": app?.processIdentifier ?? 0,
            "windows": windows.map { windowDict($0) }
        ]
        return ToolResult(
            success: true,
            evidence: "Observed macOS automation context.",
            data: compactData(payload)
        )
    }

    func find(args: [String: Any]) -> ToolResult {
        let query = text(args["query"]).lowercased()
        let roleFilter = text(args["role"]).lowercased()
        let maxDepth = integer(args["max_depth"]) ?? 8
        let maxResults = integer(args["max_results"]) ?? 50
        guard let app = resolveApplication(args: args) ?? NSWorkspace.shared.frontmostApplication else {
            return ToolResult(success: false, evidence: "No target application.", error: "No frontmost or matching app.")
        }

        let matches = locate(
            app: app,
            query: query,
            role: roleFilter,
            maxDepth: maxDepth,
            maxResults: maxResults
        )
        let locatorJSON = jsonString(matches.map { locatorDict($0.locator) })
        let evidence = matches.isEmpty
            ? "No matching UI element found."
            : "Found \(matches.count) matching UI element(s)."
        return ToolResult(
            success: !matches.isEmpty,
            evidence: evidence,
            data: [
                "app": app.localizedName ?? "",
                "bundle_id": app.bundleIdentifier ?? "",
                "locators": locatorJSON
            ],
            error: matches.isEmpty ? "element_not_found" : nil,
            suggestion: matches.isEmpty ? "Try a broader query, inspect the app context, or use screenshot/OCR fallback." : nil
        )
    }

    func inspect(args: [String: Any]) -> ToolResult {
        guard let located = resolveLocatedElement(args: args) else {
            return ToolResult(success: false, evidence: "No matching UI element to inspect.", error: "element_not_found")
        }
        let actions = actionNames(located.element)
        let attrs = attributeNames(located.element)
        var payload = locatorDict(located.locator)
        payload["actions"] = actions
        payload["attributes"] = attrs
        return ToolResult(
            success: true,
            evidence: "Inspected UI element \(located.locator.id).",
            data: compactData(payload)
        )
    }

    func read(args: [String: Any]) -> ToolResult {
        let maxChars = integer(args["max_chars"]) ?? 6_000
        let query = text(args["query"])
        let role = text(args["role"])
        let elements: [AIOSLocatedElement]
        if !query.isEmpty || !role.isEmpty || text(args["locator_id"]).isEmpty == false {
            elements = resolveLocatedElement(args: args).map { [$0] } ?? []
        } else {
            guard let app = resolveApplication(args: args) ?? NSWorkspace.shared.frontmostApplication else {
                return ToolResult(success: false, evidence: "No target application.", error: "No frontmost or matching app.")
            }
            elements = locate(app: app, query: "", role: "", maxDepth: integer(args["max_depth"]) ?? 8, maxResults: integer(args["max_results"]) ?? 120)
        }

        let lines = elements
            .map { $0.locator.labelText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = truncate(lines.joined(separator: "\n"), max: maxChars)
        return ToolResult(
            success: !joined.isEmpty,
            evidence: joined.isEmpty ? "No readable UI text found." : "Read UI text from \(elements.count) element(s).",
            data: [
                "text": joined,
                "elements": "\(elements.count)"
            ],
            error: joined.isEmpty ? "no_text" : nil
        )
    }

    func click(args: [String: Any]) -> ToolResult {
        let restoreFocus = boolean(args["restore_focus"]) ?? true
        guard let located = resolveLocatedElement(args: args) else {
            return ToolResult(success: false, evidence: "No matching UI element to click.", error: "element_not_found")
        }
        let previous = restoreFocus ? FocusSnapshot.capture() : nil
        let actions = actionNames(located.element)
        if actions.contains("AXPress") {
            let error = AXUIElementPerformAction(located.element, kAXPressAction as CFString)
            previous?.restore()
            return ToolResult(
                success: error == .success,
                evidence: error == .success ? "Pressed \(located.locator.id) with AXPress." : "AXPress failed for \(located.locator.id).",
                data: compactData(locatorDict(located.locator).merging(["method": "AXPress"]) { lhs, _ in lhs }),
                error: error == .success ? nil : "AXPress \(error.rawValue)",
                suggestion: error == .success ? nil : "Try a coordinate click or a different locator."
            )
        }

        guard let point = center(of: located.locator) else {
            previous?.restore()
            return ToolResult(success: false, evidence: "Element has no usable bounds.", error: "missing_bounds")
        }
        postMouseClick(at: point)
        previous?.restore()
        return ToolResult(
            success: true,
            evidence: "Clicked \(located.locator.id) at \(Int(point.x)),\(Int(point.y)).",
            data: compactData(locatorDict(located.locator).merging(["method": "coordinate"]) { lhs, _ in lhs })
        )
    }

    func type(args: [String: Any]) -> ToolResult {
        let value = text(args["text"])
        guard !value.isEmpty else {
            return ToolResult(success: false, evidence: "No text provided.", error: "text_required")
        }
        let restoreFocus = boolean(args["restore_focus"]) ?? true
        guard let located = resolveLocatedElement(args: args) else {
            return ToolResult(success: false, evidence: "No matching UI element to type into.", error: "element_not_found")
        }
        let previous = restoreFocus ? FocusSnapshot.capture() : nil

        let setValueError = AXUIElementSetAttributeValue(located.element, kAXValueAttribute as CFString, value as CFTypeRef)
        if setValueError == .success {
            previous?.restore()
            return ToolResult(
                success: true,
                evidence: "Set AXValue on \(located.locator.id).",
                data: compactData(locatorDict(located.locator).merging(["method": "AXValue"]) { lhs, _ in lhs })
            )
        }

        guard let point = center(of: located.locator) else {
            previous?.restore()
            return ToolResult(success: false, evidence: "Element has no usable bounds.", error: "missing_bounds")
        }
        postMouseClick(at: point)
        paste(text: value)
        previous?.restore()
        return ToolResult(
            success: true,
            evidence: "Clicked \(located.locator.id) and pasted text.",
            data: compactData(locatorDict(located.locator).merging(["method": "paste", "chars": "\(value.count)"]) { lhs, _ in lhs })
        )
    }

    func wait(args: [String: Any]) -> ToolResult {
        let condition = text(args["condition"]).lowercased()
        let timeout = max(0.1, number(args["timeout"]) ?? 10)
        let interval = max(0.1, number(args["interval"]) ?? 0.5)
        let start = Date()
        var last = ToolResult(success: false, evidence: "Waiting.", error: "timeout")

        while Date().timeIntervalSince(start) < timeout {
            switch condition {
            case "element_exists":
                let result = find(args: args)
                if result.success { return result.withEvidence("Wait condition met: element exists.") }
                last = result
            case "element_gone":
                let result = find(args: args)
                if !result.success {
                    return ToolResult(success: true, evidence: "Wait condition met: element is gone.")
                }
                last = result
            case "text_contains":
                let result = read(args: args)
                let value = text(args["value"]).lowercased()
                if result.data["text"]?.lowercased().contains(value) == true {
                    return result.withEvidence("Wait condition met: text contains value.")
                }
                last = result
            case "frontmost_app":
                let expected = text(args["value"]).lowercased()
                let app = NSWorkspace.shared.frontmostApplication
                let haystack = [app?.localizedName ?? "", app?.bundleIdentifier ?? ""].joined(separator: " ").lowercased()
                if haystack.contains(expected) {
                    return ToolResult(success: true, evidence: "Wait condition met: frontmost app matches.", data: [
                        "app": app?.localizedName ?? "",
                        "bundle_id": app?.bundleIdentifier ?? ""
                    ])
                }
                last = ToolResult(success: false, evidence: "Current frontmost app is \(app?.localizedName ?? "unknown").", data: [
                    "app": app?.localizedName ?? "",
                    "bundle_id": app?.bundleIdentifier ?? ""
                ], error: "condition_not_met")
            case "window_title_contains":
                let value = text(args["value"]).lowercased()
                let windows = visibleWindows(pid: resolveApplication(args: args)?.processIdentifier)
                if windows.contains(where: { $0.title.lowercased().contains(value) }) {
                    return ToolResult(success: true, evidence: "Wait condition met: window title contains value.", data: [
                        "windows": jsonString(windows.map { windowDict($0) })
                    ])
                }
                last = ToolResult(success: false, evidence: "No visible window title contained \(value).", data: [
                    "windows": jsonString(windows.map { windowDict($0) })
                ], error: "condition_not_met")
            default:
                return ToolResult(success: false, evidence: "Unknown wait condition.", error: "unknown_condition")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }

        return ToolResult(
            success: false,
            evidence: "Timed out waiting for \(condition). Last evidence: \(last.evidence)",
            data: last.data,
            error: "timeout",
            suggestion: "Observe context, broaden the locator, or use screenshot/OCR fallback."
        )
    }

    private func resolveLocatedElement(args: [String: Any]) -> AIOSLocatedElement? {
        if let id = optionalText(args["locator_id"]) ?? optionalText(args["element_id"]),
           let element = elementStore[id],
           let locator = locatorStore[id] {
            return AIOSLocatedElement(locator: locator, element: element)
        }
        let query = text(args["query"]).lowercased()
        let role = text(args["role"]).lowercased()
        guard let app = resolveApplication(args: args) ?? NSWorkspace.shared.frontmostApplication else { return nil }
        return locate(app: app, query: query, role: role, maxDepth: integer(args["max_depth"]) ?? 8, maxResults: 1).first
    }

    private func locate(app: NSRunningApplication, query: String, role: String, maxDepth: Int, maxResults: Int) -> [AIOSLocatedElement] {
        generation += 1
        if generation > 10_000 {
            generation = 1
            elementStore.removeAll()
            locatorStore.removeAll()
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var results: [AIOSLocatedElement] = []
        var visited = 0

        func walk(_ element: AXUIElement, depth: Int, path: String) {
            guard depth <= maxDepth, results.count < maxResults, visited < 2_000 else { return }
            visited += 1
            let locator = makeLocator(element: element, app: app, path: path, index: visited)
            let haystack = [
                locator.role,
                locator.title,
                locator.value,
                locator.description,
                locator.identifier,
                locator.domID
            ].joined(separator: "\n").lowercased()
            let queryMatches = query.isEmpty || haystack.contains(query)
            let roleMatches = role.isEmpty || locator.role.lowercased().contains(role)
            if queryMatches && roleMatches {
                store(locator: locator, element: element)
                results.append(AIOSLocatedElement(locator: locator, element: element))
            }
            for child in children(of: element) {
                walk(child, depth: depth + 1, path: "\(path).\(visited)")
            }
        }

        walk(appElement, depth: 0, path: "root")
        return results
    }

    private func store(locator: AIOSLocator, element: AXUIElement) {
        elementStore[locator.id] = element
        locatorStore[locator.id] = locator
    }

    private func makeLocator(element: AXUIElement, app: NSRunningApplication, path: String, index: Int) -> AIOSLocator {
        let role = attrString(element, kAXRoleAttribute as CFString)
        let title = attrString(element, kAXTitleAttribute as CFString)
        let value = attrString(element, kAXValueAttribute as CFString)
        let description = attrString(element, kAXDescriptionAttribute as CFString)
        let identifier = attrString(element, "AXIdentifier" as CFString)
        let domID = attrString(element, "AXDOMIdentifier" as CFString)
        let enabled = attrBool(element, kAXEnabledAttribute as CFString) ?? true
        let rect = bounds(element)
        let idSeed = [
            app.bundleIdentifier ?? app.localizedName ?? "app",
            role,
            title,
            value,
            description,
            identifier,
            domID,
            path,
            "\(generation)",
            "\(index)"
        ].joined(separator: "|")
        let id = "E\(abs(idSeed.hashValue))"
        return AIOSLocator(
            id: id,
            appName: app.localizedName ?? "",
            bundleID: app.bundleIdentifier ?? "",
            pid: app.processIdentifier,
            role: role,
            title: title,
            value: value,
            description: description,
            identifier: identifier,
            domID: domID,
            enabled: enabled,
            x: rect.map { Double($0.origin.x) },
            y: rect.map { Double($0.origin.y) },
            width: rect.map { Double($0.size.width) },
            height: rect.map { Double($0.size.height) },
            path: path
        )
    }

    private func resolveApplication(args: [String: Any]) -> NSRunningApplication? {
        if let bundleID = optionalText(args["bundle_id"]) {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        if let appName = optionalText(args["app_name"]) ?? optionalText(args["app"]) {
            let needle = appName.lowercased()
            return NSWorkspace.shared.runningApplications.first { app in
                (app.localizedName ?? "").lowercased().contains(needle) ||
                (app.bundleIdentifier ?? "").lowercased().contains(needle)
            }
        }
        return nil
    }

    private func visibleWindows(pid: pid_t?) -> [AIOSWindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { item in
            let ownerPID = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if let pid, ownerPID != pid { return nil }
            guard let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return AIOSWindowSnapshot(
                id: (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                title: item[kCGWindowName as String] as? String ?? "",
                ownerName: item[kCGWindowOwnerName as String] as? String ?? "",
                pid: ownerPID,
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.size.width,
                height: bounds.size.height
            )
        }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func attrString(_ element: AXUIElement, _ attribute: CFString) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let raw = value else { return "" }
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        if let attributed = raw as? NSAttributedString { return attributed.string }
        return ""
    }

    private func attrBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }

    private func attributeArray(_ element: AXUIElement, _ attribute: CFString) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return [] }
        return (value as? [String]) ?? []
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success else { return [] }
        return (value as? [String]) ?? []
    }

    private func attributeNames(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyAttributeNames(element, &value) == .success else { return [] }
        return (value as? [String]) ?? []
    }

    private func bounds(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAX = positionValue,
              let sizeAX = sizeValue
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(positionAX) == AXValueGetTypeID(),
              CFGetTypeID(sizeAX) == AXValueGetTypeID(),
              AXValueGetValue(positionAX as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func center(of locator: AIOSLocator) -> CGPoint? {
        guard let x = locator.x, let y = locator.y, let width = locator.width, let height = locator.height else {
            return nil
        }
        return CGPoint(x: x + width / 2, y: y + height / 2)
    }

    private func postMouseClick(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func paste(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func locatorDict(_ locator: AIOSLocator) -> [String: Any] {
        var payload: [String: Any] = [
            "id": locator.id,
            "app": locator.appName,
            "bundle_id": locator.bundleID,
            "pid": locator.pid,
            "role": locator.role,
            "title": locator.title,
            "value": locator.value,
            "description": locator.description,
            "identifier": locator.identifier,
            "dom_id": locator.domID,
            "enabled": locator.enabled,
            "path": locator.path
        ]
        if let x = locator.x { payload["x"] = x }
        if let y = locator.y { payload["y"] = y }
        if let width = locator.width { payload["width"] = width }
        if let height = locator.height { payload["height"] = height }
        return payload
    }

    private func windowDict(_ window: AIOSWindowSnapshot) -> [String: Any] {
        [
            "id": window.id,
            "title": window.title,
            "owner": window.ownerName,
            "pid": window.pid,
            "x": window.x,
            "y": window.y,
            "width": window.width,
            "height": window.height
        ]
    }

    private func compactData(_ value: [String: Any]) -> [String: String] {
        value.reduce(into: [String: String]()) { output, item in
            if let text = item.value as? String {
                output[item.key] = text
            } else if let number = item.value as? NSNumber {
                output[item.key] = number.stringValue
            } else if let bool = item.value as? Bool {
                output[item.key] = bool ? "true" : "false"
            } else if let int = item.value as? Int {
                output[item.key] = "\(int)"
            } else if let int32 = item.value as? Int32 {
                output[item.key] = "\(int32)"
            } else if let uint32 = item.value as? UInt32 {
                output[item.key] = "\(uint32)"
            } else if let double = item.value as? Double {
                output[item.key] = "\(double)"
            } else {
                output[item.key] = jsonString(item.value)
            }
        }
    }

    private func text(_ value: Any?) -> String {
        optionalText(value) ?? ""
    }

    private func optionalText(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func boolean(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return ["1", "true", "yes"].contains(text.lowercased()) }
        return nil
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "\(value)"
        }
        return text
    }

    private func truncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max)) + "\n...[truncated]..."
    }

    private struct FocusSnapshot {
        let bundleID: String?

        static func capture() -> FocusSnapshot {
            FocusSnapshot(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }

        func restore() {
            guard let bundleID,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            else { return }
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}

private extension ToolResult {
    func withEvidence(_ evidence: String) -> ToolResult {
        ToolResult(success: success, evidence: evidence, data: data, error: error, suggestion: suggestion)
    }
}
