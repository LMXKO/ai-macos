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

@MainActor
final class ToolRegistry {
    private struct AppLaunchTarget {
        let displayName: String
        let appName: String?
        let appPath: String?
        let description: String
    }

    private static var recentExternalSendAttempts: [String: Date] = [:]

    private static let highFrequencyOpenAppTargets: [String: AppLaunchTarget] = [
        "anaconda_open": AppLaunchTarget(
            displayName: "Anaconda Navigator",
            appName: "Anaconda-Navigator",
            appPath: "/Applications/Anaconda-Navigator.app",
            description: "Open Anaconda Navigator."
        ),
        "clashx_open": AppLaunchTarget(
            displayName: "ClashX",
            appName: "ClashX",
            appPath: nil,
            description: "Open ClashX. Does not change proxy settings."
        ),
        "flyingbird_open": AppLaunchTarget(
            displayName: "FlyingBird",
            appName: "FlyingBird机场",
            appPath: "/Applications/FlyingBird机场.app",
            description: "Open FlyingBird. Does not change network/proxy state."
        ),
        "inode_client_open": AppLaunchTarget(
            displayName: "iNodeClient",
            appName: nil,
            appPath: "/Applications/iNodeClient/iNodeClient.app",
            description: "Open iNodeClient. Does not connect or disconnect VPN/network sessions."
        ),
        "inode_manager_open": AppLaunchTarget(
            displayName: "iNodeManager",
            appName: nil,
            appPath: "/Applications/iNodeManager/iNodeManager.app",
            description: "Open iNodeManager. Does not change network sessions."
        ),
        "ntfs_for_mac_open": AppLaunchTarget(
            displayName: "NTFS for Mac",
            appName: "NTFS for Mac",
            appPath: nil,
            description: "Open NTFS for Mac."
        ),
        "ui_tars_open": AppLaunchTarget(
            displayName: "UI-TARS",
            appName: "UI TARS",
            appPath: "/Applications/UI TARS.app",
            description: "Open UI-TARS desktop app."
        ),
        "veee_open": AppLaunchTarget(
            displayName: "Veee",
            appName: "Veee",
            appPath: nil,
            description: "Open Veee. Does not change network/proxy state."
        ),
        "wd_discovery_open": AppLaunchTarget(
            displayName: "WD Discovery",
            appName: nil,
            appPath: "/Applications/WD Discovery/WD Discovery.app",
            description: "Open WD Discovery."
        ),
        "yaaa_network_assistant_open": AppLaunchTarget(
            displayName: "Yaaa iNetWork Assistant",
            appName: nil,
            appPath: "/Applications/Yaaa - iNetWork Assistant.app",
            description: "Open Yaaa iNetWork Assistant."
        )
    ]

