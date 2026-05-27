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

struct LaunchAgentManager {
    static let label = "com.aios.host"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func install() throws {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": EventStore.rootURL.appendingPathComponent("launchd.out.log").path,
            "StandardErrorPath": EventStore.rootURL.appendingPathComponent("launchd.err.log").path,
            "EnvironmentVariables": [
                "AIOS_STATE_DIR": EventStore.rootURL.path
            ]
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: EventStore.rootURL, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: [.atomic])
        _ = try? runProcess("/bin/launchctl", ["unload", plistURL.path])
        _ = try runProcess("/bin/launchctl", ["load", plistURL.path])
        try AIOSConfig.update(key: "run_at_login", value: "true")
    }

    static func uninstall() throws {
        _ = try? runProcess("/bin/launchctl", ["unload", plistURL.path])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        try AIOSConfig.update(key: "run_at_login", value: "false")
    }

    static func statusText() -> String {
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        let loaded = (try? runProcess("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])) != nil
        return [
            "installed: \(installed)",
            "loaded: \(loaded)",
            "plist: \(plistURL.path)"
        ].joined(separator: "\n")
    }
}

@MainActor
final class AIOSHost: NSObject, NSApplicationDelegate {
    private let menuBar: Bool
    private var statusItem: NSStatusItem?
    private var running = false

    init(menuBar: Bool) {
        self.menuBar = menuBar
    }

    func run() async {
        if menuBar {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.delegate = self
            setupStatusItem()
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.drainQueueOnce()
                }
            }
            print("AIOS host running. State: \(EventStore.rootURL.path)")
            NSApplication.shared.run()
            return
        }
        print("AIOS host running. State: \(EventStore.rootURL.path)")
        while true {
            await drainQueueOnce()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "AIOS"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "AIOS Host Running", action: nil, keyEquivalent: ""))
        let tickItem = NSMenuItem(title: "Tick Daemon Now", action: #selector(tickDaemonNow), keyEquivalent: "t")
        tickItem.target = self
        menu.addItem(tickItem)
        let openState = NSMenuItem(title: "Open State Folder", action: #selector(openStateFolder), keyEquivalent: "o")
        openState.target = self
        menu.addItem(openState)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func openStateFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([EventStore.rootURL])
    }

    @objc private func tickDaemonNow() {
        Task { @MainActor in
            await drainQueueOnce()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func drainQueueOnce() async {
        guard !running else { return }
        _ = try? LongRunDaemonStore.tick()
        guard let item = try? TaskQueue.next() else { return }
        if let summary = try? EventStore.readSummary(runID: item.id), summary.status == "canceled" {
            try? TaskQueue.remove(item.url)
            return
        }
        running = true
        defer { running = false }
        let config = LLMConfig.fromEnvironment()
        var store: EventStore?
        do {
            store = try EventStore.start(goal: item.goal, runID: item.id)
            let loop = AgentLoop(client: OpenAICompatibleClient(config: config), tools: ToolRegistry(), eventStore: store)
            let complete = try await loop.run(goal: item.goal)
            try store?.updateStatus(complete ? "complete" : "incomplete")
            try TaskQueue.remove(item.url)
        } catch {
            if store == nil {
                store = try? EventStore.start(goal: item.goal, runID: item.id)
            }
            try? store?.append("RunFailed", ["error": error.localizedDescription])
            try? store?.updateStatus("failed")
            try? TaskQueue.remove(item.url)
            fputs("AIOS host task failed: \(error.localizedDescription)\n", stderr)
        }
    }
}

@MainActor
final class AIOSDesktopApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model = AIOSAppModel()

    func run() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.delegate = self
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = AIOSAppView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AIOS"
        window.center()
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        model.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class AIOSAppModel: ObservableObject {
    @Published var goal = ""
    @Published var runs: [EventStore.RunSummary] = []
    @Published var selectedRunID = ""
    @Published var selectedEvents = ""
    @Published var checkpointText = ""
    @Published var dashboardText = ""
    @Published var trajectoryText = ""
    @Published var replayPlanText = ""
    @Published var strategyText = ""
    @Published var memoryText = ""
    @Published var appSkillsText = ""
    @Published var routinesText = ""
    @Published var verifierText = ""
    @Published var learningWorkflowText = ""
    @Published var auditText = ""
    @Published var evalText = ""
    @Published var status = ""
    @Published var baseURL = AIOSConfig.default.baseURL
    @Published var modelName = AIOSConfig.default.model
    @Published var maxSteps = "\(AIOSConfig.default.maxSteps)"
    @Published var feedbackText = ""
    @Published var isRunning = false
    private var refreshTimer: Timer?

    func refresh() {
        do {
            runs = try EventStore.listRuns()
            if selectedRunID.isEmpty, let first = runs.first {
                selectedRunID = first.id
            }
            loadSelected()
            memoryText = jsonStringValue(MemoryStore.recent(limit: 12).map(\.dictionary))
            appSkillsText = jsonStringValue(AppSkillStore.list().map(\.dictionary))
            routinesText = jsonStringValue(RoutineStore.status(limit: 20))
            verifierText = jsonStringValue(AppVerifierStore.list(limit: 20).map(\.dictionary))
            learningWorkflowText = jsonStringValue(LearnWorkflowStore.list(limit: 20).map(\.dictionary))
            auditText = AuditLog.readText(limit: 80)
            evalText = E2ERunner.lastRunText()
            let config = try AIOSConfig.load()
            baseURL = config.baseURL
            modelName = config.model
            maxSteps = "\(config.maxSteps)"
            if !isRunning {
                status = "Ready"
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func submit() {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Enter a task."
            return
        }
        do {
            let id = try TaskQueue.submit(goal: trimmed)
            selectedRunID = id
            goal = ""
            status = "Submitted \(id). Running..."
            refresh()
            startInlineRun(runID: id, goal: trimmed)
        } catch {
            status = error.localizedDescription
        }
    }

    private func startInlineRun(runID: String, goal: String) {
        guard !isRunning else {
            status = "A task is already running."
            return
        }
        isRunning = true
        startAutoRefresh()
        Task { @MainActor in
            var store: EventStore?
            do {
                try TaskQueue.cancel(runID)
                store = try EventStore.start(goal: goal, runID: runID)
                selectedRunID = runID
                status = "Running \(runID.prefix(8))"
                let config = LLMConfig.fromEnvironment()
                let loop = AgentLoop(client: OpenAICompatibleClient(config: config), tools: ToolRegistry(), eventStore: store)
                let complete = try await loop.run(goal: goal)
                try store?.updateStatus(complete ? "complete" : "incomplete")
                status = complete ? "Complete \(runID.prefix(8))" : "Incomplete \(runID.prefix(8))"
            } catch {
                if store == nil {
                    store = try? EventStore.start(goal: goal, runID: runID)
                }
                try? store?.append("RunFailed", ["error": error.localizedDescription])
                try? store?.updateStatus("failed")
                status = "Failed: \(error.localizedDescription)"
            }
            isRunning = false
            stopAutoRefresh()
            refresh()
        }
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func loadSelected() {
        guard !selectedRunID.isEmpty else {
            selectedEvents = ""
            checkpointText = ""
            dashboardText = ""
            trajectoryText = ""
            replayPlanText = ""
            strategyText = ""
            return
        }
        selectedEvents = (try? EventStore.readEventsText(runID: selectedRunID)) ?? ""
        let summary = try? EventStore.readSummary(runID: selectedRunID)
        let checkpointURL = EventStore.runsURL
            .appendingPathComponent(selectedRunID, isDirectory: true)
            .appendingPathComponent("checkpoint.json")
        checkpointText = (try? String(contentsOf: checkpointURL, encoding: .utf8)) ?? "暂无 checkpoint"
        dashboardText = jsonStringValue(CockpitDashboardStore.dashboard(runID: selectedRunID, limit: 20))
        strategyText = jsonStringValue(ComputerUseStrategy.suggest(goal: summary?.goal ?? selectedEvents))
        if let events = try? TrajectoryStore.summarize(runID: selectedRunID, limit: 120) {
            trajectoryText = jsonStringValue(events)
        } else {
            trajectoryText = "暂无轨迹"
        }
        if let replay = try? TrajectoryStore.replayPlan(runID: selectedRunID, fromIndex: 1) {
            replayPlanText = jsonStringValue(replay)
        } else {
            replayPlanText = "暂无 replay plan"
        }
    }

    func cancelSelected() {
        guard !selectedRunID.isEmpty else { return }
        do {
            try TaskQueue.cancel(selectedRunID)
            try EventStore.markRun(runID: selectedRunID, status: "canceled", event: "RunCanceled", fields: [:])
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func retrySelected() {
        guard !selectedRunID.isEmpty else { return }
        do {
            let summary = try EventStore.readSummary(runID: selectedRunID)
            let newID = try TaskQueue.submit(goal: summary.goal)
            try EventStore.markRun(runID: selectedRunID, status: "retried", event: "RunRetried", fields: ["new_run_id": newID])
            selectedRunID = newID
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func resumeSelected() {
        guard !selectedRunID.isEmpty else { return }
        do {
            let summary = try EventStore.readSummary(runID: selectedRunID)
            try TaskQueue.submitExisting(runID: selectedRunID, goal: summary.goal)
            status = "Resume queued \(selectedRunID.prefix(8))"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func cockpitCommand(_ command: String) {
        guard !selectedRunID.isEmpty else { return }
        do {
            let item = try CockpitControlStore.record(runID: selectedRunID, command: command, feedback: feedbackText)
            status = "\(command) \(item.status)"
            if command == "feedback" || command == "replan" || command == "branch" {
                feedbackText = ""
            }
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func saveConfig() {
        do {
            try AIOSConfig.update(key: "base_url", value: baseURL)
            try AIOSConfig.update(key: "model", value: modelName)
            try AIOSConfig.update(key: "max_steps", value: maxSteps)
            status = "Config saved"
        } catch {
            status = error.localizedDescription
        }
    }

    func openStateFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([EventStore.rootURL])
    }

    func exportReplaySession() {
        guard !selectedRunID.isEmpty else { return }
        do {
            let url = try TrajectoryStore.exportSession(runID: selectedRunID)
            status = "Replay session exported: \(url.path)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = error.localizedDescription
        }
    }

    func tickDaemon() {
        do {
            let state = try LongRunDaemonStore.tick()
            status = "Daemon tick \(state.tickCount)"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func runEval() {
        do {
            let results = try E2ERunner().run(filter: nil, repeatCount: 1)
            let passed = results.filter(\.passed).count
            evalText = E2ERunner.lastRunText()
            status = "Eval \(passed)/\(results.count) passed"
        } catch {
            status = error.localizedDescription
        }
    }
}

struct AIOSAppView: View {
    @ObservedObject var model: AIOSAppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("告诉 AIOS 要完成什么任务", text: $model.goal)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submit() }
                    .disabled(model.isRunning)
                Button(model.isRunning ? "运行中" : "提交") { model.submit() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.isRunning)
                Button("刷新") { model.refresh() }
                Button("Tick") { model.tickDaemon() }
                Button("状态目录") { model.openStateFolder() }
            }
            .padding(12)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("任务")
                            .font(.headline)
                        Spacer()
                        Button("暂停") { model.cockpitCommand("pause") }
                        Button("继续") { model.resumeSelected() }
                        Button("重试") { model.retrySelected() }
                        Button("停止") { model.cancelSelected() }
                    }
                    HStack(spacing: 6) {
                        TextField("人工反馈 / 重规划说明", text: $model.feedbackText)
                            .textFieldStyle(.roundedBorder)
                        Button("反馈") { model.cockpitCommand("feedback") }
                        Button("重规划") { model.cockpitCommand("replan") }
                        Button("分支") { model.cockpitCommand("branch") }
                    }
                    List(model.runs, id: \.id, selection: $model.selectedRunID) { run in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(run.status)
                                    .font(.caption)
                                    .monospaced()
                                Text(run.id.prefix(8))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            Text(run.goal)
                                .lineLimit(2)
                            Text(run.updatedAt.isEmpty ? run.createdAt : run.updatedAt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.selectedRunID) { _, _ in model.loadSelected() }
                }
                .frame(minWidth: 280, idealWidth: 320)
                .padding(12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("事件流")
                        .font(.headline)
                    ScrollView {
                        Text(model.selectedEvents.isEmpty ? "暂无事件" : model.selectedEvents)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    DisclosureGroup("驾驶舱") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Dashboard")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(model.dashboardText.isEmpty ? "暂无 dashboard" : model.dashboardText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 110)
                            HStack {
                                Text("Strategy")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("导出 Replay Session") { model.exportReplaySession() }
                            }
                            ScrollView {
                                Text(model.strategyText.isEmpty ? "暂无 strategy" : model.strategyText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 70)
                            Text("Checkpoint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(model.checkpointText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 100)
                            Text("Trajectory")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(model.trajectoryText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 120)
                            Text("Replay Plan")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(model.replayPlanText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 100)
                        }
                    }
                    DisclosureGroup("上下文") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Memory")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(model.memoryText.isEmpty ? "暂无记忆" : model.memoryText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 90)
                            Text("App Skills")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(model.appSkillsText.isEmpty ? "暂无 app skill" : model.appSkillsText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 110)
                            Text("Routines")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(model.routinesText.isEmpty ? "暂无 routine" : model.routinesText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 90)
                            Text("Verifiers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(model.verifierText.isEmpty ? "暂无 verifier" : model.verifierText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 100)
                            Text("Learning Workflows")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(model.learningWorkflowText.isEmpty ? "暂无 learning workflow" : model.learningWorkflowText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 90)
                        }
                    }
                    DisclosureGroup("审计") {
                        ScrollView {
                            Text(model.auditText.isEmpty ? "暂无审计记录" : model.auditText)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 100)
                    }
                    DisclosureGroup("评测") {
                        VStack(alignment: .leading, spacing: 6) {
                            Button("运行评测") { model.runEval() }
                            ScrollView {
                                Text(model.evalText.isEmpty ? "暂无评测结果" : model.evalText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 120)
                        }
                    }
                    Divider()
                    HStack(spacing: 8) {
                        TextField("Base URL", text: $model.baseURL)
                        TextField("Model", text: $model.modelName)
                            .frame(width: 180)
                        TextField("Steps", text: $model.maxSteps)
                            .frame(width: 64)
                        Button("保存配置") { model.saveConfig() }
                    }
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