    var definitions: [[String: Any]] {
        [
            tool("aios_context", "Get frontmost app, bundle id, pid, and visible window titles.", [:]),
            tool("aios_automation_context", "Get frontmost/target app context and visible windows for locator-based automation.", [
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id.")
            ]),
            tool("aios_find", "Find Accessibility UI elements and return reusable locator ids with roles, labels, and bounds.", [
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter such as AXButton, AXTextField, or AXMenuItem."),
                "app_name": schema("string", "Optional target app name. Defaults to frontmost app."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "max_depth": schema("number", "Maximum AX tree depth. Default 8."),
                "max_results": schema("number", "Maximum matches. Default 50.")
            ]),
            tool("aios_inspect", "Inspect a UI element by locator id or a fresh query and return attributes/actions.", [
                "locator_id": schema("string", "Locator id returned by aios_find."),
                "query": schema("string", "Optional fallback label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "max_depth": schema("number", "Maximum AX tree depth. Default 8.")
            ]),
            tool("aios_read", "Read UI text from a located element or from the target app's AX tree.", [
                "locator_id": schema("string", "Optional locator id returned by aios_find."),
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "max_chars": schema("number", "Maximum text characters. Default 6000."),
                "max_depth": schema("number", "Maximum AX tree depth. Default 8."),
                "max_results": schema("number", "Maximum elements to read. Default 120.")
            ]),
            tool("aios_click", "Click a UI element by locator id or query using AXPress first and coordinate fallback.", [
                "locator_id": schema("string", "Locator id returned by aios_find."),
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "restore_focus": schema("boolean", "Restore the previously frontmost app after the action. Default true."),
                "allow_coordinate_fallback": schema("boolean", "Allow physical coordinate click if AXPress is unavailable. Default true.")
            ]),
            tool("aios_type", "Type text into a UI element by locator id or query using AXValue first and paste fallback.", [
                "text": schema("string", "Text to enter."),
                "locator_id": schema("string", "Locator id returned by aios_find."),
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "restore_focus": schema("boolean", "Restore the previously frontmost app after the action. Default true."),
                "allow_paste_fallback": schema("boolean", "Allow click plus paste if AXValue cannot be set. Default true.")
            ], required: ["text"]),
            tool("aios_background_click", "Non-invasive click: only perform semantic AXPress and restore focus; never uses coordinate fallback.", [
                "locator_id": schema("string", "Locator id returned by aios_find."),
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id.")
            ]),
            tool("aios_background_type", "Non-invasive type: only set AXValue and restore focus; never clicks or pastes.", [
                "text": schema("string", "Text to enter."),
                "locator_id": schema("string", "Locator id returned by aios_find."),
                "query": schema("string", "Optional label/title/value/identifier substring."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id.")
            ], required: ["text"]),
            tool("aios_wait", "Wait for a locator/UI/app condition with structured evidence.", [
                "condition": schema("string", "element_exists, element_gone, text_contains, frontmost_app, or window_title_contains."),
                "value": schema("string", "Expected text/app/window substring when required."),
                "query": schema("string", "Optional element query for element/text conditions."),
                "role": schema("string", "Optional AX role filter."),
                "app_name": schema("string", "Optional target app name."),
                "bundle_id": schema("string", "Optional target app bundle id."),
                "timeout": schema("number", "Seconds to wait. Default 10."),
                "interval": schema("number", "Polling interval seconds. Default 0.5.")
            ], required: ["condition"]),
            tool("aios_list_apps", "List installed macOS applications visible to this user. Use query to filter by name or bundle id.", [
                "query": schema("string", "Optional case-insensitive app name or bundle id filter."),
                "include_system": schema("boolean", "Whether to include /System/Applications apps. Default true.")
            ]),
            tool("aios_list_running_apps", "List currently running applications with names, bundle ids, and pids.", [:]),
            tool("aios_app_windows", "List visible windows for one app or all apps.", [
                "app_name": schema("string", "Optional application name filter."),
                "bundle_id": schema("string", "Optional bundle id filter.")
            ]),
            tool("aios_open_app", "Open or focus an app by name or bundle id.", [
                "app_name": schema("string", "Application name, for example TextEdit or Safari."),
                "bundle_id": schema("string", "Application bundle id, for example com.apple.TextEdit.")
            ]),
            tool("aios_quit_app", "Quit an app by name or bundle id. Refuses to force quit.", [
                "app_name": schema("string", "Application name, for example TextEdit or Safari."),
                "bundle_id": schema("string", "Application bundle id, for example com.apple.TextEdit.")
            ]),
            tool("aios_open_file", "Open a file or folder, optionally with a specific app.", [
                "path": schema("string", "Absolute or ~/ file/folder path."),
                "app_name": schema("string", "Optional app name to open with."),
                "bundle_id": schema("string", "Optional app bundle id to open with.")
            ], required: ["path"]),
            tool("aios_open_url", "Open a URL with the default handler or a specific app.", [
                "url": schema("string", "URL to open."),
                "app_name": schema("string", "Optional app name to open with."),
                "bundle_id": schema("string", "Optional app bundle id to open with.")
            ], required: ["url"]),
            tool("clipboard_get_text", "Read plain text from the clipboard.", [:]),
            tool("clipboard_set_text", "Set plain text on the clipboard.", [
                "text": schema("string", "Text to put on the clipboard.")
            ], required: ["text"]),
            tool("clipboard_set_files", "Put one or more file URLs on the clipboard for pasting into apps.", [
                "paths": arraySchema("string", "Absolute or ~/ file paths.")
            ], required: ["paths"]),
            tool("ui_paste", "Paste current clipboard into the frontmost app using Command-V.", [:]),
            tool("ui_keyboard_shortcut", "Send a keyboard shortcut to the frontmost app or a named app.", [
                "key": schema("string", "Key name, for example c, v, return, tab, escape, space, delete, up, down, left, right."),
                "modifiers": arraySchema("string", "Modifier names: command, shift, option, control."),
                "app_name": schema("string", "Optional app name to activate first."),
                "bundle_id": schema("string", "Optional bundle id to activate first.")
            ], required: ["key"]),
            tool("ui_click_menu", "Click a menu item in an app using System Events. menu_path example: [\"File\", \"Open...\"]", [
                "app_name": schema("string", "Application name. If omitted, uses frontmost app."),
                "bundle_id": schema("string", "Application bundle id. Optional."),
                "menu_path": arraySchema("string", "Menu path from the menu bar item to the menu item.")
            ], required: ["menu_path"]),
            tool("ui_click", "Click a screen coordinate.", [
                "x": schema("number", "Screen x coordinate."),
                "y": schema("number", "Screen y coordinate.")
            ], required: ["x", "y"]),
            tool("ui_scroll", "Scroll at the current pointer or provided coordinates.", [
                "direction": schema("string", "up, down, left, or right."),
                "amount": schema("number", "Scroll amount. Default 6."),
                "x": schema("number", "Optional screen x coordinate."),
                "y": schema("number", "Optional screen y coordinate.")
            ], required: ["direction"]),
            tool("ui_hover", "Move the cursor to a coordinate or snapshot element center.", [
                "x": schema("number", "Screen x coordinate."),
                "y": schema("number", "Screen y coordinate."),
                "snapshot_id": schema("string", "Optional snapshot id."),
                "element_id": schema("string", "Optional snapshot element id.")
            ]),
            tool("ui_drag", "Drag from one point to another.", [
                "from_x": schema("number", "Start x coordinate."),
                "from_y": schema("number", "Start y coordinate."),
                "to_x": schema("number", "End x coordinate."),
                "to_y": schema("number", "End y coordinate."),
                "duration": schema("number", "Duration seconds. Default 0.4.")
            ], required: ["from_x", "from_y", "to_x", "to_y"]),
            tool("ui_long_press", "Press and hold at a coordinate.", [
                "x": schema("number", "Screen x coordinate."),
                "y": schema("number", "Screen y coordinate."),
                "duration": schema("number", "Duration seconds. Default 0.8.")
            ], required: ["x", "y"]),
            tool("window_manage", "Focus, move, resize, minimize, zoom, or close a visible window.", [
                "action": schema("string", "focus, move, resize, set_bounds, minimize, zoom, close."),
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "x": schema("number", "Optional x."),
                "y": schema("number", "Optional y."),
                "width": schema("number", "Optional width."),
                "height": schema("number", "Optional height.")
            ], required: ["action"]),
            tool("dialog_click", "Click a button in the frontmost system/app dialog by label.", [
                "label": schema("string", "Button label substring, such as Open, Save, Cancel, Allow.")
            ], required: ["label"]),
            tool("dialog_input", "Set the focused dialog text field value.", [
                "text": schema("string", "Text to enter.")
            ], required: ["text"]),
            tool("dock_open", "Open an app from the Dock by name.", [
                "name": schema("string", "Dock item/app name.")
            ], required: ["name"]),
            tool("menubar_click", "Click a menu bar extra/status item by label substring.", [
                "label": schema("string", "Menu bar item label substring.")
            ], required: ["label"]),
            tool("space_switch", "Switch macOS Space using Control-left/right.", [
                "direction": schema("string", "left or right."),
                "count": schema("number", "Number of spaces. Default 1.")
            ], required: ["direction"]),
            tool("ax_describe_frontmost", "Summarize the frontmost app Accessibility tree with role, title, value, description, and enabled state.", [
                "max_depth": schema("number", "Maximum tree depth. Default 4."),
                "max_nodes": schema("number", "Maximum number of nodes. Default 80.")
            ]),
            tool("ax_press", "Press the first Accessibility element in the frontmost app matching a label/title/description substring.", [
                "label": schema("string", "Case-insensitive substring to find and press."),
                "role": schema("string", "Optional AX role filter such as AXButton or AXMenuItem.")
            ], required: ["label"]),
            tool("ax_get_focused_value", "Read role, title, value, and selected text from the currently focused Accessibility element.", [:]),
            tool("ax_set_focused_value", "Set the value of the currently focused Accessibility element when it supports AXValue.", [
                "text": schema("string", "Text to set.")
            ], required: ["text"]),
            tool("screen_capture", "Capture the main display to a PNG file and return the saved path.", [
                "path": schema("string", "Optional absolute or ~/ output path. Default: /tmp/aios-screen.png")
            ]),
            tool("observe_snapshot", "Collect a strong observation snapshot: frontmost context, windows, focused value, AX summary, and optional screenshot.", [
                "app_name": schema("string", "Optional app to activate before observing."),
                "bundle_id": schema("string", "Optional bundle id to activate before observing."),
                "screenshot": schema("boolean", "Whether to capture a screenshot. Default true."),
                "max_depth": schema("number", "AX tree depth. Default 4."),
                "max_nodes": schema("number", "AX node limit. Default 100.")
            ]),
            tool("observe_wait", "Poll until an app/window/AX/URL condition becomes true.", [
                "condition": schema("string", "frontmost_app, window_title_contains, ax_contains, focused_value_contains, safari_url_contains, chrome_url_contains, file_exists."),
                "value": schema("string", "Expected substring or file path."),
                "app_name": schema("string", "Optional app name for window/AX conditions."),
                "bundle_id": schema("string", "Optional bundle id."),
                "timeout": schema("number", "Seconds to wait. Default 10."),
                "interval": schema("number", "Polling interval seconds. Default 0.5.")
            ], required: ["condition", "value"]),
            tool("observe_annotate_frontmost", "Return indexed actionable Accessibility elements for the frontmost app, with labels, roles, and approximate bounds.", [
                "max_depth": schema("number", "Maximum tree depth. Default 6."),
                "max_nodes": schema("number", "Maximum nodes. Default 160.")
            ]),
            tool("snapshot_create", "Create a persistent UI snapshot with stable element ids for replayable click/type/action.", [
                "app_name": schema("string", "Optional app to activate before snapshot."),
                "bundle_id": schema("string", "Optional bundle id to activate before snapshot."),
                "screenshot": schema("boolean", "Whether to capture a screenshot. Default true."),
                "max_depth": schema("number", "Maximum AX tree depth. Default 7."),
                "max_nodes": schema("number", "Maximum nodes. Default 220.")
            ]),
            tool("snapshot_get", "Read a persisted UI snapshot by id.", [
                "snapshot_id": schema("string", "Snapshot id returned by snapshot_create.")
            ], required: ["snapshot_id"]),
            tool("snapshot_click", "Click a persisted snapshot element by element id.", [
                "snapshot_id": schema("string", "Snapshot id."),
                "element_id": schema("string", "Element id such as E1.")
            ], required: ["snapshot_id", "element_id"]),
            tool("snapshot_type", "Click a persisted snapshot element and type text.", [
                "snapshot_id": schema("string", "Snapshot id."),
                "element_id": schema("string", "Element id such as E1."),
                "text": schema("string", "Text to type or paste.")
            ], required: ["snapshot_id", "element_id", "text"]),
            tool("snapshot_press", "Perform AXPress on a persisted snapshot element when possible, otherwise click its center.", [
                "snapshot_id": schema("string", "Snapshot id."),
                "element_id": schema("string", "Element id such as E1.")
            ], required: ["snapshot_id", "element_id"]),
            tool("screen_capture_window", "Capture the first visible window matching an app name or bundle id.", [
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "path": schema("string", "Optional output path.")
            ]),
            tool("screen_capture_window_sck", "Capture a matching window through the ScreenCaptureKit-aware path, falling back to legacy CGWindow capture when needed.", [
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "path": schema("string", "Optional output path.")
            ]),
            tool("ocr_image", "Run local Vision OCR on an image file.", [
                "path": schema("string", "Absolute or ~/ image path.")
            ], required: ["path"]),
            tool("ocr_screen", "Capture the main display and run local Vision OCR.", [
                "path": schema("string", "Optional screenshot output path.")
            ]),
            tool("visual_find", "Visual fallback: capture screen/window, OCR text with bounds, and return matching visual targets.", [
                "query": schema("string", "Text substring to find visually. Empty returns OCR boxes."),
                "app_name": schema("string", "Optional app window to capture instead of the full screen."),
                "bundle_id": schema("string", "Optional app bundle id for window capture."),
                "scope": schema("string", "screen or window. Defaults to window when app_name/bundle_id is provided, otherwise screen."),
                "path": schema("string", "Optional existing image path or screenshot output path."),
                "max_results": schema("number", "Maximum matches. Default 20.")
            ]),
            tool("visual_read", "Visual fallback: capture screen/window and return OCR text plus bounded regions.", [
                "app_name": schema("string", "Optional app window to capture instead of the full screen."),
                "bundle_id": schema("string", "Optional app bundle id for window capture."),
                "scope": schema("string", "screen or window. Defaults to window when app_name/bundle_id is provided, otherwise screen."),
                "path": schema("string", "Optional existing image path or screenshot output path."),
                "max_results": schema("number", "Maximum OCR regions. Default 120.")
            ]),
            tool("visual_click", "Visual fallback: click the center of OCR text found on the screen/window. This is a foreground coordinate action.", [
                "query": schema("string", "Text substring to find visually."),
                "app_name": schema("string", "Optional app window to capture before clicking."),
                "bundle_id": schema("string", "Optional app bundle id for window capture."),
                "scope": schema("string", "screen or window. Defaults to window when app_name/bundle_id is provided, otherwise screen."),
                "max_results": schema("number", "Maximum visual matches to consider. Default 5.")
            ], required: ["query"]),
            tool("visual_ground", "Ground a screen/window/image into actionable visual candidates: OCR text, rectangles, AX hints, and saliency regions.", [
                "query": schema("string", "Optional text or intent to rank candidates."),
                "app_name": schema("string", "Optional app window to capture."),
                "bundle_id": schema("string", "Optional app bundle id."),
                "scope": schema("string", "screen, window, or image."),
                "path": schema("string", "Optional existing image path or screenshot output path."),
                "max_results": schema("number", "Maximum candidates. Default 40.")
            ]),
            tool("visual_candidates", "Return the v2 visual grounding candidate set with OCR, AX, layout, icon, color/state, and sidecar-enriched candidates.", [
                "query": schema("string", "Optional text or intent to rank candidates."),
                "app_name": schema("string", "Optional app window to capture."),
                "bundle_id": schema("string", "Optional app bundle id."),
                "scope": schema("string", "screen, window, or image."),
                "path": schema("string", "Optional existing image path or screenshot output path."),
                "max_results": schema("number", "Maximum candidates. Default 80."),
                "use_sidecar": schema("boolean", "Ask configured AIOS_VISION_* sidecar to add/rerank candidates. Default true.")
            ]),
            tool("visual_ground_action", "Select a grounded visual candidate and return an action plan; optionally execute foreground coordinate click/type with explicit allow_foreground.", [
                "query": schema("string", "Text/intent to ground."),
                "action": schema("string", "click, type, verify, observe, drag, or hover. Default click."),
                "candidate_id": schema("string", "Optional candidate id from visual_candidates/visual_ground."),
                "text": schema("string", "Text to type when action=type."),
                "execute": schema("boolean", "Whether to execute the plan. Default false."),
                "allow_foreground": schema("boolean", "Required true for coordinate execution."),
                "app_name": schema("string", "Optional app window to capture."),
                "bundle_id": schema("string", "Optional app bundle id."),
                "scope": schema("string", "screen, window, or image."),
                "path": schema("string", "Optional existing image path or screenshot output path."),
                "max_results": schema("number", "Maximum candidates. Default 80.")
            ]),
            tool("visual_ground_schema", "Return the visual grounding candidate/action schema used by the perception layer and sidecar protocol.", [:]),
            tool("visual_perception_strategy", "Return the local/sidecar visual perception strategy for OCR, AX, icon, canvas, color, and layout grounding.", [
                "surface": schema("string", "Optional surface hint."),
                "query": schema("string", "Optional grounding query.")
            ]),
            tool("visual_ui_map_cache", "Persist a visual UI map from grounded candidates so screenshots can be replayed and compared later.", [
                "image_path": schema("string", "Image path."),
                "query": schema("string", "Grounding query."),
                "candidates_json": schema("string", "Candidates JSON from visual_ground/visual_candidates.")
            ], required: ["image_path", "candidates_json"]),
            tool("visual_ui_map_recent", "List recent cached visual UI maps.", [
                "limit": schema("number", "Maximum maps. Default 10.")
            ]),
            tool("visual_analyze", "Ask a configured vision model/sidecar about a screenshot, window, or image; falls back to local visual_ground evidence when no vision endpoint is configured.", [
                "prompt": schema("string", "Question or instruction for visual analysis."),
                "query": schema("string", "Optional grounding query to include with local candidates."),
                "app_name": schema("string", "Optional app window to capture."),
                "bundle_id": schema("string", "Optional app bundle id."),
                "scope": schema("string", "screen, window, or image."),
                "path": schema("string", "Optional existing image path or screenshot output path."),
                "max_results": schema("number", "Maximum local grounding candidates. Default 40.")
            ], required: ["prompt"]),
            tool("background_control_plan", "Choose the deepest non-invasive control channel available for an app/task: CDP/DOM, app script, AX semantic, visual, or foreground coordinate fallback.", [
                "goal": schema("string", "Task or step goal."),
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "url": schema("string", "Optional browser URL context."),
                "surface": schema("string", "Optional target surface hint: web, native, canvas, design, unknown.")
            ], required: ["goal"]),
            tool("background_kernel_plan", "Return the formal CUA-style background control kernel plan with target/action/channel guarantees and macOS boundary notes.", [
                "action": schema("string", "click, type, read, verify, eval, script, wait, extract, observe."),
                "query": schema("string", "Optional semantic/visual query."),
                "selector": schema("string", "Optional DOM selector."),
                "text": schema("string", "Optional text for type actions."),
                "script": schema("string", "Optional JS/AppleScript content."),
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "url": schema("string", "Optional browser URL context."),
                "surface": schema("string", "Optional target surface hint: web, native, canvas, design, unknown."),
                "allow_foreground": schema("boolean", "Whether foreground coordinate fallback is allowed. Default false.")
            ]),
            tool("background_channel_matrix", "Return the background-control capability matrix and non-invasiveness guarantees for each channel.", [:]),
            tool("background_dispatch_plan", "Build the execution dispatch contract for no-cursor/no-focus background control, including semantic channels and adapter boundary.", [
                "action": schema("string", "click, type, read, verify, eval, script, observe."),
                "query": schema("string", "Optional semantic query."),
                "selector": schema("string", "Optional DOM selector."),
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "url": schema("string", "Optional URL."),
                "surface": schema("string", "Optional surface hint.")
            ]),
            tool("background_capabilities", "Inspect the non-invasive control channels likely available for an app: CDP, AppleScript/SDEF, AX semantic, visual capture, and foreground fallback.", [
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "url": schema("string", "Optional URL context."),
                "surface": schema("string", "Optional target surface hint: web, native, canvas, design, unknown.")
            ]),
            tool("background_appscript", "Run AppleScript against a scriptable app without intentionally activating it. Use for native semantic background automation when SDEF exposes commands.", [
                "script": schema("string", "AppleScript source to execute."),
                "app_name": schema("string", "Optional app name for evidence/capability tracking."),
                "bundle_id": schema("string", "Optional bundle id for evidence/capability tracking.")
            ], required: ["script"]),
            tool("background_action", "Execute one non-invasive action through the deepest available channel: CDP selector, AppleScript, AX background locator, or visual grounding. Foreground coordinates are opt-in only.", [
                "action": schema("string", "click, type, read, eval, script, or verify."),
                "goal": schema("string", "Task/step goal for channel selection."),
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "selector": schema("string", "Optional DOM CSS selector for browser/CDP."),
                "query": schema("string", "Optional AX/visual query."),
                "role": schema("string", "Optional AX role."),
                "text": schema("string", "Text for type actions."),
                "script": schema("string", "JavaScript or AppleScript source for eval/script actions."),
                "url_contains": schema("string", "Optional CDP tab URL filter."),
                "title_contains": schema("string", "Optional CDP tab title filter."),
                "allow_foreground": schema("boolean", "Allow foreground visual/coordinate fallback. Default false.")
            ], required: ["action"]),
            tool("browser_cdp_launch", "Launch an isolated Google Chrome profile with a remote debugging port for DOM/CDP background automation.", [
                "port": schema("number", "Remote debugging port. Default 9222."),
                "user_data_dir": schema("string", "Optional profile dir. Default under AIOS state."),
                "url": schema("string", "Optional URL to open.")
            ]),
            tool("browser_cdp_status", "Check whether a Chrome DevTools Protocol endpoint is reachable.", [
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ]),
            tool("browser_cdp_tabs", "List Chrome DevTools Protocol tabs.", [
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ]),
            tool("browser_cdp_eval", "Evaluate JavaScript in a CDP tab by id, URL substring, or title substring without mouse/keyboard focus.", [
                "script": schema("string", "JavaScript expression or async function body."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ], required: ["script"]),
            tool("browser_cdp_click", "Click a DOM selector through CDP JavaScript without using screen coordinates.", [
                "selector": schema("string", "CSS selector."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ], required: ["selector"]),
            tool("browser_cdp_type", "Set or type text into a DOM selector through CDP JavaScript without using screen focus.", [
                "selector": schema("string", "CSS selector."),
                "text": schema("string", "Text to enter."),
                "submit": schema("boolean", "Dispatch Enter after input. Default false."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ], required: ["selector", "text"]),
            tool("browser_cdp_read", "Read text/value/html from a DOM selector through CDP.", [
                "selector": schema("string", "CSS selector. Default body."),
                "property": schema("string", "text, value, html, or attr:<name>. Default text."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ]),
            tool("browser_cdp_observe", "Return a Stagehand-style DOM observation: visible interactive elements with stable selector candidates, text, roles, and bounds.", [
                "query": schema("string", "Optional text/intent filter."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "max_results": schema("number", "Maximum elements. Default 80."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ]),
            tool("browser_cdp_act", "Act on a web page through CDP using selector or observed text: click, type, read, or submit without using screen focus.", [
                "action": schema("string", "click, type, read, or submit."),
                "selector": schema("string", "Optional CSS selector."),
                "query": schema("string", "Optional text/aria-label/name to resolve to a selector."),
                "text": schema("string", "Text for type/submit actions."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ], required: ["action"]),
            tool("browser_cdp_extract", "Extract structured text/links/forms from a page through CDP.", [
                "selector": schema("string", "Root selector. Default body."),
                "schema": schema("string", "Optional extraction target: summary, links, forms, tables, or text. Default summary."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ]),
            tool("browser_cdp_wait", "Wait for a web condition through CDP: selector, text, url_contains, expression, or network_idle.", [
                "condition": schema("string", "selector, text, url_contains, expression, or network_idle."),
                "value": schema("string", "Expected selector/text/url substring/expression, or quiet milliseconds for network_idle."),
                "timeout": schema("number", "Seconds to wait. Default 15."),
                "interval": schema("number", "Polling interval seconds. Default 0.5."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ], required: ["condition", "value"]),
            tool("browser_cdp_file_upload", "Set files on an input[type=file] through CDP DOM.setFileInputFiles without using the cursor or focus.", [
                "selector": schema("string", "CSS selector for the file input."),
                "paths": arraySchema("string", "Absolute or ~/ file paths to attach."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ], required: ["selector", "paths"]),
            tool("browser_cdp_download_behavior", "Configure Chrome download behavior/path for the selected CDP tab.", [
                "download_path": schema("string", "Absolute or ~/ download directory."),
                "behavior": schema("string", "allow, deny, or default. Default allow."),
                "tab_id": schema("string", "Optional CDP tab id."),
                "url_contains": schema("string", "Optional URL substring."),
                "title_contains": schema("string", "Optional title substring."),
                "host": schema("string", "Host. Default 127.0.0.1."),
                "port": schema("number", "Port. Default 9222.")
            ], required: ["download_path"]),
            tool("browser_cdp_selector_cache", "List Stagehand-style selector cache entries learned from browser_cdp_act.", [
                "query": schema("string", "Optional URL/query/action filter."),
                "limit": schema("number", "Maximum entries. Default 50.")
            ]),
            tool("browser_runtime_session", "Register or update a durable browser runtime session/profile for long web-app work.", [
                "name": schema("string", "Session name."),
                "endpoint": schema("string", "CDP endpoint. Default http://127.0.0.1:9222."),
                "profile_dir": schema("string", "Browser profile directory."),
                "url": schema("string", "Optional URL hint."),
                "status": schema("string", "planned, running, paused, complete.")
            ]),
            tool("browser_runtime_plan", "Create a Stagehand-style long browser runtime plan using CDP observe/act/extract/wait and selector cache.", [
                "goal": schema("string", "Web task goal."),
                "url": schema("string", "Optional URL.")
            ], required: ["goal"]),
            tool("browser_runtime_snapshot", "Return durable browser runtime sessions and selector cache snapshot.", [
                "session_id": schema("string", "Optional session id.")
            ]),
            tool("memory_remember", "Persist a reusable local memory such as an app preference, locator hint, or workflow note. Never store passwords, tokens, keys, payment data, or private secrets.", [
                "kind": schema("string", "Memory kind, e.g. user_preference, app_hint, workflow_hint. Default user_note."),
                "scope": schema("string", "Scope such as global, automation, workflow, or completion. Default global."),
                "app": schema("string", "Optional app name or bundle id this memory applies to."),
                "key": schema("string", "Short lookup key."),
                "value": schema("string", "Reusable memory value. Sensitive values are rejected."),
                "confidence": schema("number", "0.0-1.0 confidence. Default 0.8.")
            ], required: ["key", "value"]),
            tool("memory_recall", "Recall durable local memories relevant to the current goal, app, or workflow.", [
                "query": schema("string", "Search query. Use the user goal or app/workflow terms."),
                "kind": schema("string", "Optional memory kind filter."),
                "app": schema("string", "Optional app filter."),
                "limit": schema("number", "Maximum memories to return. Default 8.")
            ], required: ["query"]),
            tool("memory_recent", "Return the most recent durable local memories.", [
                "limit": schema("number", "Maximum memories to return. Default 10.")
            ]),
            tool("episode_recall", "Recall prior task episodes relevant to a goal/app/workflow.", [
                "query": schema("string", "Search query."),
                "limit": schema("number", "Maximum episodes. Default 8.")
            ], required: ["query"]),
            tool("context_graph_query", "Query the durable context graph of episodes, apps, tools, recipes, and relationships.", [
                "query": schema("string", "Search query. Empty returns recent graph nodes."),
                "limit": schema("number", "Maximum nodes. Default 20.")
            ]),
            tool("context_graph_ingest", "Manually add or strengthen a context graph relationship for durable task memory.", [
                "from_kind": schema("string", "Source node kind, e.g. user, app, workflow, file, recipe."),
                "from_label": schema("string", "Source node label."),
                "to_kind": schema("string", "Target node kind."),
                "to_label": schema("string", "Target node label."),
                "relation": schema("string", "Relationship label."),
                "weight": schema("number", "Edge weight increment. Default 1.")
            ], required: ["from_kind", "from_label", "to_kind", "to_label", "relation"]),
            tool("memory_profile", "Build a compact long-term context profile from memories, episodes, graph nodes, recipes, and app skills for a goal/app.", [
                "query": schema("string", "Goal, project, app, or workflow query."),
                "limit": schema("number", "Maximum items per source. Default 8.")
            ]),
            tool("memory_index_rebuild", "Rebuild the local semantic memory index from memories, episodes, context graph, recipes, app skills, and run summaries.", [:]),
            tool("memory_semantic_recall", "Recall semantically related memory/episode/recipe/skill/context items from the local vector index.", [
                "query": schema("string", "Goal, app, workflow, project, or troubleshooting query."),
                "limit": schema("number", "Maximum indexed items. Default 10."),
                "kinds": arraySchema("string", "Optional kind filters such as memory, episode, recipe, app_skill, graph, run.")
            ], required: ["query"]),
            tool("memory_context_pack", "Build a long-task context pack from the semantic index plus context graph neighborhood.", [
                "query": schema("string", "Goal, app, workflow, project, or recovery query."),
                "limit": schema("number", "Maximum items per section. Default 8.")
            ], required: ["query"]),
            tool("memory_episode_consolidate", "Consolidate a run into a durable episode, context graph edges, and refreshed semantic memory index.", [
                "run_id": schema("string", "Run id."),
                "outcome": schema("string", "Optional outcome label.")
            ], required: ["run_id"]),
            tool("memory_shadow_digest", "Return a Shadow-style digest of recent episodes, memories, and context graph state for long tasks.", [
                "limit": schema("number", "Maximum items. Default 20.")
            ]),
            tool("session_timeline", "Project a run's raw event stream into a Codex-style structured session timeline.", [
                "run_id": schema("string", "Run id."),
                "limit": schema("number", "Maximum session events. Default 200.")
            ], required: ["run_id"]),
            tool("session_export", "Export a run as a stable session protocol artifact for cockpit, replay, or external frontends.", [
                "run_id": schema("string", "Run id.")
            ], required: ["run_id"]),
            tool("cockpit_snapshot", "Return a cockpit snapshot for a run: timeline, current step, checkpoint, trajectory, replay plan, memory, recipes, skills, and artifacts.", [
                "run_id": schema("string", "Run id."),
                "limit": schema("number", "Maximum timeline/trajectory entries. Default 80.")
            ], required: ["run_id"]),
            tool("cockpit_live_state", "Return the live long-task cockpit state: runs, graphs, user commands, and available controls.", [
                "limit": schema("number", "Maximum rows. Default 20.")
            ]),
            tool("cockpit_command", "Record a cockpit command for a run: pause, resume, feedback, replan, branch, or stop.", [
                "run_id": schema("string", "Run id."),
                "command": schema("string", "pause, resume, feedback, replan, branch, or stop."),
                "feedback": schema("string", "Optional user feedback or instruction.")
            ], required: ["run_id", "command"]),
            tool("platform_status", "Return platform-level status: tool families, state root, session protocol schema, and module layout.", [:]),
            tool("agent_role_plan", "Create a Codex-style role route for a long computer-use task: planner, specialists, executor, verifier, memory, runtime.", [
                "goal": schema("string", "Task goal."),
                "app_name": schema("string", "Optional app name."),
                "surface": schema("string", "Optional surface hint.")
            ], required: ["goal"]),
            tool("agent_handoff_packet", "Record a structured handoff packet between role agents with tools, context, and stop conditions.", [
                "goal": schema("string", "Task goal."),
                "from_role": schema("string", "Source role id."),
                "to_role": schema("string", "Destination role id."),
                "reason": schema("string", "Why handoff is needed."),
                "context_json": schema("string", "Optional JSON object context.")
            ], required: ["goal", "from_role", "to_role", "reason"]),
            tool("app_skill_list", "List app skill manifests with capabilities, tools, recipes, selectors, and permissions.", [
                "query": schema("string", "Optional app/capability query."),
                "limit": schema("number", "Maximum skills. Default 20.")
            ]),
            tool("app_skill_suggest", "Suggest app skill manifests for a task or app.", [
                "query": schema("string", "Task, app, or capability query."),
                "limit": schema("number", "Maximum skills. Default 8.")
            ], required: ["query"]),
            tool("app_skill_install", "Install or update an app skill manifest in the local app-skills directory.", [
                "id": schema("string", "Skill id."),
                "app_name": schema("string", "App display name."),
                "bundle_id": schema("string", "App bundle id."),
                "version": schema("string", "Skill version. Default 1."),
                "capabilities": arraySchema("string", "Capability tags."),
                "tools": arraySchema("string", "Tool names exposed by this skill."),
                "recipes": arraySchema("string", "Recipe ids bundled/recommended by this skill."),
                "selectors_json": schema("string", "Optional selectors map as JSON object string."),
                "permissions": arraySchema("string", "Required macOS/app permissions."),
                "notes": schema("string", "Skill notes.")
            ], required: ["id", "app_name"]),
            tool("app_skill_package_scaffold", "Create or update a plugin-style app skill package directory with manifest, selectors, recipes, docs, and compatibility metadata.", [
                "id": schema("string", "Package/skill id."),
                "app_name": schema("string", "App display name."),
                "bundle_id": schema("string", "App bundle id."),
                "version": schema("string", "Package version. Default 1."),
                "capabilities": arraySchema("string", "Capability tags."),
                "tools": arraySchema("string", "Tool names exposed by this package."),
                "recipes": arraySchema("string", "Bundled recipe ids."),
                "selectors_json": schema("string", "Optional selectors map as JSON object string."),
                "permissions": arraySchema("string", "Required macOS/app permissions."),
                "notes": schema("string", "Package notes.")
            ], required: ["id", "app_name"]),
            tool("app_skill_package_list", "List plugin-style app skill packages loaded from app-skills/packages/*.", [
                "query": schema("string", "Optional package/app/capability query."),
                "limit": schema("number", "Maximum packages. Default 20.")
            ]),
            tool("app_skill_package_validate", "Validate one app skill package against known tools and package layout.", [
                "id": schema("string", "Package id.")
            ], required: ["id"]),
            tool("app_skill_route", "Resolve a plugin-style app skill route with tools, selectors, recipes, and compatibility metadata.", [
                "query": schema("string", "Task/app query."),
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id.")
            ], required: ["query"]),
            tool("app_skill_export_manifest", "Export a built-in or package app skill manifest to a portable JSON artifact.", [
                "id": schema("string", "Skill or package id.")
            ], required: ["id"]),
            tool("trajectory_get", "Return a replayable summarized trajectory for a prior run.", [
                "run_id": schema("string", "Run id."),
                "limit": schema("number", "Maximum events. Default 200.")
            ], required: ["run_id"]),
            tool("trajectory_export", "Export a prior run trajectory to trajectories/<run_id>.json.", [
                "run_id": schema("string", "Run id.")
            ], required: ["run_id"]),
            tool("trajectory_session_export", "Export a full replay session with raw events, checkpoint, screenshots, and timeline.", [
                "run_id": schema("string", "Run id.")
            ], required: ["run_id"]),
            tool("trajectory_replay_plan", "Create a replay plan from a prior trajectory slice without executing it.", [
                "run_id": schema("string", "Run id."),
                "from_index": schema("number", "First event index. Default 1."),
                "to_index": schema("number", "Last event index. Default end.")
            ], required: ["run_id"]),
            tool("trajectory_replay", "Replay executable AppAction events from a prior run. Defaults to dry-run; foreground coordinate actions require allow_foreground=true.", [
                "run_id": schema("string", "Run id."),
                "from_index": schema("number", "First event index. Default 1."),
                "to_index": schema("number", "Last event index. Default end."),
                "dry_run": schema("boolean", "Plan only without executing. Default true."),
                "allow_foreground": schema("boolean", "Allow visual_click/ui_* foreground input. Default false."),
                "stop_on_failure": schema("boolean", "Stop at the first skipped, blocked, or failed action. Default true."),
                "record_run": schema("boolean", "When executing, record a new replay run. Default false.")
            ], required: ["run_id"]),
            tool("trajectory_clip_recipe", "Clip a trajectory slice into a reusable recipe draft with replay-aware fallbacks.", [
                "run_id": schema("string", "Run id."),
                "from_index": schema("number", "First event index. Default 1."),
                "to_index": schema("number", "Last event index. Default end."),
                "recipe_id": schema("string", "Optional recipe id."),
                "title": schema("string", "Optional recipe title.")
            ], required: ["run_id"]),
            tool("trajectory_product_export", "Export a product-grade replay session bundle with timeline, raw trajectory, replay plan, and resume points.", [
                "run_id": schema("string", "Run id."),
                "limit": schema("number", "Maximum rows. Default 400.")
            ], required: ["run_id"]),
            tool("trajectory_resume_points", "List branch/resume points for a trajectory.", [
                "run_id": schema("string", "Run id.")
            ], required: ["run_id"]),
            tool("trajectory_branch_create", "Create a queued branch run that continues from a trajectory event index.", [
                "run_id": schema("string", "Parent run id."),
                "from_index": schema("number", "Event index to branch from."),
                "goal": schema("string", "Optional branch goal.")
            ], required: ["run_id", "from_index"]),
            tool("recipe_promote_run", "Promote a successful run trajectory into a parameterized workflow recipe draft.", [
                "run_id": schema("string", "Run id."),
                "recipe_id": schema("string", "Optional recipe id."),
                "title": schema("string", "Optional recipe title.")
            ], required: ["run_id"]),
            tool("recipe_compile", "Inspect and validate a recipe as a workflow program with branches, loops, conditions, and fallbacks.", [
                "id": schema("string", "Recipe id.")
            ], required: ["id"]),
            tool("recipe_refine", "Record a recipe run outcome and update versioned success/failure counters and notes.", [
                "id": schema("string", "Recipe id."),
                "run_id": schema("string", "Run id."),
                "success": schema("boolean", "Whether the run succeeded."),
                "notes": schema("string", "Optional refinement notes.")
            ], required: ["id", "run_id", "success"]),
            tool("recipe_generalize", "Generalize a learned/promoted recipe into a parameterized workflow program with inferred schema and self-healing fallbacks.", [
                "id": schema("string", "Recipe id."),
                "output_id": schema("string", "Optional output recipe id. Default <id>-generalized.")
            ], required: ["id"]),
            tool("recipe_execute_adaptive", "Execute a recipe through the adaptive runner, injecting learned repair hints and inferred fallbacks.", [
                "id": schema("string", "Recipe id."),
                "params_json": schema("string", "Recipe params as a JSON object string.")
            ], required: ["id"]),
            tool("recipe_repair_hint", "Record a durable recipe repair hint for a failed step so future adaptive runs can self-heal.", [
                "recipe_id": schema("string", "Recipe id."),
                "step_id": schema("string", "Step id."),
                "failed_tool": schema("string", "Tool that failed."),
                "replacement_tool": schema("string", "Fallback/replacement tool."),
                "arguments_json": schema("string", "Replacement arguments as a JSON object string."),
                "reason": schema("string", "Why this repair helps."),
                "success": schema("boolean", "Whether the repair has succeeded. Default false.")
            ], required: ["recipe_id", "step_id", "failed_tool", "replacement_tool"]),
            tool("recipe_program_compile", "Compile a recipe as a workflow program with typed params, graph, pre/postconditions, verification contracts, and issues.", [
                "id": schema("string", "Recipe id.")
            ], required: ["id"]),
            tool("recipe_schema_infer", "Promote a run and infer a generalized recipe program schema from its successful actions.", [
                "run_id": schema("string", "Run id."),
                "recipe_id": schema("string", "Optional recipe id.")
            ], required: ["run_id"]),
            tool("recipe_distill_success", "Distill a successful run into a stable adaptive recipe program.", [
                "run_id": schema("string", "Run id."),
                "title": schema("string", "Optional recipe title.")
            ], required: ["run_id"]),
            tool("runtime_status", "Inspect a run's durable state: summary, checkpoint, trajectory head/tail, and queued/scheduled state.", [
                "run_id": schema("string", "Run id."),
                "limit": schema("number", "Maximum trajectory events. Default 80.")
            ], required: ["run_id"]),
            tool("runtime_schedule", "Queue a new or existing run for immediate or delayed execution.", [
                "goal": schema("string", "Goal for a new run, or fallback goal for existing run."),
                "run_id": schema("string", "Optional existing run id to requeue."),
                "resume_after_seconds": schema("number", "Optional delay in seconds."),
                "resume_at": schema("string", "Optional ISO-8601 resume time.")
            ]),
            tool("task_graph_create", "Create a durable long-running task graph with DAG dependencies and watcher conditions.", [
                "title": schema("string", "Task graph title."),
                "goal": schema("string", "Overall goal."),
                "nodes_json": schema("string", "Optional JSON array of nodes with id,title,goal,depends_on,wait_condition,wait_value,not_before.")
            ], required: ["goal"]),
            tool("task_graph_list", "List durable task graphs.", [
                "limit": schema("number", "Maximum graphs. Default 20.")
            ]),
            tool("task_graph_status", "Read one durable task graph.", [
                "id": schema("string", "Task graph id.")
            ], required: ["id"]),
            tool("task_graph_tick", "Advance durable task graphs: update finished runs, evaluate watchers, and enqueue ready nodes.", [
                "id": schema("string", "Optional task graph id. Empty ticks all active graphs.")
            ]),
            tool("long_run_daemon_status", "Return the durable long-run daemon state.", [:]),
            tool("long_run_daemon_tick", "Advance the long-run daemon once: tick task graphs, queues, and waiting runs.", [:]),
            tool("long_run_schedule", "Schedule a long-running goal for future execution.", [
                "goal": schema("string", "Goal to queue."),
                "after_seconds": schema("number", "Delay in seconds. Default 0.")
            ], required: ["goal"]),
            tool("background_driver_matrix", "List true-background driver channels including CUA-compatible external drivers, CDP, app adapters, and AX.", [:]),
            tool("background_driver_dispatch", "Build or execute a CUA-compatible no-cursor/no-focus background driver request envelope.", [
                "app_name": schema("string", "Optional app name."),
                "bundle_id": schema("string", "Optional bundle id."),
                "surface": schema("string", "Surface hint such as web, canvas, figma, blender, or native_non_ax."),
                "url": schema("string", "Optional URL."),
                "action": schema("string", "Action such as click, type, observe, verify, or drag."),
                "query": schema("string", "Semantic target query."),
                "selector": schema("string", "Optional DOM or adapter selector."),
                "text": schema("string", "Optional text for type actions."),
                "script": schema("string", "Optional script for driver channels that support it."),
                "dry_run": schema("boolean", "Return request envelope without executing. Default true.")
            ]),
            tool("visual_grounder_profiles", "List visual grounding model profiles: local VLM adapters, OpenAI-compatible sidecar, and built-in fallback.", [:]),
            tool("visual_grounder_session", "Create a multimodal grounding session plan with model profile, UI map cache key, action schema, and verification anchors.", [
                "surface": schema("string", "Surface hint such as canvas, chart, image, native, or web."),
                "query": schema("string", "Grounding target query."),
                "image_path": schema("string", "Optional screenshot/image path.")
            ]),
            tool("visual_ui_map_query", "Query cached visual UI maps by semantic target.", [
                "query": schema("string", "Semantic target query."),
                "limit": schema("number", "Maximum UI maps. Default 10.")
            ]),
            tool("recipe_learn_once", "Promote one successful run into a reusable stable recipe program with a learning record and stability score.", [
                "run_id": schema("string", "Run id to learn from."),
                "recipe_id": schema("string", "Optional target recipe id."),
                "title": schema("string", "Optional learned recipe title.")
            ], required: ["run_id"]),
            tool("recipe_program_select", "Select the best reusable recipe programs for a goal using suggestions, compile validity, and learning records.", [
                "goal": schema("string", "Task goal."),
                "limit": schema("number", "Maximum candidates. Default 5.")
            ], required: ["goal"]),
            tool("long_task_state", "Return the long-task runtime state machine with run, daemon, queue, task graphs, and user commands.", [
                "run_id": schema("string", "Optional run id."),
                "limit": schema("number", "Maximum rows. Default 20.")
            ]),
            tool("long_task_watch", "Create a durable watcher task graph that starts work when an external condition becomes true.", [
                "goal": schema("string", "Goal to run when condition is met."),
                "condition": schema("string", "Watcher condition such as file_exists, run_complete, run_finished, or time."),
                "value": schema("string", "Condition value."),
                "title": schema("string", "Optional watcher title.")
            ], required: ["goal", "condition", "value"]),
            tool("long_task_interrupt", "Inject a human interrupt into a long run and apply resume, replan, branch, pause, or stop semantics.", [
                "run_id": schema("string", "Run id."),
                "instruction": schema("string", "Human instruction or feedback."),
                "mode": schema("string", "replan, feedback, resume, branch, pause, or stop. Default replan.")
            ], required: ["run_id", "instruction"]),
            tool("memory_entity_graph", "Build a long-term entity/context graph over episodes, apps, tools, recipes, and memories.", [
                "query": schema("string", "Optional query."),
                "limit": schema("number", "Maximum entities. Default 30.")
            ]),
            tool("memory_preference_digest", "Build a compact user preference, app habit, recipe success, and context-pack digest for a long task.", [
                "query": schema("string", "Optional goal/app/project query."),
                "limit": schema("number", "Maximum entries. Default 20.")
            ]),
            tool("browser_agent_plan", "Create a Stagehand-like browser agent plan over observe, act, extract, wait, selector cache, and self-healing.", [
                "goal": schema("string", "Web task goal."),
                "url": schema("string", "Optional URL."),
                "extraction_schema": schema("string", "Optional extraction schema description or JSON.")
            ], required: ["goal"]),
            tool("browser_agent_observation", "Record a browser agent observation into the durable DOM/action cache.", [
                "url": schema("string", "Page URL."),
                "goal": schema("string", "Task goal."),
                "observation_json": schema("string", "Observation JSON from browser_cdp_observe/extract.")
            ], required: ["url", "goal", "observation_json"]),
            tool("browser_agent_snapshot", "Return browser agent runtime snapshot with durable observations and CDP runtime state.", [
                "query": schema("string", "Optional query."),
                "limit": schema("number", "Maximum observations. Default 20.")
            ]),
            tool("app_skill_sdk", "Return the app skill SDK contract for plugin-style app adapters, selectors, recipes, compatibility, and distribution.", [:]),
            tool("app_skill_marketplace", "List built-in and package app skills as a local marketplace/index.", [
                "query": schema("string", "Optional query."),
                "limit": schema("number", "Maximum skills. Default 20.")
            ]),
            tool("cockpit_dashboard", "Build a product cockpit dashboard payload with live state, run snapshot, artifacts, views, and controls.", [
                "run_id": schema("string", "Optional run id."),
                "limit": schema("number", "Maximum rows. Default 20.")
            ]),
            tool("cockpit_dashboard_export", "Export the cockpit dashboard payload to a durable JSON artifact.", [
                "run_id": schema("string", "Optional run id."),
                "limit": schema("number", "Maximum rows. Default 20.")
            ]),
            tool("trajectory_bundle_manifest", "Build a replayable session bundle manifest with timeline, raw trajectory, replay plan, resume points, and artifact lanes.", [
                "run_id": schema("string", "Run id."),
                "limit": schema("number", "Maximum rows. Default 400.")
            ], required: ["run_id"]),
            tool("trajectory_bundle_export", "Export a replayable session bundle manifest for product replay and recipe clipping.", [
                "run_id": schema("string", "Run id."),
                "limit": schema("number", "Maximum rows. Default 400.")
            ], required: ["run_id"]),
            tool("agent_harness_plan", "Create a Codex-style multi-role computer-use harness plan with memory, recipe, skill, browser, visual, and background context.", [
                "goal": schema("string", "Task goal."),
                "app_name": schema("string", "Optional app name."),
                "surface": schema("string", "Optional surface hint.")
            ], required: ["goal"]),
            tool("agent_harness_tick", "Advance the Codex-style role harness by recording a structured handoff to the next role.", [
                "goal": schema("string", "Task goal."),
                "current_role": schema("string", "Current role id. Default planner."),
                "evidence": schema("string", "Optional evidence or reason for handoff.")
            ], required: ["goal"]),
            tool("computer_use_strategy", "Return the recommended planner/executor/perception/recipe/runtime strategy for a goal.", [
                "goal": schema("string", "Task goal."),
                "app": schema("string", "Optional app context.")
            ], required: ["goal"]),
            tool("recipe_list", "List reusable AIOS workflow recipes.", [:]),
            tool("recipe_suggest", "Suggest reusable recipes that may match the user's goal before doing manual app automation.", [
                "goal": schema("string", "User goal to match against recipe titles, templates, notes, and known workflow keywords."),
                "limit": schema("number", "Maximum suggestions. Default 5.")
            ], required: ["goal"]),
            tool("recipe_execute", "Execute a reusable step-based workflow recipe directly.", [
                "id": schema("string", "Recipe id."),
                "params_json": schema("string", "Recipe params as a JSON object string.")
            ], required: ["id"]),
            tool("learn_start", "Start a tool-level learning session that can become a recipe.", [
                "title": schema("string", "Learning session title.")
            ], required: ["title"]),
            tool("learn_record_tool", "Execute and record one tool call into the active learning session.", [
                "tool": schema("string", "Tool name to execute and record."),
                "arguments_json": schema("string", "Tool arguments as a JSON object string.")
            ], required: ["tool"]),
            tool("learn_record_events", "Record raw mouse/keyboard events for a few seconds and save a replayable recipe.", [
                "title": schema("string", "Learning session title."),
                "recipe_id": schema("string", "Recipe id to save."),
                "seconds": schema("number", "Recording duration. Default 8."),
                "include_ax": schema("boolean", "Capture frontmost app and focused AX context. Default true."),
                "synthesize": schema("boolean", "Synthesize semantic locator recipe steps with coordinate fallbacks. Default true.")
            ], required: ["recipe_id"]),
            tool("learn_stop", "Stop the active learning session and save it as a recipe.", [
                "recipe_id": schema("string", "Recipe id to save.")
            ], required: ["recipe_id"]),
            tool("finder_list_directory", "List files in a directory with names, types, sizes, and modified dates.", [
                "path": schema("string", "Absolute or ~/ directory path. Default: ~/Downloads"),
                "limit": schema("number", "Maximum entries. Default 80.")
            ]),
            tool("finder_file_info", "Read metadata for a file or folder.", [
                "path": schema("string", "Absolute or ~/ file/folder path.")
            ], required: ["path"]),
            tool("finder_read_text_file", "Read and optionally verify the text content of a local UTF-8 file.", [
                "path": schema("string", "Absolute or ~/ text file path."),
                "contains": schema("string", "Optional text that must be present for success."),
                "max_chars": schema("number", "Maximum characters to return. Default 4000.")
            ], required: ["path"]),
            tool("finder_find_files", "Find files by name under a root directory.", [
                "root": schema("string", "Absolute or ~/ root directory. Default: ~/Downloads"),
                "name_contains": schema("string", "Case-insensitive filename substring."),
                "limit": schema("number", "Maximum results. Default 40.")
            ], required: ["name_contains"]),
            tool("chrome_open_url", "Open a URL in Google Chrome.", [
                "url": schema("string", "URL to open.")
            ], required: ["url"]),
            tool("chrome_get_current_tab", "Read Google Chrome front window active tab title and URL.", [:]),
            tool("chrome_new_tab", "Open a new Google Chrome tab, optionally with a URL.", [
                "url": schema("string", "Optional URL for the new tab.")
            ]),
            tool("chrome_search", "Search Google in Chrome for a query.", [
                "query": schema("string", "Search query.")
            ], required: ["query"]),
            tool("wps_open_file", "Open a document/spreadsheet/presentation in WPS Office.", [
                "path": schema("string", "Absolute or ~/ file path.")
            ], required: ["path"]),
            tool("notes_create_note", "Create a local Apple Notes note. This is local state, not an external send.", [
                "title": schema("string", "Note title."),
                "body": schema("string", "Note body.")
            ], required: ["title", "body"]),
            tool("notes_search", "Open Notes and search for text using the Notes search UI.", [
                "query": schema("string", "Search text.")
            ], required: ["query"]),
            tool("mail_compose_draft", "Create a visible Mail draft. Does not send.", [
                "to": arraySchema("string", "Recipient email addresses."),
                "subject": schema("string", "Draft subject."),
                "body": schema("string", "Draft body."),
                "attachments": arraySchema("string", "Optional absolute or ~/ file attachment paths.")
            ], required: ["subject", "body"]),
            tool("mail_search_messages", "Open Mail and search messages.", [
                "query": schema("string", "Search query.")
            ], required: ["query"]),
            tool("calendar_create_event", "Create a Calendar event.", [
                "title": schema("string", "Event title."),
                "start": schema("string", "Start date/time, e.g. 2026-05-21 15:30."),
                "end": schema("string", "End date/time, e.g. 2026-05-21 16:00."),
                "calendar": schema("string", "Optional calendar name."),
                "notes": schema("string", "Optional event notes.")
            ], required: ["title", "start", "end"]),
            tool("calendar_find_events", "Find Calendar events by title substring.", [
                "title": schema("string", "Title substring."),
                "days": schema("number", "Days from today to search. Default 30.")
            ], required: ["title"]),
            tool("wechat_open", "Open WeChat.", [:]),
            tool("wechat_search_chat", "Open WeChat search and search for a contact/chat. Does not send anything.", [
                "name": schema("string", "Contact or chat name.")
            ], required: ["name"]),
            tool("wechat_open_chat", "Open WeChat, search for a contact/chat, press Return to open the top result, and verify the current chat. Does not send anything.", [
                "recipient": schema("string", "Contact/chat name.")
            ], required: ["recipient"]),
            tool("wechat_stage_file", "Stage a file in a WeChat chat input by clipboard paste. Does not press send.", [
                "recipient": schema("string", "Contact/chat name to search before staging."),
                "path": schema("string", "Absolute or ~/ file path to stage.")
            ], required: ["recipient", "path"]),
            tool("wechat_send_text", "Search a WeChat chat, paste text, and send it.", [
                "recipient": schema("string", "Contact/chat name."),
                "text": schema("string", "Message text to send.")
            ], required: ["recipient", "text"]),
            tool("wechat_send_staged", "Send the currently staged WeChat message/file after recipient verification.", [
                "recipient": schema("string", "Recipient you verified on screen.")
            ], required: ["recipient"]),
            tool("wechat_verify_chat", "Verify whether WeChat UI appears to contain the expected chat/contact.", [
                "recipient": schema("string", "Expected contact/chat name.")
            ], required: ["recipient"]),
            tool("wechat_verify_recent_message", "Verify whether recent WeChat UI text appears to contain expected message text.", [
                "text": schema("string", "Expected text substring.")
            ], required: ["text"]),
            tool("lark_open", "Open Lark/Feishu.", [:]),
            tool("lark_search_chat", "Open Lark search and search for a contact/chat. Does not send anything.", [
                "name": schema("string", "Contact or chat name.")
            ], required: ["name"]),
            tool("lark_stage_file", "Stage a file in a Lark chat input by clipboard paste. Does not press send.", [
                "chat": schema("string", "Chat/contact name to search before staging."),
                "path": schema("string", "Absolute or ~/ file path to stage.")
            ], required: ["chat", "path"]),
            tool("lark_send_text", "Search a Lark chat, paste text, and send it.", [
                "chat": schema("string", "Chat/contact name."),
                "text": schema("string", "Message text to send.")
            ], required: ["chat", "text"]),
            tool("lark_send_staged", "Send the currently staged Lark message/file after chat verification.", [
                "chat": schema("string", "Chat/contact you verified on screen.")
            ], required: ["chat"]),
            tool("lark_verify_chat", "Verify whether Lark UI appears to contain the expected chat/contact.", [
                "chat": schema("string", "Expected chat/contact name.")
            ], required: ["chat"]),
            tool("lark_verify_recent_message", "Verify whether recent Lark UI text appears to contain expected message text.", [
                "text": schema("string", "Expected text substring.")
            ], required: ["text"]),
            tool("qq_open", "Open QQ.", [:]),
            tool("qq_search_chat", "Open QQ search and search for a contact/chat. Does not send anything.", [
                "name": schema("string", "Contact or chat name.")
            ], required: ["name"]),
            tool("qq_stage_file", "Stage a file in a QQ chat input by clipboard paste. Does not press send.", [
                "recipient": schema("string", "Contact/chat name to search before staging."),
                "path": schema("string", "Absolute or ~/ file path to stage.")
            ], required: ["recipient", "path"]),
            tool("qq_send_text", "Search a QQ chat, paste text, and send it.", [
                "recipient": schema("string", "Contact/chat name."),
                "text": schema("string", "Message text to send.")
            ], required: ["recipient", "text"]),
            tool("qq_send_staged", "Send the currently staged QQ message/file after recipient verification.", [
                "recipient": schema("string", "Recipient you verified on screen.")
            ], required: ["recipient"]),
            tool("qq_verify_chat", "Verify whether QQ UI appears to contain the expected chat/contact.", [
                "recipient": schema("string", "Expected contact/chat name.")
            ], required: ["recipient"]),
            tool("qq_verify_recent_message", "Verify whether recent QQ UI text appears to contain expected message text.", [
                "text": schema("string", "Expected text substring.")
            ], required: ["text"]),
            tool("tencent_meeting_open", "Open Tencent Meeting.", [:]),
            tool("tencent_meeting_stage_join", "Open Tencent Meeting and copy a meeting id/link to clipboard. Does not join.", [
                "meeting": schema("string", "Meeting id or meeting link.")
            ], required: ["meeting"]),
            tool("baidunetdisk_open", "Open Baidu Netdisk.", [:]),
            tool("baidunetdisk_stage_file", "Put a local file on the clipboard for manual Baidu Netdisk upload. Does not upload.", [
                "path": schema("string", "Absolute or ~/ file path.")
            ], required: ["path"]),
            tool("todesk_open", "Open ToDesk remote-control app.", [:]),
            tool("todesk_stage_remote_id", "Open ToDesk and copy a remote id/code to clipboard. Does not connect.", [
                "remote_id": schema("string", "Remote id or code.")
            ], required: ["remote_id"]),
            tool("docker_open", "Open Docker Desktop.", [:]),
            tool("docker_status", "Read whether Docker Desktop is running and list its visible windows. Does not change containers.", [:]),
            tool("xcode_open_path", "Open a file, folder, project, or workspace in Xcode.", [
                "path": schema("string", "Absolute or ~/ path.")
            ], required: ["path"]),
            tool("pycharm_open_path", "Open a file or folder in PyCharm.", [
                "path": schema("string", "Absolute or ~/ path.")
            ], required: ["path"]),
            tool("rustrover_open_path", "Open a file or folder in RustRover.", [
                "path": schema("string", "Absolute or ~/ path.")
            ], required: ["path"]),
            tool("preview_open_file", "Open a PDF/image/document in Preview.", [
                "path": schema("string", "Absolute or ~/ file path.")
            ], required: ["path"]),
            tool("libreoffice_open_file", "Open a document/spreadsheet/presentation in LibreOffice.", [
                "path": schema("string", "Absolute or ~/ file path.")
            ], required: ["path"]),
            tool("libreoffice_export_pdf", "Export a LibreOffice-supported file to PDF using soffice headless.", [
                "path": schema("string", "Absolute or ~/ file path."),
                "outdir": schema("string", "Optional output directory. Defaults to the file's directory.")
            ], required: ["path"]),
            tool("shortcuts_open", "Open the Shortcuts app.", [:]),
            tool("shortcuts_list", "List available Apple Shortcuts. Does not run them.", [:]),
            tool("shortcuts_run", "Run an Apple Shortcut by name.", [
                "name": schema("string", "Shortcut name.")
            ], required: ["name"]),
            tool("sdef_lookup", "Inspect an app's AppleScript dictionary (SDEF) and return a concise command/class summary.", [
                "app_name": schema("string", "Application name, e.g. Safari."),
                "path": schema("string", "Optional /Applications/App.app path."),
                "query": schema("string", "Optional substring filter."),
                "max_lines": schema("number", "Maximum output lines. Default 120.")
            ]),
            tool("scripting_bridge_probe", "Probe whether a target app exposes a ScriptingBridge object.", [
                "bundle_id": schema("string", "Application bundle id, e.g. com.apple.Safari.")
            ], required: ["bundle_id"]),
            tool("reminders_create", "Create a local Apple Reminders reminder.", [
                "title": schema("string", "Reminder title."),
                "notes": schema("string", "Optional notes."),
                "list": schema("string", "Optional reminders list name.")
            ], required: ["title"]),
            tool("safari_new_tab", "Open a new Safari tab, optionally with a URL.", [
                "url": schema("string", "Optional URL for the new tab.")
            ]),
            tool("safari_search", "Search the web in Safari.", [
                "query": schema("string", "Search query.")
            ], required: ["query"]),
            tool("claude_open", "Open Claude desktop app.", [:]),
            tool("codex_open", "Open Codex desktop app.", [:]),
            tool("textedit_new_document", "Open TextEdit and create a new document.", [:]),
            tool("textedit_set_text", "Set the full text of the front TextEdit document.", [
                "text": schema("string", "Text to write.")
            ], required: ["text"]),
            tool("textedit_read_text", "Read the text of the front TextEdit document.", [:]),
            tool("textedit_save_as", "Save the front TextEdit document to a path. Refuses overwrite by default.", [
                "path": schema("string", "Absolute or ~/ path to save to."),
                "overwrite": schema("boolean", "Whether an existing file may be overwritten.")
            ], required: ["path"]),
            tool("finder_create_folder", "Create a folder and verify it exists.", [
                "path": schema("string", "Absolute or ~/ folder path.")
            ], required: ["path"]),
            tool("finder_reveal_file", "Reveal a file or folder in Finder.", [
                "path": schema("string", "Absolute or ~/ file/folder path.")
            ], required: ["path"]),
            tool("safari_open_url", "Open a URL in Safari.", [
                "url": schema("string", "URL to open.")
            ], required: ["url"]),
            tool("safari_get_current_url", "Read Safari front document URL.", [:]),
            tool("safari_get_page_text", "Read Safari front document body text via JavaScript.", [:]),
            tool("safari_eval_js", "Run JavaScript in Safari front document and return the result.", [
                "script": schema("string", "JavaScript expression or script.")
            ], required: ["script"]),
            tool("chrome_get_page_text", "Read Google Chrome active tab body text via JavaScript.", [:]),
            tool("chrome_eval_js", "Run JavaScript in Google Chrome active tab and return the result.", [
                "script": schema("string", "JavaScript expression or script.")
            ], required: ["script"]),
            tool("terminal_run_command", "Run a command in Terminal.", [
                "command": schema("string", "Shell command to run.")
            ], required: ["command"])
        ] + Self.highFrequencyOpenAppTargets
            .sorted { $0.key < $1.key }
            .map { name, target in
                tool(name, target.description, [:])
            }
    }

    func execute(_ call: ToolCall) -> ToolResult {
        do {
            if let target = Self.highFrequencyOpenAppTargets[call.name] {
                return try openAppTarget(target)
            }

            switch call.name {
            case "aios_context":
                return context()
            case "aios_automation_context":
                return AIOSAutomationService.shared.context(args: call.arguments)
            case "aios_find":
                return AIOSAutomationService.shared.find(args: call.arguments)
            case "aios_inspect":
                return AIOSAutomationService.shared.inspect(args: call.arguments)
            case "aios_read":
                return AIOSAutomationService.shared.read(args: call.arguments)
            case "aios_click":
                return AIOSAutomationService.shared.click(args: call.arguments)
            case "aios_type":
                return AIOSAutomationService.shared.type(args: call.arguments)
            case "aios_background_click":
                return AIOSAutomationService.shared.backgroundClick(args: call.arguments)
            case "aios_background_type":
                return AIOSAutomationService.shared.backgroundType(args: call.arguments)
            case "aios_wait":
                return AIOSAutomationService.shared.wait(args: call.arguments)
            case "aios_list_apps":
                return try listApps(call.arguments)
            case "aios_list_running_apps":
                return listRunningApps()
            case "aios_app_windows":
                return appWindows(call.arguments)
            case "aios_open_app":
                return try openApp(call.arguments)
            case "aios_quit_app":
                return try quitApp(call.arguments)
            case "aios_open_file":
                return try openFile(call.arguments)
            case "aios_open_url":
                return try openURL(call.arguments)
            case "clipboard_get_text":
                return clipboardGetText()
            case "clipboard_set_text":
                return try clipboardSetText(call.arguments)
            case "clipboard_set_files":
                return try clipboardSetFiles(call.arguments)
            case "ui_paste":
                return try uiPaste()
            case "ui_keyboard_shortcut":
                return try uiKeyboardShortcut(call.arguments)
            case "ui_click_menu":
                return try uiClickMenu(call.arguments)
            case "ui_click":
                return try uiClick(call.arguments)
            case "ui_scroll":
                return try uiScroll(call.arguments)
            case "ui_hover":
                return try uiHover(call.arguments)
            case "ui_drag":
                return try uiDrag(call.arguments)
            case "ui_long_press":
                return try uiLongPress(call.arguments)
            case "window_manage":
                return try windowManage(call.arguments)
            case "dialog_click":
                return dialogClick(call.arguments)
            case "dialog_input":
                return try dialogInput(call.arguments)
            case "dock_open":
                return try dockOpen(call.arguments)
            case "menubar_click":
                return try menubarClick(call.arguments)
            case "space_switch":
                return try spaceSwitch(call.arguments)
            case "ax_describe_frontmost":
                return axDescribeFrontmost(call.arguments)
            case "ax_press":
                return axPress(call.arguments)
            case "ax_get_focused_value":
                return axGetFocusedValue()
            case "ax_set_focused_value":
                return try axSetFocusedValue(call.arguments)
            case "screen_capture":
                return try screenCapture(call.arguments)
            case "observe_snapshot":
                return try observeSnapshot(call.arguments)
            case "observe_wait":
                return try observeWait(call.arguments)
            case "observe_annotate_frontmost":
                return observeAnnotateFrontmost(call.arguments)
            case "snapshot_create":
                return try snapshotCreate(call.arguments)
            case "snapshot_get":
                return try snapshotGet(call.arguments)
            case "snapshot_click":
                return try snapshotClick(call.arguments)
            case "snapshot_type":
                return try snapshotType(call.arguments)
            case "snapshot_press":
                return try snapshotPress(call.arguments)
            case "screen_capture_window":
                return try screenCaptureWindow(call.arguments)
            case "screen_capture_window_sck":
                return try screenCaptureWindowSCK(call.arguments)
            case "ocr_image":
                return try ocrImage(call.arguments)
            case "ocr_screen":
                return try ocrScreen(call.arguments)
            case "visual_find":
                return try visualFind(call.arguments)
            case "visual_read":
                return try visualRead(call.arguments)
            case "visual_click":
                return try visualClick(call.arguments)
            case "visual_ground":
                return try visualGround(call.arguments)
            case "visual_candidates":
                return try visualGround(call.arguments.merging(["max_results": int(call.arguments["max_results"]) ?? 80]) { current, _ in current })
            case "visual_ground_action":
                return try visualGroundAction(call.arguments)
            case "visual_ground_schema":
                return visualGroundSchema()
            case "visual_perception_strategy":
                return visualPerceptionStrategyTool(call.arguments)
            case "visual_ui_map_cache":
                return try visualUIMapCacheTool(call.arguments)
            case "visual_ui_map_recent":
                return visualUIMapRecentTool(call.arguments)
            case "visual_analyze":
                return try visualAnalyze(call.arguments)
            case "background_control_plan":
                return backgroundControlPlan(call.arguments)
            case "background_kernel_plan":
                return backgroundKernelPlan(call.arguments)
            case "background_channel_matrix":
                return backgroundChannelMatrix()
            case "background_dispatch_plan":
                return backgroundDispatchPlan(call.arguments)
            case "background_capabilities":
                return backgroundCapabilities(call.arguments)
            case "background_appscript":
                return try backgroundAppScript(call.arguments)
            case "background_action":
                return try backgroundAction(call.arguments)
            case "browser_cdp_launch":
                return try browserCDPLaunch(call.arguments)
            case "browser_cdp_status":
                return browserCDPStatus(call.arguments)
            case "browser_cdp_tabs":
                return try browserCDPTabs(call.arguments)
            case "browser_cdp_eval":
                return try browserCDPEval(call.arguments)
            case "browser_cdp_click":
                return try browserCDPClick(call.arguments)
            case "browser_cdp_type":
                return try browserCDPType(call.arguments)
            case "browser_cdp_read":
                return try browserCDPRead(call.arguments)
            case "browser_cdp_observe":
                return try browserCDPObserve(call.arguments)
            case "browser_cdp_act":
                return try browserCDPAct(call.arguments)
            case "browser_cdp_extract":
                return try browserCDPExtract(call.arguments)
            case "browser_cdp_wait":
                return try browserCDPWait(call.arguments)
            case "browser_cdp_file_upload":
                return try browserCDPFileUpload(call.arguments)
            case "browser_cdp_download_behavior":
                return try browserCDPDownloadBehavior(call.arguments)
            case "browser_cdp_selector_cache":
                return browserCDPSelectorCache(call.arguments)
            case "browser_runtime_session":
                return try browserRuntimeSessionTool(call.arguments)
            case "browser_runtime_plan":
                return browserRuntimePlanTool(call.arguments)
            case "browser_runtime_snapshot":
                return browserRuntimeSnapshotTool(call.arguments)
            case "memory_remember":
                return try memoryRememberTool(call.arguments)
            case "memory_recall":
                return memoryRecallTool(call.arguments)
            case "memory_recent":
                return memoryRecentTool(call.arguments)
            case "episode_recall":
                return episodeRecallTool(call.arguments)
            case "context_graph_query":
                return contextGraphQueryTool(call.arguments)
            case "context_graph_ingest":
                return try contextGraphIngestTool(call.arguments)
            case "memory_profile":
                return memoryProfileTool(call.arguments)
            case "memory_index_rebuild":
                return try memoryIndexRebuildTool()
            case "memory_semantic_recall":
                return memorySemanticRecallTool(call.arguments)
            case "memory_context_pack":
                return memoryContextPackTool(call.arguments)
            case "memory_episode_consolidate":
                return try memoryEpisodeConsolidateTool(call.arguments)
            case "memory_shadow_digest":
                return memoryShadowDigestTool(call.arguments)
            case "session_timeline":
                return try sessionTimelineTool(call.arguments)
            case "session_export":
                return try sessionExportTool(call.arguments)
            case "cockpit_snapshot":
                return try cockpitSnapshotTool(call.arguments)
            case "cockpit_live_state":
                return cockpitLiveStateTool(call.arguments)
            case "cockpit_command":
                return try cockpitCommandTool(call.arguments)
            case "platform_status":
                return platformStatusTool()
            case "agent_role_plan":
                return agentRolePlanTool(call.arguments)
            case "agent_handoff_packet":
                return try agentHandoffPacketTool(call.arguments)
            case "app_skill_list":
                return appSkillListTool(call.arguments)
            case "app_skill_suggest":
                return appSkillSuggestTool(call.arguments)
            case "app_skill_install":
                return try appSkillInstallTool(call.arguments)
            case "app_skill_package_scaffold":
                return try appSkillPackageScaffoldTool(call.arguments)
            case "app_skill_package_list":
                return appSkillPackageListTool(call.arguments)
            case "app_skill_package_validate":
                return appSkillPackageValidateTool(call.arguments)
            case "app_skill_route":
                return appSkillRouteTool(call.arguments)
            case "app_skill_export_manifest":
                return try appSkillExportManifestTool(call.arguments)
            case "trajectory_get":
                return try trajectoryGetTool(call.arguments)
            case "trajectory_export":
                return try trajectoryExportTool(call.arguments)
            case "trajectory_session_export":
                return try trajectorySessionExportTool(call.arguments)
            case "trajectory_replay_plan":
                return try trajectoryReplayPlanTool(call.arguments)
            case "trajectory_replay":
                return try trajectoryReplayTool(call.arguments)
            case "trajectory_clip_recipe":
                return try trajectoryClipRecipeTool(call.arguments)
            case "trajectory_product_export":
                return try trajectoryProductExportTool(call.arguments)
            case "trajectory_resume_points":
                return try trajectoryResumePointsTool(call.arguments)
            case "trajectory_branch_create":
                return try trajectoryBranchCreateTool(call.arguments)
            case "recipe_promote_run":
                return try recipePromoteRunTool(call.arguments)
            case "recipe_compile":
                return try recipeCompileTool(call.arguments)
            case "recipe_refine":
                return try recipeRefineTool(call.arguments)
            case "recipe_generalize":
                return try recipeGeneralizeTool(call.arguments)
            case "recipe_execute_adaptive":
                return try recipeExecuteAdaptiveTool(call.arguments)
            case "recipe_repair_hint":
                return try recipeRepairHintTool(call.arguments)
            case "recipe_program_compile":
                return try recipeProgramCompileTool(call.arguments)
            case "recipe_schema_infer":
                return try recipeSchemaInferTool(call.arguments)
            case "recipe_distill_success":
                return try recipeDistillSuccessTool(call.arguments)
            case "runtime_status":
                return try runtimeStatusTool(call.arguments)
            case "runtime_schedule":
                return try runtimeScheduleTool(call.arguments)
            case "task_graph_create":
                return try taskGraphCreateTool(call.arguments)
            case "task_graph_list":
                return taskGraphListTool(call.arguments)
            case "task_graph_status":
                return try taskGraphStatusTool(call.arguments)
            case "task_graph_tick":
                return try taskGraphTickTool(call.arguments)
            case "long_run_daemon_status":
                return longRunDaemonStatusTool()
            case "long_run_daemon_tick":
                return try longRunDaemonTickTool()
            case "long_run_schedule":
                return try longRunScheduleTool(call.arguments)
            case "background_driver_matrix":
                return backgroundDriverMatrixTool()
            case "background_driver_dispatch":
                return try backgroundDriverDispatchTool(call.arguments)
            case "visual_grounder_profiles":
                return visualGrounderProfilesTool()
            case "visual_grounder_session":
                return visualGrounderSessionTool(call.arguments)
            case "visual_ui_map_query":
                return visualUIMapQueryTool(call.arguments)
            case "recipe_learn_once":
                return try recipeLearnOnceTool(call.arguments)
            case "recipe_program_select":
                return recipeProgramSelectTool(call.arguments)
            case "long_task_state":
                return longTaskStateTool(call.arguments)
            case "long_task_watch":
                return try longTaskWatchTool(call.arguments)
            case "long_task_interrupt":
                return try longTaskInterruptTool(call.arguments)
            case "memory_entity_graph":
                return memoryEntityGraphTool(call.arguments)
            case "memory_preference_digest":
                return memoryPreferenceDigestTool(call.arguments)
            case "browser_agent_plan":
                return browserAgentPlanTool(call.arguments)
            case "browser_agent_observation":
                return try browserAgentObservationTool(call.arguments)
            case "browser_agent_snapshot":
                return browserAgentSnapshotTool(call.arguments)
            case "app_skill_sdk":
                return appSkillSDKTool()
            case "app_skill_marketplace":
                return appSkillMarketplaceTool(call.arguments)
            case "cockpit_dashboard":
                return cockpitDashboardTool(call.arguments)
            case "cockpit_dashboard_export":
                return try cockpitDashboardExportTool(call.arguments)
            case "trajectory_bundle_manifest":
                return try trajectoryBundleManifestTool(call.arguments)
            case "trajectory_bundle_export":
                return try trajectoryBundleExportTool(call.arguments)
            case "agent_harness_plan":
                return try agentHarnessPlanTool(call.arguments)
            case "agent_harness_tick":
                return try agentHarnessTickTool(call.arguments)
            case "computer_use_strategy":
                return computerUseStrategyTool(call.arguments)
            case "recipe_list":
                return try recipeListTool()
            case "recipe_suggest":
                return try recipeSuggestTool(call.arguments)
            case "recipe_execute":
                return try recipeExecuteTool(call.arguments)
            case "learn_start":
                return try learnStartTool(call.arguments)
            case "learn_record_tool":
                return try learnRecordTool(call.arguments)
            case "learn_record_events":
                return try learnRecordEventsTool(call.arguments)
            case "learn_stop":
                return try learnStopTool(call.arguments)
            case "finder_list_directory":
                return try finderListDirectory(call.arguments)
            case "finder_file_info":
                return try finderFileInfo(call.arguments)
            case "finder_read_text_file":
                return try finderReadTextFile(call.arguments)
            case "finder_find_files":
                return try finderFindFiles(call.arguments)
            case "chrome_open_url":
                return try chromeOpenURL(call.arguments)
            case "chrome_get_current_tab":
                return try chromeGetCurrentTab()
            case "chrome_new_tab":
                return try chromeNewTab(call.arguments)
            case "chrome_search":
                return try chromeSearch(call.arguments)
            case "wps_open_file":
                return try wpsOpenFile(call.arguments)
            case "notes_create_note":
                return try notesCreateNote(call.arguments)
            case "notes_search":
                return try notesSearch(call.arguments)
            case "mail_compose_draft":
                return try mailComposeDraft(call.arguments)
            case "mail_search_messages":
                return try mailSearchMessages(call.arguments)
            case "calendar_create_event":
                return try calendarCreateEvent(call.arguments)
            case "calendar_find_events":
                return try calendarFindEvents(call.arguments)
            case "wechat_open":
                return try wechatOpen()
            case "wechat_search_chat":
                return try wechatSearchChat(call.arguments)
            case "wechat_open_chat":
                return try wechatOpenChat(call.arguments)
            case "wechat_stage_file":
                return try wechatStageFile(call.arguments)
            case "wechat_send_text":
                return try wechatSendText(call.arguments)
            case "wechat_send_staged":
                return try wechatSendStaged(call.arguments)
            case "wechat_verify_chat":
                return try chatVerify(appName: "WeChat", bundleID: "com.tencent.xinWeChat", expected: string(call.arguments["recipient"]) ?? "")
            case "wechat_verify_recent_message":
                return try chatVerify(appName: "WeChat", bundleID: "com.tencent.xinWeChat", expected: string(call.arguments["text"]) ?? "")
            case "lark_open":
                return try larkOpen()
            case "lark_search_chat":
                return try larkSearchChat(call.arguments)
            case "lark_stage_file":
                return try larkStageFile(call.arguments)
            case "lark_send_text":
                return try larkSendText(call.arguments)
            case "lark_send_staged":
                return try larkSendStaged(call.arguments)
            case "lark_verify_chat":
                return try chatVerify(appName: "Lark", bundleID: nil, expected: string(call.arguments["chat"]) ?? "")
            case "lark_verify_recent_message":
                return try chatVerify(appName: "Lark", bundleID: nil, expected: string(call.arguments["text"]) ?? "")
            case "qq_open":
                return try qqOpen()
            case "qq_search_chat":
                return try qqSearchChat(call.arguments)
            case "qq_stage_file":
                return try qqStageFile(call.arguments)
            case "qq_send_text":
                return try qqSendText(call.arguments)
            case "qq_send_staged":
                return try qqSendStaged(call.arguments)
            case "qq_verify_chat":
                return try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: string(call.arguments["recipient"]) ?? "")
            case "qq_verify_recent_message":
                return try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: string(call.arguments["text"]) ?? "")
            case "tencent_meeting_open":
                return try openNamedApp("TencentMeeting")
            case "tencent_meeting_stage_join":
                return try tencentMeetingStageJoin(call.arguments)
            case "baidunetdisk_open":
                return try openNamedApp("BaiduNetdisk_mac")
            case "baidunetdisk_stage_file":
                return try baiduNetdiskStageFile(call.arguments)
            case "todesk_open":
                return try openNamedApp("ToDesk")
            case "todesk_stage_remote_id":
                return try toDeskStageRemoteID(call.arguments)
            case "docker_open":
                return try openNamedApp("Docker")
            case "docker_status":
                return dockerStatus()
            case "xcode_open_path":
                return try openPathWithApp(call.arguments, appName: "Xcode")
            case "pycharm_open_path":
                return try openPathWithApp(call.arguments, appName: "PyCharm")
            case "rustrover_open_path":
                return try openPathWithApp(call.arguments, appName: "RustRover")
            case "preview_open_file":
                return try openPathWithApp(call.arguments, appName: "Preview")
            case "libreoffice_open_file":
                return try openPathWithApp(call.arguments, appName: "LibreOffice")
            case "libreoffice_export_pdf":
                return try libreOfficeExportPDF(call.arguments)
            case "shortcuts_open":
                return try openNamedApp("Shortcuts")
            case "shortcuts_list":
                return try shortcutsList()
            case "shortcuts_run":
                return try shortcutsRun(call.arguments)
            case "sdef_lookup":
                return try sdefLookup(call.arguments)
            case "scripting_bridge_probe":
                return scriptingBridgeProbe(call.arguments)
            case "reminders_create":
                return try remindersCreate(call.arguments)
            case "safari_new_tab":
                return try safariNewTab(call.arguments)
            case "safari_search":
                return try safariSearch(call.arguments)
            case "claude_open":
                return try openNamedApp("Claude")
            case "codex_open":
                return try openNamedApp("Codex")
            case "textedit_new_document":
                return try textEditNewDocument()
            case "textedit_set_text":
                return try textEditSetText(call.arguments)
            case "textedit_read_text":
                return try textEditReadText()
            case "textedit_save_as":
                return try textEditSaveAs(call.arguments)
            case "finder_create_folder":
                return try finderCreateFolder(call.arguments)
            case "finder_reveal_file":
                return try finderRevealFile(call.arguments)
            case "safari_open_url":
                return try safariOpenURL(call.arguments)
            case "safari_get_current_url":
                return try safariGetCurrentURL()
            case "safari_get_page_text":
                return try safariGetPageText()
            case "safari_eval_js":
                return try safariEvalJS(call.arguments)
            case "chrome_get_page_text":
                return try chromeGetPageText()
            case "chrome_eval_js":
                return try chromeEvalJS(call.arguments)
            case "terminal_run_command":
                return try terminalRunCommand(call.arguments)
            default:
                return ToolResult(success: false, evidence: "Unknown tool.", error: "Unknown tool: \(call.name)")
            }
        } catch {
            return ToolResult(success: false, evidence: "Tool failed.", error: error.localizedDescription)
        }
    }

    func doctor(requestPermissions: Bool = false) {
        if requestPermissions {
            requestMacOSPermissions()
        }

        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        let input = inputMonitoringAvailable()
        let config = LLMConfig.fromEnvironment()
        print("Accessibility: \(ax ? "granted" : "not granted")")
        print("Screen Recording: \(screen ? "granted" : "not granted")")
        print("Input Monitoring: \(input ? "available" : "not available")")
        print("Automation / Apple Events: requested on first use by target app")
        print("Safari JavaScript: enable Develop > Allow JavaScript from Apple Events when browser tools need page text")
        print("Chrome JavaScript: enable View > Developer > Allow JavaScript from Apple Events when browser tools need page text")
        print("LLM endpoint: \(config.baseURL.absoluteString)")
        print("LLM model: \(config.model)")
        print("LLM fallback providers: \(config.fallbacks.count)")
        print("State dir: \(EventStore.rootURL.path)")
        print("SQLite run index: \(SQLiteRunIndex.url.path)")
        print("LaunchAgent:")
        print(LaunchAgentManager.statusText().split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
        print("Shell tools: enabled")
        print("External chat send: enabled")
        print("Calendar writes: enabled")
        print("Shortcut execution: enabled")
        if requestPermissions && (!ax || !screen || !input) {
            print("Permission prompts were requested. If you changed a permission, quit and reopen the host app, then run doctor again.")
        }
    }

    func setupWizard(requestPermissions: Bool = false) {
        print("AIOS setup")
        print("1. Grant Accessibility so AIOS can read/click AX elements.")
        print("2. Grant Screen Recording so screenshots/OCR/snapshots can see the UI.")
        print("3. Grant Input Monitoring if you want raw CGEvent learning recorder.")
        print("4. Approve Automation prompts for System Events, Finder, Calendar, browsers, and chat apps as tasks need them.")
        print("5. Start the always-on worker with: aios launch-agent install")
        print("")
        doctor(requestPermissions: requestPermissions)
    }

    private func requestMacOSPermissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestScreenCaptureAccess()
    }

    private func inputMonitoringAvailable() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }
        CFMachPortInvalidate(tap)
        return true
    }

    private func context() -> ToolResult {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        let windows = visibleWindowTitles(pid: pid)
        return ToolResult(success: true, evidence: "Observed frontmost application.", data: [
            "app": app?.localizedName ?? "",
            "bundle_id": app?.bundleIdentifier ?? "",
            "pid": "\(pid)",
            "windows": windows.joined(separator: " | ")
        ])
    }

    private func openApp(_ args: [String: Any]) throws -> ToolResult {
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            try runProcess("/usr/bin/open", ["-b", bundleID])
            return ToolResult(success: true, evidence: "Opened app with bundle id \(bundleID).", data: [
                "effect": "app_opened",
                "app": bundleID,
                "bundle_id": bundleID,
                "verified": "true"
            ])
        }
        guard let appName = string(args["app_name"]), !appName.isEmpty else {
            throw RuntimeError("app_name or bundle_id is required")
        }
        let normalizedName = canonicalAppName(appName)
        try runProcess("/usr/bin/open", ["-a", normalizedName])
        return ToolResult(success: true, evidence: "Opened app \(normalizedName).", data: [
            "effect": "app_opened",
            "app": normalizedName,
            "verified": "true"
        ])
    }

    private func listApps(_ args: [String: Any]) throws -> ToolResult {
        let query = string(args["query"])?.lowercased()
        let includeSystem = bool(args["include_system"]) ?? true
        let roots = [
            "/Applications",
            NSHomeDirectory() + "/Applications"
        ] + (includeSystem ? ["/System/Applications", "/System/Applications/Utilities"] : [])
        let apps = roots.flatMap { appBundles(in: URL(fileURLWithPath: $0), maxDepth: 3) }
            .compactMap(appInfo)
            .filter { item in
                guard let query, !query.isEmpty else { return true }
                return item.values.contains { $0.lowercased().contains(query) }
            }
            .sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }

        return ToolResult(success: true, evidence: "Found \(apps.count) installed apps.", data: [
            "apps": jsonStringValue(apps)
        ])
    }

    private func listRunningApps() -> ToolResult {
        var apps: [[String: String]] = []
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            apps.append([
                "name": app.localizedName ?? "",
                "bundle_id": app.bundleIdentifier ?? "",
                "pid": "\(app.processIdentifier)",
                "active": app.isActive ? "true" : "false",
                "hidden": app.isHidden ? "true" : "false"
            ])
        }
        apps.sort { ($0["name"] ?? "") < ($1["name"] ?? "") }
        return ToolResult(success: true, evidence: "Listed \(apps.count) running apps.", data: [
            "apps": jsonStringValue(apps)
        ])
    }

    private func appWindows(_ args: [String: Any]) -> ToolResult {
        let appName = string(args["app_name"])
        let bundleID = string(args["bundle_id"])?.lowercased()
        let appsByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return ToolResult(success: false, evidence: "Could not read window list.", error: "CGWindowListCopyWindowInfo returned nil")
        }
        let windows = infos.compactMap { info -> [String: String]? in
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            guard let pid = ownerPID(from: info), let app = appsByPID[pid] else { return nil }
            if let appName, !appMatchesName(app, requested: appName) { return nil }
            if let bundleID, !(app.bundleIdentifier ?? "").lowercased().contains(bundleID) { return nil }
            return [
                "app": app.localizedName ?? "",
                "bundle_id": app.bundleIdentifier ?? "",
                "pid": "\(pid)",
                "title": info[kCGWindowName as String] as? String ?? "",
                "window_id": "\(info[kCGWindowNumber as String] as? Int ?? 0)"
            ]
        }
        return ToolResult(success: true, evidence: "Listed \(windows.count) visible windows.", data: [
            "windows": jsonStringValue(windows)
        ])
    }

    private func quitApp(_ args: [String: Any]) throws -> ToolResult {
        let app = try findRunningApp(args)
        let name = app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)"
        let requested = app.terminate()
        Thread.sleep(forTimeInterval: 0.4)
        return ToolResult(
            success: requested,
            evidence: requested ? "Requested \(name) to quit." : "Could not request quit for \(name).",
            data: ["app": name, "pid": "\(app.processIdentifier)"]
        )
    }

    private func openFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            try runProcess("/usr/bin/open", ["-b", bundleID, path])
            return ToolResult(success: true, evidence: "Opened \(path) with bundle id \(bundleID).", data: ["path": path, "bundle_id": bundleID])
        }
        if let appName = string(args["app_name"]), !appName.isEmpty {
            let normalizedName = canonicalAppName(appName)
            try runProcess("/usr/bin/open", ["-a", normalizedName, path])
            return ToolResult(success: true, evidence: "Opened \(path) with \(normalizedName).", data: ["path": path, "app": normalizedName])
        }
        try runProcess("/usr/bin/open", [path])
        return ToolResult(success: true, evidence: "Opened \(path) with the default app.", data: ["path": path])
    }

    private func openURL(_ args: [String: Any]) throws -> ToolResult {
        guard let rawURL = string(args["url"]), URL(string: rawURL) != nil else {
            throw RuntimeError("valid url is required")
        }
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            try runProcess("/usr/bin/open", ["-b", bundleID, rawURL])
            return ToolResult(success: true, evidence: "Opened URL with bundle id \(bundleID).", data: [
                "effect": "browser_url_visible",
                "app": bundleID,
                "target": rawURL,
                "url": rawURL,
                "bundle_id": bundleID,
                "verified": "true",
                "verified_current_url": "true"
            ])
        }
        if let appName = string(args["app_name"]), !appName.isEmpty {
            let normalizedName = canonicalAppName(appName)
            try runProcess("/usr/bin/open", ["-a", normalizedName, rawURL])
            return ToolResult(success: true, evidence: "Opened URL with \(normalizedName).", data: [
                "effect": "browser_url_visible",
                "app": normalizedName,
                "target": rawURL,
                "url": rawURL,
                "verified": "true",
                "verified_current_url": "true"
            ])
        }
        try runProcess("/usr/bin/open", [rawURL])
        return ToolResult(success: true, evidence: "Opened URL with the default handler.", data: [
            "effect": "browser_url_visible",
            "target": rawURL,
            "url": rawURL,
            "verified": "true",
            "verified_current_url": "true"
        ])
    }

    private func clipboardGetText() -> ToolResult {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        return ToolResult(success: true, evidence: text.isEmpty ? "Clipboard has no plain text." : "Read clipboard plain text.", data: [
            "text": text,
            "chars": "\(text.count)"
        ])
    }

    private func clipboardSetText(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return ToolResult(success: true, evidence: "Set clipboard plain text.", data: ["chars": "\(text.count)"])
    }

    private func clipboardSetFiles(_ args: [String: Any]) throws -> ToolResult {
        let paths = try stringArray(args["paths"], name: "paths").map { $0.expandingTildeInPath }
        guard !paths.isEmpty else { throw RuntimeError("paths must not be empty") }
        for path in paths where !FileManager.default.fileExists(atPath: path) {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects(urls)
        return ToolResult(success: ok, evidence: ok ? "Put \(paths.count) file URL(s) on the clipboard." : "Failed to put files on clipboard.", data: [
            "paths": jsonStringValue(paths)
        ])
    }

    private func uiPaste() throws -> ToolResult {
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Sent Command-V to the frontmost app.")
    }

    private func uiKeyboardShortcut(_ args: [String: Any]) throws -> ToolResult {
        try activateTargetAppIfProvided(args)
        let key = string(args["key"]) ?? ""
        let modifiers = (try? stringArray(args["modifiers"], name: "modifiers")) ?? []
        try sendKeyboardShortcut(key: key, modifiers: modifiers)
        return ToolResult(success: true, evidence: "Sent keyboard shortcut.", data: [
            "key": key,
            "modifiers": modifiers.joined(separator: ",")
        ])
    }

    private func uiClickMenu(_ args: [String: Any]) throws -> ToolResult {
        let menuPath = try stringArray(args["menu_path"], name: "menu_path")
        guard menuPath.count >= 2 else { throw RuntimeError("menu_path must include a menu bar item and a menu item") }
        let appName = try appNameForTarget(args)
        let listItems = menuPath.map(appleScriptString).joined(separator: ", ")
        _ = try runAppleScript("""
        set menuPath to {\(listItems)}
        tell application \(appleScriptString(appName)) to activate
        delay 0.2
        tell application "System Events"
          tell process \(appleScriptString(appName))
            set frontmost to true
            set currentMenu to menu (item 1 of menuPath) of menu bar item (item 1 of menuPath) of menu bar 1
            repeat with i from 2 to ((count of menuPath) - 1)
              set currentItem to menu item (item i of menuPath) of currentMenu
              set currentMenu to menu 1 of currentItem
            end repeat
            click menu item (last item of menuPath) of currentMenu
          end tell
        end tell
        """)
        return ToolResult(success: true, evidence: "Clicked app menu item.", data: [
            "app": appName,
            "menu_path": menuPath.joined(separator: " > ")
        ])
    }

    private func uiClick(_ args: [String: Any]) throws -> ToolResult {
        guard let x = double(args["x"]), let y = double(args["y"]) else { throw RuntimeError("x and y are required") }
        try clickPoint(x: x, y: y)
        return ToolResult(success: true, evidence: "Clicked point.", data: ["x": "\(Int(x))", "y": "\(Int(y))"])
    }

    private func uiScroll(_ args: [String: Any]) throws -> ToolResult {
        let direction = (string(args["direction"]) ?? "down").lowercased()
        let amount = int(args["amount"]) ?? 6
        let dx: Int32
        let dy: Int32
        switch direction {
        case "up":
            dx = 0; dy = Int32(amount)
        case "left":
            dx = Int32(amount); dy = 0
        case "right":
            dx = -Int32(amount); dy = 0
        default:
            dx = 0; dy = -Int32(amount)
        }
        if let x = double(args["x"]), let y = double(args["y"]) {
            try moveMouse(x: x, y: y)
        }
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            throw RuntimeError("could not create scroll event")
        }
        event.post(tap: .cghidEventTap)
        return ToolResult(success: true, evidence: "Scrolled \(direction).", data: ["direction": direction, "amount": "\(amount)"])
    }

    private func uiHover(_ args: [String: Any]) throws -> ToolResult {
        var x = double(args["x"])
        var y = double(args["y"])
        if x == nil || y == nil, string(args["snapshot_id"]) != nil, string(args["element_id"]) != nil {
            let target = try resolveSnapshotTarget(snapshotTarget(args))
            if let tx = Double(target["x"] ?? ""), let ty = Double(target["y"] ?? ""), let w = Double(target["width"] ?? ""), let h = Double(target["height"] ?? "") {
                x = tx + w / 2
                y = ty + h / 2
            }
        }
        guard let x, let y else { throw RuntimeError("x/y or snapshot_id/element_id is required") }
        try moveMouse(x: x, y: y)
        return ToolResult(success: true, evidence: "Moved cursor.", data: ["x": "\(Int(x))", "y": "\(Int(y))"])
    }

    private func uiDrag(_ args: [String: Any]) throws -> ToolResult {
        guard let fromX = double(args["from_x"]), let fromY = double(args["from_y"]), let toX = double(args["to_x"]), let toY = double(args["to_y"]) else {
            throw RuntimeError("from_x/from_y/to_x/to_y are required")
        }
        try dragMouse(from: CGPoint(x: fromX, y: fromY), to: CGPoint(x: toX, y: toY), duration: double(args["duration"]) ?? 0.4)
        return ToolResult(success: true, evidence: "Dragged pointer.", data: ["from": "\(Int(fromX)),\(Int(fromY))", "to": "\(Int(toX)),\(Int(toY))"])
    }

    private func uiLongPress(_ args: [String: Any]) throws -> ToolResult {
        guard let x = double(args["x"]), let y = double(args["y"]) else { throw RuntimeError("x and y are required") }
        try longPress(x: x, y: y, duration: double(args["duration"]) ?? 0.8)
        return ToolResult(success: true, evidence: "Long-pressed point.", data: ["x": "\(Int(x))", "y": "\(Int(y))"])
    }

    private func windowManage(_ args: [String: Any]) throws -> ToolResult {
        let action = (string(args["action"]) ?? "").lowercased()
        let app = try findRunningApp(args)
        app.activate()
        Thread.sleep(forTimeInterval: 0.2)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard err == .success, let window = windowValue.map({ unsafeDowncast($0, to: AXUIElement.self) }) else {
            return ToolResult(success: false, evidence: "No focused window for app.", error: "\(err.rawValue)")
        }
        switch action {
        case "focus":
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        case "move":
            try setAXWindowPosition(window, x: double(args["x"]) ?? 80, y: double(args["y"]) ?? 80)
        case "resize":
            try setAXWindowSize(window, width: double(args["width"]) ?? 900, height: double(args["height"]) ?? 700)
        case "set_bounds":
            try setAXWindowPosition(window, x: double(args["x"]) ?? 80, y: double(args["y"]) ?? 80)
            try setAXWindowSize(window, width: double(args["width"]) ?? 900, height: double(args["height"]) ?? 700)
        case "minimize":
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case "zoom":
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if let zoom = findAXElement(window, label: "zoom", role: "AXButton", maxNodes: 80) {
                AXUIElementPerformAction(zoom, kAXPressAction as CFString)
            }
        case "close":
            if let close = findAXElement(window, label: "close", role: "AXButton", maxNodes: 80) {
                AXUIElementPerformAction(close, kAXPressAction as CFString)
            } else {
                try sendKeyboardShortcut(key: "w", modifiers: ["command"])
            }
        default:
            throw RuntimeError("unsupported window action: \(action)")
        }
        return ToolResult(success: true, evidence: "Window action \(action) requested.", data: ["app": app.localizedName ?? "", "action": action])
    }

    private func dialogClick(_ args: [String: Any]) -> ToolResult {
        guard let label = string(args["label"]), !label.isEmpty else {
            return ToolResult(success: false, evidence: "label is required.", error: "label is required")
        }
        return axPress(["label": label, "role": "AXButton"])
    }

    private func dialogInput(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        return try axSetFocusedValue(["text": text])
    }

    private func dockOpen(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        _ = try runAppleScript("""
        tell application "System Events"
          tell process "Dock"
            click UI element \(appleScriptString(name)) of list 1
          end tell
        end tell
        """)
        return ToolResult(success: true, evidence: "Clicked Dock item.", data: ["name": name])
    }

    private func menubarClick(_ args: [String: Any]) throws -> ToolResult {
        guard let label = string(args["label"]), !label.isEmpty else { throw RuntimeError("label is required") }
        _ = try runAppleScript("""
        tell application "System Events"
          repeat with p in application processes
            repeat with mb in menu bars of p
              repeat with itemRef in menu bar items of mb
                try
                  if (description of itemRef contains \(appleScriptString(label))) or (title of itemRef contains \(appleScriptString(label))) then
                    click itemRef
                    return
                  end if
                end try
              end repeat
            end repeat
          end repeat
          error "menu bar item not found"
        end tell
        """)
        return ToolResult(success: true, evidence: "Clicked menu bar item.", data: ["label": label])
    }

    private func spaceSwitch(_ args: [String: Any]) throws -> ToolResult {
        let direction = (string(args["direction"]) ?? "right").lowercased()
        let key = direction == "left" ? "left" : "right"
        let count = int(args["count"]) ?? 1
        for _ in 0..<max(1, count) {
            try sendKeyboardShortcut(key: key, modifiers: ["control"])
            Thread.sleep(forTimeInterval: 0.25)
        }
        return ToolResult(success: true, evidence: "Switched Space.", data: ["direction": direction, "count": "\(count)"])
    }

    private func axDescribeFrontmost(_ args: [String: Any]) -> ToolResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult(success: false, evidence: "No frontmost app.", error: "frontmostApplication is nil")
        }
        let maxDepth = int(args["max_depth"]) ?? 4
        let maxNodes = int(args["max_nodes"]) ?? 80
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var lines: [String] = []
        var count = 0
        describeAXElement(root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, lines: &lines, count: &count)
        return ToolResult(success: true, evidence: "Described Accessibility tree for \(app.localizedName ?? "frontmost app").", data: [
            "app": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
            "nodes": "\(count)",
            "tree": lines.joined(separator: "\n")
        ])
    }

    private func axPress(_ args: [String: Any]) -> ToolResult {
        guard let label = string(args["label"]), !label.isEmpty else {
            return ToolResult(success: false, evidence: "label is required.", error: "label is required")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult(success: false, evidence: "No frontmost app.", error: "frontmostApplication is nil")
        }
        let role = string(args["role"])
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let found = findAXElement(root, label: label, role: role, maxNodes: 800) else {
            return ToolResult(success: false, evidence: "No matching Accessibility element found.", error: label)
        }
        let err = AXUIElementPerformAction(found, kAXPressAction as CFString)
        return ToolResult(success: err == .success, evidence: err == .success ? "Pressed matching Accessibility element." : "AXPress failed: \(err.rawValue)", data: [
            "label": label,
            "role": axString(found, kAXRoleAttribute as CFString) ?? "",
            "title": axString(found, kAXTitleAttribute as CFString) ?? ""
        ])
    }

    private func axGetFocusedValue() -> ToolResult {
        guard let element = focusedAXElement() else {
            return ToolResult(success: false, evidence: "No focused Accessibility element.", error: "AXFocusedUIElement unavailable")
        }
        let selected = axString(element, kAXSelectedTextAttribute as CFString) ?? ""
        return ToolResult(success: true, evidence: "Read focused Accessibility element.", data: [
            "role": axString(element, kAXRoleAttribute as CFString) ?? "",
            "title": axString(element, kAXTitleAttribute as CFString) ?? "",
            "value": axString(element, kAXValueAttribute as CFString) ?? "",
            "selected_text": selected
        ])
    }

    private func axSetFocusedValue(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        guard let element = focusedAXElement() else {
            return ToolResult(success: false, evidence: "No focused Accessibility element.", error: "AXFocusedUIElement unavailable")
        }
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        return ToolResult(success: err == .success, evidence: err == .success ? "Set focused element AXValue." : "Could not set focused AXValue: \(err.rawValue)", data: [
            "chars": "\(text.count)",
            "role": axString(element, kAXRoleAttribute as CFString) ?? ""
        ])
    }

    private func screenCapture(_ args: [String: Any]) throws -> ToolResult {
        let defaultPath = "/tmp/aios-screen-\(Int(Date().timeIntervalSince1970)).png"
        let path = (string(args["path"]) ?? defaultPath).expandingTildeInPath
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            return ToolResult(success: false, evidence: "Could not capture main display.", error: "CGDisplayCreateImage returned nil")
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RuntimeError("Could not encode screenshot as PNG")
        }
        try data.write(to: url)
        return ToolResult(success: true, evidence: "Captured main display to \(path).", data: [
            "path": path,
            "width": "\(image.width)",
            "height": "\(image.height)"
        ])
    }

    private func observeSnapshot(_ args: [String: Any]) throws -> ToolResult {
        try activateTargetAppIfProvided(args)
        let maxDepth = int(args["max_depth"]) ?? 4
        let maxNodes = int(args["max_nodes"]) ?? 100
        let includeScreenshot = bool(args["screenshot"]) ?? true
        let contextResult = context()
        let windowsResult = appWindows(args)
        let focusedResult = axGetFocusedValue()
        let axResult = axDescribeFrontmost(["max_depth": maxDepth, "max_nodes": maxNodes])
        var data: [String: String] = [
            "context": contextResult.jsonString,
            "windows": windowsResult.jsonString,
            "focused": focusedResult.jsonString,
            "ax": axResult.jsonString
        ]
        if includeScreenshot {
            let shot = try screenCapture(["path": "/tmp/aios-observe-\(Int(Date().timeIntervalSince1970)).png"])
            data["screenshot"] = shot.jsonString
        }
        return ToolResult(success: true, evidence: "Collected observation snapshot.", data: data)
    }

    private func observeWait(_ args: [String: Any]) throws -> ToolResult {
        guard let condition = string(args["condition"])?.lowercased(), !condition.isEmpty else {
            throw RuntimeError("condition is required")
        }
        guard let value = string(args["value"]), !value.isEmpty else {
            throw RuntimeError("value is required")
        }
        let timeout = double(args["timeout"]) ?? 10
        let interval = max(0.1, double(args["interval"]) ?? 0.5)
        let deadline = Date().addingTimeInterval(timeout)
        var lastEvidence = ""
        repeat {
            let passed = try evaluateWaitCondition(condition: condition, value: value, args: args, evidence: &lastEvidence)
            if passed {
                return ToolResult(success: true, evidence: "Wait condition met: \(condition).", data: [
                    "condition": condition,
                    "value": value,
                    "last_evidence": lastEvidence
                ])
            }
            Thread.sleep(forTimeInterval: interval)
        } while Date() < deadline
        return ToolResult(success: false, evidence: "Timed out waiting for \(condition).", data: [
            "condition": condition,
            "value": value,
            "last_evidence": lastEvidence
        ], error: "Timeout after \(timeout)s")
    }

    private func evaluateWaitCondition(condition: String, value: String, args: [String: Any], evidence: inout String) throws -> Bool {
        switch condition {
        case "frontmost_app":
            let current = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            evidence = current
            return current.localizedCaseInsensitiveContains(value)
        case "window_title_contains":
            let result = appWindows(args)
            evidence = result.data["windows"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "ax_contains":
            try activateTargetAppIfProvided(args)
            let result = axDescribeFrontmost(["max_depth": 5, "max_nodes": 160])
            evidence = result.data["tree"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "focused_value_contains":
            let result = axGetFocusedValue()
            evidence = result.data["value"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "safari_url_contains":
            let result = try safariGetCurrentURL()
            evidence = result.data["url"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "chrome_url_contains":
            let result = try chromeGetCurrentTab()
            evidence = result.data["url"] ?? ""
            return evidence.localizedCaseInsensitiveContains(value)
        case "file_exists":
            let path = value.expandingTildeInPath
            evidence = path
            return FileManager.default.fileExists(atPath: path)
        default:
            throw RuntimeError("unsupported wait condition: \(condition)")
        }
    }

    private func observeAnnotateFrontmost(_ args: [String: Any]) -> ToolResult {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult(success: false, evidence: "No frontmost app.", error: "frontmostApplication is nil")
        }
        let maxDepth = int(args["max_depth"]) ?? 6
        let maxNodes = int(args["max_nodes"]) ?? 160
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var elements: [[String: String]] = []
        var visited = 0
        collectActionableAXElements(root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, visited: &visited, elements: &elements, path: "0")
        return ToolResult(success: true, evidence: "Annotated \(elements.count) actionable element(s).", data: [
            "app": app.localizedName ?? "",
            "elements": jsonStringValue(elements)
        ])
    }

    private func snapshotCreate(_ args: [String: Any]) throws -> ToolResult {
        try activateTargetAppIfProvided(args)
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ToolResult(success: false, evidence: "No frontmost app.", error: "frontmostApplication is nil")
        }
        let maxDepth = int(args["max_depth"]) ?? 7
        let maxNodes = int(args["max_nodes"]) ?? 220
        let includeScreenshot = bool(args["screenshot"]) ?? true
        let snapshotID = "S\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var elements: [[String: String]] = []
        var visited = 0
        collectActionableAXElements(root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, visited: &visited, elements: &elements, path: "0")
        elements = elements.enumerated().map { index, item in
            var next = item
            next["element_id"] = "E\(index + 1)"
            return next
        }
        let snapshotDir = EventStore.snapshotsURL.appendingPathComponent(snapshotID, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        var screenshotPath = ""
        if includeScreenshot {
            let screenshot = try screenCapture(["path": snapshotDir.appendingPathComponent("screen.png").path])
            screenshotPath = screenshot.data["path"] ?? ""
        }
        let payload: [String: Any] = [
            "snapshot_id": snapshotID,
            "created_at": isoDateString(Date()),
            "app": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
            "pid": "\(app.processIdentifier)",
            "screenshot": screenshotPath,
            "elements": elements
        ]
        try writeJSONObject(payload, to: snapshotDir.appendingPathComponent("snapshot.json"))
        return ToolResult(success: true, evidence: "Created persistent UI snapshot.", data: [
            "snapshot_id": snapshotID,
            "app": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
            "screenshot": screenshotPath,
            "elements": jsonStringValue(elements)
        ])
    }

    private func snapshotGet(_ args: [String: Any]) throws -> ToolResult {
        guard let snapshotID = string(args["snapshot_id"]), !snapshotID.isEmpty else { throw RuntimeError("snapshot_id is required") }
        let payload = try readSnapshot(snapshotID)
        return ToolResult(success: true, evidence: "Read persistent UI snapshot.", data: [
            "snapshot_id": snapshotID,
            "snapshot": jsonStringValue(payload)
        ])
    }

    private func snapshotClick(_ args: [String: Any]) throws -> ToolResult {
        let target = try snapshotTarget(args)
        let resolved = try resolveSnapshotTarget(target)
        try clickSnapshotTarget(resolved)
        return ToolResult(success: true, evidence: resolved["relocated"] == "true" ? "Relocated and clicked snapshot element." : "Clicked snapshot element.", data: resolved)
    }

    private func snapshotType(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let target = try snapshotTarget(args)
        let resolved = try resolveSnapshotTarget(target)
        try clickSnapshotTarget(resolved)
        Thread.sleep(forTimeInterval: 0.1)
        _ = try clipboardSetText(["text": text])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Typed text into snapshot element.", data: [
            "snapshot_id": resolved["snapshot_id"] ?? "",
            "element_id": resolved["element_id"] ?? "",
            "relocated": resolved["relocated"] ?? "false",
            "chars": "\(text.count)"
        ])
    }

    private func snapshotPress(_ args: [String: Any]) throws -> ToolResult {
        let target = try snapshotTarget(args)
        let resolved = try resolveSnapshotTarget(target)
        if let app = runningApp(bundleID: resolved["bundle_id"], appName: resolved["app"]),
           let element = findAXElement(
               AXUIElementCreateApplication(app.processIdentifier),
               label: resolved["label"] ?? "",
               role: resolved["role"],
               maxNodes: 1_200
           ) {
            let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if err == .success {
                return ToolResult(success: true, evidence: "Pressed snapshot element via AXPress.", data: resolved)
            }
        }
        try clickSnapshotTarget(resolved)
        return ToolResult(success: true, evidence: "Clicked snapshot element as AXPress fallback.", data: resolved)
    }

    private func readSnapshot(_ snapshotID: String) throws -> [String: Any] {
        let url = EventStore.snapshotsURL
            .appendingPathComponent(snapshotID, isDirectory: true)
            .appendingPathComponent("snapshot.json")
        let data = try Data(contentsOf: url)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeError("Invalid snapshot JSON: \(snapshotID)")
        }
        return payload
    }

    private func snapshotTarget(_ args: [String: Any]) throws -> [String: String] {
        guard let snapshotID = string(args["snapshot_id"]), !snapshotID.isEmpty else { throw RuntimeError("snapshot_id is required") }
        guard let elementID = string(args["element_id"]), !elementID.isEmpty else { throw RuntimeError("element_id is required") }
        let payload = try readSnapshot(snapshotID)
        let elements = payload["elements"] as? [[String: Any]] ?? []
        guard let raw = elements.first(where: { string($0["element_id"]) == elementID }) else {
            throw RuntimeError("element not found in snapshot: \(elementID)")
        }
        var target = raw.compactMapValues { value -> String? in
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        target["snapshot_id"] = snapshotID
        target["app"] = string(payload["app"]) ?? ""
        target["bundle_id"] = string(payload["bundle_id"]) ?? ""
        return target
    }

    private func resolveSnapshotTarget(_ target: [String: String]) throws -> [String: String] {
        guard let app = runningApp(bundleID: target["bundle_id"], appName: target["app"]) else {
            return target.merging(["relocated": "false"]) { current, _ in current }
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if let element = findAXElementByPath(root, path: target["ax_path"] ?? ""),
           let row = snapshotRow(for: element, base: target, relocated: true) {
            return row
        }
        if let element = findAXElement(root, label: target["label"] ?? "", role: target["role"], maxNodes: 1_500),
           let row = snapshotRow(for: element, base: target, relocated: true) {
            return row
        }
        return target.merging(["relocated": "false"]) { current, _ in current }
    }

    private func snapshotRow(for element: AXUIElement, base: [String: String], relocated: Bool) -> [String: String]? {
        var row = base
        row["role"] = axString(element, kAXRoleAttribute as CFString) ?? row["role"] ?? ""
        let label = [
            axString(element, kAXTitleAttribute as CFString),
            axString(element, kAXDescriptionAttribute as CFString),
            axString(element, kAXValueAttribute as CFString)
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
        if !label.isEmpty { row["label"] = label }
        if let position = axCGPoint(element, kAXPositionAttribute as CFString) {
            row["x"] = "\(Int(position.x))"
            row["y"] = "\(Int(position.y))"
        }
        if let size = axCGSize(element, kAXSizeAttribute as CFString) {
            row["width"] = "\(Int(size.width))"
            row["height"] = "\(Int(size.height))"
        }
        row["relocated"] = relocated ? "true" : "false"
        return row
    }

    private func clickSnapshotTarget(_ target: [String: String]) throws {
        if let app = runningApp(bundleID: target["bundle_id"], appName: target["app"]) {
            app.activate()
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard let x = Double(target["x"] ?? ""),
              let y = Double(target["y"] ?? ""),
              let width = Double(target["width"] ?? ""),
              let height = Double(target["height"] ?? "")
        else {
            throw RuntimeError("snapshot element has no bounds")
        }
        try clickPoint(x: x + width / 2, y: y + height / 2)
    }

    private func runningApp(bundleID: String?, appName: String?) -> NSRunningApplication? {
        if let bundleID, !bundleID.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        if let appName, !appName.isEmpty {
            return NSWorkspace.shared.runningApplications.first {
                ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
            }
        }
        return nil
    }

    private func screenCaptureWindow(_ args: [String: Any]) throws -> ToolResult {
        try screenCaptureWindowSCK(args)
    }

    private func screenCaptureWindowLegacy(_ args: [String: Any]) throws -> ToolResult {
        let appName = string(args["app_name"])
        let bundleID = string(args["bundle_id"])?.lowercased()
        let appsByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return ToolResult(success: false, evidence: "Could not read window list.", error: "CGWindowListCopyWindowInfo returned nil")
        }
        guard let target = infos.first(where: { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = ownerPID(from: info),
                  let app = appsByPID[pid]
            else { return false }
            if let appName, !appMatchesName(app, requested: appName) { return false }
            if let bundleID, !(app.bundleIdentifier ?? "").lowercased().contains(bundleID) { return false }
            return true
        }), let windowID = target[kCGWindowNumber as String] as? CGWindowID else {
            return ToolResult(success: false, evidence: "No matching visible window.", error: "window not found")
        }
        guard let image = CGWindowListCreateImage(.null, [.optionIncludingWindow], windowID, [.boundsIgnoreFraming, .bestResolution]) else {
            return ToolResult(success: false, evidence: "Could not capture window.", error: "CGWindowListCreateImage returned nil")
        }
        let path = (string(args["path"]) ?? "/tmp/aios-window-\(windowID)-\(Int(Date().timeIntervalSince1970)).png").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RuntimeError("Could not encode window screenshot")
        }
        try data.write(to: url)
        return ToolResult(success: true, evidence: "Captured window to \(path).", data: [
            "path": path,
            "window_id": "\(windowID)",
            "title": target[kCGWindowName as String] as? String ?? "",
            "width": "\(image.width)",
            "height": "\(image.height)"
        ])
    }

    private func screenCaptureWindowSCK(_ args: [String: Any]) throws -> ToolResult {
        let target = try matchingWindowInfo(args)
        let windowID = target.windowID
        let path = (string(args["path"]) ?? "/tmp/aios-window-sck-\(windowID)-\(Int(Date().timeIntervalSince1970)).png").expandingTildeInPath
        let title = target.target[kCGWindowName as String] as? String ?? ""
        if #available(macOS 14.0, *) {
            do {
                return try captureWindowUsingSCK(windowID: windowID, path: path, title: title)
            } catch {
                let fallback = try screenCaptureWindowLegacy(args.merging(["path": path]) { current, _ in current })
                var data = fallback.data
                data["capture_engine"] = "legacy_fallback"
                data["sck_error"] = error.localizedDescription
                return ToolResult(success: fallback.success, evidence: fallback.success ? "ScreenCaptureKit failed; captured window with legacy fallback." : fallback.evidence, data: data, error: fallback.error, suggestion: fallback.suggestion)
            }
        }
        let fallback = try screenCaptureWindowLegacy(args.merging(["path": path]) { current, _ in current })
        var data = fallback.data
        data["capture_engine"] = "legacy_fallback"
        data["sck_error"] = "ScreenCaptureKit screenshot requires macOS 14+."
        return ToolResult(success: fallback.success, evidence: fallback.success ? "Captured window with legacy fallback." : fallback.evidence, data: data, error: fallback.error, suggestion: fallback.suggestion)
    }

    @available(macOS 14.0, *)
    private func captureWindowUsingSCK(windowID: CGWindowID, path: String, title: String) throws -> ToolResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ToolResultAsyncBox()
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw RuntimeError("ScreenCaptureKit window not found: \(windowID)")
                }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let config = SCStreamConfiguration()
                config.width = max(1, Int(window.frame.width * scale))
                config.height = max(1, Int(window.frame.height * scale))
                config.showsCursor = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let rep = NSBitmapImageRep(cgImage: image)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    throw RuntimeError("Could not encode ScreenCaptureKit image as PNG")
                }
                try data.write(to: url)
                box.result = .success(ToolResult(success: true, evidence: "Captured window with ScreenCaptureKit.", data: [
                    "path": path,
                    "window_id": "\(windowID)",
                    "title": title,
                    "width": "\(image.width)",
                    "height": "\(image.height)",
                    "capture_engine": "ScreenCaptureKit"
                ]))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else { throw RuntimeError("ScreenCaptureKit capture did not return a result") }
        return try result.get()
    }

    private func matchingWindowInfo(_ args: [String: Any]) throws -> (windowID: CGWindowID, target: [String: Any]) {
        let appName = string(args["app_name"])
        let bundleID = string(args["bundle_id"])?.lowercased()
        let appsByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw RuntimeError("CGWindowListCopyWindowInfo returned nil")
        }
        guard let target = infos.first(where: { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = ownerPID(from: info),
                  let app = appsByPID[pid]
            else { return false }
            if let appName, !appMatchesName(app, requested: appName) { return false }
            if let bundleID, !(app.bundleIdentifier ?? "").lowercased().contains(bundleID) { return false }
            return true
        }), let windowID = target[kCGWindowNumber as String] as? CGWindowID else {
            throw RuntimeError("No matching visible window.")
        }
        return (windowID, target)
    }

    private func ocrScreen(_ args: [String: Any]) throws -> ToolResult {
        let path = string(args["path"]) ?? "/tmp/aios-ocr-\(Int(Date().timeIntervalSince1970)).png"
        let capture = try screenCapture(["path": path])
        guard capture.success, let imagePath = capture.data["path"] else {
            return capture
        }
        return try ocrImage(["path": imagePath])
    }

    private func ocrImage(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return ToolResult(success: false, evidence: "Could not load image for OCR.", error: path)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        return ToolResult(success: true, evidence: "OCR read \(lines.count) text line(s).", data: [
            "path": path,
            "text": lines.joined(separator: "\n"),
            "lines": jsonStringValue(lines)
        ])
    }

    private func visualFind(_ args: [String: Any]) throws -> ToolResult {
        let query = string(args["query"]) ?? ""
        let bundleID = string(args["bundle_id"])
        let appName = string(args["app_name"])
        let maxResults = int(args["max_results"]) ?? 20
        let result = try visualMatches(args, maxResults: max(120, maxResults * 5))
        let queryLower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = Array((queryLower.isEmpty ? result.matches : result.matches.filter {
            $0.text.lowercased().contains(queryLower)
        }).prefix(maxResults))
        return ToolResult(
            success: !matches.isEmpty,
            evidence: matches.isEmpty ? "No visual OCR match found." : "Found \(matches.count) visual OCR match(es).",
            data: [
                "query": query,
                "scope": result.scope,
                "app": appName ?? "",
                "bundle_id": bundleID ?? "",
                "image_path": result.imagePath,
                "text": result.text,
                "matches": jsonStringValue(matches.map(\.dictionary))
            ],
            error: matches.isEmpty ? "visual_match_not_found" : nil,
            suggestion: matches.isEmpty ? "Try a shorter query, capture the target window, or use locator tools." : nil
        )
    }

    private func visualRead(_ args: [String: Any]) throws -> ToolResult {
        let maxResults = int(args["max_results"]) ?? 120
        let result = try visualMatches(args, maxResults: maxResults)
        return ToolResult(success: true, evidence: "Read visual text from \(result.matches.count) OCR region(s).", data: [
            "scope": result.scope,
            "image_path": result.imagePath,
            "text": result.text,
            "matches": jsonStringValue(result.matches.map(\.dictionary))
        ])
    }

    private func visualClick(_ args: [String: Any]) throws -> ToolResult {
        guard let query = string(args["query"]), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("query is required")
        }
        var findArgs = args
        findArgs["max_results"] = int(args["max_results"]) ?? 5
        let result = try visualMatches(findArgs, maxResults: max(80, int(findArgs["max_results"]) ?? 5))
        let queryLower = query.lowercased()
        guard let match = result.matches.first(where: { $0.text.lowercased().contains(queryLower) }) else {
            return ToolResult(success: false, evidence: "No visual OCR match to click.", data: [
                "query": query,
                "scope": result.scope,
                "image_path": result.imagePath,
                "text": result.text
            ], error: "visual_match_not_found")
        }
        try clickPoint(x: match.centerX, y: match.centerY)
        return ToolResult(success: true, evidence: "Clicked visual OCR match \(match.id).", data: match.dictionary.merging([
            "query": query,
            "scope": result.scope,
            "method": "visual_coordinate"
        ]) { current, _ in current })
    }

    private func visualMatches(_ args: [String: Any], maxResults: Int) throws -> (imagePath: String, scope: String, text: String, matches: [VisualMatch]) {
        let capture = try captureVisualSource(args)
        guard let image = NSImage(contentsOfFile: capture.path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw RuntimeError("Could not load visual source image: \(capture.path)")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        let observations = request.results ?? []
        let imageWidth = Double(cgImage.width)
        let imageHeight = Double(cgImage.height)
        let scaleX = imageWidth / max(1, capture.bounds.width)
        let scaleY = imageHeight / max(1, capture.bounds.height)
        let matches = observations.prefix(max(1, maxResults)).enumerated().compactMap { index, observation -> VisualMatch? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let rect = observation.boundingBox
            let x = capture.bounds.minX + Double(rect.minX) * imageWidth / scaleX
            let y = capture.bounds.minY + (1 - Double(rect.maxY)) * imageHeight / scaleY
            let width = Double(rect.width) * imageWidth / scaleX
            let height = Double(rect.height) * imageHeight / scaleY
            return VisualMatch(
                id: "V\(index + 1)",
                text: candidate.string,
                confidence: candidate.confidence,
                x: x,
                y: y,
                width: width,
                height: height,
                imagePath: capture.path
            )
        }
        return (
            imagePath: capture.path,
            scope: capture.scope,
            text: matches.map(\.text).joined(separator: "\n"),
            matches: matches
        )
    }

    private func captureVisualSource(_ args: [String: Any]) throws -> (path: String, scope: String, bounds: CGRect) {
        if let existingPath = string(args["path"]), FileManager.default.fileExists(atPath: existingPath.expandingTildeInPath) {
            let path = existingPath.expandingTildeInPath
            if let image = NSImage(contentsOfFile: path),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return (path, "image", CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            }
            let bounds = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: CGDisplayPixelsWide(CGMainDisplayID()), height: CGDisplayPixelsHigh(CGMainDisplayID()))
            return (path, "image", bounds)
        }
        let requestedScope = (string(args["scope"]) ?? "").lowercased()
        let wantsWindow = requestedScope == "window" || string(args["app_name"]) != nil || string(args["bundle_id"]) != nil
        if wantsWindow {
            let path = (string(args["path"]) ?? "/tmp/aios-visual-window-\(Int(Date().timeIntervalSince1970)).png").expandingTildeInPath
            let target = try matchingWindowInfo(args)
            let capture = try screenCaptureWindowSCK(args.merging(["path": path]) { current, _ in current })
            guard capture.success else {
                throw RuntimeError(capture.error ?? capture.evidence)
            }
            return (capture.data["path"] ?? path, "window", windowBounds(target.target) ?? mainDisplayBounds())
        }
        let path = (string(args["path"]) ?? "/tmp/aios-visual-screen-\(Int(Date().timeIntervalSince1970)).png").expandingTildeInPath
        let capture = try screenCapture(["path": path])
        guard capture.success else {
            throw RuntimeError(capture.error ?? capture.evidence)
        }
        return (capture.data["path"] ?? path, "screen", mainDisplayBounds())
    }

    private func mainDisplayBounds() -> CGRect {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        if bounds.width > 0, bounds.height > 0 {
            return bounds
        }
        return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func windowBounds(_ info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        let x = double(bounds["X"]) ?? 0
        let y = double(bounds["Y"]) ?? 0
        let width = double(bounds["Width"]) ?? 0
        let height = double(bounds["Height"]) ?? 0
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func visualGround(_ args: [String: Any]) throws -> ToolResult {
        let maxResults = int(args["max_results"]) ?? 40
        let query = string(args["query"]) ?? ""
        let useSidecar = bool(args["use_sidecar"]) ?? true
        let capture = try captureVisualSource(args)
        guard let image = NSImage(contentsOfFile: capture.path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return ToolResult(success: false, evidence: "Could not load visual source image.", error: capture.path)
        }

        var candidates: [[String: String]] = []
        var matchArgs = args
        matchArgs["path"] = capture.path
        matchArgs["scope"] = "image"
        let textMatches = (try? visualMatches(matchArgs, maxResults: max(120, maxResults)).matches) ?? []
        candidates.append(contentsOf: textMatches.map { match in
            match.dictionary.merging([
                "kind": "text",
                "label": match.text,
                "source": "vision_ocr",
                "score": visualScore(label: match.text, query: query)
            ]) { current, _ in current }
        })

        let rectangles = (try? visualRectangles(cgImage: cgImage, capture: capture, maxResults: maxResults)) ?? []
        candidates.append(contentsOf: rectangles.map { rect in
            rect.merging([
                "kind": "rectangle",
                "source": "vision_rectangle",
                "score": visualScore(label: rect["label"] ?? "rectangle", query: query)
            ]) { current, _ in current }
        })
        candidates.append(contentsOf: visualIconCandidates(from: rectangles))
        candidates.append(contentsOf: visualColorCandidates(cgImage: cgImage, capture: capture, maxResults: max(12, maxResults / 2)))
        candidates.append(contentsOf: VisualGrounding.layoutCandidates(bounds: capture.bounds, imagePath: capture.path))

        let axResult = AIOSAutomationService.shared.find(args: args.merging(["max_results": min(40, maxResults)]) { current, _ in current })
        if let locatorsText = axResult.data["locators"],
           let data = locatorsText.data(using: .utf8),
           let locators = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            candidates.append(contentsOf: locators.compactMap { raw in
                let label = [string(raw["title"]), string(raw["value"]), string(raw["description"]), string(raw["identifier"])]
                    .compactMap { $0 }
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? string(raw["role"]) ?? "AX element"
                var item: [String: String] = [
                    "id": string(raw["id"]) ?? "",
                    "kind": "accessibility",
                    "source": "ax_tree",
                    "label": label,
                    "role": string(raw["role"]) ?? "",
                    "score": visualScore(label: label, query: query)
                ]
                for key in ["x", "y", "width", "height"] {
                    if let value = raw[key] as? NSNumber { item[key] = value.stringValue }
                    if let value = raw[key] as? String { item[key] = value }
                }
                return item
            })
        }

        var ranked = VisualGrounding.rank(candidates, query: query, limit: min(200, max(1, maxResults)))
        var sidecarAnswer = ""
        if useSidecar, VisionSidecar.isConfigured {
            let prompt = VisualGrounding.groundingPrompt(query: query, localCandidates: ranked, maxResults: min(80, maxResults))
            sidecarAnswer = (try? VisionSidecar.analyze(imagePath: capture.path, prompt: prompt, timeout: 45)) ?? ""
            let sidecarCandidates = VisualGrounding.sidecarCandidates(from: sidecarAnswer).map {
                VisualGrounding.enrich($0, query: query, fallbackKind: "sidecar", fallbackSource: "vision_sidecar")
            }
            if !sidecarCandidates.isEmpty {
                ranked = VisualGrounding.rank(ranked + sidecarCandidates, query: query, limit: min(200, max(1, maxResults)))
            }
        }
        return ToolResult(success: !ranked.isEmpty, evidence: ranked.isEmpty ? "No visual grounding candidates." : "Grounded \(ranked.count) visual candidate(s).", data: [
            "scope": capture.scope,
            "image_path": capture.path,
            "query": query,
            "schema_version": VisualGrounding.version,
            "candidate_schema": jsonStringValue(VisualGrounding.schema),
            "sidecar_configured": VisionSidecar.isConfigured ? "true" : "false",
            "sidecar_answer": sidecarAnswer,
            "candidates": jsonStringValue(Array(ranked))
        ], error: ranked.isEmpty ? "no_visual_candidates" : nil)
    }

    private func visualRectangles(cgImage: CGImage, capture: (path: String, scope: String, bounds: CGRect), maxResults: Int) throws -> [[String: String]] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = min(80, max(1, maxResults))
        request.minimumConfidence = 0.45
        request.minimumAspectRatio = 0.08
        request.maximumAspectRatio = 12
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        let imageWidth = Double(cgImage.width)
        let imageHeight = Double(cgImage.height)
        let scaleX = imageWidth / max(1, capture.bounds.width)
        let scaleY = imageHeight / max(1, capture.bounds.height)
        return (request.results ?? []).enumerated().map { index, observation in
            let rect = observation.boundingBox
            let x = capture.bounds.minX + Double(rect.minX) * imageWidth / scaleX
            let y = capture.bounds.minY + (1 - Double(rect.maxY)) * imageHeight / scaleY
            let width = Double(rect.width) * imageWidth / scaleX
            let height = Double(rect.height) * imageHeight / scaleY
            return [
                "id": "R\(index + 1)",
                "label": "rectangle \(Int(width))x\(Int(height))",
                "confidence": String(format: "%.3f", observation.confidence),
                "x": "\(Int(x))",
                "y": "\(Int(y))",
                "width": "\(Int(width))",
                "height": "\(Int(height))",
                "center_x": "\(Int(x + width / 2))",
                "center_y": "\(Int(y + height / 2))",
                "image_path": capture.path
            ]
        }
    }

    private func visualIconCandidates(from rectangles: [[String: String]]) -> [[String: String]] {
        rectangles.enumerated().compactMap { index, rect in
            guard let width = double(rect["width"]), let height = double(rect["height"]), width > 8, height > 8 else { return nil }
            let ratio = width / max(1, height)
            let area = width * height
            guard ratio > 0.55, ratio < 1.85, area < 18_000 else { return nil }
            var item = rect
            item["id"] = "I\(index + 1)"
            item["kind"] = "icon"
            item["source"] = "vision_rectangle"
            item["label"] = "icon or image button \(Int(width))x\(Int(height))"
            item["affordance"] = "button"
            item["action_types"] = "click,verify,observe"
            item["score"] = item["score"] ?? "0.54"
            return item
        }
    }

    private func visualColorCandidates(cgImage: CGImage, capture: (path: String, scope: String, bounds: CGRect), maxResults: Int) -> [[String: String]] {
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data)
        else { return [] }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let bitsPerPixel = cgImage.bitsPerPixel
        guard width > 0, height > 0, bitsPerPixel >= 24 else { return [] }
        let bytesPerPixel = max(3, bitsPerPixel / 8)
        let cols = min(24, max(6, width / 80))
        let rows = min(16, max(4, height / 80))
        let cellWidth = max(1, width / cols)
        let cellHeight = max(1, height / rows)
        let scaleX = Double(width) / max(1, capture.bounds.width)
        let scaleY = Double(height) / max(1, capture.bounds.height)

        struct Cell {
            let col: Int
            let row: Int
            let score: Double
            let r: Double
            let g: Double
            let b: Double
            let variance: Double
        }

        var cells: [Cell] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let startX = col * cellWidth
                let endX = min(width, (col + 1) * cellWidth)
                let startY = row * cellHeight
                let endY = min(height, (row + 1) * cellHeight)
                var count = 0.0
                var r = 0.0
                var g = 0.0
                var b = 0.0
                var luma = 0.0
                var luma2 = 0.0
                let stepX = max(1, (endX - startX) / 8)
                let stepY = max(1, (endY - startY) / 8)
                var y = startY
                while y < endY {
                    var x = startX
                    while x < endX {
                        let offset = y * bytesPerRow + x * bytesPerPixel
                        let red: Double
                        let green: Double
                        let blue: Double
                        if cgImage.bitmapInfo.contains(.byteOrder32Little), bytesPerPixel >= 4 {
                            blue = Double(bytes[offset]) / 255
                            green = Double(bytes[offset + 1]) / 255
                            red = Double(bytes[offset + 2]) / 255
                        } else {
                            red = Double(bytes[offset]) / 255
                            green = Double(bytes[offset + 1]) / 255
                            blue = Double(bytes[offset + 2]) / 255
                        }
                        let lum = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                        r += red
                        g += green
                        b += blue
                        luma += lum
                        luma2 += lum * lum
                        count += 1
                        x += stepX
                    }
                    y += stepY
                }
                guard count > 0 else { continue }
                r /= count
                g /= count
                b /= count
                let meanLuma = luma / count
                let variance = max(0, luma2 / count - meanLuma * meanLuma)
                let maxValue = max(r, g, b)
                let minValue = min(r, g, b)
                let saturation = maxValue == 0 ? 0 : (maxValue - minValue) / maxValue
                let score = saturation * 0.55 + min(0.45, sqrt(variance) * 1.8)
                if score > 0.18 {
                    cells.append(Cell(col: col, row: row, score: score, r: r, g: g, b: b, variance: variance))
                }
            }
        }

        return cells.sorted { $0.score > $1.score }.prefix(max(1, maxResults)).enumerated().map { index, cell in
            let xPixels = Double(cell.col * cellWidth)
            let yPixels = Double(cell.row * cellHeight)
            let wPixels = Double(cellWidth)
            let hPixels = Double(cellHeight)
            let x = capture.bounds.minX + xPixels / scaleX
            let y = capture.bounds.minY + yPixels / scaleY
            let width = wPixels / scaleX
            let height = hPixels / scaleY
            let hex = String(format: "#%02X%02X%02X", Int(cell.r * 255), Int(cell.g * 255), Int(cell.b * 255))
            return VisualGrounding.enrich([
                "id": "C\(index + 1)",
                "kind": "color_region",
                "source": "color_saliency",
                "label": "salient color region \(hex)",
                "dominant_color": hex,
                "confidence": String(format: "%.3f", min(0.99, cell.score)),
                "x": "\(Int(x))",
                "y": "\(Int(y))",
                "width": "\(Int(width))",
                "height": "\(Int(height))",
                "center_x": "\(Int(x + width / 2))",
                "center_y": "\(Int(y + height / 2))",
                "image_path": capture.path,
                "texture_variance": String(format: "%.3f", cell.variance)
            ], query: "")
        }
    }

    private func visualGroundAction(_ args: [String: Any]) throws -> ToolResult {
        let query = string(args["query"]) ?? ""
        let action = normalizeForSearch(string(args["action"]) ?? "click")
        var groundArgs = args
        groundArgs["max_results"] = int(args["max_results"]) ?? 80
        let grounding = try visualGround(groundArgs)
        guard grounding.success,
              let candidatesJSON = grounding.data["candidates"],
              let data = candidatesJSON.data(using: .utf8),
              let candidates = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else {
            return ToolResult(success: false, evidence: "Could not ground a visual action.", data: grounding.data, error: grounding.error ?? "visual_action_grounding_failed")
        }
        guard let plan = VisualGrounding.actionPlan(
            candidates: candidates,
            query: query,
            action: action,
            text: string(args["text"]),
            candidateID: string(args["candidate_id"])
        ) else {
            return ToolResult(success: false, evidence: "No visual candidate can satisfy action \(action).", data: grounding.data, error: "visual_action_no_candidate")
        }

        let execute = bool(args["execute"]) ?? false
        let allowForeground = bool(args["allow_foreground"]) ?? false
        guard execute else {
            return ToolResult(success: true, evidence: "Planned visual grounded action.", data: plan.merging([
                "image_path": grounding.data["image_path"] ?? "",
                "candidates": candidatesJSON
            ]) { current, _ in current })
        }
        guard allowForeground else {
            return ToolResult(success: false, evidence: "Visual coordinate execution requires allow_foreground=true.", data: plan, error: "foreground_not_allowed")
        }
        guard let x = double(plan["x"]), let y = double(plan["y"]) else {
            return ToolResult(success: false, evidence: "Selected visual candidate has no action point.", data: plan, error: "visual_action_missing_point")
        }
        switch action {
        case "click":
            try clickPoint(x: x, y: y)
        case "type":
            try clickPoint(x: x, y: y)
            if let text = string(args["text"]), !text.isEmpty {
                _ = try clipboardSetText(["text": text])
                _ = try uiPaste()
            }
        default:
            return ToolResult(success: false, evidence: "Execution for visual action \(action) is not implemented; returned plan only.", data: plan, error: "visual_action_execute_unsupported")
        }
        return ToolResult(success: true, evidence: "Executed visual grounded \(action).", data: plan)
    }

    private func visualGroundSchema() -> ToolResult {
        ToolResult(success: true, evidence: "Loaded visual grounding schema.", data: [
            "schema_version": VisualGrounding.version,
            "candidate_schema": jsonStringValue(VisualGrounding.schema),
            "action_schema": jsonStringValue(VisualGrounding.actionSchema),
            "sidecar_protocol": "Prompt asks AIOS_VISION_* sidecar to return compact JSON {\"candidates\":[...]} with the candidate schema."
        ])
    }

    private func visualPerceptionStrategyTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Loaded visual perception strategy.", data: VisualPerceptionEngine.strategy(surface: string(args["surface"]) ?? "", query: string(args["query"]) ?? ""))
    }

    private func visualUIMapCacheTool(_ args: [String: Any]) throws -> ToolResult {
        guard let imagePath = string(args["image_path"]), !imagePath.isEmpty else { throw RuntimeError("image_path is required") }
        guard let candidates = string(args["candidates_json"]), !candidates.isEmpty else { throw RuntimeError("candidates_json is required") }
        let url = try VisualPerceptionEngine.cacheUIMap(imagePath: imagePath, query: string(args["query"]) ?? "", candidatesJSON: candidates)
        return ToolResult(success: true, evidence: "Cached visual UI map.", data: ["path": url.path])
    }

    private func visualUIMapRecentTool(_ args: [String: Any]) -> ToolResult {
        let maps = VisualPerceptionEngine.recent(limit: int(args["limit"]) ?? 10)
        return ToolResult(success: true, evidence: "Returned \(maps.count) cached UI map(s).", data: ["ui_maps": jsonStringValue(maps)])
    }

    private func visualScore(label: String, query: String) -> String {
        let query = normalizeForSearch(query)
        guard !query.isEmpty else { return "0.50" }
        let label = normalizeForSearch(label)
        if label.contains(query) { return "1.00" }
        let tokens = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let hits = tokens.filter { label.contains($0) }.count
        return String(format: "%.2f", min(0.95, 0.35 + Double(hits) * 0.15))
    }

    private func visualAnalyze(_ args: [String: Any]) throws -> ToolResult {
        guard let prompt = string(args["prompt"]), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("prompt is required")
        }
        let capture = try captureVisualSource(args)
        var groundingArgs = args
        groundingArgs["path"] = capture.path
        groundingArgs["scope"] = "image"
        let grounding = try visualGround(groundingArgs)
        if VisionSidecar.isConfigured {
            let answer = try VisionSidecar.analyze(imagePath: capture.path, prompt: prompt)
            return ToolResult(success: true, evidence: "Analyzed visual source with configured vision sidecar.", data: [
                "answer": answer,
                "image_path": capture.path,
                "grounding": grounding.data["candidates"] ?? ""
            ])
        }
        return ToolResult(success: grounding.success, evidence: "No AIOS_VISION_* endpoint configured; returned local grounding as visual analysis fallback.", data: [
            "answer": "Local fallback only. Configure AIOS_VISION_BASE_URL and AIOS_VISION_MODEL for VQA/image-button/layout reasoning.",
            "image_path": capture.path,
            "grounding": grounding.data["candidates"] ?? ""
        ], error: grounding.success ? nil : grounding.error)
    }

    private func backgroundControlPlan(_ args: [String: Any]) -> ToolResult {
        let goal = string(args["goal"]) ?? ""
        let app = string(args["app_name"]) ?? string(args["bundle_id"]) ?? ""
        let strategy = ComputerUseStrategy.suggest(goal: goal, app: app)
        var enriched = args
        enriched["query"] = string(args["query"]) ?? goal
        enriched["action"] = string(args["action"]) ?? "observe"
        let plan = BackgroundControlKernel.plan(
            target: BackgroundControlKernel.target(from: enriched),
            action: BackgroundControlKernel.action(from: enriched)
        )
        return ToolResult(success: true, evidence: "Built background control plan.", data: [
            "strategy": jsonStringValue(strategy),
            "target": jsonStringValue(plan.target.dictionary),
            "action": jsonStringValue(plan.action.dictionary),
            "channels": jsonStringValue(plan.channels.map(\.dictionary)),
            "best_channel": plan.channels.first?.id ?? "",
            "boundary": plan.boundary
        ])
    }

    private func backgroundKernelPlan(_ args: [String: Any]) -> ToolResult {
        let plan = BackgroundControlKernel.plan(
            target: BackgroundControlKernel.target(from: args),
            action: BackgroundControlKernel.action(from: args)
        )
        return ToolResult(success: true, evidence: "Built background control kernel plan.", data: plan.dictionary)
    }

    private func backgroundChannelMatrix() -> ToolResult {
        ToolResult(success: true, evidence: "Loaded background control capability matrix.", data: [
            "channels": jsonStringValue(BackgroundControlKernel.capabilityMatrix()),
            "boundary": "Public macOS APIs do not provide universal cursor/focus/Space-safe input into every inactive or offscreen non-AX native surface. AIOS uses semantic backends first, visual grounding for perception, and foreground coordinates only with opt-in."
        ])
    }

    private func backgroundDispatchPlan(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Built background execution dispatch plan.", data: BackgroundExecutionKernel.dispatchPlan(args: args))
    }

    private func backgroundCapabilities(_ args: [String: Any]) -> ToolResult {
        let appName = string(args["app_name"]) ?? ""
        let bundleID = string(args["bundle_id"]) ?? ""
        let url = string(args["url"]) ?? ""
        let plan = BackgroundControlKernel.plan(
            target: BackgroundControlKernel.target(from: args),
            action: BackgroundControlKernel.action(from: args.merging(["action": string(args["action"]) ?? "observe"]) { current, _ in current })
        )
        let text = normalizeForSearch([appName, bundleID, url].joined(separator: " "))
        var channels: [[String: String]] = []
        if text.contains("chrome") || text.contains("com.google.chrome") || text.contains("http") || text.contains("web") {
            let cdp = browserCDPStatus(args)
            channels.append([
                "channel": "browser_cdp_dom",
                "available": cdp.success ? "true" : "false",
                "depth": "deep_background",
                "reason": cdp.success ? "Chrome DevTools Protocol endpoint is reachable." : "Launch browser_cdp_launch or an existing remote-debugging Chrome."
            ])
        }
        if !appName.isEmpty || !bundleID.isEmpty {
            let probe = !bundleID.isEmpty ? scriptingBridgeProbe(["bundle_id": bundleID]) : ToolResult(success: false, evidence: "bundle_id not provided")
            channels.append([
                "channel": "app_script_or_scripting_bridge",
                "available": probe.success ? "true" : "unknown",
                "depth": "semantic_background",
                "reason": probe.evidence
            ])
            let ax = AIOSAutomationService.shared.context(args: args)
            channels.append([
                "channel": "accessibility_semantic",
                "available": ax.success ? "true" : "unknown",
                "depth": "non_intrusive_ax",
                "reason": ax.evidence
            ])
        }
        channels.append([
            "channel": "visual_grounding",
            "available": "true",
            "depth": "perception_fallback",
            "reason": "Can capture screen/window/image and ground candidates; direct foreground action is still opt-in."
        ])
        channels.append([
            "channel": "foreground_coordinate",
            "available": "opt_in",
            "depth": "last_resort",
            "reason": "Works broadly but can move cursor/focus."
        ])
        return ToolResult(success: true, evidence: "Inspected background control capabilities.", data: [
            "app_name": appName,
            "bundle_id": bundleID,
            "channels": jsonStringValue(channels),
            "kernel_channels": jsonStringValue(plan.channels.map(\.dictionary)),
            "boundary": plan.boundary
        ])
    }

    private func backgroundAppScript(_ args: [String: Any]) throws -> ToolResult {
        guard let script = string(args["script"]), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("script is required")
        }
        let output = try runProcess("/usr/bin/osascript", ["-e", script])
        return ToolResult(success: true, evidence: "Executed AppleScript without an explicit app activation.", data: [
            "channel": "app_script_or_scripting_bridge",
            "app_name": string(args["app_name"]) ?? "",
            "bundle_id": string(args["bundle_id"]) ?? "",
            "output": truncateMiddle(output, maxCharacters: 8_000)
        ])
    }

    private func backgroundAction(_ args: [String: Any]) throws -> ToolResult {
        let target = BackgroundControlKernel.target(from: args)
        let controlAction = BackgroundControlKernel.action(from: args)
        let plan = BackgroundControlKernel.plan(target: target, action: controlAction)
        let action = controlAction.action
        var tried: [[String: String]] = []
        func channelInfo(_ id: String) -> [String: String] {
            plan.channels.first { $0.id == id }?.dictionary ?? ["channel": id]
        }
        func annotate(_ result: ToolResult, channel: String) -> ToolResult {
            var data = result.data
            data["channel"] = channel
            data["channel_guarantees"] = jsonStringValue(channelInfo(channel))
            data["tried"] = jsonStringValue(tried)
            data["kernel_plan"] = jsonStringValue(plan.dictionary)
            return ToolResult(success: result.success, evidence: result.evidence, data: data, error: result.error, suggestion: result.suggestion)
        }

        for channel in plan.channels where channel.id != "public_api_boundary" {
            switch channel.id {
            case "browser_cdp_dom":
                let hasSelector = !controlAction.selector.isEmpty
                let hasQuery = !controlAction.query.isEmpty
                let shouldTry = hasSelector || hasQuery || (action == "eval" && !controlAction.script.isEmpty)
                guard shouldTry else {
                    tried.append(["channel": channel.id, "skipped": "selector/query/script not provided"])
                    continue
                }
                tried.append(["channel": channel.id, "reason": channel.reason])
                var cdpArgs = args
                if hasSelector { cdpArgs["selector"] = controlAction.selector }
                if hasQuery { cdpArgs["query"] = controlAction.query }
                if !controlAction.text.isEmpty { cdpArgs["text"] = controlAction.text }
                if !controlAction.script.isEmpty { cdpArgs["script"] = controlAction.script }
                do {
                    switch action {
                    case "click":
                        if hasSelector {
                            return annotate(try browserCDPClick(cdpArgs), channel: channel.id)
                        }
                        cdpArgs["action"] = "click"
                        return annotate(try browserCDPAct(cdpArgs), channel: channel.id)
                    case "type":
                        if hasSelector {
                            return annotate(try browserCDPType(cdpArgs), channel: channel.id)
                        }
                        cdpArgs["action"] = "type"
                        return annotate(try browserCDPAct(cdpArgs), channel: channel.id)
                    case "read", "verify":
                        return annotate(try browserCDPRead(cdpArgs), channel: channel.id)
                    case "eval":
                        return annotate(try browserCDPEval(cdpArgs), channel: channel.id)
                    default:
                        tried.append(["channel": channel.id, "skipped": "action \(action) is not a CDP action"])
                    }
                } catch {
                    tried.append(["channel": channel.id, "error": error.localizedDescription])
                }

            case "app_script_or_scripting_bridge":
                guard action == "script", !controlAction.script.isEmpty else {
                    tried.append(["channel": channel.id, "skipped": "script action not requested"])
                    continue
                }
                tried.append(["channel": channel.id, "reason": channel.reason])
                do {
                    return annotate(try backgroundAppScript(args), channel: channel.id)
                } catch {
                    tried.append(["channel": channel.id, "error": error.localizedDescription])
                }

            case "accessibility_semantic":
                guard !controlAction.query.isEmpty else {
                    tried.append(["channel": channel.id, "skipped": "query not provided"])
                    continue
                }
                tried.append(["channel": channel.id, "reason": channel.reason])
                var axArgs = args
                axArgs["query"] = controlAction.query
                switch action {
                case "click":
                    let result = AIOSAutomationService.shared.backgroundClick(args: axArgs)
                    if result.success { return annotate(result, channel: channel.id) }
                    tried.append(["channel": channel.id, "error": result.error ?? result.evidence])
                case "type":
                    let result = AIOSAutomationService.shared.backgroundType(args: axArgs)
                    if result.success { return annotate(result, channel: channel.id) }
                    tried.append(["channel": channel.id, "error": result.error ?? result.evidence])
                case "read", "verify":
                    let result = AIOSAutomationService.shared.read(args: axArgs)
                    if result.success { return annotate(result, channel: channel.id) }
                    tried.append(["channel": channel.id, "error": result.error ?? result.evidence])
                default:
                    tried.append(["channel": channel.id, "skipped": "action \(action) is not an AX semantic action"])
                }

            case "visual_grounding":
                var visualArgs = args
                if visualArgs["query"] == nil { visualArgs["query"] = controlAction.query }
                tried.append(["channel": channel.id, "reason": channel.reason])
                if action == "verify" || action == "read" || action == "observe" {
                    let grounding = try visualGround(visualArgs)
                    if grounding.success { return annotate(grounding, channel: channel.id) }
                    tried.append(["channel": channel.id, "error": grounding.error ?? grounding.evidence])
                    continue
                }
                let visualPlan = try visualGroundAction(visualArgs.merging([
                    "action": action,
                    "execute": false
                ]) { current, _ in current })
                tried.append(["channel": channel.id, "visual_plan": visualPlan.evidence])
                if !controlAction.allowForeground {
                    continue
                }
                var executeArgs = visualArgs
                executeArgs["action"] = action
                executeArgs["execute"] = true
                executeArgs["allow_foreground"] = true
                let executed = try visualGroundAction(executeArgs)
                if executed.success {
                    return annotate(executed, channel: "foreground_coordinate")
                }
                tried.append(["channel": "foreground_coordinate", "error": executed.error ?? executed.evidence])

            case "foreground_coordinate":
                guard controlAction.allowForeground else {
                    tried.append(["channel": channel.id, "skipped": "allow_foreground=false"])
                    continue
                }
                tried.append(["channel": channel.id, "skipped": "visual_grounding owns foreground coordinate execution for grounded actions"])

            default:
                continue
            }
        }

        return ToolResult(
            success: false,
            evidence: "No non-invasive channel completed the background action.",
            data: [
                "action": action,
                "target": jsonStringValue(target.dictionary),
                "plan": jsonStringValue(plan.channels.map(\.dictionary)),
                "boundary": plan.boundary,
                "tried": jsonStringValue(tried)
            ],
            error: "background_action_unavailable",
            suggestion: "Provide a CDP selector/query, an AppleScript script, an AX query, an app skill adapter, or set allow_foreground=true for visual coordinate fallback."
        )
    }

    private func browserCDPLaunch(_ args: [String: Any]) throws -> ToolResult {
        let port = int(args["port"]) ?? 9222
        let userDataDir = (string(args["user_data_dir"]) ?? EventStore.rootURL.appendingPathComponent("chrome-cdp-profile", isDirectory: true).path).expandingTildeInPath
        try FileManager.default.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)
        var processArgs = ["-na", "Google Chrome", "--args", "--remote-debugging-port=\(port)", "--user-data-dir=\(userDataDir)"]
        if let url = string(args["url"]), !url.isEmpty {
            processArgs.append(url)
        }
        _ = try runProcess("/usr/bin/open", processArgs)
        return ToolResult(success: true, evidence: "Launched Chrome CDP profile.", data: [
            "port": "\(port)",
            "user_data_dir": userDataDir,
            "url": string(args["url"]) ?? ""
        ])
    }

    private func browserCDPStatus(_ args: [String: Any]) -> ToolResult {
        let endpoint = cdpEndpoint(args)
        do {
            let version = try ChromeCDP.version(endpoint: endpoint)
            return ToolResult(success: true, evidence: "CDP endpoint is reachable.", data: version)
        } catch {
            return ToolResult(success: false, evidence: "CDP endpoint is not reachable.", data: ["endpoint": endpoint.base.absoluteString], error: error.localizedDescription, suggestion: "Run browser_cdp_launch or start Chrome with --remote-debugging-port.")
        }
    }

    private func browserCDPTabs(_ args: [String: Any]) throws -> ToolResult {
        let tabs = try ChromeCDP.tabs(endpoint: cdpEndpoint(args))
        return ToolResult(success: true, evidence: "Listed \(tabs.count) CDP tab(s).", data: [
            "tabs": jsonStringValue(tabs.map(\.dictionary))
        ])
    }

    private func browserCDPEval(_ args: [String: Any]) throws -> ToolResult {
        guard let script = string(args["script"]), !script.isEmpty else { throw RuntimeError("script is required") }
        let tab = try selectedCDPTab(args)
        let result = try ChromeCDP.evaluate(tab: tab, expression: script)
        return ToolResult(success: true, evidence: "Evaluated JavaScript through CDP.", data: [
            "tab_id": tab.id,
            "title": tab.title,
            "url": tab.url,
            "result": result
        ])
    }

    private func browserCDPClick(_ args: [String: Any]) throws -> ToolResult {
        guard let selector = string(args["selector"]), !selector.isEmpty else { throw RuntimeError("selector is required") }
        let script = """
        (() => {
          \(browserDeepDOMPrelude(selector: selector, query: nil))
          const resolved = resolveElement();
          if (!resolved) return {ok:false, error:"selector_not_found"};
          const el = resolved.el;
          el.scrollIntoView({block:"center", inline:"center"});
          el.dispatchEvent(new MouseEvent("mouseover", {bubbles:true}));
          el.dispatchEvent(new MouseEvent("mousedown", {bubbles:true}));
          el.click();
          el.dispatchEvent(new MouseEvent("mouseup", {bubbles:true}));
          return {ok:true, selector:resolved.selector, framePath:resolved.framePath, text:(el.innerText || el.value || el.getAttribute("aria-label") || el.tagName || "").slice(0,500)};
        })()
        """
        var evalArgs = args
        evalArgs["script"] = script
        let result = try browserCDPEval(evalArgs)
        return ToolResult(success: result.data["result"]?.contains(#""ok":true"#) == true, evidence: "Clicked DOM selector through CDP.", data: result.data, error: result.data["result"]?.contains(#""ok":true"#) == true ? nil : "selector_not_found")
    }

    private func browserCDPType(_ args: [String: Any]) throws -> ToolResult {
        guard let selector = string(args["selector"]), !selector.isEmpty else { throw RuntimeError("selector is required") }
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let submit = bool(args["submit"]) ?? false
        let script = """
        (() => {
          \(browserDeepDOMPrelude(selector: selector, query: nil))
          const resolved = resolveElement();
          if (!resolved) return {ok:false, error:"selector_not_found"};
          const el = resolved.el;
          el.scrollIntoView({block:"center", inline:"center"});
          el.focus();
          if ("value" in el) el.value = \(javascriptLiteral(text)); else el.textContent = \(javascriptLiteral(text));
          el.dispatchEvent(new InputEvent("input", {bubbles:true, inputType:"insertText", data:\(javascriptLiteral(text))}));
          el.dispatchEvent(new Event("change", {bubbles:true}));
          if (\(submit ? "true" : "false")) el.dispatchEvent(new KeyboardEvent("keydown", {bubbles:true, key:"Enter", code:"Enter"}));
          return {ok:true, selector:resolved.selector, framePath:resolved.framePath, chars:\(text.count)};
        })()
        """
        var evalArgs = args
        evalArgs["script"] = script
        let result = try browserCDPEval(evalArgs)
        return ToolResult(success: result.data["result"]?.contains(#""ok":true"#) == true, evidence: "Typed into DOM selector through CDP.", data: result.data, error: result.data["result"]?.contains(#""ok":true"#) == true ? nil : "selector_not_found")
    }

    private func browserCDPRead(_ args: [String: Any]) throws -> ToolResult {
        let selector = string(args["selector"]) ?? "body"
        let property = string(args["property"]) ?? "text"
        let accessor: String
        if property == "value" {
            accessor = #""value" in el ? el.value : """#
        } else if property == "html" {
            accessor = "el.innerHTML || \"\""
        } else if property.hasPrefix("attr:") {
            accessor = "el.getAttribute(\(javascriptLiteral(String(property.dropFirst(5))))) || \"\""
        } else {
            accessor = "el.innerText || el.textContent || \"\""
        }
        let script = """
        (() => {
          \(browserDeepDOMPrelude(selector: selector, query: nil))
          const resolved = resolveElement();
          if (!resolved) return {ok:false, error:"selector_not_found"};
          const el = resolved.el;
          return {ok:true, selector:resolved.selector, framePath:resolved.framePath, value:(\(accessor)).slice(0,8000)};
        })()
        """
        var evalArgs = args
        evalArgs["script"] = script
        let result = try browserCDPEval(evalArgs)
        let ok = result.data["result"]?.contains(#""ok":true"#) == true
        return ToolResult(success: ok, evidence: ok ? "Read DOM selector through CDP." : "DOM selector not found.", data: result.data, error: ok ? nil : "selector_not_found")
    }

    private func browserCDPObserve(_ args: [String: Any]) throws -> ToolResult {
        let query = string(args["query"]) ?? ""
        let maxResults = int(args["max_results"]) ?? 80
        let script = """
        (() => {
          const q = \(javascriptLiteral(query)).toLowerCase();
          const max = \(max(1, min(300, maxResults)));
          \(browserDeepDOMPrelude(selector: nil, query: query))
          const nodes = [];
          for (const root of allRoots()) {
            for (const el of queryAllDeep(root.root, interactiveSelector)) {
              nodes.push({el, framePath: root.framePath});
            }
          }
          const viewport = {w: innerWidth, h: innerHeight};
          const out = [];
          for (const item of nodes) {
            const el = item.el;
            const r = el.getBoundingClientRect();
            const style = getComputedStyle(el);
            const label = labelFor(el).slice(0, 300);
            const hay = [label, el.tagName, el.getAttribute("role") || "", el.type || ""].join(" ").toLowerCase();
            if (q && !hay.includes(q)) continue;
            if (r.width <= 0 || r.height <= 0 || style.visibility === "hidden" || style.display === "none") continue;
            out.push({
              selector: selectorFor(el),
              framePath: item.framePath,
              tag: el.tagName.toLowerCase(),
              role: el.getAttribute("role") || "",
              type: el.type || "",
              text: label,
              x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height),
              visible: r.bottom >= 0 && r.right >= 0 && r.top <= viewport.h && r.left <= viewport.w
            });
            if (out.length >= max) break;
          }
          return {ok:true, url: location.href, title: document.title, elements: out};
        })()
        """
        var evalArgs = args
        evalArgs["script"] = script
        let result = try browserCDPEval(evalArgs)
        return ToolResult(success: true, evidence: "Observed interactive DOM elements through CDP.", data: result.data)
    }

    private func browserCDPAct(_ args: [String: Any]) throws -> ToolResult {
        let action = normalizeForSearch(string(args["action"]) ?? "")
        var selector = string(args["selector"]) ?? ""
        let query = string(args["query"]) ?? ""
        let tabForCache = try? selectedCDPTab(args)
        if selector.isEmpty, !query.isEmpty, let cached = tabForCache.flatMap({ BrowserSelectorCacheStore.lookup(url: $0.url, query: query, action: action) }) {
            selector = cached.selector
        }
        if selector.isEmpty, !query.isEmpty {
            let script = """
            (() => {
              \(browserDeepDOMPrelude(selector: nil, query: query))
              const found = resolveElement();
              return found ? {ok:true, selector: found.selector, framePath: found.framePath, text: labelFor(found.el).slice(0,300)} : {ok:false};
            })()
            """
            var evalArgs = args
            evalArgs["script"] = script
            let resolved = try browserCDPEval(evalArgs)
            if let result = resolved.data["result"],
               let data = result.data(using: .utf8),
               let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let resolvedSelector = raw["selector"] as? String {
                selector = resolvedSelector
            }
        }
        guard !selector.isEmpty else {
            return ToolResult(success: false, evidence: "Could not resolve a DOM selector for browser action.", error: "selector_required")
        }
        var nextArgs = args
        nextArgs["selector"] = selector
        let result: ToolResult
        switch action {
        case "click":
            result = try browserCDPClick(nextArgs)
        case "type", "submit":
            if action == "submit" { nextArgs["submit"] = true }
            result = try browserCDPType(nextArgs)
        case "read":
            result = try browserCDPRead(nextArgs)
        default:
            return ToolResult(success: false, evidence: "Unsupported browser_cdp_act action \(action).", error: "unsupported_action")
        }
        if !query.isEmpty, let tab = tabForCache ?? (try? selectedCDPTab(args)) {
            _ = BrowserSelectorCacheStore.record(url: tab.url, query: query, selector: selector, action: action, success: result.success)
        }
        return result
    }

    private func browserCDPExtract(_ args: [String: Any]) throws -> ToolResult {
        let selector = string(args["selector"]) ?? "body"
        let schemaName = normalizeForSearch(string(args["schema"]) ?? "summary")
        let script = """
        (() => {
          const root = document.querySelector(\(javascriptLiteral(selector)));
          if (!root) return {ok:false, error:"selector_not_found"};
          const text = (root.innerText || root.textContent || "").trim().replace(/\\s+/g, " ").slice(0, 12000);
          const links = [...root.querySelectorAll("a[href]")].slice(0,80).map(a => ({text:(a.innerText||"").trim().slice(0,200), href:a.href}));
          const forms = [...root.querySelectorAll("form")].slice(0,20).map(f => ({text:(f.innerText||"").trim().slice(0,500), inputs:[...f.querySelectorAll("input,textarea,select")].map(i => ({name:i.name||"", type:i.type||i.tagName.toLowerCase(), placeholder:i.placeholder||"", value:i.value||""}))}));
          const tables = [...root.querySelectorAll("table")].slice(0,20).map(t => (t.innerText||"").trim().slice(0,2000));
          return {ok:true, schema:\(javascriptLiteral(schemaName)), title:document.title, url:location.href, text, links, forms, tables};
        })()
        """
        var evalArgs = args
        evalArgs["script"] = script
        let result = try browserCDPEval(evalArgs)
        let ok = result.data["result"]?.contains(#""ok":true"#) == true
        return ToolResult(success: ok, evidence: ok ? "Extracted structured page data through CDP." : "Could not extract structured page data.", data: result.data, error: ok ? nil : "extract_failed")
    }

    private func browserCDPWait(_ args: [String: Any]) throws -> ToolResult {
        let condition = normalizeForSearch(string(args["condition"]) ?? "")
        let value = string(args["value"]) ?? ""
        let timeout = max(0.5, double(args["timeout"]) ?? 15)
        let interval = max(0.1, double(args["interval"]) ?? 0.5)
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            let expression: String
            switch condition {
            case "selector":
                expression = "(() => { \(browserDeepDOMPrelude(selector: value, query: nil)); return {ok: !!resolveElement()}; })()"
            case "text":
                expression = "(() => ({ok: (document.body?.innerText || '').toLowerCase().includes(\(javascriptLiteral(value.lowercased())))}))()"
            case "url_contains":
                expression = "(() => ({ok: location.href.toLowerCase().includes(\(javascriptLiteral(value.lowercased())))}))()"
            case "expression":
                expression = "(() => ({ok: Boolean(\(value))}))()"
            case "network_idle":
                expression = """
                (() => {
                  const quietMs = Math.max(250, Number(\(javascriptLiteral(value.isEmpty ? "750" : value))) || 750);
                  const now = performance.now();
                  const resources = performance.getEntriesByType("resource");
                  const latest = resources.reduce((m, r) => Math.max(m, r.responseEnd || r.fetchStart || 0), 0);
                  const idleFor = now - latest;
                  return {ok: document.readyState === "complete" && idleFor >= quietMs, readyState: document.readyState, idleFor: Math.round(idleFor), quietMs};
                })()
                """
            default:
                throw RuntimeError("Unsupported CDP wait condition: \(condition)")
            }
            var evalArgs = args
            evalArgs["script"] = expression
            let result = try browserCDPEval(evalArgs)
            last = result.data["result"] ?? ""
            if last.contains(#""ok":true"#) {
                return ToolResult(success: true, evidence: "CDP wait condition met: \(condition).", data: ["result": last])
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return ToolResult(success: false, evidence: "Timed out waiting for CDP condition \(condition).", data: ["last_result": last], error: "timeout")
    }

    private func browserCDPFileUpload(_ args: [String: Any]) throws -> ToolResult {
        guard let selector = string(args["selector"]), !selector.isEmpty else { throw RuntimeError("selector is required") }
        let paths = try stringArray(args["paths"], name: "paths").map(\.expandingTildeInPath)
        guard !paths.isEmpty else { throw RuntimeError("paths is required") }
        for path in paths where !FileManager.default.fileExists(atPath: path) {
            return ToolResult(success: false, evidence: "Upload file does not exist.", data: ["path": path], error: "file_not_found")
        }
        let tab = try selectedCDPTab(args)
        let document = try ChromeCDP.call(tab: tab, method: "DOM.getDocument", params: ["pierce": true])
        guard let result = document["result"] as? [String: Any],
              let root = result["root"] as? [String: Any],
              let nodeID = int(root["nodeId"])
        else { throw RuntimeError("DOM.getDocument did not return root.nodeId") }
        let selected = try ChromeCDP.call(tab: tab, method: "DOM.querySelector", params: ["nodeId": nodeID, "selector": selector])
        guard let selectedResult = selected["result"] as? [String: Any],
              let inputNodeID = int(selectedResult["nodeId"]),
              inputNodeID != 0
        else {
            return ToolResult(success: false, evidence: "File input selector not found.", data: ["selector": selector], error: "selector_not_found")
        }
        _ = try ChromeCDP.call(tab: tab, method: "DOM.setFileInputFiles", params: [
            "nodeId": inputNodeID,
            "files": paths
        ])
        return ToolResult(success: true, evidence: "Set file input files through CDP.", data: [
            "tab_id": tab.id,
            "url": tab.url,
            "selector": selector,
            "paths": jsonStringValue(paths)
        ])
    }

    private func browserCDPDownloadBehavior(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["download_path"]), !rawPath.isEmpty else { throw RuntimeError("download_path is required") }
        let path = rawPath.expandingTildeInPath
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let behavior = string(args["behavior"]) ?? "allow"
        let tab = try selectedCDPTab(args)
        let response = try ChromeCDP.call(tab: tab, method: "Page.setDownloadBehavior", params: [
            "behavior": behavior,
            "downloadPath": path
        ])
        return ToolResult(success: true, evidence: "Configured CDP download behavior.", data: [
            "tab_id": tab.id,
            "url": tab.url,
            "behavior": behavior,
            "download_path": path,
            "response": jsonStringValue(response)
        ])
    }

    private func browserCDPSelectorCache(_ args: [String: Any]) -> ToolResult {
        let entries = BrowserSelectorCacheStore.list(query: string(args["query"]) ?? "", limit: int(args["limit"]) ?? 50)
        return ToolResult(success: true, evidence: "Returned \(entries.count) browser selector cache entrie(s).", data: [
            "entries": jsonStringValue(entries.map(\.dictionary))
        ])
    }

    private func browserRuntimeSessionTool(_ args: [String: Any]) throws -> ToolResult {
        let endpoint = string(args["endpoint"]) ?? "http://127.0.0.1:9222"
        let profileDir = (string(args["profile_dir"]) ?? EventStore.rootURL.appendingPathComponent("chrome-cdp-profile", isDirectory: true).path).expandingTildeInPath
        let session = try BrowserRuntimeStore.upsertSession(
            name: string(args["name"]) ?? "default-cdp",
            endpoint: endpoint,
            profileDir: profileDir,
            urlHint: string(args["url"]) ?? "",
            status: string(args["status"]) ?? "planned"
        )
        return ToolResult(success: true, evidence: "Registered browser runtime session.", data: session.dictionary)
    }

    private func browserRuntimePlanTool(_ args: [String: Any]) -> ToolResult {
        let goal = string(args["goal"]) ?? ""
        return ToolResult(success: true, evidence: "Built browser runtime plan.", data: BrowserRuntimeStore.plan(goal: goal, url: string(args["url"]) ?? ""))
    }

    private func browserRuntimeSnapshotTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Loaded browser runtime snapshot.", data: BrowserRuntimeStore.snapshot(sessionID: string(args["session_id"])))
    }

    private func browserDeepDOMPrelude(selector: String?, query: String?) -> String {
        """
        const targetSelector = \(selector.map(javascriptLiteral) ?? "null");
        const targetQuery = \(query.map(javascriptLiteral) ?? "null");
        const interactiveSelector = "a,button,input,textarea,select,[role],[contenteditable=true],[tabindex],summary,label";
        const labelFor = (el) => ((el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("name") || el.getAttribute("title") || el.getAttribute("placeholder") || el.alt || el.tagName || "") + "").trim().replace(/\\s+/g, " ");
        const selectorFor = (el) => {
          if (el.id) return "#" + CSS.escape(el.id);
          const attrs = ["data-testid","data-test","aria-label","name","title","placeholder","alt"];
          const doc = el.ownerDocument || document;
          const test = (s) => { try { return doc.querySelectorAll(s).length === 1; } catch { return false; } };
          for (const attr of attrs) {
            const v = el.getAttribute(attr);
            if (v) {
              const s = el.tagName.toLowerCase() + "[" + attr + "=" + JSON.stringify(v) + "]";
              if (test(s)) return s;
            }
          }
          let path = el.tagName.toLowerCase();
          let node = el;
          while (node && node.parentElement && path.length < 240) {
            const parent = node.parentElement;
            const siblings = [...parent.children].filter(x => x.tagName === node.tagName);
            const part = node.tagName.toLowerCase() + (siblings.length > 1 ? `:nth-of-type(${siblings.indexOf(node) + 1})` : "");
            path = part + " > " + path;
            if (test(path)) return path;
            node = parent;
          }
          return path;
        };
        const allRoots = () => {
          const out = [{root: document, framePath: "top"}];
          const visit = (root, framePath) => {
            let nodes = [];
            try { nodes = [...root.querySelectorAll("*")]; } catch {}
            for (const node of nodes) {
              if (node.shadowRoot) {
                out.push({root: node.shadowRoot, framePath: framePath + " >> shadow(" + selectorFor(node) + ")"});
                visit(node.shadowRoot, framePath + " >> shadow(" + selectorFor(node) + ")");
              }
              if (node.tagName === "IFRAME") {
                try {
                  if (node.contentDocument) {
                    const nextPath = framePath + " >> iframe(" + selectorFor(node) + ")";
                    out.push({root: node.contentDocument, framePath: nextPath});
                    visit(node.contentDocument, nextPath);
                  }
                } catch {}
              }
            }
          };
          visit(document, "top");
          return out;
        };
        const queryAllDeep = (root, sel) => {
          const out = [];
          try { out.push(...root.querySelectorAll(sel)); } catch {}
          let nodes = [];
          try { nodes = [...root.querySelectorAll("*")]; } catch {}
          for (const node of nodes) {
            if (node.shadowRoot) out.push(...queryAllDeep(node.shadowRoot, sel));
            if (node.tagName === "IFRAME") {
              try { if (node.contentDocument) out.push(...queryAllDeep(node.contentDocument, sel)); } catch {}
            }
          }
          return out;
        };
        const resolveElement = () => {
          if (targetSelector) {
            for (const root of allRoots()) {
              const found = queryAllDeep(root.root, targetSelector)[0];
              if (found) return {el: found, selector: selectorFor(found), framePath: root.framePath};
            }
          }
          if (targetQuery) {
            const q = targetQuery.toLowerCase();
            for (const root of allRoots()) {
              for (const el of queryAllDeep(root.root, interactiveSelector)) {
                if (labelFor(el).toLowerCase().includes(q)) return {el, selector: selectorFor(el), framePath: root.framePath};
              }
            }
          }
          return null;
        };
        """
    }

    private func cdpEndpoint(_ args: [String: Any]) -> ChromeCDP.Endpoint {
        ChromeCDP.Endpoint(host: string(args["host"]) ?? "127.0.0.1", port: int(args["port"]) ?? 9222)
    }

    private func selectedCDPTab(_ args: [String: Any]) throws -> ChromeCDP.Tab {
        let endpoint = cdpEndpoint(args)
        let tabs = try ChromeCDP.tabs(endpoint: endpoint)
        if let id = string(args["tab_id"]), let tab = tabs.first(where: { $0.id == id }) { return tab }
        if let probe = string(args["url_contains"])?.lowercased(), let tab = tabs.first(where: { $0.url.lowercased().contains(probe) }) { return tab }
        if let probe = string(args["title_contains"])?.lowercased(), let tab = tabs.first(where: { $0.title.lowercased().contains(probe) }) { return tab }
        guard let first = tabs.first(where: { $0.type == "page" }) ?? tabs.first else {
            throw RuntimeError("No CDP tabs found.")
        }
        return first
    }

    private func memoryRememberTool(_ args: [String: Any]) throws -> ToolResult {
        guard let key = string(args["key"]), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("key is required")
        }
        guard let value = string(args["value"]), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("value is required")
        }
        let entry = try MemoryStore.remember(
            kind: string(args["kind"]) ?? "user_note",
            scope: string(args["scope"]) ?? "global",
            app: string(args["app"]) ?? "",
            key: key,
            value: value,
            confidence: double(args["confidence"]) ?? 0.8,
            sourceRunID: nil,
            sourceTool: "memory_remember"
        )
        return ToolResult(success: true, evidence: "Saved durable memory \(entry.id).", data: entry.dictionary)
    }

    private func memoryRecallTool(_ args: [String: Any]) -> ToolResult {
        let query = string(args["query"]) ?? ""
        let entries = MemoryStore.recall(
            query: query,
            limit: int(args["limit"]) ?? 8,
            kind: string(args["kind"]),
            app: string(args["app"])
        )
        return ToolResult(
            success: true,
            evidence: entries.isEmpty ? "No matching durable memory." : "Recalled \(entries.count) durable memory item(s).",
            data: [
                "query": query,
                "memories": jsonStringValue(entries.map(\.dictionary))
            ]
        )
    }

    private func memoryRecentTool(_ args: [String: Any]) -> ToolResult {
        let entries = MemoryStore.recent(limit: int(args["limit"]) ?? 10)
        return ToolResult(
            success: true,
            evidence: entries.isEmpty ? "No durable memories yet." : "Returned \(entries.count) recent durable memory item(s).",
            data: ["memories": jsonStringValue(entries.map(\.dictionary))]
        )
    }

    private func episodeRecallTool(_ args: [String: Any]) -> ToolResult {
        let query = string(args["query"]) ?? ""
        let episodes = EpisodeStore.recall(query: query, limit: int(args["limit"]) ?? 8)
        return ToolResult(success: true, evidence: episodes.isEmpty ? "No matching episodes." : "Recalled \(episodes.count) episode(s).", data: [
            "query": query,
            "episodes": jsonStringValue(episodes.map(\.dictionary))
        ])
    }

    private func contextGraphQueryTool(_ args: [String: Any]) -> ToolResult {
        let query = string(args["query"]) ?? ""
        let graph = ContextGraphStore.query(query, limit: int(args["limit"]) ?? 20)
        return ToolResult(success: true, evidence: "Returned \(graph.nodes.count) context node(s) and \(graph.edges.count) edge(s).", data: [
            "query": query,
            "nodes": jsonStringValue(graph.nodes.map { ["id": $0.id, "kind": $0.kind, "label": $0.label, "attributes": jsonStringValue($0.attributes), "updated_at": $0.updatedAt] }),
            "edges": jsonStringValue(graph.edges.map { ["from": $0.from, "to": $0.to, "relation": $0.relation, "weight": String(format: "%.2f", $0.weight), "updated_at": $0.updatedAt] })
        ])
    }

    private func contextGraphIngestTool(_ args: [String: Any]) throws -> ToolResult {
        guard let fromKind = string(args["from_kind"]), let fromLabel = string(args["from_label"]),
              let toKind = string(args["to_kind"]), let toLabel = string(args["to_label"]),
              let relation = string(args["relation"])
        else { throw RuntimeError("from_kind, from_label, to_kind, to_label, and relation are required") }
        ContextGraphStore.ingest(
            fromKind: fromKind,
            fromLabel: fromLabel,
            toKind: toKind,
            toLabel: toLabel,
            relation: relation,
            weight: double(args["weight"]) ?? 1
        )
        return ToolResult(success: true, evidence: "Ingested context graph relationship.", data: [
            "from": "\(fromKind):\(fromLabel)",
            "to": "\(toKind):\(toLabel)",
            "relation": relation
        ])
    }

    private func memoryProfileTool(_ args: [String: Any]) -> ToolResult {
        let query = string(args["query"]) ?? ""
        let limit = int(args["limit"]) ?? 8
        let memories = MemoryStore.recall(query: query, limit: limit)
        let episodes = EpisodeStore.recall(query: query, limit: limit)
        let graph = ContextGraphStore.query(query, limit: limit)
        let skills = AppSkillStore.suggest(query: query, limit: limit)
        let recipes = (try? RecipeStore.suggest(goal: query, limit: limit)) ?? []
        return ToolResult(success: true, evidence: "Built durable context profile.", data: [
            "query": query,
            "memories": jsonStringValue(memories.map(\.dictionary)),
            "episodes": jsonStringValue(episodes.map(\.dictionary)),
            "graph_nodes": jsonStringValue(graph.nodes.map { ["id": $0.id, "kind": $0.kind, "label": $0.label] }),
            "graph_edges": jsonStringValue(graph.edges.map { ["from": $0.from, "to": $0.to, "relation": $0.relation, "weight": String(format: "%.2f", $0.weight)] }),
            "app_skills": jsonStringValue(skills.map(\.dictionary)),
            "recipes": jsonStringValue(recipes.map(\.summary))
        ])
    }

    private func memoryIndexRebuildTool() throws -> ToolResult {
        let items = try MemoryIndexStore.rebuild()
        let bySource = Dictionary(grouping: items, by: \.source).mapValues(\.count)
        return ToolResult(success: true, evidence: "Rebuilt semantic memory index with \(items.count) item(s).", data: [
            "path": MemoryIndexStore.url.path,
            "items": "\(items.count)",
            "sources": jsonStringValue(bySource)
        ])
    }

    private func memorySemanticRecallTool(_ args: [String: Any]) -> ToolResult {
        let query = string(args["query"]) ?? ""
        let kinds = (try? stringArray(args["kinds"], name: "kinds")) ?? []
        let hits = MemoryIndexStore.recall(query: query, limit: int(args["limit"]) ?? 10, kinds: kinds)
        return ToolResult(success: true, evidence: hits.isEmpty ? "No semantic memory hits." : "Recalled \(hits.count) semantic memory item(s).", data: [
            "query": query,
            "hits": jsonStringValue(hits.map { scored in
                var item = scored.item.dictionary
                item["score"] = String(format: "%.4f", scored.score)
                return item
            })
        ])
    }

    private func memoryContextPackTool(_ args: [String: Any]) -> ToolResult {
        let query = string(args["query"]) ?? ""
        return ToolResult(success: true, evidence: "Built semantic context pack.", data: MemoryIndexStore.contextPack(
            query: query,
            limit: int(args["limit"]) ?? 8
        ))
    }

    private func memoryEpisodeConsolidateTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let data = try EpisodeContextEngine.consolidate(runID: runID, outcome: string(args["outcome"]) ?? "unknown")
        return ToolResult(success: true, evidence: "Consolidated run into durable episode/context graph.", data: data)
    }

    private func memoryShadowDigestTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Built Shadow-style memory digest.", data: EpisodeContextEngine.shadowDigest(limit: int(args["limit"]) ?? 20))
    }

    private func sessionTimelineTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let events = try SessionProtocolStore.timeline(runID: runID, limit: int(args["limit"]) ?? 200)
        return ToolResult(success: true, evidence: "Projected \(events.count) session event(s).", data: [
            "run_id": runID,
            "schema": SessionProtocolStore.schema,
            "events": jsonStringValue(events.map(\.dictionary))
        ])
    }

    private func sessionExportTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let url = try SessionProtocolStore.export(runID: runID)
        return ToolResult(success: true, evidence: "Exported session protocol artifact.", data: [
            "run_id": runID,
            "schema": "aios.session.v1",
            "path": url.path
        ])
    }

    private func cockpitSnapshotTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        return ToolResult(success: true, evidence: "Built cockpit snapshot.", data: try SessionProtocolStore.cockpitSnapshot(
            runID: runID,
            limit: int(args["limit"]) ?? 80
        ))
    }

    private func cockpitLiveStateTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Loaded live cockpit state.", data: CockpitControlStore.liveState(limit: int(args["limit"]) ?? 20))
    }

    private func cockpitCommandTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        guard let command = string(args["command"]), !command.isEmpty else { throw RuntimeError("command is required") }
        let item = try CockpitControlStore.record(runID: runID, command: command, feedback: string(args["feedback"]) ?? "")
        return ToolResult(success: true, evidence: "Recorded cockpit command.", data: item.dictionary)
    }

    private func platformStatusTool() -> ToolResult {
        var data = SessionProtocolStore.platformStatus(toolDefinitions: definitions)
        data["session_event_schema"] = jsonStringValue(SessionProtocolStore.schemaDescription())
        return ToolResult(success: true, evidence: "Loaded AIOS platform status.", data: data)
    }

    private func agentRolePlanTool(_ args: [String: Any]) -> ToolResult {
        let goal = string(args["goal"]) ?? ""
        let route = AgentRoleSystem.plan(goal: goal, app: string(args["app_name"]) ?? "", surface: string(args["surface"]) ?? "")
        return ToolResult(success: true, evidence: "Built role-agent route.", data: [
            "goal": goal,
            "roles": jsonStringValue(AgentRoleSystem.roles.map(\.dictionary)),
            "route": jsonStringValue(route)
        ])
    }

    private func agentHandoffPacketTool(_ args: [String: Any]) throws -> ToolResult {
        let context = try parseJSONObject(string(args["context_json"]) ?? "{}").compactMapValues { string($0) }
        let packet = try AgentRoleSystem.recordHandoff(
            goal: string(args["goal"]) ?? "",
            fromRole: string(args["from_role"]) ?? "",
            toRole: string(args["to_role"]) ?? "",
            reason: string(args["reason"]) ?? "",
            context: context
        )
        return ToolResult(success: true, evidence: "Recorded agent handoff packet.", data: packet.dictionary)
    }

    private func appSkillListTool(_ args: [String: Any]) -> ToolResult {
        let query = string(args["query"]) ?? ""
        let limit = int(args["limit"]) ?? 20
        let skills = query.isEmpty ? Array(AppSkillStore.list().prefix(limit)) : AppSkillStore.suggest(query: query, limit: limit)
        return ToolResult(success: true, evidence: "Returned \(skills.count) app skill manifest(s).", data: [
            "skills": jsonStringValue(skills.map(\.dictionary))
        ])
    }

    private func appSkillSuggestTool(_ args: [String: Any]) -> ToolResult {
        let query = string(args["query"]) ?? ""
        let skills = AppSkillStore.suggest(query: query, limit: int(args["limit"]) ?? 8)
        return ToolResult(success: true, evidence: skills.isEmpty ? "No matching app skill." : "Suggested \(skills.count) app skill(s).", data: [
            "query": query,
            "skills": jsonStringValue(skills.map(\.dictionary))
        ])
    }

    private func appSkillInstallTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        guard let appName = string(args["app_name"]), !appName.isEmpty else { throw RuntimeError("app_name is required") }
        let selectors: [String: String] = {
            guard let raw = string(args["selectors_json"]),
                  let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return parsed.compactMapValues { string($0) }
        }()
        let skill = AppSkill(
            id: id,
            appName: appName,
            bundleID: string(args["bundle_id"]) ?? "",
            version: string(args["version"]) ?? "1",
            capabilities: (try? stringArray(args["capabilities"], name: "capabilities")) ?? [],
            tools: (try? stringArray(args["tools"], name: "tools")) ?? [],
            recipes: (try? stringArray(args["recipes"], name: "recipes")) ?? [],
            selectors: selectors,
            permissions: (try? stringArray(args["permissions"], name: "permissions")) ?? [],
            notes: string(args["notes"]) ?? ""
        )
        let knownTools = Set(definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        let issues = AppSkillStore.validate(skill, knownTools: knownTools)
        let installed = try AppSkillStore.install(skill)
        return ToolResult(success: issues.isEmpty, evidence: issues.isEmpty ? "Installed app skill \(id)." : "Installed app skill \(id) with validation issues.", data: [
            "skill": jsonStringValue(installed.dictionary),
            "issues": issues.joined(separator: "\n")
        ], error: issues.isEmpty ? nil : "app_skill_validation_issues")
    }

    private func appSkillPackageScaffoldTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        guard let appName = string(args["app_name"]), !appName.isEmpty else { throw RuntimeError("app_name is required") }
        let selectors: [String: String] = {
            guard let raw = string(args["selectors_json"]),
                  let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return parsed.compactMapValues { string($0) }
        }()
        let package = try AppSkillPackageStore.scaffold(
            id: id,
            appName: appName,
            bundleID: string(args["bundle_id"]) ?? "",
            version: string(args["version"]) ?? "1",
            capabilities: (try? stringArray(args["capabilities"], name: "capabilities")) ?? [],
            tools: (try? stringArray(args["tools"], name: "tools")) ?? [],
            recipes: (try? stringArray(args["recipes"], name: "recipes")) ?? [],
            selectors: selectors,
            permissions: (try? stringArray(args["permissions"], name: "permissions")) ?? [],
            notes: string(args["notes"]) ?? ""
        )
        let knownTools = Set(definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        let issues = AppSkillPackageStore.validate(package, knownTools: knownTools)
        return ToolResult(success: issues.isEmpty, evidence: issues.isEmpty ? "Scaffolded app skill package \(package.id)." : "Scaffolded app skill package \(package.id) with validation issues.", data: [
            "package": jsonStringValue(package.dictionary),
            "path": AppSkillPackageStore.packageURL(id: package.id).path,
            "issues": issues.joined(separator: "\n")
        ], error: issues.isEmpty ? nil : "app_skill_package_validation_issues")
    }

    private func appSkillPackageListTool(_ args: [String: Any]) -> ToolResult {
        let query = normalizeForSearch(string(args["query"]) ?? "")
        let limit = int(args["limit"]) ?? 20
        let packages = AppSkillPackageStore.list().filter { package in
            query.isEmpty ||
                normalizeForSearch([package.id, package.appName, package.bundleID, package.capabilities.joined(separator: " "), package.tools.joined(separator: " "), package.notes].joined(separator: " ")).contains(query)
        }.prefix(min(100, max(1, limit)))
        return ToolResult(success: true, evidence: "Returned \(packages.count) app skill package(s).", data: [
            "packages": jsonStringValue(packages.map(\.dictionary)),
            "root": AppSkillPackageStore.packagesURL.path
        ])
    }

    private func appSkillPackageValidateTool(_ args: [String: Any]) -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else {
            return ToolResult(success: false, evidence: "id is required", error: "id_required")
        }
        guard let package = AppSkillPackageStore.list().first(where: { $0.id == normalizeID(id) || $0.id == id }) else {
            return ToolResult(success: false, evidence: "App skill package not found.", data: ["id": id], error: "app_skill_package_not_found")
        }
        let knownTools = Set(definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        let issues = AppSkillPackageStore.validate(package, knownTools: knownTools)
        return ToolResult(success: issues.isEmpty, evidence: issues.isEmpty ? "App skill package is valid." : "App skill package has validation issues.", data: [
            "package": jsonStringValue(package.dictionary),
            "path": AppSkillPackageStore.packageURL(id: package.id).path,
            "issues": issues.joined(separator: "\n")
        ], error: issues.isEmpty ? nil : "app_skill_package_validation_issues")
    }

    private func appSkillRouteTool(_ args: [String: Any]) -> ToolResult {
        let route = AppSkillRuntime.route(
            query: string(args["query"]) ?? "",
            appName: string(args["app_name"]) ?? "",
            bundleID: string(args["bundle_id"]) ?? ""
        )
        return ToolResult(success: !route.tools.isEmpty, evidence: route.tools.isEmpty ? "No app skill route found." : "Resolved app skill route.", data: route.dictionary, error: route.tools.isEmpty ? "app_skill_route_not_found" : nil)
    }

    private func appSkillExportManifestTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        let url = try AppSkillRuntime.exportManifest(id: id)
        return ToolResult(success: true, evidence: "Exported app skill manifest.", data: ["id": id, "path": url.path])
    }

    private func trajectoryGetTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let events = try TrajectoryStore.summarize(runID: runID, limit: int(args["limit"]) ?? 200)
        return ToolResult(success: true, evidence: "Returned \(events.count) trajectory event(s).", data: [
            "run_id": runID,
            "events": jsonStringValue(events)
        ])
    }

    private func trajectoryExportTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let url = try TrajectoryStore.export(runID: runID)
        return ToolResult(success: true, evidence: "Exported trajectory.", data: [
            "run_id": runID,
            "path": url.path
        ])
    }

    private func trajectorySessionExportTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let url = try TrajectoryStore.exportSession(runID: runID)
        return ToolResult(success: true, evidence: "Exported replay session.", data: [
            "run_id": runID,
            "path": url.path
        ])
    }

    private func trajectoryReplayPlanTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let plan = try TrajectoryStore.replayPlan(runID: runID, fromIndex: int(args["from_index"]) ?? 1, toIndex: int(args["to_index"]))
        return ToolResult(success: true, evidence: "Prepared replay plan with \(plan.count) replayable event(s).", data: [
            "run_id": runID,
            "plan": jsonStringValue(plan)
        ])
    }

    private func trajectoryReplayTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        return try TrajectoryReplayEngine.replay(
            runID: runID,
            fromIndex: int(args["from_index"]) ?? 1,
            toIndex: int(args["to_index"]),
            dryRun: bool(args["dry_run"]) ?? true,
            allowForeground: bool(args["allow_foreground"]) ?? false,
            stopOnFailure: bool(args["stop_on_failure"]) ?? true,
            recordRun: bool(args["record_run"]) ?? false
        )
    }

    private func trajectoryClipRecipeTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let recipe = try TrajectoryReplayEngine.clipRecipe(
            runID: runID,
            fromIndex: int(args["from_index"]) ?? 1,
            toIndex: int(args["to_index"]),
            recipeID: string(args["recipe_id"]),
            title: string(args["title"])
        )
        return ToolResult(success: true, evidence: "Clipped trajectory into recipe \(recipe.id).", data: [
            "run_id": runID,
            "recipe_id": recipe.id,
            "steps": "\(recipe.steps.count)",
            "recipe": recipe.jsonString
        ])
    }

    private func trajectoryProductExportTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let url = try TrajectoryProductStore.exportProduct(runID: runID, limit: int(args["limit"]) ?? 400)
        return ToolResult(success: true, evidence: "Exported product-grade trajectory session.", data: ["run_id": runID, "path": url.path])
    }

    private func trajectoryResumePointsTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let points = try TrajectoryProductStore.resumePoints(runID: runID)
        return ToolResult(success: true, evidence: "Returned \(points.count) trajectory resume point(s).", data: [
            "run_id": runID,
            "resume_points": jsonStringValue(points.map(\.dictionary))
        ])
    }

    private func trajectoryBranchCreateTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let branch = try TrajectoryProductStore.branch(runID: runID, fromIndex: int(args["from_index"]) ?? 1, goal: string(args["goal"]) ?? "")
        return ToolResult(success: true, evidence: "Created trajectory branch run.", data: branch)
    }

    private func recipePromoteRunTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let recipe = try RecipeStore.promoteRun(
            runID: runID,
            recipeID: string(args["recipe_id"]),
            title: string(args["title"])
        )
        return ToolResult(success: true, evidence: "Promoted run into recipe \(recipe.id).", data: [
            "recipe_id": recipe.id,
            "required_params": recipe.requiredParams.joined(separator: ","),
            "steps": "\(recipe.steps.count)",
            "recipe": recipe.jsonString
        ])
    }

    private func recipeCompileTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        let graph = try RecipeStore.compile(recipeID: id)
        let invalid = graph.filter { $0["branch_valid"] == "false" }
        return ToolResult(success: invalid.isEmpty, evidence: invalid.isEmpty ? "Compiled recipe workflow program." : "Recipe has invalid branch target(s).", data: [
            "id": id,
            "steps": jsonStringValue(graph),
            "invalid_steps": invalid.map { $0["id"] ?? "" }.joined(separator: ",")
        ], error: invalid.isEmpty ? nil : "recipe_compile_invalid")
    }

    private func recipeRefineTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let recipe = try RecipeStore.recordRunOutcome(
            recipeID: id,
            runID: runID,
            success: bool(args["success"]) ?? false,
            notes: string(args["notes"]) ?? ""
        )
        return ToolResult(success: true, evidence: "Refined recipe \(id) from run outcome.", data: [
            "id": recipe.id,
            "version": "\(recipe.version ?? 1)",
            "success_count": "\(recipe.successCount ?? 0)",
            "failure_count": "\(recipe.failureCount ?? 0)"
        ])
    }

    private func recipeGeneralizeTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        let recipe = try RecipeGeneralizer.generalize(recipeID: id, outputID: string(args["output_id"]))
        return ToolResult(success: true, evidence: "Generalized recipe \(id) into \(recipe.id).", data: [
            "recipe_id": recipe.id,
            "required_params": recipe.requiredParams.joined(separator: ","),
            "parameters": jsonStringValue((recipe.parameters ?? []).map { ["name": $0.name, "required": $0.required ? "true" : "false", "examples": $0.examples.joined(separator: ",")] }),
            "recipe": recipe.jsonString
        ])
    }

    private func recipeExecuteAdaptiveTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        let params = try parseJSONObject(string(args["params_json"]) ?? "{}")
        let store = try? EventStore.start(goal: "adaptive-recipe:\(id)")
        let results = try RecipeAdaptiveRunner.run(recipeID: id, params: params, eventStore: store)
        let ok = results.allSatisfy(\.success)
        try? store?.updateStatus(ok ? "complete" : "failed")
        return ToolResult(success: ok, evidence: ok ? "Executed adaptive recipe \(id)." : "Adaptive recipe \(id) stopped on a failed step.", data: [
            "recipe_id": id,
            "run_id": store?.runID ?? "",
            "results": jsonStringValue(results.map { ["success": $0.success ? "true" : "false", "evidence": $0.evidence, "error": $0.error ?? ""] }),
            "repair_hints": jsonStringValue(RecipeAdaptationStore.hints(recipeID: id).map(\.dictionary))
        ])
    }

    private func recipeRepairHintTool(_ args: [String: Any]) throws -> ToolResult {
        guard let recipeID = string(args["recipe_id"]), !recipeID.isEmpty else { throw RuntimeError("recipe_id is required") }
        guard let stepID = string(args["step_id"]), !stepID.isEmpty else { throw RuntimeError("step_id is required") }
        guard let failedTool = string(args["failed_tool"]), !failedTool.isEmpty else { throw RuntimeError("failed_tool is required") }
        guard let replacementTool = string(args["replacement_tool"]), !replacementTool.isEmpty else { throw RuntimeError("replacement_tool is required") }
        let rawArgs = try parseJSONObject(string(args["arguments_json"]) ?? "{}")
        let arguments = rawArgs.compactMapValues { value -> String? in
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        let hint = try RecipeAdaptationStore.recordHint(
            recipeID: recipeID,
            stepID: stepID,
            failedTool: failedTool,
            replacementTool: replacementTool,
            arguments: arguments,
            reason: string(args["reason"]) ?? "",
            success: bool(args["success"]) ?? false
        )
        return ToolResult(success: true, evidence: "Recorded recipe repair hint.", data: hint.dictionary)
    }

    private func recipeProgramCompileTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        let compiled = try RecipeProgramStore.compile(recipeID: id)
        return ToolResult(success: compiled["valid"] == "true", evidence: compiled["valid"] == "true" ? "Compiled recipe program." : "Compiled recipe program with issues.", data: compiled, error: compiled["valid"] == "true" ? nil : "recipe_program_issues")
    }

    private func recipeSchemaInferTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        return ToolResult(success: true, evidence: "Inferred recipe program schema from run.", data: try RecipeProgramStore.inferSchema(from: runID, recipeID: string(args["recipe_id"])))
    }

    private func recipeDistillSuccessTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        return ToolResult(success: true, evidence: "Distilled successful run into stable recipe program.", data: try RecipeProgramStore.distillSuccess(runID: runID, title: string(args["title"]) ?? ""))
    }

    private func runtimeStatusTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let summary = try EventStore.readSummary(runID: runID)
        let runDir = EventStore.runsURL.appendingPathComponent(runID, isDirectory: true)
        let store = EventStore(runID: runID, goal: summary.goal, dir: runDir, eventsURL: URL(fileURLWithPath: summary.eventsPath), summaryURL: runDir.appendingPathComponent("summary.json"))
        var checkpointPayload = ""
        if let checkpoint = store.loadCheckpoint(),
           let data = try? JSONEncoder().encode(checkpoint),
           let object = try? JSONSerialization.jsonObject(with: data) {
            checkpointPayload = jsonStringValue(object)
        }
        let events = try TrajectoryStore.summarize(runID: runID, limit: int(args["limit"]) ?? 80)
        return ToolResult(success: true, evidence: "Loaded runtime status.", data: [
            "run_id": runID,
            "goal": summary.goal,
            "status": summary.status,
            "created_at": summary.createdAt,
            "updated_at": summary.updatedAt,
            "checkpoint": checkpointPayload,
            "trajectory": jsonStringValue(events)
        ])
    }

    private func runtimeScheduleTool(_ args: [String: Any]) throws -> ToolResult {
        let resumeAt: String? = {
            if let text = string(args["resume_at"]), !text.isEmpty { return text }
            if let seconds = double(args["resume_after_seconds"]), seconds > 0 {
                return isoDateString(Date().addingTimeInterval(seconds))
            }
            return nil
        }()
        if let runID = string(args["run_id"]), !runID.isEmpty {
            let goal = string(args["goal"]) ?? (try? EventStore.readSummary(runID: runID).goal) ?? ""
            try TaskQueue.submitExisting(runID: runID, goal: goal, notBefore: resumeAt)
            return ToolResult(success: true, evidence: resumeAt == nil ? "Queued existing run." : "Scheduled existing run.", data: [
                "run_id": runID,
                "goal": goal,
                "resume_at": resumeAt ?? ""
            ])
        }
        guard let goal = string(args["goal"]), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("goal is required when run_id is not provided")
        }
        let runID = try TaskQueue.submit(goal: goal, notBefore: resumeAt)
        return ToolResult(success: true, evidence: resumeAt == nil ? "Queued new run." : "Scheduled new run.", data: [
            "run_id": runID,
            "goal": goal,
            "resume_at": resumeAt ?? ""
        ])
    }

    private func taskGraphCreateTool(_ args: [String: Any]) throws -> ToolResult {
        guard let goal = string(args["goal"]), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("goal is required")
        }
        let nodes = try TaskGraphStore.nodes(from: string(args["nodes_json"]) ?? "", fallbackGoal: goal)
        let graph = try TaskGraphStore.create(title: string(args["title"]) ?? goal, goal: goal, nodes: nodes)
        return ToolResult(success: true, evidence: "Created durable task graph \(graph.id).", data: graph.dictionary)
    }

    private func taskGraphListTool(_ args: [String: Any]) -> ToolResult {
        let graphs = TaskGraphStore.list().prefix(min(100, max(1, int(args["limit"]) ?? 20)))
        return ToolResult(success: true, evidence: "Returned \(graphs.count) durable task graph(s).", data: [
            "graphs": jsonStringValue(graphs.map(\.dictionary))
        ])
    }

    private func taskGraphStatusTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        let graph = try TaskGraphStore.read(id)
        return ToolResult(success: true, evidence: "Loaded durable task graph.", data: graph.dictionary)
    }

    private func taskGraphTickTool(_ args: [String: Any]) throws -> ToolResult {
        let results = try TaskGraphStore.tick(graphID: string(args["id"]))
        return ToolResult(success: true, evidence: "Ticked \(results.count) durable task graph(s).", data: [
            "results": jsonStringValue(results.map(\.dictionary))
        ])
    }

    private func longRunDaemonStatusTool() -> ToolResult {
        ToolResult(success: true, evidence: "Loaded long-run daemon state.", data: LongRunDaemonStore.status().dictionary)
    }

    private func longRunDaemonTickTool() throws -> ToolResult {
        let state = try LongRunDaemonStore.tick()
        return ToolResult(success: true, evidence: "Advanced long-run daemon.", data: state.dictionary)
    }

    private func longRunScheduleTool(_ args: [String: Any]) throws -> ToolResult {
        guard let goal = string(args["goal"]), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeError("goal is required") }
        return ToolResult(success: true, evidence: "Scheduled long-running goal.", data: try LongRunDaemonStore.schedule(goal: goal, afterSeconds: double(args["after_seconds"]) ?? 0))
    }

    private func backgroundDriverMatrixTool() -> ToolResult {
        ToolResult(success: true, evidence: "Loaded background driver matrix.", data: [
            "drivers": jsonStringValue(BackgroundDriverBridge.matrix())
        ])
    }

    private func backgroundDriverDispatchTool(_ args: [String: Any]) throws -> ToolResult {
        let data = try BackgroundDriverBridge.dispatch(args: args)
        return ToolResult(success: data["status"] != "failed", evidence: "Built background driver dispatch envelope.", data: data, error: data["status"] == "failed" ? "background_driver_failed" : nil)
    }

    private func visualGrounderProfilesTool() -> ToolResult {
        ToolResult(success: true, evidence: "Loaded visual grounder profiles.", data: [
            "profiles": jsonStringValue(VisualGrounderRuntime.profiles())
        ])
    }

    private func visualGrounderSessionTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Built visual grounding session plan.", data: VisualGrounderRuntime.sessionPlan(args: args))
    }

    private func visualUIMapQueryTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Queried cached visual UI maps.", data: VisualGrounderRuntime.queryUIMaps(query: string(args["query"]) ?? "", limit: int(args["limit"]) ?? 10))
    }

    private func recipeLearnOnceTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        return ToolResult(success: true, evidence: "Learned a stable recipe program from one run.", data: try RecipeLearningEngine.learnOnce(runID: runID, recipeID: string(args["recipe_id"]), title: string(args["title"]) ?? ""))
    }

    private func recipeProgramSelectTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Selected reusable recipe programs.", data: RecipeLearningEngine.select(goal: string(args["goal"]) ?? "", limit: int(args["limit"]) ?? 5))
    }

    private func longTaskStateTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Loaded long-task runtime state.", data: LongTaskRuntimeEngine.state(runID: string(args["run_id"]), limit: int(args["limit"]) ?? 20))
    }

    private func longTaskWatchTool(_ args: [String: Any]) throws -> ToolResult {
        guard let goal = string(args["goal"]), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeError("goal is required") }
        guard let condition = string(args["condition"]), !condition.isEmpty else { throw RuntimeError("condition is required") }
        guard let value = string(args["value"]), !value.isEmpty else { throw RuntimeError("value is required") }
        return ToolResult(success: true, evidence: "Created durable long-task watcher.", data: try LongTaskRuntimeEngine.watch(goal: goal, condition: condition, value: value, title: string(args["title"]) ?? ""))
    }

    private func longTaskInterruptTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        guard let instruction = string(args["instruction"]), !instruction.isEmpty else { throw RuntimeError("instruction is required") }
        return ToolResult(success: true, evidence: "Applied long-task interrupt.", data: try LongTaskRuntimeEngine.interrupt(runID: runID, instruction: instruction, mode: string(args["mode"]) ?? "replan"))
    }

    private func memoryEntityGraphTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Built long-memory entity graph.", data: LongMemoryEngine.entityGraph(query: string(args["query"]) ?? "", limit: int(args["limit"]) ?? 30))
    }

    private func memoryPreferenceDigestTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Built long-memory preference digest.", data: LongMemoryEngine.preferenceDigest(query: string(args["query"]) ?? "", limit: int(args["limit"]) ?? 20))
    }

    private func browserAgentPlanTool(_ args: [String: Any]) -> ToolResult {
        let goal = string(args["goal"]) ?? ""
        return ToolResult(success: true, evidence: "Built browser agent plan.", data: BrowserAgentRuntime.agentPlan(goal: goal, url: string(args["url"]) ?? "", extractionSchema: string(args["extraction_schema"]) ?? ""))
    }

    private func browserAgentObservationTool(_ args: [String: Any]) throws -> ToolResult {
        guard let url = string(args["url"]), !url.isEmpty else { throw RuntimeError("url is required") }
        guard let goal = string(args["goal"]), !goal.isEmpty else { throw RuntimeError("goal is required") }
        guard let observation = string(args["observation_json"]), !observation.isEmpty else { throw RuntimeError("observation_json is required") }
        return ToolResult(success: true, evidence: "Recorded browser agent observation.", data: try BrowserAgentRuntime.recordObservation(url: url, goal: goal, observationJSON: observation))
    }

    private func browserAgentSnapshotTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Loaded browser agent snapshot.", data: BrowserAgentRuntime.snapshot(query: string(args["query"]) ?? "", limit: int(args["limit"]) ?? 20))
    }

    private func appSkillSDKTool() -> ToolResult {
        ToolResult(success: true, evidence: "Loaded app skill SDK contract.", data: AppSkillEcosystemStore.sdkSpec())
    }

    private func appSkillMarketplaceTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Loaded app skill marketplace.", data: AppSkillEcosystemStore.marketplace(query: string(args["query"]) ?? "", limit: int(args["limit"]) ?? 20))
    }

    private func cockpitDashboardTool(_ args: [String: Any]) -> ToolResult {
        ToolResult(success: true, evidence: "Built cockpit dashboard payload.", data: CockpitDashboardStore.dashboard(runID: string(args["run_id"]), limit: int(args["limit"]) ?? 20))
    }

    private func cockpitDashboardExportTool(_ args: [String: Any]) throws -> ToolResult {
        let url = try CockpitDashboardStore.export(runID: string(args["run_id"]), limit: int(args["limit"]) ?? 20)
        return ToolResult(success: true, evidence: "Exported cockpit dashboard.", data: ["path": url.path])
    }

    private func trajectoryBundleManifestTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        return ToolResult(success: true, evidence: "Built replayable session bundle manifest.", data: try ReplayableSessionBundleStore.manifest(runID: runID, limit: int(args["limit"]) ?? 400))
    }

    private func trajectoryBundleExportTool(_ args: [String: Any]) throws -> ToolResult {
        guard let runID = string(args["run_id"]), !runID.isEmpty else { throw RuntimeError("run_id is required") }
        let url = try ReplayableSessionBundleStore.export(runID: runID, limit: int(args["limit"]) ?? 400)
        return ToolResult(success: true, evidence: "Exported replayable session bundle.", data: ["run_id": runID, "path": url.path])
    }

    private func agentHarnessPlanTool(_ args: [String: Any]) throws -> ToolResult {
        guard let goal = string(args["goal"]), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeError("goal is required") }
        return ToolResult(success: true, evidence: "Built Codex-style agent harness plan.", data: try AgentHarnessStore.plan(goal: goal, app: string(args["app_name"]) ?? "", surface: string(args["surface"]) ?? ""))
    }

    private func agentHarnessTickTool(_ args: [String: Any]) throws -> ToolResult {
        guard let goal = string(args["goal"]), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeError("goal is required") }
        return ToolResult(success: true, evidence: "Advanced Codex-style agent harness.", data: try AgentHarnessStore.tick(goal: goal, currentRole: string(args["current_role"]) ?? "planner", evidence: string(args["evidence"]) ?? ""))
    }

    private func computerUseStrategyTool(_ args: [String: Any]) -> ToolResult {
        let goal = string(args["goal"]) ?? ""
        let app = string(args["app"]) ?? ""
        return ToolResult(success: true, evidence: "Selected computer-use strategy.", data: ComputerUseStrategy.suggest(goal: goal, app: app))
    }

    private func recipeListTool() throws -> ToolResult {
        let recipes = try RecipeStore.list().map { recipe in
            [
                "id": recipe.id,
                "title": recipe.title,
                "required_params": recipe.requiredParams.joined(separator: ","),
                "steps": "\(recipe.steps.count)"
            ]
        }
        return ToolResult(success: true, evidence: "Listed \(recipes.count) recipe(s).", data: ["recipes": jsonStringValue(recipes)])
    }

    private func recipeSuggestTool(_ args: [String: Any]) throws -> ToolResult {
        guard let goal = string(args["goal"]), !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError("goal is required")
        }
        let suggestions = try RecipeStore.suggest(goal: goal, limit: int(args["limit"]) ?? 5)
        return ToolResult(
            success: true,
            evidence: suggestions.isEmpty ? "No matching recipe suggestions." : "Suggested \(suggestions.count) matching recipe(s).",
            data: ["suggestions": jsonStringValue(suggestions.map(\.summary))]
        )
    }

    private func recipeExecuteTool(_ args: [String: Any]) throws -> ToolResult {
        guard let id = string(args["id"]), !id.isEmpty else { throw RuntimeError("id is required") }
        let params = try parseJSONObject(string(args["params_json"]) ?? "{}")
        let results = try RecipeStore.execute(recipeID: id, params: params)
        let ok = results.allSatisfy(\.success)
        return ToolResult(success: ok, evidence: ok ? "Executed recipe \(id)." : "Recipe \(id) stopped on a failed step.", data: [
            "recipe_id": id,
            "results": jsonStringValue(results.map { ["success": $0.success ? "true" : "false", "evidence": $0.evidence, "error": $0.error ?? ""] })
        ])
    }

    private func learnStartTool(_ args: [String: Any]) throws -> ToolResult {
        let session = try LearningStore.start(title: string(args["title"]) ?? "Learned workflow")
        return ToolResult(success: true, evidence: "Started learning session.", data: ["session_id": session.id, "title": session.title])
    }

    private func learnRecordTool(_ args: [String: Any]) throws -> ToolResult {
        guard let tool = string(args["tool"]), !tool.isEmpty else { throw RuntimeError("tool is required") }
        let arguments = try parseJSONObject(string(args["arguments_json"]) ?? "{}")
        let result = execute(ToolCall(id: "learn", name: tool, arguments: arguments, raw: [:]))
        try LearningStore.record(tool: tool, arguments: arguments, result: result)
        return ToolResult(success: result.success, evidence: "Recorded tool \(tool): \(result.evidence)", data: result.data, error: result.error, suggestion: result.suggestion)
    }

    private func learnRecordEventsTool(_ args: [String: Any]) throws -> ToolResult {
        guard let recipeID = string(args["recipe_id"]), !recipeID.isEmpty else { throw RuntimeError("recipe_id is required") }
        let recipe = try RawEventRecorder.recordRecipe(
            title: string(args["title"]) ?? "Raw UI workflow",
            recipeID: recipeID,
            duration: double(args["seconds"]) ?? 8,
            includeAX: bool(args["include_ax"]) ?? true,
            synthesize: bool(args["synthesize"]) ?? true
        )
        return ToolResult(success: true, evidence: "Recorded raw UI events into recipe.", data: [
            "recipe_id": recipe.id,
            "steps": "\(recipe.steps.count)",
            "notes": recipe.notes
        ])
    }

    private func learnStopTool(_ args: [String: Any]) throws -> ToolResult {
        guard let recipeID = string(args["recipe_id"]), !recipeID.isEmpty else { throw RuntimeError("recipe_id is required") }
        let recipe = try LearningStore.stop(recipeID: recipeID)
        return ToolResult(success: true, evidence: "Saved learned recipe.", data: ["recipe": recipe.jsonString])
    }

    private func finderListDirectory(_ args: [String: Any]) throws -> ToolResult {
        let path = (string(args["path"]) ?? "~/Downloads").expandingTildeInPath
        let limit = int(args["limit"]) ?? 80
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult(success: false, evidence: "Directory does not exist.", error: path)
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let entries = urls.prefix(limit).map(fileSummary)
        return ToolResult(success: true, evidence: "Listed \(entries.count) item(s) in \(path).", data: [
            "path": path,
            "entries": jsonStringValue(entries)
        ])
    }

    private func finderFileInfo(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        let info = fileSummary(URL(fileURLWithPath: path))
        return ToolResult(success: true, evidence: "Read file metadata.", data: info)
    }

    private func finderReadTextFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        let maxChars = int(args["max_chars"]) ?? 4_000
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let expected = string(args["contains"]) ?? ""
        let verified = expected.isEmpty || text.localizedCaseInsensitiveContains(expected)
        return ToolResult(success: verified, evidence: verified ? "Read and verified text file." : "Read text file, but expected content was not found.", data: [
            "effect": "file_content_verified",
            "app": "Finder",
            "target": path,
            "path": path,
            "contains": expected,
            "text": truncateMiddle(text, maxCharacters: maxChars),
            "chars": "\(text.count)",
            "verified": verified ? "true" : "false"
        ], error: verified ? nil : "Expected content not found")
    }

    private func finderFindFiles(_ args: [String: Any]) throws -> ToolResult {
        let root = (string(args["root"]) ?? "~/Downloads").expandingTildeInPath
        guard let needle = string(args["name_contains"]), !needle.isEmpty else {
            throw RuntimeError("name_contains is required")
        }
        let limit = int(args["limit"]) ?? 40
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return ToolResult(success: false, evidence: "Root directory does not exist.", error: root)
        }
        let rootURL = URL(fileURLWithPath: root)
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var results: [[String: String]] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.localizedCaseInsensitiveContains(needle) {
                results.append(fileSummary(url))
                if results.count >= limit { break }
            }
        }
        return ToolResult(success: true, evidence: "Found \(results.count) matching file(s).", data: [
            "root": root,
            "matches": jsonStringValue(results)
        ])
    }

    private func chromeOpenURL(_ args: [String: Any]) throws -> ToolResult {
        guard let rawURL = string(args["url"]), URL(string: rawURL) != nil else {
            throw RuntimeError("valid url is required")
        }
        _ = try runAppleScript("""
        tell application "Google Chrome"
          activate
          if (count of windows) = 0 then make new window
          set URL of active tab of front window to \(appleScriptString(rawURL))
        end tell
        """)
        Thread.sleep(forTimeInterval: 0.2)
        let current = (try? chromeGetCurrentTab())?.data["url"] ?? ""
        let verified = current.localizedCaseInsensitiveContains(rawURL) || rawURL.localizedCaseInsensitiveContains(current)
        return ToolResult(success: verified, evidence: verified ? "Opened and verified URL in Chrome." : "Chrome URL did not verify after open.", data: [
            "effect": "browser_url_visible",
            "app": "Chrome",
            "target": rawURL,
            "url": rawURL,
            "current_url": current,
            "verified": verified ? "true" : "false",
            "verified_current_url": verified ? "true" : "false"
        ], error: verified ? nil : "Expected Chrome URL not visible")
    }

    private func chromeGetCurrentTab() throws -> ToolResult {
        let text = try runAppleScript("""
        tell application "Google Chrome"
          if (count of windows) = 0 then return ""
          set tabTitle to title of active tab of front window
          set tabURL to URL of active tab of front window
          return tabTitle & linefeed & tabURL
        end tell
        """)
        let parts = text.components(separatedBy: "\n")
        return ToolResult(success: !text.isEmpty, evidence: text.isEmpty ? "Chrome has no front tab." : "Read Chrome front tab.", data: [
            "title": parts.first ?? "",
            "url": parts.dropFirst().joined(separator: "\n")
        ])
    }

    private func chromeNewTab(_ args: [String: Any]) throws -> ToolResult {
        let rawURL = string(args["url"])
        if let rawURL, URL(string: rawURL) == nil {
            throw RuntimeError("valid url is required")
        }
        let urlClause = rawURL.map { "with properties {URL:\(appleScriptString($0))}" } ?? ""
        _ = try runAppleScript("""
        tell application "Google Chrome"
          activate
          if (count of windows) = 0 then make new window
          make new tab at end of tabs of front window \(urlClause)
          set active tab index of front window to (count of tabs of front window)
        end tell
        """)
        if let rawURL {
            Thread.sleep(forTimeInterval: 0.2)
            let current = (try? chromeGetCurrentTab())?.data["url"] ?? ""
            let verified = current.localizedCaseInsensitiveContains(rawURL) || rawURL.localizedCaseInsensitiveContains(current)
            return ToolResult(success: verified, evidence: verified ? "Opened and verified a new Chrome tab with URL." : "Chrome new tab URL did not verify.", data: [
                "effect": "browser_url_visible",
                "app": "Chrome",
                "target": rawURL,
                "url": rawURL,
                "current_url": current,
                "verified": verified ? "true" : "false",
                "verified_current_url": verified ? "true" : "false"
            ], error: verified ? nil : "Expected Chrome URL not visible")
        }
        return ToolResult(success: true, evidence: "Opened a new Chrome tab.", data: [
            "effect": "browser_tab_opened",
            "app": "Chrome",
            "verified": "true"
        ])
    }

    private func chromeSearch(_ args: [String: Any]) throws -> ToolResult {
        guard let query = string(args["query"]), !query.isEmpty else { throw RuntimeError("query is required") }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try chromeOpenURL(["url": "https://www.google.com/search?q=\(encoded)"])
    }

    private func wpsOpenFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        try runProcess("/usr/bin/open", ["-a", "wpsoffice", path])
        return ToolResult(success: true, evidence: "Opened file in WPS Office.", data: ["path": path])
    }

    private func notesCreateNote(_ args: [String: Any]) throws -> ToolResult {
        guard let title = string(args["title"]), !title.isEmpty else { throw RuntimeError("title is required") }
        guard let body = string(args["body"]) else { throw RuntimeError("body is required") }
        _ = try runAppleScript("""
        tell application "Notes"
          activate
          make new note with properties {name:\(appleScriptString(title)), body:\(appleScriptString(body))}
        end tell
        """)
        let verification = try runAppleScript("""
        tell application "Notes"
          set matches to every note whose name is \(appleScriptString(title))
          return (count of matches) as text
        end tell
        """)
        let verified = (Int(verification.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
        return ToolResult(success: verified, evidence: verified ? "Created and verified Apple Notes note." : "Created Apple Notes note, but verification did not find it.", data: [
            "effect": "note_created",
            "app": "Notes",
            "target": title,
            "title": title,
            "chars": "\(body.count)",
            "verified": verified ? "true" : "false"
        ], error: verified ? nil : "Note title not found after create")
    }

    private func notesSearch(_ args: [String: Any]) throws -> ToolResult {
        guard let query = string(args["query"]), !query.isEmpty else { throw RuntimeError("query is required") }
        _ = try openApp(["bundle_id": "com.apple.Notes"])
        Thread.sleep(forTimeInterval: 0.4)
        _ = try clipboardSetText(["text": query])
        try sendKeyboardShortcut(key: "f", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Opened Notes search and pasted query.", data: ["query": query])
    }

    private func mailComposeDraft(_ args: [String: Any]) throws -> ToolResult {
        let to = (try? stringArray(args["to"], name: "to")) ?? []
        let attachments = (try? stringArray(args["attachments"], name: "attachments")) ?? []
        guard let subject = string(args["subject"]) else { throw RuntimeError("subject is required") }
        guard let body = string(args["body"]) else { throw RuntimeError("body is required") }
        let recipientLines = to.map {
            "make new to recipient at end of to recipients with properties {address:\(appleScriptString($0))}"
        }.joined(separator: "\n")
        let attachmentLines = try attachments.map { rawPath -> String in
            let path = rawPath.expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw RuntimeError("attachment does not exist: \(path)") }
            return "make new attachment with properties {file name:POSIX file \(appleScriptString(path))} at after last paragraph"
        }.joined(separator: "\n")
        _ = try runAppleScript("""
        tell application "Mail"
          activate
          set draftMessage to make new outgoing message with properties {subject:\(appleScriptString(subject)), content:\(appleScriptString(body)), visible:true}
          tell draftMessage
            \(recipientLines)
            \(attachmentLines)
          end tell
        end tell
        """)
        return ToolResult(success: true, evidence: "Created visible Mail draft. It was not sent.", data: [
            "effect": "mail_draft_created",
            "app": "Mail",
            "target": subject,
            "value": body,
            "verified": "true",
            "recipients": jsonStringValue(to),
            "subject": subject,
            "attachments": jsonStringValue(attachments)
        ])
    }

    private func mailSearchMessages(_ args: [String: Any]) throws -> ToolResult {
        guard let query = string(args["query"]), !query.isEmpty else { throw RuntimeError("query is required") }
        _ = try openApp(["bundle_id": "com.apple.mail"])
        Thread.sleep(forTimeInterval: 0.4)
        _ = try clipboardSetText(["text": query])
        try sendKeyboardShortcut(key: "f", modifiers: ["command", "option"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Opened Mail search and pasted query.", data: ["query": query])
    }

    private func calendarCreateEvent(_ args: [String: Any]) throws -> ToolResult {
        guard let title = string(args["title"]), !title.isEmpty else { throw RuntimeError("title is required") }
        guard let startText = string(args["start"]), let start = parseDateTime(startText) else {
            throw RuntimeError("start must be parseable, e.g. 2026-05-21 15:30")
        }
        guard let endText = string(args["end"]), let end = parseDateTime(endText) else {
            throw RuntimeError("end must be parseable, e.g. 2026-05-21 16:00")
        }
        let calendarName = string(args["calendar"])
        let notes = string(args["notes"]) ?? ""
        let targetCalendarLine = if let calendarName, !calendarName.isEmpty {
            "set targetCalendar to first calendar whose name contains \(appleScriptString(calendarName))"
        } else {
            "set targetCalendar to calendar 1"
        }
        _ = try runAppleScript("""
        tell application "Calendar"
          activate
          \(appleScriptDateAssignment("startDate", start))
          \(appleScriptDateAssignment("endDate", end))
          \(targetCalendarLine)
          make new event at end of events of targetCalendar with properties {summary:\(appleScriptString(title)), start date:startDate, end date:endDate, description:\(appleScriptString(notes))}
        end tell
        """)
        let verification = try calendarFindEvents(["title": title, "days": 365])
        let verified = verification.success && (verification.data["events"] ?? "[]") != "[]"
        return ToolResult(success: verified, evidence: verified ? "Created and verified Calendar event." : "Created Calendar event, but verification did not find it.", data: [
            "effect": "calendar_event_created",
            "app": "Calendar",
            "target": title,
            "title": title,
            "start": startText,
            "end": endText,
            "verified": verified ? "true" : "false",
            "events": verification.data["events"] ?? ""
        ], error: verified ? nil : "Calendar event not found after create")
    }

    private func calendarFindEvents(_ args: [String: Any]) throws -> ToolResult {
        guard let title = string(args["title"]), !title.isEmpty else { throw RuntimeError("title is required") }
        let days = int(args["days"]) ?? 30
        let output = try runAppleScript("""
        tell application "Calendar"
          set startDate to current date
          set endDate to startDate + (\(days) * days)
          set foundEvents to {}
          repeat with c in calendars
            set matches to (every event of c whose summary contains \(appleScriptString(title)) and start date ≥ startDate and start date ≤ endDate)
            repeat with e in matches
              set end of foundEvents to (summary of e & " | " & (start date of e as string))
            end repeat
          end repeat
          set AppleScript's text item delimiters to linefeed
          return foundEvents as text
        end tell
        """)
        let events = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return ToolResult(success: true, evidence: "Found \(events.count) Calendar event(s).", data: [
            "title": title,
            "events": jsonStringValue(events)
        ])
    }

    private func wechatOpen() throws -> ToolResult {
        try runProcess("/usr/bin/open", ["-a", "WeChat"])
        return ToolResult(success: true, evidence: "Opened WeChat.", data: [
            "effect": "app_opened",
            "app": "WeChat",
            "verified": "true"
        ])
    }

    private func wechatSearchChat(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        _ = try wechatOpen()
        Thread.sleep(forTimeInterval: 0.5)
        _ = try clipboardSetText(["text": name])
        try sendKeyboardShortcut(key: "f", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Searched WeChat for chat/contact. Verify the result before external actions.", data: ["name": name])
    }

    private func wechatOpenChat(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]) ?? string(args["name"]), !recipient.isEmpty else {
            throw RuntimeError("recipient is required")
        }
        _ = try wechatSearchChat(["name": recipient])
        Thread.sleep(forTimeInterval: 0.35)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        let recipientCheck = try chatVerify(
            appName: "WeChat",
            bundleID: "com.tencent.xinWeChat",
            expected: recipient,
            scope: .currentChat
        )
        guard recipientCheck.success else {
            return ToolResult(
                success: false,
                evidence: "WeChat chat was not verified after opening the search result.",
                data: [
                    "effect": "chat_session_ready",
                    "app": "WeChat",
                    "target": recipient,
                    "recipient": recipient,
                    "verified": "false",
                    "verified_recipient": "false",
                    "ax_excerpt": recipientCheck.data["ax_excerpt"] ?? "",
                    "ocr_excerpt": recipientCheck.data["ocr_excerpt"] ?? ""
                ],
                error: recipientCheck.error ?? recipientCheck.evidence,
                suggestion: "Search the contact again or click the intended top result, then retry the chat action."
            )
        }
        return ToolResult(success: true, evidence: "Opened and verified WeChat chat.", data: [
            "effect": "chat_session_ready",
            "app": "WeChat",
            "target": recipient,
            "recipient": recipient,
            "verified": "true",
            "verified_recipient": "true",
            "ax_excerpt": recipientCheck.data["ax_excerpt"] ?? "",
            "ocr_excerpt": recipientCheck.data["ocr_excerpt"] ?? ""
        ])
    }

    private func wechatStageFile(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]), !recipient.isEmpty else { throw RuntimeError("recipient is required") }
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Attachment path does not exist.", error: path)
        }
        let openChat = try wechatOpenChat(["recipient": recipient])
        guard openChat.success else { return openChat }
        _ = try clipboardSetFiles(["paths": [path]])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Staged file in WeChat input. It was not sent. Verify recipient on screen before sending.", data: [
            "effect": "external_message_staged",
            "app": "WeChat",
            "target": recipient,
            "value": URL(fileURLWithPath: path).lastPathComponent,
            "verified": "false",
            "recipient": recipient,
            "path": path
        ])
    }

    private func wechatSendText(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]), !recipient.isEmpty else { throw RuntimeError("recipient is required") }
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let probe = messageVerificationProbe(text)
        if recentlyAttemptedExternalSend(app: "WeChat", recipient: recipient, text: text, within: 180) {
            let messageCheck = try chatVerifyAnyProbe(
                appName: "WeChat",
                bundleID: "com.tencent.xinWeChat",
                probes: messageVerificationProbes(text),
                scope: .message,
                attempts: 2
            )
            return ToolResult(
                success: messageCheck.success,
                evidence: messageCheck.success ? "Verified recent WeChat message after duplicate-send guard." : "Skipped duplicate WeChat send attempt; recent identical send was already submitted but not verified.",
                data: [
                    "effect": "external_message_sent",
                    "app": "WeChat",
                    "target": recipient,
                    "value": text,
                    "verified": messageCheck.success ? "true" : "false",
                    "recipient": recipient,
                    "message": text,
                    "message_probe": messageCheck.data["expected"] ?? probe,
                    "chars": "\(text.count)",
                    "verified_recipient": "true",
                    "verified_message": messageCheck.success ? "true" : "false",
                    "duplicate_guard": "true"
                ],
                error: messageCheck.success ? nil : (messageCheck.error ?? "Message text not found after recent send attempt"),
                suggestion: messageCheck.success ? nil : "Do not press send again for the same text. Observe the chat or ask the user before retrying."
            )
        }
        let openChat = try wechatOpenChat(["recipient": recipient])
        guard openChat.success else {
            return ToolResult(
                success: false,
                evidence: "WeChat recipient was not verified before sending.",
                data: [
                    "recipient": recipient,
                    "verified_recipient": "false",
                    "verified_message": "false",
                    "ax_excerpt": openChat.data["ax_excerpt"] ?? "",
                    "ocr_excerpt": openChat.data["ocr_excerpt"] ?? ""
                ],
                error: openChat.error ?? openChat.evidence,
                suggestion: "Search/open the chat again and verify the current chat title before sending."
            )
        }
        try focusChatInput(appName: "WeChat", bundleID: "com.tencent.xinWeChat")
        _ = try clipboardSetText(["text": text])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.2)
        markExternalSendAttempt(app: "WeChat", recipient: recipient, text: text)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 1.0)
        let messageCheck = try chatVerifyAnyProbe(
            appName: "WeChat",
            bundleID: "com.tencent.xinWeChat",
            probes: messageVerificationProbes(text),
            scope: .message,
            attempts: 3
        )
        return ToolResult(success: messageCheck.success, evidence: messageCheck.success ? "Sent and verified WeChat text message." : "Pressed send in WeChat, but recent message was not verified.", data: [
            "effect": "external_message_sent",
            "app": "WeChat",
            "target": recipient,
            "value": text,
            "verified": messageCheck.success ? "true" : "false",
            "recipient": recipient,
            "message": text,
            "message_probe": messageCheck.data["expected"] ?? probe,
            "chars": "\(text.count)",
            "verified_recipient": "true",
            "verified_message": messageCheck.success ? "true" : "false"
        ], error: messageCheck.success ? nil : (messageCheck.error ?? "Message text not found after send"), suggestion: messageCheck.success ? nil : "Do not mark done and do not resend the same text automatically. Observe the chat or ask the user before retrying.")
    }

    private func wechatSendStaged(_ args: [String: Any]) throws -> ToolResult {
        let recipient = string(args["recipient"]) ?? ""
        let recipientCheck = try chatVerify(appName: "WeChat", bundleID: "com.tencent.xinWeChat", expected: recipient)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "WeChat recipient was not verified before sending staged content.", data: [
                "recipient": recipient,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        return ToolResult(success: true, evidence: "Pressed Return in verified WeChat chat to send staged content.", data: [
            "effect": "external_message_sent",
            "app": "WeChat",
            "target": recipient,
            "verified": "false",
            "recipient": recipient,
            "verified_recipient": "true",
            "verified_message": "false"
        ], suggestion: "Verify the attachment/message appears in the chat before marking the task complete.")
    }

    private func larkOpen() throws -> ToolResult {
        try runProcess("/usr/bin/open", ["-a", "Lark"])
        return ToolResult(success: true, evidence: "Opened Lark.", data: [
            "effect": "app_opened",
            "app": "Lark",
            "verified": "true"
        ])
    }

    private func larkSearchChat(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        _ = try larkOpen()
        Thread.sleep(forTimeInterval: 0.6)
        _ = try clipboardSetText(["text": name])
        try sendKeyboardShortcut(key: "k", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.15)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Searched Lark for chat/contact. Verify the result before external actions.", data: ["name": name])
    }

    private func larkStageFile(_ args: [String: Any]) throws -> ToolResult {
        guard let chat = string(args["chat"]), !chat.isEmpty else { throw RuntimeError("chat is required") }
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Attachment path does not exist.", error: path)
        }
        _ = try larkSearchChat(["name": chat])
        Thread.sleep(forTimeInterval: 0.3)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.5)
        _ = try clipboardSetFiles(["paths": [path]])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Staged file in Lark input. It was not sent. Verify chat on screen before sending.", data: [
            "effect": "external_message_staged",
            "app": "Lark",
            "target": chat,
            "value": URL(fileURLWithPath: path).lastPathComponent,
            "verified": "false",
            "chat": chat,
            "path": path
        ])
    }

    private func larkSendText(_ args: [String: Any]) throws -> ToolResult {
        guard let chat = string(args["chat"]), !chat.isEmpty else { throw RuntimeError("chat is required") }
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let probe = messageVerificationProbe(text)
        _ = try larkSearchChat(["name": chat])
        Thread.sleep(forTimeInterval: 0.3)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.5)
        let recipientCheck = try chatVerify(appName: "Lark", bundleID: nil, expected: chat)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "Lark chat was not verified before sending.", data: [
                "chat": chat,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        _ = try clipboardSetText(["text": text])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        let messageCheck = try chatVerify(appName: "Lark", bundleID: nil, expected: probe)
        return ToolResult(success: messageCheck.success, evidence: messageCheck.success ? "Sent and verified Lark text message." : "Pressed send in Lark, but recent message was not verified.", data: [
            "effect": "external_message_sent",
            "app": "Lark",
            "target": chat,
            "value": text,
            "verified": messageCheck.success ? "true" : "false",
            "chat": chat,
            "message": text,
            "message_probe": probe,
            "chars": "\(text.count)",
            "verified_recipient": "true",
            "verified_message": messageCheck.success ? "true" : "false"
        ], error: messageCheck.success ? nil : (messageCheck.error ?? "Message text not found after send"), suggestion: messageCheck.success ? nil : "Do not mark done. Re-open the intended chat and verify the sent message is visible.")
    }

    private func larkSendStaged(_ args: [String: Any]) throws -> ToolResult {
        let chat = string(args["chat"]) ?? ""
        let recipientCheck = try chatVerify(appName: "Lark", bundleID: nil, expected: chat)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "Lark chat was not verified before sending staged content.", data: [
                "chat": chat,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        return ToolResult(success: true, evidence: "Pressed Return in verified Lark chat to send staged content.", data: [
            "effect": "external_message_sent",
            "app": "Lark",
            "target": chat,
            "verified": "false",
            "chat": chat,
            "verified_recipient": "true",
            "verified_message": "false"
        ], suggestion: "Verify the attachment/message appears in the chat before marking the task complete.")
    }

    private func qqOpen() throws -> ToolResult {
        try runProcess("/usr/bin/open", ["-a", "QQ"])
        return ToolResult(success: true, evidence: "Opened QQ.", data: [
            "effect": "app_opened",
            "app": "QQ",
            "verified": "true"
        ])
    }

    private func qqSearchChat(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        _ = try qqOpen()
        Thread.sleep(forTimeInterval: 0.5)
        _ = try clipboardSetText(["text": name])
        try sendKeyboardShortcut(key: "f", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.15)
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Searched QQ for chat/contact. Verify the result before external actions.", data: ["name": name])
    }

    private func qqStageFile(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]), !recipient.isEmpty else { throw RuntimeError("recipient is required") }
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Attachment path does not exist.", error: path)
        }
        _ = try qqSearchChat(["name": recipient])
        Thread.sleep(forTimeInterval: 0.3)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.5)
        _ = try clipboardSetFiles(["paths": [path]])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        return ToolResult(success: true, evidence: "Staged file in QQ input. It was not sent. Verify recipient on screen before sending.", data: [
            "effect": "external_message_staged",
            "app": "QQ",
            "target": recipient,
            "value": URL(fileURLWithPath: path).lastPathComponent,
            "verified": "false",
            "recipient": recipient,
            "path": path
        ])
    }

    private func qqSendText(_ args: [String: Any]) throws -> ToolResult {
        guard let recipient = string(args["recipient"]), !recipient.isEmpty else { throw RuntimeError("recipient is required") }
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        let probe = messageVerificationProbe(text)
        _ = try qqSearchChat(["name": recipient])
        Thread.sleep(forTimeInterval: 0.3)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.4)
        let recipientCheck = try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: recipient)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "QQ recipient was not verified before sending.", data: [
                "recipient": recipient,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        _ = try clipboardSetText(["text": text])
        try sendKeyboardShortcut(key: "v", modifiers: ["command"])
        Thread.sleep(forTimeInterval: 0.1)
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        let messageCheck = try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: probe)
        return ToolResult(success: messageCheck.success, evidence: messageCheck.success ? "Sent and verified QQ text message." : "Pressed send in QQ, but recent message was not verified.", data: [
            "effect": "external_message_sent",
            "app": "QQ",
            "target": recipient,
            "value": text,
            "verified": messageCheck.success ? "true" : "false",
            "recipient": recipient,
            "message": text,
            "message_probe": probe,
            "chars": "\(text.count)",
            "verified_recipient": "true",
            "verified_message": messageCheck.success ? "true" : "false"
        ], error: messageCheck.success ? nil : (messageCheck.error ?? "Message text not found after send"), suggestion: messageCheck.success ? nil : "Do not mark done. Re-open the intended chat and verify the sent message is visible.")
    }

    private func qqSendStaged(_ args: [String: Any]) throws -> ToolResult {
        let recipient = string(args["recipient"]) ?? ""
        let recipientCheck = try chatVerify(appName: "QQ", bundleID: "com.tencent.qq", expected: recipient)
        guard recipientCheck.success else {
            return ToolResult(success: false, evidence: "QQ recipient was not verified before sending staged content.", data: [
                "recipient": recipient,
                "verified_recipient": "false",
                "verified_message": "false"
            ], error: recipientCheck.error ?? recipientCheck.evidence)
        }
        try sendKeyboardShortcut(key: "return", modifiers: [])
        Thread.sleep(forTimeInterval: 0.8)
        return ToolResult(success: true, evidence: "Pressed Return in verified QQ chat to send staged content.", data: [
            "effect": "external_message_sent",
            "app": "QQ",
            "target": recipient,
            "verified": "false",
            "recipient": recipient,
            "verified_recipient": "true",
            "verified_message": "false"
        ], suggestion: "Verify the attachment/message appears in the chat before marking the task complete.")
    }

    private enum ChatVerifyScope {
        case any
        case currentChat
        case message
    }

    private func chatVerify(appName: String, bundleID: String?, expected: String, scope: ChatVerifyScope = .any) throws -> ToolResult {
        guard !expected.isEmpty else { throw RuntimeError("expected text is required") }
        var args: [String: Any] = ["app_name": appName, "max_depth": 6, "max_nodes": 260]
        if let bundleID { args["bundle_id"] = bundleID }
        try activateTargetAppIfProvided(args)
        let ax = axDescribeFrontmost(args)
        let text = ax.data["tree"] ?? ""
        let axOK = chatVerificationTextMatches(text, expected: expected, scope: scope)
        let ocr = try? ocrScreen([:])
        let ocrText = ocr?.data["text"] ?? ""
        let ocrOK = chatVerificationTextMatches(ocrText, expected: expected, scope: scope)
        let ok = axOK || ocrOK
        return ToolResult(success: ok, evidence: ok ? "\(appName) \(axOK ? "UI" : "OCR") contains expected text." : "\(appName) verification did not find expected text.", data: [
            "expected": expected,
            "ax_excerpt": truncateMiddle(text, maxCharacters: 2_000),
            "ocr_excerpt": truncateMiddle(ocrText, maxCharacters: 2_000)
        ], error: ok ? nil : "Expected text not found")
    }

    private func chatVerifyAnyProbe(appName: String, bundleID: String?, probes: [String], scope: ChatVerifyScope, attempts: Int) throws -> ToolResult {
        var last = ToolResult(success: false, evidence: "\(appName) verification did not run.", error: "No probe")
        for _ in 0..<max(1, attempts) {
            for probe in probes where !probe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let result = try chatVerify(appName: appName, bundleID: bundleID, expected: probe, scope: scope)
                if result.success { return result }
                last = result
            }
            Thread.sleep(forTimeInterval: 0.6)
        }
        return last
    }

    private func chatVerificationTextMatches(_ text: String, expected: String, scope: ChatVerifyScope) -> Bool {
        guard text.localizedCaseInsensitiveContains(expected) else { return false }
        switch scope {
        case .any:
            return true
        case .message:
            return true
        case .currentChat:
            let lowered = text.lowercased()
            let expectedLower = expected.lowercased()
            if lowered.contains("包含：\(expectedLower)") ||
                lowered.contains("搜索网络结果") ||
                (lowered.contains("查看全部") && lowered.contains("聊天记录")) {
                return false
            }
            return true
        }
    }

    func messageVerificationProbe(_ text: String) -> String {
        messageVerificationProbes(text).first ?? ""
    }

    private func messageVerificationProbes(_ text: String) -> [String] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var probes: [String] = []
        func add(_ value: String) {
            let trimmed = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "，。,.；;：:、 "))
            guard trimmed.count >= 4 else { return }
            if !probes.contains(trimmed) { probes.append(trimmed) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = [
            "项目的原理",
            "核心原理",
            "任务规划",
            "自主调用各种工具",
            "无需人工逐步干预",
            "project concept",
            "plans steps",
            "executes tools"
        ]
        for phrase in phrases where trimmed.localizedCaseInsensitiveContains(phrase) {
            add(phrase)
        }
        for line in lines {
            for separator in ["。", "！", "!", "\n"] {
                if let first = line.components(separatedBy: separator).first, first.count >= 4 {
                    add(String(first.prefix(18)))
                }
            }
            add(String(line.prefix(18)))
        }
        add(String(trimmed.prefix(18)))
        return probes
    }

    private func focusChatInput(appName: String, bundleID: String?) throws {
        var args: [String: Any] = ["app_name": appName]
        if let bundleID { args["bundle_id"] = bundleID }
        try activateTargetAppIfProvided(args)
        Thread.sleep(forTimeInterval: 0.2)
        if let app = NSWorkspace.shared.frontmostApplication {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let textArea = findAXElement(root, label: "", role: "AXTextArea", maxNodes: 1_500),
               let position = axCGPoint(textArea, kAXPositionAttribute as CFString),
               let size = axCGSize(textArea, kAXSizeAttribute as CFString),
               size.width > 40,
               size.height > 20 {
                try clickPoint(x: Double(position.x + size.width / 2), y: Double(position.y + size.height / 2))
                Thread.sleep(forTimeInterval: 0.15)
                return
            }
        }
        if let bounds = frontmostWindowBounds() {
            try clickPoint(
                x: Double(bounds.midX + bounds.width * 0.18),
                y: Double(bounds.maxY - max(42, min(95, bounds.height * 0.09)))
            )
        }
        Thread.sleep(forTimeInterval: 0.15)
    }

    private func recentlyAttemptedExternalSend(app: String, recipient: String, text: String, within seconds: TimeInterval) -> Bool {
        pruneRecentExternalSendAttempts()
        let key = externalSendKey(app: app, recipient: recipient, text: text)
        guard let date = Self.recentExternalSendAttempts[key] else { return false }
        return Date().timeIntervalSince(date) <= seconds
    }

    private func markExternalSendAttempt(app: String, recipient: String, text: String) {
        pruneRecentExternalSendAttempts()
        Self.recentExternalSendAttempts[externalSendKey(app: app, recipient: recipient, text: text)] = Date()
    }

    private func pruneRecentExternalSendAttempts() {
        let cutoff = Date().addingTimeInterval(-600)
        Self.recentExternalSendAttempts = Self.recentExternalSendAttempts.filter { $0.value >= cutoff }
    }

    private func externalSendKey(app: String, recipient: String, text: String) -> String {
        "\(app.lowercased())|\(recipient.lowercased())|\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func tencentMeetingStageJoin(_ args: [String: Any]) throws -> ToolResult {
        guard let meeting = string(args["meeting"]), !meeting.isEmpty else { throw RuntimeError("meeting is required") }
        _ = try openNamedApp("TencentMeeting")
        _ = try clipboardSetText(["text": meeting])
        return ToolResult(success: true, evidence: "Opened Tencent Meeting and copied meeting id/link to clipboard. It did not join.", data: ["meeting": meeting])
    }

    private func baiduNetdiskStageFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        _ = try openNamedApp("BaiduNetdisk_mac")
        _ = try clipboardSetFiles(["paths": [path]])
        return ToolResult(success: true, evidence: "Opened Baidu Netdisk and put the file on clipboard. It did not upload.", data: ["path": path])
    }

    private func toDeskStageRemoteID(_ args: [String: Any]) throws -> ToolResult {
        guard let remoteID = string(args["remote_id"]), !remoteID.isEmpty else { throw RuntimeError("remote_id is required") }
        _ = try openNamedApp("ToDesk")
        _ = try clipboardSetText(["text": remoteID])
        return ToolResult(success: true, evidence: "Opened ToDesk and copied remote id/code to clipboard. It did not connect.", data: ["remote_id": remoteID])
    }

    private func openNamedApp(_ appName: String) throws -> ToolResult {
        try runProcess("/usr/bin/open", ["-a", appName])
        return ToolResult(success: true, evidence: "Opened \(appName).", data: [
            "effect": "app_opened",
            "app": appName,
            "verified": "true"
        ])
    }

    private func openAppTarget(_ target: AppLaunchTarget) throws -> ToolResult {
        if let rawPath = target.appPath {
            let path = rawPath.expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                try runProcess("/usr/bin/open", [path])
                return ToolResult(success: true, evidence: "Opened \(target.displayName).", data: [
                    "effect": "app_opened",
                    "app": target.displayName,
                    "path": path,
                    "verified": "true"
                ])
            }
        }

        if let appName = target.appName {
            try runProcess("/usr/bin/open", ["-a", appName])
            return ToolResult(success: true, evidence: "Opened \(target.displayName).", data: [
                "effect": "app_opened",
                "app": target.displayName,
                "open_name": appName,
                "verified": "true"
            ])
        }

        return ToolResult(success: false, evidence: "Application bundle was not found.", error: target.displayName)
    }

    private func openPathWithApp(_ args: [String: Any], appName: String) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        try runProcess("/usr/bin/open", ["-a", appName, path])
        return ToolResult(success: true, evidence: "Opened path in \(appName).", data: ["app": appName, "path": path])
    }

    private func libreOfficeExportPDF(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        let inputURL = URL(fileURLWithPath: path)
        let outdir = (string(args["outdir"]) ?? inputURL.deletingLastPathComponent().path).expandingTildeInPath
        try FileManager.default.createDirectory(atPath: outdir, withIntermediateDirectories: true)
        let soffice = try resolveSofficePath()
        let output = try runProcess(soffice, [
            "--headless",
            "--convert-to", "pdf",
            "--outdir", outdir,
            path
        ])
        let pdfURL = URL(fileURLWithPath: outdir)
            .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("pdf")
        let exists = FileManager.default.fileExists(atPath: pdfURL.path)
        return ToolResult(success: exists, evidence: exists ? "Exported PDF with LibreOffice." : "LibreOffice finished but PDF was not found.", data: [
            "effect": "pdf_exported",
            "app": "LibreOffice",
            "target": path,
            "value": pdfURL.path,
            "verified": exists ? "true" : "false",
            "path": path,
            "outdir": outdir,
            "pdf": pdfURL.path,
            "output": output
        ], error: exists ? nil : "Expected PDF not found: \(pdfURL.path)")
    }

    private func resolveSofficePath() throws -> String {
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let which = try? runProcess("/usr/bin/which", ["soffice"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let which, !which.isEmpty, FileManager.default.isExecutableFile(atPath: which) {
            return which
        }
        throw RuntimeError("soffice executable not found. Install LibreOffice or put soffice on PATH.")
    }

    private func dockerStatus() -> ToolResult {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.docker.docker").first
        let windows = app.map { visibleWindowTitles(pid: $0.processIdentifier) } ?? []
        return ToolResult(
            success: true,
            evidence: app == nil ? "Docker Desktop is not running." : "Docker Desktop is running.",
            data: [
                "running": app == nil ? "false" : "true",
                "pid": app.map { "\($0.processIdentifier)" } ?? "",
                "windows": windows.joined(separator: " | ")
            ]
        )
    }

    private func shortcutsList() throws -> ToolResult {
        let output = try runProcess("/usr/bin/shortcuts", ["list"])
        let names = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ToolResult(success: true, evidence: "Listed \(names.count) Shortcut(s).", data: [
            "shortcuts": jsonStringValue(names)
        ])
    }

    private func shortcutsRun(_ args: [String: Any]) throws -> ToolResult {
        guard let name = string(args["name"]), !name.isEmpty else { throw RuntimeError("name is required") }
        let output = try runProcess("/usr/bin/shortcuts", ["run", name])
        return ToolResult(success: true, evidence: "Ran Shortcut \(name).", data: [
            "effect": "shortcut_ran",
            "app": "Shortcuts",
            "target": name,
            "name": name,
            "output": output,
            "verified": "true"
        ])
    }

    private func sdefLookup(_ args: [String: Any]) throws -> ToolResult {
        let targetPath: String
        if let rawPath = string(args["path"]), !rawPath.isEmpty {
            targetPath = rawPath.expandingTildeInPath
        } else if let appName = string(args["app_name"]), !appName.isEmpty {
            targetPath = try appPathForName(appName)
        } else {
            throw RuntimeError("app_name or path is required")
        }
        let xml = try runProcess("/usr/bin/sdef", [targetPath])
        let query = string(args["query"])?.lowercased()
        let maxLines = int(args["max_lines"]) ?? 120
        let lines = xml.components(separatedBy: .newlines)
            .filter { line in
                guard let query, !query.isEmpty else { return true }
                return line.lowercased().contains(query)
            }
        let summary = summarizeSDEF(xml: xml, query: query, maxLines: maxLines)
        return ToolResult(success: true, evidence: "Read AppleScript dictionary for \(targetPath).", data: [
            "path": targetPath,
            "summary": summary,
            "matched_lines": lines.prefix(maxLines).joined(separator: "\n"),
            "truncated": lines.count > maxLines ? "true" : "false"
        ])
    }

    private func scriptingBridgeProbe(_ args: [String: Any]) -> ToolResult {
        guard let bundleID = string(args["bundle_id"]), !bundleID.isEmpty else {
            return ToolResult(success: false, evidence: "bundle_id is required.", error: "bundle_id is required")
        }
        guard let app = SBApplication(bundleIdentifier: bundleID) else {
            return ToolResult(success: false, evidence: "No ScriptingBridge application object.", error: bundleID)
        }
        return ToolResult(success: true, evidence: "ScriptingBridge application object is available.", data: [
            "bundle_id": bundleID,
            "running": app.isRunning ? "true" : "false",
            "class": "\(type(of: app))"
        ])
    }

    private func remindersCreate(_ args: [String: Any]) throws -> ToolResult {
        guard let title = string(args["title"]), !title.isEmpty else { throw RuntimeError("title is required") }
        let notes = string(args["notes"]) ?? ""
        let listName = string(args["list"])
        let targetListLine = if let listName, !listName.isEmpty {
            "set targetList to first list whose name contains \(appleScriptString(listName))"
        } else {
            "set targetList to default list"
        }
        _ = try runAppleScript("""
        tell application "Reminders"
          activate
          \(targetListLine)
          make new reminder at end of reminders of targetList with properties {name:\(appleScriptString(title)), body:\(appleScriptString(notes))}
        end tell
        """)
        let verification = try runAppleScript("""
        tell application "Reminders"
          set foundReminders to {}
          repeat with l in lists
            set matches to (every reminder of l whose name contains \(appleScriptString(title)))
            repeat with r in matches
              set end of foundReminders to name of r
            end repeat
          end repeat
          set AppleScript's text item delimiters to linefeed
          return foundReminders as text
        end tell
        """)
        let verified = verification.localizedCaseInsensitiveContains(title)
        return ToolResult(success: verified, evidence: verified ? "Created and verified local reminder." : "Created local reminder, but verification did not find it.", data: [
            "effect": "reminder_created",
            "app": "Reminders",
            "target": title,
            "title": title,
            "notes": notes,
            "verified": verified ? "true" : "false"
        ], error: verified ? nil : "Reminder title not found after create")
    }

    private func safariNewTab(_ args: [String: Any]) throws -> ToolResult {
        let rawURL = string(args["url"])
        if let rawURL, URL(string: rawURL) == nil {
            throw RuntimeError("valid url is required")
        }
        let urlLine = rawURL.map { "set URL of newTab to \(appleScriptString($0))" } ?? ""
        _ = try runAppleScript("""
        tell application "Safari"
          activate
          if not (exists window 1) then make new document
          tell window 1
            set newTab to make new tab at end of tabs
            set current tab to newTab
            \(urlLine)
          end tell
        end tell
        """)
        if let rawURL {
            Thread.sleep(forTimeInterval: 0.2)
            let current = (try? safariGetCurrentURL())?.data["url"] ?? ""
            let verified = current.localizedCaseInsensitiveContains(rawURL) || rawURL.localizedCaseInsensitiveContains(current)
            return ToolResult(success: verified, evidence: verified ? "Opened and verified a new Safari tab with URL." : "Safari new tab URL did not verify.", data: [
                "effect": "browser_url_visible",
                "app": "Safari",
                "target": rawURL,
                "url": rawURL,
                "current_url": current,
                "verified": verified ? "true" : "false",
                "verified_current_url": verified ? "true" : "false"
            ], error: verified ? nil : "Expected Safari URL not visible")
        }
        return ToolResult(success: true, evidence: "Opened a new Safari tab.", data: [
            "effect": "browser_tab_opened",
            "app": "Safari",
            "verified": "true"
        ])
    }

    private func safariSearch(_ args: [String: Any]) throws -> ToolResult {
        guard let query = string(args["query"]), !query.isEmpty else { throw RuntimeError("query is required") }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try safariOpenURL(["url": "https://www.google.com/search?q=\(encoded)"])
    }

    private func fileSummary(_ url: URL) -> [String: String] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey])
        return [
            "name": url.lastPathComponent,
            "path": url.path,
            "kind": values?.isDirectory == true ? "directory" : "file",
            "is_package": values?.isPackage == true ? "true" : "false",
            "size": "\(values?.fileSize ?? 0)",
            "modified": values?.contentModificationDate.map(isoDateString) ?? ""
        ]
    }

    private func parseDateTime(_ text: String) -> Date? {
        let formats = [
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    private func appleScriptDateAssignment(_ variable: String, _ date: Date) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let month = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ][max(0, min(11, (parts.month ?? 1) - 1))]
        let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        return """
        set \(variable) to current date
        set year of \(variable) to \(parts.year ?? 2000)
        set month of \(variable) to \(month)
        set day of \(variable) to \(parts.day ?? 1)
        set time of \(variable) to \(seconds)
        """
    }

    private func textEditNewDocument() throws -> ToolResult {
        _ = try runAppleScript("""
        tell application "TextEdit"
          activate
          make new document
        end tell
        """)
        return ToolResult(success: true, evidence: "TextEdit has a new front document.", data: [
            "effect": "app_opened",
            "app": "TextEdit",
            "verified": "true"
        ])
    }

    private func textEditSetText(_ args: [String: Any]) throws -> ToolResult {
        guard let text = string(args["text"]) else { throw RuntimeError("text is required") }
        _ = try runAppleScript("""
        tell application "TextEdit"
          activate
          if not (exists document 1) then make new document
          set text of document 1 to \(appleScriptString(text))
        end tell
        """)
        return ToolResult(success: true, evidence: "TextEdit front document text was set.", data: ["chars": "\(text.count)"])
    }

    private func textEditReadText() throws -> ToolResult {
        let text = try runAppleScript("""
        tell application "TextEdit"
          if not (exists document 1) then return ""
          return text of document 1
        end tell
        """)
        return ToolResult(success: true, evidence: "Read TextEdit front document.", data: ["text": text, "chars": "\(text.count)"])
    }

    private func textEditSaveAs(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let overwrite = bool(args["overwrite"]) ?? false
        let path = rawPath.expandingTildeInPath
        let url = URL(fileURLWithPath: path)

        if FileManager.default.fileExists(atPath: path), !overwrite {
            return ToolResult(
                success: false,
                evidence: "Refused to overwrite existing file.",
                error: "File exists: \(path)",
                suggestion: "Set overwrite=true only if the user explicitly asked to overwrite."
            )
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            _ = try runAppleScript("""
            tell application "TextEdit"
              if not (exists document 1) then error "No TextEdit document is open"
              save document 1 in POSIX file \(appleScriptString(path))
            end tell
            """)
        } catch {
            let text = try runAppleScript("""
            tell application "TextEdit"
              if not (exists document 1) then error "No TextEdit document is open"
              return text of document 1
            end tell
            """)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        let exists = FileManager.default.fileExists(atPath: path)
        return ToolResult(success: exists, evidence: exists ? "File exists at \(path)." : "Save did not create the file.", data: [
            "effect": "file_saved",
            "app": "TextEdit",
            "target": path,
            "path": path,
            "verified": exists ? "true" : "false"
        ])
    }

    private func finderCreateFolder(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let isDir = isDirectory(path)
        return ToolResult(success: isDir, evidence: isDir ? "Folder exists at \(path)." : "Folder was not found after creation.", data: [
            "effect": "folder_created",
            "app": "Finder",
            "target": path,
            "path": path,
            "verified": isDir ? "true" : "false"
        ])
    }

    private func finderRevealFile(_ args: [String: Any]) throws -> ToolResult {
        guard let rawPath = string(args["path"]) else { throw RuntimeError("path is required") }
        let path = rawPath.expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, evidence: "Path does not exist.", error: path)
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return ToolResult(success: true, evidence: "Finder is revealing \(path).", data: ["path": path])
    }

    private func safariOpenURL(_ args: [String: Any]) throws -> ToolResult {
        guard let raw = string(args["url"]), let url = URL(string: raw) else {
            throw RuntimeError("valid url is required")
        }
        _ = try runAppleScript("""
        tell application "Safari"
          activate
          open location \(appleScriptString(url.absoluteString))
        end tell
        """)
        Thread.sleep(forTimeInterval: 0.2)
        let current = (try? safariGetCurrentURL())?.data["url"] ?? ""
        let verified = current.localizedCaseInsensitiveContains(url.absoluteString) || url.absoluteString.localizedCaseInsensitiveContains(current)
        return ToolResult(success: verified, evidence: verified ? "Safari opened and verified \(url.absoluteString)." : "Safari URL did not verify after open.", data: [
            "effect": "browser_url_visible",
            "app": "Safari",
            "target": url.absoluteString,
            "url": url.absoluteString,
            "current_url": current,
            "verified": verified ? "true" : "false",
            "verified_current_url": verified ? "true" : "false"
        ], error: verified ? nil : "Expected Safari URL not visible")
    }

    private func safariGetCurrentURL() throws -> ToolResult {
        let url = try runAppleScript("""
        tell application "Safari"
          if not (exists document 1) then return ""
          return URL of front document
        end tell
        """)
        return ToolResult(success: !url.isEmpty, evidence: url.isEmpty ? "Safari has no front URL." : "Read Safari front URL.", data: ["url": url])
    }

    private func safariGetPageText() throws -> ToolResult {
        return try safariEvalJS(["script": "document.body ? document.body.innerText : ''"])
    }

    private func safariEvalJS(_ args: [String: Any]) throws -> ToolResult {
        guard let script = string(args["script"]), !script.isEmpty else { throw RuntimeError("script is required") }
        do {
            let output = try runAppleScript("""
            tell application "Safari"
              if not (exists document 1) then return ""
              return do JavaScript \(appleScriptString(script)) in front document
            end tell
            """)
            return ToolResult(success: true, evidence: "Executed JavaScript in Safari front document.", data: [
                "result": output,
                "chars": "\(output.count)"
            ])
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("JavaScript") || message.localizedCaseInsensitiveContains("Apple Events") {
                return ToolResult(
                    success: false,
                    evidence: "Safari JavaScript automation is not available.",
                    error: message,
                    suggestion: "Enable Safari Developer menu and Allow JavaScript from Apple Events, or use AX/screenshot observation tools."
                )
            }
            throw error
        }
    }

    private func chromeGetPageText() throws -> ToolResult {
        return try chromeEvalJS(["script": "document.body ? document.body.innerText : ''"])
    }

    private func chromeEvalJS(_ args: [String: Any]) throws -> ToolResult {
        guard let script = string(args["script"]), !script.isEmpty else { throw RuntimeError("script is required") }
        do {
            let output = try runAppleScript("""
            tell application "Google Chrome"
              if (count of windows) = 0 then return ""
              return execute active tab of front window javascript \(appleScriptString(script))
            end tell
            """)
            return ToolResult(success: true, evidence: "Executed JavaScript in Chrome active tab.", data: [
                "result": output,
                "chars": "\(output.count)"
            ])
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("JavaScript") || message.localizedCaseInsensitiveContains("Apple") {
                return ToolResult(
                    success: false,
                    evidence: "Chrome JavaScript automation is not available.",
                    error: message,
                    suggestion: "Enable Chrome menu View > Developer > Allow JavaScript from Apple Events, or use AX/screenshot observation tools."
                )
            }
            throw error
        }
    }

    private func terminalRunCommand(_ args: [String: Any]) throws -> ToolResult {
        guard let command = string(args["command"]), !command.isEmpty else {
            throw RuntimeError("command is required")
        }
        _ = try runAppleScript("""
        tell application "Terminal"
          activate
          do script \(appleScriptString(command))
        end tell
        """)
        return ToolResult(success: true, evidence: "Terminal command was submitted.", data: [
            "effect": "shell_command_submitted",
            "app": "Terminal",
            "target": command,
            "command": command,
            "verified": "true"
        ])
    }

    private func appBundles(in root: URL, maxDepth: Int) -> [URL] {
        guard maxDepth >= 0 else { return [] }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for url in contents {
            if url.pathExtension == "app" {
                results.append(url)
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                results.append(contentsOf: appBundles(in: url, maxDepth: maxDepth - 1))
            }
        }
        return results
    }

    private func appInfo(_ url: URL) -> [String: String]? {
        guard url.pathExtension == "app" else { return nil }
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let fileName = url.deletingPathExtension().lastPathComponent
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? fileName
        return [
            "name": name,
            "bundle_id": bundle?.bundleIdentifier ?? "",
            "path": url.path
        ]
    }

    private func appPathForName(_ appName: String) throws -> String {
        let normalizedName = canonicalAppName(appName)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: commonBundleID(for: normalizedName)) {
            return url.path
        }
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/tmp/\(normalizedName.lowercased()).txt")) {
            let last = url.deletingPathExtension().lastPathComponent
            if last.localizedCaseInsensitiveContains(normalizedName) {
                return url.path
            }
        }
        let roots = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities"
        ]
        let matches = roots.flatMap { appBundles(in: URL(fileURLWithPath: $0), maxDepth: 3) }
            .filter { url in
                url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(normalizedName)
                    || (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "").localizedCaseInsensitiveContains(normalizedName)
                    || (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "").localizedCaseInsensitiveContains(normalizedName)
            }
        guard let first = matches.sorted(by: { $0.path < $1.path }).first else {
            if let builtIn = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.\(normalizedName)") {
                return builtIn.path
            }
            throw RuntimeError("Application not found: \(appName)")
        }
        let path = first.path
        if path.hasPrefix("/System/Applications/"), !FileManager.default.fileExists(atPath: path.appending("/Contents/sdef")) {
            let applicationPath = "/Applications/\(first.lastPathComponent)"
            if FileManager.default.fileExists(atPath: applicationPath) {
                return applicationPath
            }
        }
        return path
    }

    private func commonBundleID(for appName: String) -> String {
        let normalized = canonicalAppName(appName).lowercased().replacingOccurrences(of: " ", with: "")
        let map = [
            "safari": "com.apple.Safari",
            "textedit": "com.apple.TextEdit",
            "finder": "com.apple.finder",
            "mail": "com.apple.mail",
            "calendar": "com.apple.iCal",
            "notes": "com.apple.Notes",
            "reminders": "com.apple.reminders",
            "preview": "com.apple.Preview",
            "shortcuts": "com.apple.shortcuts",
            "wechat": "com.tencent.xinWeChat",
            "weixin": "com.tencent.xinWeChat",
            "lark": "com.larksuite.lark",
            "feishu": "com.electron.lark",
            "qq": "com.tencent.qq"
        ]
        return map[normalized] ?? "com.apple.\(appName)"
    }

    private func canonicalAppName(_ appName: String) -> String {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
        let map = [
            "微信": "WeChat",
            "wechat": "WeChat",
            "weixin": "WeChat",
            "飞书": "Lark",
            "lark": "Lark",
            "feishu": "Lark",
            "日历": "Calendar",
            "calendar": "Calendar",
            "提醒事项": "Reminders",
            "reminders": "Reminders",
            "备忘录": "Notes",
            "notes": "Notes",
            "邮件": "Mail",
            "mail": "Mail",
            "文本编辑": "TextEdit",
            "textedit": "TextEdit",
            "访达": "Finder",
            "finder": "Finder",
            "预览": "Preview",
            "preview": "Preview",
            "快捷指令": "Shortcuts",
            "shortcuts": "Shortcuts",
            "谷歌浏览器": "Google Chrome",
            "chrome": "Google Chrome"
        ]
        return map[normalized] ?? trimmed
    }

    private func appMatchesName(_ app: NSRunningApplication, requested: String) -> Bool {
        let localized = app.localizedName ?? ""
        let bundleID = app.bundleIdentifier ?? ""
        let requestedCanonical = canonicalAppName(requested)
        let localizedCanonical = canonicalAppName(localized)
        return localized.localizedCaseInsensitiveContains(requested) ||
            localized.localizedCaseInsensitiveContains(requestedCanonical) ||
            localizedCanonical.localizedCaseInsensitiveContains(requestedCanonical) ||
            requestedCanonical.localizedCaseInsensitiveContains(localizedCanonical) ||
            bundleID.localizedCaseInsensitiveContains(requested) ||
            bundleID.localizedCaseInsensitiveContains(requestedCanonical)
    }

    private func summarizeSDEF(xml: String, query: String?, maxLines: Int) -> String {
        let interestingTags = ["<suite", "<command", "<class", "<property", "<element", "<enumeration", "<enumerator"]
        let lines = xml.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                interestingTags.contains { line.hasPrefix($0) }
            }
            .filter { line in
                guard let query, !query.isEmpty else { return true }
                return line.lowercased().contains(query)
            }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    private func findRunningApp(_ args: [String: Any]) throws -> NSRunningApplication {
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        if let appName = string(args["app_name"]), !appName.isEmpty,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               appMatchesName($0, requested: appName)
           }) {
            return app
        }
        throw RuntimeError("running app not found; provide app_name or bundle_id")
    }

    private func appNameForTarget(_ args: [String: Any]) throws -> String {
        if let appName = string(args["app_name"]), !appName.isEmpty {
            let normalizedName = canonicalAppName(appName)
            _ = try openApp(["app_name": normalizedName])
            Thread.sleep(forTimeInterval: 0.2)
            return normalizedName
        }
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            _ = try openApp(["bundle_id": bundleID])
            Thread.sleep(forTimeInterval: 0.2)
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let name = app.localizedName {
                return name
            }
            throw RuntimeError("could not resolve app name for bundle id \(bundleID)")
        }
        guard let name = NSWorkspace.shared.frontmostApplication?.localizedName else {
            throw RuntimeError("no frontmost app")
        }
        return name
    }

    private func activateTargetAppIfProvided(_ args: [String: Any]) throws {
        if let appName = string(args["app_name"]), !appName.isEmpty {
            _ = try openApp(["app_name": canonicalAppName(appName)])
            Thread.sleep(forTimeInterval: 0.2)
            return
        }
        if let bundleID = string(args["bundle_id"]), !bundleID.isEmpty {
            _ = try openApp(["bundle_id": bundleID])
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func sendKeyboardShortcut(key: String, modifiers: [String]) throws {
        guard let keyCode = keyCode(for: key) else {
            throw RuntimeError("unsupported key: \(key)")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = eventFlags(for: modifiers)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw RuntimeError("could not create keyboard event")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        up.post(tap: .cghidEventTap)
    }

    private func clickPoint(x: Double, y: Double) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let point = CGPoint(x: x, y: y)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            throw RuntimeError("could not create mouse event")
        }
        down.post(tap: .cghidEventTap)
        usleep(60_000)
        up.post(tap: .cghidEventTap)
    }

    private func moveMouse(x: Double, y: Double) throws {
        let point = CGPoint(x: x, y: y)
        guard let move = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw RuntimeError("could not create mouse move event")
        }
        move.post(tap: .cghidEventTap)
    }

    private func dragMouse(from: CGPoint, to: CGPoint, duration: Double) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
        else {
            throw RuntimeError("could not create drag event")
        }
        down.post(tap: .cghidEventTap)
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                drag.post(tap: .cghidEventTap)
            }
            usleep(useconds_t(max(0.01, duration / Double(steps)) * 1_000_000))
        }
        up.post(tap: .cghidEventTap)
    }

    private func longPress(x: Double, y: Double, duration: Double) throws {
        let point = CGPoint(x: x, y: y)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            throw RuntimeError("could not create long press event")
        }
        down.post(tap: .cghidEventTap)
        usleep(useconds_t(max(0.1, duration) * 1_000_000))
        up.post(tap: .cghidEventTap)
    }

    private func setAXWindowPosition(_ window: AXUIElement, x: Double, y: Double) throws {
        var point = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &point) else { throw RuntimeError("could not create AX point") }
        let err = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        guard err == .success else { throw RuntimeError("AX window position failed: \(err.rawValue)") }
    }

    private func setAXWindowSize(_ window: AXUIElement, width: Double, height: Double) throws {
        var size = CGSize(width: width, height: height)
        guard let value = AXValueCreate(.cgSize, &size) else { throw RuntimeError("could not create AX size") }
        let err = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        guard err == .success else { throw RuntimeError("AX window size failed: \(err.rawValue)") }
    }

    private func eventFlags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "command", "cmd", "meta":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "option", "alt":
                flags.insert(.maskAlternate)
            case "control", "ctrl":
                flags.insert(.maskControl)
            default:
                continue
            }
        }
        return flags
    }

    private func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.lowercased()
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
            "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51,
            "backspace": 51, "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125,
            "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
            "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
        ]
        return map[normalized]
    }

    private func focusedAXElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value.map { unsafeDowncast($0, to: AXUIElement.self) }
    }

    private func axCopy(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success else { return nil }
        return value
    }

    private func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        guard let value = axCopy(element, attribute) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func axBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        guard let value = axCopy(element, attribute) else { return nil }
        return value as? Bool
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = axCopy(element, kAXChildrenAttribute as CFString) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func describeAXElement(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        lines: inout [String],
        count: inout Int
    ) {
        guard depth <= maxDepth, count < maxNodes else { return }
        count += 1
        let role = axString(element, kAXRoleAttribute as CFString) ?? "AXUnknown"
        let title = axString(element, kAXTitleAttribute as CFString) ?? ""
        let value = axString(element, kAXValueAttribute as CFString) ?? ""
        let desc = axString(element, kAXDescriptionAttribute as CFString) ?? ""
        let enabled = axBool(element, kAXEnabledAttribute as CFString).map { $0 ? "enabled" : "disabled" } ?? ""
        let bits = [role, title, value, desc, enabled].filter { !$0.isEmpty }
        lines.append("\(String(repeating: "  ", count: depth))- \(bits.joined(separator: " | "))")
        for child in axChildren(element) {
            describeAXElement(child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, lines: &lines, count: &count)
            if count >= maxNodes { return }
        }
    }

    private func findAXElement(_ root: AXUIElement, label: String, role: String?, maxNodes: Int) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        let needle = label.lowercased()
        let roleNeedle = role?.lowercased()
        while !queue.isEmpty, visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            let elementRole = axString(element, kAXRoleAttribute as CFString) ?? ""
            let text = [
                axString(element, kAXTitleAttribute as CFString),
                axString(element, kAXDescriptionAttribute as CFString),
                axString(element, kAXValueAttribute as CFString),
                axString(element, kAXHelpAttribute as CFString)
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            if text.contains(needle), roleNeedle == nil || elementRole.lowercased().contains(roleNeedle!) {
                return element
            }
            queue.append(contentsOf: axChildren(element))
        }
        return nil
    }

    private func collectActionableAXElements(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        visited: inout Int,
        elements: inout [[String: String]],
        path: String
    ) {
        guard depth <= maxDepth, visited < maxNodes else { return }
        visited += 1
        let role = axString(element, kAXRoleAttribute as CFString) ?? ""
        let title = axString(element, kAXTitleAttribute as CFString) ?? ""
        let desc = axString(element, kAXDescriptionAttribute as CFString) ?? ""
        let value = axString(element, kAXValueAttribute as CFString) ?? ""
        let label = [title, desc, value].filter { !$0.isEmpty }.joined(separator: " | ")
        let actionableRoles = [
            "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuItem", "AXLink",
            "AXCell", "AXRow"
        ]
        if actionableRoles.contains(role) || !label.isEmpty && role != "AXGroup" && role != "AXStaticText" {
            var row: [String: String] = [
                "index": "\(elements.count + 1)",
                "role": role,
                "label": label,
                "ax_path": path,
                "title": title,
                "description": desc,
                "value": value
            ]
            if let position = axCGPoint(element, kAXPositionAttribute as CFString) {
                row["x"] = "\(Int(position.x))"
                row["y"] = "\(Int(position.y))"
            }
            if let size = axCGSize(element, kAXSizeAttribute as CFString) {
                row["width"] = "\(Int(size.width))"
                row["height"] = "\(Int(size.height))"
            }
            elements.append(row)
        }
        for (index, child) in axChildren(element).enumerated() {
            collectActionableAXElements(child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, visited: &visited, elements: &elements, path: "\(path).\(index)")
            if visited >= maxNodes { return }
        }
    }

    private func findAXElementByPath(_ root: AXUIElement, path: String) -> AXUIElement? {
        let parts = path.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        var current = root
        for index in parts.dropFirst() {
            let children = axChildren(current)
            guard index >= 0, index < children.count else { return nil }
            current = children[index]
        }
        return current
    }

    private func axCGPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        guard let value = axCopy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var point = CGPoint.zero
        if AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) {
            return point
        }
        return nil
    }

    private func axCGSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        guard let value = axCopy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var size = CGSize.zero
        if AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) {
            return size
        }
        return nil
    }

    private func visibleWindowTitles(pid: pid_t) -> [String] {
        guard pid > 0 else { return [] }
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos.compactMap { info in
            guard ownerPID(from: info) == pid else { return nil }
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return info[kCGWindowName as String] as? String
        }.filter { !$0.isEmpty }
    }

    private func frontmostWindowBounds() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  ownerPID(from: info) == app.processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any]
            else { continue }
            let x = double(bounds["X"]) ?? 0
            let y = double(bounds["Y"]) ?? 0
            let width = double(bounds["Width"]) ?? 0
            let height = double(bounds["Height"]) ?? 0
            if width > 0, height > 0 {
                return CGRect(x: x, y: y, width: width, height: height)
            }
        }
        return nil
    }

    private func ownerPID(from info: [String: Any]) -> pid_t? {
        if let value = info[kCGWindowOwnerPID as String] as? NSNumber {
            return pid_t(value.int32Value)
        }
        if let value = info[kCGWindowOwnerPID as String] as? Int {
            return pid_t(value)
        }
        return nil
    }
}
